import AppKit

class FlippedView: NSView { override var isFlipped: Bool { true } }

func uiLabel(_ text:String,size:CGFloat = 12,weight:NSFont.Weight = .regular,color:String? = nil) -> NSTextField {
    let label = NSTextField(labelWithString:text); label.font = .systemFont(ofSize:size,weight:weight); label.textColor = color.map{NSColor(hex:$0)} ?? .secondaryLabelColor; return label
}
func symbolButton(_ symbol:String,label:String,target:AnyObject?,action:Selector) -> NSButton {
    let button = NSButton(image:NSImage(systemSymbolName:symbol,accessibilityDescription:label) ?? NSImage(),target:target,action:action)
    button.bezelStyle = .texturedRounded; button.imagePosition = .imageOnly; button.toolTip = label; button.setAccessibilityLabel(label); return button
}

final class StencilCard: FlippedView {
    let kind: ShapeKind
    weak var editor: EditorWindowController?
    var hover = false
    private var downEvent:NSEvent?
    private var dragged = false
    init(kind:ShapeKind,editor:EditorWindowController) {
        self.kind = kind; self.editor = editor; super.init(frame:.zero)
        setAccessibilityElement(true); setAccessibilityRole(.button); setAccessibilityLabel("Add \(kind.title)")
    }
    required init?(coder:NSCoder) { fatalError() }
    override func updateTrackingAreas() { super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }; addTrackingArea(NSTrackingArea(rect:bounds,options:[.activeInKeyWindow,.mouseEnteredAndExited],owner:self,userInfo:nil)) }
    override func mouseEntered(with event:NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event:NSEvent) { hover = false; needsDisplay = true }
    override func draw(_ dirtyRect:NSRect) {
        if hover { EditorPalette.hover.setFill(); NSBezierPath(roundedRect:bounds.insetBy(dx:0,dy:2),xRadius:7,yRadius:7).fill() }
        NSColor.white.setFill();NSBezierPath(roundedRect:CGRect(x:7,y:5,width:48,height:34),xRadius:2,yRadius:2).fill()
        var n = DiagramNode(kind:kind,x:13,y:10,text:""); n.width = 40; n.height = 26; n.strokeWidth = 1.2
        if kind == .person { n.x = 24; n.width = 18; n.y = 5; n.height = 34 }
        if kind == .text { n.text = "T"; n.fontSize = 21; n.width = 40; n.height = 32; n.y = 6 }
        DiagramDrawing.drawNode(n,shadow:false)
        (kind.title as NSString).draw(at:CGPoint(x:65,y:15),withAttributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor.labelColor])
        ("+" as NSString).draw(at:CGPoint(x:bounds.width-20,y:14),withAttributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:(hover ? EditorPalette.accent : NSColor.tertiaryLabelColor)])
    }
    override func mouseDown(with event:NSEvent) { downEvent = event; dragged = false }
    override func mouseDragged(with event:NSEvent) {
        guard !dragged,let down = downEvent,hypot(event.locationInWindow.x-down.locationInWindow.x,event.locationInWindow.y-down.locationInWindow.y) > 4 else { return }
        dragged = true
        let item = NSPasteboardItem(); item.setString(kind.rawValue,forType:CanvasView.shapePasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter:item)
        let image = NSImage(size:CGSize(width:80,height:45),flipped:true) { _ in var n = DiagramNode(kind:self.kind,x:5,y:5,text:""); n.width = 70; n.height = 35; DiagramDrawing.drawNode(n,shadow:false); return true }
        dragging.setDraggingFrame(CGRect(x:10,y:0,width:80,height:45),contents:image)
        beginDraggingSession(with:[dragging],event:down,source:self)
    }
    override func mouseUp(with event:NSEvent) { if !dragged { editor?.insertShape(kind) }; downEvent = nil }
    override func accessibilityPerformPress() -> Bool { editor?.insertShape(kind); return true }
}
extension StencilCard: NSDraggingSource {
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext) -> NSDragOperation { .copy }
}

final class MasterStencilCard: FlippedView, NSDraggingSource {
    var definition:StencilDefinition
    weak var editor:EditorWindowController?
    private var down:NSEvent?
    private var dragged = false
    private let pins:LibraryPins
    init(_ definition:StencilDefinition,editor:EditorWindowController,pins:LibraryPins = .shared) {
        self.definition = definition;self.editor = editor;self.pins = pins;super.init(frame:.zero)
        toolTip = definition.metadataDescription
        setAccessibilityElement(true);setAccessibilityRole(.button);setAccessibilityLabel("Add \(definition.name)")
    }
    required init?(coder:NSCoder) { fatalError() }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.white.setFill();NSBezierPath(roundedRect:CGRect(x:7,y:5,width:48,height:34),xRadius:2,yRadius:2).fill()
        NSGraphicsContext.saveGraphicsState()
        let p = definition.fragment,scale = min(40/max(1,p.width),32/max(1,p.height))
        let transform = NSAffineTransform();transform.translateX(by:13+(40-p.width*scale)/2,yBy:6+(32-p.height*scale)/2);transform.scale(by:scale);transform.concat()
        for edge in p.edges { DiagramDrawing.drawEdge(edge,in:p) };for node in p.nodes { DiagramDrawing.drawNode(node,shadow:false,paperScale:p.paperScale) }
        NSGraphicsContext.restoreGraphicsState()
        let style = NSMutableParagraphStyle();style.lineBreakMode = .byTruncatingTail
        (definition.name as NSString).draw(in:CGRect(x:65,y:14,width:bounds.width-70,height:22),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.labelColor,.paragraphStyle:style])
    }
    override func mouseDown(with event:NSEvent) { down = event;dragged = false }
    override func mouseDragged(with event:NSEvent) {
        guard !dragged,let down = down,hypot(event.locationInWindow.x-down.locationInWindow.x,event.locationInWindow.y-down.locationInWindow.y)>4 else { return };dragged = true
        let item = NSPasteboardItem();item.setString(definition.id.uuidString,forType:CanvasView.stencilPasteboardType)
        let dragging = NSDraggingItem(pasteboardWriter:item);dragging.setDraggingFrame(bounds,contents:bitmapImageRepForCachingDisplay(in:bounds).map{rep in cacheDisplay(in:bounds,to:rep);let image = NSImage(size:bounds.size);image.addRepresentation(rep);return image})
        beginDraggingSession(with:[dragging],event:down,source:self)
    }
    override func mouseUp(with event:NSEvent) { if !dragged { editor?.insertStencil(definition) };down = nil }
    override func accessibilityPerformPress() -> Bool { editor?.insertStencil(definition);return true }
    override func menu(for event:NSEvent) -> NSMenu? {
        guard definition.source != nil else { return nil }
        let menu = NSMenu()
        let item = NSMenuItem(title:pins.isPinned(definition.source) ? "Unpin Master" : "Pin Master",action:#selector(togglePin(_:)),keyEquivalent:"")
        item.target = self;menu.addItem(item);return menu
    }
    @discardableResult func togglePin() -> Bool {
        guard let editor,editor.lifecycleJobs.isActive,let source = definition.source else { return false }
        guard (editor.window?.firstResponder as? NSTextView)?.hasMarkedText() != true else {
            editor.root.showMessage("Finish text composition before changing master pins.");return false
        }
        do {
            let wasPinned = pins.isPinned(source);try pins.setMaster(source,pinned:!wasPinned)
            editor.root.showMessage((wasPinned ? "Unpinned " : "Pinned ") + definition.name);return true
        } catch { editor.root.showMessage(error.localizedDescription);return false }
    }
    @objc private func togglePin(_ sender:Any?) { _ = togglePin() }
    func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext) -> NSDragOperation { .copy }
}

