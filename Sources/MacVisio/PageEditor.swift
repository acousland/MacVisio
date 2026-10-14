import AppKit

extension EditorWindowController {
    func configurePage(name:String? = nil,width:Double? = nil,height:Double? = nil,isBackground:Bool? = nil,background:UUID?? = nil,scale:DrawingScale?? = nil) {
        canvas.finishPageInteraction();var next = diagramDocument.diagram
        do {
            try PageOperations.configure(next.page.id,in:&next,name:name,width:width,height:height,isBackground:isBackground,background:background,scale:scale)
            diagramDocument.replace(with:next,action:"Page Setup");canvas.fitPage()
        } catch { presentError(error) }
    }
    @objc func addBackgroundPage(_ sender:Any?) {
        canvas.finishPageInteraction();var next = diagramDocument.diagram
        do { try PageOperations.addBackground(to:next.page.id,in:&next);diagramDocument.replace(with:next,action:"Add Background Page");canvas.select([]);setTool(.pointer);canvas.fitPage() } catch { presentError(error) }
    }
    @objc func editBackgroundPage(_ sender:Any?) { if let id = diagramDocument.diagram.page.backgroundPageID { switchPage(id) } }
    @objc func matchBackgroundSize(_ sender:Any?) {
        canvas.finishPageInteraction();var next = diagramDocument.diagram
        guard let id = next.page.backgroundPageID else { return }
        do { let factor = next.pages.first{$0.id == id}!.paperScale;try PageOperations.configure(id,in:&next,width:next.page.paperWidth/factor,height:next.page.paperHeight/factor);diagramDocument.replace(with:next,action:"Match Background Size") } catch { presentError(error) }
    }
    @objc func showPageSetup(_ sender:Any?) {
        canvas.finishPageInteraction()
        let diagram = diagramDocument.diagram,page = diagram.page
        let view = FlippedView(frame:CGRect(x:0,y:0,width:420,height:300))
        func row(_ title:String,_ y:CGFloat,_ control:NSView) { let label = uiLabel(title);label.frame = CGRect(x:0,y:y+3,width:125,height:22);view.addSubview(label);control.frame = CGRect(x:130,y:y,width:280,height:26);view.addSubview(control) }
        let name = NSTextField(string:page.name),width = NSTextField(string:String(page.paperWidth)),height = NSTextField(string:String(page.paperHeight))
        let paperLength = NSTextField(string:"\(page.drawingScale?.page ?? 1) in"),drawingLength = NSTextField(string:"\(page.drawingScale?.drawing ?? 1) in")
        let kind = NSPopUpButton();kind.addItems(withTitles:["Foreground","Background"]);kind.selectItem(at:page.isBackground == true ? 1 : 0)
        let background = NSPopUpButton();background.addItem(withTitle:"None")
        for p in PageOperations.backgroundCandidates(for:page.id,in:diagram) { background.addItem(withTitle:p.name);background.lastItem?.representedObject = p.id.uuidString }
        if let id = page.backgroundPageID,let item = background.itemArray.first(where:{$0.representedObject as? String == id.uuidString}) { background.select(item) }
        row("Name",0,name);row("Paper width",38,width);row("Paper height",76,height);row("Page type",114,kind);row("Background",152,background);row("Scale: paper",190,paperLength);row("Scale: drawing",228,drawingLength)
        let hint = uiLabel("Paper sizes: points or units. Scale example: 1 cm on paper = 50 cm drawn.",size:10);hint.frame = CGRect(x:0,y:270,width:420,height:22);view.addSubview(hint)
        let alert = NSAlert();alert.messageText = "Page Setup";alert.informativeText = "Backgrounds are shared. Edit a background page to update every page using it.";alert.accessoryView = view;alert.addButton(withTitle:"Apply");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return };view.window?.makeFirstResponder(nil)
        func dimension(_ field:NSTextField,_ original:Double) throws -> Double {
            let text = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            if text == String(original) { return original };if let value = Double(text),value.isFinite { return value }
            return try ShapeSheet.evaluate(text){_ in throw DiagramError.invalid("Page sizes cannot refer to shape cells.") }*72
        }
        do {
            let target = (background.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:))
            var scale = DrawingScale(page:try dimension(paperLength,(page.drawingScale?.page ?? 1)*72)/72,drawing:try dimension(drawingLength,(page.drawingScale?.drawing ?? 1)*72)/72)
            if scale.page == page.drawingScale?.page,scale.drawing == page.drawingScale?.drawing { scale.type = page.drawingScale?.type }
            guard scale.isValid else { throw DiagramError.invalid("Enter positive paper and drawing lengths for the scale.") }
            configurePage(name:name.stringValue.isEmpty ? "Page" : name.stringValue,width:try dimension(width,page.paperWidth)/scale.factor,height:try dimension(height,page.paperHeight)/scale.factor,isBackground:kind.indexOfSelectedItem == 1,background:.some(target),scale:.some(scale))
        } catch { presentError(error) }
    }
    @objc func goToPage(_ sender:Any?) {
        let alert = NSAlert();alert.messageText = "Go to Page";alert.addButton(withTitle:"Open Page");alert.addButton(withTitle:"Cancel")
        let popup = NSPopUpButton(frame:CGRect(x:0,y:0,width:340,height:26))
        for p in diagramDocument.diagram.orderedPages { popup.addItem(withTitle:p.name+(p.isBackground == true ? " (background)" : ""));popup.lastItem?.representedObject = p.id.uuidString }
        if let item = popup.itemArray.first(where:{$0.representedObject as? String == diagramDocument.diagram.activePageID.uuidString}) { popup.select(item) };alert.accessoryView = popup
        if alert.runModal() == .alertFirstButtonReturn,let raw = popup.selectedItem?.representedObject as? String,let id = UUID(uuidString:raw) { switchPage(id) }
    }
}
