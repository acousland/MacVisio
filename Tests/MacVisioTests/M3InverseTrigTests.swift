import Foundation
import CryptoKit
import XCTest
@testable import MacVisio

/// Local PtgAngDft result typing for ASIN/ACOS/ATAN. Expected values use
/// independent geometric constants and endpoint expansions, not production helpers.
final class M3InverseTrigTests: XCTestCase {
    private let names = ["ASIN","ACOS","ATAN"]
    private func scalar(_ formula:String) throws -> Double { try ShapeSheet.evaluate(formula){_ in throw DiagramError.invalid("Unexpected reference")} }
    private func typed(_ formula:String,scalar:Bool = false) throws -> SheetValue {
        try TypedShapeSheet.evaluate(formula,resolve:{_ in throw DiagramError.invalid("Unexpected reference")},call:{_,_ in throw DiagramError.invalid("Unexpected function")},scalar:scalar)
    }
    private func expression(_ name:String,_ value:Double) -> ShapeSheet.Expression { .call(name,[.number(value)]) }
    private func values(_ expression:ShapeSheet.Expression) throws -> [Double] {
        [try ShapeSheet.evaluate(expression,resolve:{_ in 0}),
         try TypedShapeSheet.evaluate(expression,resolve:{_ in .number(0)},call:{_,_ in .number(0)}).numeric(),
         try TypedShapeSheet.evaluate(expression,resolve:{_ in .number(0)},call:{_,_ in .number(0)},scalar:true).numeric()]
    }
    private func assertValue(_ name:String,_ input:Double,_ expected:Double,accuracy:Double = 1e-14,file:StaticString = #filePath,line:UInt = #line) throws {
        for value in try values(expression(name,input)) { XCTAssertEqual(value,expected,accuracy:accuracy,file:file,line:line);XCTAssertTrue(value.isFinite,file:file,line:line) }
    }
    private func rejects(_ expression:ShapeSheet.Expression,file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertThrowsError(try ShapeSheet.evaluate(expression,resolve:{_ in 0}),file:file,line:line)
        for mode in [false,true] { XCTAssertThrowsError(try TypedShapeSheet.evaluate(expression,resolve:{_ in .number(0)},call:{_,_ in .number(0)},scalar:mode),file:file,line:line) }
    }

    func testGeometricValuesAndUnambiguousReferenceExamples() throws {
        for (name,input,expected) in [("ASIN",0.5,Double.pi/6),("ASIN",-0.5,-Double.pi/6),
                                      ("ACOS",0.5,Double.pi/3),("ACOS",-0.5,2*Double.pi/3),
                                      ("ATAN",1.0,Double.pi/4),("ATAN",-1.0,-Double.pi/4)] { try assertValue(name,input,expected) }
        // DEG retypes without scaling (EXPR-48).
        XCTAssertEqual(try scalar("DEG(ASIN(1))"),Double.pi/2,accuracy:1e-12)
        XCTAssertEqual(try scalar("DEG(ACOS(0))"),Double.pi/2,accuracy:1e-12)
        XCTAssertEqual(try scalar("DEG(ATAN(1))"),Double.pi/4,accuracy:1e-12)
    }

    func testPrincipalRangesAndInclusiveAsinAcosEndpoints() throws {
        for input in [-1.0,-0.5,0,0.5,1] {
            for value in try values(expression("ASIN",input)) { XCTAssertGreaterThanOrEqual(value,-Double.pi/2);XCTAssertLessThanOrEqual(value,Double.pi/2) }
            for value in try values(expression("ACOS",input)) { XCTAssertGreaterThanOrEqual(value,0);XCTAssertLessThanOrEqual(value,Double.pi) }
        }
        try assertValue("ASIN",-1,-Double.pi/2,accuracy:0);try assertValue("ASIN",1,Double.pi/2,accuracy:0)
        try assertValue("ACOS",-1,Double.pi,accuracy:0);try assertValue("ACOS",1,0,accuracy:0)
        for input in [-1e200,-1.0,0,1,1e200] { for value in try values(expression("ATAN",input)) {
            XCTAssertGreaterThanOrEqual(value,-Double.pi/2);XCTAssertLessThanOrEqual(value,Double.pi/2)
        } }
    }

