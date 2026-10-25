import Foundation
import XCTest
@testable import MacVisio

/// Independent expected values for the bounded ROUND/CEILING/FLOOR proposal.
/// These are local regressions against documented rules, not Visio runtime evidence.
final class M3NumericBoundaryTests: XCTestCase {
    private func scalar(_ formula:String) throws -> Double {
        try ShapeSheet.evaluate(formula) { _ in throw DiagramError.invalid("Unexpected numeric reference") }
    }
    private func typed(_ formula:String,scalar:Bool = false) throws -> SheetValue {
        try TypedShapeSheet.evaluate(formula,resolve:{_ in throw DiagramError.invalid("Unexpected numeric reference")},call:{_,_ in throw DiagramError.invalid("Unexpected numeric function")},scalar:scalar)
    }
    private func values(_ formula:String) throws -> [Double] {
        [try scalar(formula),try typed(formula).numeric(),try typed(formula,scalar:true).numeric()]
    }
    private func values(_ expression:ShapeSheet.Expression) throws -> [Double] {
        let resolve:(String)throws->SheetValue = {_ in throw DiagramError.invalid("Unexpected numeric reference")}
        let call:(String,[SheetValue])throws->SheetValue = {_,_ in throw DiagramError.invalid("Unexpected numeric function")}
        return [try ShapeSheet.evaluate(expression,resolve:{_ in throw DiagramError.invalid("Unexpected numeric reference")}),
                try TypedShapeSheet.evaluate(expression,resolve:resolve,call:call).numeric(),
                try TypedShapeSheet.evaluate(expression,resolve:resolve,call:call,scalar:true).numeric()]
    }
    private func rejects(_ formula:String,file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertThrowsError(try scalar(formula),formula,file:file,line:line)
        XCTAssertThrowsError(try typed(formula),formula,file:file,line:line)
        XCTAssertThrowsError(try typed(formula,scalar:true),formula,file:file,line:line)
    }

    func testRoundDocumentedExamplesAndPrecisionIdentityBoundaries() throws {
        let cases:[(String,Double)] = [
            ("ROUND(123.654,2)",123.65),("ROUND(123.654,0)",124),("ROUND(123.654,-1)",120),
            ("ROUND(123456789.75,-8)",100000000),("ROUND(123456789.75,-9)",123456789.75),
            ("ROUND(6e-16,15)",1e-15),("ROUND(6e-16,16)",6e-16),
            ("ROUND(123.654,99)",123.654),("ROUND(123.654,-32768)",123.654),
            ("ROUND(123.654,32767)",123.654),("ROUND(123.654,2.9)",123.65),
            ("ROUND(123.654,-1.9)",120)
        ]
        for (formula,expected) in cases { for value in try values(formula) { XCTAssertEqual(value,expected,formula) } }
    }

    func testRoundPrecisionTruncatesBeforeItsSignedSixteenBitRangeCheck() throws {
        for precision in [32767.999,-32768.999] {
            let expression = ShapeSheet.Expression.call("ROUND",[.number(12.25),.number(precision)])
            for value in try values(expression) { XCTAssertEqual(value,12.25) }
        }
        for formula in ["ROUND(12.25,32768)","ROUND(12.25,-32769)","ROUND(12.25,1e308)","ROUND(12.25,-1e308)"] { rejects(formula) }
        for value in try values("IFERROR(ROUND(12.25,32768),17)") { XCTAssertEqual(value,17) }
    }

    func testRoundFiniteIntegralExtremesDoNotOverflowAnUnnecessaryDecimalScale() throws {
        for number in [Double.greatestFiniteMagnitude,-Double.greatestFiniteMagnitude,1e308,-1e308] {
            for digits in [-8.0,0,1,15] {
                let expression = ShapeSheet.Expression.call("ROUND",[.number(number),.number(digits)])
                for value in try values(expression) { XCTAssertTrue(value.isFinite);XCTAssertEqual(value,number) }
            }
        }
        for number in [9007199254740992.0,-9007199254740992.0,9007199254740991.0,-9007199254740991.0] {
            for digits in [0.0,1,15] {
                let expression = ShapeSheet.Expression.call("ROUND",[.number(number),.number(digits)])
                for value in try values(expression) { XCTAssertEqual(value,number) }
            }
        }
        for (formula,expected) in [("ROUND(9007199254740992,-8)",9007199300000000.0),("ROUND(-9007199254740992,-8)",-9007199300000000.0)] {
            for value in try values(formula) { XCTAssertEqual(value,expected) }
        }
        for value in try values("ROUND(5e-324,15)") { XCTAssertEqual(value,0) }
    }

