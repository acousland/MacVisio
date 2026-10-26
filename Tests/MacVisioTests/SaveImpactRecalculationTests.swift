import XCTest
@testable import MacVisio

/// Customer drawings could not be saved after ordinary edits ("This save may change unsupported source
/// behavior"): shapes only recalculated were treated as edited, moving a master instance counted as changing
/// what it inherits, and FILENAME() had no file to read.
final class SaveImpactRecalculationTests: XCTestCase {
    private func shape() -> DiagramNode {
        var node = DiagramNode(x: 10, y: 10, text: "Frame")
        node.formatting.sheet["Height"] = ShapeSheetCell(value: "10.0245", formula: "GUARD(ThePage!PageHeight-Sheet.53!Height)")
        node.formatting.sheet["PinY"] = ShapeSheetCell(value: "0.5978", formula: "GUARD(Sheet.62!Height)")
        return node
    }

    func testValuesRecalculatedFromUnchangedFormulasAreNotAnEdit() {
        let original = shape()
        var recalculated = original
        recalculated.formatting.sheet["Height"]?.value = "9.9177"; recalculated.height -= 7.7; recalculated.y += 3
        XCTAssertTrue(DocumentSaveImpact.onlyRecalculated(original, recalculated))
    }

    func testAuthoredChangesAreStillEdits() {
        let original = shape()
        var moved = original; moved.x += 20
        XCTAssertFalse(DocumentSaveImpact.onlyRecalculated(original, moved), "A move without a driving formula is authored")
        var retexted = original; retexted.text = "Renamed"
        XCTAssertFalse(DocumentSaveImpact.onlyRecalculated(original, retexted))
        var reformulated = original; reformulated.formatting.sheet["Height"] = ShapeSheetCell(value: "2", formula: "2 in")
        XCTAssertFalse(DocumentSaveImpact.onlyRecalculated(original, reformulated))
    }

    func testFileNameFunctionReadsTheOpenDrawingsName() throws {
        var diagram = Diagram()
        diagram.fileURL = URL(fileURLWithPath: "/tmp/Logical Definition (Zoning) v1.0.0.vsdx")
        let node = DiagramNode(text: "Version"); diagram.page.nodes = [node]
        let context = ShapeSheetContext(page: diagram.page, document: diagram)
        let formula = "MID(FILENAME(),FIND(\"v1\",FILENAME()),FIND(\".vsd\",FILENAME())-FIND(\"v1\",FILENAME()))"
        XCTAssertEqual(try context.evaluate(formula, on: node.id).text, "v1.0.0")
        XCTAssertEqual(diagram, { var copy = diagram; copy.fileURL = nil; return copy }(), "The location is not part of the drawing")
    }
}
