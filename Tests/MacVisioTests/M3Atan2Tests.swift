import Foundation
import CryptoKit
import XCTest
@testable import MacVisio

/// Local engineering against the primary ATan2 range and PtgAngDft contract.
/// Expected angles below use independent constants and geometric identities.
final class M3Atan2Tests: XCTestCase {
    private func scalar(_ formula:String) throws -> Double {
        try ShapeSheet.evaluate(formula){_ in throw DiagramError.invalid("Unexpected reference")}
    }
    private func typed(_ formula:String,scalar:Bool = false) throws -> SheetValue {
        try TypedShapeSheet.evaluate(formula,resolve:{_ in throw DiagramError.invalid("Unexpected reference")},call:{_,_ in throw DiagramError.invalid("Unexpected function")},scalar:scalar)
    }
    private func angle(_ y:Double,_ x:Double) -> ShapeSheet.Expression { .call("ATAN2",[.number(y),.number(x)]) }
    private func values(_ expression:ShapeSheet.Expression) throws -> [Double] {
        [try ShapeSheet.evaluate(expression,resolve:{_ in 0}),
         try TypedShapeSheet.evaluate(expression,resolve:{_ in .number(0)},call:{_,_ in .number(0)}).numeric(),
         try TypedShapeSheet.evaluate(expression,resolve:{_ in .number(0)},call:{_,_ in .number(0)},scalar:true).numeric()]
    }
    private func assertAngle(_ y:Double,_ x:Double,_ expected:Double,accuracy:Double = 1e-14,file:StaticString = #filePath,line:UInt = #line) throws {
        for value in try values(angle(y,x)) {
            XCTAssertEqual(value,expected,accuracy:accuracy,file:file,line:line)
            XCTAssertGreaterThan(value,-Double.pi,file:file,line:line);XCTAssertLessThanOrEqual(value,Double.pi,file:file,line:line)
        }
    }
    private func rejects(_ expression:ShapeSheet.Expression,file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertThrowsError(try ShapeSheet.evaluate(expression,resolve:{_ in 0}),file:file,line:line)
        for mode in [false,true] {
            XCTAssertThrowsError(try TypedShapeSheet.evaluate(expression,resolve:{_ in .number(0)},call:{_,_ in .number(0)},scalar:mode),file:file,line:line)
        }
    }

    func testDocumentedInputsAndArgumentOrderUseGeometricAngles() throws {
        // Microsoft Learn's first example prints 29.0456, but atan(5/9) in
        // degrees is 29.054604099077146. Follow the function contract.
        // DEG retypes the radian value as degrees without scaling it (EXPR-48).
        XCTAssertEqual(try scalar("DEG(ATAN2(1.25,2.25))"),29.054604099077146 * .pi/180,accuracy:1e-12)
        XCTAssertEqual(try scalar("DEG(ATAN2(1,SQRT(3)))"),Double.pi/6,accuracy:1e-12)
        XCTAssertEqual(try scalar("DEG(ATAN2(1,1))"),Double.pi/4,accuracy:1e-12)
        try assertAngle(1,2,0.4636476090008061);try assertAngle(2,1,1.1071487177940904)
    }

    func testAxesAndFourQuadrantsUseTheNormativePrincipalRange() throws {
        for (y,x,expected) in [(0.0,1.0,0.0),(1,0,Double.pi/2),(0,-1,Double.pi),(-1,0,-Double.pi/2),
                               (1,1,Double.pi/4),(1,-1,3*Double.pi/4),(-1,-1,-3*Double.pi/4),(-1,1,-Double.pi/4)] {
            try assertAngle(y,x,expected)
        }
    }

    func testEverySignedZeroOriginReturnsPositiveZero() throws {
        for y in [0.0,-0.0] { for x in [0.0,-0.0] {
            for value in try values(angle(y,x)) { XCTAssertEqual(value,0);XCTAssertEqual(value.sign,.plus) }
        } }
    }

