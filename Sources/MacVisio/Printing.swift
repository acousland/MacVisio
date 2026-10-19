import AppKit
import MacVisioInfrastructure

enum DiagramPrintingError: Error, LocalizedError, Equatable {
    case invalidPDF
    case invalidPageRange
    case invalidSettings
    case unsupportedSetting(String)
    case pageDoesNotFit(Int)
    case operationInProgress
    case alreadyRun

    var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "The prepared drawing PDF is invalid or exceeds the supported print limits."
        case .invalidPageRange:
            return "Choose a range within the drawing's foreground pages."
        case .invalidSettings:
            return "Choose a valid paper size, nonnegative margins, and positive scale. One drawing page per sheet is supported."
        case .unsupportedSetting(let setting):
            return "The selected print option “\(setting)” is not supported. Turn it off and print again."
        case .pageDoesNotFit(let page):
            return "Foreground page \(page) does not fit the selected paper, margins, and scale. Choose larger paper or an explicit smaller scale. Printing across tiles is not yet supported."
        case .operationInProgress:
            return "Finish the current native print operation before starting another."
        case .alreadyRun:
            return "This prepared print session has already run. Start a new print operation."
        }
    }
}

enum OwnedPrintJobs {
    /// Native page numbers refer exclusively to foreground pages in document
    /// order. Backgrounds are painted through each foreground's evaluated scene.
    @discardableResult
    static func submit(
        snapshot: Diagram, input: LifecycleJobInput, owner: LifecycleJobOwner,
        progress: @escaping (LifecycleJobProgress) -> Void = { _ in },
        completion: @escaping (Result<OwnedPreparedPDF, Error>) -> Void
    ) throws -> LifecycleJobHandle {
        let pages = snapshot.orderedPages.filter { $0.isBackground != true }.map(\.id)
        guard !pages.isEmpty else { throw DiagramError.invalid("There are no foreground pages to print.") }
        return try OwnedExportJobs.submitPreparedPDF(
            snapshot: snapshot, input: input, pageIDs: pages, owner: owner,
            progress: progress, completion: completion)
    }
}

/// Main-thread native publication of an immutable, evaluated PDF. A single
/// selected paper format is used for the operation. Smaller source pages retain
/// their physical dimensions on that common paper; there is no automatic fit.
final class DiagramPrintSession {
    let prepared: OwnedPreparedPDF
    let view: PrintDocumentView
    let printInfo: NSPrintInfo
    private(set) var operation: NSPrintOperation?
    private(set) var failure: Error?
    private var hasRun = false
    private let title: String

    init(prepared: OwnedPreparedPDF, title: String, basePrintInfo: NSPrintInfo? = nil) throws {
        precondition(Thread.isMainThread)
        self.prepared = prepared
        self.title = title
        view = try PrintDocumentView(data: prepared.data, expectedPageCount: prepared.pageIDs.count)
        printInfo = (basePrintInfo ?? NSPrintInfo.shared).copy() as! NSPrintInfo
        let paper = view.enclosingPaperSize
        // NSPrintInfo normalizes paperSize to its current orientation. Establish
        // the unrotated medium first, then orient it to the desired physical
        // bounds, rather than assigning a wide size while still in portrait.
        printInfo.orientation = .portrait
        printInfo.paperSize = CGSize(width: min(paper.width, paper.height), height: max(paper.width, paper.height))
        printInfo.orientation = paper.width > paper.height ? .landscape : .portrait
        guard abs(printInfo.paperSize.width - paper.width) <= 0.001,
              abs(printInfo.paperSize.height - paper.height) <= 0.001 else {
            throw DiagramPrintingError.invalidSettings
        }
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.scalingFactor = 1
        printInfo.horizontalPagination = .clip
        printInfo.verticalPagination = .clip
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        let settings = printInfo.dictionary()
        settings[NSPrintInfo.AttributeKey.allPages] = true
        settings[NSPrintInfo.AttributeKey.firstPage] = 1
        settings[NSPrintInfo.AttributeKey.lastPage] = prepared.pageIDs.count
        settings[NSPrintInfo.AttributeKey.pagesAcross] = 1
        settings[NSPrintInfo.AttributeKey.pagesDown] = 1
        settings[NSPrintInfo.AttributeKey.headerAndFooter] = false
        settings[NSPrintInfo.AttributeKey.selectionOnly] = false
        settings[NSPrintInfo.AttributeKey.reversePageOrder] = false
        settings.removeObject(forKey: NSPrintInfo.AttributeKey.jobSavingURL)
        printInfo.jobDisposition = .spool
        NativePrintSettings.initializeDefaults(in: printInfo)
    }