    func testSignedZeroAndTinyValuesArePreservedWithoutTolerance() throws {
        for name in ["ASIN","ATAN"] {
            for zero in [0.0,-0.0] { for value in try values(expression(name,zero)) { XCTAssertEqual(value,0);XCTAssertEqual(value.sign,zero.sign) } }
            for tiny in [Double.leastNonzeroMagnitude,-Double.leastNonzeroMagnitude,Double.leastNormalMagnitude,-Double.leastNormalMagnitude] {
                try assertValue(name,tiny,tiny,accuracy:0)
            }
        }
        for zero in [0.0,-0.0] { try assertValue("ACOS",zero,Double.pi/2,accuracy:0) }
        for tiny in [Double.leastNormalMagnitude,-Double.leastNormalMagnitude] { try assertValue("ACOS",tiny,Double.pi/2,accuracy:0) }
        for value in try values(expression("ACOS",1)) { XCTAssertEqual(value.sign,.plus) }
    }

    func testAdjacentInsideDomainValuesDoNotSnapToEndpoints() throws {
        // For delta=2^-53, acos(1-delta)=sqrt(2*delta)*(1+delta/12+...).
        // An independent Decimal expansion produced these rounded constants.
        try assertValue("ACOS",(1.0).nextDown,1.49011611938476563878634354255e-8,accuracy:1e-23)
        try assertValue("ACOS",(-1.0).nextUp,3.141592638688632044614986995416,accuracy:1e-15)
        try assertValue("ASIN",(1.0).nextDown,1.570796311893735425383665303776,accuracy:1e-15)
        try assertValue("ASIN",(-1.0).nextUp,-1.570796311893735425383665303776,accuracy:1e-15)
        for value in try values(expression("ASIN",(1.0).nextDown)) { XCTAssertLessThan(value,Double.pi/2) }
        for value in try values(expression("ACOS",(1.0).nextDown)) { XCTAssertGreaterThan(value,0) }
    }

    func testAdjacentOutsideDomainInputsRemainErrorsWithoutClamping() {
        for name in ["ASIN","ACOS"] {
            for value in [(1.0).nextUp,(-1.0).nextDown,Double.greatestFiniteMagnitude,-Double.greatestFiniteMagnitude] { rejects(expression(name,value)) }
        }
    }

    func testAtanFiniteExtremesMayRoundToARepresentableRangeEndpoint() throws {
        // Finite mathematical arctangents approach +/-pi/2; binary64 can round
        // the nearest result to that endpoint. No artificial inset is applied.
        try assertValue("ATAN",Double.greatestFiniteMagnitude,Double.pi/2,accuracy:0)
        try assertValue("ATAN",-Double.greatestFiniteMagnitude,-Double.pi/2,accuracy:0)
        try assertValue("ATAN",0.5,0.4636476090008061)
        try assertValue("ATAN",2,1.1071487177940904)
    }

    func testNonfiniteInputsArityAndLazyFallbackKeepGenericErrorBehavior() throws {
        let invalidArguments:[[ShapeSheet.Expression]] = [[],[.number(0),.number(1)]]
        for name in names {
            for input in [Double.infinity,-Double.infinity,Double.nan] { rejects(expression(name,input)) }
            for arguments in invalidArguments { rejects(.call(name,arguments)) }
            for formula in ["\(name)(1,)","\(name)(EXP(1000))","\(name)(1/0)"] { XCTAssertThrowsError(try scalar(formula));XCTAssertThrowsError(try typed(formula)) }
            XCTAssertEqual(try scalar("IFERROR(\(name)(),17)"),17)
            XCTAssertEqual(try typed("IFERROR(\(name)(),17)"),.number(17))
        }
        XCTAssertEqual(try scalar("IFERROR(ASIN(2),19)"),19);XCTAssertEqual(try typed("IFERROR(ACOS(-2),19)"),.number(19))
    }

