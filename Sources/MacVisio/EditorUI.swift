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
    let definition:StencilDefinition
    weak var editor:EditorWindowController?
    private var down:NSEvent?
    private var dragged = false
    init(_ definition:StencilDefinition,editor:EditorWindowController) {
        self.definition = definition;self.editor = editor;super.init(frame:.zero)
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
    init(editor:EditorWindowController) {
        self.editor = editor; super.init(frame:.zero)
        wantsLayer = true; layer?.backgroundColor = EditorPalette.panel.cgColor
        heading.textColor = .labelColor
        search.placeholderString = "Search shapes"; search.delegate = self; search.setAccessibilityIdentifier("shapeSearch")
        category.addItems(withTitles:["All shapes","Flowchart","Basic shapes","Containers"]); category.target = self; category.action = #selector(filterChanged(_:)); category.font = .systemFont(ofSize:12,weight:.medium)
        listScroll.documentView = list; listScroll.hasVerticalScroller = true; listScroll.autohidesScrollers = true; listScroll.drawsBackground = false
        openStencil.target = editor;openStencil.action = #selector(EditorWindowController.openStencil(_:));openStencil.bezelStyle = .recessed;openStencil.font = .systemFont(ofSize:11)
        [heading,search,category,listScroll,subtitle,openStencil].forEach { addSubview($0) }; rebuild()
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() {
        super.layout(); heading.frame = CGRect(x:20,y:16,width:180,height:25); search.frame = CGRect(x:15,y:48,width:bounds.width-30,height:26)
        category.frame = CGRect(x:12,y:84,width:bounds.width-24,height:26); listScroll.frame = CGRect(x:10,y:123,width:bounds.width-20,height:max(80,bounds.height-214))
        openStencil.frame = CGRect(x:12,y:bounds.height-72,width:bounds.width-24,height:25)
        subtitle.frame = CGRect(x:17,y:bounds.height-34,width:bounds.width-20,height:18); rebuild()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance();effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = EditorPalette.panel.cgColor };needsDisplay = true
    }
    @objc func filterChanged(_ sender:Any?) { rebuild() }
    func refreshCategories(selecting family:String? = nil) {
        let old = family ?? category.titleOfSelectedItem
        category.removeAllItems();category.addItems(withTitles:["All shapes","Flowchart","Basic shapes","Containers"])
        for name in Set(editor?.stencils.map(\.family) ?? []).sorted() { category.addItem(withTitle:name) }
        if let old = old { category.selectItem(withTitle:old) };rebuild()
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
        let masters = editor.stencils.filter{(category.indexOfSelectedItem == 0 || category.titleOfSelectedItem == $0.family) && (q.isEmpty || $0.name.lowercased().contains(q))}
        for view in list.subviews { view.removeFromSuperview() }
        list.frame = CGRect(x:0,y:0,width:max(170,listScroll.contentSize.width),height:CGFloat(kinds.count+masters.count)*46+8)
        for (i,kind) in kinds.enumerated() { let card = StencilCard(kind:kind,editor:editor); card.frame = CGRect(x:0,y:CGFloat(i)*46,width:list.bounds.width,height:44); list.addSubview(card) }
        for (i,definition) in masters.enumerated() { let card = MasterStencilCard(definition,editor:editor);card.frame = CGRect(x:0,y:CGFloat(i+kinds.count)*46,width:list.bounds.width,height:44);list.addSubview(card) }
    }
}

