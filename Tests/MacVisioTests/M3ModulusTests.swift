import Foundation
import CryptoKit
import XCTest
@testable import MacVisio

/// Bounded local MODULUS engineering against primary specification contracts.
/// Expected values below do not call the production remainder helper.
final class M3ModulusTests: XCTestCase {
    private func scalar(_ formula:String) throws -> Double {
        try ShapeSheet.evaluate(formula) { _ in throw DiagramError.invalid("Unexpected reference") }
    }
    private func typed(_ formula:String,scalar:Bool = false) throws -> SheetValue {
        try TypedShapeSheet.evaluate(formula,resolve:{_ in throw DiagramError.invalid("Unexpected reference")},call:{_,_ in throw DiagramError.invalid("Unexpected function")},scalar:scalar)
    }
    private func values(_ expression:ShapeSheet.Expression) throws -> [Double] {
        [try ShapeSheet.evaluate(expression,resolve:{_ in throw DiagramError.invalid("Unexpected reference")}),
         try TypedShapeSheet.evaluate(expression,resolve:{_ in .number(0)},call:{_,_ in .number(0)}).numeric(),
         try TypedShapeSheet.evaluate(expression,resolve:{_ in .number(0)},call:{_,_ in .number(0)},scalar:true).numeric()]
    }
    private func values(_ formula:String) throws -> [Double] { try values(ShapeSheet.parse(formula)) }
    private func rejects(_ expression:ShapeSheet.Expression,file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertThrowsError(try ShapeSheet.evaluate(expression,resolve:{_ in 0}),file:file,line:line)
        for mode in [false,true] {
            XCTAssertThrowsError(try TypedShapeSheet.evaluate(expression,resolve:{_ in .number(0)},call:{_,_ in .number(0)},scalar:mode),file:file,line:line)
        }
    }
    private func rejects(_ formula:String,file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertThrowsError(try scalar(formula),formula,file:file,line:line)
        for mode in [false,true] { XCTAssertThrowsError(try typed(formula,scalar:mode),formula,file:file,line:line) }
    }
    private func modulus(_ number:Double,_ divisor:Double) -> ShapeSheet.Expression { .call("MODULUS",[.number(number),.number(divisor)]) }

    func testPublishedDecimalExamplesKeepTheDivisorSignWithoutFloatNarrowing() throws {
        for (formula,expected) in [("MODULUS(5,1.4)",0.8),("MODULUS(5,-1.4)",-0.6),
                                   ("MODULUS(-5,1.4)",0.6),("MODULUS(-5,-1.4)",-0.8)] {
            for value in try values(formula) { XCTAssertEqual(value,expected,accuracy:1e-12,formula) }
        }
    }

    func testLargeIntegerRemaindersDoNotLoseTheirLowBitsToAQuotientProduct() throws {
        // These integers have exact independent remainders modulo three.
        for (number,divisor,expected) in [(10000000000000000.0,3.0,1.0),(9007199254740994,3,1),
                                          (10000000000000000,-3,-2),(-10000000000000000,3,2),(-10000000000000000,-3,-1)] {
            for value in try values(modulus(number,divisor)) { XCTAssertEqual(value,expected) }
        }
    }

    func testFiniteGreatestMagnitudeUsesNoOverflowingQuotient() throws {
        // greatestFiniteMagnitude = 2^1024 - 2^971, whose remainder modulo 3 is 2.
        let large = Double.greatestFiniteMagnitude
        for (number,divisor,expected) in [(large,3.0,2.0),(-large,3,1),(large,-3,-1),(-large,-3,-2)] {
            for value in try values(modulus(number,divisor)) { XCTAssertTrue(value.isFinite);XCTAssertEqual(value,expected) }
        }
        for divisor in [Double(Float.leastNonzeroMagnitude),-Double(Float.leastNonzeroMagnitude)] {
            for number in [large,-large] { for value in try values(modulus(number,divisor)) { XCTAssertEqual(value,0) } }
        }
    }

