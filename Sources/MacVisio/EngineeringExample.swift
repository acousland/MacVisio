import AppKit

enum EngineeringExample {
    static func generate(library:URL,in directory:URL) throws {
        let courts = try VisioStencil.read(from:library.appendingPathComponent("RECRT_M.VSSX")).items
        let gates = try VisioStencil.read(from:library.appendingPathComponent("SITACC_M.VSSX")).items
        let blocks = try VisioStencil.read(from:library.appendingPathComponent("BLOCKP_M.VSSX")).items
        var model = Diagram();model.title = "Engineering Scale";model.page.width = 900/0.005;model.page.height = 700/0.005;model.page.drawingScale = DrawingScale(page:1,drawing:200,type:3)
        for (items,name,point) in [(courts,"Basketball court",CGPoint(x:100,y:160)),(gates,"Entrance gate",CGPoint(x:500,y:360)),(blocks,"Elbow 1",CGPoint(x:530,y:470))] {
            guard let master = items.first(where:{$0.name == name}) else { throw DiagramError.invalid("The engineering example master is missing: \(name)") }
            try DiagramOperations.insert(master.fragment,into:&model.page,at:CGPoint(x:point.x/model.page.paperScale,y:point.y/model.page.paperScale))
        }
        func label(_ text:String,_ rect:CGRect,_ size:Double,_ bold:Bool = false) {
            var node = DiagramNode(kind:.text,x:rect.minX/model.page.paperScale,y:rect.minY/model.page.paperScale,text:text);node.width = rect.width/model.page.paperScale;node.height = rect.height/model.page.paperScale;node.fontSize = size;node.bold = bold
            node.formatting.textBox = ShapeTextBox();model.page.nodes.append(node)
        }
        label("Sports-site plan · drawing scale 1:200",CGRect(x:50,y:35,width:800,height:65),26,true)
        label("Real drawing dimensions stay unchanged.\nFont sizes and line weights use paper units.",CGRect(x:410,y:165,width:420,height:80),16)
        label("Basketball court: 15.2 m × 28.7 m",CGRect(x:60,y:640,width:330,height:30),13)
        label("Entrance gate: 12.192 m real span",CGRect(x:420,y:290,width:420,height:40),14)
        label("Signed-width elbow symbol",CGRect(x:430,y:425,width:360,height:30),14)
        model = try model.validated();try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(model).write(to:directory.appendingPathComponent("engineering-scale.macvisio"),options:.atomic)
        try VisioFormat.write(model,to:directory.appendingPathComponent("engineering-scale.vsdx"));try VSDBinaryFormat.write(model,to:directory.appendingPathComponent("engineering-scale.vsd"))
        try VisioReusableFormat.writeTemplate(model,to:directory.appendingPathComponent("engineering-scale.vstx"))
        try DiagramExport.png(model.page,scale:1).write(to:directory.appendingPathComponent("engineering-scale.png"));try DiagramExport.pdf(model.page).write(to:directory.appendingPathComponent("engineering-scale.pdf"))
        try DiagramDrawing.svg(model.page).write(to:directory.appendingPathComponent("engineering-scale.svg"),atomically:true,encoding:.utf8)
        let doc = MacVisioDocument();doc.diagram = model;doc.makeWindowControllers()
        if let editor = doc.windowControllers.first as? EditorWindowController,let view = editor.window?.contentView {
            editor.stencils = courts;editor.root.stencil.refreshCategories(selecting:courts.first?.family);view.layoutSubtreeIfNeeded();editor.canvas.fitPage();view.layoutSubtreeIfNeeded()
            if let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:image);try image.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("engineering-editor.png")) }
        }
    }
}
