import AppKit
import UniformTypeIdentifiers

extension EditorWindowController {
    @objc func exportSelectionStencil(_ sender:Any?) {
        canvas.finishEditing(commit:true)
        guard !canvas.selectedNodes.isEmpty || canvas.selectedEdge != nil,let window = window else { return }
        let diagram = diagramDocument.diagram,page = diagram.page
        let ids = DiagramOperations.expandedSelection(canvas.selectedNodes,in:page)
        let binding = diagram.visioArchive?.pages.first{$0.pageID == page.id}
        let fragment = DiagramOperations.fragment(ids,edges:canvas.selectedEdge.map{Set([$0])} ?? [],from:page,binding:binding)
        let panel = NSSavePanel();panel.allowedContentTypes = [UTType(filenameExtension:"vssx") ?? .data];panel.nameFieldStringValue = "\(diagram.title).vssx"
        panel.message = "Save the selection as one reusable master. Supported geometry, text, images, data and connection points are included."
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let url = panel.url,let self = self else { return }
            do { let title = fragment.nodes.first(where:{$0.parentID == nil})?.text ?? "";let master = StencilDefinition(name:title.isEmpty ? "Selection" : title,family:diagram.title,fragment:fragment);try VisioReusableFormat.writeStencil([master],to:url);self.root.showMessage("Exported \(url.lastPathComponent)") } catch { self.presentError(error) }
        }
    }
    @objc func editConnectionPoints(_ sender:Any?) {
        guard selection.count == 1,let node = selection.first,!diagramDocument.diagram.page.isLocked(node) else { return }
        let grid = PropertyGrid(columns:["Name","Index","X","X Formula","Y","Y Formula","Dir X","Dir Y","Type"],rows:node.formatting.connectionPoints.map{[$0.name ?? "",String($0.index),$0.x.value,$0.x.formula,$0.y.value,$0.y.formula,String($0.directionX),String($0.directionY),String($0.type)]},width:1080)
        guard grid.run(title:"Connection Points",message:"X and Y use local inches measured from the shape's lower-left corner. Values accept units such as 72pt or 2cm. Formulas can use Width, Height and numeric ShapeSheet cells. Indexes start at zero. Type: 0 inward, 1 outward, 2 both.") else { return }
        do {
            var points:[ShapeConnectionPoint] = []
            for row in grid.rows where !row.allSatisfy({$0.isEmpty}) {
                guard let index = UInt32(row[1]),let dx = Double(row[6].isEmpty ? "0" : row[6]),let dy = Double(row[7].isEmpty ? "0" : row[7]),let type = Int(row[8].isEmpty ? "0" : row[8]) else { throw DiagramError.invalid("Connection-point indexes, directions and types must be numeric.") }
                func cell(_ value:String,_ formula:String) throws -> ShapeSheetCell { let number = try ShapeSheet.evaluate(value){_ in throw DiagramError.invalid("Put references in the Formula column.") };return ShapeSheetCell(value:ShapeSheetEngine.format(number),formula:formula) }
                points.append(ShapeConnectionPoint(index:index,name:row[0].isEmpty ? nil : row[0],x:try cell(row[2],row[3]),y:try cell(row[4],row[5]),directionX:dx,directionY:dy,type:type))
            }
            try setConnectionPoints(points,for:node.id)
        } catch { presentError(error) }
    }
    @objc func openStencil(_ sender:Any?) {
        let panel = NSOpenPanel();panel.allowedContentTypes = ["vssx","vss"].map{UTType(filenameExtension:$0) ?? .data};panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return };for url in panel.urls { loadStencil(url) }
    }
    func loadStencil(_ url:URL) {
        do {
            let result = try VisioStencil.read(from:url)
            stencils.append(contentsOf:result.items);root.stencil.refreshCategories(selecting:result.items.first?.family)
            if !result.warnings.isEmpty { let alert = NSAlert();alert.messageText = "Stencil import notes";alert.informativeText = result.warnings.prefix(8).joined(separator:"\n");alert.beginSheetModal(for:window!) }
        } catch { presentError(error) }
    }
}

