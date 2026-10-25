import Foundation

/// Developer reference probe (WP-15-T02/T03, WP-16-T03): evaluates formula cases and text fields on one
/// shape of a drawing so the typed results can be compared with Visio's for the same cases on the same
/// drawing (scripts/run-formula-reference.py, VisioFormulaReferenceTests).
enum FormulaProbe {
    struct Case: Decodable { let id: String; let formula: String }
    struct Field: Decodable { let id: String; let formula: String; let format: String }
    struct Spec: Decodable { let cases: [Case]; let fields: [Field]? }

    /// Visio's results in the reference guest use en-GB; evaluation formats the same way.
    static func evaluate(_ diagram: Diagram, documentURL: URL?, hostID: String = "2", cases: [Case], fields: [Field]) throws -> (cases: [[String: Any]], fields: [[String: Any]]) {
        let previousLocale = VisioPictureFormat.locale
        VisioPictureFormat.locale = Locale(identifier: "en_GB")
        defer { VisioPictureFormat.locale = previousLocale }
        let page = diagram.pages[0]
        guard let binding = diagram.visioArchive?.pages.first(where: { $0.pageID == page.id }),
              let host = binding.nodeIDs.first(where: { $0.value == hostID })?.key else {
            throw DiagramError.invalid("The probe drawing has no shape Sheet.\(hostID).")
        }
        func context() -> ShapeSheetContext {
            // A fresh context per case keeps one case's failure or cache from affecting another.
            let context = ShapeSheetContext(page: page, binding: binding, document: diagram, mode: .typedFields)
            context.documentURL = documentURL
            return context
        }
        var records: [[String: Any]] = []
        for item in cases {
            var record: [String: Any] = ["id": item.id, "formula": item.formula]
            do {
                let formula = item.formula.hasPrefix("=") ? String(item.formula.dropFirst()) : item.formula
                let value = try context().evaluate(formula, on: host)
                record["ok"] = true
                record["text"] = value.text
                switch value {
                case .number(let number): record["kind"] = "number"; record["internal"] = number
                case .quantity(let number, let unit): record["kind"] = "quantity"; record["unit"] = unit; record["internal"] = number  // internal units
                case .string: record["kind"] = "string"
                case .boolean(let flag): record["kind"] = "boolean"; record["internal"] = flag ? 1.0 : 0.0
                case .date: record["kind"] = "date"; record["internal"] = try value.numeric()
                case .color(let color): record["kind"] = "color"; record["color"] = color.hex
                case .point: record["kind"] = "point"
                }
            } catch {
                record["ok"] = false
                record["error"] = error.localizedDescription
            }
            records.append(record)
        }
        var displays: [[String: Any]] = []
        for field in fields {
            let evaluation = context()
            do {
                let value = try evaluation.evaluate(field.formula, on: host), picture = try evaluation.evaluate(field.format, on: host).text
                displays.append(["id": field.id, "text": try FieldFormatting.format(value, picture: picture)])
            } catch { displays.append(["id": field.id, "error": error.localizedDescription]) }
        }
        return (records, displays)
    }

    static func run(drawing: URL, cases: URL, hostID: String = "2", output: URL) throws {
        let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: cases))
        let diagram = try VisioFormat.readPublic(parts: VisioPackage.read(drawing), title: drawing.lastPathComponent).diagram
        let results = try evaluate(diagram, documentURL: drawing, hostID: hostID, cases: spec.cases, fields: spec.fields ?? [])
        let report: [String: Any] = ["schemaVersion": 1, "drawing": drawing.lastPathComponent, "cases": results.cases, "fields": results.fields]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
}