    func testNegativeAxisMapsExcludedMinusPiToPlusPiWithoutTolerance() throws {
        for zero in [0.0,-0.0] { try assertAngle(zero,-1,Double.pi,accuracy:0) }
        // Nearby representable angles remain on their own side of the cut.
        try assertAngle(1e-12,-1,Double.pi-1e-12,accuracy:1e-15)
        try assertAngle(-1e-12,-1,-Double.pi+1e-12,accuracy:1e-15)
        for value in try values(angle(-1e-12,-1)) { XCTAssertLessThan(value,0) }
        // Signed zero on the positive axis is within the documented interval.
        for value in try values(angle(-0.0,1)) { XCTAssertEqual(value,0);XCTAssertEqual(value.sign,.minus) }
    }

    func testEqualFiniteExtremesRetainQuadrantsWithoutIntermediateDivision() throws {
        for magnitude in [Double.greatestFiniteMagnitude,Double.leastNormalMagnitude,Double.leastNonzeroMagnitude] {
            try assertAngle(magnitude,magnitude,Double.pi/4)
            try assertAngle(magnitude,-magnitude,3*Double.pi/4)
            try assertAngle(-magnitude,-magnitude,-3*Double.pi/4)
            try assertAngle(-magnitude,magnitude,-Double.pi/4)
        }
    }

    func testUnbalancedFiniteExtremesRemainFiniteAtRepresentableAxesAndCut() throws {
        let large = Double.greatestFiniteMagnitude,tiny = Double.leastNonzeroMagnitude
        try assertAngle(large,tiny,Double.pi/2,accuracy:0);try assertAngle(-large,tiny,-Double.pi/2,accuracy:0)
        try assertAngle(tiny,large,0,accuracy:0);try assertAngle(-tiny,large,0,accuracy:0)
        try assertAngle(tiny,-large,Double.pi,accuracy:0);try assertAngle(-tiny,-large,Double.pi,accuracy:0)
        try assertAngle(large/2,large,0.4636476090008061)
    }

    func testNonfiniteInputsAndWrongArityRemainErrorsWithLazyFallback() throws {
        for value in [Double.infinity,-Double.infinity,Double.nan] { rejects(angle(value,1));rejects(angle(1,value)) }
        let invalidArguments:[[ShapeSheet.Expression]] = [[],[.number(1)],[.number(1),.number(2),.number(3)]]
        for arguments in invalidArguments { rejects(.call("ATAN2",arguments)) }
        for formula in ["ATAN2(1,)","ATAN2(EXP(1000),1)","ATAN2(1,1/0)"] {
            XCTAssertThrowsError(try scalar(formula));XCTAssertThrowsError(try typed(formula))
        }
        XCTAssertEqual(try scalar("IFERROR(ATAN2(1),17)"),17)
        XCTAssertEqual(try typed("IFERROR(ATAN2(1),17)"),.number(17))
    }

    func testTypedResultCarriesDefaultAngleAndComposesWithKnownAngleQuantities() throws {
        let result = try typed("ATAN2(1,1)")
        XCTAssertEqual(result.unit,"DA");XCTAssertEqual(result.dimension,"angle")
        XCTAssertEqual(try result.numeric(),Double.pi/4,accuracy:1e-15)
        XCTAssertEqual(try typed("ATAN2(1,1)+45deg").numeric(),Double.pi/2,accuracy:1e-14)
        XCTAssertEqual(try typed("ATAN2(1,1)/45deg"),.number(1))
        XCTAssertEqual(try typed("ATAN2(1,1)",scalar:true),.number(Double.pi/4))
        // Visio adds internal values and keeps the first unit (EXPR-36, EXPR-41).
        XCTAssertEqual(try typed("ATAN2(1,1)+1in").numeric(),Double.pi/4+1,accuracy:1e-14)
        XCTAssertEqual(try typed("ATAN2(1,1)+1").numeric(),Double.pi/4+1,accuracy:1e-14)
        XCTAssertEqual(try FieldFormatting.format(result,picture:"esc(7)",unit:"DEG",type:2),"45.00 deg")
        XCTAssertEqual(try FieldFormatting.format(result,picture:"esc(7)",unit:"RAD",type:2),"0.79 rad")
    }

    func testVDoubleUnitInputsUseCanonicalValuesRatherThanDisplayDigits() throws {
        for formula in ["ATAN2(25.4mm,1in)","ATAN2(72pt,25.4mm)","ATAN2(1rad,1in)","ATAN2(13mm*2,26mm)"] {
            XCTAssertEqual(try scalar(formula),Double.pi/4,accuracy:1e-14)
            let value = try typed(formula);XCTAssertEqual(value.unit,"DA");XCTAssertEqual(try value.numeric(),Double.pi/4,accuracy:1e-14)
        }
    }

