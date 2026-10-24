import XCTest
@testable import MacVisio

final class AutomationPrototypeTests: XCTestCase {
    func testTranslatedScriptDrivesThePageObjectModel() {
        let script = """
        const page = Application.ActivePage;
        const a = page.DrawRectangle(1, 1, 3, 2); a.Text = "Start";
        const b = page.DrawRectangle(4, 1, 6, 2.5); b.Text = "End";
        ({ count: page.Shapes.Count, texts: [a.Text, b.Text], ids: [a.ID, b.ID] })
        """
        let outcome = AutomationPrototype.run(script, on: Diagram())
        XCTAssertNil(outcome.error)
        let result = outcome.result as? [String: Any]
        XCTAssertEqual(result?["count"] as? Int, 2)
        XCTAssertEqual(result?["texts"] as? [String], ["Start", "End"])
        let shapes = AutomationPrototype.visioShapes(outcome.diagram)
        XCTAssertEqual(shapes[1]["pinX"] as? Double ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(shapes[1]["pinY"] as? Double ?? 0, 1.75, accuracy: 1e-9)
        XCTAssertEqual(shapes[1]["height"] as? Double ?? 0, 1.5, accuracy: 1e-9)
    }

    func testUnmodifiedVBAIsNotExecuted() {
        let vba = """
        Sub Main()
            Dim shp As Visio.Shape
            Set shp = ActivePage.DrawRectangle(1, 1, 3, 2)
            shp.Text = "Start"
        End Sub
        """
        let outcome = AutomationPrototype.run(vba, on: Diagram())
        XCTAssertNotNil(outcome.error, "VBA source is not JavaScript; unmodified VBA compatibility is unsupported")
        XCTAssertTrue(outcome.diagram.page.nodes.isEmpty)
    }
}