    func testBothSidesOfAnExactMultipleRemainDistinctWithoutBoundarySnapping() throws {
        let cases:[(Double,Double,Double)] = [(1.0.nextDown,1,0.9999999999999999),(1,1,0),(1.0.nextUp,1,2.220446049250313e-16),
            ((-1.0).nextUp,1,1.1102230246251565e-16),((-1.0).nextDown,1,0.9999999999999998),
            ((-1.0).nextUp,-1,-0.9999999999999999),(-1,-1,0),((-1.0).nextDown,-1,-2.220446049250313e-16),
            (1.0.nextDown,-1,-1.1102230246251565e-16),(1.0.nextUp,-1,-0.9999999999999998)]
        for (number,divisor,expected) in cases { for value in try values(modulus(number,divisor)) { XCTAssertEqual(value,expected) } }
    }

    func testTinySameSignRemaindersRemainNonzeroAndExactMultiplesKeepPositiveZero() throws {
        let tiny = Double.leastNonzeroMagnitude
        for (number,divisor) in [(tiny,1.0),(-tiny,-1.0)] {
            for value in try values(modulus(number,divisor)) { XCTAssertEqual(value,number);XCTAssertNotEqual(value,0) }
        }
        for number in [0.0,-0.0,6,-6] { for divisor in [3.0,-3.0] {
            for value in try values(modulus(number,divisor)) { XCTAssertEqual(value,0);XCTAssertEqual(value.sign,.plus) }
        } }
    }

    func testVFloatRangeIncludesSubnormalsAndDoubleValuesBetweenFloatRepresentations() throws {
        let lower = Double(Float.leastNonzeroMagnitude),upper = Double(Float.greatestFiniteMagnitude)
        for divisor in [lower,lower.nextUp,upper.nextDown,upper] {
            for sign in [1.0,-1.0] {
                let number = sign*divisor/2
                for value in try values(modulus(number,sign*divisor)) { XCTAssertEqual(value,number) }
            }
        }
    }

    func testVFloatRangeAndZeroDivisorErrorsApplyBeforeRemainderEvaluation() throws {
        let lower = Double(Float.leastNonzeroMagnitude),upper = Double(Float.greatestFiniteMagnitude)
        for divisor in [lower.nextDown,upper.nextUp,1e-50,1e39] {
            for sign in [1.0,-1.0] { rejects(modulus(0,sign*divisor));rejects(modulus(5,sign*divisor)) }
        }
        for divisor in [0.0,-0.0] { rejects(modulus(5,divisor)) }
        for value in try values("IFERROR(MODULUS(5,0),17)") { XCTAssertEqual(value,17) }
    }

    func testUnrepresentableOppositeSignCorrectionRefusesInsteadOfReturningTheDivisor() throws {
        for (number,divisor) in [(-1e-308,1.0),(1e-308,-1.0),(-1.0,Double(Float.greatestFiniteMagnitude))] {
            rejects(modulus(number,divisor))
        }
        for value in try values("IFERROR(MODULUS(-1e-308,1),19)") { XCTAssertEqual(value,19) }
    }

    func testNonfiniteOperandsArityAndUnsupportedCoercionsRemainErrors() {
        for number in [Double.infinity,-Double.infinity,Double.nan] { rejects(modulus(number,2));rejects(modulus(2,number)) }
        for formula in ["MODULUS()","MODULUS(1)","MODULUS(1,2,3)","MODULUS(1,)","MODULUS(\"bad\",2)","MODULUS(1,\"2in\")","MODULUS(1furlong,2)"] { rejects(formula) }
        let call:(String,[SheetValue])throws->SheetValue = {_,_ in .number(0)}
        for value in [SheetValue.quantity(1,"UNSUPPORTED"),.color(ShapeSheetColor(red:1,green:2,blue:3))] {
            for formula in ["MODULUS(Input,2)","MODULUS(2,Input)"] {
                XCTAssertThrowsError(try TypedShapeSheet.evaluate(formula,resolve:{_ in value},call:call))
            }
        }
    }

