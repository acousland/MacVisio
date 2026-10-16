import AppKit
import ImageIO
import MacVisioInfrastructure

enum OwnedExportFormat: String {
    case pdf, png, svg, vsdx, vsd, vstx
}

struct ExportPreparationWork {
    var mainBatches = 0
    var preparedObjects = 0
    var retainedRecordBytes = 0
    var maximumMainStepSeconds: TimeInterval = 0
    var maximumObjectSeconds: TimeInterval = 0
}

struct OwnedExportResult {
    let jobID: UUID
    let input: LifecycleJobInput
    let destination: URL
    let preparation: ExportPreparationWork
}

/// UI drawing/font/layout work is recorded on main in bounded batches. Workers
/// receive only immutable PDF bytes or SVG markup, never AppKit views, mutable
/// retained scene layers, NSFontManager or live document state.
enum OwnedExportJobs {
    static let maximumRecordingBytes = 128 * 1024 * 1024

    @discardableResult
    static func submit(
        snapshot: Diagram, input: LifecycleJobInput, sourceURL: URL?, destination: URL,
        format: OwnedExportFormat, allPages: Bool = false, owner: LifecycleJobOwner,
        progress: @escaping (LifecycleJobProgress) -> Void = { _ in },
        completion: @escaping (Result<OwnedExportResult, Error>) -> Void
    ) throws -> LifecycleJobHandle {
        let jobID = UUID()
        let handle = try LifecycleJobService.shared.submit(
            id: jobID, kind: .export, input: input,
            accepts: { candidate in
                owner.isActive && candidate.ownerID == owner.id
            }, progress: progress,
            work: { context in
                var preparation = ExportPreparationWork()
                try AtomicJobOutput.write(
                    to: destination, input: sourceURL, cancellation: context.cancellation
                ) { staging in
                    switch format {
                    case .vsdx:
                        context.progress("Writing Visio drawing")
                        try VisioFormat.write(snapshot, to: staging)
                    case .vsd:
                        context.progress("Writing binary Visio drawing")
                        try VSDBinaryFormat.write(snapshot, to: staging)
                    case .vstx:
                        context.progress("Writing Visio template")
                        try VisioReusableFormat.writeTemplate(snapshot, to: staging)
                    case .pdf, .png, .svg:
                        let prepared = try MainExportRecorder.prepare(
                            snapshot: snapshot, format: format, allPages: allPages, context: context)
                        preparation = prepared.work
                        context.progress("Assembling \(format.rawValue.uppercased())")
                        try ExportRecordAssembly.write(
                            prepared.pages, to: staging, format: format, context: context)
                    }
                }
                return OwnedExportResult(
                    jobID: jobID, input: input, destination: destination, preparation: preparation)
            },
            completion: { result in
                owner.finish(jobID)
                completion(result)
            })
        owner.track(handle)
        return handle
    }

    @discardableResult
    static func submitStencil(
        definitions: [StencilDefinition], input: LifecycleJobInput, sourceURL: URL?, destination: URL,
        owner: LifecycleJobOwner, progress: @escaping (LifecycleJobProgress) -> Void = { _ in },
        completion: @escaping (Result<OwnedExportResult, Error>) -> Void
    ) throws -> LifecycleJobHandle {
        let jobID = UUID()
        let handle = try LifecycleJobService.shared.submit(
            id: jobID, kind: .export, input: input,
            accepts: { candidate in
                owner.isActive && candidate.ownerID == owner.id
            }, progress: progress,
            work: { context in
                context.progress("Writing Visio stencil")
                try AtomicJobOutput.write(
                    to: destination, input: sourceURL, cancellation: context.cancellation
                ) {
                    try VisioReusableFormat.writeStencil(definitions, to: $0)
                }
                return OwnedExportResult(
                    jobID: jobID, input: input, destination: destination, preparation: ExportPreparationWork()
                )
            },
            completion: { result in
                owner.finish(jobID)
                completion(result)
            })
        owner.track(handle)
        return handle
    }
}

private struct ExportRecordPage {
    let width: Double
    let height: Double
    let title: String
    var records: [Data] = []
}

private struct RecordedExport {
    let pages: [ExportRecordPage]
    let work: ExportPreparationWork
}

private final class ExportPreparationWaiter {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<RecordedExport, Error>?

    func finish(_ value: Result<RecordedExport, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws -> RecordedExport {
        semaphore.wait()
        lock.lock()
        let value = result!
        lock.unlock()
        return try value.get()
    }
}

private final class MainExportRecorder {
    private let snapshot: Diagram
    private let format: OwnedExportFormat
    private let pageIDs: [UUID]
    private let context: LifecycleJobContext
    private let waiter: ExportPreparationWaiter
    private var pages: [ExportRecordPage] = []
    private var scene: DiagramScene?
    private var runtime: PageRuntime?
    private var pageIndex = 0
    private var layerIndex = 0
    private var objectIndex = 0
    private var work = ExportPreparationWork()