    /// Settings are accepted and checked before the native operation can spool.
    /// The panel is deliberately separate from rendering: invalid paper/range
    /// choices must throw a typed diagnostic before any page reaches a printer.
    /// A manually presented NSPrintPanel does not provide print preview here.
    @discardableResult
    func run(
        showsPrintPanel: Bool = true, isOwnerActive: () -> Bool = { true }
    ) throws -> Bool {
        precondition(Thread.isMainThread)
        do {
            if let failure { throw failure }
            guard !hasRun else { throw DiagramPrintingError.alreadyRun }
            guard isOwnerActive() else { throw LifecycleJobError.staleInput }
            guard NSPrintOperation.current == nil else { throw DiagramPrintingError.operationInProgress }
            if showsPrintPanel {
                let panel = NSPrintPanel()
                panel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling])
                panel.options.remove(.showsPreview)
                let accessory = DiagramPrintAccessoryController()
                panel.addAccessoryController(accessory)
                guard panel.runModal(with: printInfo) == NSApplication.ModalResponse.OK.rawValue else { return false }
            }
            guard isOwnerActive() else { throw LifecycleJobError.staleInput }
            let operation = try makeOperation()
            hasRun = true
            let success = operation.run()
            if let error = view.failure { throw error }
            return success
        } catch {
            if failure == nil { failure = error }
            throw error
        }
    }

    /// Exposed for native save-to-PDF qualification without contacting a printer.
    /// Callers must perform their owner check before running the result.
    func makeOperation() throws -> NSPrintOperation {
        precondition(Thread.isMainThread)
        if let failure { throw failure }
        guard NSPrintOperation.current == nil else { throw DiagramPrintingError.operationInProgress }
        try view.validate(printInfo: printInfo)
        // Custom native pagination does not reliably apply NSPrintInfo scaling
        // to save-to-PDF graphics. Consume the requested scale exactly once in
        // the PDF view, and spool at unit scale on both save and printer paths.
        // The session's printInfo continues to represent the user's settings.
        let scale = printInfo.scalingFactor
        let nativeInfo = printInfo.copy() as! NSPrintInfo
        nativeInfo.scalingFactor = 1
        try view.validate(printInfo: nativeInfo, additionalScale: scale)
        try view.configureRenderingScale(scale)
        let result = NSPrintOperation(view: view, printInfo: nativeInfo)
        result.jobTitle = title
        result.showsPrintPanel = false
        result.showsProgressPanel = false
        result.canSpawnSeparateThread = false
        result.pageOrder = .ascendingPageOrder
        // AppKit's documented factory contract copies this validated print info.
        // Do not introduce a throwing path after construction: creating the
        // operation can install NSPrintOperation.current before run cleans it up.
        operation = result
        return result
    }
}

/// Core Graphics PDF painting only. No Diagram, formulas, retained scenes,
/// AppKit fonts, or editable document state cross this publication boundary.
final class PrintDocumentView: NSView {
    static let maximumPaperDimension: CGFloat = 20_000
    static let maximumViewExtent: CGFloat = 100_000_000
    let pageRects: [CGRect]
    let enclosingPaperSize: CGSize
    private let document: CGPDFDocument
    private let data: Data
    private var printingPageRects: [CGRect]
    private var renderingScale: CGFloat = 1
    private(set) var failure: DiagramPrintingError?

