import AppKit

enum ControlExample {
    static func make() throws -> Diagram {
        var d = Diagram();d.title = "Control handles";d.page.width = 1000;d.page.height = 720
        func cell(_ value:String,_ formula:String = "") -> ShapeSheetCell { ShapeSheetCell(value:value,formula:formula) }
        func label(_ text:String,_ y:Double,_ size:Double = 17) -> DiagramNode { var n = DiagramNode(kind:.text,x:60,y:y,text:text);n.width = 880;n.height = 65;n.fontSize = size;n.formatting.alignment = .left;return n }
        var notch = DiagramNode(x:160,y:230,text:"Drag the yellow handle");notch.width = 432;notch.height = 216;notch.fill = "#E6F1FF";notch.stroke = "#2463A2";notch.fontSize = 18
        notch.formatting.sheet["User.Notch"] = cell("0.5")
        notch.formatting.controls = [ShapeControl(name:"Notch",index:0,cells:["X":cell("3","GUARD(Width/2)"),"Y":cell("2.5","Height-SETATREF(User.Notch,SETATREFEVAL(Height-SETATREFEXPR()))"),"XCon":cell("1"),"YCon":cell("0"),"XDyn":cell("3","Width/2"),"YDyn":cell("3","Height"),"CanGlue":cell("0"),"Prompt":cell("Adjust notch depth")])]
        func row(_ index:Int,_ x:String,_ y:String) -> ShapeGeometryRow { ShapeGeometryRow(index:index,type:index == 1 ? "MoveTo" : "LineTo",cells:["X":cell("0",x),"Y":cell("0",y)]) }
        notch.formatting.geometry = [ShapeGeometrySection(index:0,cells:[:],rows:[row(1,"0","0"),row(2,"Width","0"),row(3,"Width","Height"),row(4,"Width/2","Controls.Notch.Y"),row(5,"0","Height"),row(6,"0","0")])]
        d.page.nodes = [label("Control handles",35,28),label("The handle redirects its vertical position to User.Notch.",105),notch,label("Shape > Control Handles adds, renames or removes rows.\nShape > Control Cells edits formulas, anchors and behavior.",510),label("VSDX retains the definitions. Experimental VSD contains the saved drawing.",620)]
        let result = ShapeSheetEngine.recalculate(d);guard result.issues.isEmpty else { throw DiagramError.invalid(result.issues.joined(separator:"\n")) };return try result.diagram.validated()
    }
    static func generate(in directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let d = try make(),node = d.page.nodes[2],moved = try ControlEditing.moved(d,node:node.id,control:"Notch",to:DiagramCoordinates.world(CGPoint(x:node.width/2,y:90),in:node))
        for (name,model) in [("control-handles",d),("control-handles-adjusted",moved)] {
            let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(model).write(to:directory.appendingPathComponent(name+".macvisio"),options:.atomic)
            try VisioFormat.write(model,to:directory.appendingPathComponent(name+".vsdx"));try VSDBinaryFormat.write(model,to:directory.appendingPathComponent(name+".vsd"))
            try DiagramExport.png(model.scene(),scale:1).write(to:directory.appendingPathComponent(name+".png"));try DiagramExport.pdf(model).write(to:directory.appendingPathComponent(name+".pdf"))
        }
        let doc = MacVisioDocument();doc.diagram = d;doc.makeWindowControllers()
        if let editor = doc.windowControllers.first as? EditorWindowController,let view = editor.window?.contentView {
            view.layoutSubtreeIfNeeded();editor.canvas.fitPage();editor.canvas.select([node.id]);view.layoutSubtreeIfNeeded()
            if let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:image);try image.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("control-editor.png")) }
        };doc.windowControllers.forEach{$0.close()}
        let report:[String:Any] = ["beforeNotch":d.page.nodes[2].formatting.sheet["User.Notch"]!.value,"afterNotch":moved.page.nodes[2].formatting.sheet["User.Notch"]!.value,"controlFormulaRetained":d.page.nodes[2].formatting.controls[0].cell("Y")?.formula == moved.page.nodes[2].formatting.controls[0].cell("Y")?.formula,"geometryChanged":d.page.nodes[2].formatting.paths != moved.page.nodes[2].formatting.paths,"windowsValidated":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("control-verification.json"))
    }
}