    func testRoundHalfwayNeighborsKeepExistingNearestAwayFromZeroPolicy() throws {
        for (number,expected) in [(0.5.nextDown,0.0),(0.5,1),(0.5.nextUp,1),((-0.5).nextDown,-1),(-0.5,-1),((-0.5).nextUp,0)] {
            let expression = ShapeSheet.Expression.call("ROUND",[.number(number),.number(0)])
            for value in try values(expression) { XCTAssertEqual(value,expected) }
        }
        for (formula,expected) in [("ROUND(1.25,1)",1.3),("ROUND(-1.25,1)",-1.3)] {
            for value in try values(formula) { XCTAssertEqual(value,expected) }
        }
    }

    func testCeilingAndFloorHandleUnderflowWithoutTreatingANonzeroNumberAsZero() throws {
        for (formula,expected) in [("CEILING(1e-308,1e308)",1e308),("CEILING(-1e-308,-1e308)",-1e308),
                                   ("FLOOR(1e-308,1e308)",0),("FLOOR(-1e-308,-1e308)",0)] {
            for value in try values(formula) { XCTAssertEqual(value,expected,formula) }
        }
        for (formula,expected) in [("CEILING(5e-324,1)",1.0),("CEILING(-5e-324,-1)",-1),("FLOOR(5e-324,1)",0)] {
            for value in try values(formula) { XCTAssertEqual(value,expected,formula) }
        }
    }

    func testExactlyRepresentableMultipleNeighborsAreNotSnappedAcrossABoundary() throws {
        let cases:[(Double,Double,Double,Double)] = [
            (0.75,0.25,0.75,0.75),(0.75.nextDown,0.25,0.75,0.5),(0.75.nextUp,0.25,1,0.75),
            (-0.75,-0.25,-0.75,-0.75),((-0.75).nextUp,-0.25,-0.75,-0.5),((-0.75).nextDown,-0.25,-1,-0.75)
        ]
        for (number,multiple,ceiling,floor) in cases {
            for (name,expected) in [("CEILING",ceiling),("FLOOR",floor)] {
                let expression = ShapeSheet.Expression.call(name,[.number(number),.number(multiple)])
                for value in try values(expression) { XCTAssertEqual(value,expected) }
            }
        }
    }

    func testZeroAndSignedZeroKeepTheirExistingHostConventions() throws {
        let cases:[(String,FloatingPointSign)] = [("ROUND(-0,0)",.minus),("ROUND(-0,99)",.minus),
            ("ROUND(-1e-308,15)",.minus),("CEILING(-0)",.plus),("FLOOR(-0)",.plus),
            ("CEILING(2,0)",.plus),("FLOOR(-2,0)",.plus),("FLOOR(-1e-308,-1e308)",.minus)]
        for (formula,sign) in cases {
            for value in try values(formula) { XCTAssertEqual(value,0);XCTAssertEqual(value.sign,sign,formula) }
        }
    }

    func testZeroRulesSignErrorsAndUnsupportedOverflowRemainExplicit() throws {
        for formula in ["CEILING(0,-1)","FLOOR(0,1)","CEILING(-2,0)","FLOOR(2,0)"] {
            for value in try values(formula) { XCTAssertEqual(value,0,formula) }
        }
        for formula in ["CEILING(2,-1)","FLOOR(-2,1)","CEILING(1e308,1e-308)","FLOOR(1e308,1e-308)",
                        "CEILING(1.7e308,1e308)","CEILING()","ROUND(1)","ROUND(1,2,3)","CEILING(1,)"] { rejects(formula) }
        for value in try values("IFERROR(CEILING(1e308,1e-308),23)") { XCTAssertEqual(value,23) }
    }

    func testNonfiniteOperandsAndNonnumericInputsStillFailThroughBothEngines() {
        for number in [Double.infinity,-Double.infinity,Double.nan] {
            for name in ["ROUND","CEILING","FLOOR"] {
                let args:[ShapeSheet.Expression] = name == "ROUND" ? [.number(number),.number(0)] : [.number(number)]
                let expression = ShapeSheet.Expression.call(name,args)
                XCTAssertThrowsError(try ShapeSheet.evaluate(expression,resolve:{_ in 0}))
                for mode in [false,true] {
                    XCTAssertThrowsError(try TypedShapeSheet.evaluate(expression,resolve:{_ in .number(0)},call:{_,_ in .number(0)},scalar:mode))
                }
            }
        }
        for formula in ["ROUND(\"no\",1)","CEILING(\"no\")","FLOOR(\"no\",1)"] { rejects(formula) }
        // Typed numeric-string coercion is an existing separate host contract.
        XCTAssertThrowsError(try scalar("ROUND(\"12.25\",1)"))
        XCTAssertEqual(try typed("ROUND(\"12.25\",1)"),.number(12.3))
    }

