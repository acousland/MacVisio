import AppKit
import QuartzCore

/// Observes traced input handling and canvas drawing while a drag/pan measurement runs.
/// Inactive (nil) outside `--measure-drag-pan`, so ordinary editing pays only a nil check.
final class DragPanProbe {
    static var active: DragPanProbe?
    /// Phase whose inputs are currently being handled; each phase's handled times pair with its own posted inputs.
    fileprivate var phase = "idle"
    fileprivate(set) var handled: [String: [Double]] = [:]
    fileprivate(set) var handlingDurations: [String: [Double]] = [:]
    fileprivate(set) var lastDrawEnd = 0.0
    fileprivate(set) var drawDurations: [Double] = []
    fileprivate(set) var phaseDrawDurations: [String: [Double]] = [:]
    private var inputStart: Double?
    fileprivate(set) var dirtyAreas: [String: [Double]] = [:]
    func dirty(_ rect: NSRect, visible: NSRect) { dirtyAreas[phase, default: []].append(Double(rect.width * rect.height / max(1, visible.width * visible.height))) }
    func inputStarted() { inputStart = CACurrentMediaTime() }
    func inputHandled() {
        let now = CACurrentMediaTime()
        handled[phase, default: []].append(now)
        if let inputStart { handlingDurations[phase, default: []].append(now - inputStart) }
        inputStart = nil
    }
    func drew(since start: Double) {
        lastDrawEnd = CACurrentMediaTime()
        drawDurations.append(lastDrawEnd - start)
        phaseDrawDurations[phase, default: []].append(lastDrawEnd - start)
    }
}

/// MV-NFR-02: replays a defined drag and pan trace through the editor's own event handlers in an
/// on-screen editor window. Input-to-feedback runs from posting an input to the display-link
/// target time of the first frame presented after that input was handled and drawn. Frame time is
/// the interval between successive presented frames that carried new canvas content while the
/// trace was producing input at 120 Hz, faster than the display refreshes. Never saves the drawing.
@available(macOS 14.0, *)
final class DragPanPerformance: NSObject {
    static let steps = 240, runs = 5, inputInterval = 1.0 / 120

    private let editor: EditorWindowController
    private let document: MacVisioDocument
    private let output: URL
    private let probe = DragPanProbe()
    private var link: CADisplayLink?
    private var posted: [Double] = []
    private var feedback: [Double?] = []
    private var phaseOf: [String] = []
    private var frames: [(phase: String, time: Double)] = []
    private var drawsAtLastTick = 0
    private var originAtLastTick = CGPoint.zero
    private var phase = "idle" { didSet { probe.phase = phase } }
    private var postedIndex: [String: Int] = [:]
    private var phaseIndexOf: [Int] = []
    private var errors: [String] = []
    private var fitZoom = 1.0

    private init(editor: EditorWindowController, document: MacVisioDocument, output: URL) {
        self.editor = editor; self.document = document; self.output = output
    }

    static func run(_ delegate: AppDelegate, input: URL, output: URL) {
        guard input.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL else {
            fputs("The timing report must differ from the drawing.\n", stderr); exit(1)
        }
        NSApp.activate(ignoringOtherApps: true)
        delegate.open(input) { document, error in
            guard let document, error == nil, let editor = document.windowControllers.first as? EditorWindowController else {
                fputs("Drag/pan measurement could not open the drawing: \(error?.localizedDescription ?? "unknown")\n", stderr); exit(1)
            }
            let measurement = DragPanPerformance(editor: editor, document: document, output: output)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { measurement.start() }
            objc_setAssociatedObject(editor, &associationKey, measurement, .OBJC_ASSOCIATION_RETAIN)
        }
    }
    private static var associationKey = 0

    private var canvas: CanvasView { editor.canvas }
    private var window: NSWindow { editor.window! }