    init(data: Data, expectedPageCount: Int) throws {
        precondition(Thread.isMainThread)
        guard !data.isEmpty, data.count <= OwnedExportJobs.maximumRecordingBytes,
              (1...1000).contains(expectedPageCount),
              let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), !document.isEncrypted,
              document.numberOfPages == expectedPageCount else { throw DiagramPrintingError.invalidPDF }
        self.document = document
        self.data = data
        var rects: [CGRect] = []
        var y: CGFloat = 0, width: CGFloat = 0, height: CGFloat = 0
        for index in 1...expectedPageCount {
            guard let page = document.page(at: index) else { throw DiagramPrintingError.invalidPDF }
            let box = page.getBoxRect(.mediaBox)
            guard [box.origin.x, box.origin.y, box.width, box.height].allSatisfy(\.isFinite),
                  box.origin == .zero, box.width > 0, box.height > 0,
                  box.width <= Self.maximumPaperDimension, box.height <= Self.maximumPaperDimension,
                  page.rotationAngle == 0 else { throw DiagramPrintingError.invalidPDF }
            rects.append(CGRect(x: 0, y: y, width: box.width, height: box.height))
            width = max(width, box.width)
            height = max(height, box.height)
            y += box.height
        }
        pageRects = rects
        printingPageRects = rects
        enclosingPaperSize = CGSize(width: width, height: height)
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: y))
    }

    required init?(coder: NSCoder) { return nil }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageRects.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        guard (1...printingPageRects.count).contains(page) else { return .zero }
        return printingPageRects[page - 1]
    }

    override func locationOfPrintRect(_ rect: NSRect) -> NSPoint {
        guard let info = NSPrintOperation.current?.printInfo else { return .zero }
        // Placement is in physical page coordinates, including requested margins.
        return CGPoint(x: info.leftMargin, y: info.paperSize.height - info.topMargin - rect.height)
    }

    func configureRenderingScale(_ scale: CGFloat) throws {
        precondition(Thread.isMainThread)
        let size = CGSize(width: enclosingPaperSize.width * scale,
                          height: (pageRects.last?.maxY ?? 0) * scale)
        guard scale.isFinite, scale > 0, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width <= Self.maximumViewExtent, size.height <= Self.maximumViewExtent else {
            throw DiagramPrintingError.invalidSettings
        }
        let rects = pageRects.map {
            CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale)
        }
        guard rects.allSatisfy({ rect in
            [rect.minX, rect.minY, rect.width, rect.height, rect.maxX, rect.maxY].allSatisfy(\.isFinite)
                && rect.width > 0 && rect.height > 0 && rect.minX >= 0 && rect.minY >= 0
                && rect.maxX <= Self.maximumViewExtent && rect.maxY <= Self.maximumViewExtent
        }) else {
            throw DiagramPrintingError.invalidSettings
        }
        renderingScale = scale
        printingPageRects = rects
        frame = CGRect(origin: .zero, size: size)
    }

    func selectedPages(printInfo info: NSPrintInfo) throws -> ClosedRange<Int> {
        let settings = info.dictionary()
        let allPages: Bool
        if let value = settings[NSPrintInfo.AttributeKey.allPages] {
            guard let number = value as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue == 0 || number.doubleValue == 1 else {
                throw DiagramPrintingError.invalidPageRange
            }
            allPages = number.boolValue
        } else { allPages = true }
        if allPages {
            return 1...pageRects.count
        }
        guard let first = settings[NSPrintInfo.AttributeKey.firstPage] as? NSNumber,
              let last = settings[NSPrintInfo.AttributeKey.lastPage] as? NSNumber,
              first.doubleValue.isFinite, last.doubleValue.isFinite,
              first.doubleValue.rounded() == first.doubleValue,
              last.doubleValue.rounded() == last.doubleValue,
              first.doubleValue >= 1, last.doubleValue <= Double(pageRects.count),
              first.doubleValue <= last.doubleValue else { throw DiagramPrintingError.invalidPageRange }
        return first.intValue...last.intValue
    }

    func validate(printInfo info: NSPrintInfo, additionalScale: CGFloat = 1) throws {
        // Physical-attribute getters and the backend printSettings bridge may
        // normalize malformed raw attributes. Refuse invalid page/range/layout
        // requests before asking AppKit to synchronize those values.
        let selected = try selectedPages(printInfo: info)
        try NativePrintSettings.validate(info)
        let paper = info.paperSize, scale = info.scalingFactor * additionalScale
        let margins = [info.leftMargin, info.rightMargin, info.topMargin, info.bottomMargin]
        guard [paper.width, paper.height, scale].allSatisfy({ $0.isFinite && $0 > 0 }),
              paper.width <= Self.maximumPaperDimension, paper.height <= Self.maximumPaperDimension,
              margins.allSatisfy({ $0.isFinite && $0 >= 0 }),
              info.horizontalPagination == .clip, info.verticalPagination == .clip else {
            throw DiagramPrintingError.invalidSettings
        }
        let availableWidth = paper.width - info.leftMargin - info.rightMargin
        let availableHeight = paper.height - info.topMargin - info.bottomMargin
        guard availableWidth > 0, availableHeight > 0 else { throw DiagramPrintingError.invalidSettings }
        for page in selected {
            let rect = pageRects[page - 1]
            guard rect.width * scale <= availableWidth + 0.001,
                  rect.height * scale <= availableHeight + 0.001 else {
                throw DiagramPrintingError.pageDoesNotFit(page)
            }
        }
        // These are document-margin checks. Printer imageable bounds and
        // device calibration are separate, unqualified physical constraints.
    }

    override func draw(_ dirtyRect: NSRect) {
        guard failure == nil, let drawing = NSGraphicsContext.current?.cgContext else { return }
        if let info = NSPrintOperation.current?.printInfo {
            do { try validate(printInfo: info, additionalScale: renderingScale) }
            catch { failure = error as? DiagramPrintingError ?? .invalidSettings; return }
        }
        for (index, rect) in printingPageRects.enumerated() where rect.intersects(dirtyRect) {
            guard let page = document.page(at: index + 1) else { failure = .invalidPDF; return }
            drawing.saveGState()
            drawing.clip(to: rect)
            drawing.translateBy(x: rect.minX, y: rect.minY)
            drawing.scaleBy(x: renderingScale, y: renderingScale)
            drawing.drawPDFPage(page)
            drawing.restoreGState()
        }
    }
}