    private init(
        snapshot: Diagram, format: OwnedExportFormat, allPages: Bool, context: LifecycleJobContext,
        waiter: ExportPreparationWaiter
    ) {
        self.snapshot = snapshot
        self.format = format
        self.context = context
        self.waiter = waiter
        pageIDs =
            allPages && format == .pdf
            ? snapshot.orderedPages.filter { $0.isBackground != true }.map(\.id) : [snapshot.page.id]
    }

    static func prepare(
        snapshot: Diagram, format: OwnedExportFormat, allPages: Bool, context: LifecycleJobContext
    ) throws -> RecordedExport {
        precondition(!Thread.isMainThread, "The worker waits while main prepares bounded drawing records")
        let snapshot = try snapshot.validated()
        let waiter = ExportPreparationWaiter()
        let handler = context.cancellation.onCancel { waiter.finish(.failure(LifecycleJobError.cancelled)) }
        defer { context.cancellation.removeHandler(handler) }
        let recorder = MainExportRecorder(
            snapshot: snapshot, format: format, allPages: allPages, context: context, waiter: waiter)
        DispatchQueue.main.async { recorder.step() }
        return try waiter.wait()
    }

    private func step() {
        precondition(Thread.isMainThread)
        do {
            try context.checkpoint()
            work.mainBatches += 1
            let start = ProcessInfo.processInfo.systemUptime
            var steps = 0
            while steps < 32 && (steps == 0 || ProcessInfo.processInfo.systemUptime - start < 0.004) {
                let stepStart = ProcessInfo.processInfo.systemUptime
                let finished = try autoreleasepool { try prepareOne() }
                work.maximumMainStepSeconds = max(
                    work.maximumMainStepSeconds, ProcessInfo.processInfo.systemUptime - stepStart)
                if finished {
                    waiter.finish(.success(RecordedExport(pages: pages, work: work)))
                    return
                }
                steps += 1
            }
            context.progress("Preparing \(format.rawValue.uppercased()): \(work.preparedObjects) objects")
            DispatchQueue.main.async { self.step() }
        } catch { waiter.finish(.failure(error)) }
    }

    /// Each setup stage is measured too: scene field resolution and an indexed
    /// layer build can exceed the target even before recording one object.
    private func prepareOne() throws -> Bool {
        try context.checkpoint()
        guard pageIndex < pageIDs.count else { return true }
        if scene == nil {
            let prepared = snapshot.scene(for: pageIDs[pageIndex])
            scene = prepared
            pages.append(
                ExportRecordPage(
                    width: prepared.page.paperWidth, height: prepared.page.paperHeight,
                    title: prepared.page.name))
            return false
        }
        let scene = self.scene!
        if layerIndex >= scene.layers.count {
            self.scene = nil
            runtime = nil
            layerIndex = 0
            objectIndex = 0
            pageIndex += 1
            return false
        }
        let layer = scene.layers[layerIndex]
        if runtime == nil {
            var printingPage = layer
            printingPage.layers = layer.layers?.map {
                var result = $0
                result.visible = result.visible && result.printable
                return result
            }
            runtime = PageRuntime(page: printingPage)
            return false
        }
        let runtime = self.runtime!
        guard objectIndex < runtime.paintOrder.count else {
            self.runtime = nil
            objectIndex = 0
            layerIndex += 1
            return false
        }
        let element = runtime.paintOrder[objectIndex]
        objectIndex += 1
        let start = ProcessInfo.processInfo.systemUptime
        let record: Data?
        switch element {
        case .node(let id):
            guard runtime.isVisible(nodeID: id), let node = runtime.nodesByID[id] else { return false }
            if format == .svg {
                record = svgRecord(
                    DiagramDrawing.svgFragment(node: node, in: layer), layer: layer, scene: scene)
            } else {
                let colored = DiagramDrawing.layerColored(node, in: layer)
                let prepared = PreparedNodeDrawing(colored, paperScale: layer.paperScale)
                record = try pdfRecord(layer: layer, scene: scene) {
                    DiagramDrawing.drawNode(
                        colored, shadow: false, paperScale: layer.paperScale, prepared: prepared)
                }
            }
        case .edge(let id):
            guard runtime.isVisible(edgeID: id), let edge = runtime.edgesByID[id] else { return false }
            let route = DiagramGeometry.route(edge, in: layer)
            if format == .svg {
                record = svgRecord(
                    DiagramDrawing.svgFragment(edge: edge, route: route, in: layer), layer: layer,
                    scene: scene)
            } else {
                record = try pdfRecord(layer: layer, scene: scene) {
                    DiagramDrawing.drawEdge(
                        DiagramDrawing.layerColored(edge, in: layer), in: layer, preparedRoute: route)
                }
            }
        }
        work.maximumObjectSeconds = max(
            work.maximumObjectSeconds, ProcessInfo.processInfo.systemUptime - start)
        if let record {
            guard record.count <= OwnedExportJobs.maximumRecordingBytes - work.retainedRecordBytes else {
                throw DiagramError.invalid("Prepared export records exceed the 128 MB retention limit.")
            }
            pages[pages.count - 1].records.append(record)
            work.retainedRecordBytes += record.count
            work.preparedObjects += 1
        }
        return false
    }

