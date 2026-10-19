import AppKit
import ImageIO
import MacVisioInfrastructure

enum OwnedExportFormat: String {
    case pdf, png, svg, vsdx, vsd, vstx
    case jpeg = "jpg"
    case tiff
    var isRaster: Bool { self == .png || self == .jpeg || self == .tiff }
    var displayName: String { self == .jpeg ? "JPEG" : rawValue.uppercased() }
}

/// ImageIO's documented quality input; these labels make no codec, chroma
/// sampling, file-size or reference-fidelity promise.
enum JPEGExportQuality: Double, CaseIterable, Hashable {
    case standard = 0.6, high = 0.85, maximum = 1
    var title: String {
        switch self { case .standard: return "Standard (60%)"
        case .high: return "High (85%)"
        case .maximum: return "Maximum (100%)" }
    }
}

/// Value settings captured with the immutable export snapshot. Physical page
/// dimensions stay in points; raster resolution changes only the sampling.
struct OwnedExportOptions: Equatable {
    static let supportedDPI = 36.0...1200.0
    static let maximumRasterDimension = 100_000
    /// Conservative product bound for this JPEG writer, not a codec maximum.
    static let maximumJPEGRasterDimension = 65_000
    static let maximumRasterPixels = 100_000_000
    var rasterDPI: Double = 144
    var transparentBackground = false
    /// Nil uses High for JPEG. A JPEG-only request on another format is refused.
    var jpegQuality: JPEGExportQuality? = nil
    /// Explicit PDF order takes precedence over the legacy active/all selector.
    var pdfPageIDs: [UUID]? = nil
    var rasterRegion: RasterExportRegion = .page
    var rasterSelection: RasterExportSelection? = nil

    func pageIDs(in snapshot: Diagram, format: OwnedExportFormat, allPages: Bool = false) throws -> [UUID] {
        try validateRasterFormat(format)
        if (format == .jpeg || format == .tiff), allPages {
            throw DiagramError.invalid("JPEG and TIFF export one active page or region. Use PDF to export multiple pages.")
        }
        if format != .pdf, pdfPageIDs != nil { throw DiagramError.invalid("Page selection is available for PDF export.") }
        if !format.isRaster, rasterRegion != .page || rasterSelection != nil {
            throw DiagramError.invalid("Region selection is available for raster export.")
        }
        if format.isRaster {
            try validateRasterDPI()
            if rasterRegion == .page {
                try validateRasterDimensions(rasterSize(width: snapshot.page.paperWidth, height: snapshot.page.paperHeight), format: format)
            }
            if rasterRegion != .selection, rasterSelection != nil {
                throw DiagramError.invalid("A captured selection requires Selection bounds.")
            }
        }
        guard format == .pdf else { return [snapshot.page.id] }
        if let selected = pdfPageIDs {
            let available = Set(snapshot.pages.map(\.id))
            guard !selected.isEmpty, selected.count <= 1000, Set(selected).count == selected.count,
                  selected.allSatisfy({ available.contains($0) }) else {
                throw DiagramError.invalid("Choose one or more different pages from the current drawing, in export order.")
            }
            return selected
        }
        let result = allPages ? snapshot.orderedPages.filter { $0.isBackground != true }.map(\.id) : [snapshot.page.id]
        guard !result.isEmpty else { throw DiagramError.invalid("There are no foreground pages to export.") }
        return result
    }

    func validateRasterFormat(_ format: OwnedExportFormat) throws {
        if format == .jpeg, transparentBackground {
            throw DiagramError.invalid("JPEG requires an opaque white background. Choose PNG or TIFF to retain transparency.")
        }
        if format != .jpeg, jpegQuality != nil {
            throw DiagramError.invalid("JPEG quality is available only for JPEG export.")
        }
    }

    func validateRasterDimensions(_ size: (width: Int, height: Int), format: OwnedExportFormat) throws {
        if format == .jpeg, size.width > Self.maximumJPEGRasterDimension || size.height > Self.maximumJPEGRasterDimension {
            throw DiagramError.invalid("JPEG export supports dimensions up to 65,000 pixels and 100 million pixels total. Choose a lower resolution.")
        }
    }