    private func start() {
        if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.visibleFrame, display: true) }
        window.makeKeyAndOrderFront(nil)
        canvas.fitPage()
        fitZoom = canvas.zoom
        window.makeFirstResponder(canvas)
        window.displayIfNeeded()
        DragPanProbe.active = probe
        let link = canvas.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.runPhase(run: 0) }
    }

    // MARK: Trace

    private func runPhase(run: Int) {
        guard run < Self.runs else { return finish() }
        // MACVISIO_TRACE_PHASES=drag or =pan profiles one phase alone; the qualification trace runs both.
        let only = ProcessInfo.processInfo.environment["MACVISIO_TRACE_PHASES"]
        let panThenNext = { if only == "drag" { self.runPhase(run: run + 1) } else { self.pan(run: run) { self.runPhase(run: run + 1) } } }
        if only == "pan" { panThenNext() } else { drag(run: run) { panThenNext() } }
    }

    /// The unlocked top-level shape nearest the middle of the visible canvas.
    private func visibleNode() -> DiagramNode? {
        let visible = canvas.visibleRect.insetBy(dx: 60, dy: 60)
        let middle = CGPoint(x: visible.midX, y: visible.midY)
        let runtime = document.runtime()
        return document.diagram.page.nodes.filter { node in
            guard node.parentID == nil, !runtime.isLocked(nodeID: node.id) else { return false }
            return visible.contains(viewPoint(CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2)))
        }.min { a, b in
            let pa = viewPoint(CGPoint(x: a.x + a.width / 2, y: a.y + a.height / 2)), pb = viewPoint(CGPoint(x: b.x + b.width / 2, y: b.y + b.height / 2))
            return hypot(pa.x - middle.x, pa.y - middle.y) < hypot(pb.x - middle.x, pb.y - middle.y)
        }
    }

    /// Scrolls so the bounding box of the page's shapes is centred in the viewport.
    private func centerOnShapes() {
        let nodes = document.diagram.page.nodes
        guard !nodes.isEmpty else { return }
        let box = nodes.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
        let middle = viewPoint(CGPoint(x: box.midX, y: box.midY)), visible = canvas.visibleRect
        canvas.scroll(CGPoint(x: max(0, middle.x - visible.width / 2), y: max(0, middle.y - visible.height / 2)))
    }

    private func viewPoint(_ page: CGPoint) -> CGPoint {
        ViewportCoordinates(pageOrigin: canvas.pageOrigin, paperScale: canvas.page.paperScale, zoom: canvas.zoom)
            .canvas(DrawingLocation(point: page)).point
    }

    private func mouse(_ type: NSEvent.EventType, at viewPoint: CGPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: canvas.convert(viewPoint, to: nil), modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
    }

    private func drag(run: Int, then next: @escaping () -> Void) {
        canvas.setZoom(fitZoom)
        centerOnShapes()
        window.displayIfNeeded()
        // Let the zoom change's full redraw finish before the measured trace begins.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.dragTrace(run: run, then: next) }
    }

    private func dragTrace(run: Int, then next: @escaping () -> Void) {
        guard let node = visibleNode() else {
            errors.append("No visible unlocked shape for drag run \(run) in \(NSStringFromRect(canvas.visibleRect)) at zoom \(canvas.zoom)"); return next()
        }
        let start = viewPoint(CGPoint(x: node.x + node.width / 2, y: node.y + node.height / 2))
        let direction: CGFloat = run.isMultiple(of: 2) ? 1 : -1
        // Events go straight to the canvas's own handlers, like pan to the scroll view's: the trace then
        // does not depend on which app the window server considers active.
        guard let down = mouse(.leftMouseDown, at: start) else { return next() }
        canvas.mouseDown(with: down)
        var step = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.phase = "drag"
            Timer.scheduledTimer(withTimeInterval: Self.inputInterval, repeats: true) { timer in
                step += 1
                let point = CGPoint(x: start.x + direction * CGFloat(step), y: start.y + direction * CGFloat(step) / 2)
                if step <= Self.steps, let event = self.mouse(.leftMouseDragged, at: point) {
                    self.record(phase: "drag"); self.canvas.mouseDragged(with: event); return
                }
                timer.invalidate()
                if let up = self.mouse(.leftMouseUp, at: point) { self.canvas.mouseUp(with: up) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.phase = "idle"; next() }
            }
        }
    }

    private func pan(run: Int, then next: @escaping () -> Void) {
        canvas.setZoom(fitZoom * 2.5)
        centerOnShapes()
        window.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.panTrace(run: run, then: next) }
    }

    private func panTrace(run: Int, then next: @escaping () -> Void) {
        let clip = editor.scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [probe] _ in
            probe.inputHandled()
        }
        let before = clip.bounds.origin
        let direction: Int32 = run.isMultiple(of: 2) ? -1 : 1
        var step = 0
        phase = "pan"
        Timer.scheduledTimer(withTimeInterval: Self.inputInterval, repeats: true) { timer in
            step += 1
            // Pixel scroll events go to the editor scroll view's own handler: a synthetic CGEvent cannot carry
            // the window-server pointer routing, but scrolling, clip-view copying and exposure redraws are real.
            if step <= Self.steps,
               let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: direction * 3, wheel2: direction * 2, wheel3: 0),
               let event = { () -> NSEvent? in
                   // A trackpad's continuous pixel deltas scroll directly; without this flag AppKit animates each step.
                   cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                   return NSEvent(cgEvent: cg)
               }() {
                self.record(phase: "pan")
                self.probe.inputStarted()
                self.editor.scrollView.scrollWheel(with: event)
                return
            }
            timer.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NotificationCenter.default.removeObserver(observer)
                if clip.bounds.origin == before { self.errors.append("Pan run \(run) did not move the viewport") }
                self.phase = "idle"; next()
            }
        }
    }

    private func record(phase: String) {
        posted.append(CACurrentMediaTime()); feedback.append(nil); phaseOf.append(phase)
        phaseIndexOf.append(postedIndex[phase, default: 0]); postedIndex[phase, default: 0] += 1
    }

    // MARK: Frames

    @objc private func tick(_ link: CADisplayLink) {
        let target = link.targetTimestamp
        // A presented frame carries new content when the canvas drew or the viewport moved (scrolling
        // shifts already-drawn content without a canvas draw).
        let draws = probe.drawDurations.count, origin = editor.scrollView.contentView.bounds.origin
        if draws != drawsAtLastTick || origin != originAtLastTick, phase != "idle" { frames.append((phase, target)) }
        drawsAtLastTick = draws; originAtLastTick = origin
        guard !canvas.needsDisplay else { return }
        for index in feedback.indices where feedback[index] == nil {
            guard let handled = probe.handled[phaseOf[index]], phaseIndexOf[index] < handled.count else { continue }
            let handledAt = handled[phaseIndexOf[index]]
            if phaseOf[index] == "pan" || probe.lastDrawEnd >= handledAt { feedback[index] = target - posted[index] }
        }
    }

    // MARK: Report

    private func finish() {
        link?.invalidate(); DragPanProbe.active = nil
        func stats(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return ["count": 0] }
            func q(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded()))] * 1000 }
            return ["count": sorted.count, "p50Ms": q(0.5), "p95Ms": q(0.95), "maxMs": sorted.last! * 1000]
        }
        var phases: [String: Any] = [:]
        var passed = errors.isEmpty
        for name in ["drag", "pan"] {
            let latencies = feedback.indices.filter { phaseOf[$0] == name }.compactMap { feedback[$0] }
            let missing = feedback.indices.filter { phaseOf[$0] == name && feedback[$0] == nil }.count
            let times = frames.filter { $0.phase == name }.map(\.time)
            let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 < 1 }
            let latency = stats(latencies), frame = stats(intervals)
            let ok = missing == 0 && (latency["p95Ms"] as? Double ?? .infinity) <= 50 && (frame["p95Ms"] as? Double ?? .infinity) <= 33
            passed = passed && ok
            phases[name] = ["frameIntervalsMs": intervals.map { ($0 * 1000).rounded() }, "inputToFeedback": latency, "frameInterval": frame, "inputsWithoutFeedback": missing, "passed": ok,
                            "inputHandling": stats(probe.handlingDurations[name] ?? []),
                            "dirtyPercentOfViewport": stats((probe.dirtyAreas[name] ?? []).map { $0 / 10 }), "canvasDraw": stats(probe.phaseDrawDurations[name] ?? [])]
        }
        var size = 0; sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size); sysctlbyname("hw.model", &model, &size, nil, 0)
        let report: [String: Any] = [
            "requirement": "MV-NFR-02", "targets": ["inputToFeedbackP95Ms": 50, "frameTimeP95Ms": 33],
            "trace": "\(Self.runs) runs x (\(Self.steps)-step single-shape drag through the canvas mouse handlers at fit-page zoom with every shape visible + \(Self.steps)-step pixel pan through the editor scroll view at 2.5x fit zoom) at 120 Hz (trackpad rate)",
            "nodesOnActivePage": document.diagram.page.nodes.count, "edgesOnActivePage": document.diagram.page.edges.count,
            "phases": phases, "drawDurations": stats(probe.drawDurations), "errors": errors, "passed": passed,
            "host": ["model": String(cString: model), "os": ProcessInfo.processInfo.operatingSystemVersionString,
                     "processors": ProcessInfo.processInfo.activeProcessorCount,
                     "maximumFramesPerSecond": window.screen?.maximumFramesPerSecond ?? 0],
            "inputSaved": false, "phasesRun": ProcessInfo.processInfo.environment["MACVISIO_TRACE_PHASES"] ?? "drag,pan",
            "geometry": ["window": NSStringFromRect(window.frame), "windowVisible": window.isVisible,
                         "occlusionVisible": window.occlusionState.contains(.visible), "canvasBounds": NSStringFromRect(canvas.bounds),
                         "canvasVisible": NSStringFromRect(canvas.visibleRect), "preparedContent": NSStringFromRect(canvas.preparedContentRect), "zoom": canvas.zoom, "pageFrame": NSStringFromRect(canvas.pageFrame),
                         "firstNode": document.diagram.page.nodes.first.map { "\($0.x),\($0.y) \($0.width)x\($0.height)" } ?? "none",
                         "isKey": window.isKeyWindow, "appActive": NSApp.isActive],
        ]
        document.updateChangeCount(.changeCleared)
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output, options: .atomic); print(String(decoding: data, as: UTF8.self))
        } catch { fputs("Drag/pan report failed: \(error.localizedDescription)\n", stderr); exit(1) }
        exit(passed ? 0 : 1)
    }
}
