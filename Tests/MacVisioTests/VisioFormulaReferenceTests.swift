import XCTest
@testable import MacVisio

/// Replays the Visio 2019 (16.0.10730) formula and field reference offline: every case Visio evaluated
/// on Fixtures/Reference/formula-context.vsdx must agree with MacVisio on the same drawing, unless the
/// recorded dispositions name it (environment-dependent) or list it as an open gap.
/// Refresh the fixtures with scripts/run-formula-reference.py.
final class VisioFormulaReferenceTests: XCTestCase {
    private struct Reference: Decodable {
        struct Case: Decodable { let id: String; let formula: String; let accepted: Bool; let cellError: Int?; let units: Int?; let resultIU: Double?; let resultStr: String? }
        struct Field: Decodable { let id: String; let formula: String; let format: String; let text: String?; let error: Bool? }
        let cases: [Case]; let fields: [Field]
    }
    private struct Dispositions: Decodable { let cases: [String: String]; let prefixes: [String: String]; let open: [String: String]? }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Reference"))
    }

    func testMacVisioAgreesWithVisioOnEveryReferenceCase() throws {
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: fixture("formula-visio-2019.json")))
        let dispositions = try JSONDecoder().decode(Dispositions.self, from: Data(contentsOf: fixture("formula-dispositions.json")))
        let drawing = try fixture("formula-context.vsdx")
        let diagram = try VisioFormat.readPublic(parts: VisioPackage.read(drawing), title: "context.vsdx").diagram
        // FILENAME() must see the name Visio saved the probe under.
        let named = FileManager.default.temporaryDirectory.appendingPathComponent("context.vsdx")
        let results = try FormulaProbe.evaluate(diagram, documentURL: named,
            cases: reference.cases.map { FormulaProbe.Case(id: $0.id, formula: $0.formula) },
            fields: reference.fields.map { FormulaProbe.Field(id: $0.id, formula: $0.formula, format: $0.format) })
        let mac = Dictionary(uniqueKeysWithValues: results.cases.map { ($0["id"] as! String, $0) })
        let fields = Dictionary(uniqueKeysWithValues: results.fields.map { ($0["id"] as! String, $0) })
        func excused(_ id: String) -> Bool {
            if dispositions.cases[id] != nil || dispositions.open?[id] != nil { return true }
            let suffix = id.split(separator: "-").last.flatMap { Int($0) }
            if id.hasPrefix("FIELDCODE"), let code = suffix { return (40...81).contains(code) && ![64, 65, 74, 75, 77].contains(code) }
            return false
        }
        var checked = 0, failures: [String] = []
        for item in reference.cases where !excused(item.id) {
            checked += 1
            let actual = try XCTUnwrap(mac[item.id])
            let ok = actual["ok"] as? Bool ?? false
            if !item.accepted || (item.cellError ?? 0) != 0 {
                if ok { failures.append("\(item.id) \(item.formula): Visio refuses it; MacVisio gives \(actual["text"] ?? "")") }
                continue
            }
            guard ok else { failures.append("\(item.id) \(item.formula): MacVisio error \(actual["error"] ?? "")"); continue }
            let expected = item.resultStr ?? ""
            switch item.units {
            case 231?, 225?:
                if actual["text"] as? String != expected { failures.append("\(item.id) \(item.formula): Visio \(expected.debugDescription), MacVisio \((actual["text"] as? String ?? "").debugDescription)") }
            case 251?:
                let hex = (actual["color"] as? String).map { String($0.prefix(7)).uppercased() }
                let parts = expected.dropFirst(4).dropLast().split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let visio = parts.count == 3 ? String(format: "#%02X%02X%02X", parts[0], parts[1], parts[2]) : expected
                if hex != visio { failures.append("\(item.id) \(item.formula): Visio \(visio), MacVisio \(hex ?? "none")") }
            default:
                if (actual["kind"] as? String) == "string", expected.hasPrefix("POLYLINE(") || expected.hasPrefix("NURBS(") {
                    if actual["text"] as? String != expected { failures.append("\(item.id): \(expected) vs \(actual["text"] ?? "")") }
                    continue
                }
                guard let value = actual["internal"] as? Double, let target = item.resultIU else { failures.append("\(item.id) \(item.formula): no numeric result"); continue }
                let tolerance = item.formula.contains("TEXTWIDTH") || item.formula.contains("TEXTHEIGHT") ? 1e-4 : max(1e-12, abs(target) * 1e-9)
                if abs(value - target) > tolerance { failures.append("\(item.id) \(item.formula): Visio \(target), MacVisio \(value)") }
            }
        }
        for item in reference.fields where !excused(item.id) {
            checked += 1
            let actual = try XCTUnwrap(fields[item.id])
            if item.error == true { if actual["error"] == nil { failures.append("\(item.id): Visio refuses the field") }; continue }
            let expected = (item.text ?? "").replacingOccurrences(of: "\r\n", with: "\n")
            if actual["text"] as? String != expected { failures.append("\(item.id) \(item.formula) [\(item.format)]: Visio \(expected.debugDescription), MacVisio \(String(describing: actual["text"] ?? actual["error"]))") }
        }
        XCTAssertGreaterThan(checked, 1800)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) of \(checked) reference cases disagree:\n" + failures.prefix(40).joined(separator: "\n"))
    }
}
