import AppKit
import XCTest
@testable import MacVisio

final class BinaryVisioTests:XCTestCase {
    private var urls:[URL] = []
    override func tearDown() { for url in urls { try? FileManager.default.removeItem(at:url) };super.tearDown() }
    private func temp() -> URL { let u = FileManager.default.temporaryDirectory.appendingPathComponent("BinaryVisio-\(UUID()).vsd");urls.append(u);return u }
    func testCompoundFileStoresMiniAndRegularStreamsAndDirectoryTree() throws {
        var streams:[String:Data] = [:]
        for i in 0..<17 { streams["Stream\(i)"] = Data(repeating:UInt8(i),count:i*751) };streams["Empty"] = Data()
        let encoded = try CompoundFile(streams:streams).encoded()
        XCTAssertEqual(encoded.prefix(8),CompoundFile.signature);XCTAssertEqual(try CompoundFile.read(encoded).streams,streams)
        XCTAssertThrowsError(try CompoundFile(streams:["Case":Data(),"CASE":Data()]).encoded())
    }
    func testCompoundFileDIFATRoundTripAndTruncationBounds() throws {
        let payload = Data(repeating:0xA5,count:8*1024*1024)
        let encoded = try CompoundFile(streams:["Large":payload]).encoded()
        XCTAssertGreaterThan(try BinaryBytes(encoded).u32(72),0);XCTAssertEqual(try CompoundFile.read(encoded).streams["Large"],payload)
        XCTAssertThrowsError(try CompoundFile.read(encoded.dropLast()))
        var bad = encoded;bad.set(UInt32.max,at:48);XCTAssertThrowsError(try CompoundFile.read(bad))
    }
    func testCompoundReaderOpensRealLegacyFilesIncludingMiniStreams() throws {
        for name in ["no-bgcolor","Visio11FormatLine","Visio5PlanWithDimensions","Visio6TextFieldsWithUnits","bitmaps"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:"vsd",subdirectory:"Fixtures"))
            let file = try CompoundFile.read(Data(contentsOf:url))
            XCTAssertTrue(try XCTUnwrap(file.streams["VisioDocument"]).starts(with:Data("Visio (TM) Drawing\r\n\0".utf8)),name)
            XCTAssertEqual(file.streams["VisioInformation"]?.count,28,name)
        }
    }
    func testPrototypeBinaryExportParsesIndependentlyWithUnicodeTextAndCurves() throws {
        var diagram = DiagramTemplate.flowchart.makeDiagram();diagram.page.nodes[0].text = "Start café 東京 🚀"
        let url = temp();try VSDBinaryFormat.encoded(diagram,includeMetadata:false).write(to:url)
        let file = try CompoundFile.read(Data(contentsOf:url)),stream = try XCTUnwrap(file.streams["VisioDocument"])
        XCTAssertEqual(try BinaryBytes(stream).u8(26),11);XCTAssertEqual(try BinaryBytes(stream).u32(28),UInt32(stream.count))
        let result = try LegacyVisioFormat.read(from:url)
        XCTAssertEqual(result.diagram.pages.count,1);XCTAssertEqual(result.diagram.page.width,diagram.page.width,accuracy:0.01)
        XCTAssertEqual(result.diagram.page.height,diagram.page.height,accuracy:0.01)
        XCTAssertTrue(result.diagram.page.nodes.contains{$0.text.contains("Start café 東京 🚀")})
        XCTAssertTrue(result.diagram.page.nodes.flatMap{$0.formatting.paths}.flatMap(\.commands).contains{$0.kind == "C"})
        if ProcessInfo.processInfo.environment["MACVISIO_KEEP_PROTOTYPE"] == "1" { try Data(contentsOf:url).write(to:URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/vsd-prototype.vsd")) }
    }
    func testPrototypeBinaryGroupsTransformsImagesAndMultiplePagesParseIndependently() throws {
        _ = NSApplication.shared
        var diagram = Diagram();var group = DiagramNode(x:100,y:90,text:"");group.width = 300;group.height = 200;group.rotation = 20;group.formatting.isGroup = true
        var child = DiagramNode(kind:.ellipse,x:150,y:140,text:"Group child");child.parentID = group.id;child.rotation = 20;child.formatting.fontName = "Courier New";child.formatting.italic = true
        diagram.page.nodes = [group,child]
        var second = DiagramPage(name:"Images");var image = DiagramNode(x:40,y:50,text:"")
        let nsimage = NSImage(size:CGSize(width:8,height:8),flipped:true){_ in NSColor.red.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:8,height:8)).fill();return true}
        let rep = NSBitmapImageRep(data:nsimage.tiffRepresentation!)!;image.formatting.image = EmbeddedImage(data:rep.representation(using:.png,properties:[:])!,mimeType:"image/png");second.nodes = [image];diagram.pages.append(second)
        let url = temp();try VSDBinaryFormat.encoded(diagram,includeMetadata:false).write(to:url);let parsed = try LegacyVisioFormat.read(from:url).diagram
        XCTAssertEqual(parsed.pages.count,2);XCTAssertTrue(parsed.pages[0].nodes.contains{$0.text == "Group child"});XCTAssertTrue(parsed.pages[1].nodes.contains{$0.formatting.image != nil})
    }
    func testNativeBinarySaveUsesRealCFBAndReopensAllNativeModelDetails() throws {
        _ = NSApplication.shared
        let doc = MacVisioDocument();doc.diagram = DiagramTemplate.flowchart.makeDiagram();doc.diagram.page.nodes[0].formatting.data = [ShapeDataProperty(key:"Owner",label:"Owner",value:"Alex")]
        let url = temp();try doc.write(to:url,ofType:MacVisioDocument.legacyType)
        let data = try Data(contentsOf:url);XCTAssertTrue(data.starts(with:CompoundFile.signature))
        let decoded = MacVisioDocument();try decoded.read(from:data,ofType:MacVisioDocument.legacyType)
        XCTAssertEqual(decoded.diagram,doc.diagram);XCTAssertTrue(decoded.legacyNative);XCTAssertFalse(decoded.importWarnings.isEmpty)
        let compound = try CompoundFile.read(data);XCTAssertNotNil(compound.streams["VisioDocument"]);XCTAssertNotNil(compound.streams[VSDBinaryFormat.nativeStream])
    }
    func testExternalBinaryEditInvalidatesNativeMetadata() throws {
        var diagram = Diagram();diagram.page.nodes = [DiagramNode(x:100,y:100,text:"Before")]
        var file = try CompoundFile.read(VSDBinaryFormat.encoded(diagram));var publicData = file.streams["VisioDocument"]!
        let search = Data("Before".utf16.flatMap{[UInt8($0&255),UInt8($0>>8)]}),replacement = Data("After!".utf16.flatMap{[UInt8($0&255),UInt8($0>>8)]})
        let range = try XCTUnwrap(publicData.range(of:search));publicData.replaceSubrange(range,with:replacement);file.streams["VisioDocument"] = publicData
        XCTAssertNil(VSDBinaryFormat.nativeModel(in:file));let url = temp();try file.encoded().write(to:url)
        let result = try LegacyVisioFormat.read(from:url);XCTAssertFalse(result.legacyNative);XCTAssertTrue(result.diagram.page.nodes.contains{$0.text == "After!"})
        XCTAssertTrue(result.warnings.contains{$0.contains("changed outside")})
    }
    func testUnchangedLegacySourceIsPreservedByteForByteAcrossNativeAndVSDXRecovery() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource:"no-bgcolor",withExtension:"vsd",subdirectory:"Fixtures")),original = try Data(contentsOf:fixture)
        let imported = try LegacyVisioFormat.read(from:fixture).diagram
        XCTAssertEqual(try VSDBinaryFormat.encoded(imported),original)
        let recovered = try JSONDecoder().decode(Diagram.self,from:JSONEncoder().encode(imported)).validated();XCTAssertEqual(try VSDBinaryFormat.encoded(recovered),original)
        let package = temp().deletingPathExtension().appendingPathExtension("vsdx");urls.append(package);try VisioFormat.write(imported,to:package)
        let parts = try VisioPackage.read(package);XCTAssertTrue(parts.keys.contains{$0.hasSuffix(".mvsd")})
        let reopened = try VisioFormat.read(from:package).diagram;XCTAssertEqual(reopened.legacySource?.data,original);XCTAssertEqual(try VSDBinaryFormat.encoded(reopened),original)
    }
    func testUnsupportedBinaryImageTypeFailsWithoutOverwritingDestination() throws {
        var diagram = Diagram();var node = DiagramNode();node.formatting.image = EmbeddedImage(data:Data("%PDF".utf8),mimeType:"application/pdf");diagram.page.nodes = [node]
        let url = temp(),original = Data("Existing file".utf8);try original.write(to:url)
        XCTAssertThrowsError(try VSDBinaryFormat.write(diagram,to:url));XCTAssertEqual(try Data(contentsOf:url),original)
    }
    func testPreservedCompoundSourceMustActuallyContainVisioData() throws {
        var diagram = Diagram();let bytes = try CompoundFile(streams:["Other":Data("not Visio".utf8)]).encoded()
        diagram.legacySource = LegacyVisioSource(data:bytes,title:diagram.title,pages:diagram.pages)
        XCTAssertThrowsError(try diagram.validated());XCTAssertThrowsError(try VSDBinaryFormat.encoded(diagram))
    }
    func testBinaryBMPStoresDIBAndIndependentReaderRestoresValidPixels() throws {
        _ = NSApplication.shared
        let image = NSImage(size:CGSize(width:8,height:8),flipped:true){_ in NSColor.red.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:8,height:8)).fill();return true}
        let rep = try XCTUnwrap(NSBitmapImageRep(data:image.tiffRepresentation!)),bytes = try XCTUnwrap(rep.representation(using:.bmp,properties:[:]))
        var diagram = Diagram();var node = DiagramNode(x:20,y:30,text:"");node.formatting.image = EmbeddedImage(data:bytes,mimeType:"image/bmp");diagram.page.nodes = [node]
        let url = temp();try VSDBinaryFormat.encoded(diagram,includeMetadata:false).write(to:url)
        let parsed = try LegacyVisioFormat.read(from:url).diagram,decoded = try XCTUnwrap(parsed.page.nodes.compactMap{$0.formatting.image}.first)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data:decoded.data)),color = try XCTUnwrap(bitmap.colorAt(x:2,y:2)?.usingColorSpace(.deviceRGB))
        let originalBitmap = try XCTUnwrap(NSBitmapImageRep(data:bytes)),originalColor = try XCTUnwrap(originalBitmap.colorAt(x:2,y:2)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(decoded.data.dropFirst(14),bytes.dropFirst(14))
        XCTAssertEqual(color.redComponent,originalColor.redComponent,accuracy:0.00001);XCTAssertEqual(color.greenComponent,originalColor.greenComponent,accuracy:0.00001);XCTAssertEqual(color.blueComponent,originalColor.blueComponent,accuracy:0.00001)
    }
    func testCubicControlPointsSurviveIndependentBinaryNURBSParsing() throws {
        var diagram = Diagram();diagram.page.width = 720;diagram.page.height = 540
        var node = DiagramNode(x:72,y:72,text:"");node.width = 144;node.height = 72
        node.formatting.paths = [VectorPath(commands:[VectorCommand("M",0,1),VectorCommand("C",0,0,1,0,1,1),VectorCommand("Z")])];diagram.page.nodes = [node]
        let url = temp();try VSDBinaryFormat.encoded(diagram,includeMetadata:false).write(to:url)
        let parsed = try LegacyVisioFormat.read(from:url).diagram
        let curveNode = try XCTUnwrap(parsed.page.nodes.first{$0.formatting.paths.flatMap(\.commands).contains{$0.kind == "C"}})
        let curve = try XCTUnwrap(curveNode.formatting.paths.flatMap(\.commands).first{$0.kind == "C"})
        let world = stride(from:0,to:6,by:2).map{CGPoint(x:curveNode.x+curve.values[$0]*curveNode.width,y:curveNode.y+curve.values[$0+1]*curveNode.height)}
        for (actual,expected) in zip(world,[CGPoint(x:72,y:72),CGPoint(x:216,y:72),CGPoint(x:216,y:144)]) { XCTAssertEqual(actual.x,expected.x,accuracy:0.001);XCTAssertEqual(actual.y,expected.y,accuracy:0.001) }
    }
}
