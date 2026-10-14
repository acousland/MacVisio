import AppKit

enum RichTextExample {
    static func generate(in directory:URL) throws {
        var model = Diagram();model.title = "Project Handover";model.page.name = "Review";model.page.width = 900;model.page.height = 620
        var heading = DiagramNode(kind:.text,x:90,y:55,text:"Project review");heading.width = 720;heading.height = 60;heading.fontSize = 28;heading.bold = true
        var card = DiagramNode(kind:.roundedRectangle,x:90,y:150,text:"");card.width = 720;card.height = 340;card.fill = "#F3F6FD";card.stroke = "#BECBE0";card.formatting.textBox = ShapeTextBox(left:28,right:28,top:26,bottom:26,verticalAlignment:0)
        func run(_ text:String,_ size:Double = 18,_ color:String = "#20334F",bold:Bool = false,italic:Bool = false,underline:Bool = false,font:String = "Arial",align:TextAlignment = .left) -> ShapeTextRun {
            var character = ShapeCharacterStyle(node:card);character.size = size;character.color = color;character.bold = bold;character.italic = italic;character.underline = underline;character.fontName = font
            return ShapeTextRun(text:text,character:character,paragraph:ShapeParagraphStyle(alignment:align))
        }
        let runs = [run("Project handover\n",26,bold:true),run("\nCritical path",20,"#B3261E",bold:true),run(" due "),run("Friday",18,"#B3261E",underline:true),run(".\n\nOwner: "),run("Architecture team\n",18,italic:true),run("\nReview ticket: "),run("ARCH-2048\n",18,font:"Courier New"),run("\nReady for review ✓",18,"#216E39",bold:true,align:.right)]
        card.text = runs.map(\.text).joined();card.formatting.textRuns = runs;card.fontSize = 26;card.bold = true;card.formatting.fontName = "Arial";card.formatting.alignment = .left
        var footer = DiagramNode(kind:.text,x:90,y:525,text:"Prepared for the architecture review");footer.width = 720;footer.height = 35;footer.fontSize = 14;footer.textColor = "#53657D"
        model.page.nodes = [heading,card,footer]
        var scaled = model.page;scaled.id = UUID();scaled.name = "Scale 1:50";scaled.width *= 50;scaled.height *= 50;scaled.drawingScale = DrawingScale(page:1,drawing:50,type:3)
        for i in scaled.nodes.indices {
            scaled.nodes[i].id = UUID();scaled.nodes[i].x *= 50;scaled.nodes[i].y *= 50;scaled.nodes[i].width *= 50;scaled.nodes[i].height *= 50
            if var box = scaled.nodes[i].formatting.textBox { box.left *= 50;box.right *= 50;box.top *= 50;box.bottom *= 50;scaled.nodes[i].formatting.textBox = box }
        }
        model.pages.append(scaled);model = try model.validated();try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(model).write(to:directory.appendingPathComponent("project-handover.macvisio"),options:.atomic)
        try VisioFormat.write(model,to:directory.appendingPathComponent("project-handover.vsdx"));try VSDBinaryFormat.write(model,to:directory.appendingPathComponent("project-handover.vsd"));try VisioReusableFormat.writeTemplate(model,to:directory.appendingPathComponent("project-handover.vstx"))
        try DiagramExport.png(model.page,scale:1).write(to:directory.appendingPathComponent("project-handover.png"));try DiagramExport.pdf(model).write(to:directory.appendingPathComponent("project-handover.pdf"))
        try DiagramDrawing.svg(model.page).write(to:directory.appendingPathComponent("project-handover.svg"),atomically:true,encoding:.utf8)
        let document = MacVisioDocument();document.diagram = model;document.makeWindowControllers()
        if let editor = document.windowControllers.first as? EditorWindowController,let view = editor.window?.contentView {
            view.layoutSubtreeIfNeeded();editor.canvas.fitPage();view.layoutSubtreeIfNeeded()
            if let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:image);try image.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("rich-text-editor.png")) }
        }
    }
}
