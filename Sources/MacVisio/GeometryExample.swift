import AppKit

enum GeometryExample {
    static func make() throws -> Diagram {
        var model = Diagram();model.title = "Geometry formulas";model.page.width = 1000;model.page.height = 720
        func label(_ text:String,_ x:Double,_ y:Double,_ width:Double,_ size:Double) -> DiagramNode { var n = DiagramNode(kind:.text,x:x,y:y,text:text);n.width = width;n.height = 58;n.fontSize = size;n.formatting.alignment = .left;return n }
        model.page.nodes = [label("Formula-driven geometry",60,40,850,28),label("Width, Height and User.Notch control the vertices.",60,100,850,17)]
        func polygon(_ x:Double,_ width:Double,_ height:Double,_ notch:Double,_ text:String) -> DiagramNode {
            var n = DiagramNode(x:x,y:210,text:text);n.width = width;n.height = height;n.fill = "#E6F1FF";n.stroke = "#2463A2";n.fontSize = 17
            n.formatting.sheet["User.Notch"] = ShapeSheetCell(value:String(notch))
            func row(_ i:Int,_ type:String,_ x:String,_ y:String) -> ShapeGeometryRow { ShapeGeometryRow(index:i,type:type,cells:["X":ShapeSheetCell(value:"0",formula:x),"Y":ShapeSheetCell(value:"0",formula:y)]) }
            n.formatting.geometry = [ShapeGeometrySection(index:0,cells:[:],rows:[row(1,"MoveTo","0","0"),row(2,"LineTo","Width","0"),row(3,"LineTo","Geometry1.X2","Height-User.Notch"),row(4,"LineTo","Width/2","Height"),row(5,"LineTo","0","Geometry1.Y3"),row(6,"LineTo","0","0")])];return n
        }
        model.page.nodes += [polygon(70,216,144,0.25,"3 × 2 inches"),polygon(420,432,216,0.75,"6 × 3 inches")]
        model.page.nodes += [label("Notch = 0.25 in",70,450,270,17),label("Notch = 0.75 in",420,450,450,17),label("Select a shape, then use Shape > Geometry to edit a cell formula.\nResizing recalculates the supported geometry cells.",60,555,880,17)]
        return try ShapeSheetEngine.recalculate(model).diagram.validated()
    }
    static func generate(in directory:URL) throws {
        let model = try make();try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(model).write(to:directory.appendingPathComponent("geometry-formulas.macvisio"),options:.atomic)
        try VisioFormat.write(model,to:directory.appendingPathComponent("geometry-formulas.vsdx"));try VSDBinaryFormat.write(model,to:directory.appendingPathComponent("geometry-formulas.vsd"))
        try DiagramExport.png(model.scene(),scale:1).write(to:directory.appendingPathComponent("geometry-formulas.png"));try DiagramExport.pdf(model).write(to:directory.appendingPathComponent("geometry-formulas.pdf"));try DiagramDrawing.svg(model.scene()).write(to:directory.appendingPathComponent("geometry-formulas.svg"),atomically:true,encoding:.utf8)
        let doc = MacVisioDocument();doc.diagram = model;doc.makeWindowControllers()
        if let editor = doc.windowControllers.first as? EditorWindowController,let view = editor.window?.contentView {
            view.layoutSubtreeIfNeeded();editor.canvas.fitPage();view.layoutSubtreeIfNeeded()
            if let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:image);try image.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("geometry-editor.png")) }
        }
    }
}