    func testExistingTypedCoercionsRemainBoundedAndUnsupportedInputsRefuse() throws {
        XCTAssertEqual(try typed("ATAN2(\"1\",\"1\")"),.quantity(Double.pi/4,"DA"))
        XCTAssertEqual(try typed("ATAN2(TRUE,TRUE)"),.quantity(Double.pi/4,"DA"))
        XCTAssertThrowsError(try scalar("ATAN2(\"1\",\"1\")"))
        let day = ShapeSheet.Expression.call("ATAN2",[.reference("Day"),.number(25569)])
        XCTAssertEqual(try TypedShapeSheet.evaluate(day,resolve:{_ in .date(SheetValue.date(serial:25569))},call:{_,_ in .number(0)}),.quantity(Double.pi/4,"DA"))
        for formula in ["ATAN2(\"1in\",1)","ATAN2(1,\"TRUE\")","ATAN2(\"bad\",1)","ATAN2(1furlong,1)"] {
            XCTAssertThrowsError(try typed(formula));XCTAssertThrowsError(try scalar(formula))
        }
        for value in [SheetValue.quantity(1,"UNSUPPORTED"),.color(ShapeSheetColor(red:1,green:2,blue:3))] {
            for formula in ["ATAN2(Input,1)","ATAN2(1,Input)"] {
                XCTAssertThrowsError(try TypedShapeSheet.evaluate(formula,resolve:{_ in value},call:{_,_ in .number(0)}))
            }
        }
    }

    func testShapePageAndDocumentHostsShareDefaultAngleMetadata() throws {
        var drawing = Diagram(),node = DiagramNode(text:"")
        let scope = UUID(),sheetID = DefinitionRegistry.stableID(scope,"sheet:TheDoc")
        var documentSheet = DefinitionSheet(id:sheetID,publicID:"TheDoc",parentID:nil,attributes:[:],cells:[],rows:[],text:nil)
        for (name,cell) in [("Y",ShapeSheetCell(value:"1",unit:"IN")),("X",ShapeSheetCell(value:"1",unit:"MM")),
                            ("Direction",ShapeSheetCell(value:"9",formula:"ATAN2(User.Y,User.X)",unit:"DA"))] {
            documentSheet.set(DefinitionCellAddress(cell:"Value",section:"User",rowName:name),to:cell)
        }
        drawing.definitions = DefinitionRegistry(sourceDocumentID:scope,documentPart:"visio/document.xml",documentSheet:documentSheet,masters:[],styles:[],uses:[])
        drawing.page.sheet = ["User.Direction":ShapeSheetCell(value:"9",formula:"TheDoc!User.Direction",unit:"DA")]
        node.formatting.sheet = ["User.Direction":ShapeSheetCell(value:"9",formula:"ThePage!User.Direction",unit:"DA")];drawing.page.nodes = [node]
        let scalarHost = ShapeSheetContext(page:drawing.page,document:drawing,mode:.scalarGeometry)
        let typedHost = ShapeSheetContext(page:drawing.page,document:drawing,mode:.typedFields)
        for reference in ["User.Direction","ThePage!User.Direction","TheDoc!User.Direction"] {
            XCTAssertEqual(try scalarHost.value(node.id,reference),.number(Double.pi/4))
            XCTAssertEqual(try typedHost.value(node.id,reference),.quantity(Double.pi/4,"DA"))
        }
    }

    func testSharedHostErrorsDoNotSubstituteTheStoredAngleCache() throws {
        var page = DiagramPage(),node = DiagramNode(text:"")
        let cell = ShapeSheetCell(value:"0.25",formula:"ATAN2(1)",unit:"DA")
        node.formatting.sheet["User.Bad"] = cell;page.nodes = [node];page.sheet = ["User.Bad":cell]
        for mode in [ShapeSheetContext.ValueMode.scalarGeometry,.typedFields] {
            let host = ShapeSheetContext(page:page,mode:mode)
            for reference in ["User.Bad","ThePage!User.Bad"] { XCTAssertThrowsError(try host.value(node.id,reference)) }
        }
        XCTAssertEqual(page.nodes[0].formatting.sheet["User.Bad"],cell);XCTAssertEqual(page.sheet?["User.Bad"],cell)
    }

