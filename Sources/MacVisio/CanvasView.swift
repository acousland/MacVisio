import AppKit
import QuartzCore

enum CanvasTool: Int { case pointer, connector, text, line }

final class InlineTextView: NSTextView {
    var finish: ((Bool) -> Void)?
    private let textUndo = UndoManager()
    override var undoManager: UndoManager? { textUndo }
    // NSTextView does not handle these standard menu selectors itself. Keep
    // them in this input session, including when its history is exhausted.
    @objc func undo(_ sender: Any?) { textUndo.undo() }
    @objc func redo(_ sender: Any?) { textUndo.redo() }
    func applyFormatting(_ value: NSAttributedString) {
        let old = NSAttributedString(attributedString: attributedString())
        undoManager?.registerUndo(withTarget: self) { $0.applyFormatting(old) }
        textStorage?.setAttributedString(value)
        didChangeText()
    }
    override func keyDown(with event: NSEvent) {
        let evidence = PerformanceEvidence.begin(.event)
        defer { PerformanceEvidence.end(evidence) }
        if event.keyCode == 53 {
            finishFromKeyboard(commit: false)
            return
        }
        if event.keyCode == 36 && event.modifierFlags.contains(.command) {
            finishFromKeyboard(commit: true)
            return
        }
        super.keyDown(with: event)
    }
    private func finishFromKeyboard(commit: Bool) {
        // The finish callback removes this text view. Preserve the explicit
        // keyboard destination before removal, without overriding a normal
        // resignFirstResponder transition to an inspector or another field.
        let hostWindow = window
        let canvas = superview as? CanvasView
        finish?(commit)
        if let canvas, canvas.editor != nil, canvas.window === hostWindow {
            hostWindow?.makeFirstResponder(canvas)
        }
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { finish?(true) }
        return result
    }
}

