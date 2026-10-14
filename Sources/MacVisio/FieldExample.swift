import AppKit

enum FieldExample {
    static func make() throws -> Diagram {
        var model = Diagram();model.title = "Release Review";model.page.name = "Review";model.page.width = 900;model.page.height = 640
        func label(_ text:String,_ y:Double,_ size:Double) -> DiagramNode { var node = DiagramNode(kind:.text,x:70,y:y,text:text);node.width = 760;node.height = 60;node.fontSize = size;node.formatting.fontName = "Arial";return node }
        var title = label("",55,28);title.bold = true;title = try TextFieldEngine.inserting(formula:"PAGENAME() & \" · release readiness\"",into:title)
        var card = DiagramNode(x:130,y:180,text:"Status: ");card.width = 640;card.height = 130;card.fontSize = 24;card.fill = "#EAF2FB";card.formatting.fontName = "Arial"
        card.formatting.data = [ShapeDataProperty(key:"Status",label:"Review status",value:"Ready for review",type:0,format:"",prompt:"")]
        card = try TextFieldEngine.inserting(formula:"Prop.Status",into:card)
        var dimensions = label("Drawing width: ",365,20);dimensions = try TextFieldEngine.inserting(formula:"FORMAT(ThePage!PageWidth,FIELDPICTURE(7))",into:dimensions)
        var second = DiagramPage(name:"Details",width:900,height:640);var body = label("Owner: Architecture team\nReference: ARCH-2048",190,22);body.height = 150;second.nodes = [body]
        var background = DiagramPage(name:"Shared footer",width:900,height:640);background.isBackground = true
        var footer = label("",565,14);footer.textColor = "#53657D";footer.height = 40
        footer = try TextFieldEngine.inserting(formula:"PAGENAME() & \" · \" & PAGENUMBER() & \"/\" & PAGECOUNT()",into:footer)
        background.nodes = [footer];model.page.nodes = [title,card,dimensions];model.page.backgroundPageID = background.id;second.backgroundPageID = background.id;model.pages += [second,background]
        model = TextFieldEngine.recalculate(model).diagram;return try model.validated()
    }
    static func generate(in directory:URL) throws {
        let model = try make();try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(model).write(to:directory.appendingPathComponent("release-review.macvisio"),options:.atomic)
        try VisioFormat.write(model,to:directory.appendingPathComponent("release-review.vsdx"));try VSDBinaryFormat.write(model,to:directory.appendingPathComponent("release-review.vsd"));try VisioReusableFormat.writeTemplate(model,to:directory.appendingPathComponent("release-review.vstx"))
        try DiagramExport.png(model.scene(),scale:1).write(to:directory.appendingPathComponent("release-review.png"));try DiagramExport.pdf(model).write(to:directory.appendingPathComponent("release-review.pdf"));try DiagramDrawing.svg(model.scene()).write(to:directory.appendingPathComponent("release-review.svg"),atomically:true,encoding:.utf8)
        let doc = MacVisioDocument();doc.diagram = model;doc.makeWindowControllers()
        if let editor = doc.windowControllers.first as? EditorWindowController,let view = editor.window?.contentView {
            view.layoutSubtreeIfNeeded();editor.canvas.fitPage();view.layoutSubtreeIfNeeded()
            if let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:image);try image.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("field-editor.png")) }
        }
    }
}