    func testAngleMetadataGeometryAndExplicitFieldFormattingSurvivePublicOnlySave() throws {
        var drawing = Diagram(),node = DiagramNode(x:100,y:100,text:"")
        node.formatting.sourceShapeID = "9"
        node.formatting.sheet["Angle"] = ShapeSheetCell(value:"0",formula:"ATAN2(1,1)",unit:"DA")
        node = try TextFieldEngine.inserting(formula:"ATAN2(1,1)+45deg",picture:"0.00",type:2,into:node)
        node.formatting.textFields?[0].cells["Value"]?.unit = "DA"
        let expectedFieldIndex = try XCTUnwrap(node.formatting.textFields?.first?.index)
        var degrees = try TextFieldEngine.inserting(formula:"ATAN2(1,1)",picture:"esc(7)",type:2,into:DiagramNode(x:350,y:100,text:""))
        degrees.formatting.sourceShapeID = "10";degrees.formatting.textFields?[0].cells["Value"]?.unit = "DEG"
        var unitless = try TextFieldEngine.inserting(formula:"ATAN2(1,1)",picture:"0.00",type:2,into:DiagramNode(x:100,y:300,text:""))
        unitless.formatting.sourceShapeID = "11"
        let unitlessFieldIndex = try XCTUnwrap(unitless.formatting.textFields?.first?.index)
        XCTAssertEqual(unitless.formatting.textFields?.first?.cells["Value"]?.unit,"")
        drawing.page.nodes = [node,degrees,unitless]
        let result = DiagramCalculation.recalculate(drawing)
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined());XCTAssertEqual(result.diagram.page.nodes[0].rotation,-45,accuracy:1e-10)
        XCTAssertEqual(result.diagram.page.nodes[0].text,"90.00");XCTAssertEqual(result.diagram.page.nodes[1].text,"45.00 deg")  // angles display in degrees (FORMATESC-ang)
        XCTAssertEqual(result.diagram.page.nodes[2].text,"45.00")
        XCTAssertEqual(result.diagram.page.nodes[2].formatting.textFields?.first?.cells["Value"]?.unit,"")
        let saved = try publicSave(result.diagram),reopened = DiagramCalculation.recalculate(saved.diagram)
        XCTAssertTrue(reopened.issues.isEmpty,reopened.issues.joined())
        let publicNode = try XCTUnwrap(reopened.diagram.page.nodes.first{$0.formatting.sourceShapeID == "9"})
        XCTAssertEqual(publicNode.rotation,-45,accuracy:1e-8);XCTAssertEqual(publicNode.text,"90.00")
        XCTAssertEqual(publicNode.formatting.textFields?.first?.cells["Value"]?.unit,"DA")
        XCTAssertEqual(publicNode.formatting.textFields?.first?.cells["Value"]?.formula,"ATAN2(1,1)+45deg")
        let shape = try publicShape(saved.parts,id:"9"),publicAngle = try XCTUnwrap(shape.elementsLocal("Cell").first{$0.attr("N") == "Angle"})
        XCTAssertEqual(publicAngle.attr("F"),"ATAN2(1,1)");XCTAssertEqual(publicAngle.attr("U"),"DA")
        XCTAssertEqual(Double(publicAngle.attr("V") ?? "") ?? 0,Double.pi/4,accuracy:1e-11)
        let field = try publicField(shape,index:expectedFieldIndex)
        XCTAssertEqual(field.attr("U"),"DA");XCTAssertEqual(field.attr("F"),"ATAN2(1,1)+45deg")
        XCTAssertEqual(Double(field.attr("V") ?? "") ?? 0,Double.pi/2,accuracy:1e-11)
        XCTAssertEqual(reopened.diagram.page.nodes.first{$0.formatting.sourceShapeID == "10"}?.text,"45.00 deg")
        let unitlessNode = try XCTUnwrap(reopened.diagram.page.nodes.first{$0.formatting.sourceShapeID == "11"})
        XCTAssertEqual(unitlessNode.text,"45.00");XCTAssertEqual(unitlessNode.formatting.textFields?.first?.cells["Value"]?.unit,"")
        let unitlessValue = try publicField(publicShape(saved.parts,id:"11"),index:unitlessFieldIndex)
        XCTAssertNil(unitlessValue.attr("U"));XCTAssertEqual(unitlessValue.attr("F"),"ATAN2(1,1)")
        XCTAssertEqual(Double(unitlessValue.attr("V") ?? "") ?? 0,Double.pi/4,accuracy:1e-11)
        try retainEvidenceIfRequested(saved,testName:#function,scenario:"default-angle-and-degrees")
    }

