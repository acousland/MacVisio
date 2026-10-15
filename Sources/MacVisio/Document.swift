import AppKit
import UniformTypeIdentifiers

@objc(MacVisioDocument)
final class MacVisioDocument: NSDocument {
    static let nativeType = "com.macvisio.diagram"
    static let visioType = "com.microsoft.visio.vsdx"
    static let legacyType = "com.microsoft.visio.vsd"
    var diagram = Diagram()
    var importWarnings: [String] = []
    var calculationIssues: [String] = []
    var legacyNative = false
    weak var documentWorkflow:DocumentWorkflow?
    override class var autosavesInPlace: Bool { true }
    override class var writableTypes: [String] { [visioType,nativeType,legacyType] }
    override class var readableTypes: [String] { [visioType,legacyType,nativeType] }
    override init() { super.init(); hasUndoManager = true }
    override func makeWindowControllers() {
        let controller = EditorWindowController(document:self)
        addWindowController(controller)
    }
    override func data(ofType typeName:String) throws -> Data {
        for controller in windowControllers { (controller as? EditorWindowController)?.canvas.finishEditing(commit:true) }
        if typeName == Self.legacyType { return try VSDBinaryFormat.encoded(diagram) }
        if typeName == Self.visioType {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-save-\(UUID()).vsdx")
            defer { try? FileManager.default.removeItem(at:url) }
            try VisioFormat.write(diagram,to:url)
            return try Data(contentsOf:url)
        }
        guard typeName == Self.nativeType else { throw DiagramError.invalid("This file type cannot be written.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        return try encoder.encode(diagram.validated())
    }
    override func read(from data:Data,ofType typeName:String) throws {
        guard data.count <= 256_000_000 else { throw DiagramError.invalid("This diagram exceeds the supported document size.") }
        if typeName == Self.legacyType {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-read-\(UUID()).vsd");defer{try? FileManager.default.removeItem(at:url)}
            try data.write(to:url);let result = try LegacyVisioFormat.read(from:url);diagram = result.diagram;importWarnings = result.warnings;legacyNative = result.legacyNative;return
        }
        if typeName == Self.visioType {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-read-\(UUID()).vsdx")
            defer { try? FileManager.default.removeItem(at:url) }
            try data.write(to:url)
            let result = try VisioFormat.read(from:url); diagram = result.diagram; importWarnings = result.warnings; return
        }
        diagram = GeometrySheet.refreshCompositeCaches(try JSONDecoder().decode(Diagram.self,from:data).validated())
    }
    override func read(from url:URL,ofType typeName:String) throws {
        if ["vsd","vst"].contains(url.pathExtension.lowercased()) || typeName == Self.legacyType {
            let result = try LegacyVisioFormat.read(from:url); diagram = result.diagram; importWarnings = result.warnings;legacyNative = result.legacyNative
        } else if (url.pathExtension.lowercased() == "vsdx" || url.pathExtension.lowercased() == "vstx") {
            let result = try VisioFormat.read(from:url); diagram = try result.diagram.validated(); importWarnings = result.warnings
        } else { try read(from:Data(contentsOf:url),ofType:typeName) }
    }
    override func write(to url:URL,ofType typeName:String) throws {
        let ext = url.pathExtension.lowercased()
        guard (ext != "vsd" || typeName == Self.legacyType),(ext != "vsdx" || typeName == Self.visioType) else { throw DiagramError.invalid("The file extension does not match its selected format.") }
        try super.write(to:url,ofType:typeName)
    }
    override func save(to url:URL,ofType typeName:String,for saveOperation:NSDocument.SaveOperationType,completionHandler:@escaping (Error?)->Void) {
        super.save(to:url,ofType:typeName,for:saveOperation) { [weak self] error in
            if error == nil,[NSDocument.SaveOperationType.saveOperation,.saveAsOperation,.autosaveInPlaceOperation].contains(saveOperation) {
                DispatchQueue.main.async { [weak self] in self?.documentWorkflow?.noteRecent(url) }
            }
            completionHandler(error)
        }
    }
    override func close() {
        let workflow = documentWorkflow
        super.close()
        workflow?.documentClosed(self)
    }
    func commitTextEditing() {
        for controller in windowControllers { (controller as? EditorWindowController)?.canvas.finishEditing(commit:true) }
    }
    override func canClose(withDelegate delegate:Any,shouldClose shouldCloseSelector:Selector?,contextInfo:UnsafeMutableRawPointer?) {
        commitTextEditing()
        super.canClose(withDelegate:delegate,shouldClose:shouldCloseSelector,contextInfo:contextInfo)
    }
    func replace(with next:Diagram,action:String) {
        guard next != diagram else { return }
        let calculation = DiagramCalculation.recalculate(ShapeRichText.synchronize(next,previous:diagram),previous:diagram)
        applyCalculated(calculation.diagram,issues:calculation.issues,action:action)
    }
    private func applyCalculated(_ next:Diagram,issues:[String],action:String) {
        let previousIssues = calculationIssues;calculationIssues = issues
        guard next != diagram else { return }
        let previous = diagram
        undoManager?.registerUndo(withTarget:self) { target in target.applyCalculated(previous,issues:previousIssues,action:action) }
        undoManager?.setActionName(action)
        diagram = next
        updateChangeCount(.changeDone)
        for controller in windowControllers { (controller as? EditorWindowController)?.refresh() }
    }
}

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    unowned let diagramDocument: MacVisioDocument
    let canvas = CanvasView(frame:.zero)
    let scrollView = NSScrollView()
    var root: EditorRootView!
    var stencils: [StencilDefinition] = []
    private var fittedInitialPage = false
    var selection: [DiagramNode] { diagramDocument.diagram.page.nodes.filter { canvas.selectedNodes.contains($0.id) } }
    var editableSelectionIDs: Set<UUID> {
        let page = diagramDocument.diagram.page
        return DiagramOperations.expandedSelection(Set(selection.filter{!page.isLocked($0)}.map(\.id)),in:page)
    }
    init(document:MacVisioDocument) {
        diagramDocument = document
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x:0,y:0,width:1440,height:900)
        let frame = CGRect(x:0,y:0,width:min(1450,screen.width-50),height:min(930,screen.height-65))
        let window = NSWindow(contentRect:frame,styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.minSize = CGSize(width:1000,height:680)
        window.title = document.diagram.title; window.titlebarAppearsTransparent = true; window.backgroundColor = EditorPalette.panel
        EditorAppearance.apply();window.appearance = nil
        window.tabbingMode = .disallowed
        super.init(window:window)
        window.delegate = self; window.center(); window.setFrameAutosaveName("MacVisioEditor")
        canvas.editor = self
        scrollView.hasVerticalScroller = true; scrollView.hasHorizontalScroller = true; scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false; scrollView.documentView = canvas
        root = EditorRootView(editor:self); window.contentView = root
        window.setAccessibilityIdentifier("MacVisioEditor")
        refresh()
    }
    required init?(coder:NSCoder) { fatalError() }
    override func showWindow(_ sender:Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        let fit = !fittedInitialPage;fittedInitialPage = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if fit { self.canvas.fitPage() }
            self.window?.makeFirstResponder(self.canvas)
        }
    }
    func windowDidBecomeKey(_ notification:Notification) { diagramDocument.documentWorkflow?.documentActivated(diagramDocument) }
    func windowDidResize(_ notification:Notification) { canvas.refreshSize() }
    func windowWillClose(_ notification:Notification) { canvas.finishEditing(commit:true) }
    func refresh() {
        guard root != nil else { return }
        let page = diagramDocument.diagram.page
        canvas.selectedNodes.formIntersection(Set(page.nodes.map(\.id)))
        if !page.edges.contains(where:{$0.id == canvas.selectedEdge}) { canvas.selectedEdge = nil }
        root.refreshPages(); root.refreshImportNotes(); root.inspector.refresh(); canvas.refreshSize(); updateStatus()
    }
    func selectionChanged() { root.inspector.refresh(); updateStatus() }
    func updateStatus() {
        let page = diagramDocument.diagram.page
        let prefix = canvas.pendingSource != nil ? "Click a destination shape" : canvas.tool == .connector ? "Click two shapes to connect" : canvas.tool == .text ? "Click the page to add text" : canvas.selectedNodes.count > 0 ? "\(canvas.selectedNodes.count) selected" : "\(page.nodes.count) shapes · \(page.edges.count) connectors"
        root.status.stringValue = "\(page.name)   /   \(prefix)"
        root.zoomLabel.stringValue = "\(Int((canvas.zoom*100).rounded()))%"
        root.ribbon.refreshSelection()
    }
    func setTool(_ tool:CanvasTool) { canvas.finishEditing(commit:true); canvas.tool = tool; updateStatus(); window?.makeFirstResponder(canvas) }
    func visibleCenter() -> CGPoint { CGPoint(x:(canvas.visibleRect.midX-canvas.pageOrigin.x)/canvas.coordinateZoom,y:(canvas.visibleRect.midY-canvas.pageOrigin.y)/canvas.coordinateZoom) }
    func insertShape(_ kind:ShapeKind,at point:CGPoint? = nil) {
        canvas.finishEditing(commit:true)
        var next = diagramDocument.diagram
        let factor = next.page.paperScale,size = CGSize(width:kind.defaultSize.width/factor,height:kind.defaultSize.height/factor), center = visibleCenter()
        let p = point ?? CGPoint(x:center.x-size.width/2,y:center.y-size.height/2)
        var n = DiagramNode(kind:kind,x:max(0,min(next.page.width-size.width,DiagramGeometry.snapped(p.x,grid:10/factor))),y:max(0,min(next.page.height-size.height,DiagramGeometry.snapped(p.y,grid:10/factor))))
        n.width = size.width;n.height = size.height
        if point == nil {
            var attempts = 0
            while next.page.nodes.contains(where:{abs($0.x-n.x)<5 && abs($0.y-n.y)<5}) && attempts < 12 { n.x = min(next.page.width-n.width,n.x+20); n.y = min(next.page.height-n.height,n.y+20); attempts += 1 }
        }
        next.page.nodes.append(n); diagramDocument.replace(with:next,action:"Add \(kind.title)"); canvas.select([n.id]); setTool(.pointer)
    }
    func connect(_ source:UUID,to target:UUID,sourcePort:String? = nil,targetPort:String? = nil) {
        var next = diagramDocument.diagram
        guard let targetNode = next.page.nodes.first(where:{$0.id == target}),next.page.permitsGlue(to:targetNode) else { return }
        var edge = DiagramEdge(source:source,target:target);edge.parentID = DiagramOperations.commonGroup(source,target,in:next.page)
        edge.sourcePort = sourcePort;edge.targetPort = targetPort
        next.page.edges.append(edge); diagramDocument.replace(with:next,action:"Connect Shapes"); canvas.select([],edge:edge.id)
    }
    func setConnectionPoints(_ points:[ShapeConnectionPoint],for nodeID:UUID) throws {
        var next = diagramDocument.diagram;let original = next.page
        guard let index = next.page.nodes.firstIndex(where:{$0.id == nodeID}),!next.page.isLocked(next.page.nodes[index]) else { throw DiagramError.invalid("Select an unlocked shape to edit connection points.") }
        let old = next.page.nodes[index].formatting.connectionPoints
        next.page.nodes[index].formatting.connectionPoints = points
        for i in next.page.edges.indices {
            let route = DiagramGeometry.route(next.page.edges[i],in:original)
            func replacement(_ key:String?) -> String? { guard let key else { return nil };if points.contains(where:{$0.id == key}) { return key };return old.first(where:{$0.id == key}).flatMap{point in points.first{$0.index == point.index}?.id} }
            if next.page.edges[i].source == nodeID,let key = next.page.edges[i].sourcePort {
                if let key = replacement(key) { next.page.edges[i].sourcePort = key }
                else { next.page.edges[i].sourcePort = nil;next.page.edges[i].source = UUID();next.page.edges[i].sourcePosition = route.first.map(DiagramPoint.init) }
            }
            if next.page.edges[i].target == nodeID,let key = next.page.edges[i].targetPort {
                if let key = replacement(key) { next.page.edges[i].targetPort = key }
                else { next.page.edges[i].targetPort = nil;next.page.edges[i].target = UUID();next.page.edges[i].targetPosition = route.last.map(DiagramPoint.init) }
            }
        }
        diagramDocument.replace(with:try next.validated(),action:"Edit Connection Points")
    }
    func modifySelection(_ action:String,_ body:(inout DiagramNode)->Void) {
        var next = diagramDocument.diagram
        let roots = DiagramOperations.roots(canvas.selectedNodes,in:next.page)
        for id in roots {
            guard let i = next.page.nodes.firstIndex(where:{$0.id == id}),!next.page.isLocked(next.page.nodes[i]) else { continue }
            let previous = next.page.nodes[i]; body(&next.page.nodes[i]); let changed = next.page.nodes[i]
            if previous.rect != changed.rect || previous.rotation != changed.rotation || previous.formatting.flipX != changed.formatting.flipX || previous.formatting.flipY != changed.formatting.flipY { DiagramOperations.transformChildren(in:&next.page,from:previous,to:changed) }
        }
        diagramDocument.replace(with:next,action:action)
    }
    func modifyEdge(_ action:String,_ body:(inout DiagramEdge)->Void) {
        var next = diagramDocument.diagram
        if let i = next.page.edges.firstIndex(where:{$0.id == canvas.selectedEdge}),!next.page.isLocked(next.page.edges[i]) { body(&next.page.edges[i]); diagramDocument.replace(with:next,action:action) }
    }
    @objc func deleteSelection(_ sender:Any?) {
        canvas.finishEditing(commit:true)
        var next = diagramDocument.diagram
        let ids = editableSelectionIDs
        let lockedEdges = Set(next.page.edges.filter{next.page.isLocked($0)}.map(\.id))
        next.page.nodes.removeAll { ids.contains($0.id) }
        next.page.edges.removeAll { ids.contains($0.source) || ids.contains($0.target) || $0.parentID.map(ids.contains) == true || ($0.id == canvas.selectedEdge && !lockedEdges.contains($0.id)) }
        diagramDocument.replace(with:next,action:"Delete"); canvas.select([])
    }
    @objc func duplicateSelection(_ sender:Any?) {
        let diagram = diagramDocument.diagram
        let fragment = DiagramOperations.fragment(editableSelectionIDs,edges:Set([canvas.selectedEdge].compactMap{$0}),from:diagram.page,binding:diagram.visioArchive?.pages.first{$0.pageID == diagram.page.id})
        pasteFragment(fragment)
    }
    func copySelection() {
        let ids = canvas.selectedNodes
        let expanded = DiagramOperations.expandedSelection(ids,in:diagramDocument.diagram.page)
        let diagram = diagramDocument.diagram
        let fragment = DiagramOperations.fragment(expanded,edges:Set([canvas.selectedEdge].compactMap{$0}),from:diagram.page,binding:diagram.visioArchive?.pages.first{$0.pageID == diagram.page.id})
        guard !fragment.nodes.isEmpty || !fragment.edges.isEmpty,let data = try? JSONEncoder().encode(fragment) else { return }
        let board = NSPasteboard.general; board.clearContents(); board.setData(data,forType:CanvasView.fragmentPasteboardType)
        board.setString(fragment.nodes.map(\.text).joined(separator:"\n"),forType:.string)
    }
    func pasteSelection() {
        canvas.finishEditing(commit:true)
        guard let data = NSPasteboard.general.data(forType:CanvasView.fragmentPasteboardType),let fragment = try? JSONDecoder().decode(DiagramPage.self,from:data) else { return }
        pasteFragment(fragment)
    }
    func pasteFragment(_ fragment:DiagramPage,at point:CGPoint? = nil) {
        canvas.finishEditing(commit:true)
        var next = diagramDocument.diagram
        let binding = next.visioArchive?.pages.first(where:{$0.pageID == next.page.id})
        let reserved = (binding?.nodeIDs.map{$0.value} ?? [])+(binding?.edgeIDs.map{$0.value} ?? [])
        do {
            let ids = try DiagramOperations.insert(fragment,into:&next.page,at:point,reservedIDs:reserved)
            diagramDocument.replace(with:next,action:"Insert Shapes");canvas.select(ids);setTool(.pointer)
        } catch { presentError(error) }
    }
    func insertStencil(_ definition:StencilDefinition,at point:CGPoint? = nil) {
        let center = point ?? visibleCenter()
        pasteFragment(definition.fragment,at:CGPoint(x:center.x-definition.fragment.width/2,y:center.y-definition.fragment.height/2))
    }
    @objc func editText(_ sender:Any?) { if let id = canvas.selectedNodes.first { canvas.beginEditing(id) } else if canvas.selectedEdge != nil { editConnectorLabel() } }
    func editConnectorLabel() {
        guard let edge = diagramDocument.diagram.page.edges.first(where:{$0.id == canvas.selectedEdge}),!diagramDocument.diagram.page.isLocked(edge) else { return }
        let alert = NSAlert(); alert.messageText = "Connector label"; alert.addButton(withTitle:"Apply"); alert.addButton(withTitle:"Cancel")
        let field = NSTextField(string:edge.label); field.frame = CGRect(x:0,y:0,width:300,height:24); alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn { modifyEdge("Edit Connector Label") { $0.label = field.stringValue } }
    }
    @objc func bringToFront(_ sender:Any?) {
        var next = diagramDocument.diagram; let moved = next.page.nodes.filter { editableSelectionIDs.contains($0.id) && !next.page.isLocked($0) }; let ids = Set(moved.map(\.id))
        next.page.nodes.removeAll { ids.contains($0.id) }; next.page.nodes.append(contentsOf:moved); diagramDocument.replace(with:next,action:"Bring to Front")
    }
    @objc func sendToBack(_ sender:Any?) {
        var next = diagramDocument.diagram; let moved = next.page.nodes.filter { editableSelectionIDs.contains($0.id) && !next.page.isLocked($0) }; let ids = Set(moved.map(\.id))
        next.page.nodes.removeAll { ids.contains($0.id) }; next.page.nodes.insert(contentsOf:moved,at:0); diagramDocument.replace(with:next,action:"Send to Back")
    }
    @objc func toggleLock(_ sender:Any?) {
        var next = diagramDocument.diagram; let lock = selection.contains{!$0.locked}
        for i in next.page.nodes.indices where canvas.selectedNodes.contains(next.page.nodes[i].id) { next.page.nodes[i].locked = lock }
        diagramDocument.replace(with:next,action:lock ? "Lock Shapes" : "Unlock Shapes")
    }
    @objc func alignLeft(_ sender:Any?) { guard let x = selection.filter({!$0.locked}).map(\.x).min() else { return }; modifySelection("Align Left") { $0.x = x } }
    @objc func boldText(_ sender:Any?) { if canvas.formatEditingText("bold") { return };let enabled = !(selection.first?.bold ?? false);modifySelection("Bold Text"){$0.bold = enabled} }
    @objc func italicText(_ sender:Any?) { if canvas.formatEditingText("italic") { return };let enabled = !(selection.first?.formatting.italic ?? false);modifySelection("Italic Text"){$0.formatting.italic = enabled} }
    @objc func underlineText(_ sender:Any?) { if canvas.formatEditingText("underline") { return };let enabled = !(selection.first?.formatting.underline ?? false);modifySelection("Underline Text"){$0.formatting.underline = enabled} }
    @objc func alignCenter(_ sender:Any?) { guard !selection.isEmpty else { return }; let x = selection.map{$0.center.x}.reduce(0,+)/Double(selection.count); modifySelection("Align Center") { $0.x = x-$0.width/2 } }
    @objc func alignTop(_ sender:Any?) { guard let y = selection.filter({!$0.locked}).map(\.y).min() else { return }; modifySelection("Align Top") { $0.y = y } }
    @objc func distributeHorizontal(_ sender:Any?) { distribute(horizontal:true) }
    @objc func distributeVertical(_ sender:Any?) { distribute(horizontal:false) }
    private func distribute(horizontal:Bool) {
        let page = diagramDocument.diagram.page,roots = DiagramOperations.roots(canvas.selectedNodes,in:page)
        let nodes = page.nodes.filter{roots.contains($0.id) && !page.isLocked($0)}.sorted{ horizontal ? $0.center.x < $1.center.x : $0.center.y < $1.center.y }; guard nodes.count >= 3 else { return }
        let start = horizontal ? nodes.first!.center.x : nodes.first!.center.y, end = horizontal ? nodes.last!.center.x : nodes.last!.center.y
        var next = diagramDocument.diagram
        for (position,node) in nodes.enumerated() {
            guard let i = next.page.nodes.firstIndex(where:{$0.id == node.id}) else { continue }
            let c = start+(end-start)*Double(position)/Double(nodes.count-1)
            if horizontal { next.page.nodes[i].x = c-node.width/2 } else { next.page.nodes[i].y = c-node.height/2 }
            if node.formatting.isGroup { let changed = next.page.nodes[i];DiagramOperations.transformChildren(in:&next.page,from:node,to:changed) }
        }
        diagramDocument.replace(with:next,action:"Distribute Shapes")
    }
    @objc func addPage(_ sender:Any?) {
        canvas.finishEditing(commit:true); var next = diagramDocument.diagram; var page = DiagramPage(); page.name = "Page \(next.pages.count+1)"; next.pages.append(page); next.activePageID = page.id
        diagramDocument.replace(with:next,action:"Add Page"); canvas.select([]); canvas.fitPage()
    }
    @objc func duplicatePage(_ sender:Any?) {
        canvas.finishEditing(commit:true); var next = diagramDocument.diagram; var p = next.page; p.id = UUID(); p.name += " Copy"
        // IDs need only be unique within a page, so connections remain intact.
        next.pages.append(p); next.activePageID = p.id; diagramDocument.replace(with:next,action:"Duplicate Page"); canvas.select([])
    }
    @objc func deletePage(_ sender:Any?) {
        guard diagramDocument.diagram.pages.count > 1 else { return }
        let alert = NSAlert(); alert.messageText = "Delete \(diagramDocument.diagram.page.name)?"; alert.informativeText = "The page and its contents will be removed. You can undo this change."; alert.addButton(withTitle:"Delete Page"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        canvas.finishPageInteraction();var next = diagramDocument.diagram
        do { try PageOperations.delete(next.page.id,in:&next);diagramDocument.replace(with:next,action:"Delete Page");canvas.select([]);canvas.fitPage() } catch { presentError(error) }
    }
    func switchPage(_ id:UUID) { guard diagramDocument.diagram.pages.contains(where:{$0.id == id}) else { return };canvas.finishPageInteraction();diagramDocument.diagram.activePageID = id;canvas.select([]);setTool(.pointer);refresh();canvas.fitPage() }
    @objc func zoomIn(_ sender:Any?) { canvas.setZoom(canvas.zoom*1.2) }
    @objc func zoomOut(_ sender:Any?) { canvas.setZoom(canvas.zoom/1.2) }
    @objc func fitPage(_ sender:Any?) { canvas.fitPage() }
    @objc func actualSize(_ sender:Any?) { canvas.setZoom(1) }
    @objc func toggleGrid(_ sender:Any?) { canvas.showsGrid.toggle(); canvas.needsDisplay = true }
    @objc func toggleSnap(_ sender:Any?) { canvas.snapsToGrid.toggle(); root.snapButton.state = canvas.snapsToGrid ? .on : .off }
    @objc func pointerTool(_ sender:Any?) { setTool(.pointer) }
    @objc func connectorTool(_ sender:Any?) { setTool(.connector) }
    @objc func textTool(_ sender:Any?) { setTool(.text) }
    @objc func exportPDF(_ sender:Any?) { exportFile(ext:"pdf") }
    @objc func exportAllPagesPDF(_ sender:Any?) { exportFile(ext:"pdf",allPages:true) }
    @objc func exportPNG(_ sender:Any?) { exportFile(ext:"png") }
    @objc func exportSVG(_ sender:Any?) { exportFile(ext:"svg") }
    @objc func exportVSDX(_ sender:Any?) { exportFile(ext:"vsdx") }
    @objc func exportVSD(_ sender:Any?) { exportFile(ext:"vsd") }
    @objc func exportTemplate(_ sender:Any?) { exportFile(ext:"vstx") }
    func exportFile(ext:String,allPages:Bool = false) {
        canvas.finishEditing(commit:true)
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension:ext) ?? .data]; panel.nameFieldStringValue = "\(diagramDocument.diagram.title).\(ext)"
        if ext == "vsd" { panel.message = "Experimental binary VSD: cached graphics/text; advanced behavior is incomplete. Output has not been validated in Microsoft Visio. Keep original files." }
        if allPages { panel.message = "Export foreground pages with their assigned backgrounds. Background pages are not separate PDF pages." }
        guard let window = window else { return }
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let self = self,let url = panel.url else { return }
            do {
                switch ext {
                case "pdf": let data = try allPages ? DiagramExport.pdf(self.diagramDocument.diagram) : DiagramExport.pdf(self.diagramDocument.diagram.scene());try data.write(to:url,options:.atomic)
                case "png": try DiagramExport.png(self.diagramDocument.diagram.scene()).write(to:url,options:.atomic)
                case "svg": try DiagramDrawing.svg(self.diagramDocument.diagram.scene()).write(to:url,atomically:true,encoding:.utf8)
                case "vsdx": try VisioFormat.write(self.diagramDocument.diagram,to:url)
                case "vsd": try VSDBinaryFormat.write(self.diagramDocument.diagram,to:url)
                case "vstx": try VisioReusableFormat.writeTemplate(self.diagramDocument.diagram,to:url)
                default: break
                }
                self.root.showMessage("Exported \(url.lastPathComponent)")
            } catch { self.presentError(error) }
        }
    }
    @objc func printDiagram(_ sender:Any?) {
        canvas.finishEditing(commit:true)
        let view = ExportPageView(scene:diagramDocument.diagram.scene())
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo; info.horizontalPagination = .fit; info.verticalPagination = .fit; info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        NSPrintOperation(view:view,printInfo:info).run()
    }
    func validateMenuItem(_ menuItem:NSMenuItem) -> Bool {
        if menuItem.action == #selector(editGeometry(_:)) { return selection.count == 1 && selection[0].formatting.geometry != nil && !diagramDocument.diagram.page.isLocked(selection[0]) }
        if menuItem.action == #selector(editControls(_:)) { return selection.count == 1 && !diagramDocument.diagram.page.isLocked(selection[0]) }
        if menuItem.action == #selector(editControlCells(_:)) { return selection.count == 1 && !selection[0].formatting.controls.isEmpty && !diagramDocument.diagram.page.isLocked(selection[0]) }
        if [#selector(insertField(_:)),#selector(editTextFields(_:))].contains(menuItem.action) { return selection.count == 1 && !diagramDocument.diagram.page.isLocked(selection[0]) }
        if [#selector(boldText(_:)),#selector(italicText(_:)),#selector(underlineText(_:))].contains(menuItem.action) { return canvas.isEditingText || !selection.isEmpty }
        if menuItem.action == #selector(exportSelectionStencil(_:)) { return !canvas.selectedNodes.isEmpty || canvas.selectedEdge != nil }
        if [#selector(editBackgroundPage(_:)),#selector(matchBackgroundSize(_:))].contains(menuItem.action) { return diagramDocument.diagram.page.backgroundPageID != nil }
        if menuItem.action == #selector(exportAllPagesPDF(_:)) { return diagramDocument.diagram.pages.contains{$0.isBackground != true} }
        if menuItem.action == #selector(toggleGrid(_:)) { menuItem.state = canvas.showsGrid ? .on : .off }
        if menuItem.action == #selector(toggleSnap(_:)) { menuItem.state = canvas.snapsToGrid ? .on : .off }
        if [#selector(deleteSelection(_:)),#selector(editText(_:))].contains(menuItem.action) { return !canvas.selectedNodes.isEmpty || canvas.selectedEdge != nil }
        if [#selector(duplicateSelection(_:)),#selector(bringToFront(_:)),#selector(sendToBack(_:)),#selector(toggleLock(_:))].contains(menuItem.action) { return !selection.isEmpty }
        if [#selector(alignLeft(_:)),#selector(alignCenter(_:)),#selector(alignTop(_:))].contains(menuItem.action) { return selection.count >= 2 }
        if [#selector(distributeHorizontal(_:)),#selector(distributeVertical(_:))].contains(menuItem.action) { return selection.count >= 3 }
        if menuItem.action == #selector(deletePage(_:)) { return diagramDocument.diagram.pages.count > 1 }
        return true
    }
}