/// These controls are documented in the SDK's PMPrintSettingsKeys.h. NSPrintInfo
/// exposes Core Printing's dotted setting names with underscores in printSettings
/// (NSPrintInfo.h). Inspect both documented spellings if supplied, while creating
/// isolated defaults with the NSPrintInfo spelling. Device, duplex, color, copies,
/// collation, and other spool settings remain owned by the native print system.
private enum NativePrintSettings {
    private static let layoutNUp = "com.apple.print.PrintSettings.PMLayoutNUp"
    private static let layoutRows = "com.apple.print.PrintSettings.PMLayoutRows"
    private static let layoutColumns = "com.apple.print.PrintSettings.PMLayoutColumns"
    private static let selectionOnly = "com.apple.print.PrintSettings.PMPrintSelectionOnly"
    private static let pageMapping = "com.apple.print.PageToPaperMappingType"
    private static let allowScalingUp = "com.apple.print.PageToPaperMappingAllowScalingUp"
    private static let outputOrder = "OutputOrder"
    private static let pageSet = "page-set"
    private static let mirror = "mirror"

    static func initializeDefaults(in info: NSPrintInfo) {
        let defaults: [(String, Any)] = [
            (layoutNUp, false), (layoutRows, 1), (layoutColumns, 1), (selectionOnly, false),
            // PMPageToPaperMappingType: kPMPageToPaperMappingNone = 1.
            (pageMapping, 1), (allowScalingUp, false),
            (outputOrder, "Normal"), (pageSet, "all"), (mirror, "false")
        ]
        for (key, value) in defaults {
            info.printSettings.removeObject(forKey: key)
            info.printSettings[normalized(key)] = value
        }
    }

    static func validate(_ info: NSPrintInfo) throws {
        let attributes = info.dictionary()
        let disabled: [(NSPrintInfo.AttributeKey, String)] = [
            (.reversePageOrder, "Reverse page order"), (.selectionOnly, "Print selection only"),
            (.headerAndFooter, "Headers and footers"),
            (.horizontallyCentered, "Centered page placement"), (.verticallyCentered, "Centered page placement")
        ]
        for (key, label) in disabled { try requireNumber(attributes[key], equals: 0, label: label) }
        for key in [NSPrintInfo.AttributeKey.pagesAcross, .pagesDown] {
            try requireNumber(attributes[key], equals: 1, label: "Multiple pages per sheet")
        }
        let settings = info.printSettings
        let numeric: [(String, Double, String)] = [
            (layoutNUp, 0, "Multiple pages per sheet"),
            (layoutRows, 1, "Multiple pages per sheet"),
            (layoutColumns, 1, "Multiple pages per sheet"),
            (selectionOnly, 0, "Print selection only"),
            (pageMapping, 1, "Automatic page-to-paper scaling"),
            (allowScalingUp, 0, "Automatic page-to-paper scaling")
        ]
        for (key, expected, label) in numeric {
            for spelling in spellings(key) { try requireNumber(settings[spelling], equals: expected, label: label) }
        }
        for (key, expected, label) in [
            (outputOrder, "Normal", "Reverse page order"),
            (pageSet, "all", "Odd/even page filtering"),
            (mirror, "false", "Mirrored printing")
        ] {
            for spelling in spellings(key) {
                guard let value = settings[spelling] else { continue }
                guard let text = value as? String, text.caseInsensitiveCompare(expected) == .orderedSame else {
                    throw DiagramPrintingError.unsupportedSetting(label)
                }
            }
        }
    }

    private static func requireNumber(_ value: Any?, equals expected: Double, label: String) throws {
        guard let value else { return }
        guard let number = value as? NSNumber, number.doubleValue.isFinite,
              number.doubleValue == expected else { throw DiagramPrintingError.unsupportedSetting(label) }
    }

    private static func normalized(_ key: String) -> String {
        key.replacingOccurrences(of: ".", with: "_")
    }

    private static func spellings(_ key: String) -> [String] {
        let name = normalized(key)
        return name == key ? [key] : [name, key]
    }
}

private final class DiagramPrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    override func loadView() {
        let label = NSTextField(wrappingLabelWithString:
            "All foreground pages use one selected paper size. Default scale is 100% with zero document margins. Smaller drawing pages keep their physical size. Choose paper large enough for the selected pages; tiling is not available. Printer hardware margins still apply.")
        label.frame = CGRect(x: 16, y: 16, width: 380, height: 90)
        view = NSView(frame: CGRect(x: 0, y: 0, width: 412, height: 122))
        view.addSubview(label)
        title = "Drawing pages"
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Drawing pages", .itemDescription: "One paper size; explicit scale; no tiling or automatic fit."]]
    }
}