    func validateRasterDPI() throws {
        guard rasterDPI.isFinite, Self.supportedDPI.contains(rasterDPI) else {
            throw DiagramError.invalid("Raster resolution must be between 36 and 1200 dpi.")
        }
    }

    func rasterSize(width: Double, height: Double) throws -> (width: Int, height: Int) {
        try validateRasterDPI()
        let scale = rasterDPI / 72, w = width * scale, h = height * scale
        guard width.isFinite, height.isFinite, width > 0, height > 0, w.isFinite, h.isFinite,
              w >= 1, h >= 1, w <= Double(Self.maximumRasterDimension), h <= Double(Self.maximumRasterDimension) else {
            throw DiagramError.invalid("The page and resolution exceed the supported raster dimensions.")
        }
        let pixels = (width: Int(w), height: Int(h))
        guard pixels.width <= Self.maximumRasterPixels / pixels.height else {
            throw DiagramError.invalid("Raster export supports up to 100 million pixels. Choose a lower resolution.")
        }
        return pixels
    }
}

struct ExportPreparationWork {
    var mainBatches = 0
    var preparedObjects = 0
    var measuredObjects = 0
    var rasterViewport: CGRect? = nil
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

/// Immutable worker-produced PDF used by publication consumers that do not need
/// a file destination. AppKit painting has already completed before delivery.
struct OwnedPreparedPDF {
    let jobID: UUID
    let input: LifecycleJobInput
    let data: Data
    let pageIDs: [UUID]
    let preparation: ExportPreparationWork
}

/// UI drawing/font/layout work is recorded on main in bounded batches. Workers
/// receive only immutable PDF bytes or SVG markup, never AppKit views, mutable
/// retained scene layers, NSFontManager or live document state.
enum OwnedExportJobs {
    static let maximumRecordingBytes = 128 * 1024 * 1024

    @discardableResult
    static func submitPreparedPDF(
        snapshot: Diagram, input: LifecycleJobInput, pageIDs: [UUID], owner: LifecycleJobOwner,
        progress: @escaping (LifecycleJobProgress) -> Void = { _ in },
        completion: @escaping (Result<OwnedPreparedPDF, Error>) -> Void
    ) throws -> LifecycleJobHandle {
        let jobID = UUID()
        let options = OwnedExportOptions(pdfPageIDs: pageIDs)
        let handle = try LifecycleJobService.shared.submit(
            id: jobID, kind: .export, input: input,
            accepts: { owner.isActive && $0.ownerID == owner.id }, progress: progress,
            work: { context in
                let prepared = try MainExportRecorder.prepare(
                    snapshot: snapshot, format: .pdf, allPages: false, options: options, context: context)
                context.progress("Assembling print PDF")
                let data = try ExportRecordAssembly.pdfData(prepared.pages, context: context)
                try context.checkpoint()
                return OwnedPreparedPDF(
                    jobID: jobID, input: input, data: data, pageIDs: pageIDs,
                    preparation: prepared.work)
            }, completion: { result in
                owner.finish(jobID)
                completion(result)
            })
        owner.track(handle)
        return handle
    }

