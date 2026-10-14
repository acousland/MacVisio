import AppKit
import XCTest
@testable import MacVisio

final class CompositeGeometryTests:XCTestCase {
    private var files:[URL] = []
    override func tearDown() { files.forEach{try? FileManager.default.removeItem(at:$0)};super.tearDown() }
    private func file(_ ext:String) -> URL { let f = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-composite-\(UUID()).\(ext)");files.append(f);return f }
    private func data(_ formula:String) throws -> CompositeGeometry { try CompositeGeometry.evaluate(formula,numeric:{_ in throw DiagramError.invalid("Unexpected numeric reference")}) }
    private func model() throws -> Diagram {
        var d = Diagram(),n = DiagramNode(x:100,y:100,text:"");n.width = 144;n.height = 144;n.formatting.sheet["User.C1X"] = ShapeSheetCell(value:"0.25")
        n.formatting.geometry = [ShapeGeometrySection(index:0,cells:["NoFill":ShapeSheetCell(value:"1")],rows:[ShapeGeometryRow(index:1,type:"MoveTo",cells:["X":ShapeSheetCell(value:"0"),"Y":ShapeSheetCell(value:"0")]),ShapeGeometryRow(index:2,type:"NURBSTo",cells:["X":ShapeSheetCell(value:"2",formula:"Width"),"Y":ShapeSheetCell(value:"0"),"A":ShapeSheetCell(value:"0"),"B":ShapeSheetCell(value:"1"),"C":ShapeSheetCell(value:"0"),"D":ShapeSheetCell(value:"1"),"E":ShapeSheetCell(value:"NURBS(1,3,0,0,0.25,1,0,1,0.75,1,0,1)",formula:"GUARD(NURBS(1,3,0,0,User.C1X,1,0,1,0.75,1,0,1))")])])]
        d.page.nodes = [n];return ShapeSheetEngine.recalculate(d).diagram
    }
    private func evaluate(_ curve:VisioNURBS.Cubic,_ t:Double) -> CGPoint { let u = 1-t;return CGPoint(x:u*u*u*curve.start.x+3*u*u*t*curve.a.x+3*u*t*t*curve.b.x+t*t*t*curve.end.x,y:u*u*u*curve.start.y+3*u*u*t*curve.a.y+3*u*t*t*curve.b.y+t*t*t*curve.end.y) }
    private func independentPage(_ url:URL) throws -> DiagramPage {
        let process = Process(),pipe = Pipe();process.executableURL = try XCTUnwrap(LegacyVisioFormat.converterURL);process.arguments = [url.path];process.standardOutput = pipe;process.standardError = FileHandle.nullDevice
        try process.run();let output = pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();XCTAssertEqual(process.terminationStatus,0)
        let text = String(decoding:output,as:UTF8.self),start = try XCTUnwrap(text.range(of:"<svg:svg")),end = try XCTUnwrap(text.range(of:"</svg:svg>"))
        return try SVGImport.page(Data(text[start.lowerBound..<end.upperBound].utf8),name:"Independent").page
    }
    func testNonrationalCubicHasExactBezierControls() throws {
        let c = try VisioNURBS.cubics(data("NURBS(1,3,1,1,0.25,1,0,1,0.75,1,0,1)"),from:.zero,to:CGPoint(x:1,y:0),firstKnot:0,penultimateKnot:0,firstWeight:1,lastWeight:1,width:1,height:1)
        XCTAssertEqual(c.count,1);XCTAssertEqual(c[0].a.x,0.25,accuracy:1e-10);XCTAssertEqual(c[0].a.y,1,accuracy:1e-10);XCTAssertEqual(c[0].b.x,0.75,accuracy:1e-10);XCTAssertEqual(c[0].b.y,1,accuracy:1e-10)
    }
    func testSerializedKnotPrecisionDoesNotDiscardValidCurves() throws {
        let a = try data("NURBS(0.20499544778396,3,0,0,0.76799121563205,0.56187247099078,0.16159116808785,1,0.77186712614949,0.565148656221,0.16159116808785,1)")
        let curves = try VisioNURBS.cubics(a,from:CGPoint(x:0.76,y:0.55),to:CGPoint(x:0.78,y:0.57),firstKnot:0.161591168087853,penultimateKnot:0.161591168087853,firstWeight:1,lastWeight:1,width:1,height:1)
        XCTAssertEqual(curves.count,1);XCTAssertEqual(curves[0].a.x,a.values[4],accuracy:1e-12);XCTAssertEqual(curves[0].a.y,a.values[5],accuracy:1e-12);XCTAssertEqual(curves[0].b.x,a.values[8],accuracy:1e-12)
        XCTAssertThrowsError(try VisioNURBS.cubics(a,from:.zero,to:CGPoint(x:1,y:1),firstKnot:0.2,penultimateKnot:0.2,firstWeight:1,lastWeight:1,width:1,height:1))
        // Earlier MacVisio compound caches used twelve significant digits.
        let older = try data("NURBS(0.204995447784,3,0,0,0.767991215632,0.561872470991,0.161591168088,1,0.771867126149,0.565148656221,0.161591168088,1)")
        let recovered = try VisioNURBS.cubics(older,from:CGPoint(x:0.76,y:0.55),to:CGPoint(x:0.78,y:0.57),firstKnot:0.161591168087853,penultimateKnot:0.161591168087853,firstWeight:1,lastWeight:1,width:1,height:1)
        XCTAssertEqual(recovered.count,1);XCTAssertEqual(recovered[0].a.x,older.values[4],accuracy:1e-12)
    }
    func testDistinctOneULPKnotSpansAreEvaluatedWithoutCollapsing() throws {
        let a = 1.0,b = a.nextUp,c = b.nextUp,d = c.nextUp
        let data = try self.data("NURBS(\(d),1,1,1,1,1,\(a),1,2,0,\(b),1)")
        let curves = try VisioNURBS.cubics(data,from:.zero,to:CGPoint(x:3,y:1),firstKnot:a,penultimateKnot:c,firstWeight:1,lastWeight:1,width:1,height:1)
        XCTAssertEqual(curves.count,3);XCTAssertEqual(curves.map(\.end),[CGPoint(x:1,y:1),CGPoint(x:2,y:0),CGPoint(x:3,y:1)])
        XCTAssertEqual(evaluate(curves[0],0.5),CGPoint(x:0.5,y:0.5));XCTAssertEqual(evaluate(curves[1],0.5),CGPoint(x:1.5,y:0.5))
        XCTAssertEqual(try self.data(data.formula).values,data.values)
    }
    func testFullPrecisionCompoundCachesRoundTripBeyondFormulaLengthLimit() throws {
        var values = [399.0,3,1,1]
        for i in 1...400 { values += [Double(i)/401,sin(Double(i)/10),Double(max(0,i-3)),1] }
        let original = CompositeGeometry(name:"NURBS",values:values),cache = original.formula
        XCTAssertGreaterThan(cache.count,16384)
        XCTAssertEqual(try CompositeGeometry.evaluate(cache,numeric:{_ in throw DiagramError.invalid("Unexpected reference")},cached:true),original)
        XCTAssertThrowsError(try data(cache))
        let sections = [ShapeGeometrySection(index:0,cells:[:],rows:[ShapeGeometryRow(index:1,type:"MoveTo",cells:["X":ShapeSheetCell(value:"0"),"Y":ShapeSheetCell(value:"0")]),ShapeGeometryRow(index:2,type:"NURBSTo",cells:["X":ShapeSheetCell(value:"1"),"Y":ShapeSheetCell(value:"0"),"A":ShapeSheetCell(value:"398"),"C":ShapeSheetCell(value:"0"),"E":ShapeSheetCell(value:cache)])])]
        let rendered = VisioFormat.geometryPaths(sections,width:1,height:1);XCTAssertTrue(rendered.warnings.isEmpty);XCTAssertGreaterThan(rendered.paths[0].commands.count,300)
    }
    func testRationalQuarterCircleMatchesAnalyticRadius() throws {
        let c = try VisioNURBS.cubics(data("NURBS(1,2,1,1,1,1,0,\(sqrt(0.5)))"),from:CGPoint(x:1,y:0),to:CGPoint(x:0,y:1),firstKnot:0,penultimateKnot:0,firstWeight:1,lastWeight:1,width:1,height:1)
        XCTAssertGreaterThan(c.count,1);XCTAssertEqual(c.first!.start,CGPoint(x:1,y:0));XCTAssertEqual(c.last!.end,CGPoint(x:0,y:1))
        for curve in c { for i in 0...20 { let p = evaluate(curve,Double(i)/20);XCTAssertEqual(hypot(p.x,p.y),1,accuracy:0.00002) } }
    }
    func testNonuniformKnotsProduceContinuousSpans() throws {
        let c = try VisioNURBS.cubics(data("NURBS(1,2,1,1,0.2,1,0,1,0.8,-1,0,1)"),from:.zero,to:CGPoint(x:1,y:0),firstKnot:0,penultimateKnot:0.5,firstWeight:1,lastWeight:1,width:1,height:1)
        XCTAssertEqual(c.count,2);XCTAssertEqual(c[0].end.x,0.5,accuracy:1e-10);XCTAssertEqual(c[0].end.y,0,accuracy:1e-10);XCTAssertEqual(c[0].end,c[1].start)
        let a = CGPoint(x:c[0].end.x-c[0].b.x,y:c[0].end.y-c[0].b.y),b = CGPoint(x:c[1].a.x-c[1].start.x,y:c[1].a.y-c[1].start.y);XCTAssertEqual(a.x,b.x,accuracy:1e-10);XCTAssertEqual(a.y,b.y,accuracy:1e-10)
    }
    func testHighDegreeBendsBetweenQuarterSamplesAreNotFlattened() throws {
        // y(t)=100*t²*(1-t)²*(t-.25)*(t-.5)*(t-.75). It and its
        // endpoint derivatives vanish at the old approximation's sample points.
        let y = [0.0,0,-25.0/56,65.0/56,-65.0/56,25.0/56,0,0]
        let points = (1..<7).map{"\(Double($0)/7),\(y[$0]),0,1"}.joined(separator:",")
        let curves = try VisioNURBS.cubics(data("NURBS(1,7,1,1,\(points))"),from:.zero,to:CGPoint(x:1,y:0),firstKnot:0,penultimateKnot:0,firstWeight:1,lastWeight:1,width:1,height:1)
        XCTAssertGreaterThan(curves.count,1)
        for x in [0.1,0.3,0.6,0.9] { let curve = try XCTUnwrap(curves.first{x >= $0.start.x && x <= $0.end.x}),p = evaluate(curve,(x-curve.start.x)/(curve.end.x-curve.start.x)),expected = 100*x*x*(1-x)*(1-x)*(x-0.25)*(x-0.5)*(x-0.75);XCTAssertEqual(p.y,expected,accuracy:0.00002) }
    }
    func testHighDegreeAndInvalidInputsAreBounded() throws {
        let controls = (1..<25).map{"\(Double($0)/25),\(Double($0)/25),0,1"}.joined(separator:",")
        let c = try VisioNURBS.cubics(data("NURBS(1,25,1,1,\(controls))"),from:.zero,to:CGPoint(x:1,y:1),firstKnot:0,penultimateKnot:0,firstWeight:1,lastWeight:1,width:1,height:1)
        XCTAssertEqual(c.count,1);let midpoint = evaluate(c[0],0.5);XCTAssertEqual(midpoint.x,0.5,accuracy:1e-9);XCTAssertEqual(midpoint.y,0.5,accuracy:1e-9)
        for invalid in ["NURBS(1,26,1,1,1,1,0,1)","POLYLINE(0,0,1)","NURBS(1,2,0.5,0,1,1,0,1)"] { XCTAssertThrowsError(try data(invalid)) }
        XCTAssertThrowsError(try VisioNURBS.cubics(data("NURBS(1,2,1,1,1,1,0,-1)"),from:.zero,to:CGPoint(x:1,y:1),firstKnot:0,penultimateKnot:0,firstWeight:1,lastWeight:1,width:1,height:1))
        XCTAssertThrowsError(try VisioNURBS.cubics(data("NURBS(1,2,1,1,1,1,0,1)"),from:.zero,to:CGPoint(x:1,y:1),firstKnot:0.5,penultimateKnot:0,firstWeight:1,lastWeight:1,width:1,height:1))
    }
    func testMixedPolylineCoordinateTypesAndSignedAxes() throws {
        let p = try data("POLYLINE(0,1,0.25,1,0.75,0.5)").coordinates(width:-4,height:8)
        XCTAssertEqual(p,[CGPoint(x:-1,y:1),CGPoint(x:-3,y:0.5)])
        let sections = [ShapeGeometrySection(index:0,cells:[:],rows:[ShapeGeometryRow(index:1,type:"MoveTo",cells:["X":ShapeSheetCell(value:"0"),"Y":ShapeSheetCell(value:"0")]),ShapeGeometryRow(index:2,type:"PolylineTo",cells:["X":ShapeSheetCell(value:"-4"),"Y":ShapeSheetCell(value:"0"),"A":ShapeSheetCell(value:"POLYLINE(0,1,0.25,1,0.75,0.5)")])])]
        let result = VisioFormat.geometryPaths(sections,width:-4,height:2);XCTAssertTrue(result.warnings.isEmpty);XCTAssertEqual(result.paths[0].commands[1].values,[0.75,0.5]);XCTAssertEqual(result.paths[0].commands[2].values,[0.25,0.75])
    }
    func testCompositeArgumentsRecalculateAndReferenceDataCells() throws {
        let old = try model();var next = old;next.page.nodes[0].width = 288;next.page.nodes[0].formatting.sheet["User.C1X"]?.value = "0.4"
        next.page.nodes[0].formatting.sheet["User.Curve"] = ShapeSheetCell(value:"",formula:"IF(TRUE,NURBS(1,3,0,0,User.C1X,1,0,1,0.75,1,0,1),Unsupported())")
        try GeometrySheet.set("Geometry1.E2",ShapeSheetCell(value:GeometrySheet.cell("Geometry1.E2",on:old.page.nodes[0])!.value,formula:"User.Curve"),on:&next.page.nodes[0])
        let result = ShapeSheetEngine.recalculate(next,previous:old);XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"\n"));XCTAssertEqual(result.diagram.page.nodes[0].formatting.paths[0].commands[1].values,[0.4,0,0.75,0,1,1])
        XCTAssertEqual(GeometrySheet.cell("Geometry1.E2",on:result.diagram.page.nodes[0])?.formula,"User.Curve")
    }
    func testUnsupportedAndCyclicCompositeExpressionsRetainSavedCurve() throws {
        var d = try model();let old = d.page.nodes[0].formatting.paths
        d.page.nodes[0].formatting.geometry![0].rows[1].cells["E"]?.formula = "Unsupported(Width)"
        let result = ShapeSheetEngine.recalculate(d);XCTAssertFalse(result.issues.isEmpty);XCTAssertEqual(result.diagram.page.nodes[0].formatting.paths,old)
        d.page.nodes[0].formatting.geometry![0].rows[1].cells["E"]?.formula = "User.Curve";d.page.nodes[0].formatting.sheet["User.Curve"] = ShapeSheetCell(value:"",formula:"Geometry1.E2")
        let circular = ShapeSheetEngine.recalculate(d);XCTAssertTrue(circular.issues.contains{$0.contains("Circular")});XCTAssertEqual(circular.diagram.page.nodes[0].formatting.paths,old)
    }
    func testPublicVSDXAndBinaryCurvesHaveMatchingBoundsWithoutPrivateModel() throws {
        let diagram = try model(),expected = DiagramDrawing.outline(for:diagram.page.nodes[0]).bounds
        for ext in ["vsdx","vsd"] {
            let out = file(ext)
            if ext == "vsd" { try VSDBinaryFormat.encoded(diagram,includeMetadata:false).write(to:out) }
            else { try VisioFormat.write(diagram,to:out);var parts = try VisioPackage.read(out);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:out)
                let imported = try VisioFormat.read(from:out).diagram;XCTAssertEqual(GeometrySheet.cell("Geometry1.E2",on:imported.page.nodes[0])?.formula,GeometrySheet.cell("Geometry1.E2",on:diagram.page.nodes[0])?.formula)
            }
            let parsed = try independentPage(out)
            let bounds = parsed.nodes.filter{!$0.formatting.paths.isEmpty}.reduce(CGRect.null){$0.union(DiagramDrawing.outline(for:$1).bounds)}
            XCTAssertEqual(bounds.minX,expected.minX,accuracy:0.02,ext);XCTAssertEqual(bounds.minY,expected.minY,accuracy:0.02,ext);XCTAssertEqual(bounds.width,expected.width,accuracy:0.02,ext);XCTAssertEqual(bounds.height,expected.height,accuracy:0.02,ext)
        }
    }
    func testCrossScaleCompositeCachesPreserveCoordinates() throws {
        var d = try model();d.page.drawingScale = DrawingScale(page:1,drawing:50);d.page.width *= 50;d.page.height *= 50
        d.page.nodes[0].formatting.geometry![0].rows[1].cells["E"] = ShapeSheetCell(value:"NURBS(1,3,0,1,0.25,2,0,1,0.75,2,0,1)");d = ShapeSheetEngine.recalculate(d).diagram
        let original = d.page.nodes[0].formatting.paths[0].commands,converted = DrawingScale.convert(d.page,to:1,targetMeasured:false);d.pages = [converted];d.activePageID = converted.id
        let next = ShapeSheetEngine.recalculate(d).diagram.page.nodes[0];XCTAssertEqual(next.formatting.paths[0].commands.count,original.count)
        for (a,b) in zip(next.formatting.paths[0].commands,original) { XCTAssertEqual(a.kind,b.kind);for (x,y) in zip(a.values,b.values) { XCTAssertEqual(x,y,accuracy:1e-10) } }
        XCTAssertEqual(GeometrySheet.cell("Geometry1.E2",on:next)?.value,"NURBS(1,3,0,1,0.25,0.04,0,1,0.75,0.04,0,1)")
    }
    func testCompositeSourceEditsPatchCachesWithoutFlatteningOrLosingUnknownCells() throws {
        let source = file("vsdx");try VisioFormat.write(model(),to:source);var parts = try VisioPackage.read(source);parts.removeValue(forKey:"macvisio/document.json")
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!),shape = xml.rootElement()!.firstLocal("Shapes")!.elementsLocal("Shape")[0],section = shape.elementsLocal("Section").first{$0.attr("N") == "Geometry"}!,row = section.elementsLocal("Row").first{$0.attr("IX") == "2"}!
        row.addChild(try VisioXML.element("<Cell N=\"VendorExtra\" V=\"opaque\" U=\"STR\"/>"));parts["visio/pages/page1.xml"] = xml.xmlData(options:.nodePreserveAll);try VisioPackage.write(parts,to:source)
        let old = try VisioFormat.read(from:source).diagram;var next = old;next.page.nodes[0].formatting.sheet["User.C1X"]?.value = "0.4";next = ShapeSheetEngine.recalculate(next,previous:old).diagram
        let destination = file("vsdx");try VisioFormat.write(next,to:destination);var output = try VisioPackage.read(destination);output.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(output,to:destination)
        for (key,value) in parts where key != "visio/pages/page1.xml" { XCTAssertEqual(output[key],value,key) }
        let read = try VisioFormat.read(from:destination).diagram,node = read.page.nodes[0]
        XCTAssertEqual(GeometrySheet.cell("Geometry1.E2",on:node)?.formula,"GUARD(NURBS(1,3,0,0,User.C1X,1,0,1,0.75,1,0,1))");XCTAssertEqual(GeometrySheet.cell("Geometry1.VendorExtra2",on:node)?.value,"opaque");XCTAssertEqual(GeometrySheet.cell("Geometry1.VendorExtra2",on:node)?.unit,"STR")
        XCTAssertEqual(node.formatting.paths[0].commands[1].values[0],0.4,accuracy:1e-9);XCTAssertEqual(node.formatting.geometry![0].rows[1].type,"NURBSTo")
    }
    func testWeightedNURBSAndPolylineBinarySavedRecordsMatchPublicGraphics() throws {
        for nurbs in [false,true] {
            var d = try model();d.page.nodes[0].formatting.geometry![0].rows[1] = ShapeGeometryRow(index:2,type:nurbs ? "NURBSTo" : "PolylineTo",cells:["X":ShapeSheetCell(value:nurbs ? "0" : "2"),"Y":ShapeSheetCell(value:nurbs ? "1" : "0"),"A":ShapeSheetCell(value:nurbs ? "0" : "POLYLINE(0,1,0.25,1,0.75,0.5)"),"E":ShapeSheetCell(value:"NURBS(1,2,1,1,1,1,0,\(sqrt(0.5)))")])
            if nurbs { d.page.nodes[0].formatting.geometry![0].rows[0].cells["X"]?.value = "1" }
            let calculated = ShapeSheetEngine.recalculate(d);XCTAssertTrue(calculated.issues.isEmpty);d = calculated.diagram
            let expected = DiagramDrawing.outline(for:d.page.nodes[0]).bounds
            for ext in ["vsdx","vsd"] {
                let out = file(ext);if ext == "vsdx" { try VisioFormat.write(d,to:out) } else { try VSDBinaryFormat.encoded(d,includeMetadata:false).write(to:out) }
                let p = try independentPage(out),actual = p.nodes.filter{!$0.formatting.paths.isEmpty}.reduce(CGRect.null){$0.union(DiagramDrawing.outline(for:$1).bounds)}
                XCTAssertEqual(actual.minX,expected.minX,accuracy:0.03);XCTAssertEqual(actual.minY,expected.minY,accuracy:0.03);XCTAssertEqual(actual.width,expected.width,accuracy:0.03);XCTAssertEqual(actual.height,expected.height,accuracy:0.03)
            }
        }
    }
    func testEarlierNativeGeometryCachesAreRecoveredFromRetainedDefinitions() throws {
        let expected = try model();var old = expected;old.page.nodes[0].formatting.paths = [VectorPath(commands:[VectorCommand("M",0,1),VectorCommand("L",1,1)])]
        let doc = MacVisioDocument();try doc.read(from:JSONEncoder().encode(old),ofType:MacVisioDocument.nativeType);XCTAssertEqual(doc.diagram.page.nodes[0].formatting.paths,expected.page.nodes[0].formatting.paths)
        var binary = try CompoundFile.read(VSDBinaryFormat.encoded(old)),envelope = try JSONSerialization.jsonObject(with:binary.streams[VSDBinaryFormat.nativeStream]!) as! [String:Any]
        envelope.removeValue(forKey:"geometryVersion");binary.streams[VSDBinaryFormat.nativeStream] = try JSONSerialization.data(withJSONObject:envelope)
        let recovered = try XCTUnwrap(VSDBinaryFormat.nativeModel(in:binary));XCTAssertEqual(recovered.page.nodes[0].formatting.paths,expected.page.nodes[0].formatting.paths)
        let out = file("vsdx");try VisioFormat.write(old,to:out);var parts = try VisioPackage.read(out),metadata = try JSONSerialization.jsonObject(with:parts["macvisio/document.json"]!) as! [String:Any]
        for version in [1,2] {
            metadata["geometryVersion"] = version;parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:metadata);try VisioPackage.write(parts,to:out)
            let imported = try VisioFormat.read(from:out);XCTAssertTrue(imported.warnings.contains{$0.contains("native composite caches were rebuilt")});XCTAssertEqual(imported.diagram.page.nodes[0].formatting.paths,expected.page.nodes[0].formatting.paths);XCTAssertEqual(imported.diagram.page.id,old.page.id);XCTAssertEqual(imported.diagram.page.nodes[0].id,old.page.nodes[0].id)
        }
    }
    func testVersionOneGeometryMetadataRetainsOriginalLegacySourceBytes() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource:"no-bgcolor",withExtension:"vsd",subdirectory:"Fixtures")),bytes = try Data(contentsOf:fixture),original = try LegacyVisioFormat.read(from:fixture).diagram
        let out = file("vsdx");try VisioFormat.write(original,to:out);var parts = try VisioPackage.read(out),metadata = try JSONSerialization.jsonObject(with:parts["macvisio/document.json"]!) as! [String:Any]
        metadata["geometryVersion"] = 1;parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:metadata);try VisioPackage.write(parts,to:out)
        let read = try VisioFormat.read(from:out).diagram;XCTAssertEqual(read.page.id,original.page.id);XCTAssertEqual(read.legacySource?.data,bytes);XCTAssertEqual(try VSDBinaryFormat.encoded(read),bytes)
    }
    func testNativeCompositeGeometryCacheEditingAndUndo() throws {
        _ = NSApplication.shared;let doc = MacVisioDocument();doc.diagram = try model();doc.makeWindowControllers();doc.undoManager?.groupsByEvent = false
        let editor = try XCTUnwrap(doc.windowControllers.first as? EditorWindowController),id = doc.diagram.page.nodes[0].id
        doc.undoManager?.beginUndoGrouping();try editor.setGeometryCell("Geometry1.E2",value:"NURBS(1,3,0,0,0.4,1,0,1,0.75,1,0,1)",formula:"",for:id);doc.undoManager?.endUndoGrouping()
        XCTAssertEqual(doc.diagram.page.nodes[0].formatting.paths[0].commands[1].values[0],0.4,accuracy:1e-9);doc.undoManager?.undo();XCTAssertEqual(GeometrySheet.cell("Geometry1.E2",on:doc.diagram.page.nodes[0])?.formula,GeometrySheet.cell("Geometry1.E2",on:try model().page.nodes[0])?.formula)
        doc.windowControllers.forEach{$0.close()}
    }
}