final class StencilPanel: FlippedView, NSSearchFieldDelegate {
    weak var editor: EditorWindowController?
    let search = NSSearchField()
    let category = NSPopUpButton()
    let list = FlippedView()
    let listScroll = NSScrollView()
    let heading = uiLabel("Shapes",size:17,weight:.semibold)
    let subtitle = uiLabel("Drag shapes onto the drawing",size:10)
    let openStencil = NSButton(title:"More Shapes…",target:nil,action:nil)
    let managePins = NSButton(title:"Pinned Libraries…",target:nil,action:nil)
    private var shapeCards: [String: StencilCard] = [:]
    private var masterCards: [UUID: MasterStencilCard] = [:]
    private var visibleRows: [NSView] = []
    private let pins:LibraryPins
    private var pinObserver:NSObjectProtocol?
    private(set) var visibleMasterIDs:[UUID] = []
    private(set) var cardsCreatedCount = 0
    init(editor:EditorWindowController,pins:LibraryPins = .shared) {
        self.editor = editor;self.pins = pins; super.init(frame:.zero)
        wantsLayer = true; layer?.backgroundColor = EditorPalette.panel.cgColor
        heading.textColor = .labelColor
        search.placeholderString = "Search shapes"; search.delegate = self; search.setAccessibilityIdentifier("shapeSearch")
        category.addItems(withTitles:["All shapes","Flowchart","Basic shapes","Containers","Pinned masters"]); category.item(at:4)?.representedObject = "pinned";category.target = self; category.action = #selector(filterChanged(_:)); category.font = .systemFont(ofSize:12,weight:.medium)
        listScroll.documentView = list; listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true; listScroll.drawsBackground = false
        openStencil.target = editor;openStencil.action = #selector(EditorWindowController.openStencil(_:));openStencil.bezelStyle = .recessed;openStencil.font = .systemFont(ofSize:11)
        managePins.target = editor;managePins.action = #selector(EditorWindowController.managePinnedLibraries(_:));managePins.bezelStyle = .recessed;managePins.font = .systemFont(ofSize:11)
        managePins.setAccessibilityIdentifier("managePinnedLibraries")
        [heading,search,category,listScroll,subtitle,openStencil,managePins].forEach { addSubview($0) }
        pinObserver = NotificationCenter.default.addObserver(forName:LibraryPins.didChange,object:pins,queue:.main){[weak self] _ in self?.rebuild()}
        rebuild()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let pinObserver { NotificationCenter.default.removeObserver(pinObserver) } }
    func detachEditor() {
        if let pinObserver { NotificationCenter.default.removeObserver(pinObserver);self.pinObserver = nil }
        editor = nil
        search.delegate = nil;category.target = nil;openStencil.target = nil;managePins.target = nil
        for card in shapeCards.values { card.editor = nil }
        for card in masterCards.values { card.editor = nil }
        for row in list.subviews { row.removeFromSuperview() }
        shapeCards = [:];masterCards = [:];visibleRows = [];visibleMasterIDs = []
    }
    override func layout() {
        super.layout(); heading.frame = CGRect(x:20,y:16,width:180,height:25); search.frame = CGRect(x:15,y:48,width:bounds.width-30,height:26)
        category.frame = CGRect(x:12,y:84,width:bounds.width-24,height:26); listScroll.frame = CGRect(x:10,y:123,width:bounds.width-20,height:max(80,bounds.height-244))
        managePins.frame = CGRect(x:12,y:bounds.height-102,width:bounds.width-24,height:25)
        openStencil.frame = CGRect(x:12,y:bounds.height-72,width:bounds.width-24,height:25)
        subtitle.frame = CGRect(x:17,y:bounds.height-34,width:bounds.width-20,height:18); layoutRows()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance();effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = EditorPalette.panel.cgColor };needsDisplay = true
    }
    @objc func filterChanged(_ sender:Any?) { rebuild() }
    func refreshCategories(selecting family:String? = nil) {
        let old = family.map { "family:"+$0 } ?? (category.selectedItem?.representedObject as? String)
        let oldIndex = category.indexOfSelectedItem
        category.removeAllItems();category.addItems(withTitles:["All shapes","Flowchart","Basic shapes","Containers","Pinned masters"]);category.item(at:4)?.representedObject = "pinned"
        for name in Set(editor?.stencils.map(\.family) ?? []).sorted() {
            let item = NSMenuItem(title:name,action:nil,keyEquivalent:"")
            item.representedObject = "family:"+name;category.menu?.addItem(item)
        }
        if let old,let item = category.itemArray.first(where:{($0.representedObject as? String) == old}) { category.select(item) }
        else if old == nil,(0..<4).contains(oldIndex) { category.selectItem(at:oldIndex) }
        rebuild()
    }
    func controlTextDidChange(_ obj:Notification) { rebuild() }
    func rebuild() {
        guard let editor = editor else { return }
        let group: [ShapeKind]
        switch category.indexOfSelectedItem {
        case 1: group = [.rectangle,.roundedRectangle,.diamond,.parallelogram,.document,.cylinder,.hexagon]
        case 2: group = [.rectangle,.roundedRectangle,.ellipse,.diamond,.triangle,.hexagon,.cloud,.person,.text]
        case 3: group = [.swimlane]
        default: group = ShapeKind.allCases
        }
        let q = search.stringValue.lowercased()
        let kinds = category.indexOfSelectedItem >= 4 ? [] : group.filter{q.isEmpty || $0.title.lowercased().contains(q) || $0.rawValue.lowercased().contains(q)}
        let state = pins.snapshot
        let pinnedCategory = (category.selectedItem?.representedObject as? String) == "pinned"
        let family = (category.selectedItem?.representedObject as? String).flatMap { $0.hasPrefix("family:") ? String($0.dropFirst(7)) : nil }
        let words = q.split(whereSeparator:{$0.isWhitespace})
        let masters = editor.stencils.filter { definition in
            let categoryMatches = category.indexOfSelectedItem == 0 || (pinnedCategory ? definition.source.map { state.masters.contains($0.key) } == true : family == definition.family)
            return categoryMatches && words.allSatisfy { definition.searchMetadata.localizedCaseInsensitiveContains(String($0)) }
        }
        visibleMasterIDs = masters.map(\.id)
        let currentMasterIDs = Set(editor.stencils.map(\.id))
        masterCards = masterCards.filter { currentMasterIDs.contains($0.key) }
        var rows: [NSView] = []
        for kind in kinds {
            if shapeCards[kind.rawValue] == nil {
                shapeCards[kind.rawValue] = StencilCard(kind: kind, editor: editor)
                cardsCreatedCount += 1
            }
            if let card = shapeCards[kind.rawValue] { rows.append(card) }
        }
        for definition in masters {
            if let card = masterCards[definition.id] {
                card.definition = definition
                card.toolTip = definition.metadataDescription
                card.setAccessibilityLabel("Add \(definition.name)")
                card.needsDisplay = true
            } else {
                masterCards[definition.id] = MasterStencilCard(definition, editor: editor,pins:pins)
                cardsCreatedCount += 1
            }
            if let card = masterCards[definition.id] { rows.append(card) }
        }
        let currentRows = Set(rows.map(ObjectIdentifier.init))
        for view in list.subviews where !currentRows.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }
        for row in rows where row.superview !== list { list.addSubview(row) }
        visibleRows = rows
        layoutRows()
    }
    private func layoutRows() {
        list.frame = CGRect(x: 0, y: 0, width: max(170, listScroll.contentSize.width), height: CGFloat(visibleRows.count)*46+8)
        for (index, row) in visibleRows.enumerated() { row.frame = CGRect(x: 0, y: CGFloat(index)*46, width: list.bounds.width, height: 44) }

    }
}