    private func svgRecord(_ content: String, layer: DiagramPage, scene: DiagramScene) -> Data {
        let offset = scene.offset(for: layer)
        return Data(
            "<g transform=\"translate(\(offset.x) \(offset.y)) scale(\(layer.paperScale))\">\(content)</g>"
                .utf8)
    }

    private func pdfRecord(layer: DiagramPage, scene: DiagramScene, draw: () -> Void) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: scene.page.paperWidth, height: scene.page.paperHeight)
        guard let consumer = CGDataConsumer(data: data),
            let drawing = CGContext(consumer: consumer, mediaBox: &box, nil)
        else {
            throw DiagramError.invalid("Could not prepare a vector export record.")
        }
        drawing.beginPDFPage(nil)
        drawing.clip(to: box)
        drawing.translateBy(x: 0, y: box.height)
        drawing.scaleBy(x: 1, y: -1)
        let offset = scene.offset(for: layer)
        drawing.translateBy(x: offset.x, y: offset.y)
        drawing.scaleBy(x: layer.paperScale, y: layer.paperScale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: drawing, flipped: true)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        drawing.endPDFPage()
        drawing.closePDF()
        return data as Data
    }
}

private enum ExportRecordAssembly {
    static func write(
        _ pages: [ExportRecordPage], to output: URL, format: OwnedExportFormat, context: LifecycleJobContext
    ) throws {
        precondition(!Thread.isMainThread)
        guard let first = pages.first else {
            throw DiagramError.invalid("There are no foreground pages to export.")
        }
        switch format {
        case .svg:
            let title = first.title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
                of: "<", with: "&lt;"
            ).replacingOccurrences(of: ">", with: "&gt;")
            var data = Data(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(first.width)\" height=\"\(first.height)\" viewBox=\"0 0 \(first.width) \(first.height)\"><title>\(title)</title><defs><clipPath id=\"paperClip\"><rect width=\"\(first.width)\" height=\"\(first.height)\"/></clipPath></defs><rect width=\"100%\" height=\"100%\" fill=\"white\"/><g clip-path=\"url(#paperClip)\">"
                    .utf8)
            for record in first.records {
                try context.checkpoint()
                data.append(record)
            }
            data.append(Data("</g></svg>".utf8))
            try data.write(to: output)
        case .pdf:
            guard let consumer = CGDataConsumer(url: output as CFURL),
                let drawing = CGContext(consumer: consumer, mediaBox: nil, nil)
            else {
                throw DiagramError.invalid("Could not create the PDF output.")
            }
            for page in pages {
                try context.checkpoint()
                var box = CGRect(x: 0, y: 0, width: page.width, height: page.height)
                let media = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                drawing.beginPDFPage([kCGPDFContextMediaBox as String: media] as CFDictionary)
                drawing.setFillColor(CGColor(gray: 1, alpha: 1))
                drawing.fill(box)
                try draw(page.records, in: drawing, context: context)
                drawing.endPDFPage()
            }
            drawing.closePDF()
        case .png:
            let width = Int(first.width * 2)
            let height = Int(first.height * 2)
            guard width > 0, height > 0, width <= 100000, height <= 100000, width <= 100_000_000 / height,
                let drawing = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                throw DiagramError.invalid("Page is too large to export as PNG.")
            }
            drawing.scaleBy(x: 2, y: 2)
            drawing.setFillColor(CGColor(gray: 1, alpha: 1))
            drawing.fill(CGRect(x: 0, y: 0, width: first.width, height: first.height))
            try draw(first.records, in: drawing, context: context)
            guard let image = drawing.makeImage(),
                let destination = CGImageDestinationCreateWithURL(
                    output as CFURL, "public.png" as CFString, 1, nil)
            else {
                throw DiagramError.invalid("Could not encode the PNG image.")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw DiagramError.invalid("Could not finish the PNG image.")
            }
        default: throw DiagramError.invalid("This export does not use prepared vector records.")
        }
    }

    private static func draw(_ records: [Data], in drawing: CGContext, context: LifecycleJobContext) throws {
        for record in records {
            try context.checkpoint()
            guard let provider = CGDataProvider(data: record as CFData),
                let document = CGPDFDocument(provider), let page = document.page(at: 1)
            else {
                throw DiagramError.invalid("A prepared vector export record is invalid.")
            }
            drawing.drawPDFPage(page)
        }
    }
}
