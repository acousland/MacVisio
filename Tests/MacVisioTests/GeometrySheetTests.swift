import AppKit
import XCTest
@testable import MacVisio

final class GeometrySheetTests:XCTestCase {
    private var files:[URL] = []
    override func tearDown() { for file in files { try? FileManager.default.removeItem(at:file) };super.tearDown() }
    private func file(_ ext:String) -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-geometry-\(UUID()).\(ext)");files.append(url);return url }
    private func model() -> Diagram {
        var diagram = Diagram();var node = DiagramNode(x:100,y:100,text:"");node.width = 288;node.height = 144
        node.formatting.sheet["User.Notch"] = ShapeSheetCell(value:"0.25",formula:"")
        func row(_ index:Int,_ type:String,_ x:String,_ y:String,_ fx:String = "",_ fy:String = "") -> ShapeGeometryRow { ShapeGeometryRow(index:index,type:type,cells:["X":ShapeSheetCell(value:x,formula:fx),"Y":ShapeSheetCell(value:y,formula:fy)]) }
        node.formatting.geometry = [ShapeGeometrySection(index:0,cells:["NoFill":ShapeSheetCell(value:"0"),"NoLine":ShapeSheetCell(value:"0"),"NoShow":ShapeSheetCell(value:"0")],rows:[row(1,"MoveTo","0","0"),row(2,"LineTo","4","0","Width",""),row(3,"LineTo","4","1.75","Geometry1.X2","Height-User.Notch"),row(4,"LineTo","2","2","Width/2","Height"),row(5,"LineTo","0","1.75","0","Geometry1.Y3"),row(6,"LineTo","0","0")])]
        node.formatting.paths = VisioFormat.geometryPaths(node.formatting.geometry!,width:4,height:2).paths;diagram.page.nodes = [node];return diagram
    }
    func testGeometryDependenciesUpdateKnownVerticesAfterResize() throws {
        let before = model();var next = before;next.page.nodes[0].width = 432;next.page.nodes[0].height = 216;next.page.nodes[0].formatting.sheet["User.Notch"]?.value = "0.5"
        let result = ShapeSheetEngine.recalculate(next,previous:before);XCTAssertTrue(result.issues.isEmpty)
        let node = result.diagram.page.nodes[0],commands = node.formatting.paths[0].commands
        XCTAssertEqual(commands[1].values,[1,1]);XCTAssertEqual(commands[2].values[0],1,accuracy:1e-9);XCTAssertEqual(commands[2].values[1],1.0/6,accuracy:1e-9);XCTAssertEqual(commands[3].values,[0.5,0]);XCTAssertEqual(commands[4].values[1],1.0/6,accuracy:1e-9)
        XCTAssertEqual(GeometrySheet.cell("Geometry1.X2",on:node)?.value,"6");XCTAssertEqual(GeometrySheet.cell("Geometry1.Y3",on:node)?.formula,"Height-User.Notch")
    }
    func testUnsignedGeometryIndexesAreAddressableWithoutOverflowAliases() throws {
        var node = DiagramNode();node.formatting.geometry = [ShapeGeometrySection(index:Int(UInt32.max),cells:["NoShow":ShapeSheetCell(value:"0")],rows:[ShapeGeometryRow(index:Int(UInt32.max),type:"LineTo",cells:["X":ShapeSheetCell(value:"1")])])]
        let reference = "Geometry4294967296.X4294967295"
        try GeometrySheet.set(reference,ShapeSheetCell(value:"2"),on:&node);XCTAssertEqual(GeometrySheet.cell(reference,on:node)?.value,"2")
        XCTAssertNil(GeometrySheet.address("Geometry1.X999999999999999999999999"));XCTAssertNil(GeometrySheet.address("Geometry1.X4294967296"));XCTAssertNil(GeometrySheet.address("Geometry4294967297.NoShow"))
    }
    func testPublicImportAndFreshExportRetainGeometryFormulasAndUnits() throws {
        var diagram = model();diagram.page.nodes[0].formatting.geometry![0].rows[2].cells["Y"]?.unit = "IN"
        let url = file("vsdx");try VisioFormat.write(diagram,to:url);var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:url)
        let imported = try VisioFormat.read(from:url).diagram,node = imported.page.nodes[0]
        XCTAssertEqual(GeometrySheet.cell("Geometry1.Y3",on:node)?.formula,"Height-User.Notch");XCTAssertEqual(GeometrySheet.cell("Geometry1.Y3",on:node)?.unit,"IN")
        let copy = file("vsdx");try VisioFormat.write(imported,to:copy);XCTAssertEqual(try VisioPackage.read(copy),parts)
    }
    func testRemovingLastGeometrySectionDoesNotResurrectPrimitiveOutline() throws {
        let source = file("vsdx");try VisioFormat.write(model(),to:source);var parts = try VisioPackage.read(source);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:source)
        var edited = try VisioFormat.read(from:source).diagram;edited.page.nodes[0].formatting.geometry = [];edited = ShapeSheetEngine.recalculate(edited).diagram
        for fresh in [false,true] {
            var drawing = edited;if fresh { drawing.visioArchive = nil }
            let out = file("vsdx");try VisioFormat.write(drawing,to:out);var output = try VisioPackage.read(out);output.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(output,to:out)
            let read = try VisioFormat.read(from:out).diagram;XCTAssertNotNil(read.page.nodes[0].formatting.geometry);XCTAssertTrue(read.page.nodes[0].formatting.paths.isEmpty);XCTAssertTrue(DiagramDrawing.outline(for:read.page.nodes[0]).isEmpty)
        }
    }
    func testSourcePreservingResizePatchesCachesAndRetainsFormulas() throws {
        let url = file("vsdx");try VisioFormat.write(model(),to:url);var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:url)
        let old = try VisioFormat.read(from:url).diagram;var next = old;next.page.nodes[0].width = 432
        next = ShapeSheetEngine.recalculate(next,previous:old).diagram;let out = file("vsdx");try VisioFormat.write(next,to:out)
        parts = try VisioPackage.read(out);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:out)
        let read = try VisioFormat.read(from:out).diagram
        XCTAssertEqual(GeometrySheet.cell("Geometry1.X2",on:read.page.nodes[0])?.value,"6");XCTAssertEqual(GeometrySheet.cell("Geometry1.X2",on:read.page.nodes[0])?.formula,"Width")
        XCTAssertEqual(read.page.nodes[0].formatting.paths[0].commands[3].values[0],0.5,accuracy:1e-9)
    }
    func testUnsupportedOrCyclicGeometryRetainsCachedValues() throws {
        var diagram = model();diagram.page.nodes[0].formatting.geometry![0].rows[2].cells["Y"]?.formula = "Unsupported(Height)"
        let old = GeometrySheet.cell("Geometry1.Y3",on:diagram.page.nodes[0])!.value,result = ShapeSheetEngine.recalculate(diagram)
        XCTAssertEqual(GeometrySheet.cell("Geometry1.Y3",on:result.diagram.page.nodes[0])?.value,old);XCTAssertFalse(result.issues.isEmpty)
        diagram.page.nodes[0].formatting.geometry![0].rows[1].cells["X"]?.formula = "Geometry1.X3"
        diagram.page.nodes[0].formatting.geometry![0].rows[2].cells["X"]?.formula = "Geometry1.X2";XCTAssertTrue(ShapeSheetEngine.recalculate(diagram).issues.contains{$0.contains("Circular")})
    }
    func testRelativeCurvesAndVisibilityRecalculate() throws {
        var diagram = model();diagram.page.nodes[0].formatting.geometry = [ShapeGeometrySection(index:0,cells:["NoShow":ShapeSheetCell(value:"0",formula:"IF(User.Notch>1,1,0)")],rows:[ShapeGeometryRow(index:1,type:"RelMoveTo",cells:["X":ShapeSheetCell(value:"0"),"Y":ShapeSheetCell(value:"0")]),ShapeGeometryRow(index:2,type:"RelCubBezTo",cells:["X":ShapeSheetCell(value:"1"),"Y":ShapeSheetCell(value:"1"),"A":ShapeSheetCell(value:"0.2",formula:"User.Notch"),"B":ShapeSheetCell(value:"0"),"C":ShapeSheetCell(value:"0.8"),"D":ShapeSheetCell(value:"1")])])]
        let rendered = ShapeSheetEngine.recalculate(diagram).diagram;XCTAssertEqual(rendered.page.nodes[0].formatting.paths[0].commands[1].values[0],0.25,accuracy:1e-9)
        diagram.page.nodes[0].formatting.sheet["User.Notch"]?.value = "2";let hidden = ShapeSheetEngine.recalculate(diagram).diagram;XCTAssertTrue(hidden.page.nodes[0].formatting.paths.isEmpty);XCTAssertTrue(DiagramDrawing.outline(for:hidden.page.nodes[0]).isEmpty)
    }
    func testCrossShapeGeometryReferencesAreScopedAfterCopy() throws {
        var diagram = model(),other = DiagramNode(x:500,y:100,text:"");diagram.page.nodes[0].formatting.sourceShapeID = "1";other.formatting.sourceShapeID = "2";other.width = 72
        diagram.page.nodes[0].formatting.geometry![0].rows[1].cells["X"]?.formula = "Sheet.2!Width";diagram.page.nodes.append(other)
        let initial = ShapeSheetEngine.recalculate(diagram);XCTAssertEqual(GeometrySheet.cell("Geometry1.X2",on:initial.diagram.page.nodes[0])?.value,"1")
        let fragment = DiagramOperations.fragment(Set(diagram.page.nodes.map(\.id)),from:diagram.page);var page = DiagramPage();var existing = DiagramNode();existing.formatting.sourceShapeID = "7";page.nodes = [existing]
        try DiagramOperations.insert(fragment,into:&page);let copied = try XCTUnwrap(page.nodes.first{$0.formatting.geometry != nil})
        XCTAssertNotEqual(GeometrySheet.cell("Geometry1.X2",on:copied)?.formula,"Sheet.2!Width")
    }
    func testIndependentBothFormatsAcceptUpdatedCachedGeometry() throws {
        var diagram = model();diagram.page.nodes[0].width = 432;diagram = ShapeSheetEngine.recalculate(diagram).diagram
        for ext in ["vsdx","vsd"] { let out = file(ext);if ext == "vsdx" { try VisioFormat.write(diagram,to:out) } else { try VSDBinaryFormat.write(diagram,to:out) }
            let process = Process(),pipe = Pipe();process.executableURL = try XCTUnwrap(LegacyVisioFormat.converterURL);process.arguments = [out.path];process.standardOutput = pipe;process.standardError = FileHandle.nullDevice;try process.run();let data = pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
            let html = String(decoding:data,as:UTF8.self);XCTAssertTrue(html.contains("svg:path"),ext)
        }
    }
    func testCrossScaleMaterializedGeometryKeepsPhysicalCoordinates() throws {
        var diagram = model();diagram.page.drawingScale = DrawingScale(page:1,drawing:50);diagram.page.width *= 50;diagram.page.height *= 50
        let source = diagram.page.nodes[0].formatting.paths
        let fragment = DrawingScale.convert(diagram.page,to:1,targetMeasured:false);var copy = Diagram();copy.pages = [fragment];copy.activePageID = fragment.id
        let result = ShapeSheetEngine.recalculate(copy).diagram
        for (a,b) in zip(source[0].commands,result.page.nodes[0].formatting.paths[0].commands) { for (x,y) in zip(a.values,b.values) { XCTAssertEqual(x,y,accuracy:1e-8) } }
        XCTAssertEqual(GeometrySheet.cell("Geometry1.X2",on:result.page.nodes[0])?.formula,"")
    }
    func testNativeGeometryEditingUndoAndOldMetadataUpgrade() throws {
        _ = NSApplication.shared
        let doc = MacVisioDocument();doc.diagram = model();doc.makeWindowControllers();doc.undoManager?.groupsByEvent = false
        let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController),id = doc.diagram.page.nodes[0].id
        doc.undoManager?.beginUndoGrouping();try editor.setGeometryCell("Geometry1.Y3",value:"1.75",formula:"Height/2",for:id);doc.undoManager?.endUndoGrouping()
        XCTAssertEqual(doc.diagram.page.nodes[0].formatting.paths[0].commands[2].values[1],0.5,accuracy:1e-8);doc.undoManager?.undo();XCTAssertEqual(GeometrySheet.cell("Geometry1.Y3",on:doc.diagram.page.nodes[0])?.formula,"Height-User.Notch")
        for controller in doc.windowControllers { controller.close() }
        let out = file("vsdx");try VisioFormat.write(model(),to:out);var parts = try VisioPackage.read(out)
        var envelope = try JSONSerialization.jsonObject(with:parts["macvisio/document.json"]!) as! [String:Any];envelope.removeValue(forKey:"geometryVersion");parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:envelope);try VisioPackage.write(parts,to:out)
        let read = try VisioFormat.read(from:out);XCTAssertTrue(read.warnings.contains{$0.contains("public geometry rows were reimported")});XCTAssertEqual(GeometrySheet.cell("Geometry1.X2",on:read.diagram.page.nodes[0])?.formula,"Width")
    }
}