final class MixedColorWell: NSColorWell {
    var isMixed = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isMixed else { return }
        let inner = bounds.insetBy(dx: 7, dy: 7)
        NSColor.controlBackgroundColor.setFill(); inner.fill()
        ("—" as NSString).draw(at: CGPoint(x: bounds.midX-6, y: bounds.midY-8),
            withAttributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor])
    }
}

final class InspectorPanel: FlippedView, NSTextFieldDelegate {
    weak var editor: EditorWindowController?
    private var fields: [String:NSTextField] = [:]
    private var displayedFieldValues: [String:String] = [:]
    private var colorWells: [String:NSColorWell] = [:]
    private var currentKey = ""
    private var applying = false
    private(set) var lengthUnit: InspectorLengthUnit = .points
    private struct CachedLayout {
        var views: [NSView]
        var fields: [String: NSTextField]
        var wells: [String: NSColorWell]
        var labels: [String: NSTextField]
    }
    private var layouts: [String: CachedLayout] = [:]
    private var dynamicLabels: [String: NSTextField] = [:]
    private(set) var layoutsCreatedCount = 0
    init(editor:EditorWindowController) {
        self.editor = editor; super.init(frame:.zero); wantsLayer = true; layer?.backgroundColor = EditorPalette.panel.cgColor
    }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance();effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = EditorPalette.panel.cgColor };needsDisplay = true
    }
    @discardableResult
    private func label(_ text:String,_ x:Double,_ y:Double,_ width:Double = 190,size:CGFloat = 11,weight:NSFont.Weight = .regular,key:String? = nil) -> NSTextField { let l = uiLabel(text,size:size,weight:weight); l.frame = CGRect(x:x,y:y,width:width,height:size >= 16 ? 24 : 18); if weight == .bold || weight == .semibold { l.textColor = .labelColor }; addSubview(l); if let key { dynamicLabels[key] = l }; return l }
    private func section(_ text:String,y:Double) { label(text,18,y,190,size:10,weight:.bold) }
    private func field(_ key:String,_ value:String,x:Double = 18,y:Double,width:Double = 194,height:Double = 24) {
        let f = NSTextField(string:value); f.frame = CGRect(x:x,y:y,width:width,height:height); f.font = .systemFont(ofSize:12); f.delegate = self; f.target = self; f.action = #selector(fieldChanged(_:)); f.identifier = NSUserInterfaceItemIdentifier(key); f.setAccessibilityLabel(key); f.setAccessibilityIdentifier("inspector_\(key)"); addSubview(f); fields[key] = f; displayedFieldValues[key] = value
    }
    private func well(_ key:String,color:String,y:Double) {
        label(key,18,y+5,130)
        let well = MixedColorWell(frame:CGRect(x:169,y:y,width:43,height:28)); well.color = NSColor(hex:color); well.target = self; well.action = #selector(colorChanged(_:)); well.identifier = NSUserInterfaceItemIdentifier(key); well.setAccessibilityLabel(key); addSubview(well); colorWells[key] = well
    }
    func refresh() {
        guard !applying,let editor = editor else { return }
        let focused = window?.firstResponder as? NSTextView
        if let focused, let textField = focused.delegate as? NSTextField,
            let key = textField.identifier?.rawValue, fields[key] === textField,
            focused.hasMarkedText() || focused.string != displayedFieldValues[key]
        { return }
        let selection = editor.selection
        let page = editor.diagramDocument.diagram.page
        let edge = page.edges.first { $0.id == editor.canvas.selectedEdge }
        let mode = !selection.isEmpty ? "node" : edge != nil ? "edge" : "page"
        if currentKey != mode {
            for view in subviews { view.removeFromSuperview() }
            currentKey = mode
            fields = [:]; displayedFieldValues = [:]; colorWells = [:]; dynamicLabels = [:]
        }
        if let layout = layouts[mode] {
            fields = layout.fields; colorWells = layout.wells; dynamicLabels = layout.labels
            for view in layout.views where view.superview !== self { addSubview(view) }
            updateValues(selection: selection, edge: edge, page: page)
            return
        }
        label(!selection.isEmpty || edge != nil ? "Format Shape" : "Format Page",18,18,210,size:17,weight:.semibold,key:"heading")
        if !selection.isEmpty {
            let node = selection[0]; currentKey = "node"
            label(selection.count == 1 ? node.kind.title : "\(selection.count) shapes",18,45,190,size:18,weight:.semibold,key:"selection")
            label(node.locked ? "Locked · unlock to edit" : page.paperScale == 1 ? "Shape properties" : "Drawing lengths · paper fonts",18,72,200,size:11,key:"detail")
            section("TEXT",y:112); field("Text",node.text,y:139,height:46)
            label("Font size (pt)",18,199,106); field("Font size",String(Int(node.fontSize)),x:125,y:194,width:87)
            let bold = NSButton(checkboxWithTitle:"Bold text",target:self,action:#selector(boldChanged(_:))); bold.frame = CGRect(x:16,y:230,width:190,height:24); bold.state = node.bold ? .on : .off; addSubview(bold)
            section("APPEARANCE",y:281)
            well("Fill",color:node.fill,y:307); well("Line",color:node.stroke,y:345); well("Text color",color:node.textColor,y:383)
            label("Line width (pt)",18,430,110); field("Line width",String(format:"%.1f",node.strokeWidth),x:125,y:424,width:87)
            label("POSITION & SIZE",18,475,120,size:10,weight:.bold); addLengthUnitPicker(y:470)
            let properties: [(String,Double)] = [("X",node.x),("Y",node.y),("Width",node.width),("Height",node.height)]
            for (i,p) in properties.enumerated() { let x = i%2 == 0 ? 18.0 : 121.0; let y = 501.0+Double(i/2)*57; label(p.0+" ("+lengthUnit.rawValue+")",x,y,91,key:"unit."+p.0); field(p.0,String(format:"%.0f",p.1),x:x,y:y+21,width:91) }
            label("Rotation (deg)",18,628,106); field("Rotation",String(format:"%.0f",node.rotation),x:125,y:622,width:87)
            let lock = NSButton(checkboxWithTitle:"Lock shape",target:editor,action:#selector(EditorWindowController.toggleLock(_:))); lock.frame = CGRect(x:16,y:665,width:190,height:24); lock.state = node.locked ? .on : .off; addSubview(lock)
            section("MORE FORMATTING",y:710)
            label("Font",18,739); field("Font",node.formatting.fontName,y:760)
            let italic = NSButton(checkboxWithTitle:"Italic",target:self,action:#selector(italicChanged(_:))); italic.frame = CGRect(x:16,y:799,width:94,height:23); italic.state = node.formatting.italic ? .on : .off; addSubview(italic)
            let underline = NSButton(checkboxWithTitle:"Underline",target:self,action:#selector(underlineChanged(_:))); underline.frame = CGRect(x:112,y:799,width:108,height:23); underline.state = node.formatting.underline ? .on : .off; addSubview(underline)
            let alignment = NSPopUpButton(frame:CGRect(x:15,y:838,width:201,height:26)); alignment.addItems(withTitles:["Left aligned","Centered","Right aligned"]); alignment.selectItem(at:node.formatting.alignment == .left ? 0 : node.formatting.alignment == .right ? 2 : 1); alignment.target = self; alignment.action = #selector(alignmentChanged(_:)); addSubview(alignment)
            let pattern = NSPopUpButton(frame:CGRect(x:15,y:878,width:201,height:26)); pattern.addItems(withTitles:["Solid line","Dashed line","Dotted line","Dash-dot line","Dash-dot-dot line"]); pattern.selectItem(at:max(0,min(4,node.formatting.linePattern-1))); pattern.target = self; pattern.action = #selector(patternChanged(_:)); addSubview(pattern)
            let layer = NSPopUpButton(frame:CGRect(x:15,y:918,width:201,height:26)); let names = ["Default"]+(page.layers ?? []).map(\.name).filter{$0 != "Default"}; layer.addItems(withTitles:names); layer.selectItem(withTitle:node.layer); layer.target = self; layer.action = #selector(layerChanged(_:)); layer.setAccessibilityLabel("Shape layer"); addSubview(layer)
            let data = NSButton(title:"Shape Data…",target:editor,action:#selector(EditorWindowController.editShapeData(_:))); data.bezelStyle = .rounded; data.frame = CGRect(x:15,y:969,width:201,height:26); addSubview(data)
            let links = NSButton(title:"Hyperlinks…",target:editor,action:#selector(EditorWindowController.editHyperlinks(_:))); links.bezelStyle = .rounded; links.frame = CGRect(x:15,y:1007,width:201,height:26); addSubview(links)
        } else if let edge {
            currentKey = "edge"; label("Connector",18,45,190,size:18,weight:.semibold); label(page.nodes.contains(where:{$0.id == edge.source}) && page.nodes.contains(where:{$0.id == edge.target}) ? "Attached to both shapes" : "Free or partially attached line",18,74,key:"detail")
            section("LABEL",y:118); field("Label",edge.label,y:146)
            section("APPEARANCE",y:210); well("Line",color:edge.color,y:240)
            label("Line width (pt)",18,289,110); field("Line width",String(format:"%.1f",edge.width),x:125,y:284,width:87)
            let route = NSPopUpButton(frame:CGRect(x:15,y:333,width:201,height:27)); route.addItems(withTitles:["Right angle","Straight"]); route.selectItem(at:edge.style == .orthogonal ? 0 : 1); route.target = self; route.action = #selector(routeChanged(_:)); addSubview(route)
            let arrow = NSButton(checkboxWithTitle:"Arrow at end",target:self,action:#selector(arrowChanged(_:))); arrow.frame = CGRect(x:16,y:382,width:190,height:24); arrow.state = edge.arrow ? .on : .off; addSubview(arrow)
            let start = NSButton(checkboxWithTitle:"Arrow at start",target:self,action:#selector(startArrowChanged(_:)));start.frame = CGRect(x:16,y:414,width:190,height:24);start.state = edge.startArrow == true ? .on : .off;addSubview(start)
            let pattern = NSPopUpButton(frame:CGRect(x:15,y:450,width:201,height:26));pattern.addItems(withTitles:["Solid line","Dashed line","Dotted line","Dash-dot line","Dash-dot-dot line"]);pattern.selectItem(at:max(0,min(4,(edge.dash ?? 1)-1)));pattern.target = self;pattern.action = #selector(edgePatternChanged(_:));addSubview(pattern)
        } else {
            currentKey = "page"; label("Drawing page",18,45,190,size:18,weight:.semibold); label("Select a shape to format it",18,74,198)
            section("PAGE",y:121); addLengthUnitPicker(y:116); label("Name",18,150); field("Page name",page.name,y:174)
            label("Width (pt)",18,220,91,key:"unit.Page width"); label("Height (pt)",121,220,91,key:"unit.Page height"); field("Page width",String(Int(page.paperWidth)),x:18,y:244,width:91); field("Page height",String(Int(page.paperHeight)),x:121,y:244,width:91)
            label("Paper dimensions · 1 in = 72 pt",18,282,200,size:10)
            let setup = NSButton(title:"Page Setup…",target:editor,action:#selector(EditorWindowController.showPageSetup(_:)));setup.bezelStyle = .rounded;setup.frame = CGRect(x:15,y:312,width:201,height:26);addSubview(setup)
            label("",18,352,200,size:11,key:"background")
            let edit = NSButton(title:"Edit Background",target:editor,action:#selector(EditorWindowController.editBackgroundPage(_:)));edit.bezelStyle = .rounded;edit.frame = CGRect(x:15,y:379,width:201,height:26);addSubview(edit)

        }
        layouts[mode] = CachedLayout(views: subviews, fields: fields, wells: colorWells, labels: dynamicLabels)
        layoutsCreatedCount += 1
        updateValues(selection: selection, edge: edge, page: page)
    }

    private func addLengthUnitPicker(y: Double) {
        let picker = NSPopUpButton(frame: CGRect(x: 142, y: y, width: 74, height: 25))
        picker.addItems(withTitles: InspectorLengthUnit.allCases.map(\.rawValue))
        picker.selectItem(withTitle: lengthUnit.rawValue)
        picker.identifier = NSUserInterfaceItemIdentifier("inspectorLengthUnit")
        picker.setAccessibilityLabel("Length display unit")
        picker.toolTip = "Drawing lengths use this unit. Fonts and line widths stay in paper points; rotation uses degrees."
        picker.target = self; picker.action = #selector(lengthUnitChanged(_:)); addSubview(picker)
    }
    @objc private func lengthUnitChanged(_ sender: NSPopUpButton) {
        editor?.diagramDocument.commitTextEditing()
        guard let value = sender.titleOfSelectedItem.flatMap(InspectorLengthUnit.init(rawValue:)) else { return }
        lengthUnit = value
        refresh()
    }
    private func updateProtection(selection: [DiagramNode], page: DiagramPage) {
        for (key, field) in fields {
            let reasons = selection.compactMap { NativeEditProtection.blockReason(for: key, node: $0, in: page) }
            field.isEnabled = reasons.count != selection.count
            let units = ["X", "Y", "Width", "Height"].contains(key) ? "Drawing length in \(lengthUnit.rawValue)." : key == "Rotation" ? "Angle in degrees." : ["Font size", "Line width"].contains(key) ? "Paper points (pt)." : ""
            field.toolTip = ([units] + reasons.prefix(1)).filter { !$0.isEmpty }.joined(separator: " ")
            field.setAccessibilityHelp(field.toolTip)
        }
        for (key, well) in colorWells {
            let reasons = selection.compactMap { NativeEditProtection.blockReason(for: key, node: $0, in: page) }
            well.isEnabled = reasons.count != selection.count
            if let reason = reasons.first { well.toolTip = reason }
        }
        for action in [#selector(boldChanged(_:)), #selector(italicChanged(_:)), #selector(underlineChanged(_:)), #selector(alignmentChanged(_:)), #selector(patternChanged(_:)), #selector(layerChanged(_:))] {
            let reasons = selection.compactMap { NativeEditProtection.blockReason(for: "Formatting", node: $0, in: page) }
            button(action)?.isEnabled = reasons.count != selection.count
            button(action)?.toolTip = reasons.first
        }
    }
    private func common<T: Equatable>(_ values: [T]) -> T? {
        guard let first = values.first, values.dropFirst().allSatisfy({ $0 == first }) else { return nil }
        return first
    }
    private func setField(_ key: String, value: String?) {
        guard let field = fields[key] else { return }
        field.stringValue = value ?? ""
        if let input = field.currentEditor() as? NSTextView, input.string != field.stringValue {
            let previous = input.selectedRange(), count = field.stringValue.utf16.count
            input.string = field.stringValue
            let location = min(previous.location, count)
            input.setSelectedRange(NSRange(location: location, length: min(previous.length, count-location)))
        }
        field.placeholderString = value == nil ? "Mixed" : nil
        field.setAccessibilityValue(value ?? "Mixed")
        displayedFieldValues[key] = field.stringValue
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        // AppKit sends the field's commit action after this notification.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }
    private func button(_ action: Selector) -> NSButton? {
        subviews.compactMap { $0 as? NSButton }.first { $0.action == action }
    }
    private func setCheck(_ action: Selector, values: [Bool]) {
        guard let control = button(action) else { return }
        control.allowsMixedState = true
        control.state = common(values).map { $0 ? .on : .off } ?? .mixed
    }
    private func setPopup(_ action: Selector, index: Int?) {
        guard let popup = button(action) as? NSPopUpButton else { return }
        popup.menu?.autoenablesItems = false
        if popup.lastItem?.title == "Mixed" { popup.removeItem(at: popup.numberOfItems-1) }
        if let index { popup.selectItem(at: index) }
        else {
            popup.addItem(withTitle: "Mixed")
            popup.lastItem?.isEnabled = false
            popup.selectItem(at: popup.numberOfItems-1)
        }
    }
    private func setColor(_ key: String, values: [String]) {
        guard let well = colorWells[key] else { return }
        let value = common(values)
        well.color = NSColor(hex: value ?? "#FFFFFF00")
        (well as? MixedColorWell)?.isMixed = value == nil
        well.toolTip = value == nil ? "Mixed colors" : key
        well.setAccessibilityValue(value ?? "Mixed")
    }
    private func updateValues(selection: [DiagramNode], edge: DiagramEdge?, page: DiagramPage) {
        (subviews.first { $0.identifier?.rawValue == "inspectorLengthUnit" } as? NSPopUpButton)?.selectItem(withTitle: lengthUnit.rawValue)
        if !selection.isEmpty {
            dynamicLabels["selection"]?.stringValue = selection.count == 1 ? selection[0].kind.title : "\(selection.count) shapes"
            let locks = selection.map { page.isLocked($0) }
            dynamicLabels["detail"]?.stringValue = locks.allSatisfy({ $0 }) ? "Locked · unlock to edit"
                : locks.contains(true) ? "Includes locked shapes" : page.paperScale == 1 ? "Shape properties" : "Drawing lengths · paper fonts"
            setField("Text", value: common(selection.map(\.text)))
            setField("Font", value: common(selection.map { $0.formatting.fontName }))
            let numeric: [(String, (DiagramNode) -> Double, String)] = [
                ("Font size", { $0.fontSize }, "%.0f"), ("Line width", { $0.strokeWidth }, "%.1f"),
                ("X", { $0.x }, "%.0f"), ("Y", { $0.y }, "%.0f"), ("Width", { $0.width }, "%.0f"),
                ("Height", { $0.height }, "%.0f"), ("Rotation", { $0.rotation }, "%.0f")]
            for (key, value, format) in numeric {
                let length = ["X", "Y", "Width", "Height"].contains(key)
                setField(key, value: common(selection.map(value)).map { length ? lengthUnit.display($0) : String(format: format, $0) })
                if length { dynamicLabels["unit."+key]?.stringValue = key+" ("+lengthUnit.rawValue+")" }
            }
            updateProtection(selection: selection, page: page)
            setCheck(#selector(boldChanged(_:)), values: selection.map(\.bold))
            setCheck(#selector(italicChanged(_:)), values: selection.map { $0.formatting.italic })
            setCheck(#selector(underlineChanged(_:)), values: selection.map { $0.formatting.underline })
            setCheck(#selector(EditorWindowController.toggleLock(_:)), values: selection.map(\.locked))
            setColor("Fill", values: selection.map(\.fill)); setColor("Line", values: selection.map(\.stroke)); setColor("Text color", values: selection.map(\.textColor))
            setPopup(#selector(alignmentChanged(_:)), index: common(selection.map { $0.formatting.alignment }).map { $0 == .left ? 0 : $0 == .right ? 2 : 1 })
            setPopup(#selector(patternChanged(_:)), index: common(selection.map { $0.formatting.linePattern }).map { max(0, min(4, $0-1)) })
            if let layer = button(#selector(layerChanged(_:))) as? NSPopUpButton {
                let names = ["Default"]+(page.layers ?? []).map(\.name).filter { $0 != "Default" }
                if layer.itemTitles.filter({ $0 != "Mixed" }) != names { layer.removeAllItems(); layer.addItems(withTitles: names) }
                setPopup(#selector(layerChanged(_:)), index: common(selection.map(\.layer)).flatMap { names.firstIndex(of: $0) })
            }
        } else if let edge {
            setField("Label", value: edge.label); setField("Line width", value: String(format: "%.1f", edge.width))
            setColor("Line", values: [edge.color])
            dynamicLabels["detail"]?.stringValue = page.nodes.contains { $0.id == edge.source } && page.nodes.contains { $0.id == edge.target }
                ? "Attached to both shapes" : "Free or partially attached line"
            setPopup(#selector(routeChanged(_:)), index: edge.style == .orthogonal ? 0 : 1)
            setCheck(#selector(arrowChanged(_:)), values: [edge.arrow]); setCheck(#selector(startArrowChanged(_:)), values: [edge.startArrow == true])
            setPopup(#selector(edgePatternChanged(_:)), index: max(0, min(4, (edge.dash ?? 1)-1)))
        } else {
            setField("Page name", value: page.name); setField("Page width", value: lengthUnit.display(page.paperWidth)); setField("Page height", value: lengthUnit.display(page.paperHeight))
            dynamicLabels["unit.Page width"]?.stringValue = "Width ("+lengthUnit.rawValue+")"
            dynamicLabels["unit.Page height"]?.stringValue = "Height ("+lengthUnit.rawValue+")"
            let background = page.backgroundPageID.flatMap { id in editor?.diagramDocument.diagram.pages.first { $0.id == id } }
            dynamicLabels["background"]?.stringValue = background.map { "Background: \($0.name)" } ?? (page.isBackground == true ? "Shared background page" : "")
            button(#selector(EditorWindowController.editBackgroundPage(_:)))?.isHidden = background == nil
        }
    }
    @objc private func fieldChanged(_ sender:NSTextField) {
        guard let editor = editor,let key = sender.identifier?.rawValue,fields[key] === sender else { return }
        let raw = sender.stringValue
        // AppKit also sends the action when an untouched field loses focus.
        // Displayed numbers may be rounded; only commit an actual text change.
        guard raw != displayedFieldValues[key] else { return }
        displayedFieldValues[key] = raw
        if currentKey == "node" {
            if key == "Text" { editor.modifySelection("Edit Text") { $0.text = raw }; return }
            if key == "Font" { editor.modifySelection("Font") { $0.formatting.fontName = raw.isEmpty ? "System" : raw }; return }
            guard let number = InspectorLengthUnit.parse(raw, defaultUnit: lengthUnit,
                angle: key == "Rotation", paperPoints: key == "Font size" || key == "Line width") else {
                sender.toolTip = "Enter a finite number with pt, mm, cm or in; angles accept deg or rad. Use ShapeSheet for formulas."
                displayedFieldValues[key] = nil; refresh(); return
            }
            editor.modifySelection("Format Shape") { node in
                switch key {
                case "Font size": node.fontSize = max(4,min(200,number))
                case "Line width": node.strokeWidth = max(0,min(20,number))
                case "X": node.x = max(0,min(editor.diagramDocument.diagram.page.width-node.width,number))
                case "Y": node.y = max(0,min(editor.diagramDocument.diagram.page.height-node.height,number))
                case "Width": node.width = max(30,min(editor.diagramDocument.diagram.page.width-node.x,number))
                case "Height": node.height = max(24,min(editor.diagramDocument.diagram.page.height-node.y,number))
                case "Rotation": node.rotation = number.truncatingRemainder(dividingBy:360)
                default: break
                }
            }
        } else if currentKey == "edge" {
            if key == "Label" { editor.modifyEdge("Edit Label") { $0.label = raw } }
            else if let width = InspectorLengthUnit.parse(raw,paperPoints:true) { editor.modifyEdge("Line Width") { $0.width = max(0.5,min(20,width)) } }
        } else {
            if key == "Page name" { editor.configurePage(name:raw.isEmpty ? "Page" : raw) }
            else if let value = InspectorLengthUnit.parse(raw,defaultUnit:lengthUnit) {
                if key == "Page width" { editor.configurePage(width:value/editor.diagramDocument.diagram.page.paperScale) }
                if key == "Page height" { editor.configurePage(height:value/editor.diagramDocument.diagram.page.paperScale) }
            }
        }
    }
    @objc private func colorChanged(_ sender:NSColorWell) {
        guard let editor = editor,let key = sender.identifier?.rawValue else { return }
        applying = true; defer { applying = false; refresh() }
        if currentKey == "edge" { editor.modifyEdge("Connector Color") { $0.color = sender.color.hexString } }
        else { editor.modifySelection("Shape Color") { n in if key == "Fill" { n.fill = sender.color.hexString }; if key == "Line" { n.stroke = sender.color.hexString }; if key == "Text color" { n.textColor = sender.color.hexString } } }
    }
    @objc private func boldChanged(_ sender:NSButton) { editor?.modifySelection("Bold Text") { $0.bold = sender.state == .on } }
    @objc private func italicChanged(_ sender:NSButton) { editor?.modifySelection("Italic Text") { $0.formatting.italic = sender.state == .on } }
    @objc private func underlineChanged(_ sender:NSButton) { editor?.modifySelection("Underline Text") { $0.formatting.underline = sender.state == .on } }
    @objc private func alignmentChanged(_ sender:NSPopUpButton) { guard sender.selectedItem?.isEnabled != false else { return }; editor?.modifySelection("Text Alignment") { $0.formatting.alignment = sender.indexOfSelectedItem == 0 ? .left : sender.indexOfSelectedItem == 2 ? .right : .center } }
    @objc private func patternChanged(_ sender:NSPopUpButton) { guard sender.selectedItem?.isEnabled != false else { return }; editor?.modifySelection("Line Pattern") { $0.formatting.linePattern = sender.indexOfSelectedItem+1 } }
    @objc private func layerChanged(_ sender:NSPopUpButton) { guard sender.selectedItem?.isEnabled != false else { return }; editor?.modifySelection("Shape Layer") { $0.layer = sender.titleOfSelectedItem ?? "Default"; $0.formatting.layerNames = [$0.layer] } }
    @objc private func routeChanged(_ sender:NSPopUpButton) { guard sender.selectedItem?.isEnabled != false else { return }; editor?.modifyEdge("Connector Style") { $0.style = sender.indexOfSelectedItem == 0 ? .orthogonal : .straight;$0.points = nil } }
    @objc private func arrowChanged(_ sender:NSButton) { editor?.modifyEdge("Connector Arrow") { $0.arrow = sender.state == .on } }
    @objc private func startArrowChanged(_ sender:NSButton) { editor?.modifyEdge("Connector Start Arrow") { $0.startArrow = sender.state == .on } }
    @objc private func edgePatternChanged(_ sender:NSPopUpButton) { guard sender.selectedItem?.isEnabled != false else { return }; editor?.modifyEdge("Connector Line Pattern") { $0.dash = sender.indexOfSelectedItem+1 } }
}

final class EditorRootView: FlippedView {
    weak var editor:EditorWindowController?
    let stencil:StencilPanel
    let inspector:InspectorPanel
    let inspectorScroll = NSScrollView()
    let ribbon:VisioRibbonView
    let footer = FlippedView()
    let pageStrip = FlippedView()
    let pageScroll = NSScrollView()
    let snapButton = NSButton(checkboxWithTitle:"Snap to Grid",target:nil,action:nil)
    let status = uiLabel("",size:11)
    let importNotesButton = NSButton(title:"Import notes",target:nil,action:nil)
    let zoomLabel = uiLabel("100%",size:11,weight:.medium)
    /// Visio's status bar: the active page's position, the text language and a zoom slider.
    let languageLabel = uiLabel(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? "",size:11)
    let pageLabel = uiLabel("",size:11)
    let zoomSlider = NSSlider(value:100,minValue:10,maxValue:400,target:nil,action:nil)
    private(set) var allPagesButton:NSButton!
    /// View > Task Panes > Format Shape (hidden by default, as in Visio).
    var showsFormatPane = UserDefaults.standard.bool(forKey:"MacVisioFormatPaneVisible") {
        didSet { UserDefaults.standard.set(showsFormatPane,forKey:"MacVisioFormatPaneVisible");inspectorScroll.isHidden = !showsFormatPane;needsLayout = true }
    }
    private var zoomMinus:NSButton!
    private var zoomPlus:NSButton!
    private var fit:NSButton!
    private var addPageButton:NSButton!
    private var pageButtons: [UUID: PageTabButton] = [:]
    private(set) var pageButtonsCreatedCount = 0
    private struct PageViewState {
        var nodeIDs: Set<UUID>
        var edgeID: UUID?
        var zoom: Double
        var scrollOrigin: CGPoint
        var inspectorOrigin: CGPoint
    }
    private var pageViewStates: [UUID: PageViewState] = [:]
    var libraryRequestedInNarrowWindow = false
    init(editor:EditorWindowController) {
        self.editor = editor;stencil = StencilPanel(editor:editor);inspector = InspectorPanel(editor:editor)
        ribbon = VisioRibbonView(editor:editor)
        super.init(frame:.zero)
        [self,footer,pageStrip].forEach{$0.wantsLayer = true}
        ribbon.onAppearanceChanged = { EditorAppearance.apply($0) }
        snapButton.target = editor;snapButton.action = #selector(EditorWindowController.toggleSnap(_:));snapButton.state = .on;snapButton.font = .systemFont(ofSize:11)
        inspectorScroll.documentView = inspector;inspectorScroll.hasVerticalScroller = true;inspectorScroll.autohidesScrollers = true;inspectorScroll.drawsBackground = false
        pageScroll.documentView = pageStrip;pageScroll.hasHorizontalScroller = true;pageScroll.autohidesScrollers = true;pageScroll.drawsBackground = false
        [stencil,editor.scrollView,inspectorScroll,ribbon,pageScroll,footer].forEach{addSubview($0)}
        zoomMinus = symbolButton("minus",label:"Zoom out",target:editor,action:#selector(EditorWindowController.zoomOut(_:)))
        zoomPlus = symbolButton("plus",label:"Zoom in",target:editor,action:#selector(EditorWindowController.zoomIn(_:)))
        fit = symbolButton("arrow.up.left.and.arrow.down.right",label:"Fit page",target:editor,action:#selector(EditorWindowController.fitPage(_:)))
        addPageButton = symbolButton("plus",label:"Add page",target:editor,action:#selector(EditorWindowController.addPage(_:)))
        zoomSlider.target = self;zoomSlider.action = #selector(zoomSliderChanged(_:));zoomSlider.controlSize = .mini
        zoomSlider.identifier = NSUserInterfaceItemIdentifier("zoomSlider");zoomSlider.setAccessibilityLabel("Zoom")
        languageLabel.textColor = .secondaryLabelColor
        [pageLabel,languageLabel,status,zoomMinus,zoomSlider,zoomPlus,zoomLabel,fit].forEach{footer.addSubview($0)}
        allPagesButton = NSButton(title:"All ▴",target:self,action:#selector(showAllPages(_:)))
        allPagesButton.isBordered = false;allPagesButton.font = .systemFont(ofSize:11);allPagesButton.identifier = NSUserInterfaceItemIdentifier("allPages")
        allPagesButton.setAccessibilityLabel("All pages");pageStrip.addSubview(allPagesButton)
        inspectorScroll.isHidden = !showsFormatPane
        importNotesButton.target = editor;importNotesButton.action = #selector(EditorWindowController.showDocumentIssues(_:))
        importNotesButton.bezelStyle = .recessed;importNotesButton.font = .systemFont(ofSize:11)
        importNotesButton.identifier = NSUserInterfaceItemIdentifier("importNotes")
        importNotesButton.setAccessibilityLabel("View drawing issues")
        importNotesButton.toolTip = "Review material import, calculation, font and content issues, including cached display state."
        footer.addSubview(importNotesButton)
        refreshImportNotes()
        addSubview(addPageButton)
        refreshAppearance()
    }
    required init?(coder:NSCoder) { fatalError() }
    func detachEditor() {
        editor = nil
        stencil.detachEditor()
        inspector.editor = nil
        ribbon.detachEditor()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance();refreshAppearance() }
    private func refreshAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = EditorPalette.border.cgColor
            footer.layer?.backgroundColor = EditorPalette.footer.cgColor
            pageStrip.layer?.backgroundColor = EditorPalette.panel.cgColor
        }
        needsDisplay = true
    }
    override func layout() {
        super.layout();guard let editor else{return}
        let w = bounds.width,h = bounds.height,left = (bounds.width >= 1000 || libraryRequestedInNarrowWindow) ? 224.0 : 0.0,right = showsFormatPane ? 248.0 : 0.0,top = VisioRibbonView.tabHeight+VisioRibbonView.commandHeight,bottom = 30.0,pages = 33.0
        stencil.isHidden = left == 0
        let bodyHeight = max(1,h-top-bottom-1)
        ribbon.frame = CGRect(x:0,y:0,width:w,height:top)
        stencil.frame = CGRect(x:0,y:top+1,width:left,height:bodyHeight)
        inspectorScroll.frame = CGRect(x:w-right,y:top+1,width:right,height:bodyHeight)
        inspector.frame.size = CGSize(width:right,height:max(1100,inspectorScroll.contentSize.height))
        editor.scrollView.frame = CGRect(x:left+1,y:top+1,width:max(1,w-left-right-2),height:max(1,bodyHeight-pages-1))
        pageScroll.frame = CGRect(x:left+1,y:h-bottom-pages,width:max(1,w-left-right-2),height:pages)
        footer.frame = CGRect(x:0,y:h-bottom,width:w,height:bottom)
        // Visio: "Page 1 of 1" and the language at the left; zoom slider, percentage and Fit Page at the right.
        let languageWidth = (languageLabel.stringValue as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width+8
        let pageWidth = (pageLabel.stringValue as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width+8
        pageLabel.frame = CGRect(x:12,y:8,width:pageWidth,height:17)
        languageLabel.frame = CGRect(x:pageLabel.frame.maxX+16,y:8,width:languageWidth,height:17)
        status.frame = CGRect(x:languageLabel.frame.maxX+16,y:8,width:max(80,w-(importNotesButton.isHidden ? 320 : 530)-languageLabel.frame.maxX),height:17)
        importNotesButton.frame = CGRect(x:w-520,y:3,width:180,height:24)
        zoomMinus.frame = CGRect(x:w-300,y:3,width:24,height:24)
        zoomSlider.frame = CGRect(x:w-274,y:7,width:120,height:16)
        zoomPlus.frame = CGRect(x:w-152,y:3,width:24,height:24)
        zoomLabel.frame = CGRect(x:w-126,y:7,width:44,height:17);zoomLabel.alignment = .center
        fit.frame = CGRect(x:w-74,y:3,width:32,height:24)
        refreshPages();editor.canvas.refreshSize()
    }
    func refreshPages() {
        guard let editor else{return}
        let pages = editor.diagramDocument.diagram.orderedPages
        let currentIDs = Set(pages.map(\.id))
        for (id, button) in pageButtons where !currentIDs.contains(id) { button.removeFromSuperview() }
        pageButtons = pageButtons.filter { currentIDs.contains($0.key) }
        pageViewStates = pageViewStates.filter { currentIDs.contains($0.key) }
        var x = 0.0
        for page in pages {
            let button: PageTabButton
            if let retained = pageButtons[page.id] { button = retained }
            else {
                button = PageTabButton(title: "", target: self, action: #selector(pageClicked(_:)))
                pageButtons[page.id] = button; pageButtonsCreatedCount += 1
                pageStrip.addSubview(button)
            }
            button.title = page.name+(page.isBackground == true ? " ◇" : "")
            button.identifier = NSUserInterfaceItemIdentifier(page.id.uuidString)
            button.isCurrent = page.id == editor.diagramDocument.diagram.activePageID
            button.setAccessibilityLabel("Page \(page.name)");button.setAccessibilityValue(button.isCurrent ? "Selected" : "")
            button.toolTip = page.isBackground == true ? "Edit shared background" : "Edit page"
            let width = min(180,max(90,(page.name as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width+32))
            button.frame = CGRect(x:x,y:0,width:width,height:33);button.needsDisplay = true;x += width+1
        }
        // As in Visio, "All" lists every page and "+" adds one, after the last page tab.
        allPagesButton.frame = CGRect(x:x+6,y:4,width:44,height:25)
        addPageButton.removeFromSuperview();pageStrip.addSubview(addPageButton)
        addPageButton.frame = CGRect(x:x+54,y:3,width:28,height:27)
        pageStrip.frame = CGRect(x:0,y:0,width:max(x+90,pageScroll.contentSize.width),height:33)
    }
    func capturePageViewState() {
        guard let editor else { return }
        pageViewStates[editor.diagramDocument.diagram.activePageID] = PageViewState(
            nodeIDs: editor.canvas.selectedNodes, edgeID: editor.canvas.selectedEdge,
            zoom: editor.canvas.zoom, scrollOrigin: editor.canvas.visibleRect.origin,
            inspectorOrigin: inspectorScroll.contentView.bounds.origin)
    }
    @discardableResult
    func restorePageViewState(for id: UUID) -> Bool {
        guard let editor, editor.diagramDocument.diagram.activePageID == id,
              let state = pageViewStates[id], let page = editor.diagramDocument.diagram.pages.first(where: { $0.id == id }) else { return false }
        let nodeIDs = state.nodeIDs.intersection(Set(page.nodes.map(\.id)))
        let edgeID = state.edgeID.flatMap { id in page.edges.contains(where: { $0.id == id }) ? id : nil }
        editor.canvas.select(nodeIDs, edge: edgeID)
        editor.canvas.setZoom(state.zoom)
        editor.canvas.scroll(state.scrollOrigin)
        inspectorScroll.contentView.scroll(to: state.inspectorOrigin)
        inspectorScroll.reflectScrolledClipView(inspectorScroll.contentView)
        return true
    }
    func refreshImportNotes() {
        let count = editor?.diagramDocument.currentDiagnostics.filter(\.isMaterial).count ?? 0
        importNotesButton.isHidden = count == 0
        importNotesButton.title = "Drawing issues (\(count))"
        needsLayout = true
    }
    func showMessage(_ text:String) {
        status.stringValue = text
        DispatchQueue.main.asyncAfter(deadline:.now()+5){[weak self] in self?.editor?.updateStatus()}
    }
    @objc private func showAllPages(_ sender:NSButton) {
        guard let editor else { return }
        let menu = NSMenu()
        for page in editor.diagramDocument.diagram.orderedPages {
            let item = NSMenuItem(title:page.name,action:#selector(pageMenuChosen(_:)),keyEquivalent:"")
            item.target = self;item.representedObject = page.id;item.state = page.id == editor.diagramDocument.diagram.activePageID ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning:nil,at:CGPoint(x:0,y:0),in:sender)
    }
    @objc private func pageMenuChosen(_ sender:NSMenuItem) { if let id = sender.representedObject as? UUID { editor?.switchPage(id) } }
    @objc private func zoomSliderChanged(_ sender:NSSlider) { editor?.canvas.setZoom(sender.doubleValue/100);editor?.updateStatus() }
    @objc private func pageClicked(_ sender:NSButton) {
        if let raw = sender.identifier?.rawValue,let id = UUID(uuidString:raw){editor?.switchPage(id)}
    }
}
