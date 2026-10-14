import AppKit
import XCTest
@testable import MacVisio

final class SplineGeometryTests:XCTestCase {
    private var files:[URL] = []
    override func tearDown() { files.forEach{try? FileManager.default.removeItem(at:$0)};super.tearDown() }
    private func file(_ ext:String) -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-spline-\(UUID()).\(ext)");files.append(url);return url }
    private func cell(_ v:String,_ f:String = "") -> ShapeSheetCell { ShapeSheetCell(value:v,formula:f) }
    private func model() -> Diagram {
        var d = Diagram(),n = DiagramNode(x:100,y:100,text:"");n.width = 144;n.height = 144;n.formatting.sheet["User.ControlY"] = cell("1")
        n.formatting.geometry = [ShapeGeometrySection(index:0,cells:["NoFill":cell("1")],rows:[ShapeGeometryRow(index:1,type:"MoveTo",cells:["X":cell("0"),"Y":cell("0")]),ShapeGeometryRow(index:2,type:"SplineStart",cells:["X":cell("0.5","Width/4"),"Y":cell("2","Height*User.ControlY"),"A":cell("0"),"B":cell("0"),"C":cell("1"),"D":cell("3")]),ShapeGeometryRow(index:3,type:"SplineKnot",cells:["X":cell("1.5","Width*3/4"),"Y":cell("2","Geometry1.Y2"),"A":cell("0")]),ShapeGeometryRow(index:4,type:"SplineKnot",cells:["X":cell("2","Width"),"Y":cell("0"),"A":cell("0")])])]
        d.page.nodes = [n];return ShapeSheetEngine.recalculate(d).diagram
    }
    private func publicRead(_ d:Diagram) throws -> (Diagram,[String:Data]) {
        let out = file("vsdx");try VisioFormat.write(d,to:out);var parts = try VisioPackage.read(out);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:out);return (try VisioFormat.read(from:out).diagram,parts)
    }
    private func independent(_ url:URL) throws -> DiagramPage {
        let p = Process(),pipe = Pipe();p.executableURL = try XCTUnwrap(LegacyVisioFormat.converterURL);p.arguments = [url.path];p.standardOutput = pipe;p.standardError = FileHandle.nullDevice;try p.run();let data = pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();XCTAssertEqual(p.terminationStatus,0)
        let s = String(decoding:data,as:UTF8.self),a = try XCTUnwrap(s.range(of:"<svg:svg")),b = try XCTUnwrap(s.range(of:"</svg:svg>"));return try SVGImport.page(Data(s[a.lowerBound..<b.upperBound].utf8),name:"Independent").page
    }
    func testSplineRowsProduceExactCubicInsteadOfControlPolygon() throws {
        let n = model().page.nodes[0],path = n.formatting.paths[0]
        XCTAssertEqual(path.commands.count,2);XCTAssertEqual(path.commands[1].kind,"C");XCTAssertEqual(path.commands[1].values,[0.25,0,0.75,0,1,1]);XCTAssertEqual(DiagramDrawing.outline(for:n).bounds.minY,136,accuracy:1e-9)
        let definition = try VisioSpline.definition(Array(n.formatting.geometry![0].rows.dropFirst()));XCTAssertEqual(definition.data.name,"NURBS");XCTAssertEqual(definition.firstKnot,0)
    }
    func testNonuniformSplineSpansJoinAtExpectedPoint() throws {
        var rows = model().page.nodes[0].formatting.geometry![0].rows
        rows[1].cells["D"] = cell("2");rows[1].cells["X"] = cell("0.2");rows[1].cells["Y"] = cell("1");rows[2].cells["X"] = cell("0.8");rows[2].cells["Y"] = cell("-1");rows[3].cells["X"] = cell("1");rows[3].cells["A"] = cell("0.5")
        let r = VisioFormat.geometryPaths([ShapeGeometrySection(index:0,cells:[:],rows:rows)],width:1,height:1);XCTAssertTrue(r.warnings.isEmpty);XCTAssertEqual(r.paths[0].commands.count,3);XCTAssertEqual(r.paths[0].commands[1].values.suffix(2),[0.5,1]);XCTAssertEqual(r.paths[0].commands[2].values.suffix(2),[1,1])
    }
    func testSplineFlushesBeforeFollowingSegmentsAndSeparateSubpaths() throws {
        var sections = model().page.nodes[0].formatting.geometry!;sections[0].rows.append(ShapeGeometryRow(index:5,type:"LineTo",cells:["X":cell("3"),"Y":cell("1")]))
        sections[0].rows.append(ShapeGeometryRow(index:6,type:"MoveTo",cells:["X":cell("0"),"Y":cell("1")]))
        sections[0].rows += sections[0].rows[1...3].map{var row = $0;row.index += 5;return row}
        let r = VisioFormat.geometryPaths(sections,width:2,height:2);XCTAssertTrue(r.warnings.isEmpty);XCTAssertEqual(r.paths[0].commands.map(\.kind),["M","C","L","M","C"]);XCTAssertEqual(r.paths[0].commands[2].values,[1.5,0.5])
    }
    func testSplineFormulasRecalculateAfterResizeAndParameterChange() throws {
        let old = model();var next = old;next.page.nodes[0].width = 288;next.page.nodes[0].formatting.sheet["User.ControlY"]?.value = "0.5"
        let r = ShapeSheetEngine.recalculate(next,previous:old);XCTAssertTrue(r.issues.isEmpty);XCTAssertEqual(r.diagram.page.nodes[0].formatting.paths[0].commands[1].values,[0.25,0.5,0.75,0.5,1,1]);XCTAssertEqual(GeometrySheet.cell("Geometry1.Y3",on:r.diagram.page.nodes[0])?.value,"1")
    }
    func testPublicRowTypesUnitsAndOpaqueCellsSurviveSourceEdits() throws {
        var original = model();original.page.nodes[0].formatting.geometry![0].rows[1].cells["X"]?.unit = "IN";original.page.nodes[0].formatting.geometry![0].rows[1].cells["VendorExtra"] = cell("opaque")
        let (old,before) = try publicRead(original);var next = old;next.page.nodes[0].formatting.sheet["User.ControlY"]?.value = "0.5";next = ShapeSheetEngine.recalculate(next,previous:old).diagram
        let (read,after) = try publicRead(next)
        for (key,value) in before where key != "visio/pages/page1.xml" { XCTAssertEqual(after[key],value,key) }
        let n = read.page.nodes[0];XCTAssertEqual(n.formatting.geometry![0].rows.map(\.type),["MoveTo","SplineStart","SplineKnot","SplineKnot"]);XCTAssertEqual(GeometrySheet.cell("Geometry1.X2",on:n)?.unit,"IN");XCTAssertEqual(GeometrySheet.cell("Geometry1.VendorExtra2",on:n)?.value,"opaque");XCTAssertEqual(GeometrySheet.cell("Geometry1.Y2",on:n)?.formula,"Height*User.ControlY");XCTAssertEqual(n.formatting.paths[0].commands[1].values[1],0.5,accuracy:1e-9)
    }
    func testIndependentPublicSplineGraphicsMatchInBothFormatsWithoutMetadata() throws {
        let d = model(),expected = DiagramDrawing.outline(for:d.page.nodes[0]).bounds
        for ext in ["vsdx","vsd"] {
            let out = file(ext);if ext == "vsd" { try VSDBinaryFormat.encoded(d,includeMetadata:false).write(to:out) } else { let (_,parts) = try publicRead(d);try VisioPackage.write(parts,to:out) }
            let p = try independent(out),bounds = p.nodes.filter{!$0.formatting.paths.isEmpty}.reduce(CGRect.null){$0.union(DiagramDrawing.outline(for:$1).bounds)}
            XCTAssertTrue(p.nodes.contains{$0.formatting.paths.contains{$0.commands.contains{$0.kind == "C"}}});XCTAssertEqual(bounds.minX,expected.minX,accuracy:0.02);XCTAssertEqual(bounds.minY,expected.minY,accuracy:0.02);XCTAssertEqual(bounds.width,expected.width,accuracy:0.02);XCTAssertEqual(bounds.height,expected.height,accuracy:0.02)
        }
    }
    func testInvalidSplineSequencesRetainControlPolygonAndReportDiagnostics() throws {
        var s = model().page.nodes[0].formatting.geometry!;s[0].rows[1].cells["D"] = cell("25");var issues:[VisioFormat.GeometryIssue] = []
        let r = VisioFormat.geometryPaths(s,width:2,height:2,onIssue:{issues.append($0)});XCTAssertFalse(r.warnings.isEmpty);XCTAssertEqual(issues.count,1);XCTAssertEqual(issues[0].type,"SplineStart");XCTAssertEqual(r.paths[0].commands.map(\.kind),["M","L","L","L"])
        s[0].rows.remove(at:1);issues.removeAll();_ = VisioFormat.geometryPaths(s,width:2,height:2,onIssue:{issues.append($0)});XCTAssertEqual(issues.count,2);XCTAssertTrue(issues.allSatisfy{$0.type == "SplineKnot"})
    }
    func testSplineGeometryCellEditingSupportsUndo() throws {
        _ = NSApplication.shared;let doc = MacVisioDocument();doc.diagram = model();doc.makeWindowControllers();doc.undoManager?.groupsByEvent = false
        let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController),id = doc.diagram.page.nodes[0].id
        doc.undoManager?.beginUndoGrouping();try editor.setGeometryCell("Geometry1.Y2",value:"2",formula:"Height/2",for:id);doc.undoManager?.endUndoGrouping()
        XCTAssertEqual(doc.diagram.page.nodes[0].formatting.paths[0].commands[1].values[1],0.5,accuracy:1e-9);doc.undoManager?.undo();XCTAssertEqual(GeometrySheet.cell("Geometry1.Y2",on:doc.diagram.page.nodes[0])?.formula,"Height*User.ControlY");doc.windowControllers.forEach{$0.close()}
    }
    func testCrossScaleSplineCoordinatesPreserveKnotsAndDegree() throws {
        var d = model();d.page.drawingScale = DrawingScale(page:1,drawing:50);d.page.width *= 50;d.page.height *= 50
        let original = d.page.nodes[0].formatting.paths[0].commands,converted = DrawingScale.convert(d.page,to:1,targetMeasured:false);d.pages = [converted];d.activePageID = converted.id
        let next = ShapeSheetEngine.recalculate(d).diagram.page.nodes[0]
        for (a,b) in zip(original,next.formatting.paths[0].commands) { XCTAssertEqual(a.kind,b.kind);for (x,y) in zip(a.values,b.values) { XCTAssertEqual(x,y,accuracy:1e-9) } }
        XCTAssertEqual(GeometrySheet.cell("Geometry1.C2",on:next)?.value,"1");XCTAssertEqual(GeometrySheet.cell("Geometry1.D2",on:next)?.value,"3")
    }
    func testVersionThreeNativeCachesRecoverSplineDefinitionsAndIdentities() throws {
        let expected = model();var old = expected;old.page.nodes[0].formatting.paths = [VectorPath(commands:[VectorCommand("M",0,1),VectorCommand("L",0.25,0),VectorCommand("L",0.75,0),VectorCommand("L",1,1)])]
        let out = file("vsdx");try VisioFormat.write(old,to:out);var parts = try VisioPackage.read(out),metadata = try JSONSerialization.jsonObject(with:parts["macvisio/document.json"]!) as! [String:Any];metadata["geometryVersion"] = 3;parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:metadata);try VisioPackage.write(parts,to:out)
        let read = try VisioFormat.read(from:out).diagram;XCTAssertEqual(read.page.nodes[0].formatting.paths,expected.page.nodes[0].formatting.paths);XCTAssertEqual(read.page.nodes[0].id,expected.page.nodes[0].id)
        let doc = MacVisioDocument();try doc.read(from:JSONEncoder().encode(old),ofType:MacVisioDocument.nativeType);XCTAssertEqual(doc.diagram.page.nodes[0].formatting.paths,expected.page.nodes[0].formatting.paths)
    }
}