    func testTypedResultsCarryDaAndComposeWithKnownAngleQuantities() throws {
        for (formula,expected) in [("ASIN(0.5)",Double.pi/6),("ACOS(0.5)",Double.pi/3),("ATAN(1)",Double.pi/4)] {
            let value = try typed(formula);XCTAssertEqual(value.unit,"DA");XCTAssertEqual(value.dimension,"angle")
            XCTAssertEqual(try value.numeric(),expected,accuracy:1e-14)
            let scalarResult = try typed(formula,scalar:true);XCTAssertNil(scalarResult.unit);XCTAssertEqual(try scalarResult.numeric(),expected,accuracy:1e-14)
            let sum = try typed(formula+"+30deg");XCTAssertEqual(sum.unit,"DA");XCTAssertEqual(try sum.numeric(),expected+Double.pi/6,accuracy:1e-14)
            XCTAssertEqual(try typed(formula+"+1").numeric(),expected+1,accuracy:1e-14)  // EXPR-36
        }
        XCTAssertEqual(try typed("ASIN(0.5)/30deg").numeric(),1,accuracy:1e-14)
        XCTAssertEqual(try FieldFormatting.format(typed("ACOS(0.5)"),picture:"esc(7)",unit:"DEG",type:2),"60.00 deg")
    }

    func testCanonicalUnitInputsDoNotDonateTheirUnitsToTheResult() throws {
        for (formula,expected) in [("ASIN(12.7mm)",Double.pi/6),("ACOS(36pt)",Double.pi/3),("ATAN(25.4mm)",Double.pi/4),
                                   ("ASIN(0.5rad)",Double.pi/6),("ATAN(13mm*2)",0.7970707849875946)] {
            // The computed 26mm input has canonical value 130/127; its
            // independent arctangent is 0.7970707849875946 radians.
            let result = try typed(formula);XCTAssertEqual(result.unit,"DA")
            XCTAssertEqual(try result.numeric(),expected,accuracy:1e-14);XCTAssertEqual(try scalar(formula),expected,accuracy:1e-14)
        }
    }

    func testExistingCoercionsAndUnsupportedFormsRemainExplicit() throws {
        for (name,halfAngle,trueAngle) in [("ASIN",Double.pi/6,Double.pi/2),("ACOS",Double.pi/3,0),("ATAN",0.4636476090008061,Double.pi/4)] {
            let text = try typed("\(name)(\"0.5\")");XCTAssertEqual(text.unit,"DA");XCTAssertEqual(try text.numeric(),halfAngle,accuracy:1e-14)
            XCTAssertEqual(try typed("\(name)(TRUE)").numeric(),trueAngle,accuracy:1e-14)
            XCTAssertThrowsError(try scalar("\(name)(\"0.5\")"))
            let date = SheetValue.date(serial:0)
            let value = try TypedShapeSheet.evaluate(.call(name,[.reference("Day")]),resolve:{_ in .date(date)},call:{_,_ in .number(0)})
            XCTAssertEqual(value.unit,"DA");XCTAssertEqual(try value.numeric(),name == "ACOS" ? Double.pi/2 : 0,accuracy:1e-14)
            for formula in ["\(name)(\"0.5in\")","\(name)(\"TRUE\")","\(name)(\"bad\")","\(name)(1furlong)"] { XCTAssertThrowsError(try typed(formula));XCTAssertThrowsError(try scalar(formula)) }
            for supplied in [SheetValue.quantity(0.5,"UNSUPPORTED"),.color(ShapeSheetColor(red:1,green:2,blue:3))] {
                XCTAssertThrowsError(try TypedShapeSheet.evaluate("\(name)(Input)",resolve:{_ in supplied},call:{_,_ in .number(0)}))
            }
        }
    }

    func testInverseResultsComposeWithAtan2AndLeaveForwardTrigNumeric() throws {
        let sum = try typed("ASIN(0.5)+ATAN2(1,1)")
        XCTAssertEqual(sum.unit,"DA");XCTAssertEqual(try sum.numeric(),5*Double.pi/12,accuracy:1e-14)
        for (formula,expected) in [("SIN(ASIN(0.5))",0.5),("COS(ACOS(0.5))",0.5),("TAN(ATAN(1))",1)] {
            let value = try typed(formula);XCTAssertNil(value.unit);XCTAssertEqual(try value.numeric(),expected,accuracy:1e-14)
        }
        let degrees = try typed("DEG(ASIN(0.5))");XCTAssertEqual(degrees.unit,"DEG");XCTAssertEqual(try degrees.numeric(),Double.pi/6,accuracy:1e-12)  // EXPR-48
    }

