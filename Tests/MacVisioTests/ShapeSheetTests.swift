import Foundation
import XCTest
@testable import MacVisio

final class ShapeSheetTests:XCTestCase {
    func testArithmeticUnitsReferencesAndLazyConditionals() throws {
        func value(_ s:String) throws -> Double { try ShapeSheet.evaluate(s) { name in if name == "Width" { return 4 };throw DiagramError.invalid("Unknown cell") } }
        XCTAssertEqual(try value("2 in + 25.4 mm"),3,accuracy:1e-12)
        XCTAssertEqual(try value("Width/2 + 36 pt"),2.5,accuracy:1e-12)
        XCTAssertEqual(try value("IF(Width>3, 7, 1/0)"),7)
        XCTAssertEqual(try value("IFERROR(1/0, 42)"),42)
        XCTAssertEqual(try value("IF(Width!=3,1,0)"),1)
        XCTAssertEqual(try value("MIN(13 in,1 ft,20 cm)"),20/2.54,accuracy:1e-12)
        XCTAssertEqual(try value("DEG(ATAN2(1,1))"),45,accuracy:1e-12)
        XCTAssertEqual(try value("MODULUS(-5,1.4)"),0.6,accuracy:1e-12)
        XCTAssertEqual(try value("ROUND(123.654,-1)"),120)
        XCTAssertEqual(try value("ROUND(123.654,99)"),123.654)
        XCTAssertEqual(try value("50% * 4"),2)
    }
    func testSixteenBitBitwiseFunctionsUseUnsignedUnitlessOperands() throws {
        func value(_ formula:String) throws -> Double {
            try ShapeSheet.evaluate(formula){_ in throw DiagramError.invalid("Unexpected reference")}
        }
        XCTAssertEqual(try value("BITAND(12,6)"),4)
        XCTAssertEqual(try value("BITXOR(12,6)"),10)
        XCTAssertEqual(try value("BITOR(12,6)"),14)
        XCTAssertEqual(try value("BITOR(BITAND(12,6),BITXOR(12,6))"),14)
        XCTAssertEqual(try value("BITAND(0,65535)"),0)
        XCTAssertEqual(try value("BITXOR(65535,65535)"),0)
        XCTAssertEqual(try value("BITOR(0,65535)"),65535)
        XCTAssertEqual(try value("BITAND(65535,65535)"),65535)
        XCTAssertEqual(try value("BITXOR(0,65535)"),65535)

        for function in ["BITAND","BITOR","BITXOR"] {
            for formula in ["\(function)(1)","\(function)(1,2,3)"] {
                XCTAssertThrowsError(try value(formula),formula)
            }
            for operand in ["-1","65536","1.5","1e308","1in"] {
                let formula = "\(function)(\(operand),0)"
                XCTAssertThrowsError(try value(formula),formula)
            }
        }
    }
    func testTypedBitwiseFunctionsRejectUnitsAndNonNumericTypes() throws {
        func typed(_ formula:String,resolve:@escaping (String)throws->SheetValue = {_ in .number(0)}) throws -> SheetValue {
            try TypedShapeSheet.evaluate(formula,resolve:resolve,call:{name,_ in throw DiagramError.invalid("Unexpected function: \(name)")})
        }
        XCTAssertEqual(try typed("BITAND(12,6)"),.number(4))
        XCTAssertEqual(try typed("BITXOR(12,6)"),.number(10))
        XCTAssertEqual(try typed("BITOR(12,6)"),.number(14))
        XCTAssertThrowsError(try typed("BITAND(1in,1)"))
        XCTAssertThrowsError(try typed("BITXOR(Mask,1)",resolve:{_ in .quantity(1,"IN")}))
        XCTAssertThrowsError(try typed("BITOR(Mask,1)",resolve:{_ in .boolean(true)}))
        for formula in ["BITAND(1)","BITXOR(1,2,3)"] {
            XCTAssertThrowsError(try typed(formula),formula)
        }
    }
    func testCeilingAndFloorRoundToSameSignMultiples() throws {
        func value(_ formula:String) throws -> Double { try ShapeSheet.evaluate(formula){_ in throw DiagramError.invalid("Unexpected reference") } }
        XCTAssertEqual(try value("CEILING(3.7)"),4)
        XCTAssertEqual(try value("CEILING(-3.7)"),-4)
        XCTAssertEqual(try value("CEILING(3.7,0.25)"),3.75,accuracy:1e-12)
        XCTAssertEqual(try value("CEILING(-3.7,-0.25)"),-3.75,accuracy:1e-12)
        XCTAssertEqual(try value("FLOOR(3.7)"),3)
        XCTAssertEqual(try value("FLOOR(-3.7)"),-3)
        XCTAssertEqual(try value("FLOOR(3.7,0.5)"),3.5,accuracy:1e-12)
        XCTAssertEqual(try value("FLOOR(-3.7,-0.5)"),-3.5,accuracy:1e-12)
        XCTAssertEqual(try value("CEILING(0,-0.25)"),0)
        XCTAssertEqual(try value("FLOOR(3.7,0)"),0)
        for formula in ["CEILING(3.7,-0.25)","FLOOR(-3.7,0.5)","CEILING(1,2,3)","CEILING(1e308,1e-308)"] { XCTAssertThrowsError(try value(formula),formula) }
    }
    func testSignUsesOptionalFuzzAndDefaultsToOneNanounit() throws {
        func value(_ formula:String) throws -> Double { try ShapeSheet.evaluate(formula){_ in throw DiagramError.invalid("Unexpected reference") } }
        XCTAssertEqual(try value("SIGN(-5)"),-1)
        XCTAssertEqual(try value("SIGN(0)"),0)
        XCTAssertEqual(try value("SIGN(1e-11)"),0)
        XCTAssertEqual(try value("SIGN(-1e-11)"),0)
        XCTAssertEqual(try value("SIGN(1e-9)"),0)
        XCTAssertEqual(try value("SIGN(-1e-9)"),0)
        XCTAssertEqual(try value("SIGN(1e-8)"),1)
        XCTAssertEqual(try value("SIGN(-1e-8)"),-1)
        XCTAssertEqual(try value("SIGN(0.1,0.1)"),0)
        XCTAssertEqual(try value("SIGN(-0.1,0.1)"),0)
        XCTAssertEqual(try value("SIGN(0.1001,0.1)"),1)
        XCTAssertEqual(try value("SIGN(-0.1001,0.1)"),-1)
        XCTAssertEqual(try value("SIGN(1e-11,0)"),1)
        XCTAssertEqual(try value("SIGN(-1e-11,0)"),-1)
        XCTAssertEqual(try value("SIGN(0,0)"),0)
        for formula in ["SIGN()","SIGN(1,0,3)","SIGN(1,-0.1)"] { XCTAssertThrowsError(try value(formula),formula) }
    }
    func testTypedSignReturnsUnitlessValueAndComparesCompatibleMeasures() throws {
        func typed(_ formula:String) throws -> SheetValue { try TypedShapeSheet.evaluate(formula,resolve:{_ in .number(0)},call:{_,_ in .number(0)}) }
        XCTAssertEqual(try typed("SIGN(1e-11)"),.number(0))
        XCTAssertEqual(try typed("SIGN(0.005in,1mm)"),.number(0))
        XCTAssertEqual(try typed("SIGN(-0.005in,0.1mm)"),.number(-1))
        XCTAssertEqual(try typed("SIGN(0.005in,0.1)"),.number(0))
        XCTAssertThrowsError(try typed("SIGN(0.005in,1rad)"))
        XCTAssertThrowsError(try typed("SIGN(0.005,1mm)"))
    }
    func testInstallerSIGNFuzzFormulaEvaluatesFromHVACCStencil() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),source = root.appendingPathComponent("build/Visio2019-Libraries/HVACC_U.VSSX")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Installer assets are absent") }
        let parts = try VisioPackage.read(source)
        var formulas:[String] = []
        for (part,data) in parts where part.hasPrefix("visio/masters/master") && part.hasSuffix(".xml") {
            guard let root = try VisioXML.document(data).rootElement() else { continue }
            var pending = [root]
            while let element = pending.popLast() {
                if element.localTag == "Cell",let formula = element.attr("F") { formulas.append(formula) }
                pending.append(contentsOf:(element.children ?? []).compactMap{$0 as? XMLElement})
            }
        }
        let formula = try XCTUnwrap(formulas.first{$0 == "Height+SIGN(Height,0.01)*0.14"})
        XCTAssertEqual(try ShapeSheet.evaluate(formula){reference in
            guard reference == "Height" else { throw DiagramError.invalid("Unexpected installer reference: \(reference)") };return -0.005
        },-0.005,accuracy:1e-12)
    }
    func testTypedRoundingRetainsCompatibleMeasureUnits() throws {
        func typed(_ formula:String) throws -> SheetValue { try TypedShapeSheet.evaluate(formula,resolve:{_ in .number(0)},call:{_,_ in .number(0)}) }
        XCTAssertEqual(try typed("CEILING(1.1in,0.25in)"),.quantity(1.25,"IN"))
        XCTAssertEqual(try typed("CEILING(26mm,1in)"),.quantity(2,"MM"))
        XCTAssertEqual(try typed("FLOOR(26mm,1in)"),.quantity(1,"MM"))
        let defaultMillimeters = try typed("CEILING(26mm)"),unitlessMillimeterStep = try typed("CEILING(26mm,1)")
        XCTAssertEqual(try defaultMillimeters.numeric(),26/25.4,accuracy:1e-12);XCTAssertEqual(defaultMillimeters.unit,"MM")
        XCTAssertEqual(try unitlessMillimeterStep.numeric(),26/25.4,accuracy:1e-12);XCTAssertEqual(unitlessMillimeterStep.unit,"MM")
        XCTAssertEqual(try typed("CEILING(26mm,1mm)"),.quantity(26/25.4,"MM"))
        XCTAssertEqual(try typed("FLOOR(-3.7,-0.5)"),.number(-3.5))
        XCTAssertThrowsError(try typed("CEILING(1in,1rad)"))
        XCTAssertThrowsError(try typed("FLOOR(1,1in)"))
    }
    func testInstallerCEILINGAndFLOORFormulasEvaluateFromBLDCORStencil() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),source = root.appendingPathComponent("build/Visio2019-Libraries/BLDCOR_M.VSSX")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Installer assets are absent") }
        let parts = try VisioPackage.read(source)
        var formulas:[String] = []
        for (part,data) in parts where part.hasPrefix("visio/masters/master") && part.hasSuffix(".xml") {
            guard let root = try VisioXML.document(data).rootElement() else { continue }
            var pending = [root]
            while let element = pending.popLast() {
                if element.localTag == "Cell",let formula = element.attr("F") { formulas.append(formula) }
                pending.append(contentsOf:(element.children ?? []).compactMap{$0 as? XMLElement})
            }
        }
        let ceiling = try XCTUnwrap(formulas.first{$0 == "CEILING(Sheet.5!User.ActualTreadNumber*User.LandingCount)"})
        let floorSource = try XCTUnwrap(formulas.first{$0.contains("FLOOR(User.ItemCtr)")})
        let floor = "FLOOR(User.ItemCtr)"
        XCTAssertTrue(floorSource.contains(floor))
        XCTAssertEqual(try ShapeSheet.evaluate(ceiling){reference in
            switch reference { case "Sheet.5!User.ActualTreadNumber":return 3.7;case "User.LandingCount":return 1;default:throw DiagramError.invalid("Unexpected installer reference: \(reference)") }
        },4)
        XCTAssertEqual(try ShapeSheet.evaluate(floor){reference in
            guard reference == "User.ItemCtr" else { throw DiagramError.invalid("Unexpected installer reference: \(reference)") };return 5.8
        },5)
    }
    func testUnsupportedFunctionsMalformedExpressionsAndCalculationBoundsThrow() {
        for formula in ["RUNADDON(1)","Width+","IF(1,2)","1/0","SQRT(-1)",String(repeating:"(",count:200)+"1"+String(repeating:")",count:200),"1e999","1 2","system('x')"] {
            XCTAssertThrowsError(try ShapeSheet.evaluate(formula){_ in 1},formula)
        }
    }
    private func node(_ x:Double,_ id:String) -> DiagramNode {
        var n = DiagramNode(x:x,y:100,text:"Formula shape"); n.formatting.sourceShapeID = id
        var p = DiagramPage();p.nodes = [n]
        n.formatting.sheet = ShapeSheetEngine.defaults(n,page:p).mapValues{ShapeSheetCell(value:ShapeSheetEngine.format($0))}
        n.formatting.sheet["LocPinX"]?.formula = "Width*0.5";n.formatting.sheet["LocPinY"]?.formula = "Height*0.5"
        return n
    }
    func testLiveDependenciesUserCellsAndCrossShapeReferences() throws {
        var d = Diagram();var a = node(100,"1"),b = node(500,"2")
        a.formatting.sheet["User.Padding"] = ShapeSheetCell(value:"0.25")
        a.formatting.sheet["Width"] = ShapeSheetCell(value:"2",formula:"2 in+User.Padding*2")
        b.formatting.sheet["Height"] = ShapeSheetCell(value:"1",formula:"Sheet.1!Width/2")
        d.page.nodes = [a,b]
        let result = ShapeSheetEngine.recalculate(d)
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined())
        XCTAssertEqual(result.diagram.page.nodes[0].width,180,accuracy:0.001)
        XCTAssertEqual(result.diagram.page.nodes[1].height,90,accuracy:0.001)
        XCTAssertEqual(result.diagram.page.nodes[0].center.x,a.center.x,accuracy:0.001)
        var updated = result.diagram;updated.page.nodes[0].formatting.sheet["User.Padding"]?.value = "0.5"
        let changed = ShapeSheetEngine.recalculate(updated,previous:result.diagram)
        XCTAssertEqual(changed.diagram.page.nodes[0].width,216,accuracy:0.001);XCTAssertEqual(changed.diagram.page.nodes[1].height,108,accuracy:0.001)
    }
    func testManualGeometryOverridesFormulaButGuardedGeometryRemainsProtected() {
        var d = Diagram();var n = node(100,"1");n.formatting.sheet["Width"] = ShapeSheetCell(value:"2",formula:"GUARD(2 in)");d.page.nodes = [n]
        let base = ShapeSheetEngine.recalculate(d).diagram
        var resized = base;resized.page.nodes[0].width = 400
        let guarded = ShapeSheetEngine.recalculate(resized,previous:base)
        XCTAssertEqual(guarded.diagram.page.nodes[0].width,144,accuracy:0.001)
        var unguarded = base;unguarded.page.nodes[0].formatting.sheet["Width"]?.formula = "2 in"
        resized = unguarded;resized.page.nodes[0].width = 300
        let manual = ShapeSheetEngine.recalculate(resized,previous:unguarded)
        XCTAssertEqual(manual.diagram.page.nodes[0].width,300,accuracy:0.001);XCTAssertEqual(manual.diagram.page.nodes[0].formatting.sheet["Width"]?.formula,"")
    }
    func testCyclesAndUnsupportedImportedFormulasRetainCachedGeometry() {
        var d = Diagram();var n = node(100,"1");n.formatting.sheet["Width"]?.formula = "Height";n.formatting.sheet["Height"]?.formula = "Width";d.page.nodes = [n]
        let result = ShapeSheetEngine.recalculate(d)
        XCTAssertFalse(result.issues.isEmpty);XCTAssertEqual(result.diagram.page.nodes[0].rect,n.rect)
        n.formatting.sheet["Width"]?.formula = "UNSUPPORTED(1)";n.formatting.sheet["Height"]?.formula = "";d.page.nodes = [n]
        let unsupported = ShapeSheetEngine.recalculate(d)
        XCTAssertFalse(unsupported.issues.isEmpty);XCTAssertEqual(unsupported.diagram.page.nodes[0].width,n.width)
    }
    func testPublicVisioFileContainsTheFormulaAndUpdatedCachedValue() throws {
        var d = Diagram();var n = node(100,"9");n.formatting.sheet["User.Size"] = ShapeSheetCell(value:"3");n.formatting.sheet["Width"] = ShapeSheetCell(value:"2",formula:"User.Size");d.page.nodes = [n]
        d = ShapeSheetEngine.recalculate(d).diagram
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Formula-\(UUID()).vsdx");defer{try? FileManager.default.removeItem(at:url)}
        try VisioFormat.write(d,to:url);var parts = try VisioPackage.read(url)
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!)
        let shape = try XCTUnwrap(xml.rootElement()?.firstLocal("Shapes")?.elementsLocal("Shape").first)
        XCTAssertEqual(shape.attr("ID"),"9")
        let width = shape.elementsLocal("Cell").first{$0.attr("N") == "Width"}
        XCTAssertEqual(width?.attr("V"),"3");XCTAssertEqual(width?.attr("F"),"User.Size")
        parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:url)
        let restored = try VisioFormat.read(from:url).diagram
        XCTAssertEqual(restored.page.nodes[0].width,216,accuracy:0.001);XCTAssertEqual(restored.page.nodes[0].formatting.sheet["Width"]?.formula,"User.Size")
    }
}
