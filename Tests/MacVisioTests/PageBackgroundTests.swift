import AppKit
import XCTest
@testable import MacVisio

final class PageBackgroundTests:XCTestCase {
    private var urls:[URL] = []
    override func tearDown() { for url in urls { try? FileManager.default.removeItem(at:url) };super.tearDown() }
    private func temp(_ ext:String = "vsdx") -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("PageBackground-\(UUID()).\(ext)");urls.append(u);return u }
    private func sample() -> Diagram {
        var d = Diagram();d.page.name = "First";d.page.width = 240;d.page.height = 200
        var bg = DiagramPage(name:"Shared border",width:240,height:200);bg.isBackground = true
        var border = DiagramNode(x:20,y:20,text:"");border.width = 200;border.height = 160;border.fill = "#FF0000";border.strokeWidth = 0;border.stroke = "#FFFFFF00";bg.nodes = [border]
        var front = DiagramNode(x:80,y:70,text:"");front.width = 80;front.height = 60;front.fill = "#0000FF";front.strokeWidth = 0;front.stroke = "#FFFFFF00"
        d.page.nodes = [front];d.page.backgroundPageID = bg.id
        var second = d.page;second.id = UUID();second.name = "Second";second.width = 320;second.height = 240
        d.pages.append(second);d.pages.append(bg);return d
    }
    private func publicRead(_ diagram:Diagram) throws -> Diagram {
        let url = temp();try VisioFormat.write(diagram,to:url);var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:url);return try VisioFormat.read(from:url).diagram
    }
    func testPublicVSDXFlagsReferencesAndInitialForegroundSelection() throws {
        var d = sample();let bg = d.pages.removeLast();d.pages.insert(bg,at:0)
        let result = try publicRead(d);XCTAssertTrue(result.pages[0].isBackground == true);XCTAssertEqual(result.page.name,"First")
        XCTAssertEqual(result.pages[1].backgroundPageID,result.pages[0].id);XCTAssertEqual(result.pages[2].backgroundPageID,result.pages[0].id)
        XCTAssertEqual(result.scene().backgrounds.map(\.name),["Shared border"]);XCTAssertNoThrow(try result.validated())
    }
    func testSharedBackgroundSceneLayeringAndLowerLeftAlignment() throws {
        let d = sample(),scene = d.scene(for:d.pages[1].id)
        XCTAssertEqual(scene.layers.map(\.name),["Shared border","Second"]);XCTAssertEqual(scene.offset(for:scene.backgrounds[0]),CGPoint(x:0,y:40))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(d.scene(),scale:1)))
        func rgb(_ x:Int,_ y:Int) throws -> NSColor { try XCTUnwrap(bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB)) }
        let red = try rgb(40,40),blue = try rgb(110,100),white = try rgb(5,5)
        XCTAssertGreaterThan(red.redComponent,0.9);XCTAssertLessThan(red.blueComponent,0.1)
        XCTAssertGreaterThan(blue.blueComponent,0.9);XCTAssertLessThan(blue.redComponent,0.1);XCTAssertGreaterThan(white.greenComponent,0.9)
        let svg = DiagramDrawing.svg(scene);XCTAssertTrue(svg.contains("translate(0.0 40.0)"));XCTAssertTrue(svg.contains("clip-path=\"url(#paperClip)\""));XCTAssertNoThrow(try VisioXML.document(Data(svg.utf8)))
    }
    func testBackgroundAndForegroundLayerNamesAreIndependent() throws {
        var d = sample();d.pages[2].nodes[0].layer = "Same name";d.pages[2].layers = [DiagramLayer(name:"Same name",printable:false)]
        d.pages[0].nodes[0].layer = "Same name";d.pages[0].layers = [DiagramLayer(name:"Same name")]
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(d.scene(),scale:1)))
        let corner = try XCTUnwrap(bitmap.colorAt(x:40,y:40)?.usingColorSpace(.deviceRGB)),center = try XCTUnwrap(bitmap.colorAt(x:110,y:100)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(corner.greenComponent,0.9);XCTAssertGreaterThan(center.blueComponent,0.9)
        XCTAssertFalse(DiagramDrawing.svg(d.scene()).contains("#FF0000"));XCTAssertTrue(DiagramDrawing.svg(d.scene()).contains("#0000FF"))
    }
    func testConnectorsUseTheirOwnPageWhenNodeIDsCollideAcrossLayers() throws {
        var d = sample(),a = DiagramNode(x:20,y:120,text:""),b = DiagramNode(x:100,y:120,text:"")
        a.width = 30;a.height = 30;b.width = 30;b.height = 30;a.fill = "#FFFFFF00";b.fill = "#FFFFFF00";a.strokeWidth = 0;b.strokeWidth = 0
        d.pages[0].nodes = [a,b];a.y = 20;b.y = 20;d.pages[2].nodes = [a,b]
        var edge = DiagramEdge(source:a.id,target:b.id,color:"#000000",width:2,style:.straight,arrow:false)
        d.pages[0].edges = [edge];edge.color = "#00FF00";d.pages[2].edges = [edge]
        XCTAssertNoThrow(try d.validated())
        let svg = DiagramDrawing.svg(d.scene());XCTAssertTrue(svg.contains("M 50.0 35.0 L 100.0 35.0"));XCTAssertTrue(svg.contains("M 50.0 135.0 L 100.0 135.0"))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(d.scene(),scale:1))),color = try XCTUnwrap(bitmap.colorAt(x:75,y:35)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.greenComponent,0.9);XCTAssertLessThan(color.redComponent,0.1)
    }
    func testNestedBackgroundsCyclesMissingReferencesAndDemotion() throws {
        var d = sample(),base = DiagramPage(name:"Base");base.isBackground = true;d.pages[2].backgroundPageID = base.id;d.pages.append(base)
        XCTAssertEqual(d.scene().backgrounds.map(\.name),["Base","Shared border"]);XCTAssertNoThrow(try d.validated())
        var bad = d;bad.pages[3].backgroundPageID = bad.pages[2].id;XCTAssertThrowsError(try bad.validated())
        bad = d;bad.pages[0].backgroundPageID = UUID();XCTAssertThrowsError(try bad.validated())
        XCTAssertFalse(PageOperations.backgroundCandidates(for:base.id,in:d).contains{$0.id == d.pages[2].id})
        try PageOperations.configure(d.pages[2].id,in:&d,isBackground:false)
        XCTAssertNil(d.pages[0].backgroundPageID);XCTAssertNil(d.pages[1].backgroundPageID);XCTAssertEqual(d.pages[2].backgroundPageID,base.id)
    }
    func testLongValidBackgroundChainDoesNotHaveAnArbitrary64PageLimit() throws {
        var d = Diagram(),last = d.page.id
        for i in 0..<100 { var bg = DiagramPage(name:"BG \(i)");bg.isBackground = true;d.pages.append(bg);try PageOperations.configure(last,in:&d,background:.some(bg.id));last = bg.id }
        XCTAssertEqual(d.scene().backgrounds.count,100);XCTAssertNoThrow(try d.validated())
    }
    func testPageResizePreservesLiteralVisioCoordinatesAndFreeRoutes() throws {
        var d = sample(),line = DiagramEdge(source:UUID(),target:UUID(),style:.straight);line.sourcePosition = DiagramPoint(x:10,y:20);line.targetPosition = DiagramPoint(x:100,y:80);line.points = [line.sourcePosition!,line.targetPosition!];d.page.edges = [line]
        let old = d.page.nodes[0],oldPin = ShapeSheetEngine.defaults(old,page:d.page)["PinY"]!
        try PageOperations.configure(d.page.id,in:&d,width:300,height:280)
        XCTAssertEqual(d.page.nodes[0].y,old.y+80);XCTAssertEqual(ShapeSheetEngine.defaults(d.page.nodes[0],page:d.page)["PinY"]!,oldPin,accuracy:1e-12)
        XCTAssertEqual(d.page.edges[0].sourcePosition?.y,100);XCTAssertEqual(d.page.edges[0].points?[1].y,160)
    }
    func testDeletingAndAddingBackgroundsPatchesPublicIndexAndRetainsOpaqueParts() throws {
        let source = temp();try VisioFormat.write(sample(),to:source);var parts = try VisioPackage.read(source);parts.removeValue(forKey:"macvisio/document.json");parts["vendor/original.bin"] = Data([1,2,3]);try VisioPackage.write(parts,to:source)
        var d = try VisioFormat.read(from:source).diagram;let bg = d.pages[2].id
        try PageOperations.delete(bg,in:&d);XCTAssertNil(d.pages[0].backgroundPageID);XCTAssertNil(d.pages[1].backgroundPageID)
        let added = try PageOperations.addBackground(to:d.pages[0].id,in:&d);XCTAssertEqual(d.activePageID,added)
        let destination = temp();try VisioFormat.write(d,to:destination);parts = try VisioPackage.read(destination);XCTAssertEqual(parts["vendor/original.bin"],Data([1,2,3]));parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:destination)
        let result = try VisioFormat.read(from:destination).diagram
        XCTAssertEqual(result.pages.filter{$0.isBackground == true}.count,1);XCTAssertEqual(result.pages[0].backgroundPageID,result.pages[2].id);XCTAssertNil(result.pages[1].backgroundPageID)
    }
    func testUneditedExternalBackgroundPackageRetainsEveryPartByte() throws {
        let url = temp();try VisioFormat.write(sample(),to:url);var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:url)
        let imported = try VisioFormat.read(from:url).diagram,output = temp();try VisioFormat.write(imported,to:output)
        XCTAssertEqual(try VisioPackage.read(output),parts)
    }
    func testAllPagePDFUsesForegroundSizesAndCanIncludeBackgroundPages() throws {
        let d = sample(),data = try DiagramExport.pdf(d),provider = try XCTUnwrap(CGDataProvider(data:data as CFData)),pdf = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(pdf.numberOfPages,2);XCTAssertEqual(pdf.page(at:1)?.getBoxRect(.mediaBox).size,CGSize(width:240,height:200));XCTAssertEqual(pdf.page(at:2)?.getBoxRect(.mediaBox).size,CGSize(width:320,height:240))
        let all = try DiagramExport.pdf(d,includeBackgroundPages:true),allProvider = try XCTUnwrap(CGDataProvider(data:all as CFData));XCTAssertEqual(CGPDFDocument(allProvider)?.numberOfPages,3)
    }
    func testBackgroundEditsUndoAndForegroundCanvasDoesNotSelectBackgroundShapes() throws {
        _ = NSApplication.shared
        let doc = MacVisioDocument();doc.diagram = sample();doc.makeWindowControllers();let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        defer{editor.window?.delegate = nil;doc.removeWindowController(editor)}
        let foreground = doc.diagram.page.id,bg = doc.diagram.pages[2].id
        XCTAssertNil(editor.canvas.node(at:CGPoint(x:40,y:40)));editor.configurePage(background:.some(nil));XCTAssertNil(doc.diagram.page.backgroundPageID)
        doc.undoManager?.undo();XCTAssertEqual(doc.diagram.page.backgroundPageID,bg)
        editor.switchPage(bg);XCTAssertNotNil(editor.canvas.node(at:CGPoint(x:40,y:40)));editor.canvas.pendingSource = doc.diagram.page.nodes[0].id;editor.switchPage(foreground);XCTAssertNil(editor.canvas.pendingSource)
    }
    func testBinaryBackgroundReferencesArePublicAndReopenWithoutNativeMetadata() throws {
        let d = sample(),url = temp("vsd");try VSDBinaryFormat.encoded(d,includeMetadata:false).write(to:url)
        let imported = try LegacyVisioFormat.read(from:url).diagram
        XCTAssertEqual(imported.pages.count,3);XCTAssertTrue(imported.pages[0].nodes.contains{!$0.formatting.paths.isEmpty})
        let regions = imported.pages[0].nodes.filter{!$0.formatting.paths.isEmpty};XCTAssertTrue(regions.contains{$0.fill.hasPrefix("#FF0000")});XCTAssertTrue(regions.contains{$0.fill.hasPrefix("#0000FF")})
    }
    func testOlderNativeMetadataHydratesMissingBackgroundFieldsFromPublicXML() throws {
        let url = temp();try VisioFormat.write(sample(),to:url);var parts = try VisioPackage.read(url)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with:parts["macvisio/document.json"]!) as? [String:Any])
        var diagram = envelope["diagram"] as! [String:Any],pages = diagram["pages"] as! [[String:Any]]
        for i in pages.indices { pages[i].removeValue(forKey:"isBackground");pages[i].removeValue(forKey:"backgroundPageID") };diagram["pages"] = pages;envelope["diagram"] = diagram
        var bindings = envelope["bindings"] as! [[String:Any]]
        for i in bindings.indices { var page = bindings[i]["original"] as! [String:Any];page.removeValue(forKey:"isBackground");page.removeValue(forKey:"backgroundPageID");bindings[i]["original"] = page };envelope["bindings"] = bindings
        parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:envelope);try VisioPackage.write(parts,to:url)
        let result = try VisioFormat.read(from:url).diagram
        XCTAssertTrue(result.pages[2].isBackground == true);XCTAssertEqual(result.pages[0].backgroundPageID,result.pages[2].id)
        let output = temp();try VisioFormat.write(result,to:output)
        XCTAssertEqual(try VisioPackage.read(output).filter{$0.key != "macvisio/document.json"},parts.filter{$0.key != "macvisio/document.json"})
    }
    func testPageResizeAndBackgroundAssignmentRetainOriginalShapeXMLAndFormulas() throws {
        let url = temp();try VisioFormat.write(sample(),to:url);var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json")
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!),shape = xml.rootElement()!.firstLocal("Shapes")!.firstLocal("Shape")!
        let value = VisioXML.value(shape,"PinY")!;VisioXML.set(shape,"PinY",value,formula:"UNSUPPORTED_SAVED_PIN()")
        shape.addChild(try VisioXML.element("<Extension xmlns=\"urn:private\" preserved=\"yes\"/>"));parts["visio/pages/page1.xml"] = xml.xmlData(options:.nodePreserveAll)
        try VisioPackage.write(parts,to:url);var d = try VisioFormat.read(from:url).diagram
        try PageOperations.configure(d.pages[0].id,in:&d,height:280,background:.some(nil))
        let output = temp();try VisioFormat.write(d,to:output);let after = try VisioPackage.read(output)
        XCTAssertEqual(after["visio/pages/page1.xml"],parts["visio/pages/page1.xml"])
        var publicParts = after;publicParts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(publicParts,to:output)
        let restored = try VisioFormat.read(from:output).diagram
        XCTAssertEqual(restored.pages[0].height,280,accuracy:0.0001);XCTAssertEqual(restored.pages[0].nodes[0].y,d.pages[0].nodes[0].y,accuracy:0.0001)
        XCTAssertEqual(restored.pages[0].nodes[0].formatting.sheet["PinY"]?.formula,"UNSUPPORTED_SAVED_PIN()")
    }
    func testPageIdentifierAllocationWrapsWithinUnsigned32Bits() throws {
        let url = temp();try VisioFormat.write(sample(),to:url);var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json")
        let index = try VisioXML.document(parts["visio/pages/pages.xml"]!),pages = index.rootElement()!.elementsLocal("Page")
        pages[0].setAttr("ID",String(UInt32.max));pages[1].setAttr("ID","0");pages[2].setAttr("ID","1");pages[0].setAttr("BackPage","1");pages[1].setAttr("BackPage","1")
        parts["visio/pages/pages.xml"] = index.xmlData(options:.nodePreserveAll);try VisioPackage.write(parts,to:url)
        var d = try VisioFormat.read(from:url).diagram;try PageOperations.addBackground(to:d.pages[0].id,in:&d)
        let output = temp();try VisioFormat.write(d,to:output);parts = try VisioPackage.read(output);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:output)
        let ids = try VisioXML.document(parts["visio/pages/pages.xml"]!).rootElement()!.elementsLocal("Page").compactMap{$0.attr("ID").flatMap(UInt32.init)}
        XCTAssertEqual(Set(ids),[UInt32.max,0,1,2]);XCTAssertEqual(try VisioFormat.read(from:output).diagram.pages.count,4)
    }
}