    func testShapePageAndDocumentHostsShareDaAndRefuseInvalidFormulaCaches() throws {
        for (name,source,expected,bad) in [("ASIN",0.5,Double.pi/6,"ASIN(2)"),("ACOS",0.5,Double.pi/3,"ACOS(-2)"),("ATAN",1.0,Double.pi/4,"ATAN()")] {
            var drawing = Diagram(),node = DiagramNode(text:"")
            let scope = UUID(),sheetID = DefinitionRegistry.stableID(scope,"sheet:TheDoc")
            var sheet = DefinitionSheet(id:sheetID,publicID:"TheDoc",parentID:nil,attributes:[:],cells:[],rows:[],text:nil)
            sheet.set(DefinitionCellAddress(cell:"Value",section:"User",rowName:"Source"),to:ShapeSheetCell(value:String(source),unit:"MM"))
            sheet.set(DefinitionCellAddress(cell:"Value",section:"User",rowName:"Direction"),to:ShapeSheetCell(value:"9",formula:"\(name)(User.Source)",unit:"DA"))
            sheet.set(DefinitionCellAddress(cell:"Value",section:"User",rowName:"Bad"),to:ShapeSheetCell(value:"0.25",formula:bad,unit:"DA"))
            drawing.definitions = DefinitionRegistry(sourceDocumentID:scope,documentPart:"visio/document.xml",documentSheet:sheet,masters:[],styles:[],uses:[])
            drawing.page.sheet = ["User.Direction":ShapeSheetCell(value:"9",formula:"TheDoc!User.Direction",unit:"DA"),"User.Bad":ShapeSheetCell(value:"0.25",formula:"TheDoc!User.Bad",unit:"DA")]
            node.formatting.sheet = ["User.Direction":ShapeSheetCell(value:"9",formula:"ThePage!User.Direction",unit:"DA"),"User.Bad":ShapeSheetCell(value:"0.25",formula:"ThePage!User.Bad",unit:"DA")];drawing.page.nodes = [node]
            for mode in [ShapeSheetContext.ValueMode.scalarGeometry,.typedFields] {
                let context = ShapeSheetContext(page:drawing.page,document:drawing,mode:mode)
                for prefix in ["","ThePage!","TheDoc!"] {
                    let result = try context.value(node.id,prefix+"User.Direction")
                    XCTAssertEqual(result.unit,mode == .typedFields ? "DA" : nil);XCTAssertEqual(try result.numeric(),expected,accuracy:1e-14)
                    XCTAssertThrowsError(try context.value(node.id,prefix+"User.Bad"))
                }
            }
            XCTAssertEqual(drawing.definitions?.documentSheet?.cell(DefinitionCellAddress(cell:"Value",section:"User",rowName:"Bad"))?.value,"0.25")
        }
    }