/// A transactional native editor used by shape data, hyperlinks and layers.
/// Changes are applied to the diagram only after the dialog's Apply action.
final class PropertyGrid: FlippedView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let columns: [String]
    var rows: [[String]]
    let table = NSTableView()
    init(columns:[String],rows:[[String]],width:CGFloat = 700) {
        self.columns = columns; self.rows = rows; super.init(frame:CGRect(x:0,y:0,width:width,height:300))
        let scroll = NSScrollView(frame:CGRect(x:0,y:0,width:width,height:260)); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table; addSubview(scroll)
        for (i,title) in columns.enumerated() { let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(String(i))); column.title = title; column.width = max(90,width/CGFloat(columns.count)-4); column.minWidth = 60; table.addTableColumn(column) }
        table.delegate = self; table.dataSource = self; table.usesAlternatingRowBackgroundColors = true; table.rowHeight = 27; table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let add = NSButton(title:"Add",target:self,action:#selector(addRow(_:))); add.bezelStyle = .rounded; add.frame = CGRect(x:0,y:270,width:80,height:26); addSubview(add)
        let remove = NSButton(title:"Remove",target:self,action:#selector(removeRow(_:))); remove.bezelStyle = .rounded; remove.frame = CGRect(x:90,y:270,width:90,height:26); addSubview(remove)
    }
    required init?(coder:NSCoder) { fatalError() }
    func numberOfRows(in tableView:NSTableView) -> Int { rows.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue,let index = Int(id) else { return nil }
        let field = NSTextField(string:rows[row].indices.contains(index) ? rows[row][index] : ""); field.isBordered = false; field.drawsBackground = false; field.font = .systemFont(ofSize:12); field.identifier = NSUserInterfaceItemIdentifier(id); field.tag = row; field.delegate = self; field.target = self; field.action = #selector(changed(_:)); return field
    }
    @objc func changed(_ sender:NSTextField) { guard rows.indices.contains(sender.tag),let index = Int(sender.identifier?.rawValue ?? ""),rows[sender.tag].indices.contains(index) else { return }; rows[sender.tag][index] = sender.stringValue }
    func controlTextDidEndEditing(_ obj:Notification) { if let field = obj.object as? NSTextField { changed(field) } }
    @objc func addRow(_ sender:Any?) { window?.makeFirstResponder(table); rows.append(Array(repeating:"",count:columns.count)); table.reloadData(); table.selectRowIndexes(IndexSet(integer:rows.count-1),byExtendingSelection:false) }
    @objc func removeRow(_ sender:Any?) { window?.makeFirstResponder(table); let row = table.selectedRow; guard rows.indices.contains(row) else { return }; rows.remove(at:row); table.reloadData() }
    func run(title:String,message:String = "") -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.accessoryView = self; alert.addButton(withTitle:"Apply"); alert.addButton(withTitle:"Cancel")
        let result = alert.runModal(); window?.makeFirstResponder(nil); return result == .alertFirstButtonReturn
    }
}