    func testTypedFirstUnitIsRetainedWhileNumericOperandsUseCanonicalInternalValues() throws {
        for (formula,expected,unit) in [("MODULUS(26mm,1)",0.6/25.4,"MM"),("MODULUS(5mm,2mm)",1/25.4,"MM"),
                                        ("MODULUS(5in,2in)",1,"IN"),("MODULUS(5rad,2rad)",1,"RAD")] {
            let result = try typed(formula)
            XCTAssertEqual(result.unit,unit);XCTAssertEqual(try result.numeric(),expected,accuracy:1e-14)
            XCTAssertEqual(try scalar(formula),expected,accuracy:1e-14)
            let scalarResult = try typed(formula,scalar:true);XCTAssertNil(scalarResult.unit);XCTAssertEqual(try scalarResult.numeric(),expected,accuracy:1e-14)
        }
        // The divisor's unit does not replace or create the result's unit.
        XCTAssertEqual(try typed("MODULUS(5,2in)"),.number(1))
        // vFloat range validation applies to its internal Value, not display digits.
        XCTAssertEqual(try typed("MODULUS(0.25in,1e39mm)"),.quantity(0.25,"IN"))
    }

    func testExistingTypedNumericCoercionsDoNotExpandToUnitBearingStrings() throws {
        XCTAssertThrowsError(try scalar("MODULUS(\"5\",2)"))
        XCTAssertEqual(try typed("MODULUS(\"5\",\"2\")"),.number(1))
        for value in try values("MODULUS(TRUE,2)") { XCTAssertEqual(value,1) }
        let date = ShapeSheet.Expression.call("MODULUS",[.reference("Day"),.number(2)])
        XCTAssertEqual(try TypedShapeSheet.evaluate(date,resolve:{_ in .date(Date(timeIntervalSince1970:0))},call:{_,_ in .number(0)}),.number(1))
        XCTAssertThrowsError(try typed("MODULUS(\"5in\",2)"))
    }

    func testComputedQuantitiesAndTypedFieldFormattingKeepTheFirstUnit() throws {
        let value = try typed("MODULUS(13mm*2,1)")
        XCTAssertEqual(value.unit,"MM");XCTAssertEqual(try value.numeric(),0.6/25.4,accuracy:1e-14)
        XCTAssertEqual(try FieldFormatting.format(value,picture:"esc(7)",type:2),"0.60 mm")
        var diagram = Diagram();var node = DiagramNode(text:"")
        node = try TextFieldEngine.inserting(formula:"MODULUS(13mm*2,1)",picture:"esc(7)",type:2,into:node);diagram.page.nodes = [node]
        let result = TextFieldEngine.recalculate(diagram)
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined());XCTAssertEqual(result.diagram.page.nodes[0].text,"0.60 mm")
        let saved = try publicSave(result.diagram),reopened = saved.diagram,recalculated = TextFieldEngine.recalculate(reopened)
        XCTAssertTrue(recalculated.issues.isEmpty,recalculated.issues.joined());XCTAssertEqual(recalculated.diagram.page.nodes[0].text,"0.60 mm")
        XCTAssertEqual(recalculated.diagram.page.nodes[0].formatting.textFields?.first?.cells["Value"]?.formula,"MODULUS(13mm*2,1)")
        try retainEvidenceIfRequested(saved,testName:#function,formula:"MODULUS(13mm*2,1)")
    }

    func testShapeAndPageHostsShareNumericEvaluationAndFirstUnitMetadata() throws {
        var page = DiagramPage();var node = DiagramNode(text:"")
        let cells = ["User.Source":ShapeSheetCell(value:"5",unit:"MM"),"User.Divisor":ShapeSheetCell(value:"2",unit:"IN"),
                     "User.Result":ShapeSheetCell(value:"9",formula:"MODULUS(User.Source,User.Divisor)",unit:"MM"),
                     "User.Bad":ShapeSheetCell(value:"9",formula:"MODULUS(User.Source,1e39)",unit:"MM")]
        node.formatting.sheet = cells;page.nodes = [node];page.sheet = cells
        let scalar = ShapeSheetContext(page:page,mode:.scalarGeometry),field = ShapeSheetContext(page:page,mode:.typedFields)
        for address in ["User.Result","ThePage!User.Result"] {
            XCTAssertEqual(try scalar.value(node.id,address),.number(1));XCTAssertEqual(try field.value(node.id,address),.quantity(1,"MM"))
        }
        for address in ["User.Bad","ThePage!User.Bad"] { XCTAssertThrowsError(try scalar.value(node.id,address));XCTAssertThrowsError(try field.value(node.id,address)) }
    }