    func testTypedDisplayUnitsAndScalarGeometryUnitsRemainDistinct() throws {
        for formula in ["ROUND(26mm,0)","CEILING(26mm)","FLOOR(26mm)"] {
            let field = try typed(formula)
            XCTAssertEqual(field.unit,"MM");XCTAssertEqual(try field.numeric(),26/25.4,accuracy:1e-14)
        }
        // Visio has one evaluator: geometry cells round in display units as well. A flowchart master's
        // Height = MAX(User.DefaultHeight,CEILING(TEXTHEIGHT(TheText,TxtWidth)+0MM,1)) caches 15 mm, not 1 in.
        for formula in ["ROUND(26mm,0)","CEILING(26mm)","FLOOR(26mm)"] {
            XCTAssertEqual(try typed(formula,scalar:true).numeric(),26/25.4,accuracy:1e-14,formula)
        }
        let angle = try typed("ROUND(90.25deg,0)");XCTAssertEqual(angle.unit,"DEG");XCTAssertEqual(try angle.numeric(),Double.pi/2,accuracy:1e-14)
        XCTAssertEqual(try typed("CEILING(1e-308in,1e308in)"),.quantity(1e308,"IN"))
        XCTAssertEqual(try typed("CEILING(-1e-308rad,-1e308rad)"),.quantity(-1e308,"RAD"))
        let zero = try typed("FLOOR(-1e-308in,-1e308in)");XCTAssertEqual(zero.unit,"IN");XCTAssertEqual(try zero.numeric().sign,.minus)
        // Mixed units are accepted (ROUNDING-6, ROUNDING-13).
        XCTAssertEqual(try typed("CEILING(1in,1rad)"),.quantity(1,"IN"));XCTAssertEqual(try typed("FLOOR(1,1in)"),.number(1))
    }

    func testTypedMillimeterWholeAndHalfwayBoundariesKeepTheirAdjacentValuesDistinct() throws {
        let resolve:(String)throws->SheetValue = {_ in throw DiagramError.invalid("Unexpected reference")}
        let call:(String,[SheetValue])throws->SheetValue = {_,_ in throw DiagramError.invalid("Unexpected function")}
        let whole = 26*(1/25.4),halfway = 26.5*(1/25.4)
        for (number,ceiling,floor) in [(whole.nextDown,26.0,25.0),(whole,26,26),(whole.nextUp,27,26),
                                      ((-whole).nextDown,-27,-26),(-whole,-26,-26),((-whole).nextUp,-26,-25)] {
            for (name,expected) in [("CEILING",ceiling),("FLOOR",floor)] {
                let operands:[ShapeSheet.Expression] = [.measure(number,"MM"),.binary("*",.measure(number/2,"MM"),.number(2))]
                for operand in operands {
                    let expression = ShapeSheet.Expression.call(name,[operand])
                    let result = try TypedShapeSheet.evaluate(expression,resolve:resolve,call:call)
                    XCTAssertEqual(result.unit,"MM");XCTAssertEqual(try result.numeric(),expected/25.4,accuracy:1e-14)
                }
            }
        }
        for (number,expected) in [(halfway.nextDown,26.0),(halfway,27),(halfway.nextUp,27),
                                 ((-halfway).nextDown,-27),(-halfway,-27),((-halfway).nextUp,-26)] {
            let operands:[ShapeSheet.Expression] = [.measure(number,"MM"),.binary("*",.measure(number/2,"MM"),.number(2))]
            for operand in operands {
                let expression = ShapeSheet.Expression.call("ROUND",[operand,.number(0)])
                let result = try TypedShapeSheet.evaluate(expression,resolve:resolve,call:call)
                XCTAssertEqual(result.unit,"MM");XCTAssertEqual(try result.numeric(),expected/25.4,accuracy:1e-14)
            }
        }
        // These quantities are computed by typed arithmetic before rounding.
        for (formula,expected) in [("ROUND(13.25mm*2,0)",27.0),("ROUND(-13.25mm*2,0)",-27),
                                   ("CEILING(13mm*2)",26),("FLOOR(13mm*2)",26),("CEILING(13mm*2,1)",26)] {
            // A unit multiple is taken in internal units, so CEILING(26mm,1mm) is 26.0236 mm (ROUNDING-1).
            let result = try typed(formula)
            XCTAssertEqual(result.unit,"MM");XCTAssertEqual(try result.numeric(),expected/25.4,accuracy:1e-14,formula)
        }
    }