extension EditorWindowController {
    @objc func groupSelection(_ sender:Any?) {
        canvas.finishEditing(commit:true)
        do { var next = diagramDocument.diagram;let binding = next.visioArchive?.pages.first{$0.pageID == next.page.id};let id = try DiagramOperations.group(canvas.selectedNodes,in:&next.page,binding:binding); diagramDocument.replace(with:try next.validated(),action:"Group Shapes"); canvas.select([id]) } catch { presentError(error) }
    }
    @objc func ungroupSelection(_ sender:Any?) {
        canvas.finishEditing(commit:true); var next = diagramDocument.diagram
        let ids = DiagramOperations.ungroup(canvas.selectedNodes,in:&next.page); diagramDocument.replace(with:next,action:"Ungroup Shapes"); canvas.select(ids)
    }
    @objc func flipHorizontal(_ sender:Any?) { modifySelection("Flip Horizontal") { $0.formatting.flipX.toggle() } }
    @objc func flipVertical(_ sender:Any?) { modifySelection("Flip Vertical") { $0.formatting.flipY.toggle() } }
    @objc func rotateLeft(_ sender:Any?) { modifySelection("Rotate Left") { $0.rotation = ($0.rotation-90).truncatingRemainder(dividingBy:360) } }
    @objc func rotateRight(_ sender:Any?) { modifySelection("Rotate Right") { $0.rotation = ($0.rotation+90).truncatingRemainder(dividingBy:360) } }
    @objc func editShapeData(_ sender:Any?) {
        guard let node = selection.first,selection.count == 1,!diagramDocument.diagram.page.isLocked(node) else { return }
        let data = node.formatting.data
        let grid = PropertyGrid(columns:["Key","Label","Value","Type","Format","Prompt"],rows:data.map{[$0.key,$0.label,$0.value,String($0.type),$0.format,$0.prompt]},width:820)
        guard grid.run(title:"Shape Data",message:"Type: 0 text · 1 list · 2 number · 3 Boolean · 5 date. Values and definitions are stored in the Visio shape.") else { return }
        let properties = grid.rows.filter{!$0[0].isEmpty}.map{ShapeDataProperty(key:$0[0],label:$0[1],value:$0[2],type:Int($0[3]) ?? 0,format:$0[4],prompt:$0[5])}
        guard Set(properties.map(\.key)).count == properties.count else { presentError(DiagramError.invalid("Each Shape Data key must be unique.")); return }
        modifySelection("Shape Data") { $0.formatting.data = properties }
    }
    @objc func editHyperlinks(_ sender:Any?) {
        guard let node = selection.first,selection.count == 1,!diagramDocument.diagram.page.isLocked(node) else { return }
        let grid = PropertyGrid(columns:["Address","Sub-address","Description"],rows:node.formatting.hyperlinks.map{[$0.address,$0.subAddress,$0.description]})
        guard grid.run(title:"Shape Hyperlinks") else { return }
        let links = grid.rows.filter{!$0[0].isEmpty || !$0[1].isEmpty}.map{ShapeHyperlink(address:$0[0],subAddress:$0[1],description:$0[2])}
        modifySelection("Hyperlinks") { $0.formatting.hyperlinks = links }
    }
    @objc func followHyperlink(_ sender:Any?) {
        guard let link = selection.first?.formatting.hyperlinks.first else { return }
        if link.address.isEmpty,let page = diagramDocument.diagram.pages.first(where:{$0.name == link.subAddress}) { switchPage(page.id); return }
        guard let url = URL(string:link.address),["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") else { return }; NSWorkspace.shared.open(url)
    }
    @objc func editLayers(_ sender:Any?) {
        let layers = diagramDocument.diagram.page.layers ?? [DiagramLayer(name:"Default")]
        let grid = PropertyGrid(columns:["Name","Visible","Locked","Print"],rows:layers.map{[$0.name,$0.visible ? "Yes" : "No",$0.locked ? "Yes" : "No",$0.printable ? "Yes" : "No"]},width:640)
        guard grid.run(title:"Drawing Layers",message:"Use Yes / No for visibility, locking and printing. Assign shapes to a layer in the inspector.") else { return }
        func yes(_ value:String,_ fallback:Bool) -> Bool { value.isEmpty ? fallback : ["yes","true","1","on"].contains(value.lowercased()) }
        let updated = grid.rows.filter{!$0[0].isEmpty}.map { row -> DiagramLayer in
            var layer = layers.first(where:{$0.name == row[0]}) ?? DiagramLayer(name:row[0]); layer.visible = yes(row[1],true); layer.locked = yes(row[2],false); layer.printable = yes(row[3],true); return layer
        }
        guard Set(updated.map(\.name)).count == updated.count else { presentError(DiagramError.invalid("Layer names must be unique.")); return }
        var next = diagramDocument.diagram; next.page.layers = updated
        let names = Set(updated.map(\.name))
        for i in next.page.nodes.indices { if !names.contains(next.page.nodes[i].layer) { next.page.nodes[i].layer = "Default" }; next.page.nodes[i].formatting.layerNames.removeAll{!names.contains($0)} }
        diagramDocument.replace(with:next,action:"Layer Properties")
    }
    @objc func insertImage(_ sender:Any?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,.tiff,.gif,.bmp,.pdf]
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { try insertImage(data:Data(contentsOf:url)) } catch { presentError(error) }
    }
    func insertImage(data:Data) throws {
        guard data.count <= VisioPackage.partLimit,let image = NSImage(data:data),image.size.width > 0,image.size.height > 0,
              let cgImage = image.cgImage(forProposedRect:nil,context:nil,hints:nil),cgImage.width*cgImage.height <= 50000000,
              let png = NSBitmapImageRep(cgImage:cgImage).representation(using:.png,properties:[:]),png.count <= VisioPackage.partLimit else { throw DiagramError.invalid("This image cannot be inserted or is too large.") }
        let page = diagramDocument.diagram.page,maxWidth = min(480,page.paperWidth-40),maxHeight = min(360,page.paperHeight-40)
        let scale = min(maxWidth/image.size.width,maxHeight/image.size.height,1)
        var node = DiagramNode(x:40/page.paperScale,y:40/page.paperScale,text:""); node.width = max(1,image.size.width*scale)/page.paperScale; node.height = max(1,image.size.height*scale)/page.paperScale; node.fill = "#FFFFFF00"; node.stroke = "#FFFFFF00"; node.formatting.image = EmbeddedImage(data:png,mimeType:"image/png")
        var next = diagramDocument.diagram; next.page.nodes.append(node); diagramDocument.replace(with:next,action:"Insert Image"); canvas.select([node.id])
    }
    @objc func findShapes(_ sender:Any?) {
        let alert = NSAlert(); alert.messageText = "Find Shapes"; alert.addButton(withTitle:"Find All"); alert.addButton(withTitle:"Cancel")
        let text = NSTextField(frame:CGRect(x:0,y:0,width:320,height:24)); text.placeholderString = "Shape text or Shape Data"; alert.accessoryView = text
        guard alert.runModal() == .alertFirstButtonReturn,!text.stringValue.isEmpty else { return }
        let query = text.stringValue
        let nodes = diagramDocument.diagram.page.nodes.filter{$0.text.localizedCaseInsensitiveContains(query) || $0.formatting.data.contains{$0.value.localizedCaseInsensitiveContains(query)}}
        canvas.select(Set(nodes.map(\.id))); if let node = nodes.first { canvas.scrollToVisible(CGRect(x:canvas.pageOrigin.x+node.x*canvas.zoom,y:canvas.pageOrigin.y+node.y*canvas.zoom,width:node.width*canvas.zoom,height:node.height*canvas.zoom)) }
    }
    func addFreeLine(from start:CGPoint,to end:CGPoint) {
        var edge = DiagramEdge(source:UUID(),target:UUID()); edge.sourcePosition = DiagramPoint(start); edge.targetPosition = DiagramPoint(end); edge.style = .straight; edge.arrow = false
        var next = diagramDocument.diagram; next.page.edges.append(edge); diagramDocument.replace(with:next,action:"Draw Line"); canvas.select([],edge:edge.id)
    }
    @objc func lineTool(_ sender:Any?) { setTool(.line) }
    @objc func showShapeSheet(_ sender:Any?) {
        guard selection.count == 1,let selected = selection.first,!diagramDocument.diagram.page.isLocked(selected) else { return }
        var next = diagramDocument.diagram
        let binding = next.visioArchive?.pages.first(where:{$0.pageID == next.page.id})
        do {
            let reserved = next.page.nodes.compactMap{$0.formatting.sourceShapeID}+next.page.edges.compactMap(\.sourceShapeID)+(binding?.nodeIDs.values.map{$0} ?? [])+(binding?.edgeIDs.values.map{$0} ?? [])
            var allocator = try VisioIDAllocator(reserved:reserved)
            for i in next.page.nodes.indices where next.page.nodes[i].formatting.sourceShapeID == nil { next.page.nodes[i].formatting.sourceShapeID = try binding?.nodeIDs[next.page.nodes[i].id] ?? allocator.allocate() }
        } catch { presentError(error);return }
        guard let index = next.page.nodes.firstIndex(where:{$0.id == selected.id}) else { return }
        var cells = selected.formatting.sheet
        for (key,value) in ShapeSheetEngine.defaults(selected,page:next.page) where cells[key] == nil { cells[key] = ShapeSheetCell(value:ShapeSheetEngine.format(value)) }
        if selected.formatting.sheet["LocPinX"] == nil { cells["LocPinX"]?.formula = "Width*0.5" };if selected.formatting.sheet["LocPinY"] == nil { cells["LocPinY"]?.formula = "Height*0.5" }
        let editable = cells.filter { ShapeSheetEngine.geometryKeys.contains($0.key) || ShapeSheetEngine.textKeys.contains($0.key) || $0.key.hasPrefix("User.") || $0.key.hasPrefix("Prop.") }
        let grid = PropertyGrid(columns:["Cell","Cached value","Formula","Unit"],rows:editable.keys.sorted().map{[$0,editable[$0]!.value,editable[$0]!.formula,editable[$0]!.unit]},width:900)
        guard grid.run(title:"ShapeSheet — Sheet.\(next.page.nodes[index].formatting.sourceShapeID ?? "")",message:"Lengths use inches and angles use radians internally. STR stores text; DATE stores dates. Formulas can reference text, properties, controls, geometry and other shapes. Unsupported formulas retain their cached value.") else { return }
        let names = grid.rows.map{$0[0].trimmingCharacters(in:.whitespacesAndNewlines)}
        guard Set(names.map{$0.lowercased()}).count == names.count else { presentError(DiagramError.invalid("Cell names must be unique."));return }
        do {
            for row in grid.rows {
                let key = row[0].trimmingCharacters(in:.whitespacesAndNewlines)
                if editable[key]?.value == row[1] && editable[key]?.formula == row[2] && editable[key]?.unit == row[3] { continue }
                try SheetCellEditing.set(key,value:row[1],formula:row[2],unit:row[3],on:&next.page.nodes[index])
            }
            let before = Set(DiagramCalculation.recalculate(diagramDocument.diagram).issues),calculation = DiagramCalculation.recalculate(next,previous:diagramDocument.diagram)
            let newIssues = Set(calculation.issues).subtracting(before)
            guard newIssues.isEmpty else { throw DiagramError.invalid(newIssues.sorted().prefix(4).joined(separator:"\n")) }
            diagramDocument.replace(with:try calculation.diagram.validated(),action:"Edit ShapeSheet")
        } catch { presentError(error) }
    }
}