final class CanvasView: NSView {
    weak var editor: EditorWindowController?
    lazy var accessibilityGraph = CanvasAccessibility(canvas: self)
    var keyboardFocusedObject: CanvasObjectKey?
    var document: MacVisioDocument { editor!.diagramDocument }
    /// Geometry previews are view state. Persistence always reads document.diagram.
    private(set) var interactionPreview: Diagram? {
        didSet {
            guard let preview = interactionPreview, let committed = editor?.retainedScene else {
                previewScene = nil
                return
            }
            previewScene = RetainedRenderScene(
                previewPage: preview.page, baseline: committed.snapshot, previous: previewScene)
        }
    }
    private var previewScene: RetainedRenderScene?
    var renderScene: RetainedRenderScene {
        applyPendingDrag()
        return previewStateID == document.stateID ? (previewScene ?? editor!.retainedScene) : editor!.retainedScene
    }
    private var previewStateID: UUID?
    /// Reading the preview first applies any coalesced drag position, so callers always see current state.
    var displayedDiagram: Diagram {
        applyPendingDrag()
        return previewStateID == document.stateID ? (interactionPreview ?? document.diagram) : document.diagram
    }
    var page: DiagramPage { displayedDiagram.page }
    private func beginGesturePreview() {
        beforeDrag = document.diagram
        previewStateID = document.stateID
        interactionPreview = document.diagram
    }
    private func commitGesturePreview() -> String? {
        let current = previewStateID == document.stateID
        let next = current ? interactionPreview : nil
        let control = current ? controlDrag : nil
        let baseline = controlBaseline
        let point = controlPreviewPoint
        controlPreviewPoint = nil
        interactionPreview = nil
        previewStateID = nil
        if let (id, name) = control, let baseline, let point {
            document.adjustControlInEditor(baseline: baseline, node: id, control: name, to: point)
        } else if let next {
            if let reason = gestureBlockReason(next) { return reason }
            document.replaceInEditor(with: next, action: resizeHandle == nil ? "Move Shapes" : "Resize Shape")
        }
        return nil
    }
    /// Pointer previews stay presentation-only. Validate the complete proposed
    /// transform at release, including protected descendants and group edges,
    /// before calculation or undo registration can change committed state.
    private func gestureBlockReason(_ next: Diagram) -> String? {
        guard let before = beforeDrag, let runtime = editor?.retainedScene.foreground.runtime,
            runtime.pageID == before.page.id, next.page.id == before.page.id
        else { return "The drawing changed. Start the gesture again." }
        let ids = Set(originalRects.keys)
        let roots = ids.filter { id in
            var parent = runtime.parentByID[id]
            for _ in 0..<64 {
                guard let current = parent else { return true }
                if ids.contains(current) { return false }
                parent = runtime.parentByID[current]
            }
            return false
        }.sorted { runtime.nodeIndexByID[$0, default: 0] < runtime.nodeIndexByID[$1, default: 0] }
        func proposed(_ id: UUID) -> DiagramNode? {
            guard let index = runtime.nodeIndexByID[id], next.page.nodes.indices.contains(index),
                next.page.nodes[index].id == id else { return nil }
            return next.page.nodes[index]
        }
        for id in roots {
            guard let old = runtime.nodesByID[id], let new = proposed(id) else {
                return "The selected shape changed. Start the gesture again."
            }
            let keys = [("X", old.x != new.x), ("Y", old.y != new.y),
                        ("Width", old.width != new.width), ("Height", old.height != new.height)]
                .filter { $0.1 }.map { $0.0 }
            guard !keys.isEmpty else { continue }
            let affected = runtime.descendants(of: id).sorted {
                runtime.nodeIndexByID[$0, default: 0] < runtime.nodeIndexByID[$1, default: 0]
            }
            for member in affected {
                guard let previous = runtime.nodesByID[member], let changed = proposed(member) else {
                    return "A group member changed. Start the gesture again."
                }
                let prefix = member == id ? "" : "A group member prevents this transform: "
                for key in keys {
                    if let reason = NativeEditProtection.blockReason(for: key, node: previous, in: before.page) {
                        return prefix + reason
                    }
                }
                if let reason = NativeEditProtection.blockReason(changing: previous, to: changed, in: before.page) {
                    return prefix + reason
                }
                if (runtime.edgesByParent[member] ?? []).contains(where: { runtime.isLocked(edgeID: $0) }) {
                    return "A group connector or its layer is locked."
                }
            }
        }
        return nil
    }
    private var cachedGridTile: (key: [Double], image: CGImage)?
    /// A 10x10 block of grid dots, centred in step-sized cells, rendered at the current device scale.
    private func gridTile(step: Double) -> CGImage? {
        let scale = coordinateZoom * (window?.backingScaleFactor ?? 2)
        let key = [step, scale]
        if let cachedGridTile, cachedGridTile.key == key { return cachedGridTile.image }
        let pixels = Int((step * 10 * scale).rounded())
        guard pixels > 0, pixels <= 4096,
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let cell = Double(pixels) / 10, dot = 1.3 / page.paperScale * scale
        context.setFillColor(NSColor(hex: "#DCE4EF").cgColor)
        for i in 0..<10 { for j in 0..<10 {
            context.fillEllipse(in: CGRect(x: (Double(i) + 0.5) * cell - dot / 2, y: (Double(j) + 0.5) * cell - dot / 2, width: dot, height: dot))
        } }
        guard let image = context.makeImage() else { return nil }
        cachedGridTile = (key, image)
        return image
    }
    var selectedNodes = Set<UUID>()
    var selectedEdge: UUID?
    /// View area invalidated by the previous move/resize preview step, so the next step also clears it.
    private var lastDragDamage: CGRect?
    /// View-space area a move or resize preview step can change: the moved shapes (with text overflow,
    /// shadows and selection handles), every connector whose route differs from the committed scene,
    /// and connectors attached to or grouped with the moved shapes, including their labels.
    private func dragDamage(moving ids: Set<UUID>) -> CGRect {
        var area = CGRect.null
        for node in page.nodes where ids.contains(node.id) {
            let rect = node.rect
            if node.rotation == 0 { area = area.union(rect) } else {
                let radius = hypot(rect.width, rect.height) / 2
                area = area.union(CGRect(x: rect.midX - radius, y: rect.midY - radius, width: radius * 2, height: radius * 2))
            }
        }
        let preview = renderScene.foreground.routeBounds
        let committed = editor?.retainedScene.foreground.routeBounds ?? [:]
        let labelMargin = CGSize(width: 80 / page.paperScale, height: 30 / page.paperScale)
        for edge in page.edges {
            let attached = ids.contains(edge.source) || ids.contains(edge.target) || edge.parentID.map(ids.contains) == true
            let before = committed[edge.id], after = preview[edge.id]
            guard attached || before != after else { continue }
            for bounds in [before, after].compactMap({ $0 }) {
                area = area.union(bounds.insetBy(dx: -labelMargin.width, dy: -labelMargin.height))
            }
        }
        guard !area.isNull else { return visibleRect }
        let margin = 24 / coordinateZoom
        let pageArea = area.insetBy(dx: -margin, dy: -margin)
        let origin = pageOrigin
        return CGRect(x: origin.x + pageArea.minX * coordinateZoom, y: origin.y + pageArea.minY * coordinateZoom,
                      width: pageArea.width * coordinateZoom, height: pageArea.height * coordinateZoom)
    }
    var tool: CanvasTool = .pointer {
        didSet {
            pendingSource = nil
            pendingSourcePort = nil
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }
    var zoom: Double = 0.85
    var coordinateZoom: Double { zoom * document.diagram.page.paperScale }
    var showsGrid = true
    var snapsToGrid = true
    var pendingSource: UUID?
    var pendingSourcePort: String?
    func connectionPoint(at point: CGPoint, on node: DiagramNode) -> ShapeConnectionPoint? {
        node.formatting.connectionPoints.filter { $0.type != 1 }.map {
            ($0, renderScene.foreground.connectionPoints[node.id]?[$0.id] ?? node.center)
        }.filter { hypot($0.1.x - point.x, $0.1.y - point.y) < 10 / coordinateZoom }.min {
            hypot($0.1.x - point.x, $0.1.y - point.y) < hypot($1.1.x - point.x, $1.1.y - point.y)
        }?.0
    }
    private var pointer = CGPoint.zero
    private var lineStart: CGPoint?
    private var dragStart: CGPoint?
    private var beforeDrag: Diagram?
    private var originalRects: [UUID: CGRect] = [:]
    private var resizeHandle: Int?
    private var controlDrag: (UUID, String)?
    private var controlBaseline: ControlEditing.Baseline?
    private(set) var controlPreviewPoint: CGPoint?
    private var controlDragError: Error?
    private var controlToolTips: [NSView.ToolTipTag: String] = [:]
    private var marquee: CGRect?
    private var baseSelection = Set<UUID>()
    private var inline: InlineTextView?
    private var editingID: UUID?
    private var finishingText = false
    static let shapePasteboardType = NSPasteboard.PasteboardType("com.macvisio.shape-kind")
    static let stencilPasteboardType = NSPasteboard.PasteboardType("com.macvisio.stencil-master")
    static let fragmentPasteboardType = NSPasteboard.PasteboardType("com.macvisio.fragment")
    override var isFlipped: Bool { true }
    // draw(_:) fills its whole dirty area with the workspace colour first, so the canvas is opaque.
    override var isOpaque: Bool { true }

    // MARK: Tiled display
    // On screen the canvas shows its content through tile layers rendered by draw(_:), so scrolling
    // moves already-rendered pixels and edits redraw only the invalidated parts of tiles. Snapshot
    // drawing (cacheDisplay, export previews) still calls draw(_:) directly.
    private let tileView = CanvasTileView(frame: .zero)
    private let tiles = CanvasTileCache()
    private var scrollObserver: NSObjectProtocol?
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = EditorPalette.workspace.cgColor
        applyPendingDrag()
        updateTiles()
    }
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        tiles.invalidate(invalidRect)
        super.setNeedsDisplay(invalidRect)
    }
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { tiles.invalidate(bounds) }
            super.needsDisplay = newValue
        }
    }
    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size { tiles.removeAll() }
        super.setFrameSize(newSize)
        tileView.frame = bounds
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        tiles.removeAll()
        needsDisplay = true
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
        ) { [weak self] _ in MainActor.assumeIsolated { self?.updateTiles() } }
    }
    private func updateTiles() {
        guard let window, editor != nil else { return }
        tiles.update(visible: visibleRect, bounds: bounds, scale: window.backingScaleFactor,
                     colorSpace: window.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                     host: tileView.tileLayer) { draw($0) }
    }
    override var acceptsFirstResponder: Bool { true }
    // Page size and paper scale never change during a shape gesture, so viewport geometry reads the
    // committed page and does not force a coalesced drag preview to be built.
    private var geometryPage: DiagramPage { document.diagram.page }
    var pageOrigin: CGPoint { CGPoint(x: max(44, (bounds.width - geometryPage.width * coordinateZoom) / 2), y: 36) }
    var pageFrame: CGRect {
        CGRect(
            x: pageOrigin.x, y: pageOrigin.y, width: page.width * coordinateZoom,
            height: page.height * coordinateZoom)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(tileView, positioned: .below, relativeTo: nil)
        registerForDraggedTypes([Self.shapePasteboardType, Self.stencilPasteboardType])
        setAccessibilityIdentifier("diagramCanvas")
        setAccessibilityLabel("Diagram canvas")
        setAccessibilityRole(.layoutArea)
        setAccessibilityElement(true)
        setAccessibilityHelp(
            "Option-Tab enters drawing objects. Arrows move; Option-arrows resize. Return edits text. C starts a connection. Tab moves to the next control; Shift-Tab moves to the previous control."
        )
    }
    required init?(coder: NSCoder) { fatalError() }
    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = accessibilityGraph.elements()
        children += subviews.filter { $0 is InlineTextView }
        return children
    }
    override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityGraph.elements().filter { $0.isAccessibilitySelected() }
    }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        if let inline, inline.accessibilityFrame().contains(point) {
            return inline.accessibilityHitTest(point)
        }
        if let element = accessibilityGraph.elements().reversed().first(where: {
            $0.accessibilityFrame().contains(point)
        }) {
            return element
        }
        return self
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        needsDisplay = true
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        needsDisplay = true
        return result
    }
    func detachEditor() {
        finishEditing(commit: false)
        pendingDragPoint = nil
        interactionPreview = nil
        previewStateID = nil
        beforeDrag = nil
        controlBaseline = nil
        controlDrag = nil
        controlPreviewPoint = nil
        controlDragError = nil
        dragStart = nil
        lineStart = nil
        resizeHandle = nil
        marquee = nil
        originalRects = [:]
        selectedNodes = []
        selectedEdge = nil
        pendingSource = nil
        pendingSourcePort = nil
        keyboardFocusedObject = nil
        removeAllToolTips()
        controlToolTips = [:]
        editor = nil
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    func refreshSize() {
        guard editor != nil else { return }
        let size = enclosingScrollView?.contentSize ?? .zero
        frame.size = CGSize(
            width: max(size.width, page.paperWidth * zoom + 88),
            height: max(size.height, page.paperHeight * zoom + 72))
        updateControlToolTips()
        needsDisplay = true
    }
    func setZoom(_ value: Double) {
        finishEditing(commit: true)
        let center = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        let oldOrigin = pageOrigin
        let modelCenter = CGPoint(
            x: (center.x - oldOrigin.x) / coordinateZoom, y: (center.y - oldOrigin.y) / coordinateZoom)
        zoom = max(0.2, min(3, value))
        refreshSize()
        scroll(
            CGPoint(
                x: max(0, pageOrigin.x + modelCenter.x * coordinateZoom - visibleRect.width / 2),
                y: max(0, pageOrigin.y + modelCenter.y * coordinateZoom - visibleRect.height / 2)))
        document.present(.viewportChanged(pageID: page.id, zoom: zoom, scrollOrigin: visibleRect.origin))
        editor?.updateStatus()
    }
    func fitPage() {
        guard let scrollView = enclosingScrollView else { return }
        // Fitting can hide legacy scrollers and enlarge the viewport. Refit
        // against that settled size instead of retaining the smaller old fit.
        for _ in 0..<3 {
            scrollView.tile()
            let size = scrollView.contentSize
            guard size.width > 0, size.height > 0 else { return }
            setZoom(min((size.width - 88) / page.paperWidth, (size.height - 72) / page.paperHeight))
            scrollView.tile()
            if scrollView.contentSize == size { break }
        }
        scroll(.zero)
    }
    func select(_ ids: Set<UUID>, edge: UUID? = nil) {
        selectedNodes = ids
        selectedEdge = edge
        if let focus = keyboardFocusedObject {
            switch focus.element {
            case .node(let id): if !ids.contains(id) { keyboardFocusedObject = nil }
            case .edge(let id): if edge != id { keyboardFocusedObject = nil }
            }
        }
        updateControlToolTips()
        needsDisplay = true
        editor?.selectionChanged()
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }
    func controlTip(at point: CGPoint) -> String? {
        guard selectedNodes.count == 1, let node = page.nodes.first(where: { selectedNodes.contains($0.id) }),
            !page.isLocked(node),
            let control = node.formatting.controls.first(where: {
                $0.visible
                    && hypot(
                        ControlGeometry.point($0, on: node).x - point.x,
                        ControlGeometry.point($0, on: node).y - point.y) < 9 / coordinateZoom
            })
        else { return nil }
        return control.cell("Tip")?.value ?? control.name
    }
    private func updateControlToolTips() {
        removeAllToolTips()
        controlToolTips = [:]
        guard editor != nil, selectedNodes.count == 1,
            let node = page.nodes.first(where: { selectedNodes.contains($0.id) }), !page.isLocked(node)
        else { return }
        for control in node.formatting.controls where control.visible {
            let p = ControlGeometry.point(control, on: node)
            let r = CGRect(
                x: pageOrigin.x + p.x * coordinateZoom - 9, y: pageOrigin.y + p.y * coordinateZoom - 9,
                width: 18, height: 18)
            let tag = addToolTip(r, owner: self, userData: nil)
            controlToolTips[tag] = control.cell("Tip")?.value ?? control.name
        }
    }
    @objc func view(
        _ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
        userData: UnsafeMutableRawPointer?
    ) -> String { controlToolTips[tag] ?? "" }
    func pointInPage(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        // The committed page has the same paper scale as any preview; reading it keeps drag coalescing.
        let paperScale = document.diagram.page.paperScale
        return ViewportCoordinates(pageOrigin: pageOrigin, paperScale: paperScale, zoom: zoom).drawing(
            CanvasLocation(point: p)
        ).point
    }
    func node(at point: CGPoint, includeLocked: Bool = true) -> DiagramNode? {
        guard editor != nil else { return nil }
        return renderScene.foreground.runtime.nodeCandidates(
            at: point, tolerance: 5 / coordinateZoom, includeLocked: includeLocked
        ).values.first { n in
            if !page.isVisible(n) { return false }
            if !includeLocked && page.isLocked(n) { return false }
            if n.kind == .swimlane && n.locked && point.x > n.x + min(110, n.width * 0.25) { return false }
            let radians = -n.rotation * .pi / 180
            let dx = point.x - n.center.x
            let dy = point.y - n.center.y
            let p = CGPoint(
                x: n.center.x + dx * cos(radians) - dy * sin(radians),
                y: n.center.y + dx * sin(radians) + dy * cos(radians))
            if n.kind == .text { return n.rect.contains(p) }
            if n.kind == .person { return n.rect.insetBy(dx: -5, dy: -5).contains(p) }
            var local = p
            if n.formatting.flipX { local.x = 2 * n.center.x - local.x }
            if n.formatting.flipY { local.y = 2 * n.center.y - local.y }
            let path = DiagramDrawing.outline(for: n)
            return path.contains(local)
                || ((!n.formatting.paths.isEmpty && n.formatting.paths.allSatisfy { !$0.fill })
                    && path.bounds.insetBy(dx: -5 / coordinateZoom, dy: -5 / coordinateZoom).contains(local))
        }
    }
    func edge(at p: CGPoint, includeLocked: Bool = true) -> DiagramEdge? {
        guard editor != nil else { return nil }
        return renderScene.foreground.runtime.edgeCandidates(
            intersecting: CGRect(
                x: p.x - 7 / coordinateZoom, y: p.y - 7 / coordinateZoom, width: 14 / coordinateZoom,
                height: 14 / coordinateZoom), includeLocked: includeLocked
        ).values.first { e in
            guard page.isVisible(e), includeLocked || !page.isLocked(e) else { return false }
            let route = renderScene.foreground.routes[e.id] ?? []
            return zip(route, route.dropFirst()).contains {
                DiagramGeometry.distance(p, to: $0.0, $0.1) < 7 / coordinateZoom
            }
        }
    }
    func handles(for n: DiagramNode) -> [CGPoint] {
        let r = n.rect
        return [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.maxX, y: r.midY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY),
        ]
    }
    override func draw(_ dirtyRect: NSRect) {
        let evidence = PerformanceEvidence.begin(.draw)
        let probeStart = DragPanProbe.active == nil ? 0 : CACurrentMediaTime()
        DragPanProbe.active?.dirty(dirtyRect, visible: visibleRect)
        defer {
            PerformanceEvidence.end(evidence)
            DragPanProbe.active?.drew(since: probeStart)
        }
        guard editor != nil else { return }
        EditorPalette.workspace.setFill()
        bounds.fill()
        let paper = pageFrame
        // The paper's blurred shadow only shows around its edges; blurring it for a dirty area wholly
        // inside the paper (most scroll and drag redraws) costs a full-area blur for nothing.
        if paper.insetBy(dx: 1, dy: 1).contains(dirtyRect) {
            NSColor.white.setFill()
            paper.intersection(dirtyRect).fill()
        } else {
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor(hex: "#263953").withAlphaComponent(0.15)
            shadow.shadowBlurRadius = 16
            shadow.shadowOffset = NSSize(width: 0, height: 2)
            shadow.set()
            NSColor.white.setFill()
            paper.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        // Ruler remains outside the drawing and is never included in exports.
        let rulerFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let rulerAttrs: [NSAttributedString.Key: Any] = [
            .font: rulerFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let verticalRulerStyle = NSMutableParagraphStyle()
        verticalRulerStyle.alignment = .right
        let verticalRulerAttrs: [NSAttributedString.Key: Any] = [
            .font: rulerFont, .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: verticalRulerStyle,
        ]
        let tickStep = 20 / page.paperScale
        let pixelStep = tickStep * coordinateZoom
        let topBand = CGRect(x: paper.minX, y: paper.minY - 31, width: paper.width, height: 31)
        let visibleTop = dirtyRect.intersection(topBand)
        if !visibleTop.isNull, pixelStep > 0 {
            // Restrict iteration to ticks intersecting this draw pass. Large pages
            // should not make a small invalidation walk every ruler division.
            let first = max(0, ceil((visibleTop.minX - paper.minX - 48) / pixelStep))
            let last = min(floor(page.width / tickStep), floor((visibleTop.maxX - paper.minX) / pixelStep))
            let ruler = NSBezierPath()
            if first <= last {
                var index = first
                while index <= last {
                    let x = index * tickStep
                    let px = paper.minX + x * coordinateZoom
                    let major = index.truncatingRemainder(dividingBy: 5) == 0
                    ruler.move(to: CGPoint(x: px, y: paper.minY - 5))
                    ruler.line(to: CGPoint(x: px, y: paper.minY - (major ? 12 : 8)))
                    if major {
                        ("\(Int(x))" as NSString).draw(
                            at: CGPoint(x: px + 3, y: paper.minY - 26), withAttributes: rulerAttrs)
                    }
                    index += 1
                }
            }
            EditorPalette.ruler.setStroke()
            ruler.lineWidth = 0.5
            ruler.stroke()
        }
        let leftBand = CGRect(x: paper.minX - 43, y: paper.minY, width: 43, height: paper.height)
        let visibleLeft = dirtyRect.intersection(leftBand)
        if !visibleLeft.isNull, pixelStep > 0 {
            let first = max(0, ceil((visibleLeft.minY - paper.minY - 6) / pixelStep))
            let last = min(floor(page.height / tickStep), floor((visibleLeft.maxY - paper.minY) / pixelStep))
            let ruler = NSBezierPath()
            if first <= last {
                var index = first
                while index <= last {
                    let y = index * tickStep
                    let py = paper.minY + y * coordinateZoom
                    let major = index.truncatingRemainder(dividingBy: 5) == 0
                    ruler.move(to: CGPoint(x: paper.minX - 5, y: py))
                    ruler.line(to: CGPoint(x: paper.minX - (major ? 12 : 8), y: py))
                    if major {
                        ("\(Int(y))" as NSString).draw(
                            in: CGRect(x: paper.minX - 39, y: py - 6, width: 29, height: 12),
                            withAttributes: verticalRulerAttrs)
                    }
                    index += 1
                }
            }
            EditorPalette.ruler.setStroke()
            ruler.lineWidth = 0.5
            ruler.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: paper.minX, yBy: paper.minY)
        transform.scale(by: coordinateZoom)
        transform.concat()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: page.width, height: page.height)).addClip()
        let retained = renderScene
        let scene = retained.scene
        let dirty = CGRect(
            x: (dirtyRect.minX - paper.minX) / coordinateZoom,
            y: (dirtyRect.minY - paper.minY) / coordinateZoom, width: dirtyRect.width / coordinateZoom,
            height: dirtyRect.height / coordinateZoom)
        for layer in retained.layers.dropLast() {
            let background = layer.page
            NSGraphicsContext.saveGraphicsState()
            let offset = scene.offset(for: background)
            let t = NSAffineTransform()
            t.translateX(by: offset.x / page.paperScale, yBy: offset.y / page.paperScale)
            t.scale(by: background.paperScale / page.paperScale)
            t.concat()
            let region = CGRect(
                x: (dirty.minX * page.paperScale - offset.x) / background.paperScale,
                y: (dirty.minY * page.paperScale - offset.y) / background.paperScale,
                width: dirty.width * page.paperScale / background.paperScale,
                height: dirty.height * page.paperScale / background.paperScale)
            layer.draw(in: region, printing: false)
            NSGraphicsContext.restoreGraphicsState()
        }
        if showsGrid {
            NSColor(hex: "#DCE4EF").setFill()
            let clip = CGRect(
                x: max(0, (dirtyRect.minX - paper.minX) / coordinateZoom),
                y: max(0, (dirtyRect.minY - paper.minY) / coordinateZoom),
                width: dirtyRect.width / coordinateZoom + 40, height: dirtyRect.height / coordinateZoom + 40)
            // Stamp a cached 10x10-dot tile instead of filling every dot: thousands of dots per
            // exposure made grid drawing dominate scrolling.
            let step = 20 / page.paperScale, tile = step * 10
            if let image = gridTile(step: step), let context = NSGraphicsContext.current?.cgContext {
                for x in stride(from: floor(clip.minX / tile) * tile, through: min(page.width, clip.maxX), by: tile) {
                    for y in stride(from: floor(clip.minY / tile) * tile, through: min(page.height, clip.maxY), by: tile) {
                        context.draw(image, in: CGRect(x: x - step / 2, y: y - step / 2, width: tile, height: tile))
                    }
                }
            }
        }
        retained.foreground.draw(in: dirty, printing: false, selectedEdge: selectedEdge, shadow: true)
        if tool == .connector {
            for node in retained.foreground.runtime.nodes(
                intersecting: dirty.insetBy(dx: -5 / coordinateZoom, dy: -5 / coordinateZoom),
                includeLocked: false
            ).values where page.permitsGlue(to: node) {
                for port in node.formatting.connectionPoints {
                    let p = retained.foreground.connectionPoints[node.id]?[port.id] ?? node.center
                    let mark = NSBezierPath(
                        ovalIn: CGRect(
                            x: p.x - 3 / coordinateZoom, y: p.y - 3 / coordinateZoom,
                            width: 6 / coordinateZoom, height: 6 / coordinateZoom))
                    NSColor.white.setFill()
                    mark.fill()
                    NSColor.controlAccentColor.setStroke()
                    mark.lineWidth = 1 / coordinateZoom
                    mark.stroke()
                }
            }
        }
        if let source = pendingSource, let n = retained.foreground.runtime.nodesByID[source] {
            let destination: CGPoint
            if let focus = keyboardFocusedObject, case .node(let target) = focus.element,
                target != source, let node = retained.foreground.runtime.nodesByID[target]
            {
                destination = node.center
            } else {
                destination = pointer
            }
            let p = NSBezierPath()
            p.move(
                to: pendingSourcePort.flatMap { retained.foreground.connectionPoints[n.id]?[$0] }
                    ?? DiagramGeometry.boundary(of: n, toward: destination))
            p.line(to: destination)
            p.setLineDash([5, 4], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            p.lineWidth = 2 / coordinateZoom
            p.stroke()
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            DiagramDrawing.path(for: n.kind, in: n.rect.insetBy(dx: -4, dy: -4)).fill()
        }
        if window?.firstResponder === self, let key = keyboardFocusedObject,
            let bounds = accessibilityGraph.drawingBounds(key), key.pageID == page.id
        {
            let focus = NSBezierPath(
                roundedRect: bounds.insetBy(dx: -7 / coordinateZoom, dy: -7 / coordinateZoom),
                xRadius: 4 / coordinateZoom, yRadius: 4 / coordinateZoom)
            NSColor.keyboardFocusIndicatorColor.setStroke()
            focus.lineWidth = 3 / coordinateZoom
            focus.stroke()
        }
        if let start = lineStart {
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: pointer)
            NSColor.controlAccentColor.setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        for n in retained.foreground.runtime.nodes(
            intersecting: dirty.insetBy(dx: -12 / coordinateZoom, dy: -12 / coordinateZoom)
        ).values where selectedNodes.contains(n.id) {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: n.rect.insetBy(dx: -3 / coordinateZoom, dy: -3 / coordinateZoom))
            outline.lineWidth = 1.2 / coordinateZoom
            if n.locked { outline.setLineDash([4 / coordinateZoom, 3 / coordinateZoom], count: 2, phase: 0) }
            outline.stroke()
            if !n.locked && selectedNodes.count == 1 && n.rotation == 0 {
                for p in handles(for: n) {
                    let box = NSBezierPath(
                        roundedRect: CGRect(
                            x: p.x - 4 / coordinateZoom, y: p.y - 4 / coordinateZoom,
                            width: 8 / coordinateZoom, height: 8 / coordinateZoom),
                        xRadius: 1 / coordinateZoom, yRadius: 1 / coordinateZoom)
                    NSColor.white.setFill()
                    box.fill()
                    NSColor.controlAccentColor.setStroke()
                    box.lineWidth = 1 / coordinateZoom
                    box.stroke()
                }
            }
            if selectedNodes.count == 1, !page.isLocked(n) {
                for control in n.formatting.controls where control.visible {
                    let p =
                        (controlDrag?.0 == n.id && controlDrag?.1 == control.name ? controlPreviewPoint : nil)
                        ?? ControlGeometry.point(control, on: n)
                    let r = 5 / coordinateZoom
                    let diamond = NSBezierPath()
                    diamond.move(to: CGPoint(x: p.x, y: p.y - r))
                    diamond.line(to: CGPoint(x: p.x + r, y: p.y))
                    diamond.line(to: CGPoint(x: p.x, y: p.y + r))
                    diamond.line(to: CGPoint(x: p.x - r, y: p.y))
                    diamond.close()
                    NSColor.systemYellow.setFill()
                    diamond.fill()
                    NSColor.brown.setStroke()
                    diamond.lineWidth = 1 / coordinateZoom
                    diamond.stroke()
                }
            }
        }
        if let marquee = marquee {
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
            marquee.fill()
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: marquee)
            p.lineWidth = 1 / coordinateZoom
            p.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .pointer ? .arrow : tool == .text ? .iBeam : .crosshair)
    }
    override func mouseDown(with event: NSEvent) {
        let evidence = PerformanceEvidence.begin(.event)
        defer { PerformanceEvidence.end(evidence) }
        finishEditing(commit: true)
        window?.makeFirstResponder(self)
        let p = pointInPage(event)
        pointer = p
        if tool == .pointer, selectedNodes.count == 1, let id = selectedNodes.first,
            let n = page.nodes.first(where: { $0.id == id }), page.isVisible(n), !page.isLocked(n),
            let control = n.formatting.controls.first(where: {
                $0.visible
                    && hypot(
                        ControlGeometry.point($0, on: n).x - p.x, ControlGeometry.point($0, on: n).y - p.y)
                        < 9 / coordinateZoom
            })
        {
            dragStart = p
            beginGesturePreview()
            controlBaseline = document.prepareControlGesture()
            controlDrag = (id, control.name)
            controlDragError = nil
            return
        }
        guard CGRect(x: 0, y: 0, width: page.width, height: page.height).contains(p) else {
            select([])
            return
        }
        if tool == .line {
            lineStart = p
            needsDisplay = true
            return
        }
        if tool == .text {
            editor?.insertShape(.text, at: p)
            if let id = selectedNodes.first { beginEditing(id) }
            return
        }
        if tool == .connector {
            let nearby = page.nodes.reversed().first {
                page.isVisible($0) && !page.isLocked($0) && page.permitsGlue(to: $0)
                    && connectionPoint(at: p, on: $0) != nil
            }
            guard let hit = nearby ?? node(at: p, includeLocked: false), hit.kind != .swimlane,
                page.permitsGlue(to: hit)
            else { return }
            let port = connectionPoint(at: p, on: hit)?.id
            if let source = pendingSource, source != hit.id || pendingSourcePort != port {
                editor?.connect(source, to: hit.id, sourcePort: pendingSourcePort, targetPort: port)
                pendingSource = nil
                pendingSourcePort = nil
            } else {
                pendingSource = hit.id
                pendingSourcePort = port
                select([hit.id])
            }
            needsDisplay = true
            editor?.updateStatus()
            return
        }
        if selectedNodes.count == 1, let id = selectedNodes.first,
            let n = page.nodes.first(where: { $0.id == id }), !page.isLocked(n), n.rotation == 0,
            let handle = handles(for: n).firstIndex(where: {
                hypot($0.x - p.x, $0.y - p.y) < 9 / coordinateZoom
            })
        {
            dragStart = p
            beginGesturePreview()
            originalRects = [id: n.rect]
            resizeHandle = handle
            return
        }
        let hitNode = node(at: p)
        let hitEdge = hitNode == nil || hitNode?.kind == .swimlane ? edge(at: p) : nil
        if var hit = hitNode, hitEdge == nil {
            if !event.modifierFlags.contains(.option) && event.clickCount != 2 {
                for _ in 0..<64 {
                    guard let parentID = hit.parentID,
                        let parent = page.nodes.first(where: { $0.id == parentID })
                    else { break }
                    hit = parent
                }
            }
            if event.clickCount == 2 {
                select([hit.id])
                beginEditing(hit.id)
                return
            }
            if event.modifierFlags.contains(.shift) {
                var ids = selectedNodes
                if ids.contains(hit.id) { ids.remove(hit.id) } else { ids.insert(hit.id) }
                select(ids)
            } else if !selectedNodes.contains(hit.id) {
                select([hit.id])
            }
            if !page.isLocked(hit) {
                dragStart = p
                beginGesturePreview()
                let ids = editor?.editableSelectionIDs ?? selectedNodes
                originalRects = Dictionary(
                    uniqueKeysWithValues: page.nodes.filter { ids.contains($0.id) }.map { ($0.id, $0.rect) })
            }
        } else if let edge = hitEdge {
            select([], edge: edge.id)
            if event.clickCount == 2 { editor?.editConnectorLabel() }
        } else {
            baseSelection = event.modifierFlags.contains(.shift) ? selectedNodes : []
            select(baseSelection)
            dragStart = p
            marquee = CGRect(origin: p, size: .zero)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        DragPanProbe.active?.inputStarted()
        let evidence = PerformanceEvidence.begin(.event)
        defer {
            PerformanceEvidence.end(evidence)
            DragPanProbe.active?.inputHandled()
        }
        let p = pointInPage(event)
        pointer = p
        if tool == .connector || tool == .line {
            needsDisplay = true
            return
        }
        guard let start = dragStart else { return }
        if marquee != nil {
            marquee = CGRect(
                x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x),
                height: abs(p.y - start.y))
            selectedNodes = baseSelection.union(
                document.runtime().nodes(intersecting: marquee!, includeLocked: false).values.map(\.id))
            needsDisplay = true
            editor?.selectionChanged()
            return
        }
        guard beforeDrag != nil else { return }
        if controlDrag != nil {
            // A handle is a presentation overlay during the gesture. Its
            // redirected formulas and geometry are solved once on release.
            controlPreviewPoint = p
            needsDisplay = true
            autoscroll(with: event)
            return
        }
        // Pointer devices deliver several drag events per display frame. Record only the latest
        // position here; the preview is rebuilt once per frame, just before tiles render.
        pendingDragPoint = (p, snapsToGrid && !event.modifierFlags.contains(.option))
        super.setNeedsDisplay(CGRect(x: visibleRect.minX, y: visibleRect.minY, width: 1, height: 1))
        autoscroll(with: event)
    }
    /// Latest unapplied move/resize position and whether grid snapping applies to it.
    private var pendingDragPoint: (point: CGPoint, snap: Bool)?
    private func applyPendingDrag() {
        guard let (p, snap) = pendingDragPoint else { return }
        pendingDragPoint = nil
        guard let start = dragStart, beforeDrag != nil else { return }
        var next = beforeDrag ?? document.diagram
        let group = originalRects.values.reduce(CGRect.null) { $0.union($1) }
        var movement: CGPoint?
        if resizeHandle == nil, !group.isNull {
            let dx = p.x - start.x
            let dy = p.y - start.y
            let anchor = originalRects.values.min { $0.minX < $1.minX } ?? group
            var moveX =
                snap
                ? DiagramGeometry.snapped(anchor.minX + dx, grid: 10 / page.paperScale) - anchor.minX : dx
            var moveY =
                snap
                ? DiagramGeometry.snapped(anchor.minY + dy, grid: 10 / page.paperScale) - anchor.minY : dy
            if snap {
                let selected = Set(originalRects.keys)
                let targets = document.runtime().snapCandidates(
                    near: group.offsetBy(dx: moveX, dy: moveY), excluding: selected,
                    tolerance: 6 / coordinateZoom
                ).values.map(ShapeSnapping.bounds(of:))
                let adjustment = ShapeSnapping.alignmentDelta(
                    moving: group.offsetBy(dx: moveX, dy: moveY), targets: targets,
                    tolerance: CGFloat(6 / coordinateZoom))
                moveX += adjustment.x
                moveY += adjustment.y
            }
            moveX = max(-group.minX, min(page.width - group.maxX, moveX))
            moveY = max(-group.minY, min(page.height - group.maxY, moveY))
            movement = CGPoint(x: moveX, y: moveY)
        }
        for i in next.page.nodes.indices {
            let id = next.page.nodes[i].id
            guard let r = originalRects[id] else { continue }
            if let handle = resizeHandle {
                var minX = r.minX
                var minY = r.minY
                var maxX = r.maxX
                var maxY = r.maxY
                var px = p.x
                var py = p.y
                if snap {
                    px = DiagramGeometry.snapped(px, grid: 10 / page.paperScale)
                    py = DiagramGeometry.snapped(py, grid: 10 / page.paperScale)
                }
                if [0, 6, 7].contains(handle) { minX = min(px, maxX - 30) }
                if [2, 3, 4].contains(handle) { maxX = max(px, minX + 30) }
                if [0, 1, 2].contains(handle) { minY = min(py, maxY - 24) }
                if [4, 5, 6].contains(handle) { maxY = max(py, minY + 24) }
                next.page.nodes[i].x = max(0, minX)
                next.page.nodes[i].y = max(0, minY)
                next.page.nodes[i].width = min(page.width - next.page.nodes[i].x, maxX - minX)
                next.page.nodes[i].height = min(page.height - next.page.nodes[i].y, maxY - minY)
            } else {
                next.page.nodes[i].x = r.minX + (movement?.x ?? 0)
                next.page.nodes[i].y = r.minY + (movement?.y ?? 0)
            }
        }
        if resizeHandle != nil, let id = selectedNodes.first, let before = beforeDrag,
            let old = before.page.nodes.first(where: { $0.id == id }),
            let new = next.page.nodes.first(where: { $0.id == id })
        {
            DiagramOperations.transformChildren(
                in: &next.page, from: old, to: new,
                preparedRoutes: editor?.retainedScene.foreground.routes ?? [:])
        }
        if let before = beforeDrag {
            DiagramOperations.transformGroupedEdges(
                in: &next.page, from: before.page,
                preparedRoutes: editor?.retainedScene.foreground.routes ?? [:])
        }
        interactionPreview = next
        // Redraw only what this step and the previous one touched; a full-canvas redraw of a large
        // page per drag step cannot keep up with input.
        let damage = dragDamage(moving: Set(originalRects.keys))
        setNeedsDisplay(lastDragDamage.map { damage.union($0) } ?? damage)
        lastDragDamage = damage
    }
    override func mouseUp(with event: NSEvent) {
        let evidence = PerformanceEvidence.begin(.event)
        defer { PerformanceEvidence.end(evidence) }
        if tool == .line, let start = lineStart {
            let point = pointInPage(event)
            let end = CGPoint(x: max(0, min(page.width, point.x)), y: max(0, min(page.height, point.y)))
            if hypot(end.x - start.x, end.y - start.y) > 3 { editor?.addFreeLine(from: start, to: end) }
            lineStart = nil
            needsDisplay = true
            return
        }
        if tool == .connector, let source = pendingSource,
            let target = node(at: pointInPage(event), includeLocked: false), target.id != source,
            target.kind != .swimlane, page.permitsGlue(to: target)
        {
            editor?.connect(source, to: target.id)
            pendingSource = nil
            needsDisplay = true
            editor?.updateStatus()
        }
        applyPendingDrag()
        let protectionFailure = beforeDrag != nil ? commitGesturePreview() : nil
        lastDragDamage = nil
        dragStart = nil
        beforeDrag = nil
        resizeHandle = nil
        controlDrag = nil
        controlBaseline = nil
        controlPreviewPoint = nil
        originalRects = [:]
        marquee = nil
        if let error = controlDragError { editor?.root.showMessage(error.localizedDescription) }
        controlDragError = nil
        updateControlToolTips()
        editor?.selectionChanged()
        if let protectionFailure { explainCanvasAction(protectionFailure) }
        needsDisplay = true
    }
    func finishPageInteraction() {
        finishEditing(commit: true)
        let protectionFailure = beforeDrag != nil ? commitGesturePreview() : nil
        dragStart = nil
        beforeDrag = nil
        resizeHandle = nil
        controlDrag = nil
        controlBaseline = nil
        controlPreviewPoint = nil
        originalRects = [:]
        marquee = nil
        lineStart = nil
        pendingSource = nil
        keyboardFocusedObject = nil
        if let error = controlDragError { editor?.root.showMessage(error.localizedDescription) }
        controlDragError = nil
        updateControlToolTips()
        if let protectionFailure { explainCanvasAction(protectionFailure) }
    }
    override func keyDown(with event: NSEvent) {
        let evidence = PerformanceEvidence.begin(.event)
        defer { PerformanceEvidence.end(evidence) }
        guard editor != nil else {
            super.keyDown(with: event)
            return
        }
        // Canvas commands are local to the canvas responder. NSTextView and
        // field editors retain their ordinary letters and marked-text events.
        guard window?.firstResponder === self else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 48, !flags.contains(.command), !flags.contains(.control) {
            if flags.contains(.option) {
                traverseCanvasObjects(backward: flags.contains(.shift))
            } else {
                leaveCanvas(backward: flags.contains(.shift))
            }
            return
        }
        if event.keyCode == 53 {
            let wasConnecting = pendingSource != nil
            finishEditing(commit: false)
            interactionPreview = nil
            previewStateID = nil
            dragStart = nil
            beforeDrag = nil
            resizeHandle = nil
            controlDrag = nil
            controlBaseline = nil
            controlPreviewPoint = nil
            controlDragError = nil
            originalRects = [:]
            marquee = nil
            pendingSource = nil
            pendingSourcePort = nil
            lineStart = nil
            if !wasConnecting {
                keyboardFocusedObject = nil
                select([])
            }
            editor?.setTool(.pointer)
            if wasConnecting { explainCanvasAction("Connection cancelled.") }
            return
        }
        if flags.contains(.command) || flags.contains(.control) {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            editor?.deleteSelection(nil)
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if pendingSource != nil {
                _ = confirmKeyboardConnection()
            } else if selectedNodes.count == 1, let id = selectedNodes.first {
                _ = editCanvasObjectText(id)
            } else {
                explainCanvasAction("Select one shape to edit its text.")
            }
            return
        }
        if [123, 124, 125, 126].contains(event.keyCode) {
            let amount = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
            let dx = event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0
            let dy = event.keyCode == 126 ? -amount : event.keyCode == 125 ? amount : 0
            _ = transformKeyboardSelection(dx: dx, dy: dy, resize: flags.contains(.option))
            return
        }
        if !flags.contains(.option), let c = event.charactersIgnoringModifiers?.lowercased() {
            if c == "v" {
                editor?.setTool(.pointer)
                return
            }
            if c == "c" {
                if selectedNodes.count == 1 {
                    _ = startKeyboardConnection()
                } else {
                    editor?.setTool(.connector)
                }
                return
            }
            if c == "t" {
                editor?.setTool(.text)
                return
            }
            if c == "l" {
                editor?.setTool(.line)
                return
            }
        }
        super.keyDown(with: event)
    }
    override func magnify(with event: NSEvent) { setZoom(zoom * (1 + event.magnification)) }
    var isEditingText: Bool { inline != nil }
    func fieldInsertionPosition() -> (UUID, NSRange)? {
        guard let field = inline, let id = editingID else { return nil }
        return (id, ShapeRichText.logicalSelection(field.selectedRange(), in: field.attributedString()))
    }
    func formatEditingText(_ style: String) -> Bool {
        guard let field = inline else { return false }
        let range = field.selectedRange()
        let text = NSMutableAttributedString(attributedString: field.attributedString())
        let current =
            range.length > 0
            ? text.attributes(at: range.location, effectiveRange: nil) : field.typingAttributes
        let trait: NSFontTraitMask = style == "bold" ? .boldFontMask : .italicFontMask
        let font = current[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14 * zoom)
        let enabled =
            style == "underline"
            ? (current[.underlineStyle] as? Int ?? 0) == 0
            : !NSFontManager.shared.traits(of: font).contains(trait)
        func formatted(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var result = attributes
            if style == "underline" {
                result[.underlineStyle] = enabled ? NSUnderlineStyle.single.rawValue : 0
            } else {
                let font = attributes[.font] as? NSFont ?? font
                result[.font] =
                    enabled
                    ? NSFontManager.shared.convert(font, toHaveTrait: trait)
                    : NSFontManager.shared.convert(font, toNotHaveTrait: trait)
            }
            return result
        }
        if range.length == 0 {
            field.typingAttributes = formatted(current)
        } else {
            let snapshot = NSAttributedString(attributedString: text)
            snapshot.enumerateAttributes(in: range) { attributes, range, _ in
                text.setAttributes(formatted(attributes), range: range)
            }
            field.applyFormatting(text)
        }
        return true
    }
    func beginEditing(_ id: UUID) {
        guard let n = page.nodes.first(where: { $0.id == id }), !page.isLocked(n) else { return }
        if let reason = NativeEditProtection.blockReason(for: "Text", node: n, in: page) {
            explainCanvasAction(reason)
            return
        }
        finishEditing(commit: true)
        let rect = DiagramDrawing.textRect(for: n)
        let textView = InlineTextView(
            frame: CGRect(
                x: pageOrigin.x + rect.minX * coordinateZoom, y: pageOrigin.y + rect.minY * coordinateZoom,
                width: max(60, rect.width * coordinateZoom), height: max(36, rect.height * coordinateZoom)))
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.backgroundColor = .white
        textView.textStorage?.setAttributedString(ShapeRichText.attributed(n, scale: zoom, editing: true))
        textView.typingAttributes =
            n.text.isEmpty
            ? [
                .font: NSFontManager.shared.convert(DiagramDrawing.font(for: n), toSize: n.fontSize * zoom),
                .foregroundColor: NSColor(hex: n.textColor),
            ] : textView.textStorage!.attributes(at: 0, effectiveRange: nil)
        textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 5, height: 8)
        textView.wantsLayer = true
        textView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        textView.layer?.borderWidth = 2
        textView.layer?.cornerRadius = 4
        textView.finish = { [weak self] commit in self?.finishEditing(commit: commit) }
        editingID = id
        inline = textView
        addSubview(textView)
        window?.makeFirstResponder(textView)
        textView.selectAll(nil)
    }
    func finishEditing(commit: Bool) {
        guard !finishingText, let field = inline, let id = editingID else { return }
        finishingText = true
        let text = NSAttributedString(attributedString: field.attributedString())
        field.finish = nil
        inline = nil
        editingID = nil
        field.removeFromSuperview()
        if commit {
            var next = document.diagram
            if let i = next.page.nodes.firstIndex(where: { $0.id == id }) {
                next.page.nodes[i] = ShapeRichText.applying(text, to: next.page.nodes[i], scale: zoom)
                document.replaceInEditor(with: next, action: "Edit Text")
            }
        }
        finishingText = false
    }
    @objc func copy(_ sender: Any?) { editor?.copySelection() }
    @objc func cut(_ sender: Any?) {
        editor?.cutSelection(sender)
    }
    @objc func paste(_ sender: Any?) { editor?.pasteSelection() }
    override func selectAll(_ sender: Any?) { select(Set(page.nodes.filter { !$0.locked }.map(\.id))) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation, from: nil)
        if let raw = sender.draggingPasteboard.string(forType: Self.stencilPasteboardType),
            let definition = editor?.stencils.first(where: { $0.id.uuidString == raw })
        {
            editor?.insertStencil(
                definition,
                at: CGPoint(
                    x: (p.x - pageOrigin.x) / coordinateZoom, y: (p.y - pageOrigin.y) / coordinateZoom))
            return true
        }
        guard let raw = sender.draggingPasteboard.string(forType: Self.shapePasteboardType),
            let kind = ShapeKind(rawValue: raw)
        else { return false }
        editor?.insertShape(
            kind,
            at: CGPoint(
                x: (p.x - pageOrigin.x) / coordinateZoom - kind.defaultSize.width / 2,
                y: (p.y - pageOrigin.y) / coordinateZoom - kind.defaultSize.height / 2))
        return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = pointInPage(event)
        if let hit = node(at: p), !selectedNodes.contains(hit.id) { select([hit.id]) }
        let menu = NSMenu()
        for (title, action) in [
            ("Edit Text", #selector(EditorWindowController.editText(_:))),
            ("Duplicate", #selector(EditorWindowController.duplicateSelection(_:))),
            ("Bring to Front", #selector(EditorWindowController.bringToFront(_:))),
            ("Send to Back", #selector(EditorWindowController.sendToBack(_:))),
            ("Lock / Unlock", #selector(EditorWindowController.toggleLock(_:))),
            ("Delete", #selector(EditorWindowController.deleteSelection(_:))),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = editor
            menu.addItem(item)
        }
        return menu
    }
}
