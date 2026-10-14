import Foundation
import XCTest
@testable import MacVisio

final class THEMEVALTests:XCTestCase {
    private func cell(_ value:String,_ formula:String = "") -> ShapeSheetCell { ShapeSheetCell(value:value,formula:formula) }

    private func page(with shape:DiagramNode) -> DiagramPage {
        var page = DiagramPage();page.nodes = [shape];return page
    }

    func testExplicitNoThemeShapeReturnsTypedDefaultValues() throws {
        var shape = DiagramNode(text:"No Theme")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("0")
        let context = ShapeSheetContext(page:page(with:shape))

        XCTAssertEqual(try context.evaluate("THEMEVAL(\"LineWeight\",1.25in)",on:shape.id),.quantity(1.25,"IN"))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"FillGradientEnabled\",FALSE)",on:shape.id),.boolean(false))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"LatinFont\",\"Calibri\")",on:shape.id),.string("Calibri"))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"TextColor\",RGB(0,0,0))",on:shape.id),.number(0))
    }

    func testFallbackRequiresAnExplicitNonFormulaZeroColorSchemeIndex() throws {
        var noTheme = DiagramNode(text:"No Theme")
        noTheme.formatting.sheet["ColorSchemeIndex"] = cell("0")
        XCTAssertEqual(try ShapeSheetContext(page:page(with:noTheme)).evaluate("THEMEVAL(\"FillColor\",7)",on:noTheme.id),.number(7))

        var active = DiagramNode(text:"Themed")
        active.formatting.sheet["ColorSchemeIndex"] = cell("33")
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:active)).evaluate("THEMEVAL(\"FillColor\",1/0)",on:active.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("active theme"),error.localizedDescription)
        }

        var positiveSentinel = DiagramNode(text:"Positive theme index")
        positiveSentinel.formatting.sheet["ColorSchemeIndex"] = cell("65534")
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:positiveSentinel)).evaluate("THEMEVAL(\"FillColor\",7)",on:positiveSentinel.id))

        var inherited = DiagramNode(text:"Inherited index")
        inherited.formatting.sheet["ColorSchemeIndex"] = cell("0","Inh")
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:inherited)).evaluate("THEMEVAL(\"FillColor\",7)",on:inherited.id))

        let missing = DiagramNode(text:"Missing index")
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:missing)).evaluate("THEMEVAL(\"FillColor\",7)",on:missing.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unknown"),error.localizedDescription)
        }
    }

    func testUnknownPageAndThemedShapeDoNotEvaluateDefault() throws {
        var shape = DiagramNode(text:"Themed")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("2")
        var documentPage = page(with:shape)
        documentPage.sheet = ["User.Fallback":cell("23","THEMEVAL(\"FillColor\",1/0)")]
        XCTAssertThrowsError(try ShapeSheetContext(page:documentPage).value(shape.id,"ThePage!User.Fallback")) { error in
            XCTAssertTrue(error.localizedDescription.contains("unknown"),error.localizedDescription)
        }

        for formula in ["THEMEVAL(\"FillColor\")","THEMEVAL()","THEMEVAL(\"FillColor\",7,8)"] {
            XCTAssertThrowsError(try ShapeSheetContext(page:page(with:shape)).evaluate(formula,on:shape.id),formula)
        }
    }

    func testUnsupportedThemeStateKeepsCachedCellValue() {
        var shape = DiagramNode(text:"Active theme")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("1")
        shape.formatting.sheet["User.Fallback"] = cell("23","THEMEVAL(\"FillColor\",7)")
        var diagram = Diagram();diagram.page.nodes = [shape]

        let result = ShapeSheetEngine.recalculate(diagram)
        XCTAssertEqual(result.diagram.page.nodes[0].formatting.sheet["User.Fallback"]?.value,"23")
        XCTAssertTrue(result.issues.contains{$0.localizedCaseInsensitiveContains("active theme")},result.issues.joined(separator:"\n"))
    }

    func testImportedPublicVSDXThemeMetadataDoesNotImplyNoThemeForShape() throws {
        let fixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/testfile1.vsdx")
        let imported = try VisioFormat.read(from:fixture).diagram
        let shape = try XCTUnwrap(imported.page.nodes.first)
        XCTAssertNotNil(imported.visioArchive?.parts["visio/theme/theme1.xml"])
        XCTAssertNotNil(imported.page.sheet?["ThemeIndex"])
        let colorScheme = try XCTUnwrap(shape.formatting.sheet.first{$0.key.caseInsensitiveCompare("ColorSchemeIndex") == .orderedSame}?.value)
        XCTAssertEqual(colorScheme.value,"65534")
        XCTAssertTrue(colorScheme.formula.isEmpty)

        XCTAssertThrowsError(try ShapeSheetContext(page:imported.page).evaluate("THEMEVAL(\"FillColor\",7)",on:shape.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("active theme"),error.localizedDescription)
        }
    }
}
