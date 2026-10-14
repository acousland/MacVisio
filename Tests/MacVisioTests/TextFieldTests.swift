import AppKit
import XCTest
@testable import MacVisio

final class TextFieldTests:XCTestCase {
    private var files:[URL] = []
    override func tearDown() { for file in files { try? FileManager.default.removeItem(at:file) };super.tearDown() }
    private func file(_ ext:String) -> URL { let result = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-fields-\(UUID()).\(ext)");files.append(result);return result }
    private func imported() throws -> (Diagram,URL) {
        var model = Diagram();model.page.name = "Overview";let url = file("vsdx");try VisioFormat.write(model,to:url)
        var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json")
        parts["visio/pages/page1.xml"] = Data("""
        <PageContents xmlns="http://schemas.microsoft.com/office/visio/2012/main" xml:space="preserve"><Shapes><Shape ID="1" Type="Shape">
        <Cell N="Width" V="2" U="MM"/><Cell N="Height" V="1"/><Cell N="PinX" V="3"/><Cell N="PinY" V="4"/>
        <Section N="Property"><Row N="Status"><Cell N="Type" V="0"/><Cell N="Value" V="Draft" U="STR" F="No Formula"/><Cell N="Label" V="Status"/></Row></Section>
        <Section N="Field"><Row IX="0"><Cell N="Value" V="Overview" U="STR" F="PAGENAME()"/><Cell N="Type" V="0"/></Row><Row IX="2"><Cell N="Value" V="Draft" U="STR" F="Prop.Status"/><Cell N="Type" V="0"/></Row><Row IX="5"><Cell N="Value" V="2" U="MM" F="Width"/><Cell N="Format" V="esc(7)" U="STR" F="FIELDPICTURE(7)"/><Cell N="Type" V="2"/><Cell N="UICat" V="3"/></Row></Section>
        <Text><cp IX="0"/><pp IX="0"/>Page: <fld IX="0">Overview</fld> · <fld IX="2">Draft</fld> · <fld IX="5">50.80 mm</fld></Text>
        </Shape></Shapes></PageContents>
        """.utf8);try VisioPackage.write(parts,to:url);return (try VisioFormat.read(from:url).diagram,url)
    }
    func testPublicImportRetainsReferencesCachedTextAndUnchangedBytes() throws {
        let (model,source) = try imported(),node = model.page.nodes[0]
        XCTAssertEqual(node.text,"Page: Overview · Draft · 50.80 mm");XCTAssertEqual(node.formatting.textFields?.map(\.index),[0,2,5]);XCTAssertEqual(node.formatting.textRuns?.compactMap(\.fieldIndex),[0,2,5])
        let out = file("vsdx");try VisioFormat.write(model,to:out);XCTAssertEqual(try VisioPackage.read(source),try VisioPackage.read(out))
    }
    func testPageDataAndGeometryChangesRecalculateFields() throws {
        let (model,_) = try imported();var changed = model;changed.page.name = "Release";changed.page.nodes[0].formatting.data[0].value = "Approved";changed.page.nodes[0].width = 100/25.4*72
        let numeric = ShapeSheetEngine.recalculate(changed,previous:model),fields = TextFieldEngine.recalculate(numeric.diagram)
        XCTAssertEqual(fields.diagram.page.nodes[0].text,"Page: Release · Approved · 100.00 mm");XCTAssertTrue(fields.issues.isEmpty)
    }
    func testFreshAndPreservingExportsKeepPublicFieldDefinitions() throws {
        let (model,_) = try imported()
        for fresh in [false,true] {
            var copy = model;if fresh { copy.visioArchive = nil };copy.page.name = "Renamed";copy = TextFieldEngine.recalculate(copy).diagram
            let out = file("vsdx");try VisioFormat.write(copy,to:out);var parts = try VisioPackage.read(out);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:out)
            let read = try VisioFormat.read(from:out).diagram
            XCTAssertEqual(read.page.nodes[0].text,"Page: Renamed · Draft · 50.80 mm");XCTAssertEqual(read.page.nodes[0].formatting.textFields?.first?.cells["Value"]?.formula,"PAGENAME()")
            XCTAssertEqual(read.page.nodes[0].formatting.textFields?.last?.cells["UICat"]?.value,"3")
        }
    }
    func testUnsupportedFieldsRetainCachesWithoutExecution() throws {
        var model = Diagram();var node = DiagramNode(text:"Kept");node.formatting.textFields = [ShapeTextField(index:0,cells:["Value":ShapeSheetCell(value:"cached",formula:"RUNMACRO(\"NoExecution\")")],cached:"Kept")]
        node.formatting.textRuns = [ShapeTextRun(text:"Kept",character:ShapeCharacterStyle(node:node),paragraph:ShapeParagraphStyle(),fieldIndex:0,fieldToken:UUID())];model.page.nodes = [node]
        let result = TextFieldEngine.recalculate(model);XCTAssertEqual(result.diagram.page.nodes[0].text,"Kept");XCTAssertFalse(result.issues.isEmpty)
    }
    func testRepeatedAdjacentReferencesRemainSeparate() throws {
        var (model,_) = try imported();let run = try XCTUnwrap(model.page.nodes[0].formatting.textRuns?.first{$0.fieldIndex == 2});var second = run;second.fieldToken = UUID()
        model.page.nodes[0].text = run.text+second.text;model.page.nodes[0].formatting.textRuns = [run,second];model.page.nodes[0].formatting.data[0].value = "Done"
        let result = TextFieldEngine.recalculate(model).diagram;XCTAssertEqual(result.page.nodes[0].text,"DoneDone");XCTAssertEqual(result.page.nodes[0].formatting.textRuns?.count,2)
        var fresh = result;fresh.visioArchive = nil;let out = file("vsdx");try VisioFormat.write(fresh,to:out);var parts = try VisioPackage.read(out);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:out)
        XCTAssertEqual(try VisioFormat.read(from:out).diagram.page.nodes[0].formatting.textRuns?.compactMap(\.fieldIndex),[2,2])
    }
    func testFormattingAndUnrelatedTextEditsPreserveFieldIdentity() throws {
        let (model,_) = try imported(),node = model.page.nodes[0],text = NSMutableAttributedString(attributedString:ShapeRichText.attributed(node,editing:true))
        text.addAttribute(.underlineStyle,value:1,range:(text.string as NSString).range(of:"Draft"));let formatted = ShapeRichText.applying(text,to:node)
        XCTAssertEqual(formatted.formatting.textRuns?.compactMap(\.fieldIndex),[0,2,5]);XCTAssertTrue(formatted.formatting.textRuns!.first{$0.fieldIndex == 2}!.character.underline)
        var prefixed = node;prefixed.text = "Prefix · "+node.text;XCTAssertEqual(prefixed.formatting.textRuns?.compactMap(\.fieldIndex),[0,2,5])
        text.replaceCharacters(in:(text.string as NSString).range(of:"Draft"),with:"Literal");let literal = ShapeRichText.applying(text,to:node)
        XCTAssertEqual(literal.formatting.textRuns?.compactMap(\.fieldIndex),[0,5]);XCTAssertTrue(literal.text.contains("Literal"))
    }
    func testEmptyFieldPlaceholderDoesNotBecomeLiteralOnCommit() throws {
        var node = DiagramNode(text:"");node.formatting.textFields = [ShapeTextField(index:0,cells:["Value":ShapeSheetCell(value:"",formula:"Unsupported()")],cached:"")]
        node.formatting.textRuns = [ShapeTextRun(text:"",character:ShapeCharacterStyle(node:node),paragraph:ShapeParagraphStyle(),fieldIndex:0,fieldToken:UUID())]
        let text = ShapeRichText.attributed(node,editing:true);XCTAssertEqual(text.string,"‹field›");XCTAssertEqual(ShapeRichText.logicalSelection(NSRange(location:text.length,length:0),in:text).location,0)
        let read = ShapeRichText.applying(text,to:node);XCTAssertEqual(read.text,"");XCTAssertEqual(read.formatting.textRuns?.first?.fieldIndex,0)
    }
    func testNativeInsertionAtCaretAndUndo() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument();var node = DiagramNode(text:"Start end");document.diagram.page.name = "Overview";document.diagram.page.nodes = [node];document.makeWindowControllers();document.undoManager?.groupsByEvent = false
        let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        document.undoManager?.beginUndoGrouping();try editor.insertTextField(formula:"PAGENAME()",into:node.id,range:NSRange(location:6,length:0));document.undoManager?.endUndoGrouping()
        XCTAssertEqual(document.diagram.page.nodes[0].text,"Start Overviewend");document.undoManager?.undo();XCTAssertEqual(document.diagram.page.nodes[0].text,"Start end")
        for controller in document.windowControllers { controller.close() }
    }
    func testTypedStringsBooleansUnitsAndDateFormatting() throws {
        let empty:(String)throws->SheetValue = {_ in throw DiagramError.invalid("Missing")},call:(String,[SheetValue])throws->SheetValue = {_,_ in throw DiagramError.invalid("Unsupported")}
        XCTAssertEqual(try TypedShapeSheet.evaluate("IF(TRUE,\"A\"\"B\" & LOWER(\"C\"),Unknown())",resolve:empty,call:call),.string("A\"Bc"))
        let quantity = try TypedShapeSheet.evaluate("ROUND(320.4pt,0)",resolve:empty,call:call);XCTAssertEqual(try FieldFormatting.format(quantity,picture:"esc(3)",unit:"PT",type:2),"320 pt.")
        XCTAssertEqual(try FieldFormatting.format(.number(1234.567),picture:"#,##0.00"),"1,234.57")
        let date = try XCTUnwrap(FieldFormatting.date("2026-10-14"));XCTAssertEqual(try FieldFormatting.format(.date(date),picture:"yyyy-MM-dd",type:5),"2026-10-14")
    }
    func testPageNumbersExcludeBackgroundPages() throws {
        var model = Diagram();var background = DiagramPage(name:"Background");background.isBackground = true;model.pages.insert(background,at:0)
        var node = DiagramNode(text:"");node = try TextFieldEngine.inserting(formula:"PAGENUMBER() & \"/\" & PAGECOUNT()",into:node);model.page.nodes = [node]
        let value = TextFieldEngine.recalculate(model).diagram;XCTAssertEqual(value.page.nodes[0].text,"1/1")
    }
    func testSharedBackgroundUsesForegroundFieldContextWithoutMutation() throws {
        var model = Diagram();model.page.name = "First";var second = DiagramPage(name:"Second"),background = DiagramPage(name:"Shared");background.isBackground = true
        var node = DiagramNode(text:"");node = try TextFieldEngine.inserting(formula:"PAGENAME() & \" · \" & PAGENUMBER() & \"/\" & PAGECOUNT()",into:node);background.nodes = [node]
        model.page.backgroundPageID = background.id;second.backgroundPageID = background.id;model.pages += [second,background]
        XCTAssertEqual(model.scene().backgrounds[0].nodes[0].text,"First · 1/2");XCTAssertEqual(model.scene(for:second.id).backgrounds[0].nodes[0].text,"Second · 2/2")
        XCTAssertEqual(model.pages.last?.nodes[0].text,"")
    }
    func testOldPrivateMetadataCannotHideFieldReferences() throws {
        var (model,_) = try imported();model.visioArchive = nil;let out = file("vsdx");try VisioFormat.write(model,to:out);var parts = try VisioPackage.read(out)
        var envelope = try JSONSerialization.jsonObject(with:parts["macvisio/document.json"]!) as! [String:Any];envelope.removeValue(forKey:"textFieldsVersion");parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:envelope);try VisioPackage.write(parts,to:out)
        let result = try VisioFormat.read(from:out);XCTAssertEqual(result.diagram.page.nodes[0].formatting.textFields?.count,3);XCTAssertTrue(result.warnings.contains{$0.contains("public fields were reimported")})
    }
    func testActualMediaMasterDimensionFieldsUpdateAfterResize() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/Visio2019-Libraries/MWFC_MEDIA_R2L.VSTX")
        guard FileManager.default.fileExists(atPath:root.path) else { throw XCTSkip("Installer assets unavailable") }
        var model = try VisioFormat.read(from:root).diagram
        let page = try XCTUnwrap(model.pages.firstIndex{$0.nodes.contains{node in node.formatting.textFields?.contains{ $0.cells["Value"]?.formula == "Width" && $0.cells["Value"]?.unit == "PT" } == true}})
        let i = try XCTUnwrap(model.pages[page].nodes.firstIndex{$0.formatting.textFields?.contains{$0.cells["Value"]?.formula == "Width" && $0.cells["Value"]?.unit == "PT"} == true})
        let before = model;model.pages[page].nodes[i].width = 200
        let updated = TextFieldEngine.recalculate(ShapeSheetEngine.recalculate(model,previous:before).diagram).diagram
        XCTAssertTrue(updated.pages[page].nodes[i].text.contains("200 pt."))
    }
    func testBinaryPublicFieldMarkersAndCachedValuesParseWithoutPrivateModel() throws {
        let (model,_) = try imported(),out = file("vsd");try VSDBinaryFormat.encoded(model,includeMetadata:false).write(to:out)
        let compound = try CompoundFile.read(Data(contentsOf:out)),stream = try XCTUnwrap(compound.streams["VisioDocument"])
        XCTAssertNil(compound.streams[VSDBinaryFormat.nativeStream]);XCTAssertNotNil(stream.range(of:Data([0xFC,0xFF])))
        let publicPages = try LegacyVisioFormat.graphicPages(from:out,stencils:false).pages
        XCTAssertTrue(publicPages[0].nodes.contains{$0.text.contains("Overview") && $0.text.contains("Draft") && $0.text.contains("50.80 mm")})
    }
    func testMixedExplicitAndUnassignedShapeIDsDoNotCollide() throws {
        var model = Diagram();var first = DiagramNode(text:"Target");first.formatting.sourceShapeID = "2";var next = DiagramNode(text:"")
        next = try TextFieldEngine.inserting(formula:"Sheet.2!Width",picture:"esc(3)",into:next);model.page.nodes = [first,next]
        XCTAssertTrue(TextFieldEngine.recalculate(model).issues.isEmpty)
    }
}
