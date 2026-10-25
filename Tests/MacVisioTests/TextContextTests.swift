import AppKit
import XCTest
@testable import MacVisio

final class TextContextTests:XCTestCase {
    private var files:[URL] = []
    override func tearDown() { files.forEach{try? FileManager.default.removeItem(at:$0)};super.tearDown() }
    private func file() -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-text-context-\(UUID()).vsdx");files.append(u);return u }
    private func cell(_ value:String,_ formula:String = "",_ unit:String = "") -> ShapeSheetCell { ShapeSheetCell(value:value,formula:formula,unit:unit) }
    private func model(_ text:String = "") -> Diagram {
        var d = Diagram(),n = DiagramNode(x:100,y:120,text:text);n.width = 288;n.height = 144;n.formatting.sourceShapeID = "17";n.formatting.fontName = "Arial"
        n.formatting.sheet["User.HasText"] = cell("0","NOT(STRSAME(SHAPETEXT(TheText),\"\"))")
        n.formatting.controls = [ShapeControl(name:"Label",index:0,cells:["X":cell("2","Width/2"),"Y":cell("1","Height/2"),"XCon":cell("5","IF(User.HasText,0,5)"),"YCon":cell("1"),"Prompt":cell("Add text","IF(User.HasText,\"Reposition \"&SHAPETEXT(TheText,84),\"Add text\")")])];d.page.nodes = [n];return d
    }
    private func readPublic(_ d:Diagram) throws -> (Diagram,[String:Data]) {
        let u = file();try VisioFormat.write(d,to:u);var parts = try VisioPackage.read(u);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:u);return (try VisioFormat.read(from:u).diagram,parts)
    }
    func testSTRSAMEUsesCaseSensitiveDefaultAndIgnoreCaseFlag() throws {
        func eval(_ f:String) throws -> SheetValue { try TypedShapeSheet.evaluate(f,resolve:{_ in .number(0)},call:{_,_ in .number(0)}) }
        XCTAssertEqual(try eval("STRSAME(\"cat\",\"CAT\")"),.boolean(false));XCTAssertEqual(try eval("STRSAME(\"cat\",\"CAT\",TRUE)"),.boolean(true));XCTAssertEqual(try eval("STRSAME(\"cat\",\"CAT\",FALSE)"),.boolean(false));XCTAssertEqual(try eval("STRSAME(\"cät\",\"CÄT\",TRUE)"),.boolean(true));XCTAssertThrowsError(try eval("STRSAME(\"cat\")"))
    }
    func testSHAPETEXTFlagsAndFieldExpansion() throws {
        var n = DiagramNode(text:"A\u{00ad}“quote”\tTab\r\n line  end")
        XCTAssertEqual(try ShapeTextFunctions.text(n),"A“quote”\tTab\r\n line  end");XCTAssertEqual(try ShapeTextFunctions.text(n,flags:1),n.text);XCTAssertEqual(try ShapeTextFunctions.text(n,flags:84),"A“quote” Tab line end");XCTAssertEqual(try ShapeTextFunctions.text(n,flags:32),"A\"quote\"\tTab\r\n line  end");XCTAssertThrowsError(try ShapeTextFunctions.text(n,flags:128))
        n.text = "Before display after";let style = ShapeCharacterStyle(node:n),p = ShapeParagraphStyle();n.formatting.textRuns = [ShapeTextRun(text:"Before ",character:style,paragraph:p),ShapeTextRun(text:"display",character:style,paragraph:p,fieldIndex:0),ShapeTextRun(text:" after",character:style,paragraph:p)];XCTAssertEqual(try ShapeTextFunctions.text(n,flags:2),"Before  after")
    }
    func testTextChangesRecalculateBooleanCellsVisibilityAndTooltip() throws {
        let initial = ShapeSheetEngine.recalculate(model());XCTAssertTrue(initial.issues.isEmpty);XCTAssertFalse(initial.diagram.page.nodes[0].formatting.controls[0].visible)
        var changed = initial.diagram;changed.page.nodes[0].text = "Hello\tworld";let result = ShapeSheetEngine.recalculate(changed,previous:initial.diagram),n = result.diagram.page.nodes[0]
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined());XCTAssertEqual(n.formatting.sheet["User.HasText"]?.value,"1");XCTAssertTrue(n.formatting.controls[0].visible);XCTAssertEqual(n.formatting.controls[0].cell("Prompt")?.value,"Reposition Hello world")
    }
    func testTypedPropertyAndStringUserDependenciesDriveGeometry() throws {
        var d = model("Hi"),n = d.page.nodes[0];n.formatting.data = [ShapeDataProperty(key:"Kind",label:"Kind",value:"wide")];n.formatting.sheet["Prop.Kind"] = cell("wide","","STR");n.formatting.sheet["User.Label"] = cell("","UPPER(Prop.Kind)&\" view\"","STR")
        n.formatting.geometry = [ShapeGeometrySection(index:0,cells:[:],rows:[ShapeGeometryRow(index:1,type:"MoveTo",cells:["X":cell("0"),"Y":cell("0")]),ShapeGeometryRow(index:2,type:"LineTo",cells:["X":cell("2","IF(STRSAME(Prop.Kind,\"Wide\",TRUE),Width,Width/2)"),"Y":cell("1","Height")])])];d.page.nodes[0] = n
        let result = ShapeSheetEngine.recalculate(d);XCTAssertTrue(result.issues.isEmpty,result.issues.joined());XCTAssertEqual(result.diagram.page.nodes[0].formatting.sheet["User.Label"]?.value,"WIDE view");XCTAssertEqual(result.diagram.page.nodes[0].formatting.geometry![0].rows[1].cells["X"]?.value,"4")
    }
    func testCrossShapeTextUsesTargetFontAndPageReferences() throws {
        var d = model("Target text"),other = DiagramNode(x:500,y:100,text:"Caller");d.page.nodes[0].fontSize = 28;other.fontSize = 9;other.formatting.sourceShapeID = "31";other.formatting.sheet["User.Target"] = cell("","SHAPETEXT(Sheet.17!TheText)","STR");other.formatting.sheet["User.Width"] = cell("0","TEXTWIDTH(Sheet.17!TheText)");d.page.nodes.append(other)
        let ctx = ShapeSheetContext(page:d.page);XCTAssertEqual(try ctx.value(other.id,"User.Target"),.string("Target text"));XCTAssertEqual(try ctx.number(other.id,"User.Width"),try ShapeTextFunctions.metrics(d.page.nodes[0],page:d.page).width,accuracy:1e-12);XCTAssertEqual(try ctx.value(other.id,"Sheet.0017!TheText"),.string("Target text"));XCTAssertEqual(try ctx.number(other.id,"ThePage!PageWidth"),d.page.width/72)
    }
    func testMeasurementsRespectWrappingMarginsAndPaperScale() throws {
        var d = model("The same words repeat across several lines and should wrap into a taller text block.");d.page.nodes[0].formatting.textBox = ShapeTextBox(left:7,right:9,top:5,bottom:8)
        let n = d.page.nodes[0],wide = try ShapeTextFunctions.metrics(n,page:d.page),wrapped = try ShapeTextFunctions.metrics(n,page:d.page,maximumWidth:2)
        XCTAssertGreaterThan(wide.width,wrapped.width);XCTAssertGreaterThan(wrapped.height,wide.height);XCTAssertLessThanOrEqual(wrapped.width,2+1e-9)
        var p = d.page;p.drawingScale = DrawingScale(page:1,drawing:50);var scaled = n;scaled.formatting.textBox = nil;let raw = try ShapeTextFunctions.metrics(scaled,page:d.page),measured = try ShapeTextFunctions.metrics(scaled,page:p);XCTAssertEqual(measured.width,raw.width*50,accuracy:1e-10);XCTAssertEqual(measured.height,raw.height*50,accuracy:1e-10)
        XCTAssertThrowsError(try ShapeTextFunctions.metrics(n,page:d.page,maximumWidth:0))
    }
    func testTextAutoSizesShapeAndRepositionsTextBlock() throws {
        var d = model("Small");d.page.nodes[0].formatting.sheet["Width"] = cell("4","TEXTWIDTH(TheText)+0.5in");d.page.nodes[0].formatting.sheet["Height"] = cell("2","TEXTHEIGHT(TheText,Width)");d.page.nodes[0].formatting.sheet["TxtWidth"] = cell("4","Width");d.page.nodes[0].formatting.sheet["TxtHeight"] = cell("2","Height");d.page.nodes[0].formatting.sheet["TxtPinX"] = cell("2","Width/2");d.page.nodes[0].formatting.sheet["TxtPinY"] = cell("1","Height/2");d.page.nodes[0].formatting.sheet["TxtLocPinX"] = cell("2","TxtWidth/2");d.page.nodes[0].formatting.sheet["TxtLocPinY"] = cell("1","TxtHeight/2")
        let before = ShapeSheetEngine.recalculate(d);XCTAssertTrue(before.issues.isEmpty,before.issues.joined());var changed = before.diagram;changed.page.nodes[0].text = "A substantially longer label";let after = ShapeSheetEngine.recalculate(changed,previous:before.diagram),n = after.diagram.page.nodes[0]
        XCTAssertTrue(after.issues.isEmpty,after.issues.joined());XCTAssertGreaterThan(n.width,before.diagram.page.nodes[0].width);XCTAssertEqual(n.formatting.textBox!.centerX,0.5,accuracy:1e-10);XCTAssertEqual(n.formatting.textBox!.centerY,0.5,accuracy:1e-10);XCTAssertEqual(n.formatting.textBox!.width,1,accuracy:1e-10)
    }
    func testTextDrivenControlRedirectUsesTypedConditionAndRetainsFormula() throws {
        var d = model("Choose A"),n = d.page.nodes[0];n.formatting.sheet["User.A"] = cell("1");n.formatting.sheet["User.B"] = cell("2");n.formatting.controls[0].cells["X"] = cell("1","IF(STRSAME(SHAPETEXT(TheText),\"Choose A\"),SETATREF(User.A),SETATREF(User.B))");d.page.nodes[0] = n;d = ShapeSheetEngine.recalculate(d).diagram
        let result = try ControlEditing.moved(d,node:n.id,control:"Label",to:CGPoint(x:316,y:180)).page.nodes[0];XCTAssertEqual(result.formatting.sheet["User.A"]?.value,"3");XCTAssertEqual(result.formatting.sheet["User.B"]?.value,"2");XCTAssertEqual(result.formatting.controls[0].cell("X")?.formula,n.formatting.controls[0].cell("X")?.formula)
    }
    func testPublicTextContextDefinitionsRoundTripAndOpaquePartsRemain() throws {
        let (old,parts) = try readPublic(ShapeSheetEngine.recalculate(model()).diagram);var changed = old;changed.page.nodes[0].text = "Saved label";let calculated = ShapeSheetEngine.recalculate(changed,previous:old).diagram,(read,after) = try readPublic(calculated),n = read.page.nodes[0]
        XCTAssertEqual(n.formatting.controls[0].cell("Prompt")?.value,"Reposition Saved label");XCTAssertEqual(n.formatting.controls[0].cell("Prompt")?.formula,old.page.nodes[0].formatting.controls[0].cell("Prompt")?.formula);for (part,data) in parts where part != "visio/pages/page1.xml" { XCTAssertEqual(after[part],data,part) }
    }
    func testTypedArithmeticRetainsPrecisionAndDimensionalAggregates() throws {
        func typed(_ formula:String) throws -> SheetValue { try TypedShapeSheet.evaluate(formula,resolve:{_ in .number(0)},call:{_,_ in .number(0)}) }
        let value = 0.9999999999999999;XCTAssertEqual(try typed("MIN(0.9999999999999999,1)"),.number(value));XCTAssertEqual(try typed("MAX(0.9999999999999999,0)"),.number(value));XCTAssertEqual(try typed("SUM(1in,25.4mm)"),.quantity(2,"IN"));XCTAssertEqual(try typed("1in+1rad"),.quantity(2,"IN"));XCTAssertThrowsError(try typed("1in/1rad"));XCTAssertEqual(try typed("MIN(1in,1rad)"),.quantity(1,"IN"))  // COERCE-17/18
    }
    func testCircularTextDependenciesAndUnsupportedFunctionsRetainCaches() throws {
        var d = model("Saved");d.page.nodes[0].formatting.sheet["Width"] = cell("4","TEXTWIDTH(TheText,Width)");let result = ShapeSheetEngine.recalculate(d);XCTAssertEqual(result.diagram.page.nodes[0].width,288);XCTAssertTrue(result.issues.contains{$0.contains("Circular")})
        d.page.nodes[0].formatting.sheet["Width"] = cell("4","Unknown(TheText)");let unsupported = ShapeSheetEngine.recalculate(d);XCTAssertEqual(unsupported.diagram.page.nodes[0].width,288);XCTAssertFalse(unsupported.issues.isEmpty)
    }
    func testNativeTextEditingUpdatesControlAndUndoRestoresBoth() throws {
        _ = NSApplication.shared;let doc = MacVisioDocument();doc.diagram = ShapeSheetEngine.recalculate(model()).diagram;doc.makeWindowControllers();doc.undoManager?.groupsByEvent = false;let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController);editor.canvas.select([doc.diagram.page.nodes[0].id]);let old = doc.diagram
        doc.undoManager?.beginUndoGrouping();editor.modifySelection("Edit label"){$0.text = "Native text"};doc.undoManager?.endUndoGrouping();XCTAssertTrue(doc.diagram.page.nodes[0].formatting.controls[0].visible);XCTAssertEqual(editor.canvas.controlTip(at:ControlGeometry.point(doc.diagram.page.nodes[0].formatting.controls[0],on:doc.diagram.page.nodes[0])),"Reposition Native text");doc.undoManager?.undo();XCTAssertEqual(doc.diagram,old);doc.windowControllers.forEach{$0.close()}
    }
    func testFieldExpansionAndControlVisibilitySettleInOneDocumentEdit() throws {
        _ = NSApplication.shared;var d = model();d.page.nodes[0].formatting.data = [ShapeDataProperty(key:"Label",label:"Label",value:"")];d.page.nodes[0] = try TextFieldEngine.inserting(formula:"Prop.Label",into:d.page.nodes[0]);d = DiagramCalculation.recalculate(d).diagram
        let doc = MacVisioDocument();doc.diagram = d;doc.undoManager?.groupsByEvent = false;var changed = d;changed.page.nodes[0].formatting.data[0].value = "Expanded label";doc.undoManager?.beginUndoGrouping();doc.replace(with:changed,action:"Change field data");doc.undoManager?.endUndoGrouping();XCTAssertEqual(doc.diagram.page.nodes[0].text,"Expanded label");XCTAssertTrue(doc.diagram.page.nodes[0].formatting.controls[0].visible);XCTAssertEqual(doc.diagram.page.nodes[0].formatting.controls[0].cell("Prompt")?.value,"Reposition Expanded label");XCTAssertTrue(doc.calculationIssues.isEmpty,doc.calculationIssues.joined());doc.undoManager?.undo();XCTAssertEqual(doc.diagram,d)
    }
    func testInstallerAnalyticsTextControlVisibilityChangesWithText() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),source = root.appendingPathComponent("build/Visio2019-Libraries/ANALYTICS_M.VSSX")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Installer assets are absent") }
        let imported = try VisioStencil.read(from:source),master = try XCTUnwrap(imported.items.first{$0.fragment.nodes.contains{$0.formatting.controls.contains{$0.cell("XCon")?.formula.contains("SHAPETEXT") == true}}}),host = try XCTUnwrap(master.fragment.nodes.first{$0.formatting.controls.contains{$0.cell("XCon")?.formula.contains("SHAPETEXT") == true}}),control = try XCTUnwrap(host.formatting.controls.first{$0.cell("XCon")?.formula.contains("SHAPETEXT") == true})
        var page = master.fragment;let i = page.nodes.firstIndex{$0.id == host.id}!;page.nodes[i].text = "";page.nodes[i].formatting.sheet["HideText"] = cell("0");let address = "Controls."+control.name+".XCon",hidden = try ShapeSheetContext(page:page).number(host.id,address);page.nodes[i].text = "Analytics label";let visible = try ShapeSheetContext(page:page).number(host.id,address)
        XCTAssertGreaterThanOrEqual(hidden,5);XCTAssertLessThan(visible,5);var d = Diagram();d.pages = [page];d.activePageID = page.id;let calculated = ShapeSheetEngine.recalculate(d);XCTAssertEqual(calculated.diagram.page.nodes[i].formatting.controls.first{$0.name == control.name}?.cell("XCon")?.value,CompositeGeometry.number(visible))
    }
    func testNativeStringAndTextTransformCellEditingUndoRedoAndRollback() throws {
        _ = NSApplication.shared;let doc = MacVisioDocument();doc.diagram = model("Editor");doc.diagram.page.nodes[0].formatting.data = [ShapeDataProperty(key:"Kind",label:"Kind",value:"old")];doc.makeWindowControllers();doc.undoManager?.groupsByEvent = false;let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController),id = doc.diagram.page.nodes[0].id,old = doc.diagram
        doc.undoManager?.beginUndoGrouping();try editor.setShapeSheetCell("Prop.Kind",value:"new text",formula:"",for:id);try editor.setShapeSheetCell("User.Caption",value:"",formula:"UPPER(Prop.Kind)",unit:"STR",for:id);try editor.setShapeSheetCell("TxtWidth",value:"1",formula:"TEXTWIDTH(TheText)",for:id);doc.undoManager?.endUndoGrouping();let edited = doc.diagram
        XCTAssertEqual(edited.page.nodes[0].formatting.data[0].value,"new text");XCTAssertEqual(edited.page.nodes[0].formatting.sheet["User.Caption"]?.value,"NEW TEXT");XCTAssertEqual(edited.page.nodes[0].formatting.sheet["User.Caption"]?.unit,"STR");doc.undoManager?.undo();XCTAssertEqual(doc.diagram,old);doc.undoManager?.redo();XCTAssertEqual(doc.diagram,edited)
        XCTAssertThrowsError(try editor.setShapeSheetCell("Width",value:"bad",formula:"",for:id));XCTAssertEqual(doc.diagram,edited);doc.windowControllers.forEach{$0.close()}
    }
    func testStringAndDateCellCachesRetainTypesAndRejectInvalidDates() throws {
        var n = DiagramNode(text:"Types");try SheetCellEditing.set("User.Code",value:"123",formula:"",unit:"STR",on:&n);try SheetCellEditing.set("User.Day",value:"2026-10-14",formula:"",unit:"DATE",on:&n);var p = DiagramPage();p.nodes = [n];let ctx = ShapeSheetContext(page:p)
        XCTAssertEqual(try ctx.value(n.id,"User.Code"),.string("123"));if case .date = try ctx.value(n.id,"User.Day") {} else { XCTFail("Date cache lost its type") };XCTAssertThrowsError(try SheetCellEditing.set("User.Day",value:"bad",formula:"",unit:"DATE",on:&n))
    }
    func testParagraphSpacingAndIndentationAffectNativeTextMeasurement() throws {
        let d = model("One\nTwo"),n = d.page.nodes[0],plain = try ShapeTextFunctions.metrics(n,page:d.page)
        var spaced = n,p = ShapeParagraphStyle(alignment:.left);p.cells = ["SpBefore":cell("0.1"),"SpAfter":cell("0.2"),"SpLine":cell("-2"),"IndLeft":cell("0.25"),"IndFirst":cell("0.1"),"IndRight":cell("0.3")];spaced.formatting.textRuns = [ShapeTextRun(text:n.text,character:ShapeCharacterStyle(node:n),paragraph:p)]
        let style = p.native(fontSize:14);XCTAssertEqual(style.paragraphSpacingBefore,7.2,accuracy:1e-12);XCTAssertEqual(style.paragraphSpacing,14.4,accuracy:1e-12);XCTAssertEqual(style.minimumLineHeight,28);XCTAssertEqual(style.headIndent,18);XCTAssertEqual(style.firstLineHeadIndent,25.2,accuracy:1e-12);XCTAssertEqual(style.tailIndent,-21.6,accuracy:1e-12);XCTAssertGreaterThan(try ShapeTextFunctions.metrics(spaced,page:d.page).height,plain.height)
        p.cells["SpLine"] = cell("0.5");XCTAssertEqual(p.native(fontSize:14).maximumLineHeight,36);p.cells["SpLine"] = cell("0");XCTAssertEqual(p.native(fontSize:14).maximumLineHeight,14)
    }
    func testImplicitInternalUnitsAndREFErrors() throws {
        XCTAssertEqual(try ShapeSheet.evaluate("2DL+1DP+0.5DT",resolve:{_ in 0}),3.5);XCTAssertEqual(try ShapeSheet.evaluate("1DA",resolve:{_ in 0}),1);XCTAssertEqual(try ShapeSheet.evaluate("1DE",resolve:{_ in 0}),1)
        let d = model(),ctx = ShapeSheetContext(page:d.page),id = d.page.nodes[0].id
        XCTAssertEqual(try ctx.evaluate("IFERROR(REF(),3DL)",on:id),.quantity(3,"DL"));XCTAssertThrowsError(try ctx.evaluate("REF()",on:id))
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),source = root.appendingPathComponent("build/Visio2019-Libraries/BLDCOR_M.VSSX")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Installer assets are absent") }
        let master = try XCTUnwrap(VisioStencil.read(from:source).items.first{$0.name == "Straight staircase"}),node = try XCTUnwrap(master.fragment.nodes.first{$0.formatting.controls.contains{$0.cell("X")?.formula.contains("DL") == true}}),control = try XCTUnwrap(node.formatting.controls.first{$0.cell("X")?.formula.contains("DL") == true})
        XCTAssertEqual(try ShapeSheetContext(page:master.fragment).number(node.id,"Controls."+control.name+".X"),Double(control.cell("X")!.value)!,accuracy:1e-8)
    }
}
