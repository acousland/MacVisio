import AppKit
import XCTest
@testable import MacVisio

final class EditingCompatibilityTests:XCTestCase {
    private var urls:[URL] = []
    override func tearDown() { for url in urls { try? FileManager.default.removeItem(at:url) };super.tearDown() }
    private func temp(_ ext:String) -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-editing-\(UUID()).\(ext)");urls.append(url);return url }
    private func publicParts(_ url:URL) throws -> [String:Data] { var p = try VisioPackage.read(url);p.removeValue(forKey:"macvisio/document.json");return p }
    func testGroupMoveResizeFlipAndUngroupKeepChildrenAndDetachGlue() throws {
        var page = DiagramPage();let a = DiagramNode(x:100,y:100,text:"A"),b = DiagramNode(x:300,y:100,text:"B");page.nodes = [a,b]
        let id = try DiagramOperations.group([a.id,b.id],in:&page),old = page.nodes[0]
        var new = old;new.x += 40;new.y += 25;new.width *= 2;new.formatting.flipX = true
        page.nodes[0] = new;DiagramOperations.transformChildren(in:&page,from:old,to:new)
        let childA = try XCTUnwrap(page.nodes.first{$0.id == a.id}),childB = try XCTUnwrap(page.nodes.first{$0.id == b.id})
        XCTAssertEqual(childA.width,a.width*2);XCTAssertEqual(childA.y,a.y+25);XCTAssertTrue(childA.formatting.flipX);XCTAssertGreaterThan(childA.x,childB.x)
        page.edges = [DiagramEdge(source:id,target:a.id)]
        XCTAssertEqual(DiagramOperations.ungroup([id],in:&page),[a.id,b.id]);XCTAssertNil(page.nodes[0].parentID);XCTAssertNotNil(page.edges[0].sourcePosition)
        var diagram = Diagram();diagram.pages = [page];diagram.activePageID = page.id;XCTAssertNoThrow(try diagram.validated())
    }
    func testGroupInsertionUsesSingleTranslationAndRemapsFormulaAndConnections() throws {
        var fragment = DiagramPage();var a = DiagramNode(x:10,y:20,text:"A"),b = DiagramNode(x:210,y:20,text:"B")
        a.formatting.sourceShapeID = "1";b.formatting.sourceShapeID = "2";b.formatting.sheet["Width"] = ShapeSheetCell(value:"2",formula:"Sheet.1!Width*2")
        fragment.nodes = [a,b];let group = try DiagramOperations.group([a.id,b.id],in:&fragment);fragment.edges = [DiagramEdge(source:a.id,target:b.id)]
        var page = DiagramPage();page.width = 400
        let roots = try DiagramOperations.insert(fragment,into:&page,at:CGPoint(x:390,y:80),reservedIDs:["40"])
        XCTAssertEqual(roots.count,1);XCTAssertFalse(roots.contains(group));let x = page.nodes.first{$0.text == "A"}!,y = page.nodes.first{$0.text == "B"}!
        XCTAssertEqual(y.x-x.x,200);XCTAssertEqual(y.parentID,x.parentID);XCTAssertEqual(page.edges[0].source,x.id)
        XCTAssertEqual(y.formatting.sheet["Width"]?.formula,"Sheet.\(x.formatting.sourceShapeID!)!Width*2");XCTAssertGreaterThan(Int(x.formatting.sourceShapeID!)!,40)
    }
    func testDetachedConnectorInsertionTranslatesEntireRoute() throws {
        var fragment = DiagramPage();var edge = DiagramEdge(source:UUID(),target:UUID(),label:"Detached")
        edge.sourcePosition = DiagramPoint(x:1,y:2);edge.targetPosition = DiagramPoint(x:10,y:12);edge.points = [DiagramPoint(x:1,y:2),DiagramPoint(x:1,y:12),DiagramPoint(x:10,y:12)];fragment.edges = [edge]
        var page = DiagramPage();try DiagramOperations.insert(fragment,into:&page)
        XCTAssertEqual(page.edges[0].sourcePosition,DiagramPoint(x:21,y:22));XCTAssertEqual(page.edges[0].points?[1],DiagramPoint(x:21,y:32))
        XCTAssertNotEqual(page.edges[0].source,edge.source)
    }
    func testCachedPolylineDashAndBothArrowheadsSurvivePublicVisioXML() throws {
        var diagram = Diagram();var edge = DiagramEdge(source:UUID(),target:UUID(),label:"Route")
        edge.sourcePosition = DiagramPoint(x:20,y:30);edge.targetPosition = DiagramPoint(x:320,y:230)
        edge.points = [DiagramPoint(x:20,y:30),DiagramPoint(x:20,y:180),DiagramPoint(x:240,y:180),DiagramPoint(x:320,y:230)];edge.dash = 3;edge.startArrow = true;diagram.page.edges = [edge]
        let url = temp("vsdx");try VisioFormat.write(diagram,to:url);try VisioPackage.write(publicParts(url),to:url)
        let imported = try VisioFormat.read(from:url).diagram
        XCTAssertEqual(imported.page.edges[0].dash,3);XCTAssertEqual(imported.page.edges[0].startArrow,true)
        let route = DiagramGeometry.route(imported.page.edges[0],in:imported.page);XCTAssertEqual(route.count,4)
        XCTAssertEqual(route[1].x,20,accuracy:0.001);XCTAssertEqual(route[1].y,180,accuracy:0.001);XCTAssertEqual(route[2].x,240,accuracy:0.001)
        XCTAssertTrue(DiagramDrawing.svg(imported.page).contains("stroke-dasharray="))
    }
    func testImageFontAndOffsetTextBlockArePresentInPublicInterchange() throws {
        _ = NSApplication.shared
        var diagram = Diagram();var n = DiagramNode(x:80,y:90,text:"Offset text")
        let image = NSImage(size:CGSize(width:10,height:10),flipped:true){_ in NSColor.red.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:10,height:10)).fill();return true}
        let rep = NSBitmapImageRep(data:image.tiffRepresentation!)!
        n.formatting.image = EmbeddedImage(data:rep.representation(using:.png,properties:[:])!,mimeType:"image/png")
        n.formatting.fontName = "Courier New";n.formatting.italic = true;n.formatting.underline = true;n.formatting.alignment = .left
        n.formatting.textBox = ShapeTextBox(centerX:0.6,centerY:0.4,width:0.8,height:0.5,rotation:10,left:2,right:3,top:1,bottom:4,verticalAlignment:0)
        diagram.page.nodes = [n];let url = temp("vsdx");try VisioFormat.write(diagram,to:url);try VisioPackage.write(publicParts(url),to:url)
        let result = try VisioFormat.read(from:url).diagram.page.nodes[0]
        XCTAssertEqual(result.formatting.fontName,"Courier New");XCTAssertTrue(result.formatting.italic);XCTAssertTrue(result.formatting.underline);XCTAssertEqual(result.formatting.alignment,.left)
        XCTAssertEqual(result.formatting.image?.data,n.formatting.image?.data);XCTAssertEqual(result.formatting.textBox?.centerX ?? 0,0.6,accuracy:0.001);XCTAssertEqual(result.formatting.textBox?.rotation ?? 0,10,accuracy:0.001)
    }
    func testRealOPCStencilMasterLoadsAndInsertsAsEditableShapes() throws {
        var diagram = Diagram();diagram.page.nodes = [DiagramNode(x:100,y:120,text:"Stencil master")]
        let url = temp("vssx");try VisioFormat.write(diagram,to:url);var parts = try publicParts(url)
        let contents = try VisioXML.document(parts["visio/pages/page1.xml"]!);contents.rootElement()!.name = "MasterContents"
        parts["visio/masters/master1.xml"] = contents.xmlData(options:.nodePreserveAll)
        let ns = "http://schemas.microsoft.com/office/visio/2012/main",rns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships",pkg = "http://schemas.openxmlformats.org/package/2006/relationships",base = "http://schemas.microsoft.com/visio/2010/relationships/"
        parts["visio/masters/masters.xml"] = Data("<Masters xmlns=\"\(ns)\" xmlns:r=\"\(rns)\"><Master ID=\"1\" Name=\"Test master\"><Rel r:id=\"rId1\"/></Master></Masters>".utf8)
        parts["visio/masters/_rels/masters.xml.rels"] = Data("<Relationships xmlns=\"\(pkg)\"><Relationship Id=\"rId1\" Type=\"\(base)master\" Target=\"master1.xml\"/></Relationships>".utf8)
        let rels = try VisioXML.document(parts["visio/_rels/document.xml.rels"]!);rels.rootElement()!.addChild(try VisioXML.element("<Relationship Id=\"stencilMasters\" Type=\"\(base)masters\" Target=\"masters/masters.xml\"/>"));parts["visio/_rels/document.xml.rels"] = rels.xmlData(options:.nodePreserveAll)
        try VisioPackage.write(parts,to:url)
        let items = try VisioStencil.read(from:url).items;XCTAssertEqual(items.count,1);XCTAssertEqual(items[0].name,"Test master");XCTAssertEqual(items[0].fragment.nodes[0].text,"Stencil master");XCTAssertEqual(items[0].fragment.nodes[0].x,0,accuracy:0.001)
        var page = DiagramPage();try DiagramOperations.insert(items[0].fragment,into:&page,at:CGPoint(x:50,y:70));XCTAssertEqual(page.nodes[0].x,50,accuracy:0.001)
    }
    func testVSDXFormatterNeverWritesToVSDDestination() throws {
        let url = temp("vsd"),original = Data("original file".utf8);try original.write(to:url)
        XCTAssertThrowsError(try VisioFormat.write(Diagram(),to:url));XCTAssertEqual(try Data(contentsOf:url),original)
        let doc = MacVisioDocument();XCTAssertThrowsError(try doc.write(to:url,ofType:MacVisioDocument.visioType));XCTAssertEqual(try Data(contentsOf:url),original)
    }
    func testDetachedConnectorCanSwitchBetweenOrthogonalAndStraightRouting() {
        var line = DiagramEdge(source:UUID(),target:UUID());line.sourcePosition = DiagramPoint(x:10,y:20);line.targetPosition = DiagramPoint(x:200,y:150)
        let route = DiagramGeometry.route(line,in:DiagramPage());XCTAssertEqual(route.count,4)
        for (a,b) in zip(route,route.dropFirst()) { XCTAssertTrue(a.x == b.x || a.y == b.y) }
        line.style = .straight;XCTAssertEqual(DiagramGeometry.route(line,in:DiagramPage()).count,2)
    }
    func testDuplicateNestedShapeAndLayerIDsThrowInsteadOfCrashing() throws {
        var diagram = Diagram();var group = DiagramNode(x:100,y:100,text:"");group.formatting.isGroup = true
        var child = DiagramNode(x:120,y:120,text:"Child");child.parentID = group.id;diagram.page.nodes = [group,child]
        let url = temp("vsdx");try VisioFormat.write(diagram,to:url);let original = try publicParts(url)
        var parts = original;let page = try VisioXML.document(parts["visio/pages/page1.xml"]!)
        let a = page.rootElement()!.firstLocal("Shapes")!.firstLocal("Shape")!,b = a.firstLocal("Shapes")!.firstLocal("Shape")!
        b.setAttr("ID",a.attr("ID"));parts["visio/pages/page1.xml"] = page.xmlData(options:.nodePreserveAll);try VisioPackage.write(parts,to:url)
        XCTAssertThrowsError(try VisioFormat.read(from:url))
        parts = original;let index = try VisioXML.document(parts["visio/pages/pages.xml"]!),sheet = index.rootElement()!.firstLocal("Page")!.firstLocal("PageSheet")!
        sheet.addChild(try VisioXML.element("<Section N=\"Layer\"><Row IX=\"0\"><Cell N=\"Name\" V=\"A\"/></Row><Row IX=\"0\"><Cell N=\"Name\" V=\"B\"/></Row></Section>"))
        parts["visio/pages/pages.xml"] = index.xmlData(options:.nodePreserveAll);try VisioPackage.write(parts,to:url);XCTAssertThrowsError(try VisioFormat.read(from:url))
    }
}
