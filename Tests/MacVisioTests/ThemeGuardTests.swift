import Foundation
import XCTest
@testable import MacVisio

final class ThemeGuardTests:XCTestCase {
    func testScalarThemeGuardReturnsItsArgument() throws {
        XCTAssertEqual(try ShapeSheet.evaluate("THEMEGUARD(Width/2)") { reference in
            guard reference == "Width" else { throw DiagramError.invalid("Unexpected reference.") }
            return 4
        },2)
        XCTAssertEqual(try ShapeSheet.evaluate("THEMEGUARD(2 in)") { _ in 0 },2)
        for formula in ["THEMEGUARD()","THEMEGUARD(1,2)"] {
            XCTAssertThrowsError(try ShapeSheet.evaluate(formula) { _ in 0 },formula)
        }
    }

    func testTypedThemeGuardPreservesArgumentTypeAndUnits() throws {
        func typed(_ formula:String) throws -> SheetValue {
            try TypedShapeSheet.evaluate(formula,resolve:{_ in .number(0)},call:{name,_ in throw DiagramError.invalid("Unexpected function: \(name)")})
        }
        XCTAssertEqual(try typed("THEMEGUARD(1.25in)"),.quantity(1.25,"IN"))
        XCTAssertEqual(try typed("THEMEGUARD(\"AccentColor2\")"),.string("AccentColor2"))
        for formula in ["THEMEGUARD()","THEMEGUARD(1,2)"] {
            XCTAssertThrowsError(try typed(formula),formula)
        }
    }

    func testInstallerThemeGuardColorFormulaEvaluatesFromBLDCORStencil() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),source = root.appendingPathComponent("build/Visio2019-Libraries/BLDCOR_M.VSSX")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Installer assets are absent") }
        let parts = try VisioPackage.read(source)
        var formulas:[String] = []
        for (part,data) in parts where part.hasPrefix("visio/masters/master") && part.hasSuffix(".xml") {
            guard let xml = try VisioXML.document(data).rootElement() else { continue }
            var pending = [xml]
            while let element = pending.popLast() {
                if element.localTag == "Cell",let formula = element.attr("F") { formulas.append(formula) }
                pending.append(contentsOf:(element.children ?? []).compactMap{$0 as? XMLElement})
            }
        }
        let formula = try XCTUnwrap(formulas.first{$0 == "THEMEGUARD(RGB(0,0,0))"})
        XCTAssertEqual(try ShapeSheet.evaluate(formula){_ in throw DiagramError.invalid("Unexpected installer reference.")},0)
    }

    func testThemeGuardFormulaIsRetainedUntilManualGeometryEditAndDoesNotLockIt() {
        var diagram = Diagram(),shape = DiagramNode()
        shape.formatting.sheet["Width"] = ShapeSheetCell(value:"2",formula:"THEMEGUARD(2 in)")
        diagram.page.nodes = [shape]
        let calculated = ShapeSheetEngine.recalculate(diagram)
        XCTAssertTrue(calculated.issues.isEmpty,calculated.issues.joined())
        XCTAssertEqual(calculated.diagram.page.nodes[0].width,144,accuracy:1e-9)
        XCTAssertEqual(calculated.diagram.page.nodes[0].formatting.sheet["Width"]?.formula,"THEMEGUARD(2 in)")

        var resized = calculated.diagram
        resized.page.nodes[0].width = 288
        let edited = ShapeSheetEngine.recalculate(resized,previous:calculated.diagram)
        XCTAssertTrue(edited.issues.isEmpty,edited.issues.joined())
        XCTAssertEqual(edited.diagram.page.nodes[0].width,288,accuracy:1e-9)
        XCTAssertEqual(edited.diagram.page.nodes[0].formatting.sheet["Width"]?.formula,"")
    }

    func testCompositeGeometryThemeGuardReturnsWrappedGeometry() throws {
        let geometry = try CompositeGeometry.evaluate("THEMEGUARD(NURBS(1,3,0,0,0.25,1,0,1,0.75,1,0,1))",numeric:{_ in 0})
        XCTAssertEqual(geometry.name,"NURBS")
        XCTAssertEqual(geometry.values,[1,3,0,0,0.25,1,0,1,0.75,1,0,1])
    }
}
