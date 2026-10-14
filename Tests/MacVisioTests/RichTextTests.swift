import AppKit
import XCTest
@testable import MacVisio

final class RichTextTests:XCTestCase {
    private var files:[URL] = []
    override func tearDown() { for file in files { try? FileManager.default.removeItem(at:file) };super.tearDown() }
    private func file(_ ext:String) -> URL { let result = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-rich-\(UUID()).\(ext)");files.append(result);return result }
    private func imported() throws -> (Diagram,URL) {
        let url = file("vsdx");var base = Diagram();base.page.width = 720;base.page.height = 480;try VisioFormat.write(base,to:url)
        var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json")
        parts["visio/document.xml"] = Data("<VisioDocument xmlns=\"http://schemas.microsoft.com/office/visio/2012/main\"><FaceNames><FaceName ID=\"0\" Name=\"Arial\"/><FaceName ID=\"1\" Name=\"Courier New\"/></FaceNames></VisioDocument>".utf8)
        let body = """
        <PageContents xmlns="http://schemas.microsoft.com/office/visio/2012/main" xml:space="preserve"><Shapes><Shape ID="1" Type="Shape">
        <Cell N="Width" V="8"/><Cell N="Height" V="4"/><Cell N="PinX" V="5"/><Cell N="PinY" V="3"/><Cell N="LocPinX" V="4"/><Cell N="LocPinY" V="2"/><Cell N="FillForegnd" V="#FFFFFF"/>
        <Section N="Character"><Row IX="3"><Cell N="Font" V="0"/><Cell N="Size" V="0.2222222222222222"/><Cell N="Color" V="#263238"/><Cell N="Style" V="0"/></Row><Row IX="9"><Cell N="Font" V="1"/><Cell N="Size" V="0.3055555555555556" F="GUARD(22pt)" U="PT"/><Cell N="Color" V="#C62828"/><Cell N="Style" V="7"/><Cell N="Strikethru" V="1"/><Cell N="LangID" V="1033"/></Row></Section>
        <Section N="Paragraph"><Row IX="4"><Cell N="HorzAlign" V="0"/></Row><Row IX="7"><Cell N="HorzAlign" V="2"/></Row></Section>
        <Text><cp IX="3"/><pp IX="4"/>Hello <cp IX="9"/>🙂 world<cp IX="3"/>
        <pp IX="7"/><cp IX="9"/>Next line</Text></Shape></Shapes></PageContents>
        """
        parts["visio/pages/page1.xml"] = Data(body.utf8);try VisioPackage.write(parts,to:url)
        let read = try VisioFormat.read(from:url);XCTAssertFalse(read.warnings.contains{$0.contains("reduced to")});return (read.diagram,url)
    }
    private func verify(_ model:Diagram) throws {
        let node = try XCTUnwrap(model.page.nodes.first),runs = try XCTUnwrap(node.formatting.textRuns)
        XCTAssertEqual(node.text,"Hello 🙂 world\nNext line");XCTAssertEqual(runs.map(\.text).joined(),node.text)
        XCTAssertEqual(runs[0].character.size,16,accuracy:1e-8);XCTAssertEqual(runs[1].character.size,22,accuracy:1e-8)
        XCTAssertEqual(runs[1].character.fontName,"Courier New");XCTAssertEqual(runs[1].character.color,"#C62828")
        XCTAssertTrue(runs[1].character.bold && runs[1].character.italic && runs[1].character.underline && runs[1].character.strikethrough)
        XCTAssertEqual(runs.first?.paragraph.alignment,.left);XCTAssertEqual(runs.last?.paragraph.alignment,.right)
    }
    func testSparsePublicRunsUnicodeAndUnchangedSourceBytes() throws {
        let (model,source) = try imported();try verify(model)
        let runs = try XCTUnwrap(model.page.nodes[0].formatting.textRuns);XCTAssertEqual(runs[1].character.sourceIndex,9);XCTAssertEqual(runs[1].character.cells["Size"]?.unit,"PT")
        let out = file("vsdx");try VisioFormat.write(model,to:out);XCTAssertEqual(try VisioPackage.read(out),try VisioPackage.read(source))
        XCTAssertEqual(try JSONDecoder().decode(Diagram.self,from:JSONEncoder().encode(model)),model)
    }
    func testFreshPublicRoundTripWithoutNativeMetadata() throws {
        var (model,_) = try imported();model.visioArchive = nil;let out = file("vsdx");try VisioFormat.write(model,to:out)
        var parts = try VisioPackage.read(out);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:out);try verify(VisioFormat.read(from:out).diagram)
        let root = try VisioXML.document(try XCTUnwrap(parts["visio/document.xml"]));XCTAssertTrue(root.rootElement()!.firstLocal("FaceNames")!.elementsLocal("FaceName").contains{$0.attr("NameU") == "Courier New"})
    }
    func testSourcePreservingPartialFormattingKeepsOtherRunsAndOpaqueCells() throws {
        var (model,_) = try imported();let old = model.page.nodes[0],text = NSMutableAttributedString(attributedString:ShapeRichText.attributed(old))
        let range = (text.string as NSString).range(of:"world");text.addAttribute(.font,value:NSFont(name:"Courier New",size:30)!,range:range)
        model.page.nodes[0] = ShapeRichText.applying(text,to:old)
        let out = file("vsdx");try VisioFormat.write(model,to:out);var parts = try VisioPackage.read(out);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:out)
        let read = try VisioFormat.read(from:out).diagram,runs = try XCTUnwrap(read.page.nodes[0].formatting.textRuns)
        XCTAssertEqual(try XCTUnwrap(runs.first).character.size,16,accuracy:1e-8);XCTAssertEqual(try XCTUnwrap(runs.first{$0.text.contains("world")}).character.size,30,accuracy:1e-8);XCTAssertEqual(try XCTUnwrap(runs.first{$0.text.contains("🙂")}).character.size,22,accuracy:1e-8)
        XCTAssertEqual(runs.first{$0.text.contains("world")}?.character.cells["LangID"]?.value,"1033")
        let xml = try VisioXML.element(String(decoding:parts["visio/pages/page1.xml"]!,as:UTF8.self)),shape = xml.firstLocal("Shapes")!.allShapes[0]
        let sizes = shape.elementsLocal("Section").filter{$0.attr("N") == "Character"}.flatMap{$0.elementsLocal("Row")}.map{VisioXML.number($0,"Size")*72};XCTAssertTrue(sizes.contains{abs($0-30)<1e-8})
    }
    func testScaledAttributedEditingKeepsPaperFontsAndUndo() throws {
        _ = NSApplication.shared
        var (model,_) = try imported();model.page.drawingScale = DrawingScale(page:1,drawing:50);model.page.width *= 50;model.page.height *= 50
        for i in model.page.nodes.indices { model.page.nodes[i].x *= 50;model.page.nodes[i].y *= 50;model.page.nodes[i].width *= 50;model.page.nodes[i].height *= 50 }
        let document = MacVisioDocument();document.diagram = model;document.makeWindowControllers();document.undoManager?.groupsByEvent = false
        let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController);editor.canvas.setZoom(0.5)
        let node = document.diagram.page.nodes[0];editor.canvas.select([node.id]);editor.canvas.beginEditing(node.id)
        let field = try XCTUnwrap(editor.canvas.subviews.compactMap{$0 as? NSTextView}.first)
        XCTAssertTrue(field.isRichText);XCTAssertEqual((field.textStorage!.attribute(.font,at:0,effectiveRange:nil) as! NSFont).pointSize,8,accuracy:1e-8)
        field.setSelectedRange(NSRange(location:0,length:5));editor.boldText(nil)
        field.undoManager?.undo();XCTAssertFalse(NSFontManager.shared.traits(of:field.textStorage!.attribute(.font,at:0,effectiveRange:nil) as! NSFont).contains(.boldFontMask))
        field.undoManager?.redo();XCTAssertTrue(NSFontManager.shared.traits(of:field.textStorage!.attribute(.font,at:0,effectiveRange:nil) as! NSFont).contains(.boldFontMask))
        document.undoManager?.beginUndoGrouping();editor.canvas.finishEditing(commit:true);document.undoManager?.endUndoGrouping()
        XCTAssertTrue(try XCTUnwrap(document.diagram.page.nodes[0].formatting.textRuns?.first).character.bold)
        XCTAssertEqual(document.diagram.page.nodes[0].formatting.textRuns?.first?.character.size,16)
        document.undoManager?.undo();XCTAssertFalse(try XCTUnwrap(document.diagram.page.nodes[0].formatting.textRuns?.first).character.bold)
        for controller in document.windowControllers { controller.close() }
    }
    func testInspectorFormattingAppliesAcrossRuns() throws {
        let (model,_) = try imported();var next = model;next.page.nodes[0].fontSize = 19;next.page.nodes[0].formatting.alignment = .center
        let synchronized = ShapeRichText.synchronize(next,previous:model)
        XCTAssertTrue(synchronized.page.nodes[0].formatting.textRuns!.allSatisfy{$0.character.size == 19 && $0.paragraph.alignment == .center})
    }
    func testIndependentBothFormatsPreserveCharacterRuns() throws {
        let (model,_) = try imported()
        for ext in ["vsdx","vsd"] {
            let out = file(ext);if ext == "vsdx" { var fresh = model;fresh.visioArchive = nil;try VisioFormat.write(fresh,to:out) } else { try VSDBinaryFormat.write(model,to:out) }
            let process = Process(),pipe = Pipe();process.executableURL = try XCTUnwrap(LegacyVisioFormat.converterURL);process.arguments = [out.path];process.standardOutput = pipe;process.standardError = FileHandle.nullDevice;try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
            let html = String(decoding:data,as:UTF8.self),styles = html.components(separatedBy:"\n").filter{$0.contains("<svg:tspan")}.joined(separator:"\n")
            print("Independent \(ext) styles: \(styles)")
            XCTAssertTrue(html.contains("Hello"),ext);XCTAssertTrue(html.contains("world"),ext)
            XCTAssertTrue(html.contains("Courier New"),"\(ext): \(styles)");XCTAssertTrue(html.contains("font-weight=\"bold\""),"\(ext): \(styles)");XCTAssertTrue(html.contains("font-style=\"italic\""),"\(ext): \(styles)")
        }
    }
    func testOldNativeMetadataCannotHideMixedPublicText() throws {
        var (model,_) = try imported();model.visioArchive = nil;let out = file("vsdx");try VisioFormat.write(model,to:out);var parts = try VisioPackage.read(out)
        var envelope = try JSONSerialization.jsonObject(with:parts["macvisio/document.json"]!) as! [String:Any];envelope.removeValue(forKey:"textRunsVersion");parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:envelope);try VisioPackage.write(parts,to:out)
        let read = try VisioFormat.read(from:out);try verify(read.diagram);XCTAssertTrue(read.warnings.contains{$0.contains("public text runs were reimported")})
    }
    func testPhysicalExportsIncludeStyledTextAndRichSVGPaperTransform() throws {
        _ = NSApplication.shared
        let (model,_) = try imported();let svg = DiagramDrawing.svg(model.page);XCTAssertTrue(svg.contains("font-size=\"22.0\""));XCTAssertTrue(svg.contains("font-weight=\"700\""));XCTAssertTrue(svg.contains("line-through"));XCTAssertTrue(svg.contains("🙂") && svg.contains("world"))
        let png = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(model.page,scale:1)));XCTAssertEqual(png.pixelsWide,720);XCTAssertTrue(DiagramExport.pdf(model.page).starts(with:Data("%PDF".utf8)))
        var scaled = model;scaled.page.drawingScale = DrawingScale(page:1,drawing:50);scaled.page.width *= 50;scaled.page.height *= 50
        for i in scaled.page.nodes.indices { scaled.page.nodes[i].x *= 50;scaled.page.nodes[i].y *= 50;scaled.page.nodes[i].width *= 50;scaled.page.nodes[i].height *= 50 }
        XCTAssertTrue(DiagramDrawing.svg(scaled.page).contains("scale(50.0) rotate"))
    }
    func testInvalidTextRunMismatchAndNonfiniteFontAreRejected() throws {
        var (model,_) = try imported();model.page.nodes[0].formatting.textRuns![0].text = "Wrong";XCTAssertThrowsError(try model.validated())
        (model,_) = try imported();model.page.nodes[0].formatting.textRuns![0].character.size = .infinity;XCTAssertThrowsError(try model.validated())
    }
    func testModernOrdinalFaceNamesAndOldFontMetadataUpgrade() throws {
        let (_,source) = try imported();var parts = try VisioPackage.read(source)
        parts["visio/document.xml"] = Data("<VisioDocument xmlns=\"http://schemas.microsoft.com/office/visio/2012/main\"><FaceNames><FaceName NameU=\"Arial\"/><FaceName NameU=\"Courier New\"/></FaceNames></VisioDocument>".utf8);try VisioPackage.write(parts,to:source)
        let model = try VisioFormat.read(from:source).diagram;try verify(model)
        let out = file("vsdx");try VisioFormat.write(model,to:out)
        XCTAssertEqual(try VisioFormat.read(from:out).diagram.page.nodes[0].formatting.textRuns?[1].character.fontName,"Courier New")
    }
    func testPartialEditBeforeOriginalStyleKeepsItsRowAndFormula() throws {
        var (model,_) = try imported();let original = model.page.nodes[0],text = NSMutableAttributedString(attributedString:ShapeRichText.attributed(original))
        text.addAttribute(.font,value:NSFont(name:"Courier New",size:24)!,range:(text.string as NSString).range(of:"🙂"));model.page.nodes[0] = ShapeRichText.applying(text,to:original)
        let out = file("vsdx");try VisioFormat.write(model,to:out);let parts = try VisioPackage.read(out),root = try VisioXML.element(String(decoding:parts["visio/pages/page1.xml"]!,as:UTF8.self))
        let row = try XCTUnwrap(root.firstLocal("Shapes")!.allShapes[0].elementsLocal("Section").first{$0.attr("N") == "Character"}?.elementsLocal("Row").first{$0.attr("IX") == "9"})
        XCTAssertEqual(VisioXML.number(row,"Size")*72,22,accuracy:1e-8);XCTAssertEqual(row.elementsLocal("Cell").first{$0.attr("N") == "Size"}?.attr("F"),"GUARD(22pt)")
    }
    func testNativeFreshSaveSynchronizesPublicRunIndexesAcrossEdits() throws {
        var (model,_) = try imported();model.visioArchive = nil;let out = file("vsdx");try VisioFormat.write(model,to:out)
        var native = try VisioFormat.read(from:out).diagram;let runs = try XCTUnwrap(native.page.nodes[0].formatting.textRuns)
        XCTAssertEqual(runs.map{$0.character.sourceIndex},[0,1,2,3])
        let value = NSMutableAttributedString(attributedString:ShapeRichText.attributed(native.page.nodes[0]));value.replaceCharacters(in:(value.string as NSString).range(of:"world"),with:"team")
        native.page.nodes[0] = ShapeRichText.applying(value,to:native.page.nodes[0]);try VisioFormat.write(native,to:out)
        var publicParts = try VisioPackage.read(out);publicParts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(publicParts,to:out)
        let restored = try VisioFormat.read(from:out).diagram;XCTAssertEqual(restored.page.nodes[0].text,"Hello 🙂 team\nNext line")
        XCTAssertEqual(restored.page.nodes[0].formatting.textRuns?.first{$0.text.contains("team")}?.character.fontName,"Courier New")
    }
    func testStandaloneParagraphBreakSurvivesUnrelatedGeometryEdit() throws {
        var (model,_) = try imported();model.page.nodes[0].x += 30
        let out = file("vsdx");try VisioFormat.write(model,to:out);var parts = try VisioPackage.read(out);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:out)
        try verify(VisioFormat.read(from:out).diagram)
    }
    func testIndexedMasterTextIsInheritedAndDefinitionPreservedOnEdit() throws {
        let (_,source) = try imported();var parts = try VisioPackage.read(source)
        let page = try VisioXML.element(String(decoding:parts["visio/pages/page1.xml"]!,as:UTF8.self)),shape = page.firstLocal("Shapes")!.allShapes[0]
        let ns = "http://schemas.microsoft.com/office/visio/2012/main",relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
        let master = Data("<MasterContents xmlns=\"\(ns)\"><Shapes>\(shape.xmlString)</Shapes></MasterContents>".utf8)
        parts["visio/masters/master1.xml"] = master
        parts["visio/masters/masters.xml"] = Data("<Masters xmlns=\"\(ns)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><Master ID=\"1\" NameU=\"Styled note\"><Rel r:id=\"rId1\"/></Master></Masters>".utf8)
        parts["visio/masters/_rels/masters.xml.rels"] = Data("<Relationships xmlns=\"\(relNS)\"><Relationship Id=\"rId1\" Type=\"http://schemas.microsoft.com/visio/2010/relationships/master\" Target=\"master1.xml\"/></Relationships>".utf8)
        let types = try VisioXML.document(parts["[Content_Types].xml"]!)
        for (name,type) in [("visio/masters/masters.xml","application/vnd.ms-visio.masters+xml"),("visio/masters/master1.xml","application/vnd.ms-visio.master+xml")] { let entry = XMLElement(name:"Override");entry.setAttr("PartName","/"+name);entry.setAttr("ContentType",type);types.rootElement()!.addChild(entry) }
        parts["[Content_Types].xml"] = types.xmlData(options:.nodePreserveAll)
        let rels = try VisioXML.document(parts["visio/_rels/document.xml.rels"]!),relation = XMLElement(name:"Relationship");relation.setAttr("Id","rIdMasters");relation.setAttr("Type","http://schemas.microsoft.com/visio/2010/relationships/masters");relation.setAttr("Target","masters/masters.xml");rels.rootElement()!.addChild(relation);parts["visio/_rels/document.xml.rels"] = rels.xmlData(options:.nodePreserveAll)
        parts["visio/pages/page1.xml"] = Data("<PageContents xmlns=\"\(ns)\"><Shapes><Shape ID=\"5\" Master=\"1\"/></Shapes></PageContents>".utf8);try VisioPackage.write(parts,to:source)
        var model = try VisioFormat.read(from:source).diagram;try verify(model)
        model.page.nodes[0].text = model.page.nodes[0].text.replacingOccurrences(of:"world",with:"team")
        let out = file("vsdx");try VisioFormat.write(model,to:out);var saved = try VisioPackage.read(out);XCTAssertEqual(saved["visio/masters/master1.xml"],master)
        saved.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(saved,to:out)
        XCTAssertEqual(try VisioFormat.read(from:out).diagram.page.nodes[0].formatting.textRuns?.first{$0.text.contains("team")}?.character.fontName,"Courier New")
    }
    func testDefaultCharacterFormulaChangesItsRunWithoutFlatteningOtherStyles() throws {
        var (model,_) = try imported();model.page.nodes[0].formatting.sheet["Char.Size"] = ShapeSheetCell(value:String(16.0/72),formula:"20pt")
        let changed = ShapeSheetEngine.recalculate(model).diagram,runs = try XCTUnwrap(changed.page.nodes[0].formatting.textRuns)
        XCTAssertEqual(runs.first?.character.size,20);XCTAssertEqual(runs.first{$0.text.contains("world")}?.character.size,22)
    }
    func testEmptyRichTextCanBeFilledThroughPlainTextAPI() throws {
        var (model,_) = try imported();model.page.nodes[0].text = "";XCTAssertEqual(model.page.nodes[0].formatting.textRuns,[])
        model.page.nodes[0].text = "Replacement";XCTAssertNoThrow(try model.validated());XCTAssertEqual(ShapeRichText.runs(for:model.page.nodes[0]).first?.text,"Replacement")
    }
    func testMixedTextRasterMatchesAtDifferentDrawingScales() throws {
        _ = NSApplication.shared
        let (model,_) = try imported();var scaled = model
        scaled.page.drawingScale = DrawingScale(page:1,drawing:50);scaled.page.width *= 50;scaled.page.height *= 50
        for i in scaled.page.nodes.indices { scaled.page.nodes[i].x *= 50;scaled.page.nodes[i].y *= 50;scaled.page.nodes[i].width *= 50;scaled.page.nodes[i].height *= 50 }
        let a = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(model.page,scale:1))),b = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(scaled.page,scale:1)))
        XCTAssertEqual(a.pixelsWide,b.pixelsWide);XCTAssertEqual(a.pixelsHigh,b.pixelsHigh)
        var differing = 0
        for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide {
            let p = a.colorAt(x:x,y:y)!,q = b.colorAt(x:x,y:y)!
            if abs(p.redComponent-q.redComponent)+abs(p.greenComponent-q.greenComponent)+abs(p.blueComponent-q.blueComponent) > 0.05 { differing += 1 }
        } }
        XCTAssertLessThan(differing,300,"Character sizes and paragraph layout must stay in paper units.")
    }
}
