import AppKit

enum TextContextExample {
    static func make() throws -> Diagram {
        var d = Diagram();d.title = "Text-driven shapes";d.page.width = 1000;d.page.height = 740
        func cell(_ value:String,_ formula:String = "") -> ShapeSheetCell { ShapeSheetCell(value:value,formula:formula) }
        func label(_ text:String,_ y:Double,_ size:Double = 17) -> DiagramNode { var n = DiagramNode(kind:.text,x:60,y:y,text:text);n.width = 880;n.height = 60;n.fontSize = size;n.formatting.alignment = .left;return n }
        func card(_ text:String,_ y:Double) -> DiagramNode {
            var n = DiagramNode(x:110,y:y,text:text);n.width = 288;n.height = 90;n.fontSize = 18;n.formatting.fontName = "Arial";n.fill = "#E6F1FF";n.stroke = "#2463A2"
            n.formatting.sheet["Width"] = cell("4","TEXTWIDTH(TheText)+0.6in");n.formatting.sheet["Height"] = cell("1.25","TEXTHEIGHT(TheText,Width)")
            n.formatting.sheet["TopMargin"] = cell("0.18");n.formatting.sheet["BottomMargin"] = cell("0.18");n.formatting.sheet["TxtWidth"] = cell("4","Width");n.formatting.sheet["TxtHeight"] = cell("1.25","Height");n.formatting.sheet["TxtPinX"] = cell("2","Controls.Label.X");n.formatting.sheet["TxtPinY"] = cell("0.625","Height/2");n.formatting.sheet["TxtLocPinX"] = cell("2","TxtWidth/2");n.formatting.sheet["TxtLocPinY"] = cell("0.625","TxtHeight/2")
            n.formatting.sheet["User.HasText"] = cell("1","NOT(STRSAME(SHAPETEXT(TheText),\"\"))")
            n.formatting.controls = [ShapeControl(name:"Label",index:0,cells:["X":cell("2","Width/2"),"Y":cell("0.625","Height/2"),"XCon":cell("0","IF(User.HasText,0,5)"),"YCon":cell("1"),"Prompt":cell("","\"Reposition \"&SHAPETEXT(TheText,84)")])];return n
        }
        d.page.nodes = [label("Text-driven shapes",35,28),label("Editing a label recalculates its width, height and text block.",110),card("Short label",235),card("A longer label makes a wider shape",395),label("Double-click either label to edit it. The yellow handle repositions its text.\nShape > ShapeSheet edits supported text, number and date cells.",570)]
        let calculated = DiagramCalculation.recalculate(d);guard calculated.issues.isEmpty else { throw DiagramError.invalid(calculated.issues.joined(separator:"\n")) };return try calculated.diagram.validated()
    }
    static func generate(in directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let d = try make();var changed = d;changed.page.nodes[2].text = "Edited text expands the original shape";changed = DiagramCalculation.recalculate(ShapeRichText.synchronize(changed,previous:d),previous:d).diagram
        for (name,model) in [("text-driven-shapes",d),("text-driven-shapes-edited",changed)] {
            let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys];try encoder.encode(model).write(to:directory.appendingPathComponent(name+".macvisio"),options:.atomic)
            try VisioFormat.write(model,to:directory.appendingPathComponent(name+".vsdx"));try VSDBinaryFormat.write(model,to:directory.appendingPathComponent(name+".vsd"));try DiagramExport.png(model.scene(),scale:1).write(to:directory.appendingPathComponent(name+".png"));try DiagramExport.pdf(model).write(to:directory.appendingPathComponent(name+".pdf"))
        }
        let doc = MacVisioDocument();doc.diagram = d;doc.makeWindowControllers()
        if let editor = doc.windowControllers.first as? EditorWindowController,let view = editor.window?.contentView { view.layoutSubtreeIfNeeded();editor.canvas.fitPage();editor.canvas.select([d.page.nodes[2].id]);view.layoutSubtreeIfNeeded();if let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:image);try image.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent("text-context-editor.png")) } };doc.windowControllers.forEach{$0.close()}
        let report:[String:Any] = ["beforeWidth":d.page.nodes[2].width,"afterWidth":changed.page.nodes[2].width,"tooltip":changed.page.nodes[2].formatting.controls[0].cell("Prompt")!.value,"widthFormulaRetained":d.page.nodes[2].formatting.sheet["Width"]?.formula == changed.page.nodes[2].formatting.sheet["Width"]?.formula,"windowsValidated":false];try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("text-context-verification.json"))
    }
}
