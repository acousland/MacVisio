import AppKit
import XCTest
@testable import MacVisio

final class StencilLibraryTests:XCTestCase {
    private var temporary:[URL] = []
    override func tearDown() { for url in temporary { try? FileManager.default.removeItem(at:url) };super.tearDown() }
    private func temp(_ ext:String) -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-library-\(UUID()).\(ext)");temporary.append(url);return url }
    private var installerLibrary:URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/Visio2019-Libraries") }
    func testActualInstallerFlowchartStencilImportsAndInsertsPorts() throws {
        let url = installerLibrary.appendingPathComponent("BASFLO_M.VSSX")
        guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Extract the user-supplied ISO libraries for installer interoperability checks.") }
        let result = try VisioStencil.read(from:url)
        XCTAssertEqual(result.items.count,15)
        let process = try XCTUnwrap(result.items.first{$0.name == "Process"})
        XCTAssertFalse(process.fragment.nodes.isEmpty)
        XCTAssertFalse(process.fragment.nodes.flatMap{$0.formatting.connectionPoints}.isEmpty)
        let document = try XCTUnwrap(result.items.first{$0.name == "Document"})
        XCTAssertEqual(document.fragment.nodes.flatMap{$0.formatting.paths.flatMap(\.commands)}.filter{$0.kind == "C"}.count,2)
        var page = DiagramPage();let selected = try DiagramOperations.insert(process.fragment,into:&page,at:CGPoint(x:100,y:120))
        XCTAssertFalse(selected.isEmpty);XCTAssertTrue(page.nodes.allSatisfy{$0.rect.minX >= 100-0.001})
        var diagram = Diagram();diagram.pages = [page];diagram.activePageID = page.id
        let saved = temp("vsdx");try VisioFormat.write(diagram,to:saved)
        var parts = try VisioPackage.read(saved);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:saved)
        let restored = try VisioFormat.read(from:saved).diagram
        XCTAssertEqual(restored.page.nodes.count,page.nodes.count)
        XCTAssertEqual(restored.page.nodes.map{$0.formatting.connectionPoints.count},page.nodes.map{$0.formatting.connectionPoints.count})
    }
    func testActualInstallerTemplateOpensPublicPages() throws {
        let url = installerLibrary.appendingPathComponent("BASFLO_M.VSTX")
        guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Extract the user-supplied ISO libraries for installer interoperability checks.") }
        let doc = MacVisioDocument();try doc.read(from:url,ofType:MacVisioDocument.visioType)
        XCTAssertFalse(doc.diagram.pages.isEmpty);XCTAssertNoThrow(try doc.diagram.validated())
    }
    func testLegacyMasterGraphicsAreDecodedInsteadOfDrawingPages() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource:"Visio11FormatLine",withExtension:"vsd",subdirectory:"Fixtures"))
        let stencil = temp("vss");try Data(contentsOf:source).write(to:stencil)
        let result = try VisioStencil.read(from:stencil)
        XCTAssertFalse(result.items.isEmpty);XCTAssertFalse(result.items.flatMap{$0.fragment.nodes}.isEmpty)
        XCTAssertTrue(result.warnings.contains{$0.contains("Original master names")})
        let drawing = try LegacyVisioFormat.read(from:source).diagram
        XCTAssertNotEqual(result.items.map{$0.fragment.nodes.count},drawing.pages.map{$0.nodes.count})
    }
    func testLegacyTemplateUsesBinaryDecoderAndRejectsWrongSignature() throws {
        let source = try XCTUnwrap(Bundle.module.url(forResource:"Visio11FormatLine",withExtension:"vsd",subdirectory:"Fixtures"))
        let template = temp("vst");try Data(contentsOf:source).write(to:template)
        let doc = MacVisioDocument();try doc.read(from:template,ofType:MacVisioDocument.legacyType)
        XCTAssertFalse(doc.diagram.page.nodes.isEmpty)
        let invalid = temp("vss");try Data("invalid".utf8).write(to:invalid)
        XCTAssertThrowsError(try VisioStencil.read(from:invalid))
    }
    func testReusableStencilPublicPartsPreserveGroupsGlueAndMedia() throws {
        _ = NSApplication.shared
        var page = DiagramPage();var a = DiagramNode(x:100,y:110,text:"Source"),b = DiagramNode(x:330,y:110,text:"Target")
        a.formatting.connectionPoints = [ShapeConnectionPoint(index:0,name:"Output",x:ShapeSheetCell(value:"1.8",formula:"Width"),y:ShapeSheetCell(value:"0.5"))]
        b.formatting.data = [ShapeDataProperty(key:"Code",label:"Code",value:"00125")]
        page.nodes = [a,b];var edge = DiagramEdge(source:a.id,target:b.id,label:"Reusable glue");edge.sourcePort = "N:Output";page.edges = [edge]
        _ = try DiagramOperations.group([a.id,b.id],in:&page)
        let image = NSImage(size:CGSize(width:8,height:8),flipped:true){_ in NSColor.red.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:8,height:8)).fill();return true}
        page.nodes[1].formatting.image = EmbeddedImage(data:try XCTUnwrap(NSBitmapImageRep(data:try XCTUnwrap(image.tiffRepresentation))?.representation(using:.png,properties:[:])),mimeType:"image/png")
        let file = temp("vssx");try VisioReusableFormat.writeStencil([StencilDefinition(name:"Reusable group",family:"Tests",fragment:page)],to:file)
        let parts = try VisioPackage.read(file)
        XCTAssertNil(parts["macvisio/document.json"]);XCTAssertFalse(parts.keys.contains{$0.hasPrefix("visio/pages/")})
        XCTAssertNotNil(parts["visio/masters/master1.xml"])
        XCTAssertTrue(String(decoding:parts["[Content_Types].xml"]!,as:UTF8.self).contains("application/vnd.ms-visio.stencil.main+xml"))
        let restored = try VisioStencil.read(from:file).items
        XCTAssertEqual(restored.count,1);XCTAssertEqual(restored[0].name,"Reusable group")
        XCTAssertTrue(restored[0].fragment.nodes.contains{$0.formatting.isGroup});XCTAssertTrue(restored[0].fragment.nodes.contains{$0.formatting.image != nil})
        XCTAssertTrue(restored[0].fragment.nodes.contains{$0.formatting.data.contains{$0.value == "00125"}})
        XCTAssertEqual(restored[0].fragment.edges[0].sourcePort,"N:Output");XCTAssertNotNil(restored[0].fragment.edges[0].parentID)
        let helper = try XCTUnwrap(LegacyVisioFormat.stencilConverterURL);let task = Process(),pipe = Pipe();task.executableURL = helper;task.arguments = [file.path];task.standardOutput = pipe;try task.run();let output = pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus,0);XCTAssertTrue(String(decoding:output,as:UTF8.self).contains("Reusable glue"))
    }
    func testTemplateContentTypeAndDrawingConversionKeepNativeAndPublicContent() throws {
        var model = DiagramTemplate.flowchart.makeDiagram();model.page.nodes[0].formatting.data = [ShapeDataProperty(key:"Code",label:"Code",value:"00125")]
        let template = temp("vstx");try VisioReusableFormat.writeTemplate(model,to:template)
        let parts = try VisioPackage.read(template)
        XCTAssertTrue(String(decoding:parts["[Content_Types].xml"]!,as:UTF8.self).contains("application/vnd.ms-visio.template.main+xml"))
        let imported = try VisioFormat.read(from:template).diagram
        XCTAssertEqual(imported.pages,model.pages)
        let drawing = temp("vsdx");try VisioFormat.write(imported,to:drawing)
        var publicParts = try VisioPackage.read(drawing)
        XCTAssertTrue(String(decoding:publicParts["[Content_Types].xml"]!,as:UTF8.self).contains("application/vnd.ms-visio.drawing.main+xml"))
        publicParts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(publicParts,to:drawing)
        let publicModel = try VisioFormat.read(from:drawing).diagram
        XCTAssertEqual(publicModel.page.nodes.map(\.text),model.page.nodes.map(\.text))
        XCTAssertEqual(publicModel.page.nodes[0].formatting.data.first?.value,"00125")
    }
    func testLibraryEnumerationFilteringAndSymlinkExclusion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-folder-\(UUID())")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);temporary.append(folder)
        for name in ["BASFLO_M.VSSX","BASFLO_M.VSTX","NETWORK.vss","other.txt"] { try Data().write(to:folder.appendingPathComponent(name)) }
        try FileManager.default.createSymbolicLink(at:folder.appendingPathComponent("link.vssx"),withDestinationURL:folder.appendingPathComponent("BASFLO_M.VSSX"))
        let entries = try VisioLibrary.entries(in:folder)
        XCTAssertEqual(entries.count,3);XCTAssertEqual(VisioLibrary.filter(entries,query:"basflo Stencil").map{$0.url.lastPathComponent},["BASFLO_M.VSSX"])
        XCTAssertEqual(VisioLibrary.filter(entries,query:"template").count,1)
        _ = NSApplication.shared;let picker = VisioLibraryPicker(entries:entries);picker.search.stringValue = "network";picker.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification))
        XCTAssertEqual(picker.selected?.name,"NETWORK")
    }
    func testConnectorOnlyMasterNormalizesItsPreviewAndPlacesAtDropPoint() throws {
        var page = DiagramPage();var edge = DiagramEdge(source:UUID(),target:UUID(),style:.straight)
        edge.sourcePosition = DiagramPoint(x:160,y:280);edge.targetPosition = DiagramPoint(x:260,y:280);page.edges = [edge]
        let master = try XCTUnwrap(VisioStencil.definitions([page],family:"Tests").first)
        XCTAssertEqual(master.fragment.width,100,accuracy:0.001);XCTAssertEqual(master.fragment.height,1,accuracy:0.001)
        XCTAssertEqual(master.fragment.edges[0].sourcePosition,DiagramPoint(x:0,y:0))
        var destination = DiagramPage();try DiagramOperations.insert(master.fragment,into:&destination,at:CGPoint(x:60,y:70))
        XCTAssertEqual(destination.edges[0].sourcePosition,DiagramPoint(x:60,y:70));XCTAssertEqual(destination.edges[0].targetPosition,DiagramPoint(x:160,y:70))
    }
    func testEllipticalArcRotatedRatioAndMajorSweep() throws {
        let angle = Double.pi/3,c = cos(angle),s = sin(angle)
        func ellipse(_ t:Double) -> CGPoint { CGPoint(x:10+c*2*cos(t)-s*sin(t),y:20+s*2*cos(t)+c*sin(t)) }
        let segments = try XCTUnwrap(VisioEllipticalArc.cubics(from:ellipse(0),through:ellipse(.pi/4),to:ellipse(.pi/2),angle:angle,ratio:2))
        XCTAssertEqual(segments.count,1)
        let k = 4.0/3*tan(Double.pi/8),expected = CGPoint(x:ellipse(0).x-s*k,y:ellipse(0).y+c*k)
        XCTAssertEqual(segments[0].0.x,expected.x,accuracy:1e-10);XCTAssertEqual(segments[0].0.y,expected.y,accuracy:1e-10)
        XCTAssertEqual(segments[0].2,ellipse(.pi/2))
        let major = try XCTUnwrap(VisioEllipticalArc.cubics(from:ellipse(0),through:ellipse(.pi),to:ellipse(.pi/2),angle:angle,ratio:2))
        XCTAssertEqual(major.count,3);XCTAssertEqual(major.last?.2,ellipse(.pi/2))
        XCTAssertNil(VisioEllipticalArc.cubics(from:.zero,through:CGPoint(x:1,y:0),to:CGPoint(x:2,y:0),angle:0,ratio:1))
        XCTAssertNil(VisioEllipticalArc.cubics(from:.zero,through:CGPoint(x:1,y:1),to:CGPoint(x:2,y:0),angle:0,ratio:0))
    }
    func testDeletedSentinelsZeroAxesAndUnnamedLayersKeepPublicSource() throws {
        var model = Diagram();model.page.nodes = [DiagramNode(x:40,y:60,text:"Live shape")]
        let source = temp("vsdx");try VisioFormat.write(model,to:source)
        var parts = try VisioPackage.read(source);parts.removeValue(forKey:"macvisio/document.json")
        let content = try VisioXML.document(parts["visio/pages/page1.xml"]!),shapes = content.rootElement()!.firstLocal("Shapes")!
        VisioXML.set(shapes.firstLocal("Shape")!,"Width",0)
        for masterID in ["7","9"] { shapes.addChild(try VisioXML.element("<Shape ID=\"4294967295\" MasterShape=\"\(masterID)\" Del=\"1\"/>")) }
        parts["visio/pages/page1.xml"] = content.xmlData(options:.nodePreserveAll)
        let index = try VisioXML.document(parts["visio/pages/pages.xml"]!),sheet = index.rootElement()!.firstLocal("Page")!.firstLocal("PageSheet")!
        sheet.addChild(try VisioXML.element("<Section N=\"Layer\"><Row IX=\"0\"><Cell N=\"Name\" V=\"\"/></Row><Row IX=\"1\"><Cell N=\"Name\" V=\"\"/></Row></Section>"))
        parts["visio/pages/pages.xml"] = index.xmlData(options:.nodePreserveAll);try VisioPackage.write(parts,to:source)
        let imported = try VisioFormat.read(from:source).diagram
        XCTAssertEqual(imported.page.nodes.count,1);XCTAssertEqual(imported.page.nodes[0].width,0.000072,accuracy:1e-12)
        XCTAssertEqual(Set(imported.page.layers!.map(\.name)).count,2)
        let unchanged = temp("vsdx");try VisioFormat.write(imported,to:unchanged);XCTAssertEqual(try VisioPackage.read(unchanged),parts)
        var edited = imported;edited.page.nodes[0].text = "Edited live shape";let saved = temp("vsdx");try VisioFormat.write(edited,to:saved)
        let editedParts = try VisioPackage.read(saved),editedXML = try VisioXML.document(editedParts["visio/pages/page1.xml"]!)
        XCTAssertEqual(editedXML.rootElement()!.firstLocal("Shapes")!.elementsLocal("Shape").filter{$0.attr("Del") == "1"}.count,2)
        XCTAssertEqual(VisioXML.value(editedXML.rootElement()!.firstLocal("Shapes")!.firstLocal("Shape")!,"Width"),"0")
    }
    func testSmallFrameAllowsBoundedPhysicalGeometryAndPreviewBounds() throws {
        var node = DiagramNode(x:100,y:120,text:"");node.width = 0.000072;node.height = 72
        node.formatting.paths = [VectorPath(commands:[VectorCommand("M",0,0),VectorCommand("L",2000000,1)])]
        var model = Diagram();model.page.nodes = [node]
        XCTAssertNoThrow(try model.validated())
        let master = try XCTUnwrap(VisioStencil.definitions([model.page],family:"Tests").first)
        XCTAssertEqual(master.fragment.width,144,accuracy:1e-8)
        var invalid = model;invalid.page.nodes[0].formatting.paths[0].commands[1].values[0] = 2e10
        XCTAssertThrowsError(try invalid.validated())
    }
}
