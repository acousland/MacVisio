import AppKit

enum CurveExample {
    static func make() throws -> Diagram {
        var model = Diagram();model.title = "Curves and polylines";model.page.width = 1000;model.page.height = 760
        func label(_ text:String,_ x:Double,_ y:Double,_ width:Double,_ size:Double = 17) -> DiagramNode { var n = DiagramNode(kind:.text,x:x,y:y,text:text);n.width = width;n.height = 58;n.fontSize = size;n.formatting.alignment = .left;return n }
        func row(_ i:Int,_ type:String,_ cells:[String:ShapeSheetCell]) -> ShapeGeometryRow { ShapeGeometryRow(index:i,type:type,cells:cells) }
        func cell(_ value:String,_ formula:String = "") -> ShapeSheetCell { ShapeSheetCell(value:value,formula:formula) }
        var cubic = DiagramNode(x:80,y:220,text:"");cubic.width = 380;cubic.height = 180;cubic.stroke = "#2463A2";cubic.strokeWidth = 2
        cubic.formatting.sheet["User.Tension"] = cell("0.3")
        cubic.formatting.geometry = [ShapeGeometrySection(index:0,cells:["NoFill":cell("1")],rows:[row(1,"MoveTo",["X":cell("0"),"Y":cell("0")]),row(2,"NURBSTo",["X":cell("0","Width"),"Y":cell("0"),"A":cell("0"),"B":cell("1"),"C":cell("0"),"D":cell("1"),"E":cell("","NURBS(1,3,0,0,User.Tension,1,0,1,1-User.Tension,1,0,1)")])])]
        var circle = DiagramNode(x:650,y:200,text:"");circle.width = 190;circle.height = 190;circle.stroke = "#9C3D72";circle.strokeWidth = 2
        circle.formatting.geometry = [ShapeGeometrySection(index:0,cells:["NoFill":cell("1")],rows:[row(1,"MoveTo",["X":cell("0","Width"),"Y":cell("0")]),row(2,"NURBSTo",["X":cell("0"),"Y":cell("0","Height"),"A":cell("0"),"B":cell("1"),"C":cell("0"),"D":cell("1"),"E":cell("","NURBS(1,2,0,0,1,1,0,SQRT(0.5))")])])]
        var polyline = DiagramNode(x:80,y:500,text:"");polyline.width = 790;polyline.height = 100;polyline.stroke = "#28796A";polyline.strokeWidth = 2
        polyline.formatting.geometry = [ShapeGeometrySection(index:0,cells:["NoFill":cell("1")],rows:[row(1,"MoveTo",["X":cell("0"),"Y":cell("0","Height/2")]),row(2,"PolylineTo",["X":cell("0","Width"),"Y":cell("0","Height/2"),"A":cell("","POLYLINE(0,0,0.25,0.75,0.5,0.25,0.75,0.75)")])])]
        model.page.nodes = [label("Curves and polylines",60,35,880,28),label("Geometry definitions retained in VSDX; saved curve data exported in VSD.",60,100,880),label("Cubic NURBS",80,160,390),label("Weighted quarter-circle",620,150,320),cubic,circle,label("Polyline",80,430,790),polyline,label("Select a curve and use Shape > Geometry to edit its data formula.",60,655,880)]
        var splinePage = DiagramPage(name:"Splines",width:1000,height:760),spline = DiagramNode(x:120,y:220,text:"")
        spline.width = 700;spline.height = 300;spline.stroke = "#2463A2";spline.strokeWidth = 2
        spline.formatting.geometry = [ShapeGeometrySection(index:0,cells:["NoFill":cell("1")],rows:[row(1,"MoveTo",["X":cell("0"),"Y":cell("0")]),row(2,"SplineStart",["X":cell("0","Width/4"),"Y":cell("0","Height"),"A":cell("0"),"B":cell("0"),"C":cell("1"),"D":cell("3")]),row(3,"SplineKnot",["X":cell("0","Width*3/4"),"Y":cell("0","Height"),"A":cell("0")]),row(4,"SplineKnot",["X":cell("0","Width"),"Y":cell("0"),"A":cell("0")])])]
        splinePage.nodes = [label("Spline rows",60,35,880,28),label("SplineStart and SplineKnot definitions produce a cubic curve.",60,100,880),spline,label("Geometry cell formulas remain editable, with Undo.",60,640,880)];model.pages.append(splinePage)
        let calculated = ShapeSheetEngine.recalculate(model);guard calculated.issues.isEmpty else { throw DiagramError.invalid(calculated.issues.joined(separator:"\n")) };return try calculated.diagram.validated()
    }
    static func generate(in directory:URL) throws { try save(make(),in:directory,name:"curves-and-polylines") }
    static func generateLibrary(from library:URL,in directory:URL) throws {
        let imported = try VisioStencil.read(from:library)
        guard let master = imported.items.first(where:{$0.fragment.nodes.contains{$0.formatting.geometry?.contains(where:{$0.rows.contains{$0.type == "NURBSTo"}}) == true}}) else { throw DiagramError.invalid("This stencil contains no NURBS master.") }
        let fragment = DrawingScale.convert(master.fragment,to:1,targetMeasured:false)
        var model = Diagram();model.title = master.name;model.page.width = max(600,fragment.width+120);model.page.height = max(380,fragment.height+180)
        try DiagramOperations.insert(fragment,into:&model.page,at:CGPoint(x:60,y:110))
        var title = DiagramNode(kind:.text,x:35,y:30,text:"\(master.name) · \(library.lastPathComponent)");title.width = model.page.width-70;title.height = 55;title.fontSize = 20;model.page.nodes.append(title)
        try save(model.validated(),in:directory,name:"installer-curved-master")
        let report:[String:Any] = ["source":library.lastPathComponent,"master":master.name,"sourceWarnings":imported.warnings,"nurbsRows":fragment.nodes.reduce(0){$0+($1.formatting.geometry?.reduce(0){$0+$1.rows.filter{$0.type == "NURBSTo"}.count} ?? 0)},"nativeCubicCommands":fragment.nodes.reduce(0){$0+$1.formatting.paths.reduce(0){$0+$1.commands.filter{$0.kind == "C"}.count}},"windowsValidated":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("installer-curve-report.json"))
    }
    private static func save(_ model:Diagram,in directory:URL,name:String) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(model).write(to:directory.appendingPathComponent(name+".macvisio"),options:.atomic)
        try VisioFormat.write(model,to:directory.appendingPathComponent(name+".vsdx"));try VSDBinaryFormat.write(model,to:directory.appendingPathComponent(name+".vsd"))
        try DiagramExport.png(model.scene(),scale:1).write(to:directory.appendingPathComponent(name+".png"));try DiagramExport.pdf(model).write(to:directory.appendingPathComponent(name+".pdf"));try DiagramDrawing.svg(model.scene()).write(to:directory.appendingPathComponent(name+".svg"),atomically:true,encoding:.utf8)
        let doc = MacVisioDocument();doc.diagram = model;doc.makeWindowControllers()
        if let editor = doc.windowControllers.first as? EditorWindowController,let view = editor.window?.contentView {
            view.layoutSubtreeIfNeeded();editor.canvas.fitPage();view.layoutSubtreeIfNeeded()
            if let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) { view.cacheDisplay(in:view.bounds,to:image);try image.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent(name+"-editor.png")) }
        }
    }
}
