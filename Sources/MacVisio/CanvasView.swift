import AppKit

enum CanvasTool: Int { case pointer, connector, text, line }

final class InlineTextView: NSTextView {
    var finish: ((Bool) -> Void)?
    private let textUndo = UndoManager()
    override var undoManager:UndoManager? { textUndo }
    func applyFormatting(_ value:NSAttributedString) {
        let old = NSAttributedString(attributedString:attributedString())
        undoManager?.registerUndo(withTarget:self){$0.applyFormatting(old)}
        textStorage?.setAttributedString(value);didChangeText()
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53 { finish?(false); return }
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { finish?(true); return }
        super.keyDown(with:event)
    }
    override func resignFirstResponder() -> Bool { let result = super.resignFirstResponder(); if result { finish?(true) }; return result }
}

final class CanvasView: NSView {
    weak var editor: EditorWindowController?
    var document: MacVisioDocument { editor!.diagramDocument }
    var page: DiagramPage { document.diagram.page }
    var selectedNodes = Set<UUID>()
    var selectedEdge: UUID?
    var tool: CanvasTool = .pointer { didSet { pendingSource = nil;pendingSourcePort = nil;needsDisplay = true; window?.invalidateCursorRects(for:self) } }
    var zoom: Double = 0.85
    var coordinateZoom:Double { zoom*page.paperScale }
    var showsGrid = true
    var snapsToGrid = true
    var pendingSource: UUID?
    var pendingSourcePort:String?
    func connectionPoint(at point:CGPoint,on node:DiagramNode) -> ShapeConnectionPoint? {
        node.formatting.connectionPoints.filter{$0.type != 1}.map{($0,ConnectionGeometry.point($0,on:node))}.filter{hypot($0.1.x-point.x,$0.1.y-point.y)<10/coordinateZoom}.min{hypot($0.1.x-point.x,$0.1.y-point.y)<hypot($1.1.x-point.x,$1.1.y-point.y)}?.0
    }
    private var pointer = CGPoint.zero
    private var lineStart: CGPoint?
    private var dragStart: CGPoint?
    private var beforeDrag: Diagram?
    private var originalRects: [UUID:CGRect] = [:]
    private var resizeHandle: Int?
    private var controlDrag:(UUID,String)?
    private var controlDragError:Error?
    private var controlToolTips:[NSView.ToolTipTag:String] = [:]
    private var marquee: CGRect?
    private var baseSelection = Set<UUID>()
    private var inline: InlineTextView?
    private var editingID: UUID?
    private var finishingText = false
    static let shapePasteboardType = NSPasteboard.PasteboardType("com.macvisio.shape-kind")
    static let stencilPasteboardType = NSPasteboard.PasteboardType("com.macvisio.stencil-master")
    static let fragmentPasteboardType = NSPasteboard.PasteboardType("com.macvisio.fragment")
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var pageOrigin: CGPoint { CGPoint(x:max(44,(bounds.width-page.width*coordinateZoom)/2),y:36) }
    var pageFrame: CGRect { CGRect(x:pageOrigin.x,y:pageOrigin.y,width:page.width*coordinateZoom,height:page.height*coordinateZoom) }
    override init(frame:NSRect) {
        super.init(frame:frame)
        registerForDraggedTypes([Self.shapePasteboardType,Self.stencilPasteboardType])
        setAccessibilityIdentifier("diagramCanvas"); setAccessibilityLabel("Diagram canvas")
    }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    func refreshSize() {
        guard editor != nil else { return }
        let size = enclosingScrollView?.contentSize ?? .zero
        frame.size = CGSize(width:max(size.width,page.paperWidth*zoom+88),height:max(size.height,page.paperHeight*zoom+72))
        updateControlToolTips()
        needsDisplay = true
    }
    func setZoom(_ value: Double) {
        finishEditing(commit:true)
        let center = CGPoint(x:visibleRect.midX,y:visibleRect.midY)
        let oldOrigin = pageOrigin
        let modelCenter = CGPoint(x:(center.x-oldOrigin.x)/coordinateZoom,y:(center.y-oldOrigin.y)/coordinateZoom)
        zoom = max(0.2,min(3,value)); refreshSize()
        scroll(CGPoint(x:max(0,pageOrigin.x+modelCenter.x*coordinateZoom-visibleRect.width/2),y:max(0,pageOrigin.y+modelCenter.y*coordinateZoom-visibleRect.height/2)))
        editor?.updateStatus()
    }
    func fitPage() {
        guard let size = enclosingScrollView?.contentSize, size.width > 0 else { return }
        setZoom(min((size.width-88)/page.paperWidth,(size.height-72)/page.paperHeight)); scroll(.zero)
    }
    func select(_ ids:Set<UUID>, edge:UUID? = nil) {
        selectedNodes = ids; selectedEdge = edge;updateControlToolTips(); needsDisplay = true; editor?.selectionChanged()
    }
    func controlTip(at point:CGPoint) -> String? {
        guard selectedNodes.count == 1,let node = page.nodes.first(where:{selectedNodes.contains($0.id)}),!page.isLocked(node),let control = node.formatting.controls.first(where:{$0.visible && hypot(ControlGeometry.point($0,on:node).x-point.x,ControlGeometry.point($0,on:node).y-point.y)<9/coordinateZoom}) else { return nil }
        return control.cell("Tip")?.value ?? control.name
    }
    private func updateControlToolTips() {
        removeAllToolTips();controlToolTips = [:]
        guard editor != nil,selectedNodes.count == 1,let node = page.nodes.first(where:{selectedNodes.contains($0.id)}),!page.isLocked(node) else { return }
        for control in node.formatting.controls where control.visible {
            let p = ControlGeometry.point(control,on:node),r = CGRect(x:pageOrigin.x+p.x*coordinateZoom-9,y:pageOrigin.y+p.y*coordinateZoom-9,width:18,height:18)
            let tag = addToolTip(r,owner:self,userData:nil);controlToolTips[tag] = control.cell("Tip")?.value ?? control.name
        }
    }
    @objc func view(_ view:NSView,stringForToolTip tag:NSView.ToolTipTag,point:NSPoint,userData:UnsafeMutableRawPointer?) -> String { controlToolTips[tag] ?? "" }
    func pointInPage(_ event:NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow,from:nil)
        return CGPoint(x:(p.x-pageOrigin.x)/coordinateZoom,y:(p.y-pageOrigin.y)/coordinateZoom)
    }
    func node(at point:CGPoint, includeLocked:Bool = true) -> DiagramNode? {
        page.nodes.reversed().first { n in
            if !page.isVisible(n) { return false }
            if !includeLocked && page.isLocked(n) { return false }
            if n.kind == .swimlane && n.locked && point.x > n.x+min(110,n.width*0.25) { return false }
            let radians = -n.rotation * .pi/180, dx = point.x-n.center.x, dy = point.y-n.center.y
            let p = CGPoint(x:n.center.x+dx*cos(radians)-dy*sin(radians),y:n.center.y+dx*sin(radians)+dy*cos(radians))
            if n.kind == .text { return n.rect.contains(p) }
            if n.kind == .person { return n.rect.insetBy(dx:-5,dy:-5).contains(p) }
            var local = p
            if n.formatting.flipX { local.x = 2*n.center.x-local.x }; if n.formatting.flipY { local.y = 2*n.center.y-local.y }
            let path = DiagramDrawing.outline(for:n)
            return path.contains(local) || ((!n.formatting.paths.isEmpty && n.formatting.paths.allSatisfy{!$0.fill}) && path.bounds.insetBy(dx:-5/coordinateZoom,dy:-5/coordinateZoom).contains(local))
        }
    }
    func edge(at p:CGPoint,includeLocked:Bool = true) -> DiagramEdge? {
        page.edges.reversed().first { e in
            guard page.isVisible(e),includeLocked || !page.isLocked(e) else { return false }
            let route = DiagramGeometry.route(e,in:page)
            return zip(route,route.dropFirst()).contains { DiagramGeometry.distance(p,to:$0.0,$0.1) < 7/coordinateZoom }
        }
    }
    func handles(for n:DiagramNode) -> [CGPoint] {
        let r = n.rect
        return [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.midX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.midY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.midX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY),CGPoint(x:r.minX,y:r.midY)]
    }
    override func draw(_ dirtyRect:NSRect) {
        guard editor != nil else { return }
        EditorPalette.workspace.setFill(); bounds.fill()
        let paper = pageFrame
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor(hex:"#263953").withAlphaComponent(0.15); shadow.shadowBlurRadius = 16; shadow.shadowOffset = NSSize(width:0,height:2); shadow.set()
        NSColor.white.setFill(); paper.fill()
        NSGraphicsContext.restoreGraphicsState()
        // Ruler remains outside the drawing and is never included in exports.
        let rulerFont = NSFont.monospacedDigitSystemFont(ofSize:9,weight:.regular)
        let rulerAttrs: [NSAttributedString.Key:Any] = [.font:rulerFont,.foregroundColor:NSColor.secondaryLabelColor]
        let verticalRulerStyle = NSMutableParagraphStyle(); verticalRulerStyle.alignment = .right
        let verticalRulerAttrs: [NSAttributedString.Key:Any] = [.font:rulerFont,.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:verticalRulerStyle]
        let tickStep = 20/page.paperScale
        let pixelStep = tickStep*coordinateZoom
        let topBand = CGRect(x:paper.minX,y:paper.minY-31,width:paper.width,height:31)
        let visibleTop = dirtyRect.intersection(topBand)
        if !visibleTop.isNull, pixelStep > 0 {
            // Restrict iteration to ticks intersecting this draw pass. Large pages
            // should not make a small invalidation walk every ruler division.
            let first = max(0,ceil((visibleTop.minX-paper.minX-48)/pixelStep))
            let last = min(floor(page.width/tickStep),floor((visibleTop.maxX-paper.minX)/pixelStep))
            let ruler = NSBezierPath()
            if first <= last {
                var index = first
                while index <= last {
                    let x = index*tickStep, px = paper.minX+x*coordinateZoom
                    let major = index.truncatingRemainder(dividingBy:5) == 0
                    ruler.move(to:CGPoint(x:px,y:paper.minY-5)); ruler.line(to:CGPoint(x:px,y:paper.minY-(major ? 12 : 8)))
                    if major { ("\(Int(x))" as NSString).draw(at:CGPoint(x:px+3,y:paper.minY-26),withAttributes:rulerAttrs) }
                    index += 1
                }
            }
            EditorPalette.ruler.setStroke(); ruler.lineWidth = 0.5; ruler.stroke()
        }
        let leftBand = CGRect(x:paper.minX-43,y:paper.minY,width:43,height:paper.height)
        let visibleLeft = dirtyRect.intersection(leftBand)
        if !visibleLeft.isNull, pixelStep > 0 {
            let first = max(0,ceil((visibleLeft.minY-paper.minY-6)/pixelStep))
            let last = min(floor(page.height/tickStep),floor((visibleLeft.maxY-paper.minY)/pixelStep))
            let ruler = NSBezierPath()
            if first <= last {
                var index = first
                while index <= last {
                    let y = index*tickStep, py = paper.minY+y*coordinateZoom
                    let major = index.truncatingRemainder(dividingBy:5) == 0
                    ruler.move(to:CGPoint(x:paper.minX-5,y:py)); ruler.line(to:CGPoint(x:paper.minX-(major ? 12 : 8),y:py))
                    if major { ("\(Int(y))" as NSString).draw(in:CGRect(x:paper.minX-39,y:py-6,width:29,height:12),withAttributes:verticalRulerAttrs) }
                    index += 1
                }
            }
            EditorPalette.ruler.setStroke(); ruler.lineWidth = 0.5; ruler.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by:paper.minX,yBy:paper.minY); transform.scale(by:coordinateZoom); transform.concat()
        NSBezierPath(rect:CGRect(x:0,y:0,width:page.width,height:page.height)).addClip()
        let scene = document.diagram.scene()
        for background in scene.backgrounds {
            NSGraphicsContext.saveGraphicsState();let offset = scene.offset(for:background),t = NSAffineTransform();t.translateX(by:offset.x/page.paperScale,yBy:offset.y/page.paperScale);t.scale(by:background.paperScale/page.paperScale);t.concat();DiagramDrawing.drawContents(background,printing:false);NSGraphicsContext.restoreGraphicsState()
        }
        if showsGrid {
            NSColor(hex:"#DCE4EF").setFill()
            let clip = CGRect(x:max(0,(dirtyRect.minX-paper.minX)/coordinateZoom),y:max(0,(dirtyRect.minY-paper.minY)/coordinateZoom),width:dirtyRect.width/coordinateZoom+40,height:dirtyRect.height/coordinateZoom+40)
            let dots = NSBezierPath()
            for x in stride(from:floor(clip.minX*page.paperScale/20)*20/page.paperScale,through:min(page.width,clip.maxX),by:20/page.paperScale) {
                for y in stride(from:floor(clip.minY*page.paperScale/20)*20/page.paperScale,through:min(page.height,clip.maxY),by:20/page.paperScale) { dots.appendOval(in:CGRect(x:x-0.65/page.paperScale,y:y-0.65/page.paperScale,width:1.3/page.paperScale,height:1.3/page.paperScale)) }
            }; dots.fill()
        }
        let drawingNodes = DiagramDrawing.orderedNodes(in:page)
        for n in drawingNodes where n.kind == .swimlane && page.isVisible(n) { DiagramDrawing.drawNode(n,shadow:false,paperScale:page.paperScale) }
        for e in page.edges where page.isVisible(e) { DiagramDrawing.drawEdge(e,in:page,selected:e.id == selectedEdge) }
        for n in drawingNodes where n.kind != .swimlane && page.isVisible(n) { DiagramDrawing.drawNode(n,paperScale:page.paperScale) }
        if tool == .connector {
            for node in page.nodes where page.isVisible(node) && !page.isLocked(node) && page.permitsGlue(to:node) {
                for port in node.formatting.connectionPoints {
                    let p = ConnectionGeometry.point(port,on:node),mark = NSBezierPath(ovalIn:CGRect(x:p.x-3/coordinateZoom,y:p.y-3/coordinateZoom,width:6/coordinateZoom,height:6/coordinateZoom))
                    NSColor.white.setFill();mark.fill();NSColor.controlAccentColor.setStroke();mark.lineWidth = 1/coordinateZoom;mark.stroke()
                }
            }
        }
        if let source = pendingSource, let n = page.nodes.first(where:{$0.id == source}) {
            let p = NSBezierPath(); p.move(to:ConnectionGeometry.fixed(pendingSourcePort,on:n) ?? DiagramGeometry.boundary(of:n,toward:pointer)); p.line(to:pointer); p.setLineDash([5,4],count:2,phase:0)
            NSColor.controlAccentColor.setStroke(); p.lineWidth = 2/coordinateZoom; p.stroke()
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); DiagramDrawing.path(for:n.kind,in:n.rect.insetBy(dx:-4,dy:-4)).fill()
        }
        if let start = lineStart { let path = NSBezierPath(); path.move(to:start); path.line(to:pointer); NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5; path.stroke() }
        for n in page.nodes where selectedNodes.contains(n.id) {
            NSColor.controlAccentColor.setStroke(); let outline = NSBezierPath(rect:n.rect.insetBy(dx:-3/coordinateZoom,dy:-3/coordinateZoom)); outline.lineWidth = 1.2/coordinateZoom
            if n.locked { outline.setLineDash([4/coordinateZoom,3/coordinateZoom],count:2,phase:0) }; outline.stroke()
            if !n.locked && selectedNodes.count == 1 && n.rotation == 0 {
                for p in handles(for:n) { let box = NSBezierPath(roundedRect:CGRect(x:p.x-4/coordinateZoom,y:p.y-4/coordinateZoom,width:8/coordinateZoom,height:8/coordinateZoom),xRadius:1/coordinateZoom,yRadius:1/coordinateZoom); NSColor.white.setFill(); box.fill(); NSColor.controlAccentColor.setStroke(); box.lineWidth = 1/coordinateZoom; box.stroke() }
            }
            if selectedNodes.count == 1,!page.isLocked(n) {
                for control in n.formatting.controls where control.visible {
                    let p = ControlGeometry.point(control,on:n),r = 5/coordinateZoom,diamond = NSBezierPath();diamond.move(to:CGPoint(x:p.x,y:p.y-r));diamond.line(to:CGPoint(x:p.x+r,y:p.y));diamond.line(to:CGPoint(x:p.x,y:p.y+r));diamond.line(to:CGPoint(x:p.x-r,y:p.y));diamond.close();NSColor.systemYellow.setFill();diamond.fill();NSColor.brown.setStroke();diamond.lineWidth = 1/coordinateZoom;diamond.stroke()
                }
            }
        }
        if let marquee = marquee { NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); marquee.fill(); NSColor.controlAccentColor.setStroke(); let p = NSBezierPath(rect:marquee); p.lineWidth = 1/coordinateZoom; p.stroke() }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func resetCursorRects() {
        addCursorRect(bounds,cursor:tool == .pointer ? .arrow : tool == .text ? .iBeam : .crosshair)
    }
    override func mouseDown(with event:NSEvent) {
        finishEditing(commit:true); window?.makeFirstResponder(self)
        let p = pointInPage(event); pointer = p
        if tool == .pointer,selectedNodes.count == 1,let id = selectedNodes.first,let n = page.nodes.first(where:{$0.id == id}),page.isVisible(n),!page.isLocked(n),let control = n.formatting.controls.first(where:{$0.visible && hypot(ControlGeometry.point($0,on:n).x-p.x,ControlGeometry.point($0,on:n).y-p.y)<9/coordinateZoom}) {
            dragStart = p;beforeDrag = document.diagram;controlDrag = (id,control.name);controlDragError = nil;return
        }
        guard CGRect(x:0,y:0,width:page.width,height:page.height).contains(p) else { select([]); return }
        if tool == .line { lineStart = p; needsDisplay = true; return }
        if tool == .text { editor?.insertShape(.text,at:p); if let id = selectedNodes.first { beginEditing(id) }; return }
        if tool == .connector {
            let nearby = page.nodes.reversed().first{page.isVisible($0) && !page.isLocked($0) && page.permitsGlue(to:$0) && connectionPoint(at:p,on:$0) != nil}
            guard let hit = nearby ?? node(at:p,includeLocked:false),hit.kind != .swimlane,page.permitsGlue(to:hit) else { return }
            let port = connectionPoint(at:p,on:hit)?.id
            if let source = pendingSource,source != hit.id || pendingSourcePort != port { editor?.connect(source,to:hit.id,sourcePort:pendingSourcePort,targetPort:port);pendingSource = nil;pendingSourcePort = nil }
            else { pendingSource = hit.id;pendingSourcePort = port;select([hit.id]) }
            needsDisplay = true; editor?.updateStatus(); return
        }
        if selectedNodes.count == 1, let id = selectedNodes.first, let n = page.nodes.first(where:{$0.id == id}), !page.isLocked(n), n.rotation == 0,
           let handle = handles(for:n).firstIndex(where:{ hypot($0.x-p.x,$0.y-p.y) < 9/coordinateZoom }) {
            dragStart = p; beforeDrag = document.diagram; originalRects = [id:n.rect]; resizeHandle = handle; return
        }
        if var hit = node(at:p) {
            if !event.modifierFlags.contains(.option) && event.clickCount != 2 {
                for _ in 0..<64 { guard let parentID = hit.parentID,let parent = page.nodes.first(where:{$0.id == parentID}) else { break }; hit = parent }
            }
            if event.clickCount == 2 { select([hit.id]); beginEditing(hit.id); return }
            if event.modifierFlags.contains(.shift) { var ids = selectedNodes; if ids.contains(hit.id) { ids.remove(hit.id) } else { ids.insert(hit.id) }; select(ids) }
            else if !selectedNodes.contains(hit.id) { select([hit.id]) }
            if !page.isLocked(hit) { dragStart = p; beforeDrag = document.diagram; let ids = editor?.editableSelectionIDs ?? selectedNodes; originalRects = Dictionary(uniqueKeysWithValues:page.nodes.filter{ids.contains($0.id)}.map{($0.id,$0.rect)}) }
        } else if let edge = edge(at:p) {
            select([],edge:edge.id); if event.clickCount == 2 { editor?.editConnectorLabel() }
        } else {
            baseSelection = event.modifierFlags.contains(.shift) ? selectedNodes : []
            select(baseSelection); dragStart = p; marquee = CGRect(origin:p,size:.zero)
        }
    }
    override func mouseDragged(with event:NSEvent) {
        let p = pointInPage(event); pointer = p
        if tool == .connector || tool == .line { needsDisplay = true; return }
        guard let start = dragStart else { return }
        if marquee != nil {
            marquee = CGRect(x:min(start.x,p.x),y:min(start.y,p.y),width:abs(p.x-start.x),height:abs(p.y-start.y))
            selectedNodes = baseSelection.union(page.nodes.filter { marquee!.intersects($0.rect) && !page.isLocked($0) }.map(\.id))
            needsDisplay = true; editor?.selectionChanged(); return
        }
        guard beforeDrag != nil else { return }
        if let (id,name) = controlDrag,let before = beforeDrag {
            do { document.diagram = try ControlEditing.moved(before,node:id,control:name,to:p);controlDragError = nil }
            catch { document.diagram = before;controlDragError = error }
            updateControlToolTips();needsDisplay = true;autoscroll(with:event);return
        }
        let snap = snapsToGrid && !event.modifierFlags.contains(.option)
        var next = beforeDrag ?? document.diagram
        var group = originalRects.values.reduce(CGRect.null) { $0.union($1) }
        var movement: CGPoint?
        if resizeHandle == nil,!group.isNull {
            let dx = p.x-start.x,dy = p.y-start.y
            let anchor = originalRects.values.min { $0.minX < $1.minX } ?? group
            var moveX = snap ? DiagramGeometry.snapped(anchor.minX+dx,grid:10/page.paperScale)-anchor.minX : dx
            var moveY = snap ? DiagramGeometry.snapped(anchor.minY+dy,grid:10/page.paperScale)-anchor.minY : dy
            if snap {
                let selected = Set(originalRects.keys)
                let targets = page.nodes.filter { !selected.contains($0.id) && page.isVisible($0) && page.permitsShapeSnap(to:$0) }.map(ShapeSnapping.bounds(of:))
                let adjustment = ShapeSnapping.alignmentDelta(moving:group.offsetBy(dx:moveX,dy:moveY),targets:targets,tolerance:CGFloat(6/coordinateZoom))
                moveX += adjustment.x;moveY += adjustment.y
            }
            moveX = max(-group.minX,min(page.width-group.maxX,moveX));moveY = max(-group.minY,min(page.height-group.maxY,moveY))
            movement = CGPoint(x:moveX,y:moveY)
        }
        for i in next.page.nodes.indices {
            let id = next.page.nodes[i].id
            guard let r = originalRects[id] else { continue }
            if let handle = resizeHandle {
                var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
                var px = p.x,py = p.y
                if snap { px = DiagramGeometry.snapped(px,grid:10/page.paperScale); py = DiagramGeometry.snapped(py,grid:10/page.paperScale) }
                if [0,6,7].contains(handle) { minX = min(px,maxX-30) }; if [2,3,4].contains(handle) { maxX = max(px,minX+30) }
                if [0,1,2].contains(handle) { minY = min(py,maxY-24) }; if [4,5,6].contains(handle) { maxY = max(py,minY+24) }
                next.page.nodes[i].x = max(0,minX); next.page.nodes[i].y = max(0,minY)
                next.page.nodes[i].width = min(page.width-next.page.nodes[i].x,maxX-minX); next.page.nodes[i].height = min(page.height-next.page.nodes[i].y,maxY-minY)
            } else {
                next.page.nodes[i].x = r.minX+(movement?.x ?? 0); next.page.nodes[i].y = r.minY+(movement?.y ?? 0)
            }
        }
        if resizeHandle != nil,let id = selectedNodes.first,let before = beforeDrag,
           let old = before.page.nodes.first(where:{$0.id == id}),let new = next.page.nodes.first(where:{$0.id == id}) {
            DiagramOperations.transformChildren(in:&next.page,from:old,to:new)
        }
        if let before = beforeDrag { DiagramOperations.transformGroupedEdges(in:&next.page,from:before.page) }
        document.diagram = next; needsDisplay = true
        autoscroll(with:event)
    }
    override func mouseUp(with event:NSEvent) {
        if tool == .line,let start = lineStart {
            let point = pointInPage(event),end = CGPoint(x:max(0,min(page.width,point.x)),y:max(0,min(page.height,point.y)))
            if hypot(end.x-start.x,end.y-start.y)>3 { editor?.addFreeLine(from:start,to:end) }
            lineStart = nil; needsDisplay = true; return
        }
        if tool == .connector, let source = pendingSource, let target = node(at:pointInPage(event),includeLocked:false), target.id != source, target.kind != .swimlane,page.permitsGlue(to:target) { editor?.connect(source,to:target.id); pendingSource = nil; needsDisplay = true; editor?.updateStatus() }
        if let before = beforeDrag, before != document.diagram {
            let next = document.diagram; document.diagram = before; document.replace(with:next,action:controlDrag != nil ? "Adjust Control Handle" : resizeHandle == nil ? "Move Shapes" : "Resize Shape")
        }
        dragStart = nil; beforeDrag = nil; resizeHandle = nil;controlDrag = nil; originalRects = [:]; marquee = nil
        if let error = controlDragError { editor?.root.showMessage(error.localizedDescription) };controlDragError = nil;updateControlToolTips()
        editor?.selectionChanged(); needsDisplay = true
    }
    func finishPageInteraction() {
        finishEditing(commit:true)
        if let before = beforeDrag,before != document.diagram {
            let next = document.diagram;document.diagram = before;document.replace(with:next,action:controlDrag != nil ? "Adjust Control Handle" : resizeHandle == nil ? "Move Shapes" : "Resize Shape")
        }
        dragStart = nil;beforeDrag = nil;resizeHandle = nil;controlDrag = nil;originalRects = [:];marquee = nil;lineStart = nil;pendingSource = nil
        if let error = controlDragError { editor?.root.showMessage(error.localizedDescription) };controlDragError = nil;updateControlToolTips()
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53 {
            finishEditing(commit:false)
            if let before = beforeDrag { document.diagram = before }
            dragStart = nil;beforeDrag = nil;resizeHandle = nil;controlDrag = nil;controlDragError = nil;originalRects = [:];marquee = nil;pendingSource = nil;pendingSourcePort = nil;lineStart = nil
            select([]);editor?.setTool(.pointer);return
        }
        if event.keyCode == 51 || event.keyCode == 117 { editor?.deleteSelection(nil); return }
        if [123,124,125,126].contains(event.keyCode) {
            let amount = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
            let dx = event.keyCode == 123 ? -amount : event.keyCode == 124 ? amount : 0
            let dy = event.keyCode == 126 ? -amount : event.keyCode == 125 ? amount : 0
            editor?.modifySelection("Nudge Shapes") { n in n.x = max(0,min(self.page.width-n.width,n.x+dx)); n.y = max(0,min(self.page.height-n.height,n.y+dy)) }; return
        }
        if !event.modifierFlags.contains(.command),let c = event.charactersIgnoringModifiers?.lowercased() {
            if c == "v" { editor?.setTool(.pointer); return }; if c == "c" { editor?.setTool(.connector); return }; if c == "t" { editor?.setTool(.text); return }
            if c == "l" { editor?.setTool(.line); return }
            if c == "\r",let id = selectedNodes.first { beginEditing(id); return }
        }
        super.keyDown(with:event)
    }
    override func magnify(with event:NSEvent) { setZoom(zoom*(1+event.magnification)) }
    var isEditingText:Bool { inline != nil }
    func fieldInsertionPosition() -> (UUID,NSRange)? {
        guard let field = inline,let id = editingID else { return nil };return (id,ShapeRichText.logicalSelection(field.selectedRange(),in:field.attributedString()))
    }
    func formatEditingText(_ style:String) -> Bool {
        guard let field = inline else { return false }
        let range = field.selectedRange(),text = NSMutableAttributedString(attributedString:field.attributedString())
        let current = range.length > 0 ? text.attributes(at:range.location,effectiveRange:nil) : field.typingAttributes
        let trait:NSFontTraitMask = style == "bold" ? .boldFontMask : .italicFontMask
        let font = current[.font] as? NSFont ?? NSFont.systemFont(ofSize:14*zoom)
        let enabled = style == "underline" ? (current[.underlineStyle] as? Int ?? 0) == 0 : !NSFontManager.shared.traits(of:font).contains(trait)
        func formatted(_ attributes:[NSAttributedString.Key:Any]) -> [NSAttributedString.Key:Any] {
            var result = attributes
            if style == "underline" { result[.underlineStyle] = enabled ? NSUnderlineStyle.single.rawValue : 0 }
            else { let font = attributes[.font] as? NSFont ?? font;result[.font] = enabled ? NSFontManager.shared.convert(font,toHaveTrait:trait) : NSFontManager.shared.convert(font,toNotHaveTrait:trait) }
            return result
        }
        if range.length == 0 { field.typingAttributes = formatted(current) }
        else {
            let snapshot = NSAttributedString(attributedString:text)
            snapshot.enumerateAttributes(in:range){attributes,range,_ in text.setAttributes(formatted(attributes),range:range)}
            field.applyFormatting(text)
        }
        return true
    }
    func beginEditing(_ id:UUID) {
        guard let n = page.nodes.first(where:{$0.id == id}),!page.isLocked(n) else { return }
        finishEditing(commit:true)
        let rect = DiagramDrawing.textRect(for:n)
        let textView = InlineTextView(frame:CGRect(x:pageOrigin.x+rect.minX*coordinateZoom,y:pageOrigin.y+rect.minY*coordinateZoom,width:max(60,rect.width*coordinateZoom),height:max(36,rect.height*coordinateZoom)))
        textView.isRichText = true;textView.importsGraphics = false;textView.allowsUndo = true
        textView.backgroundColor = .white;textView.textStorage?.setAttributedString(ShapeRichText.attributed(n,scale:zoom,editing:true))
        textView.typingAttributes = n.text.isEmpty ? [.font:NSFontManager.shared.convert(DiagramDrawing.font(for:n),toSize:n.fontSize*zoom),.foregroundColor:NSColor(hex:n.textColor)] : textView.textStorage!.attributes(at:0,effectiveRange:nil)
        textView.isVerticallyResizable = false; textView.textContainer?.widthTracksTextView = true; textView.textContainerInset = NSSize(width:5,height:8)
        textView.wantsLayer = true; textView.layer?.borderColor = NSColor.controlAccentColor.cgColor; textView.layer?.borderWidth = 2; textView.layer?.cornerRadius = 4
        textView.finish = { [weak self] commit in self?.finishEditing(commit:commit) }
        editingID = id; inline = textView; addSubview(textView); window?.makeFirstResponder(textView); textView.selectAll(nil)
    }
    func finishEditing(commit:Bool) {
        guard !finishingText,let field = inline,let id = editingID else { return }
        finishingText = true
        let text = NSAttributedString(attributedString:field.attributedString()); field.finish = nil; inline = nil; editingID = nil; field.removeFromSuperview()
        if commit { var next = document.diagram; if let i = next.page.nodes.firstIndex(where:{$0.id == id}) { next.page.nodes[i] = ShapeRichText.applying(text,to:next.page.nodes[i],scale:zoom); document.replace(with:next,action:"Edit Text") } }
        finishingText = false
    }
    @objc func copy(_ sender:Any?) { editor?.copySelection() }
    @objc func cut(_ sender:Any?) { editor?.copySelection(); editor?.deleteSelection(nil) }
    @objc func paste(_ sender:Any?) { editor?.pasteSelection() }
    override func selectAll(_ sender:Any?) { select(Set(page.nodes.filter{!$0.locked}.map(\.id))) }
    override func draggingEntered(_ sender:NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
        let p = convert(sender.draggingLocation,from:nil)
        if let raw = sender.draggingPasteboard.string(forType:Self.stencilPasteboardType),let definition = editor?.stencils.first(where:{$0.id.uuidString == raw}) { editor?.insertStencil(definition,at:CGPoint(x:(p.x-pageOrigin.x)/coordinateZoom,y:(p.y-pageOrigin.y)/coordinateZoom));return true }
        guard let raw = sender.draggingPasteboard.string(forType:Self.shapePasteboardType),let kind = ShapeKind(rawValue:raw) else { return false }
        editor?.insertShape(kind,at:CGPoint(x:(p.x-pageOrigin.x)/coordinateZoom-kind.defaultSize.width/2,y:(p.y-pageOrigin.y)/coordinateZoom-kind.defaultSize.height/2)); return true
    }
    override func menu(for event:NSEvent) -> NSMenu? {
        let p = pointInPage(event)
        if let hit = node(at:p),!selectedNodes.contains(hit.id) { select([hit.id]) }
        let menu = NSMenu()
        for (title,action) in [("Edit Text",#selector(EditorWindowController.editText(_:))),("Duplicate",#selector(EditorWindowController.duplicateSelection(_:))),("Bring to Front",#selector(EditorWindowController.bringToFront(_:))),("Send to Back",#selector(EditorWindowController.sendToBack(_:))),("Lock / Unlock",#selector(EditorWindowController.toggleLock(_:))),("Delete",#selector(EditorWindowController.deleteSelection(_:)))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = editor; menu.addItem(item)
        }
        return menu
    }
}
