import MacVisioInfrastructure
import AppKit
import UniformTypeIdentifiers

enum LayerPropertiesEditing {
    static func apply(_ rows:[[String]],previous:[DiagramLayer]) throws -> [DiagramLayer] {
        func text(_ row:[String],_ index:Int) -> String { row.indices.contains(index) ? row[index].trimmingCharacters(in:.whitespacesAndNewlines) : "" }
        func yes(_ value:String,_ fallback:Bool) -> Bool { value.isEmpty ? fallback : ["yes","true","1","on"].contains(value.lowercased()) }
        let updated = try rows.enumerated().filter{!text($0.element,0).isEmpty}.map { index,row in
            let name = text(row,0)
            let old = previous.first(where:{$0.name == name}) ?? (rows.count == previous.count && previous.indices.contains(index) ? previous[index] : nil)
            var layer = old ?? DiagramLayer(name:name)
            layer.visible = yes(text(row,1),true);layer.locked = yes(text(row,2),false);layer.printable = yes(text(row,3),true);layer.snap = yes(text(row,4),true);layer.glue = yes(text(row,5),true)
            let color = text(row,6)
            if color.isEmpty || color.caseInsensitiveCompare("none") == .orderedSame { layer.color = nil }
            else {
                let digits = color.hasPrefix("#") ? String(color.dropFirst()) : color
                guard digits.count == 6,digits.allSatisfy({$0.isHexDigit}) else { throw DiagramError.invalid("Layer colors must be six-digit RGB hex values, or blank for no color.") }
                layer.color = "#"+digits.uppercased()
            }
            let transparency = text(row,7)
            if !transparency.isEmpty {
                guard let value = Double(transparency),value.isFinite,(0...100).contains(value) else { throw DiagramError.invalid("Layer color transparency must be a number from 0 to 100.") }
                layer.colorTransparency = value
            }
            return layer
        }
        guard Set(updated.map(\.name)).count == updated.count else { throw DiagramError.invalid("Layer names must be unique.") }
        return updated
    }
}