    @discardableResult
    static func submit(
        snapshot: Diagram, input: LifecycleJobInput, sourceURL: URL?, destination: URL,
        format: OwnedExportFormat, allPages: Bool = false, options: OwnedExportOptions = OwnedExportOptions(), owner: LifecycleJobOwner,
        progress: @escaping (LifecycleJobProgress) -> Void = { _ in },
        completion: @escaping (Result<OwnedExportResult, Error>) -> Void
    ) throws -> LifecycleJobHandle {
        try options.validateRasterFormat(format)
        if !format.isRaster, options.rasterRegion != .page || options.rasterSelection != nil {
            throw DiagramError.invalid("Region selection is available for raster export.")
        }
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
                    case .pdf, .png, .jpeg, .tiff, .svg:
                        let prepared = try MainExportRecorder.prepare(
                            snapshot: snapshot, format: format, allPages: allPages, options: options, context: context)
                        preparation = prepared.work
                        context.progress("Assembling \(format.displayName)")
                        try ExportRecordAssembly.write(
                            prepared.pages, to: staging, format: format, options: options, context: context)
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
    var rasterViewport: RasterExportViewport? = nil
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
    private let options: OwnedExportOptions
    private let membership: RasterExportMembership?
    private var measuringBounds = false
    private var paintBounds = CGRect.null
    private var isCroppedRaster: Bool { format.isRaster && options.rasterRegion != .page }

    private init(
        snapshot: Diagram, format: OwnedExportFormat, pageIDs: [UUID], context: LifecycleJobContext,
        waiter: ExportPreparationWaiter, options: OwnedExportOptions, membership: RasterExportMembership?
    ) {
        self.snapshot = snapshot
        self.format = format
        self.context = context
        self.waiter = waiter
        self.pageIDs = pageIDs
        self.options = options
        self.membership = membership
    }

    static func prepare(
        snapshot: Diagram, format: OwnedExportFormat, allPages: Bool, options: OwnedExportOptions, context: LifecycleJobContext
    ) throws -> RecordedExport {
        precondition(!Thread.isMainThread, "The worker waits while main prepares bounded drawing records")
        let snapshot = try snapshot.validated()
        let pageIDs = try options.pageIDs(in: snapshot, format: format, allPages: allPages)
        let membership: RasterExportMembership?
        if format.isRaster, options.rasterRegion == .selection {
            guard let selection = options.rasterSelection else { throw DiagramError.invalid("Capture a selection before exporting Selection bounds.") }
            membership = try selection.expanded(in: snapshot, input: context.input, cancellation: context.cancellation)
        } else { membership = nil }
        let waiter = ExportPreparationWaiter()
        let handler = context.cancellation.onCancel { waiter.finish(.failure(LifecycleJobError.cancelled)) }
        defer { context.cancellation.removeHandler(handler) }
        let recorder = MainExportRecorder(
            snapshot: snapshot, format: format, pageIDs: pageIDs, context: context, waiter: waiter,
            options: options, membership: membership)
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
            context.progress(measuringBounds ? "Measuring \(format.displayName) bounds: \(work.measuredObjects) objects"
                             : "Preparing \(format.displayName): \(work.preparedObjects) objects")
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
            measuringBounds = isCroppedRaster
            paintBounds = .null
            pages.append(
                ExportRecordPage(
                    width: prepared.page.paperWidth, height: prepared.page.paperHeight,
                    title: prepared.page.name))
            return false
        }
        let scene = self.scene!
        if layerIndex >= scene.layers.count {
            if measuringBounds {
                let viewport = try RasterExportViewport.cropped(paintBounds, options: options)
                try options.validateRasterDimensions((viewport.pixelWidth, viewport.pixelHeight), format: format)
                pages[pages.count - 1] = ExportRecordPage(width: viewport.rect.width, height: viewport.rect.height,
                                                        title: scene.page.name, rasterViewport: viewport)
                work.rasterViewport = viewport.rect
                measuringBounds = false
                runtime = nil
                layerIndex = 0
                objectIndex = 0
                return false
            }
            self.scene = nil
            runtime = nil
            layerIndex = 0
            objectIndex = 0
            pageIndex += 1
            return false
        }
        let layer = scene.layers[layerIndex]
        if measuringBounds, options.rasterRegion == .selection, layer.id != scene.page.id {
            layerIndex += 1
            return false
        }
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
        if options.rasterRegion == .selection, layer.id == scene.page.id,
           membership?.contains(element) != true { return false }
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
                if measuringBounds {
                    let bounds = try PublicationBounds.node(colored, prepared: prepared, paperScale: layer.paperScale)
                    paintBounds = paintBounds.union(PublicationBounds.offset(bounds, by: scene.offset(for: layer)))
                    work.measuredObjects += 1
                    work.maximumObjectSeconds = max(work.maximumObjectSeconds, ProcessInfo.processInfo.systemUptime - start)
                    return false
                }
                record = try pdfRecord(layer: layer, scene: scene, viewport: pages.last?.rasterViewport?.rect) {
                    DiagramDrawing.drawNode(
                        colored, shadow: false, paperScale: layer.paperScale, prepared: prepared)
                }
            }
        case .edge(let id):
            guard runtime.isVisible(edgeID: id), let edge = runtime.edgesByID[id] else { return false }
            let route = DiagramGeometry.route(edge, in: layer)
            let colored = DiagramDrawing.layerColored(edge, in: layer)
            let label = isCroppedRaster && !edge.label.isEmpty ? PreparedEdgeLabel(text: colored.label, color: colored.color) : nil
            if measuringBounds {
                let bounds = PublicationBounds.edge(colored, route: route, label: label, paperScale: layer.paperScale)
                paintBounds = paintBounds.union(PublicationBounds.offset(bounds, by: scene.offset(for: layer)))
                work.measuredObjects += 1
                work.maximumObjectSeconds = max(work.maximumObjectSeconds, ProcessInfo.processInfo.systemUptime - start)
                return false
            }
            if format == .svg {
                record = svgRecord(
                    DiagramDrawing.svgFragment(edge: edge, route: route, in: layer), layer: layer,
                    scene: scene)
            } else {
                record = try pdfRecord(layer: layer, scene: scene, viewport: pages.last?.rasterViewport?.rect) {
                    DiagramDrawing.drawEdge(colored, in: layer, preparedRoute: route, preparedLabel: label)
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

    private func pdfRecord(layer: DiagramPage, scene: DiagramScene, viewport: CGRect? = nil, draw: () -> Void) throws -> Data {
        let data = NSMutableData()
        let source = viewport ?? CGRect(x: 0, y: 0, width: scene.page.paperWidth, height: scene.page.paperHeight)
        var box = CGRect(origin: .zero, size: source.size)
        guard let consumer = CGDataConsumer(data: data),
            let drawing = CGContext(consumer: consumer, mediaBox: &box, nil)
        else {
            throw DiagramError.invalid("Could not prepare a vector export record.")
        }
        drawing.beginPDFPage(nil)
        drawing.clip(to: box)
        drawing.translateBy(x: -source.minX, y: source.maxY)
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
    /// A consumer callback refuses bytes before the retained output exceeds the
    /// same 128 MiB bound as the preparation records. Assembly stays on a worker.
    static func pdfData(_ pages: [ExportRecordPage], context: LifecycleJobContext) throws -> Data {
        precondition(!Thread.isMainThread)
        let output = BoundedPDFOutput(limit: OwnedExportJobs.maximumRecordingBytes)
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            return Unmanaged<BoundedPDFOutput>.fromOpaque(info).takeUnretainedValue()
                .append(bytes, count: count)
        }, releaseConsumer: { info in
            guard let info else { return }
            Unmanaged<BoundedPDFOutput>.fromOpaque(info).release()
        })
        let retainedOutput = Unmanaged.passRetained(output)
        guard let consumer = CGDataConsumer(info: retainedOutput.toOpaque(), cbks: &callbacks) else {
            // Failed construction never transfers callback ownership.
            retainedOutput.release()
            throw DiagramError.invalid("Could not create the prepared print PDF consumer.")
        }
        guard let drawing = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            // Releasing the successfully created consumer balances its retain,
            // including on this context-construction failure path.
            throw DiagramError.invalid("Could not create the prepared print PDF.")
        }
        try writePDF(pages, in: drawing, context: context)
        guard !output.exceeded else {
            throw DiagramError.invalid("Prepared print PDF exceeds the 128 MB retention limit.")
        }
        try context.checkpoint()
        return output.data as Data
    }

