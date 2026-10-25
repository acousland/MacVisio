import XCTest
@testable import MacVisio

/// Replays Visio 2019's quick-style results (scripts/windows/Probe-VisioQuickStyles.ps1): with a theme
/// applied, THEMEVAL() in fill, line and text color cells resolves through QuickStyle*Color/Matrix.
final class VisioQuickStyleReferenceTests: XCTestCase {
    private struct Probe: Decodable {
        struct Record: Decodable { let theme: String; let `case`: String; let selectors: [String: String]; let values: [String: String] }
        let records: [Record]
    }

    func testThemedFillLineAndTextColorsMatchVisio() throws {
        let folder = "Fixtures/Reference/quickstyles"
        let probe = try JSONDecoder().decode(Probe.self, from: Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "quickstyles", withExtension: "json", subdirectory: folder))))
        var checked = 0, failures: [String] = []
        for theme in ["Office Theme", "Linear", "Integral"] {
            let file = "quickstyles-" + theme.replacingOccurrences(of: " ", with: "")
            let diagram = try VisioFormat.read(from: try XCTUnwrap(Bundle.module.url(forResource: file, withExtension: "vsdx", subdirectory: folder))).diagram
            var page = diagram.page
            let index = try XCTUnwrap(page.nodes.firstIndex { $0.text == "Quick" })
            for record in probe.records where record.theme == theme {
                for (key, value) in record.selectors where key.hasPrefix("QuickStyle") { page.nodes[index].formatting.sheet[key] = ShapeSheetCell(value: value) }
                let context = ShapeSheetContext(page: page, binding: diagram.visioArchive?.pages.first, document: diagram, mode: .typedFields)
                for (cell, part) in [("FillForegnd", "fill"), ("LineColor", "line"), ("Char.Color", "text")] {
                    guard let expected = record.values[cell], expected.hasPrefix("RGB(") else { continue }
                    checked += 1
                    let value = try? context.evaluate(ShapeSheetCell(value: "", formula: "THEMEVAL()"), on: page.nodes[index].id, hostCell: cell)
                    let numbers = expected.dropFirst(4).dropLast().split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    guard case .color(let color)? = value, [color.red, color.green, color.blue] == numbers else {
                        failures.append("\(theme) \(record.case) \(part): Visio \(expected), MacVisio \(String(describing: value))"); continue
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 500)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(checked) disagree:\n" + failures.prefix(40).joined(separator: "\n"))
    }
}
