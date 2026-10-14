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