    static func write(
        _ pages: [ExportRecordPage], to output: URL, format: OwnedExportFormat, options: OwnedExportOptions, context: LifecycleJobContext
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
            try writePDF(pages, in: drawing, context: context)
        case .png, .jpeg, .tiff:
            try options.validateRasterFormat(format)
            let size: (width: Int, height: Int)
            if let viewport = first.rasterViewport { size = (viewport.pixelWidth, viewport.pixelHeight) }
            else { size = try options.rasterSize(width: first.width, height: first.height) }
            try options.validateRasterDimensions(size, format: format)
            let width = size.width, height = size.height
            guard let drawing = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: (format == .jpeg ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)
            else {
                throw DiagramError.invalid("Page is too large to export as \(format.displayName).")
            }
            drawing.clear(CGRect(x: 0, y: 0, width: width, height: height))
            let scale = options.rasterDPI / 72
            drawing.scaleBy(x: scale, y: scale)
            if !options.transparentBackground {
                drawing.setFillColor(CGColor(gray: 1, alpha: 1))
                drawing.fill(CGRect(x: 0, y: 0, width: first.width, height: first.height))
            }
            try draw(first.records, in: drawing, context: context)
            try context.checkpoint()
            let type = format == .jpeg ? "public.jpeg" : (format == .tiff ? "public.tiff" : "public.png")
            guard let image = drawing.makeImage(),
                let destination = CGImageDestinationCreateWithURL(
                    output as CFURL, type as CFString, 1, nil)
            else {
                throw DiagramError.invalid("Could not encode the \(format.displayName) image.")
            }
            var properties: [CFString: Any] = [kCGImagePropertyDPIWidth: options.rasterDPI, kCGImagePropertyDPIHeight: options.rasterDPI]
            if format == .jpeg {
                properties[kCGImageDestinationLossyCompressionQuality] = (options.jpegQuality ?? .high).rawValue
            }
            if format == .jpeg || format == .tiff {
                properties[kCGImagePropertyOrientation] = 1
                // ImageIO writes JPEG physical density in EXIF's TIFF IFD.
                // Its JFIF unit is an aspect ratio, not an absolute DPI claim.
                // Keep the resolution unit integer-typed alongside the rationals.
                let density: [CFString: Any] = [kCGImagePropertyTIFFXResolution: options.rasterDPI,
                    kCGImagePropertyTIFFYResolution: options.rasterDPI, kCGImagePropertyTIFFResolutionUnit: 2]
                properties[kCGImagePropertyTIFFDictionary] = density
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            try context.checkpoint()
            guard CGImageDestinationFinalize(destination) else {
                throw DiagramError.invalid("Could not finish the \(format.displayName) image.")
            }
            try context.checkpoint()
        default: throw DiagramError.invalid("This export does not use prepared vector records.")
        }
    }

    private static func writePDF(
        _ pages: [ExportRecordPage], in drawing: CGContext, context: LifecycleJobContext
    ) throws {
        defer { drawing.closePDF() }
        guard !pages.isEmpty else { throw DiagramError.invalid("There are no foreground pages to print.") }
        for page in pages {
            try context.checkpoint()
            var box = CGRect(x: 0, y: 0, width: page.width, height: page.height)
            let media = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
            drawing.beginPDFPage([kCGPDFContextMediaBox as String: media] as CFDictionary)
            drawing.setFillColor(CGColor(gray: 1, alpha: 1))
            drawing.fill(box)
            do { try draw(page.records, in: drawing, context: context) }
            catch { drawing.endPDFPage(); throw error }
            drawing.endPDFPage()
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

private final class BoundedPDFOutput {
    let data = NSMutableData()
    let limit: Int
    private(set) var exceeded = false

    init(limit: Int) { self.limit = limit }

    func append(_ bytes: UnsafeRawPointer, count: Int) -> Int {
        guard !exceeded, count <= limit - data.length else {
            exceeded = true
            return 0
        }
        data.append(bytes, length: count)
        return count
    }
}