    func testInvalidModulusKeepsGeometryAndTypedFieldCachesAndSourceDefinitions() throws {
        for formula in ["MODULUS(3,0)","MODULUS(3,1e39)","MODULUS(3,1e-50)","MODULUS(-1e-308,1)","MODULUS(EXP(1000),2)"] {
            var diagram = Diagram();var node = DiagramNode(x:100,y:100,text:"Kept");node.width = 144;node.formatting.sourceShapeID = "9"
            let width = ShapeSheetCell(value:"2",formula:formula,unit:"IN"),field = ShapeSheetCell(value:"2",formula:formula,unit:"MM")
            node.formatting.sheet["Width"] = width
            node.formatting.textFields = [ShapeTextField(index:0,cells:["Value":field,"Type":ShapeSheetCell(value:"2")],cached:"Kept")]
            node.formatting.textRuns = [ShapeTextRun(text:"Kept",character:ShapeCharacterStyle(node:node),paragraph:ShapeParagraphStyle(),fieldIndex:0,fieldToken:UUID())]
            diagram.page.nodes = [node]
            let imported = try publicSave(diagram).diagram,calculated = DiagramCalculation.recalculate(imported)
            XCTAssertFalse(calculated.issues.isEmpty)
            let kept = try XCTUnwrap(calculated.diagram.page.nodes.first)
            XCTAssertEqual(kept.width,144,accuracy:1e-10);XCTAssertEqual(kept.text,"Kept")
            XCTAssertEqual(kept.formatting.sheet["Width"],width);XCTAssertEqual(kept.formatting.textFields?.first?.cells["Value"],field)
            let saved = try publicSave(calculated.diagram)
            XCTAssertEqual(saved.diagram.page.nodes.first?.text,"Kept")
            let xml = try VisioXML.document(XCTUnwrap(saved.parts["visio/pages/page1.xml"]))
            let shape = try XCTUnwrap(xml.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "9" })
            let publicWidth = try XCTUnwrap(shape.elementsLocal("Cell").first { $0.attr("N") == "Width" })
            XCTAssertEqual(publicWidth.attr("F"),formula);XCTAssertEqual(publicWidth.attr("V"),"2");XCTAssertEqual(publicWidth.attr("U"),"IN")
            let section = try XCTUnwrap(shape.elementsLocal("Section").first { $0.attr("N") == "Field" })
            let publicField = try XCTUnwrap(section.elementsLocal("Row").first { $0.attr("IX") == "0" }?.elementsLocal("Cell").first { $0.attr("N") == "Value" })
            XCTAssertEqual(publicField.attr("F"),formula);XCTAssertEqual(publicField.attr("V"),"2");XCTAssertEqual(publicField.attr("U"),"MM")
            try retainEvidenceIfRequested(saved,testName:#function,formula:formula)
        }
    }