    func testExplicitDaDegreeAndUnitlessCallerUnitsSurviveActualPublicSave() throws {
        // Angles display in degrees without a trailing period (FORMATESC-ang, FIELD-ang).
        let cases = [("ASIN(0.5)",Double.pi/6,"30.00","30.00 deg"),("ACOS(0.5)",Double.pi/3,"60.00","60.00 deg"),("ATAN(1)",Double.pi/4,"45.00","45.00 deg")]
        var drawing = Diagram();drawing.page.nodes = []
        for (group,item) in cases.enumerated() { for (offset,unit) in ["DA","DEG",""].enumerated() {
            var node = try TextFieldEngine.inserting(formula:item.0,picture:unit == "DEG" ? "esc(7)" : "0.00",type:2,into:DiagramNode(x:Double(100+offset*180),y:Double(100+group*160),text:""))
            node.formatting.sourceShapeID = String((group+1)*10+offset);node.formatting.textFields?[0].cells["Value"]?.unit = unit
            if offset == 0 { node.formatting.sheet["Angle"] = ShapeSheetCell(value:"0",formula:item.0,unit:"DA") }
            drawing.page.nodes.append(node)
        } }
        let result = DiagramCalculation.recalculate(drawing);XCTAssertTrue(result.issues.isEmpty,result.issues.joined())
        let saved = try publicSave(result.diagram),native = try VisioFormat.read(from:saved.nativeURL).diagram,publicResult = DiagramCalculation.recalculate(saved.diagram)
        XCTAssertTrue(publicResult.issues.isEmpty,publicResult.issues.joined())
        for (group,item) in cases.enumerated() { for (offset,unit) in ["DA","DEG",""].enumerated() {
            let sourceID = String((group+1)*10+offset),source = try XCTUnwrap(result.diagram.page.nodes.first{$0.formatting.sourceShapeID == sourceID})
            let expectedText = unit == "DEG" ? item.3 : item.2
            for diagram in [result.diagram,native,publicResult.diagram] {
                let node = try XCTUnwrap(diagram.page.nodes.first{$0.formatting.sourceShapeID == sourceID})
                XCTAssertEqual(node.text,expectedText);XCTAssertEqual(node.formatting.textFields?.first?.cells["Value"]?.unit,unit)
                if offset == 0 { XCTAssertEqual(node.rotation,-item.1*180/Double.pi,accuracy:1e-8) }
            }
            let shape = try publicShape(saved.parts,id:sourceID),index = try XCTUnwrap(source.formatting.textFields?.first?.index),field = try publicField(shape,index:index)
            XCTAssertEqual(field.attr("F"),item.0);XCTAssertEqual(field.attr("U"),unit.isEmpty ? nil : unit)
            XCTAssertEqual(Double(field.attr("V") ?? "") ?? 0,item.1,accuracy:1e-11)
            if offset == 0 {
                let angle = try XCTUnwrap(shape.elementsLocal("Cell").first{$0.attr("N") == "Angle"})
                XCTAssertEqual(angle.attr("F"),item.0);XCTAssertEqual(angle.attr("U"),"DA");XCTAssertEqual(Double(angle.attr("V") ?? "") ?? 0,item.1,accuracy:1e-11)
            }
        } }
        try retainEvidenceIfRequested(saved,testName:#function,scenario:"explicit-and-unitless-callers")
    }

    func testInvalidInverseTrigKeepsGeometryFieldCachesAndPublicSourceDefinitions() throws {
        for (scenario,formula) in [("asin-domain","ASIN(1.0000000000000002)"),("acos-domain","ACOS(-1.0000000000000002)"),("atan-nonfinite","ATAN(EXP(1000))")] {
            var drawing = Diagram(),node = DiagramNode(x:100,y:100,text:"Kept")
            node.rotation = -14.32394487827058;node.formatting.sourceShapeID = "9"
            let cell = ShapeSheetCell(value:"0.25",formula:formula,unit:"DA");node.formatting.sheet["Angle"] = cell
            node.formatting.textFields = [ShapeTextField(index:0,cells:["Value":cell,"Type":ShapeSheetCell(value:"2")],cached:"Kept")]
            node.formatting.textRuns = [ShapeTextRun(text:"Kept",character:ShapeCharacterStyle(node:node),paragraph:ShapeParagraphStyle(),fieldIndex:0,fieldToken:UUID())];drawing.page.nodes = [node]
            let imported = try publicSave(drawing).diagram,result = DiagramCalculation.recalculate(imported)
            XCTAssertFalse(result.issues.isEmpty)
            let kept = try XCTUnwrap(result.diagram.page.nodes.first)
            XCTAssertEqual(kept.rotation,node.rotation,accuracy:1e-8);XCTAssertEqual(kept.text,"Kept")
            XCTAssertEqual(kept.formatting.sheet["Angle"],cell);XCTAssertEqual(kept.formatting.textFields?.first?.cells["Value"],cell)
            let saved = try publicSave(result.diagram),shape = try publicShape(saved.parts,id:"9")
            XCTAssertEqual(saved.diagram.page.nodes.first?.text,"Kept")
            let recalculated = DiagramCalculation.recalculate(saved.diagram)
            XCTAssertFalse(recalculated.issues.isEmpty);XCTAssertEqual(recalculated.diagram.page.nodes.first?.text,"Kept")
            XCTAssertEqual(recalculated.diagram.page.nodes.first?.formatting.sheet["Angle"],cell)
            XCTAssertEqual(recalculated.diagram.page.nodes.first?.formatting.textFields?.first?.cells["Value"],cell)
            for value in [try XCTUnwrap(shape.elementsLocal("Cell").first{$0.attr("N") == "Angle"}),try publicField(shape,index:0)] {
                XCTAssertEqual(value.attr("F"),formula);XCTAssertEqual(value.attr("V"),"0.25");XCTAssertEqual(value.attr("U"),"DA")
            }
            try retainEvidenceIfRequested(saved,testName:#function,scenario:scenario)
        }
    }

    private func file() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-InverseTrig-\(UUID()).vsdx")
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

    /// An explicit absolute evidence directory retains four fixed artifact pairs.
    /// Each already-emitted package is limited to 16 MiB; manifests to 64 KiB.
    private func retainEvidenceIfRequested(_ saved:SavedDrawing,testName:String,scenario:String) throws {
        guard let path = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"],!path.isEmpty else { return }
        let allowed:[String:Set<String>] = [
            "testExplicitDaDegreeAndUnitlessCallerUnitsSurviveActualPublicSave()":["explicit-and-unitless-callers"],
            "testInvalidInverseTrigKeepsGeometryFieldCachesAndPublicSourceDefinitions()":["asin-domain","acos-domain","atan-nonfinite"]]
        guard (path as NSString).isAbsolutePath,allowed[testName]?.contains(scenario) == true else {
            throw DiagramError.invalid("Inverse-trig evidence requires an absolute M3_EVIDENCE_DIR and a known save scenario.")
        }
        let limit = 16*1024*1024
        func boundedData(_ url:URL) throws -> Data {
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard let bytes = attributes[.size] as? NSNumber,bytes.int64Value > 0,bytes.int64Value <= Int64(limit) else { throw DiagramError.invalid("An inverse-trig evidence package exceeds the 16 MiB limit.") }
            let data = try Data(contentsOf:url)
            guard !data.isEmpty,data.count <= limit else { throw DiagramError.invalid("An inverse-trig evidence package grew past its limit.") };return data
        }
        let native = try boundedData(saved.nativeURL),publicPackage = try boundedData(saved.publicURL),nodes = saved.diagram.page.nodes
        guard saved.parts.count <= 128,saved.parts.keys.allSatisfy({$0.utf8.count <= 1024}),nodes.count <= 16,nodes.allSatisfy({$0.text.utf8.count <= 4096}) else { throw DiagramError.invalid("Inverse-trig evidence exceeds its inventory limit.") }
        func artifact(_ path:String,_ bytes:Data) -> [String:Any] { ["path":path,"byte_count":bytes.count,"sha256":SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()] }
        let manifest:[String:Any] = ["schema":"macvisio.m3.inverse-trig-save.v1","suite":"M3InverseTrigTests","test":testName,"scenario":scenario,
            "state":"native-and-stripped-public-files-captured-after-assertions","captured_utc":ISO8601DateFormatter().string(from:Date()),
            "claim":"Actual local test outputs only. Consult XCTest assertions; no exact-build Visio acceptance claim.",
            "native":artifact("native.vsdx",native),"public_package":artifact("public.vsdx",publicPackage),
            "public_parts":saved.parts.keys.sorted(),"public_page_count":saved.diagram.pages.count,"public_shape_ids":nodes.compactMap{$0.formatting.sourceShapeID},"public_cached_text":nodes.map(\.text)]
        let encoded = try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])
        guard encoded.count <= 64*1024 else { throw DiagramError.invalid("An inverse-trig evidence manifest exceeds 64 KiB.") }
        let directory = URL(fileURLWithPath:path,isDirectory:true).appendingPathComponent("M3InverseTrigTests",isDirectory:true)
            .appendingPathComponent(String(testName.dropLast(2)),isDirectory:true).appendingPathComponent(scenario,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath:manifestURL.path) { try FileManager.default.removeItem(at:manifestURL) }
        try native.write(to:directory.appendingPathComponent("native.vsdx"),options:.atomic)
        try publicPackage.write(to:directory.appendingPathComponent("public.vsdx"),options:.atomic)
        try encoded.write(to:manifestURL,options:.atomic)
    }
}