extension EditorWindowController {
    @objc func exportSelectionStencil(_ sender:Any?) {
        canvas.finishEditing(commit:true)
        guard !canvas.selectedNodes.isEmpty || canvas.selectedEdge != nil,let window = window else { return }
        let diagram = diagramDocument.diagram,page = diagram.page
        let snapshotStateID = diagramDocument.stateID,snapshotRevision = diagramDocument.revision,sourceURL = diagramDocument.fileURL
        let ids = DiagramOperations.expandedSelection(canvas.selectedNodes,in:page)
        let binding = diagram.visioArchive?.pages.first{$0.pageID == page.id}
        let fragment = DiagramOperations.fragment(ids,edges:canvas.selectedEdge.map{Set([$0])} ?? [],from:page,binding:binding)
        let panel = NSSavePanel();panel.allowedContentTypes = [UTType(filenameExtension:"vssx") ?? .data];panel.nameFieldStringValue = "\(diagram.title).vssx"
        panel.message = "Save the selection as one reusable master. Supported geometry, text, images, data and connection points are included."
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let url = panel.url,let self = self else { return }
            let owner = self.lifecycleJobs
            let progress = LifecycleProgressController(title:"Exporting stencil",detail:url.lastPathComponent)
            let input = LifecycleJobInput(ownerID:owner.id,snapshotID:snapshotStateID,revision:snapshotRevision)
            do {
                let title = fragment.nodes.first(where:{$0.parentID == nil})?.text ?? ""
                let master = StencilDefinition(name:title.isEmpty ? "Selection" : title,family:diagram.title,fragment:fragment)
                let handle = try OwnedExportJobs.submitStencil(definitions:[master],input:input,sourceURL:sourceURL,
                                                              destination:url,owner:owner,progress:{progress.update($0)}) { [weak self] result in
                    progress.finish()
                    switch result {
                    case .success: self?.root.showMessage("Exported \(url.lastPathComponent)")
                    case .failure(let error):
                        if (error as? LifecycleJobError) != .cancelled && (error as? LifecycleJobError) != .staleInput { self?.presentError(error) }
                    }
                }
                progress.onCancel = { [weak handle] in handle?.cancel() }
                progress.show()
            } catch { progress.finish();self.presentError(error) }
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
    func loadStencil(_ url:URL,completion:((Error?)->Void)? = nil) {
        let owner = lifecycleJobs
        let jobID = UUID()
        let input = LifecycleJobInput(ownerID:owner.id,snapshotID:diagramDocument.stateID,revision:diagramDocument.revision)
        let progress = LifecycleProgressController(title:"Loading stencil",detail:url.lastPathComponent)
        do {
            let handle = try LifecycleJobService.shared.submit(id:jobID,kind:.library,input:input,accepts:{ [weak self] candidate in
                self != nil && owner.isActive && candidate.ownerID == owner.id
            },progress:{ progress.update($0) },work:{ context in
                context.progress("Reading \(url.lastPathComponent)")
                return try VisioStencil.read(from:url)
            },completion:{ [weak self] result in
                progress.finish()
                owner.finish(jobID)
                switch result {
                case .success(let imported):
                    guard let self,owner.isActive else { completion?(LifecycleJobError.staleInput);return }
                    self.stencils.append(contentsOf:imported.items)
                    self.root.stencil.refreshCategories(selecting:imported.items.first?.family)
                    if !imported.warnings.isEmpty,let window = self.window {
                        let alert = NSAlert();alert.messageText = "Stencil import notes"
                        alert.informativeText = imported.warnings.prefix(8).joined(separator:"\n")
                        alert.beginSheetModal(for:window)
                    }
                    completion?(nil)
                case .failure(let error):
                    if (error as? LifecycleJobError) != .cancelled && (error as? LifecycleJobError) != .staleInput { self?.presentError(error) }
                    completion?(error)
                }
            })
            owner.track(handle)
            progress.onCancel = { [weak handle] in handle?.cancel() }
            progress.show()
        } catch { progress.finish();presentError(error);completion?(error) }
    }
}

/// A transactional native editor used by shape data, hyperlinks and layers.
/// Changes are applied to the diagram only after the dialog's Apply action.
final class PropertyGrid: FlippedView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let columns: [String]
    var rows: [[String]]
    let table = NSTableView()
    private let editsShapeData:Bool
    init(columns:[String],rows:[[String]],width:CGFloat = 700,editsShapeData:Bool = false) {
        self.columns = columns; self.rows = rows; self.editsShapeData = editsShapeData; super.init(frame:CGRect(x:0,y:0,width:width,height:300))
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
        if editsShapeData,index == 3 { return shapeDataTypeEditor(row:row) }
        if editsShapeData,index == 2 { return shapeDataValueEditor(row:row) }
        let field = NSTextField(string:rows[row].indices.contains(index) ? rows[row][index] : ""); field.isBordered = false; field.drawsBackground = false; field.font = .systemFont(ofSize:12); field.identifier = NSUserInterfaceItemIdentifier(id); field.tag = row; field.delegate = self; field.target = self; field.action = #selector(changed(_:)); return field
    }
    private func shapeDataTypeEditor(row:Int) -> NSView {
        let popup = NSPopUpButton(frame:.zero,pullsDown:false)
        let value = Int(rows[row].indices.contains(3) ? rows[row][3] : "") ?? 0
        for type in ShapeDataEditing.supportedTypes {
            popup.addItem(withTitle:"\(type) · \(ShapeDataEditing.typeNames[type])")
            popup.lastItem?.representedObject = NSNumber(value:type)
        }
        if !ShapeDataEditing.supportedTypes.contains(value) {
            popup.addItem(withTitle:"\(value) · Other")
            popup.lastItem?.representedObject = NSNumber(value:value)
        }
        if let item = popup.itemArray.first(where:{($0.representedObject as? NSNumber)?.intValue == value}) { popup.select(item) }
        popup.identifier = NSUserInterfaceItemIdentifier("3");popup.tag = row;popup.target = self;popup.action = #selector(shapeDataTypeChanged(_:))
        return popup
    }
    private func shapeDataValueEditor(row:Int) -> NSView? {
        guard rows[row].count > 3,let type = Int(rows[row][3]) else { return nil }
        let value = rows[row][2]
        if type == 1 || type == 3 {
            let popup = NSPopUpButton(frame:.zero,pullsDown:false)
            var choices = type == 1 ? ShapeDataEditing.formatChoices(rows[row][4]) : ["TRUE","FALSE"]
            let display = type == 3 ? booleanDisplay(value) : value
            if !display.isEmpty && !choices.contains(display) { choices.append(display) }
            if display.isEmpty || choices.isEmpty { choices.insert("",at:0) }
            popup.addItems(withTitles:choices)
            popup.selectItem(withTitle:display)
            popup.identifier = NSUserInterfaceItemIdentifier("2");popup.tag = row;popup.target = self;popup.action = #selector(shapeDataValueChanged(_:))
            return popup
        }
        if type == 4 {
            let combo = NSComboBox(frame:.zero)
            combo.addItems(withObjectValues:ShapeDataEditing.formatChoices(rows[row][4]))
            combo.stringValue = value;combo.isBordered = false;combo.drawsBackground = false;combo.font = .systemFont(ofSize:12);combo.identifier = NSUserInterfaceItemIdentifier("2");combo.tag = row;combo.target = self;combo.action = #selector(changed(_:))
            return combo
        }
        let field = NSTextField(string:value)
        field.isBordered = false;field.drawsBackground = false;field.font = .systemFont(ofSize:12)
        field.identifier = NSUserInterfaceItemIdentifier("2");field.tag = row;field.delegate = self;field.target = self;field.action = #selector(changed(_:))
        return field
    }
    private func booleanDisplay(_ value:String) -> String {
        switch value.trimmingCharacters(in:.whitespacesAndNewlines).uppercased() { case "1","TRUE":return "TRUE";case "0","FALSE":return "FALSE";default:return value }
    }
    @objc func changed(_ sender:NSTextField) { guard rows.indices.contains(sender.tag),let index = Int(sender.identifier?.rawValue ?? ""),rows[sender.tag].indices.contains(index) else { return }; rows[sender.tag][index] = sender.stringValue }
    @objc private func shapeDataTypeChanged(_ sender:NSPopUpButton) {
        guard rows.indices.contains(sender.tag),rows[sender.tag].indices.contains(3),let type = sender.selectedItem?.representedObject as? NSNumber else { return }
        rows[sender.tag][3] = type.stringValue
        table.reloadData(forRowIndexes:IndexSet(integer:sender.tag),columnIndexes:IndexSet(integersIn:2...3))
    }
    @objc private func shapeDataValueChanged(_ sender:NSPopUpButton) {
        guard rows.indices.contains(sender.tag),rows[sender.tag].indices.contains(2) else { return }
        rows[sender.tag][2] = sender.titleOfSelectedItem ?? ""
    }
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
        do { var next = diagramDocument.diagram;let binding = next.visioArchive?.pages.first{$0.pageID == next.page.id};let id = try DiagramOperations.group(canvas.selectedNodes,in:&next.page,binding:binding); diagramDocument.replaceInEditor(with:try next.validated(),action:"Group Shapes"); canvas.select([id]) } catch { presentError(error) }
    }
    @objc func ungroupSelection(_ sender:Any?) {
        canvas.finishEditing(commit:true); var next = diagramDocument.diagram
        let ids = DiagramOperations.ungroup(canvas.selectedNodes,in:&next.page); diagramDocument.replaceInEditor(with:next,action:"Ungroup Shapes"); canvas.select(ids)
    }
    @objc func flipHorizontal(_ sender:Any?) { modifySelection("Flip Horizontal") { $0.formatting.flipX.toggle() } }
    @objc func flipVertical(_ sender:Any?) { modifySelection("Flip Vertical") { $0.formatting.flipY.toggle() } }
    @objc func rotateLeft(_ sender:Any?) { modifySelection("Rotate Left") { $0.rotation = ($0.rotation-90).truncatingRemainder(dividingBy:360) } }
    @objc func rotateRight(_ sender:Any?) { modifySelection("Rotate Right") { $0.rotation = ($0.rotation+90).truncatingRemainder(dividingBy:360) } }
    @objc func editShapeData(_ sender:Any?) {
        guard let node = selection.first,selection.count == 1,!diagramDocument.diagram.page.isLocked(node) else { return }
        let data = node.formatting.data
        let grid = PropertyGrid(columns:["Key","Label","Value","Type","Format","Prompt"],rows:data.map{[$0.key,$0.label,ShapeDataEditing.displayedValue($0),String($0.type),$0.format,$0.prompt]},width:820,editsShapeData:true)
        guard grid.run(title:"Shape Data",message:"Type 1 uses fixed choices from semicolon-separated Format entries; Type 4 lets you add choices there. Type 3 uses TRUE/FALSE. Type 2 accepts finite numbers and supported Visio measurements. Type 5 accepts ISO dates and date-times. Type 6 uses finite day values; Type 7 uses finite numeric currency amounts. Format pictures stay unchanged.") else { return }
        let entered = grid.rows.filter{!$0[0].isEmpty}.map{ShapeDataProperty(key:$0[0],label:$0[1],value:$0[2],type:Int($0[3]) ?? 0,format:$0[4],prompt:$0[5])}
        let properties:[ShapeDataProperty]
        do { properties = try ShapeDataEditing.validated(entered,previous:data) } catch { presentError(error); return }
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
        if let source = selection.first, BasicFlowchart.isOffPage(source) {
            guard let id = BasicFlowchart.targetID(for: source, in: diagramDocument.diagram), diagramDocument.diagram.pages.contains(where: { $0.id == id }) else {
                root.showMessage("The linked page no longer exists. Edit the off-page link."); return
            }
            switchPage(id); return
        }
        guard let link = selection.first?.formatting.hyperlinks.first else { return }
        if link.address.isEmpty,let page = diagramDocument.diagram.pages.first(where:{$0.name == link.subAddress}) { switchPage(page.id); return }
        guard let url = URL(string:link.address),["http","https","mailto"].contains(url.scheme?.lowercased() ?? "") else { return }; NSWorkspace.shared.open(url)
    }
    @objc func editLayers(_ sender:Any?) {
        let layers = diagramDocument.diagram.page.layers ?? [DiagramLayer(name:"Default")]
        let columns = ["Name","Visible","Locked","Print","Snap","Glue","Color (#RRGGBB)","Transparency (%)"]
        let grid = PropertyGrid(columns:columns,rows:layers.map{[$0.name,$0.visible ? "Yes" : "No",$0.locked ? "Yes" : "No",$0.printable ? "Yes" : "No",$0.snap ? "Yes" : "No",$0.glue ? "Yes" : "No",$0.color ?? "",String($0.colorTransparency)]},width:1050)
        guard grid.run(title:"Drawing Layers",message:"Snap lets other shapes align to shapes on the layer. Glue lets connectors attach to shapes on the layer. A color overrides a shape's colors when it belongs to exactly one layer; blank disables it. Enter six-digit RGB hex. Transparency is 0% opaque to 100% clear.") else { return }
        let updated:[DiagramLayer]
        do { updated = try LayerPropertiesEditing.apply(grid.rows,previous:layers) } catch { presentError(error); return }
        var next = diagramDocument.diagram; next.page.layers = updated
        let names = Set(updated.map(\.name))
        let renamed = Dictionary(uniqueKeysWithValues:layers.compactMap { old in updated.first(where:{$0.id == old.id}).map{(old.name,$0.name)} })
        for i in next.page.nodes.indices {
            next.page.nodes[i].layer = renamed[next.page.nodes[i].layer] ?? next.page.nodes[i].layer
            if !names.contains(next.page.nodes[i].layer) { next.page.nodes[i].layer = "Default" }
            next.page.nodes[i].formatting.layerNames = next.page.nodes[i].formatting.layerNames.map{renamed[$0] ?? $0}.filter{names.contains($0)}
        }
        for i in next.page.edges.indices { if let name = next.page.edges[i].layer { next.page.edges[i].layer = renamed[name] ?? (names.contains(name) ? name : nil) } }
        diagramDocument.replaceInEditor(with:next,action:"Layer Properties")
    }
    @objc func insertImage(_ sender:Any?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,.tiff,.gif,.bmp]
        panel.message = "Choose a single-frame raster image within the supported size limit."
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do {
            let source = url.resolvingSymlinksInPath().standardizedFileURL
            let metadata = try source.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
            guard metadata.isRegularFile == true, let size = metadata.fileSize, size <= VisioPackage.partLimit else { throw NativeImageDecoding.Failure.encodedLimit }
            try insertImage(data:Data(contentsOf:source,options:.mappedIfSafe))
        } catch { presentError(error) }
    }
    func insertImage(data:Data) throws {
        diagramDocument.commitTextEditing(); canvas.finishPageInteraction()
        guard !diagramDocument.isCalculating else { throw DiagramError.invalid("Wait for the current edit to finish before inserting an image.") }
        let decoded = try NativeImageDecoding.decode(data:data)
        let image = NSImage(cgImage:decoded.cgImage,size:decoded.pixelSize)
        guard let png = NSBitmapImageRep(cgImage:decoded.cgImage).representation(using:.png,properties:[:]),png.count <= VisioPackage.partLimit else { throw DiagramError.invalid("This image cannot be inserted or is too large.") }
        let page = diagramDocument.diagram.page,maxWidth = min(480,page.paperWidth-40),maxHeight = min(360,page.paperHeight-40)
        let scale = min(maxWidth/image.size.width,maxHeight/image.size.height,1)
        var node = DiagramNode(x:40/page.paperScale,y:40/page.paperScale,text:""); node.width = max(1,image.size.width*scale)/page.paperScale; node.height = max(1,image.size.height*scale)/page.paperScale; node.fill = "#FFFFFF00"; node.stroke = "#FFFFFF00"; node.formatting.image = EmbeddedImage(data:png,mimeType:"image/png")
        var next = diagramDocument.diagram; next.page.nodes.append(node); diagramDocument.replaceInEditor(with:next,action:"Insert Image"); canvas.select([node.id])
    }
    @objc func findShapes(_ sender:Any?) { showDocumentFind(sender) }
    func addFreeLine(from start:CGPoint,to end:CGPoint) {
        var edge = DiagramEdge(source:UUID(),target:UUID()); edge.sourcePosition = DiagramPoint(start); edge.targetPosition = DiagramPoint(end); edge.style = .straight; edge.arrow = false
        var next = diagramDocument.diagram; next.page.edges.append(edge); diagramDocument.replaceInEditor(with:next,action:"Draw Line"); canvas.select([],edge:edge.id)
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
            diagramDocument.replaceInEditor(with:try calculation.diagram.validated(),action:"Edit ShapeSheet")
        } catch { presentError(error) }
    }
}
