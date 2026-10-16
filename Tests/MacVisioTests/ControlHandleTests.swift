import AppKit
import XCTest
@testable import MacVisio

final class ControlHandleTests:XCTestCase {
    private var files:[URL] = []
    override func tearDown() { files.forEach{try? FileManager.default.removeItem(at:$0)};super.tearDown() }
    private func file() -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-control-\(UUID()).vsdx");files.append(u);return u }
    private func cell(_ v:String,_ f:String = "") -> ShapeSheetCell { ShapeSheetCell(value:v,formula:f) }
    private func model() -> Diagram {
        var d = Diagram(),n = DiagramNode(x:100,y:100,text:"");n.width = 288;n.height = 144;n.formatting.sheet["User.Notch"] = cell("0.5")
        n.formatting.controls = [ShapeControl(name:"Notch",index:0,cells:["X":cell("2","GUARD(Width/2)"),"Y":cell("1.5","Height-SETATREF(User.Notch,SETATREFEVAL(Height-SETATREFEXPR()))"),"XCon":cell("1"),"YCon":cell("0"),"Prompt":cell("Notch depth")])]
        func row(_ i:Int,_ x:String,_ y:String,_ fx:String = "",_ fy:String = "") -> ShapeGeometryRow { ShapeGeometryRow(index:i,type:i == 1 ? "MoveTo" : "LineTo",cells:["X":cell(x,fx),"Y":cell(y,fy)]) }
        n.formatting.geometry = [ShapeGeometrySection(index:0,cells:[:],rows:[row(1,"0","0"),row(2,"4","0","Width"),row(3,"4","1.5","Width","Controls.Notch.Y"),row(4,"2","2","Width/2","Height"),row(5,"0","1.5","","Controls.Notch.Y"),row(6,"0","0")])];d.page.nodes = [n];return ShapeSheetEngine.recalculate(d).diagram
    }
    private func publicRead(_ d:Diagram) throws -> (Diagram,[String:Data]) {
        let u = file();try VisioFormat.write(d,to:u);var parts = try VisioPackage.read(u);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:u);return (try VisioFormat.read(from:u).diagram,parts)
    }
    func testControlReferencesResolveIntoGeometryAndHandleCoordinates() throws {
        let d = model(),n = d.page.nodes[0];XCTAssertTrue(ShapeSheetEngine.recalculate(d).issues.isEmpty);XCTAssertEqual(ControlGeometry.cell("Controls.Notch",on:n)?.value,"2");XCTAssertEqual(ControlGeometry.cell("Controls.Y1",on:n)?.value,"1.5");XCTAssertEqual(ControlGeometry.point(n.formatting.controls[0],on:n),CGPoint(x:244,y:136));XCTAssertEqual(n.formatting.paths[0].commands[2].values,[1,0.25])
    }
    func testDragRedirectsParameterWithoutReplacingControlFormula() throws {
        let old = model(),id = old.page.nodes[0].id,next = try ControlEditing.moved(old,node:id,control:"Notch",to:CGPoint(x:340,y:172)),n = next.page.nodes[0]
        XCTAssertEqual(n.formatting.sheet["User.Notch"]?.value,"1");XCTAssertEqual(n.formatting.controls[0].cell("X")?.value,"2");XCTAssertEqual(n.formatting.controls[0].cell("Y")?.value,"1");XCTAssertEqual(n.formatting.controls[0].cell("Y")?.formula,old.page.nodes[0].formatting.controls[0].cell("Y")?.formula);XCTAssertEqual(n.formatting.paths[0].commands[2].values,[1,0.5])
    }
    func testStoredExpressionRetainsClampingAfterDragging() throws {
        var d = model();d.page.nodes[0].formatting.controls = [ShapeControl(name:"Clamp",index:0,cells:["X":cell("0.5","MIN(Width,MAX(0,SETATREFEXPR(0.5)))"),"Y":cell("1"),"YCon":cell("1")])];d.page.nodes[0].formatting.geometry = nil
        let n = try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Clamp",to:CGPoint(x:676,y:120)).page.nodes[0]
        XCTAssertEqual(n.formatting.controls[0].cell("X")?.value,"4");XCTAssertTrue(n.formatting.controls[0].cell("X")!.formula.contains("SETATREFEXPR(8)"));XCTAssertEqual(n.formatting.controls[0].cell("Y")?.value,"1")
    }
    func testBehaviorModesResizeCachedControlsAndPreserveHiddenLocks() throws {
        var d = model();d.page.nodes[0].formatting.geometry = nil;d.page.nodes[0].formatting.controls = (0...9).map{ShapeControl(name:"C\($0)",index:$0,cells:["X":cell("1"),"Y":cell("0.5"),"XCon":cell(String($0)),"YCon":cell(String($0))])}
        let old = d;d.page.nodes[0].width = 576;d.page.nodes[0].height = 288;let next = ShapeSheetEngine.recalculate(d,previous:old).diagram.page.nodes[0]
        let xs = next.formatting.controls.map{Double($0.cell("X")!.value)!};XCTAssertEqual(xs,[2,2,1,3,5,2,2,1,3,5]);XCTAssertTrue(next.formatting.controls.prefix(5).allSatisfy(\.visible));XCTAssertTrue(next.formatting.controls.suffix(5).allSatisfy{!$0.visible})
    }
    func testProportionalAndOffsetDraggingRemainCorrectOnResize() throws {
        var d = model();d.page.nodes[0].formatting.geometry = nil;d.page.nodes[0].formatting.controls = [ShapeControl(name:"P",index:0,cells:["X":cell("1"),"Y":cell("1"),"YCon":cell("4")])]
        let moved = try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"P",to:CGPoint(x:208,y:190));var resize = moved;resize.page.nodes[0].width *= 2;resize.page.nodes[0].height *= 2
        let n = ShapeSheetEngine.recalculate(resize,previous:moved).diagram.page.nodes[0];XCTAssertEqual(n.formatting.controls[0].cell("X")?.value,"3");XCTAssertEqual(n.formatting.controls[0].cell("Y")?.value,"2.75")
    }
    func testRotatedReflectedControlCoordinatesRoundTrip() throws {
        var d = model();d.page.nodes[0].rotation = 35;d.page.nodes[0].formatting.flipX = true
        let n = d.page.nodes[0],world = DiagramCoordinates.world(CGPoint(x:144,y:72),in:n),next = try ControlEditing.moved(d,node:n.id,control:"Notch",to:world).page.nodes[0]
        let p = ControlGeometry.point(next.formatting.controls[0],on:next);XCTAssertEqual(p.x,world.x,accuracy:1e-8);XCTAssertEqual(p.y,world.y,accuracy:1e-8)
    }
    func testPublicSourceControlEditsRetainOpaqueCellsAndOtherParts() throws {
        var d = model();d.page.nodes[0].formatting.controls[0].cells["VendorExtra"] = cell("opaque");d.page.nodes[0].formatting.controls[0].cells["Y"]?.unit = "IN"
        let (old,before) = try publicRead(d),next = try ControlEditing.moved(old,node:old.page.nodes[0].id,control:"Notch",to:CGPoint(x:244,y:172)),(read,after) = try publicRead(next)
        for (key,data) in before where key != "visio/pages/page1.xml" { XCTAssertEqual(after[key],data,key) }
        let c = read.page.nodes[0].formatting.controls[0];XCTAssertEqual(c.name,"Notch");XCTAssertEqual(c.cell("VendorExtra")?.value,"opaque");XCTAssertEqual(c.cell("Y")?.unit,"IN");XCTAssertEqual(c.cell("Y")?.formula,old.page.nodes[0].formatting.controls[0].cell("Y")?.formula);XCTAssertEqual(read.page.nodes[0].formatting.paths[0].commands[2].values[0],1,accuracy:1e-9);XCTAssertEqual(read.page.nodes[0].formatting.paths[0].commands[2].values[1],0.5,accuracy:1e-9)
    }
    func testControlDeletionWritesPublicTombstone() throws {
        let (old,_) = try publicRead(model());var d = old;d.page.nodes[0].formatting.controls = [];let (read,parts) = try publicRead(d);XCTAssertTrue(read.page.nodes[0].formatting.controls.isEmpty)
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!),row = xml.rootElement()?.firstLocal("Shapes")?.firstLocal("Shape")?.elementsLocal("Section").first{$0.attr("N") == "Control"}?.firstLocal("Row");XCTAssertEqual(row?.attr("Del"),"1")
    }
    func testOlderMetadataHydratesControlsWithoutChangingNativeIdentities() throws {
        let d = model(),u = file();try VisioFormat.write(d,to:u);var parts = try VisioPackage.read(u),m = try JSONSerialization.jsonObject(with:parts["macvisio/document.json"]!) as! [String:Any];m.removeValue(forKey:"controlsVersion")
        var diagram = m["diagram"] as! [String:Any],pages = diagram["pages"] as! [[String:Any]],nodes = pages[0]["nodes"] as! [[String:Any]],details = nodes[0]["details"] as! [String:Any];details.removeValue(forKey:"controls");nodes[0]["details"] = details;pages[0]["nodes"] = nodes;diagram["pages"] = pages;m["diagram"] = diagram;parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:m);try VisioPackage.write(parts,to:u)
        let read = try VisioFormat.read(from:u);XCTAssertEqual(read.diagram.page.nodes[0].id,d.page.nodes[0].id);XCTAssertEqual(read.diagram.page.nodes[0].formatting.controls,d.page.nodes[0].formatting.controls);XCTAssertTrue(read.warnings.contains{$0.contains("control handles")})
    }
    func testNativeControlAdjustmentAndUndo() throws {
        _ = NSApplication.shared;let doc = MacVisioDocument();doc.diagram = model();doc.makeWindowControllers();doc.undoManager?.groupsByEvent = false;let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController),id = doc.diagram.page.nodes[0].id
        doc.undoManager?.beginUndoGrouping();try editor.moveControl("Notch",on:id,to:CGPoint(x:244,y:172));doc.undoManager?.endUndoGrouping();XCTAssertEqual(doc.diagram.page.nodes[0].formatting.sheet["User.Notch"]?.value,"1");doc.undoManager?.undo();XCTAssertEqual(doc.diagram.page.nodes[0].formatting.sheet["User.Notch"]?.value,"0.5");doc.windowControllers.forEach{$0.close()}
    }
    func testNativeCanvasControlDragChangesGeometryAndCreatesOneUndoStep() throws {
        _ = NSApplication.shared;let doc = MacVisioDocument();doc.diagram = model();doc.makeWindowControllers();doc.undoManager?.groupsByEvent = false
        let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController),canvas = editor.canvas,id = doc.diagram.page.nodes[0].id;editor.window!.contentView!.layoutSubtreeIfNeeded();canvas.zoom = 1;canvas.select([id])
        func event(_ type:NSEvent.EventType,_ p:CGPoint) throws -> NSEvent {
            let location = canvas.convert(CGPoint(x:canvas.pageOrigin.x+p.x*canvas.coordinateZoom,y:canvas.pageOrigin.y+p.y*canvas.coordinateZoom),to:nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:0,windowNumber:editor.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        doc.undoManager?.beginUndoGrouping();canvas.mouseDown(with:try event(.leftMouseDown,CGPoint(x:244,y:136)));canvas.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:244,y:172)));canvas.mouseUp(with:try event(.leftMouseUp,CGPoint(x:244,y:172)));doc.undoManager?.endUndoGrouping()
        XCTAssertEqual(doc.diagram.page.nodes[0].formatting.sheet["User.Notch"]?.value,"1");XCTAssertEqual(doc.diagram.page.nodes[0].rect,model().page.nodes[0].rect);doc.undoManager?.undo();XCTAssertEqual(doc.diagram.page.nodes[0].formatting.sheet["User.Notch"]?.value,"0.5");doc.windowControllers.forEach{$0.close()}
    }
    func testSETATREFEvaluationAndNumericDefaults() throws {
        XCTAssertEqual(try ShapeSheet.evaluate("SETATREF(User.X,Unsupported(),TRUE)",resolve:{_ in 3}),0);XCTAssertEqual(try ShapeSheet.evaluate("SETATREF(User.X,Unsupported())",resolve:{_ in 3}),3);XCTAssertEqual(try ShapeSheet.evaluate("SETATREFEXPR()",resolve:{_ in 3}),0)
    }
    func testCrossScaleControlsMaterializeCoordinatesAndKeepBehavior() throws {
        var d = model();d.page.drawingScale = DrawingScale(page:1,drawing:50);d.page.width *= 50;d.page.height *= 50;let p = DrawingScale.convert(d.page,to:1,targetMeasured:false),c = p.nodes[0].formatting.controls[0]
        XCTAssertEqual(Double(c.cell("X")!.value)!,0.04,accuracy:1e-10);XCTAssertEqual(Double(c.cell("Y")!.value)!,0.03,accuracy:1e-10);XCTAssertEqual(c.cell("Y")?.formula,"");XCTAssertEqual(c.behavior("X"),1)
    }
    private func redirected(_ formula:String) -> Diagram {
        var d = model();d.page.nodes[0].formatting.geometry = nil;d.page.nodes[0].formatting.controls = [ShapeControl(name:"Redirect",index:0,cells:["X":cell("1",formula),"Y":cell("1"),"YCon":cell("1")])];d.page.nodes[0].formatting.sheet["User.A"] = cell("1");d.page.nodes[0].formatting.sheet["User.B"] = cell("2");return d
    }
    func testCrossShapeRedirectUsesSourceIdentityAndQuotedReference() throws {
        var d = redirected("SETATREF(\"Sheet.37!User.Value\")");var other = DiagramNode(x:450,y:300,text:"Target");other.formatting.sourceShapeID = "37";other.formatting.sheet["User.Value"] = cell("1");d.page.nodes.append(other)
        let moved = try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120));XCTAssertEqual(moved.page.nodes[1].formatting.sheet["User.Value"]?.value,"3");XCTAssertEqual(moved.page.nodes[0].formatting.controls[0].cell("X")?.value,"3");XCTAssertEqual(moved.page.nodes[0].formatting.controls[0].cell("X")?.formula,d.page.nodes[0].formatting.controls[0].cell("X")?.formula)
        d.page.nodes[1].locked = true;XCTAssertThrowsError(try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120)))
    }
    func testRedirectChainsAcceptTenReferencesAndRejectElevenAndCycles() throws {
        var d = redirected("SETATREF(User.R0)")
        for i in 0..<10 { d.page.nodes[0].formatting.sheet["User.R\(i)"] = cell("1",i == 9 ? "" : "SETATREF(User.R\(i+1))") }
        let n = try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120)).page.nodes[0];XCTAssertEqual(n.formatting.sheet["User.R9"]?.value,"3");XCTAssertEqual(n.formatting.sheet["User.R0"]?.formula,"SETATREF(User.R1)")
        d.page.nodes[0].formatting.sheet["User.R9"] = cell("1","SETATREF(User.R10)");d.page.nodes[0].formatting.sheet["User.R10"] = cell("1");XCTAssertThrowsError(try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120)))
        d.page.nodes[0].formatting.sheet["User.R9"] = cell("1","SETATREF(User.R0)");XCTAssertThrowsError(try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120)))
    }
    func testLazyBranchesDoNotWriteInactiveTargets() throws {
        for formula in ["IF(TRUE,SETATREF(User.A),SETATREF(User.B))","IFERROR(SETATREF(User.A),SETATREF(User.B))"] {
            let d = redirected(formula),n = try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120)).page.nodes[0];XCTAssertEqual(n.formatting.sheet["User.A"]?.value,"3");XCTAssertEqual(n.formatting.sheet["User.B"]?.value,"2")
        }
        let d = redirected("IFERROR(SETATREF(User.A)/0,SETATREF(User.B))"),n = try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120)).page.nodes[0];XCTAssertEqual(n.formatting.sheet["User.A"]?.value,"1");XCTAssertEqual(n.formatting.sheet["User.B"]?.value,"3")
    }
    func testGuardedAndMultipleRedirectsRemainTransactional() throws {
        var d = redirected("GUARD(Width/2)");XCTAssertThrowsError(try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120)))
        d = redirected("GUARD(SETATREF(User.A)+SETATREF(User.B))");let n = try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120)).page.nodes[0];XCTAssertEqual(n.formatting.sheet["User.A"]?.value,"3");XCTAssertEqual(n.formatting.sheet["User.B"]?.value,"3");XCTAssertEqual(n.formatting.controls[0].cell("X")?.value,"6")
        d.page.nodes[0].formatting.sheet["User.B"] = cell("2","GUARD(2)");let old = d;XCTAssertThrowsError(try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120)));XCTAssertEqual(d,old)
    }
    func testRedirectAndOwnStoredInputBothUpdateWithoutChangingAssignmentTemplate() throws {
        let d = redirected("SETATREF(User.A,SETATREFEXPR(),TRUE)+SETATREFEXPR(1)"),n = try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:316,y:120)).page.nodes[0]
        XCTAssertEqual(n.formatting.sheet["User.A"]?.value,"3");XCTAssertEqual(n.formatting.controls[0].cell("X")?.value,"3");XCTAssertTrue(n.formatting.controls[0].cell("X")!.formula.contains("SETATREF(User.A,SETATREFEXPR(),TRUE)"));XCTAssertTrue(n.formatting.controls[0].cell("X")!.formula.contains("SETATREFEXPR(3)"))
    }
    func testControlRenameUpdatesLocalAndCrossSheetReferencesAndPublicRow() throws {
        var d = model();var other = DiagramNode(x:450,y:300,text:"");other.formatting.sheet["User.Depth"] = cell("1.5","Sheet.1!Controls.Notch.Y");d.page.nodes.append(other)
        let (old,parts) = try publicRead(d);var controls = old.page.nodes[0].formatting.controls;controls[0].name = "Depth";controls[0].cells["VendorExtra"] = cell("opaque");let next = try ControlEditor.replace(old,controls:controls,on:old.page.nodes[0].id),(read,after) = try publicRead(next)
        XCTAssertEqual(read.page.nodes[0].formatting.controls[0].name,"Depth");XCTAssertEqual(read.page.nodes[0].formatting.controls[0].index,0);XCTAssertEqual(read.page.nodes[0].formatting.controls[0].cell("VendorExtra")?.value,"opaque");XCTAssertEqual(read.page.nodes[0].formatting.geometry![0].rows[2].cells["Y"]?.formula,"Controls.Depth.Y");XCTAssertEqual(read.page.nodes[1].formatting.sheet["User.Depth"]?.formula,"Sheet.1!Controls.Depth.Y")
        for (key,data) in parts where key != "visio/pages/page1.xml" { XCTAssertEqual(after[key],data,key) }
        let xml = try VisioXML.document(after["visio/pages/page1.xml"]!),rows = xml.rootElement()!.firstLocal("Shapes")!.firstLocal("Shape")!.elementsLocal("Section").first{$0.attr("N") == "Control"}!.elementsLocal("Row");XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].attr("N"),"Depth");XCTAssertNil(rows[0].attr("Del"))
        XCTAssertEqual(ControlEditor.remap("IF(TRUE,Controls.Notch.Y,Sheet.2!Controls.Notch.Y)+\"Controls.Notch.Y\"",renames:["notch":"Depth"],local:true,sheetID:"1"),"IF(TRUE,Controls.Depth.Y,Sheet.2!Controls.Notch.Y)+\"Controls.Notch.Y\"")
    }
    func testNativeControlCellEditorAddRenameDeleteUndoAndInvalidRollback() throws {
        _ = NSApplication.shared;let doc = MacVisioDocument();doc.diagram = model();doc.makeWindowControllers();doc.undoManager?.groupsByEvent = false;let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController),id = doc.diagram.page.nodes[0].id;editor.canvas.select([id])
        doc.undoManager?.beginUndoGrouping();try editor.setControlCell("Controls.Notch.XCon",value:"0",formula:"",for:id);doc.undoManager?.endUndoGrouping();XCTAssertEqual(doc.diagram.page.nodes[0].formatting.controls[0].behavior("X"),0);doc.undoManager?.undo();XCTAssertEqual(doc.diagram.page.nodes[0].formatting.controls[0].behavior("X"),1)
        let old = doc.diagram;XCTAssertThrowsError(try editor.setControlCell("Controls.Notch.XCon",value:"11",formula:"",for:id));XCTAssertEqual(doc.diagram,old)
        var controls = old.page.nodes[0].formatting.controls;controls.append(ShapeControl(name:"Extra",index:1,cells:["X":cell("1"),"Y":cell("1")]))
        doc.undoManager?.beginUndoGrouping();try editor.setControls(controls,for:id);doc.undoManager?.endUndoGrouping();XCTAssertEqual(doc.diagram.page.nodes[0].formatting.controls.count,2);doc.undoManager?.undo();XCTAssertEqual(doc.diagram.page.nodes[0].formatting.controls.count,1)
        XCTAssertTrue(editor.validateMenuItem(NSMenuItem(title:"Controls",action:#selector(EditorWindowController.editControls(_:)),keyEquivalent:"")));editor.canvas.select([]);XCTAssertFalse(editor.validateMenuItem(NSMenuItem(title:"Controls",action:#selector(EditorWindowController.editControls(_:)),keyEquivalent:"")));doc.windowControllers.forEach{$0.close()}
    }
    func testNativeCanvasEscapeRestoresControlDragAndTooltip() throws {
        _ = NSApplication.shared;let doc = MacVisioDocument();doc.diagram = model();doc.makeWindowControllers();let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController),canvas = editor.canvas;canvas.zoom = 1;canvas.select([doc.diagram.page.nodes[0].id]);XCTAssertEqual(canvas.controlTip(at:CGPoint(x:244,y:136)),"Notch depth")
        func event(_ type:NSEvent.EventType,_ p:CGPoint) throws -> NSEvent { try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(CGPoint(x:canvas.pageOrigin.x+p.x*canvas.coordinateZoom,y:canvas.pageOrigin.y+p.y*canvas.coordinateZoom),to:nil),modifierFlags:[],timestamp:0,windowNumber:editor.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)) }
        let old = doc.diagram;canvas.mouseDown(with:try event(.leftMouseDown,CGPoint(x:244,y:136)));canvas.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:244,y:172)));XCTAssertEqual(canvas.page.nodes[0].formatting.sheet["User.Notch"]?.value,"0.5");XCTAssertEqual(canvas.controlPreviewPoint,CGPoint(x:244,y:172));XCTAssertEqual(doc.diagram,old)
        canvas.keyDown(with:try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:editor.window!.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)));canvas.mouseUp(with:try event(.leftMouseUp,CGPoint(x:244,y:172)));XCTAssertEqual(doc.diagram,old);XCTAssertFalse(doc.isDocumentEdited);doc.windowControllers.forEach{$0.close()}
    }
    func testIndexedMasterControlOverridesRetainPageReferencesAndSaveMinimally() throws {
        let u = file();try VisioFormat.write(Diagram(),to:u);var parts = try VisioPackage.read(u);parts.removeValue(forKey:"macvisio/document.json")
        let ns = "http://schemas.microsoft.com/office/visio/2012/main",base = "http://schemas.microsoft.com/visio/2010/relationships/"
        parts["visio/masters/masters.xml"] = Data("<Masters xmlns=\"\(ns)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><Master ID=\"7\" NameU=\"Control\"><Rel r:id=\"rId1\"/></Master></Masters>".utf8)
        parts["visio/masters/_rels/masters.xml.rels"] = Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(base)master\" Target=\"master1.xml\"/></Relationships>".utf8)
        let dims = "<Cell N=\"Width\" V=\"4\"/><Cell N=\"Height\" V=\"2\"/><Cell N=\"PinX\" V=\"2\"/><Cell N=\"PinY\" V=\"1\"/>"
        parts["visio/masters/master1.xml"] = Data("<MasterContents xmlns=\"\(ns)\"><Shapes><Shape ID=\"1\">\(dims)<Section N=\"User\"><Row N=\"Depth\"><Cell N=\"Value\" V=\"0.5\"/></Row></Section><Section N=\"Control\"><Row N=\"Adjust\" IX=\"0\"><Cell N=\"X\" V=\"2\" F=\"Sheet.1!Width/2\"/><Cell N=\"Y\" V=\"0.5\" F=\"SETATREF(User.Depth)\"/><Cell N=\"XCon\" V=\"1\"/><Cell N=\"Prompt\" V=\"Adjust depth\"/><Cell N=\"VendorExtra\" V=\"preserve\"/></Row></Section></Shape></Shapes></MasterContents>".utf8)
        let rels = try VisioXML.document(parts["visio/_rels/document.xml.rels"]!);rels.rootElement()!.addChild(try VisioXML.element("<Relationship Id=\"masterIndex\" Type=\"\(base)masters\" Target=\"masters/masters.xml\"/>"));parts["visio/_rels/document.xml.rels"] = rels.xmlData(options:.nodePreserveAll)
        let types = try VisioXML.document(parts["[Content_Types].xml"]!);for (part,type) in [("masters.xml","masters"),("master1.xml","master")] { types.rootElement()!.addChild(try VisioXML.element("<Override PartName=\"/visio/masters/\(part)\" ContentType=\"application/vnd.ms-visio.\(type)+xml\"/>")) };parts["[Content_Types].xml"] = types.xmlData(options:.nodePreserveAll)
        parts["visio/pages/page1.xml"] = Data("<PageContents xmlns=\"\(ns)\"><Shapes><Shape ID=\"10\" Master=\"7\">\(dims)<Section N=\"Control\"><Row IX=\"0\"><Cell N=\"X\" V=\"1\" F=\"Sheet.1!Width/6\"/></Row></Section></Shape><Shape ID=\"20\" Master=\"7\">\(dims)</Shape><Shape ID=\"1\"><Cell N=\"Width\" V=\"6\"/><Cell N=\"Height\" V=\"1\"/><Cell N=\"PinX\" V=\"3\"/><Cell N=\"PinY\" V=\"6\"/></Shape></Shapes></PageContents>".utf8);try VisioPackage.write(parts,to:u)
        let old = try VisioFormat.read(from:u).diagram,a = try XCTUnwrap(old.page.nodes.first{$0.formatting.sourceShapeID == "10"}),b = try XCTUnwrap(old.page.nodes.first{$0.formatting.sourceShapeID == "20"})
        XCTAssertEqual(a.formatting.controls.count,1);XCTAssertEqual(a.formatting.controls[0].name,"Adjust");XCTAssertEqual(a.formatting.controls[0].cell("X")?.formula,"Sheet.1!Width/6");XCTAssertEqual(b.formatting.controls[0].cell("X")?.formula,"Sheet.20!Width/2")
        let point = DiagramCoordinates.world(CGPoint(x:72,y:72),in:a),edited = try ControlEditing.moved(old,node:a.id,control:"Adjust",to:point),(read,after) = try publicRead(edited)
        XCTAssertEqual(after["visio/masters/master1.xml"],parts["visio/masters/master1.xml"]);let n = try XCTUnwrap(read.page.nodes.first{$0.formatting.sourceShapeID == "10"});XCTAssertEqual(n.formatting.controls.count,1);XCTAssertEqual(n.formatting.controls[0].cell("Y")?.value,"1");XCTAssertEqual(n.formatting.controls[0].cell("VendorExtra")?.value,"preserve");XCTAssertEqual(read.page.nodes.first{$0.formatting.sourceShapeID == "20"}?.formatting.controls[0].cell("Y")?.value,"0.5")
        let xml = try VisioXML.document(after["visio/pages/page1.xml"]!),shape = xml.rootElement()!.firstLocal("Shapes")!.elementsLocal("Shape").first{$0.attr("ID") == "10"}!,rows = shape.elementsLocal("Section").first{$0.attr("N") == "Control"}!.elementsLocal("Row");XCTAssertEqual(rows.count,1)
        var controls = n.formatting.controls;controls[0].name = "Depth";let renamed = try ControlEditor.replace(read,controls:controls,on:n.id),(renamedPublic,renamedParts) = try publicRead(renamed),renamedNode = try XCTUnwrap(renamedPublic.page.nodes.first{$0.formatting.sourceShapeID == "10"})
        XCTAssertEqual(renamedNode.formatting.controls.count,1);XCTAssertEqual(renamedNode.formatting.controls[0].name,"Depth");XCTAssertEqual(renamedNode.formatting.controls[0].cell("X")?.formula,"Sheet.1!Width/6");XCTAssertEqual(renamedNode.formatting.controls[0].cell("Y")?.value,"1");XCTAssertEqual(renamedParts["visio/masters/master1.xml"],parts["visio/masters/master1.xml"])
    }
    func testBoundRangesAndDragRetainConstraintExpression() throws {
        func eval(_ f:String) throws -> Double { try ShapeSheet.evaluate(f){_ in throw DiagramError.invalid("Unexpected reference") } }
        XCTAssertEqual(try eval("BOUND(9,0,FALSE,0,4)"),4);XCTAssertEqual(try eval("BOUND(-1,0,FALSE,4,0)"),0);XCTAssertEqual(try eval("BOUND(3.8,0,FALSE,2,2,FALSE,4,4,FALSE,6,6)"),4);XCTAssertEqual(try eval("BOUND(,0,FALSE,2in,2in,FALSE,4in,4in)"),2)
        XCTAssertEqual(try eval("BOUND(3,2,FALSE,Unsupported(),4)"),3);XCTAssertEqual(try eval("BOUND(3,0,TRUE,Unsupported(),4)"),3);XCTAssertEqual(try eval("BOUND(9,1,FALSE,0,4)"),9);XCTAssertEqual(try eval("BOUND(3,1,FALSE,0,4)"),4.nextUp);XCTAssertThrowsError(try eval("BOUND(3,9,FALSE,0,4)"))
        let d = redirected("BOUND(Width*0.1,0,FALSE,0,Width)"),next = try ControlEditing.moved(d,node:d.page.nodes[0].id,control:"Redirect",to:CGPoint(x:820,y:120)),n = next.page.nodes[0];XCTAssertEqual(n.formatting.controls[0].cell("X")?.value,"4");XCTAssertEqual(n.formatting.controls[0].cell("X")?.formula,"BOUND((Width*2.5),0,FALSE,0,Width)")
        var resized = next;resized.page.nodes[0].width *= 2;XCTAssertEqual(ShapeSheetEngine.recalculate(resized,previous:next).diagram.page.nodes[0].formatting.controls[0].cell("X")?.value,"8")
        let typed = try TypedShapeSheet.evaluate("BOUND(5in,0,FALSE,1in,3in)",resolve:{_ in .number(0)},call:{_,_ in .number(0)});XCTAssertEqual(typed,.quantity(3,"IN"))
    }
    func testInstallerParallelogramControlsImportDragAndPublicSave() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),source = root.appendingPathComponent("build/Visio2019-Libraries/BASIC_U.VSSX")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Installer assets are absent") }
        let imported = try VisioStencil.read(from:source),master = try XCTUnwrap(imported.items.first{$0.name == "Parallelogram"});var d = Diagram();try DiagramOperations.insert(master.fragment,into:&d.page,at:CGPoint(x:100,y:100));d = ShapeSheetEngine.recalculate(d).diagram
        let node = try XCTUnwrap(d.page.nodes.first{!$0.formatting.controls.isEmpty}),control = node.formatting.controls[0];XCTAssertEqual(control.cell("Prompt")?.value,"Side Offset");XCTAssertEqual(control.cell("Tip")?.value,"Side Offset");XCTAssertTrue(control.visible)
        let p = DiagramCoordinates.world(CGPoint(x:node.width*0.35,y:0),in:node),next = try ControlEditing.moved(d,node:node.id,control:control.name,to:p),n = try XCTUnwrap(next.page.nodes.first{$0.id == node.id});XCTAssertEqual(Double(n.formatting.controls[0].cell("X")!.value)!,node.width*0.35/72,accuracy:1e-9);XCTAssertTrue(n.formatting.controls[0].cell("X")!.formula.hasPrefix("BOUND("));XCTAssertNotEqual(n.formatting.paths,node.formatting.paths)
        let (read,parts) = try publicRead(next);XCTAssertEqual(read.page.nodes.first{$0.formatting.controls.count > 0}?.formatting.controls[0].cell("Prompt")?.value,"Side Offset");XCTAssertTrue(String(data:parts["visio/pages/page1.xml"]!,encoding:.utf8)!.contains("N=\"Control\""))
    }
}