    func testInvalidAtan2KeepsGeometryAndFieldCachesAndPublicSourceDefinitions() throws {
        let scenarios = [("wrong-arity","ATAN2(1)"),("nonfinite-input","ATAN2(EXP(1000),1)"),
                         ("division-error","ATAN2(1,1/0)"),("unsupported-unit-string","ATAN2(\"1in\",1)")]
        for (scenario,formula) in scenarios {
            var drawing = Diagram(),node = DiagramNode(x:100,y:100,text:"Kept")
            node.rotation = -14.32394487827058;node.formatting.sourceShapeID = "9"
            let angleCell = ShapeSheetCell(value:"0.25",formula:formula,unit:"DA")
            node.formatting.sheet["Angle"] = angleCell
            node.formatting.textFields = [ShapeTextField(index:0,cells:["Value":angleCell,"Type":ShapeSheetCell(value:"2")],cached:"Kept")]
            node.formatting.textRuns = [ShapeTextRun(text:"Kept",character:ShapeCharacterStyle(node:node),paragraph:ShapeParagraphStyle(),fieldIndex:0,fieldToken:UUID())]
            drawing.page.nodes = [node]
            let imported = try publicSave(drawing).diagram,result = DiagramCalculation.recalculate(imported)
            XCTAssertFalse(result.issues.isEmpty)
            let kept = try XCTUnwrap(result.diagram.page.nodes.first)
            XCTAssertEqual(kept.rotation,node.rotation,accuracy:1e-8);XCTAssertEqual(kept.text,"Kept")
            XCTAssertEqual(kept.formatting.sheet["Angle"],angleCell);XCTAssertEqual(kept.formatting.textFields?.first?.cells["Value"],angleCell)
            let saved = try publicSave(result.diagram),shape = try publicShape(saved.parts,id:"9")
            XCTAssertEqual(saved.diagram.page.nodes.first?.text,"Kept")
            for cell in [try XCTUnwrap(shape.elementsLocal("Cell").first{$0.attr("N") == "Angle"}),try publicField(shape)] {
                XCTAssertEqual(cell.attr("F"),formula);XCTAssertEqual(cell.attr("V"),"0.25");XCTAssertEqual(cell.attr("U"),"DA")
            }
            try retainEvidenceIfRequested(saved,testName:#function,scenario:scenario)
        }
    }

    private func file() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-Atan2-\(UUID()).vsdx")
        addTeardownBlock{try? FileManager.default.removeItem(at:url)};return url
    }
    private typealias SavedDrawing = (diagram:Diagram,parts:[String:Data],nativeURL:URL,publicURL:URL)
    private func publicSave(_ diagram:Diagram) throws -> SavedDrawing {
        let native = file();try VisioFormat.write(diagram,to:native);var parts = try VisioPackage.read(native)
        if let metadata = parts["macvisio/document.json"] {
            let storage = try NativeMetadataStorage.load(metadata,parts:parts)
            for name in storage.storageParts.union(["macvisio/document.json"]) { parts.removeValue(forKey:name) }
        }
        let relationships = try VisioXML.document(XCTUnwrap(parts["_rels/.rels"]))
        for item in relationships.rootElement()?.elementsLocal("Relationship") ?? [] where item.attr("Type") == "urn:macvisio:relationships:diagram" { item.detach() }
        parts["_rels/.rels"] = relationships.xmlData(options:.nodePreserveAll)
        let types = try VisioXML.document(XCTUnwrap(parts["[Content_Types].xml"]))
        for item in types.rootElement()?.elementsLocal("Override") ?? [] where item.attr("PartName") == "/macvisio/document.json" { item.detach() }
        parts["[Content_Types].xml"] = types.xmlData(options:.nodePreserveAll)
        XCTAssertFalse(parts.keys.contains{$0.hasPrefix("macvisio/")})
        let output = file();try VisioPackage.write(parts,to:output)
        return (try VisioFormat.read(from:output).diagram,parts,native,output)
    }
    private func publicShape(_ parts:[String:Data],id:String) throws -> XMLElement {
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        return try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first{$0.attr("ID") == id})
    }
    private func publicField(_ shape:XMLElement,index:Int = 0) throws -> XMLElement {
        try XCTUnwrap(shape.elementsLocal("Section").first{$0.attr("N") == "Field"}?.elementsLocal("Row").first{$0.attr("IX") == String(index)}?.elementsLocal("Cell").first{$0.attr("N") == "Value"})
    }

    /// An explicit absolute evidence directory retains five fixed artifact pairs.
    /// Each already-emitted package is limited to 16 MiB; manifests to 64 KiB.
    private func retainEvidenceIfRequested(_ saved:SavedDrawing,testName:String,scenario:String) throws {
        guard let path = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"],!path.isEmpty else { return }
        let allowed:[String:Set<String>] = [
            "testAngleMetadataGeometryAndExplicitFieldFormattingSurvivePublicOnlySave()":["default-angle-and-degrees"],
            "testInvalidAtan2KeepsGeometryAndFieldCachesAndPublicSourceDefinitions()":["wrong-arity","nonfinite-input","division-error","unsupported-unit-string"]]
        guard (path as NSString).isAbsolutePath,allowed[testName]?.contains(scenario) == true else {
            throw DiagramError.invalid("ATAN2 evidence requires an absolute M3_EVIDENCE_DIR and a known save scenario.")
        }
        let limit = 16*1024*1024
        func boundedData(_ url:URL) throws -> Data {
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard let bytes = attributes[.size] as? NSNumber,bytes.int64Value > 0,bytes.int64Value <= Int64(limit) else { throw DiagramError.invalid("An ATAN2 evidence package exceeds the 16 MiB limit.") }
            let data = try Data(contentsOf:url)
            guard !data.isEmpty,data.count <= limit else { throw DiagramError.invalid("An ATAN2 evidence package grew past its limit.") };return data
        }
        let native = try boundedData(saved.nativeURL),publicPackage = try boundedData(saved.publicURL),nodes = saved.diagram.page.nodes
        guard saved.parts.count <= 128,saved.parts.keys.allSatisfy({$0.utf8.count <= 1024}),nodes.count <= 16,nodes.allSatisfy({$0.text.utf8.count <= 4096}) else { throw DiagramError.invalid("ATAN2 evidence exceeds its inventory limit.") }
        func artifact(_ path:String,_ bytes:Data) -> [String:Any] { ["path":path,"byte_count":bytes.count,"sha256":SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()] }
        let manifest:[String:Any] = ["schema":"macvisio.m3.atan2-save.v1","suite":"M3Atan2Tests","test":testName,"scenario":scenario,
            "state":"native-and-stripped-public-files-captured-after-assertions","captured_utc":ISO8601DateFormatter().string(from:Date()),
            "claim":"Actual local test outputs only. Consult XCTest assertions; no exact-build Visio acceptance claim.",
            "native":artifact("native.vsdx",native),"public_package":artifact("public.vsdx",publicPackage),
            "public_parts":saved.parts.keys.sorted(),"public_page_count":saved.diagram.pages.count,"public_shape_ids":nodes.compactMap{$0.formatting.sourceShapeID},"public_cached_text":nodes.map(\.text)]
        let encoded = try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])
        guard encoded.count <= 64*1024 else { throw DiagramError.invalid("An ATAN2 evidence manifest exceeds 64 KiB.") }
        let directory = URL(fileURLWithPath:path,isDirectory:true).appendingPathComponent("M3Atan2Tests",isDirectory:true)
            .appendingPathComponent(String(testName.dropLast(2)),isDirectory:true).appendingPathComponent(scenario,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath:manifestURL.path) { try FileManager.default.removeItem(at:manifestURL) }
        try native.write(to:directory.appendingPathComponent("native.vsdx"),options:.atomic)
        try publicPackage.write(to:directory.appendingPathComponent("public.vsdx"),options:.atomic)
        try encoded.write(to:manifestURL,options:.atomic)
    }
}