final class InspectorPanel: FlippedView {
    weak var editor: EditorWindowController?
    private var fields: [String:NSTextField] = [:]
    private var colorWells: [String:NSColorWell] = [:]
    private var currentKey = ""
    private var applying = false
    init(editor:EditorWindowController) {
        self.editor = editor; super.init(frame:.zero); wantsLayer = true; layer?.backgroundColor = EditorPalette.panel.cgColor
    }
    required init?(coder:NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance();effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = EditorPalette.panel.cgColor };needsDisplay = true
    }
    private func label(_ text:String,_ x:Double,_ y:Double,_ width:Double = 190,size:CGFloat = 11,weight:NSFont.Weight = .regular) { let l = uiLabel(text,size:size,weight:weight); l.frame = CGRect(x:x,y:y,width:width,height:size >= 16 ? 24 : 18); if weight == .bold || weight == .semibold { l.textColor = .labelColor }; addSubview(l) }
    private func section(_ text:String,y:Double) { label(text,18,y,190,size:10,weight:.bold) }
    private func field(_ key:String,_ value:String,x:Double = 18,y:Double,width:Double = 194,height:Double = 24) {
        let f = NSTextField(string:value); f.frame = CGRect(x:x,y:y,width:width,height:height); f.font = .systemFont(ofSize:12); f.target = self; f.action = #selector(fieldChanged(_:)); f.identifier = NSUserInterfaceItemIdentifier(key); f.setAccessibilityLabel(key); f.setAccessibilityIdentifier("inspector_\(key)"); addSubview(f); fields[key] = f
    }
    private func well(_ key:String,color:String,y:Double) {
        label(key,18,y+5,130)
        let well = NSColorWell(frame:CGRect(x:169,y:y,width:43,height:28)); well.color = NSColor(hex:color); well.target = self; well.action = #selector(colorChanged(_:)); well.identifier = NSUserInterfaceItemIdentifier(key); well.setAccessibilityLabel(key); addSubview(well); colorWells[key] = well
    }
    func refresh() {
        guard !applying,let editor = editor else { return }
        let focused = window?.firstResponder as? NSTextView
        if let textField = focused?.delegate as? NSTextField,fields.values.contains(where:{$0 === textField}) { return }
        for view in subviews { view.removeFromSuperview() }; fields = [:]; colorWells = [:]
        let selection = editor.selection
        let page = editor.diagramDocument.diagram.page
        label(!selection.isEmpty || editor.canvas.selectedEdge != nil ? "Format Shape" : "Format Page",18,18,210,size:17,weight:.semibold)
        if !selection.isEmpty {
            let node = selection[0]; currentKey = "node"
            label(selection.count == 1 ? node.kind.title : "\(selection.count) shapes",18,45,190,size:18,weight:.semibold)
            label(node.locked ? "Locked · unlock to edit" : page.paperScale == 1 ? "Shape properties" : "Drawing lengths · paper fonts",18,72,200,size:11)
            section("TEXT",y:112); field("Text",node.text,y:139,height:46)
            label("Font size",18,199,95); field("Font size",String(Int(node.fontSize)),x:125,y:194,width:87)
            let bold = NSButton(checkboxWithTitle:"Bold text",target:self,action:#selector(boldChanged(_:))); bold.frame = CGRect(x:16,y:230,width:190,height:24); bold.state = node.bold ? .on : .off; addSubview(bold)
            section("APPEARANCE",y:281)
            well("Fill",color:node.fill,y:307); well("Line",color:node.stroke,y:345); well("Text color",color:node.textColor,y:383)
            label("Line width",18,430,110); field("Line width",String(format:"%.1f",node.strokeWidth),x:125,y:424,width:87)
            section("POSITION & SIZE",y:475)
            let properties: [(String,Double)] = [("X",node.x),("Y",node.y),("Width",node.width),("Height",node.height)]
            for (i,p) in properties.enumerated() { let x = i%2 == 0 ? 18.0 : 121.0; let y = 501.0+Double(i/2)*57; label(p.0,x,y,91); field(p.0,String(format:"%.0f",p.1),x:x,y:y+21,width:91) }
            label("Rotation",18,628,100); field("Rotation",String(format:"%.0f",node.rotation),x:125,y:622,width:87)
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
        } else if let edge = page.edges.first(where:{$0.id == editor.canvas.selectedEdge}) {
            currentKey = "edge"; label("Connector",18,45,190,size:18,weight:.semibold); label(page.nodes.contains(where:{$0.id == edge.source}) && page.nodes.contains(where:{$0.id == edge.target}) ? "Attached to both shapes" : "Free or partially attached line",18,74)
            section("LABEL",y:118); field("Label",edge.label,y:146)
            section("APPEARANCE",y:210); well("Line",color:edge.color,y:240)
            label("Line width",18,289,100); field("Line width",String(format:"%.1f",edge.width),x:125,y:284,width:87)
            let route = NSPopUpButton(frame:CGRect(x:15,y:333,width:201,height:27)); route.addItems(withTitles:["Right angle","Straight"]); route.selectItem(at:edge.style == .orthogonal ? 0 : 1); route.target = self; route.action = #selector(routeChanged(_:)); addSubview(route)
            let arrow = NSButton(checkboxWithTitle:"Arrow at end",target:self,action:#selector(arrowChanged(_:))); arrow.frame = CGRect(x:16,y:382,width:190,height:24); arrow.state = edge.arrow ? .on : .off; addSubview(arrow)
            let start = NSButton(checkboxWithTitle:"Arrow at start",target:self,action:#selector(startArrowChanged(_:)));start.frame = CGRect(x:16,y:414,width:190,height:24);start.state = edge.startArrow == true ? .on : .off;addSubview(start)
            let pattern = NSPopUpButton(frame:CGRect(x:15,y:450,width:201,height:26));pattern.addItems(withTitles:["Solid line","Dashed line","Dotted line","Dash-dot line","Dash-dot-dot line"]);pattern.selectItem(at:max(0,min(4,(edge.dash ?? 1)-1)));pattern.target = self;pattern.action = #selector(edgePatternChanged(_:));addSubview(pattern)
        } else {
            currentKey = "page"; label("Drawing page",18,45,190,size:18,weight:.semibold); label("Select a shape to format it",18,74,198)
            section("PAGE",y:121); label("Name",18,150); field("Page name",page.name,y:174)
            label("Paper width",18,220,91); label("Paper height",121,220,91); field("Page width",String(Int(page.paperWidth)),x:18,y:244,width:91); field("Page height",String(Int(page.paperHeight)),x:121,y:244,width:91)
            label("Dimensions in points (72 = 1 inch)",18,282,200,size:10)
            let setup = NSButton(title:"Page Setup…",target:editor,action:#selector(EditorWindowController.showPageSetup(_:)));setup.bezelStyle = .rounded;setup.frame = CGRect(x:15,y:312,width:201,height:26);addSubview(setup)
            if let id = page.backgroundPageID,let background = editor.diagramDocument.diagram.pages.first(where:{$0.id == id}) {
                label("Background: \(background.name)",18,352,200,size:11)
                let edit = NSButton(title:"Edit Background",target:editor,action:#selector(EditorWindowController.editBackgroundPage(_:)));edit.bezelStyle = .rounded;edit.frame = CGRect(x:15,y:379,width:201,height:26);addSubview(edit)
            } else if page.isBackground == true { label("Shared background page",18,352,200,size:11) }
        }
    }
    @objc private func fieldChanged(_ sender:NSTextField) {
        guard let editor = editor,let key = sender.identifier?.rawValue else { return }
        let raw = sender.stringValue
        if currentKey == "node" {
            if key == "Text" { editor.modifySelection("Edit Text") { $0.text = raw }; return }
            if key == "Font" { editor.modifySelection("Font") { $0.formatting.fontName = raw.isEmpty ? "System" : raw }; return }
            let number:Double
            if let plain = Double(raw),plain.isFinite { number = plain }
            else if let parsed = try? ShapeSheet.evaluate(raw,resolve:{_ in throw DiagramError.invalid("Use the ShapeSheet editor for references.")}),parsed.isFinite { number = key == "Rotation" ? parsed*180 / .pi : parsed*72 }
            else { refresh();return }
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
            else if let width = Double(raw),width.isFinite { editor.modifyEdge("Line Width") { $0.width = max(0.5,min(20,width)) } }
        } else {
            if key == "Page name" { editor.configurePage(name:raw.isEmpty ? "Page" : raw) }
            else if let value = Double(raw),value.isFinite {
                if key == "Page width" { editor.configurePage(width:value/editor.diagramDocument.diagram.page.paperScale) }
                if key == "Page height" { editor.configurePage(height:value/editor.diagramDocument.diagram.page.paperScale) }
            }
        }
    }
    @objc private func colorChanged(_ sender:NSColorWell) {
        guard let editor = editor,let key = sender.identifier?.rawValue else { return }
        applying = true; defer { applying = false }
        if currentKey == "edge" { editor.modifyEdge("Connector Color") { $0.color = sender.color.hexString } }
        else { editor.modifySelection("Shape Color") { n in if key == "Fill" { n.fill = sender.color.hexString }; if key == "Line" { n.stroke = sender.color.hexString }; if key == "Text color" { n.textColor = sender.color.hexString } } }
    }
    @objc private func boldChanged(_ sender:NSButton) { editor?.modifySelection("Bold Text") { $0.bold = sender.state == .on } }
    @objc private func italicChanged(_ sender:NSButton) { editor?.modifySelection("Italic Text") { $0.formatting.italic = sender.state == .on } }
    @objc private func underlineChanged(_ sender:NSButton) { editor?.modifySelection("Underline Text") { $0.formatting.underline = sender.state == .on } }
    @objc private func alignmentChanged(_ sender:NSPopUpButton) { editor?.modifySelection("Text Alignment") { $0.formatting.alignment = sender.indexOfSelectedItem == 0 ? .left : sender.indexOfSelectedItem == 2 ? .right : .center } }
    @objc private func patternChanged(_ sender:NSPopUpButton) { editor?.modifySelection("Line Pattern") { $0.formatting.linePattern = sender.indexOfSelectedItem+1 } }
    @objc private func layerChanged(_ sender:NSPopUpButton) { editor?.modifySelection("Shape Layer") { $0.layer = sender.titleOfSelectedItem ?? "Default"; $0.formatting.layerNames = [$0.layer] } }
    @objc private func routeChanged(_ sender:NSPopUpButton) { editor?.modifyEdge("Connector Style") { $0.style = sender.indexOfSelectedItem == 0 ? .orthogonal : .straight;$0.points = nil } }
    @objc private func arrowChanged(_ sender:NSButton) { editor?.modifyEdge("Connector Arrow") { $0.arrow = sender.state == .on } }
    @objc private func startArrowChanged(_ sender:NSButton) { editor?.modifyEdge("Connector Start Arrow") { $0.startArrow = sender.state == .on } }
    @objc private func edgePatternChanged(_ sender:NSPopUpButton) { editor?.modifyEdge("Connector Line Pattern") { $0.dash = sender.indexOfSelectedItem+1 } }
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
    private var zoomMinus:NSButton!
    private var zoomPlus:NSButton!
    private var fit:NSButton!
    private var addPageButton:NSButton!
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
        [status,snapButton,zoomMinus,zoomLabel,zoomPlus,fit].forEach{footer.addSubview($0)}
        importNotesButton.target = editor;importNotesButton.action = #selector(EditorWindowController.showImportNotes(_:))
        importNotesButton.bezelStyle = .recessed;importNotesButton.font = .systemFont(ofSize:11)
        importNotesButton.identifier = NSUserInterfaceItemIdentifier("importNotes")
        importNotesButton.setAccessibilityLabel("View import compatibility notes")
        importNotesButton.toolTip = "This drawing has import compatibility limitations. Click to view the details."
        footer.addSubview(importNotesButton)
        refreshImportNotes()
        addSubview(addPageButton)
        refreshAppearance()
    }
    required init?(coder:NSCoder) { fatalError() }
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
        let w = bounds.width,h = bounds.height,left = 224.0,right = 248.0,top = 144.0,bottom = 30.0,pages = 33.0
        let bodyHeight = max(1,h-top-bottom-1)
        ribbon.frame = CGRect(x:0,y:0,width:w,height:top)
        stencil.frame = CGRect(x:0,y:top+1,width:left,height:bodyHeight)
        inspectorScroll.frame = CGRect(x:w-right,y:top+1,width:right,height:bodyHeight)
        inspector.frame.size = CGSize(width:right,height:max(1100,inspectorScroll.contentSize.height))
        editor.scrollView.frame = CGRect(x:left+1,y:top+1,width:max(1,w-left-right-2),height:max(1,bodyHeight-pages-1))
        pageScroll.frame = CGRect(x:left+1,y:h-bottom-pages,width:max(1,w-left-right-36),height:pages)
        addPageButton.frame = CGRect(x:w-right-33,y:h-bottom-pages+3,width:30,height:27)
        footer.frame = CGRect(x:0,y:h-bottom,width:w,height:bottom)
        status.frame = CGRect(x:16,y:8,width:max(150,w-(importNotesButton.isHidden ? 420 : 600)),height:17)
        importNotesButton.frame = CGRect(x:w-552,y:3,width:180,height:24)
        snapButton.frame = CGRect(x:w-358,y:4,width:112,height:22)
        zoomMinus.frame = CGRect(x:w-236,y:3,width:28,height:24)
        zoomLabel.frame = CGRect(x:w-202,y:7,width:48,height:17);zoomLabel.alignment = .center
        zoomPlus.frame = CGRect(x:w-149,y:3,width:28,height:24)
        fit.frame = CGRect(x:w-106,y:3,width:39,height:24)
        refreshPages();editor.canvas.refreshSize()
    }
    func refreshPages() {
        guard let editor else{return}
        for view in pageStrip.subviews { view.removeFromSuperview() }
        var x = 0.0
        for page in editor.diagramDocument.diagram.orderedPages {
            let button = PageTabButton(title:page.name+(page.isBackground == true ? " ◇" : ""),target:self,action:#selector(pageClicked(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(page.id.uuidString)
            button.isCurrent = page.id == editor.diagramDocument.diagram.activePageID
            button.setAccessibilityLabel("Page \(page.name)");button.setAccessibilityValue(button.isCurrent ? "Selected" : "")
            button.toolTip = page.isBackground == true ? "Edit shared background" : "Edit page"
            let width = min(180,max(90,(page.name as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:11)]).width+32))
            button.frame = CGRect(x:x,y:0,width:width,height:33);pageStrip.addSubview(button);x += width+1
        }
        pageStrip.frame = CGRect(x:0,y:0,width:max(x,pageScroll.contentSize.width),height:33)
    }
    func refreshImportNotes() {
        let count = editor?.diagramDocument.importWarnings.count ?? 0
        importNotesButton.isHidden = count == 0
        importNotesButton.title = "Import notes (\(count))"
        needsLayout = true
    }
    func showMessage(_ text:String) {
        status.stringValue = text
        DispatchQueue.main.asyncAfter(deadline:.now()+5){[weak self] in self?.editor?.updateStatus()}
    }
    @objc private func pageClicked(_ sender:NSButton) {
        if let raw = sender.identifier?.rawValue,let id = UUID(uuidString:raw){editor?.switchPage(id)}
    }
}