    func testTypedExtremeQuantityKeepsUnitsAndUnrepresentableDisplayConversionStillRefuses() throws {
        let expression = ShapeSheet.Expression.call("ROUND",[.reference("Huge"),.number(15)])
        let call:(String,[SheetValue])throws->SheetValue = {_,_ in throw DiagramError.invalid("Unexpected function")}
        let exact = try TypedShapeSheet.evaluate(expression,resolve:{_ in .quantity(Double.greatestFiniteMagnitude,"IN")},call:call)
        XCTAssertEqual(exact,.quantity(Double.greatestFiniteMagnitude,"IN"))
        XCTAssertThrowsError(try TypedShapeSheet.evaluate(expression,resolve:{_ in .quantity(Double.greatestFiniteMagnitude,"MM")},call:call))
    }

    func testShapeAndPageHostsPreserveTheirOwnUnitModeAndErrorPropagation() throws {
        var page = DiagramPage();var node = DiagramNode(text:"")
        let rounded = ShapeSheetCell(value:"1",formula:"ROUND(26mm,0)",unit:"MM")
        node.formatting.sheet["User.Rounded"] = rounded
        page.nodes = [node];page.sheet = ["User.Rounded":rounded,"User.Bad":ShapeSheetCell(value:"9",formula:"ROUND(1,32768)")]
        let scalar = ShapeSheetContext(page:page,mode:.scalarGeometry),field = ShapeSheetContext(page:page,mode:.typedFields)
        for address in ["User.Rounded","ThePage!User.Rounded"] {
            XCTAssertEqual(try scalar.value(node.id,address).numeric(),26/25.4,accuracy:1e-14)
            let result = try field.value(node.id,address);XCTAssertEqual(result.unit,"MM");XCTAssertEqual(try result.numeric(),26/25.4,accuracy:1e-14)
        }
        XCTAssertThrowsError(try scalar.value(node.id,"ThePage!User.Bad"));XCTAssertThrowsError(try field.value(node.id,"ThePage!User.Bad"))
    }

    func testInvalidRoundingKeepsGeometryFormulaAndCachedDimensions() {
        for formula in ["ROUND(3,32768)","CEILING(3,-1)","FLOOR(1e308,1e-308)"] {
            var diagram = Diagram();var node = DiagramNode(x:100,y:100,text:"");node.width = 144
            node.formatting.sheet["Width"] = ShapeSheetCell(value:"2",formula:formula,unit:"IN");diagram.page.nodes = [node]
            let result = ShapeSheetEngine.recalculate(diagram),saved = result.diagram.page.nodes[0]
            XCTAssertFalse(result.issues.isEmpty);XCTAssertEqual(saved.width,144);XCTAssertEqual(saved.formatting.sheet["Width"],node.formatting.sheet["Width"])
        }
    }

    func testInvalidRoundingKeepsTypedFieldFormulaUnitAndCachedText() {
        // FLOOR of a negative value to a positive multiple is #NUM! in Visio (ROUNDING-14).
        for formula in ["ROUND(3,32768)","FLOOR(-2.5cm,1cm)","FLOOR(1e308,1e-308)"] {
            var diagram = Diagram();var node = DiagramNode(text:"Kept")
            let value = ShapeSheetCell(value:"2",formula:formula,unit:"IN")
            node.formatting.textFields = [ShapeTextField(index:0,cells:["Value":value,"Type":ShapeSheetCell(value:"2")],cached:"Kept")]
            node.formatting.textRuns = [ShapeTextRun(text:"Kept",character:ShapeCharacterStyle(node:node),paragraph:ShapeParagraphStyle(),fieldIndex:0,fieldToken:UUID())]
            diagram.page.nodes = [node]
            let result = TextFieldEngine.recalculate(diagram),saved = result.diagram.page.nodes[0]
            XCTAssertFalse(result.issues.isEmpty);XCTAssertEqual(saved.text,"Kept");XCTAssertEqual(saved.formatting.textFields?.first?.cached,"Kept")
            XCTAssertEqual(saved.formatting.textFields?.first?.cells["Value"],value)
        }
    }
}
