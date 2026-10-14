import AppKit
import XCTest
@testable import MacVisio

final class DrawingScaleTests:XCTestCase {
    private var temporary:[URL] = []
    override func tearDown() { for url in temporary { try? FileManager.default.removeItem(at:url) };super.tearDown() }
    private func file(_ ext:String) -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-scale-\(UUID()).\(ext)");temporary.append(url);return url }
    private func scaled() -> Diagram {
        var model = Diagram();model.page.width = 36000;model.page.height = 18000;model.page.drawingScale = DrawingScale(page:1,drawing:50)
        var node = DiagramNode(x:5000,y:5000,text:"Scaled drawing");node.width = 7200;node.height = 3600;node.fontSize = 14;node.strokeWidth = 2
        node.formatting.textBox = ShapeTextBox(left:10,right:10,top:8,bottom:8);model.page.nodes = [node];return model
    }
    func testScaledPublicXMLKeepsDrawingCoordinatesAndPhysicalSize() throws {
        let model = scaled(),url = file("vsdx");XCTAssertNoThrow(try model.validated());try VisioFormat.write(model,to:url)
        var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:url)
        let restored = try VisioFormat.read(from:url).diagram
        XCTAssertEqual(restored.page.paperWidth,720,accuracy:1e-9);XCTAssertEqual(restored.page.paperHeight,360,accuracy:1e-9)
        XCTAssertEqual(restored.page.nodes[0].width,7200,accuracy:1e-8);XCTAssertEqual(restored.page.nodes[0].fontSize,14,accuracy:1e-8);XCTAssertEqual(restored.page.nodes[0].strokeWidth,2,accuracy:1e-8)
        let unchanged = file("vsdx");try VisioFormat.write(restored,to:unchanged);XCTAssertEqual(try VisioPackage.read(unchanged),parts)
        let png = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(restored.page,scale:1)));XCTAssertEqual(png.pixelsWide,720);XCTAssertEqual(png.pixelsHigh,360)
        let pdf = try XCTUnwrap(CGPDFDocument(CGDataProvider(data:DiagramExport.pdf(restored.page) as CFData)!));XCTAssertEqual(pdf.page(at:1)?.getBoxRect(.mediaBox).width,720)
        XCTAssertTrue(DiagramDrawing.svg(restored.page).contains("viewBox=\"0 0 720.0 360.0\""))
    }
    func testScaledRenderingMatchesPhysicalReferenceWithSameFontsAndLines() throws {
        _ = NSApplication.shared
        let model = scaled();var reference = model
        reference.page.width *= 0.02;reference.page.height *= 0.02;reference.page.drawingScale = nil
        reference.page.nodes[0].x *= 0.02;reference.page.nodes[0].y *= 0.02;reference.page.nodes[0].width *= 0.02;reference.page.nodes[0].height *= 0.02
        reference.page.nodes[0].formatting.textBox?.left *= 0.02;reference.page.nodes[0].formatting.textBox?.right *= 0.02;reference.page.nodes[0].formatting.textBox?.top *= 0.02;reference.page.nodes[0].formatting.textBox?.bottom *= 0.02
        let actual = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(model.page,scale:1))),expected = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(reference.page,scale:1)))
        var differing = 0
        for y in 0..<actual.pixelsHigh { for x in 0..<actual.pixelsWide { let a = actual.colorAt(x:x,y:y)!,b = expected.colorAt(x:x,y:y)!;if abs(a.redComponent-b.redComponent)+abs(a.greenComponent-b.greenComponent)+abs(a.blueComponent-b.blueComponent) > 0.05 { differing += 1 } } }
        XCTAssertLessThan(differing,300,"Paper font sizes and line weights must stay unchanged by drawing scale.")
    }
    func testScaledCanvasAndDifferentScaleBackgroundsUsePhysicalCoordinates() throws {
        _ = NSApplication.shared
        let doc = MacVisioDocument();doc.diagram = scaled();doc.makeWindowControllers();let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        editor.canvas.setZoom(1);XCTAssertEqual(editor.canvas.pageFrame.width,720,accuracy:1e-8);XCTAssertEqual(editor.canvas.coordinateZoom,0.02,accuracy:1e-8)
        var background = DiagramPage(width:7200,height:3600);background.drawingScale = DrawingScale(page:1,drawing:10);background.isBackground = true
        XCTAssertEqual(DiagramScene(page:doc.diagram.page,backgrounds:[background]).offset(for:background),.zero)
    }
    func testActualEngineeringLibrariesReadScaledPaperDimensions() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/Visio2019-Libraries")
        guard FileManager.default.fileExists(atPath:root.path) else { throw XCTSkip("Installer assets are not available.") }
        for (file,name,w,h) in [("RECRT_M.VSSX","Basketball key",20.9763779528,43.0866141732),("SITACC_M.VSSX","Entrance gate",345.6,13.6913385827)] {
            let masters = try VisioStencil.read(from:root.appendingPathComponent(file)).items
            let master = try XCTUnwrap(masters.first{$0.name == name}),node = try XCTUnwrap(master.fragment.nodes.first{$0.parentID == nil})
            XCTAssertEqual(node.width*master.fragment.paperScale,w,accuracy:1e-6);XCTAssertEqual(node.height*master.fragment.paperScale,h,accuracy:1e-6)
        }
        let template = try VisioFormat.read(from:root.appendingPathComponent("CEILPL_M.VSTX")).diagram
        XCTAssertEqual(template.page.paperWidth,2383.93700787402,accuracy:1e-6);XCTAssertEqual(template.page.paperScale,0.02,accuracy:1e-10)
    }
    func testSignedNestedGeometryAndOffCenterFlippedPinRoundTrip() throws {
        let url = file("vsdx");var base = Diagram();base.page.width = 200;base.page.height = 50/25.4*72;try VisioFormat.write(base,to:url)
        var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json")
        let ns = "http://schemas.microsoft.com/office/visio/2012/main"
        func cell(_ name:String,_ mm:Double) -> String { "<Cell N=\"\(name)\" V=\"\(mm/25.4)\" U=\"MM\"/>" }
        let parent = cell("Width",40)+cell("Height",40)+cell("PinX",50)+cell("PinY",50)+cell("LocPinX",20)+cell("LocPinY",20)+"<Cell N=\"FlipY\" V=\"1\"/>"
        let child = cell("Width",-1)+cell("Height",40)+cell("PinX",0)+cell("PinY",0)+cell("LocPinX",0)+cell("LocPinY",0)
        let rows = [(-1.0,9.0),(0,0),(0,40),(-1,31)].enumerated().map { i,p in "<Row IX=\"\(i+1)\" T=\"\(i == 0 ? "MoveTo" : "LineTo")\">\(cell("X",p.0))\(cell("Y",p.1))</Row>" }.joined()
        parts["visio/pages/page1.xml"] = Data("<PageContents xmlns=\"\(ns)\"><Shapes><Shape ID=\"5\" Type=\"Group\">\(parent)<Shapes><Shape ID=\"7\" Type=\"Shape\">\(child)<Section N=\"Geometry\" IX=\"0\">\(rows)</Section></Shape></Shapes></Shape></Shapes></PageContents>".utf8);try VisioPackage.write(parts,to:url)
        let imported = try VisioFormat.read(from:url).diagram
        let expected = [(82.2047244094,-31.1811023622),(85.0393700787,-56.6929133858),(85.0393700787,56.6929133858),(82.2047244094,31.1811023622)]
        func verify(_ model:Diagram,_ dx:Double = 0) throws {
            let node = try XCTUnwrap(model.page.nodes.first{$0.formatting.sourceShapeID == "7"})
            XCTAssertTrue(node.formatting.negativeWidth == true);XCTAssertEqual(node.center.x,83.6220472441+dx,accuracy:1e-8)
            for (command,p) in zip(node.formatting.paths[0].commands,expected) { let actual = DiagramCoordinates.world(CGPoint(x:command.values[0]*node.width,y:command.values[1]*node.height),in:node);XCTAssertEqual(actual.x,p.0+dx,accuracy:1e-8);XCTAssertEqual(actual.y,p.1,accuracy:1e-8) }
        }
        try verify(imported);try verify(ShapeSheetEngine.recalculate(imported,previous:imported).diagram)
        var fresh = imported;fresh.visioArchive = nil;let out = file("vsdx");try VisioFormat.write(fresh,to:out)
        var publicParts = try VisioPackage.read(out);publicParts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(publicParts,to:out);try verify(VisioFormat.read(from:out).diagram)
        var moved = imported;let childIndex = try XCTUnwrap(moved.page.nodes.firstIndex{$0.formatting.sourceShapeID == "7"});moved.page.nodes[childIndex].x += 20;try VisioFormat.write(moved,to:out)
        publicParts = try VisioPackage.read(out);publicParts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(publicParts,to:out);try verify(VisioFormat.read(from:out).diagram,20)
        let binary = file("vsd");try VSDBinaryFormat.write(imported,to:binary)
        let independent = try LegacyVisioFormat.graphicPages(from:binary,stencils:false).pages[0]
        let pathNode = try XCTUnwrap(independent.nodes.first{!$0.formatting.paths.isEmpty}),path = try XCTUnwrap(pathNode.formatting.paths.first)
        for (command,p) in zip(path.commands.filter{$0.kind == "M" || $0.kind == "L"},expected) { let point = DiagramCoordinates.world(CGPoint(x:command.values[0]*pathNode.width,y:command.values[1]*pathNode.height),in:pathNode);XCTAssertEqual(point.x,p.0,accuracy:0.02);XCTAssertEqual(point.y,p.1,accuracy:0.02) }
    }
    func testCrossScaleFragmentPreservesPhysicalSizePortsAndPublicCache() throws {
        var source = scaled();source.page.nodes[0].formatting.sheet["Width"] = ShapeSheetCell(value:"100",formula:"GUARD(100in)")
        source.page.nodes[0].formatting.connectionPoints = [ShapeConnectionPoint(index:0,name:"Output",x:ShapeSheetCell(value:"100",formula:"Width"),y:ShapeSheetCell(value:"25",formula:"Height/2"))]
        let fragment = DiagramOperations.fragment([source.page.nodes[0].id],from:source.page);XCTAssertEqual(fragment.paperScale,0.02)
        var target = DiagramPage();try DiagramOperations.insert(fragment,into:&target,at:CGPoint(x:50,y:60))
        XCTAssertEqual(target.nodes[0].width,144,accuracy:1e-8);XCTAssertEqual(target.nodes[0].formatting.sheet["Width"]?.formula,"")
        XCTAssertEqual(target.nodes[0].formatting.connectionPoints[0].x.formula,"Width")
        XCTAssertEqual(ConnectionGeometry.point(target.nodes[0].formatting.connectionPoints[0],on:target.nodes[0]).x,194,accuracy:1e-8)
        var doc = Diagram();doc.pages = [target];doc.activePageID = target.id
        let calculated = ShapeSheetEngine.recalculate(doc).diagram;XCTAssertEqual(calculated.page.nodes[0].width,144,accuracy:1e-8)
        let saved = file("vsdx");try VisioFormat.write(calculated,to:saved)
        var parts = try VisioPackage.read(saved);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:saved)
        XCTAssertEqual(try VisioFormat.read(from:saved).diagram.page.nodes[0].width,144,accuracy:1e-8)
    }
    func testScaleEditingUndoAndOlderMetadataHydration() throws {
        _ = NSApplication.shared
        let saved = file("vsdx");try VisioFormat.write(scaled(),to:saved)
        var imported = try VisioFormat.read(from:saved).diagram;imported.page.drawingScale = nil;imported.visioArchive!.pages[0].original.drawingScale = nil
        let hydrated = try imported.validated();XCTAssertEqual(hydrated.page.paperScale,0.02,accuracy:1e-10);XCTAssertEqual(hydrated.visioArchive?.pages[0].original.paperScale,0.02)
        let doc = MacVisioDocument();doc.diagram = hydrated;doc.makeWindowControllers();doc.undoManager?.groupsByEvent = false
        let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController)
        doc.undoManager?.beginUndoGrouping();editor.configurePage(width:720/0.01,height:360/0.01,scale:.some(DrawingScale(page:1,drawing:100)));doc.undoManager?.endUndoGrouping()
        XCTAssertEqual(doc.diagram.page.paperWidth,720);XCTAssertEqual(doc.diagram.page.nodes[0].width*doc.diagram.page.paperScale,72)
        doc.undoManager?.undo();XCTAssertEqual(doc.diagram.page.paperScale,0.02);XCTAssertEqual(doc.diagram.page.nodes[0].width,7200)
    }
    func testIndependentReadersAcceptPhysicalScaleInBothFormats() throws {
        _ = NSApplication.shared
        for ext in ["vsdx","vsd"] {
            let out = file(ext);if ext == "vsdx" { try VisioFormat.write(scaled(),to:out) } else { try VSDBinaryFormat.write(scaled(),to:out) }
            let task = Process(),pipe = Pipe();task.executableURL = try XCTUnwrap(LegacyVisioFormat.converterURL);task.arguments = [out.path];task.standardOutput = pipe;task.standardError = FileHandle.nullDevice;try task.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit();XCTAssertEqual(task.terminationStatus,0)
            let html = String(decoding:output,as:UTF8.self),regex = try NSRegularExpression(pattern:"<svg:svg[\\s\\S]*?</svg:svg>")
            let match = try XCTUnwrap(regex.firstMatch(in:html,range:NSRange(html.startIndex...,in:html))),range = try XCTUnwrap(Range(match.range,in:html))
            let page = try SVGImport.page(Data(html[range].utf8),name:"Independent").page
            XCTAssertEqual(page.width,720,accuracy:0.01,ext);XCTAssertEqual(page.height,360,accuracy:0.01,ext)
            XCTAssertTrue(page.nodes.contains{$0.text.contains("Scaled drawing")})
            XCTAssertEqual(try XCTUnwrap(page.nodes.first{$0.text.contains("Scaled drawing")}).fontSize,14,accuracy:0.02,ext)
        }
    }
    func testIndependentReaderKeepsTextFollowingGroupWithCachedSheet() throws {
        var model = scaled()
        var group = DiagramNode(x:1000,y:1000,text:"");group.width = 10000;group.height = 8000;group.formatting.isGroup = true
        var child = DiagramNode(x:2000,y:2000,text:"");child.parentID = group.id;child.width = 2000;child.height = 1000
        child.formatting.sheet["HideText"] = ShapeSheetCell(value:"0",formula:"Inh")
        model.page.nodes = [group,child]+model.page.nodes
        let out = file("vsdx");try VisioFormat.write(model,to:out)
        let parts = try VisioPackage.read(out),page = try VisioXML.element(String(decoding:try XCTUnwrap(parts["visio/pages/page1.xml"]),as:UTF8.self))
        for shape in try XCTUnwrap(page.firstLocal("Shapes")).allShapes {
            XCTAssertFalse(shape.elementsLocal("Section").contains{$0.childCount == 0 && ["Property","Hyperlink"].contains($0.attr("N") ?? "")})
        }
        let task = Process(),pipe = Pipe();task.executableURL = try XCTUnwrap(LegacyVisioFormat.converterURL);task.arguments = [out.path];task.standardOutput = pipe;task.standardError = FileHandle.nullDevice;try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile();task.waitUntilExit();XCTAssertEqual(task.terminationStatus,0)
        XCTAssertTrue(String(decoding:output,as:UTF8.self).contains("Scaled drawing"))
    }
    func testPositiveFlippedOffCenterPinAndOlderMetadataUsePublicTransforms() throws {
        var base = Diagram();base.page.width = 720;base.page.height = 720;let url = file("vsdx");try VisioFormat.write(base,to:url)
        var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json")
        parts["visio/pages/page1.xml"] = Data("<PageContents xmlns=\"http://schemas.microsoft.com/office/visio/2012/main\"><Shapes><Shape ID=\"1\" Type=\"Shape\"><Cell N=\"Width\" V=\"2\"/><Cell N=\"Height\" V=\"1\"/><Cell N=\"PinX\" V=\"5\"/><Cell N=\"PinY\" V=\"3\"/><Cell N=\"LocPinX\" V=\"0\"/><Cell N=\"LocPinY\" V=\"0\"/><Cell N=\"Angle\" V=\"1.5707963267948966\"/><Cell N=\"FlipX\" V=\"1\"/><Text>Off-center flip</Text></Shape></Shapes></PageContents>".utf8);try VisioPackage.write(parts,to:url)
        let imported = try VisioFormat.read(from:url).diagram
        XCTAssertEqual(imported.page.nodes[0].center.x,324,accuracy:1e-9);XCTAssertEqual(imported.page.nodes[0].center.y,576,accuracy:1e-9)
        var flipped = imported;flipped.page.nodes[0].formatting.flipX = false
        let saved = file("vsdx");try VisioFormat.write(flipped,to:saved)
        var publicParts = try VisioPackage.read(saved);publicParts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(publicParts,to:saved)
        XCTAssertEqual(try VisioFormat.read(from:saved).diagram.page.nodes[0].center.y,576,accuracy:1e-9)
        var native = imported;native.visioArchive = nil;try VisioFormat.write(native,to:saved);var archived = try VisioPackage.read(saved)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with:try XCTUnwrap(archived["macvisio/document.json"])) as? [String:Any]);envelope.removeValue(forKey:"coordinateTransformVersion")
        var diagram = envelope["diagram"] as! [String:Any],pages = diagram["pages"] as! [[String:Any]],nodes = pages[0]["nodes"] as! [[String:Any]];nodes[0]["x"] = 0;pages[0]["nodes"] = nodes;diagram["pages"] = pages;envelope["diagram"] = diagram
        archived["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:envelope);try VisioPackage.write(archived,to:saved)
        let upgraded = try VisioFormat.read(from:saved)
        XCTAssertEqual(upgraded.diagram.page.nodes[0].center.x,324,accuracy:1e-9);XCTAssertTrue(upgraded.warnings.contains{$0.contains("flipped-pin")})
    }
    func testMeasuredToMeasuredInsertionKeepsRealDimensions() throws {
        let source = scaled();var destination = DiagramPage(width:72000,height:36000);destination.drawingScale = DrawingScale(page:1,drawing:100)
        try DiagramOperations.insert(DiagramOperations.fragment([source.page.nodes[0].id],from:source.page),into:&destination,at:CGPoint(x:1000,y:2000))
        XCTAssertEqual(destination.nodes[0].width,7200,accuracy:1e-8);XCTAssertEqual(destination.nodes[0].width*destination.paperScale,72,accuracy:1e-8)
        XCTAssertEqual(destination.nodes[0].formatting.sheet["DropOnPageScale"]?.value,"1")
    }
}