    private func file() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-Modulus-\(UUID()).vsdx")
        addTeardownBlock { try? FileManager.default.removeItem(at:url) };return url
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
        XCTAssertFalse(parts.keys.contains { $0.hasPrefix("macvisio/") })
        let output = file();try VisioPackage.write(parts,to:output)
        return (try VisioFormat.read(from:output).diagram,parts,native,output)
    }

    /// An explicit absolute M3_EVIDENCE_DIR retains at most six fixed pairs,
    /// each bounded to two 16 MiB packages and a 64 KiB manifest. Capture runs
    /// after the existing assertions; their XCTest log remains authoritative.
    private func retainEvidenceIfRequested(_ saved:SavedDrawing,testName:String,formula:String) throws {
        guard let path = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"],!path.isEmpty else { return }
        let allowed:[String:[String:String]] = [
            "testComputedQuantitiesAndTypedFieldFormattingKeepTheFirstUnit()": ["MODULUS(13mm*2,1)":"computed-field"],
            "testInvalidModulusKeepsGeometryAndTypedFieldCachesAndSourceDefinitions()": [
                "MODULUS(3,0)":"zero-divisor","MODULUS(3,1e39)":"divisor-above-range",
                "MODULUS(3,1e-50)":"divisor-below-range","MODULUS(-1e-308,1)":"unrepresentable-correction",
                "MODULUS(EXP(1000),2)":"nonfinite-operand"]
        ]
        guard (path as NSString).isAbsolutePath,let scenario = allowed[testName]?[formula] else {
            throw DiagramError.invalid("MODULUS evidence requires an absolute M3_EVIDENCE_DIR and a known save test/scenario.")
        }
        let limit = 16*1024*1024
        func boundedData(_ url:URL) throws -> Data {
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard let bytes = attributes[.size] as? NSNumber,bytes.int64Value > 0,bytes.int64Value <= Int64(limit) else {
                throw DiagramError.invalid("A MODULUS evidence package exceeds the 16 MiB retention limit.")
            }
            let data = try Data(contentsOf:url)
            guard !data.isEmpty,data.count <= limit else { throw DiagramError.invalid("MODULUS evidence grew past its package limit.") }
            return data
        }
        let native = try boundedData(saved.nativeURL),publicPackage = try boundedData(saved.publicURL)
        let nodes = saved.diagram.page.nodes
        guard saved.parts.count <= 128,saved.parts.keys.allSatisfy({$0.utf8.count <= 1024}),nodes.count <= 16,
              nodes.allSatisfy({$0.text.utf8.count <= 4096}) else {
            throw DiagramError.invalid("MODULUS evidence exceeds its manifest inventory limit.")
        }
        func artifact(_ name:String,_ data:Data) -> [String:Any] {
            ["path":name,"byte_count":data.count,"sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()]
        }
        let manifest:[String:Any] = [
            "schema":"macvisio.m3.modulus-save.v1","suite":"M3ModulusTests","test":testName,"scenario":scenario,"formula":formula,
            "state":"native-and-stripped-public-files-captured-after-assertions",
            "captured_utc":ISO8601DateFormatter().string(from:Date()),
            "claim":"Actual local test outputs only. Consult the XCTest log for assertions; no exact-build Visio acceptance claim.",
            "native":artifact("native.vsdx",native),"public_package":artifact("public.vsdx",publicPackage),
            "public_parts":saved.parts.keys.sorted(),"public_page_count":saved.diagram.pages.count,
            "public_shape_ids":nodes.compactMap{$0.formatting.sourceShapeID},"public_cached_text":nodes.map(\.text)]
        let encoded = try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])
        guard encoded.count <= 64*1024 else { throw DiagramError.invalid("A MODULUS evidence manifest exceeds the 64 KiB retention limit.") }
        let directory = URL(fileURLWithPath:path,isDirectory:true).appendingPathComponent("M3ModulusTests",isDirectory:true)
            .appendingPathComponent(String(testName.dropLast(2)),isDirectory:true).appendingPathComponent(scenario,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        // Fixed names bound repeated runs. Publish the new manifest last, so
        // an interrupted overwrite cannot retain a manifest for mixed bytes.
        if FileManager.default.fileExists(atPath:manifestURL.path) { try FileManager.default.removeItem(at:manifestURL) }
        try native.write(to:directory.appendingPathComponent("native.vsdx"),options:.atomic)
        try publicPackage.write(to:directory.appendingPathComponent("public.vsdx"),options:.atomic)
        try encoded.write(to:manifestURL,options:.atomic)
    }
}
