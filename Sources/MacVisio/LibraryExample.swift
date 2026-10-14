import AppKit

enum LibraryExample {
    static func generate(from stencil:URL,in directory:URL) throws {
        let items = try VisioStencil.read(from:stencil).items
        var model = Diagram();model.title = "Installer Flowchart";model.page.width = 900;model.page.height = 540
        var roots:[UUID] = []
        for (i,entry) in [("Process","Receive request"),("Decision","Approved?"),("Document","Complete request")].enumerated() {
            guard let master = items.first(where:{$0.name == entry.0}) else { throw DiagramError.invalid("The example needs Process, Decision and Document masters.") }
            let inserted = try DiagramOperations.insert(master.fragment,into:&model.page,at:CGPoint(x:80+Double(i)*265,y:205))
            guard let root = inserted.first,let index = model.page.nodes.firstIndex(where:{$0.id == root}) else { throw DiagramError.invalid("The example master has no root shape.") }
            model.page.nodes[index].text = entry.1;roots.append(root)
        }
        for i in 0..<roots.count-1 {
            let source = model.page.nodes.first{$0.id == roots[i]}!,target = model.page.nodes.first{$0.id == roots[i+1]}!
            var edge = DiagramEdge(source:source.id,target:target.id,label:i == 0 ? "Review" : "Yes",style:.orthogonal)
            edge.sourcePort = source.formatting.connectionPoints.max{ConnectionGeometry.local($0,on:source).x < ConnectionGeometry.local($1,on:source).x}?.id
            edge.targetPort = target.formatting.connectionPoints.min{ConnectionGeometry.local($0,on:target).x < ConnectionGeometry.local($1,on:target).x}?.id
            model.page.edges.append(edge)
        }
        var title = DiagramNode(kind:.text,x:50,y:65,text:"Flowchart from the Visio 2019 installer");title.width = 800;title.height = 52;title.fontSize = 26;title.bold = true;model.page.nodes.append(title)
        var footer = DiagramNode(kind:.text,x:50,y:385,text:"Editable Process, Decision and Document masters • Connection-point glue");footer.width = 800;footer.height = 48;footer.fontSize = 14;model.page.nodes.append(footer)
        model = try model.validated()
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys];try encoder.encode(model).write(to:directory.appendingPathComponent("installer-flowchart.macvisio"),options:.atomic)
        try VisioFormat.write(model,to:directory.appendingPathComponent("installer-flowchart.vsdx"));try VSDBinaryFormat.write(model,to:directory.appendingPathComponent("installer-flowchart.vsd"))
        try VisioReusableFormat.writeTemplate(model,to:directory.appendingPathComponent("installer-flowchart.vstx"))
        try VisioReusableFormat.writeStencil(items.filter{["Process","Decision","Document"].contains($0.name)},to:directory.appendingPathComponent("flowchart-masters.vssx"))
        try DiagramExport.png(model.page,scale:1).write(to:directory.appendingPathComponent("installer-flowchart.png"));try DiagramExport.pdf(model.page).write(to:directory.appendingPathComponent("installer-flowchart.pdf"))
        let doc = MacVisioDocument();doc.diagram = model;doc.makeWindowControllers()
        if let editor = doc.windowControllers.first as? EditorWindowController,let view = editor.window?.contentView {
            editor.stencils = items;editor.root.stencil.refreshCategories(selecting:items.first?.family);view.layoutSubtreeIfNeeded();editor.canvas.fitPage();view.layoutSubtreeIfNeeded()
            if let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:image);try image.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("library-editor.png")) }
        }
        let entries = try VisioLibrary.entries(in:stencil.deletingLastPathComponent())
        let picker = VisioLibraryPicker(entries:entries);picker.search.stringValue = "BASFLO";picker.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        let browser = FlippedView(frame:CGRect(x:0,y:0,width:680,height:450));browser.wantsLayer = true;browser.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let label = uiLabel("Visio Libraries — \(entries.count) stencils and templates",size:16,weight:.semibold);label.frame = CGRect(x:30,y:12,width:620,height:24);browser.addSubview(label)
        picker.frame.origin = CGPoint(x:30,y:46);browser.addSubview(picker)
        let window = NSWindow(contentRect:browser.frame,styleMask:[.titled],backing:.buffered,defer:false);window.appearance = NSAppearance(named:.aqua);window.contentView = browser;browser.layoutSubtreeIfNeeded()
        if let image = browser.bitmapImageRepForCachingDisplay(in:browser.bounds) { browser.cacheDisplay(in:browser.bounds,to:image);try image.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("library-browser.png")) }
    }
}
