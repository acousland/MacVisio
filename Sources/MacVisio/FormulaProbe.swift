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
                let value = evaluation.displayValue(try evaluation.evaluate(field.formula, on: host)), picture = try evaluation.evaluate(field.format, on: host).text
                displays.append(["id": field.id, "text": try FieldFormatting.format(value, picture: picture)])
            } catch { displays.append(["id": field.id, "error": error.localizedDescription]) }
        }
        return (records, displays)
    }

    struct HostCase: Decodable { let id: String; let host: String; let formula: String }

    /// The host matrix: each case's formula is put in a shape User cell, a page User cell, a Geometry
    /// row, a control handle or a text field of the probe drawing through a document edit, and the value
    /// is read back after MacVisio's own document calculation, as the editor would show it.
    static func runHosts(drawing: URL, cases: URL, output: URL) throws {
        struct Spec: Decodable { let hostCases: [HostCase]? }
        let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: cases))
        let previousLocale = VisioPictureFormat.locale
        VisioPictureFormat.locale = Locale(identifier: "en_GB")
        defer { VisioPictureFormat.locale = previousLocale }
        let document = MacVisioDocument()
        try document.read(from: drawing, ofType: MacVisioDocument.visioType)
        let base = document.diagram, baseIssues = Set(document.calculationIssues)
        guard let nodeIndex = base.pages[0].nodes.firstIndex(where: { $0.formatting.controls.contains { $0.name == "Probe" } }) else {
            throw DiagramError.invalid("The probe drawing has no host-matrix shape.")
        }
        var records: [[String: Any]] = []
        for item in spec.hostCases ?? [] {
            document.replace(with: base, action: "Reset probe")
            var next = base, node = next.pages[0].nodes[nodeIndex]
            var record: [String: Any] = ["id": item.id, "host": item.host, "formula": item.formula]
            do {
                switch item.host {
                case "shape": node.formatting.sheet["User.Probe", default: ShapeSheetCell(value: "")].formula = item.formula
                case "page": next.pages[0].sheet?["User.Probe", default: ShapeSheetCell(value: "")].formula = item.formula
                case "geometry":
                    guard var cell = GeometrySheet.cell("Geometry1.X2", on: node) else { throw DiagramError.invalid("No Geometry1.X2.") }
                    cell.formula = item.formula; try GeometrySheet.set("Geometry1.X2", cell, on: &node)
                case "control":
                    guard let c = node.formatting.controls.firstIndex(where: { $0.name == "Probe" }) else { throw DiagramError.invalid("No control.") }
                    node.formatting.controls[c].cells["X", default: ShapeSheetCell(value: "")].formula = item.formula
                case "field":
                    guard var fields = node.formatting.textFields, !fields.isEmpty else { throw DiagramError.invalid("No field.") }
                    fields[0].cells["Value", default: ShapeSheetCell(value: "")].formula = item.formula; node.formatting.textFields = fields
                default: throw DiagramError.invalid("Unknown host \(item.host).")
                }
                next.pages[0].nodes[nodeIndex] = node
                document.replace(with: next, action: "Probe \(item.host)")
                let result = document.diagram.pages[0], calculated = result.nodes[nodeIndex]
                switch item.host {
                case "shape": record["value"] = calculated.formatting.sheet["User.Probe"]?.value
                case "page": record["value"] = result.sheet?["User.Probe"]?.value
                case "geometry": record["value"] = GeometrySheet.cell("Geometry1.X2", on: calculated)?.value
                case "control": record["value"] = calculated.formatting.controls.first { $0.name == "Probe" }?.cells["X"]?.value
                default: record["value"] = calculated.text
                }
                let issues = Set(document.calculationIssues).subtracting(baseIssues).sorted()
                if !issues.isEmpty { record["issues"] = issues }
                if let error = document.lastCalculationJobError { record["error"] = error.localizedDescription }
            } catch { record["error"] = error.localizedDescription }
            records.append(record)
        }
        let report: [String: Any] = ["schemaVersion": 1, "drawing": drawing.lastPathComponent, "hostCases": records]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }

    static func run(drawing: URL, cases: URL, hostID: String = "2", output: URL) throws {
        let spec = try JSONDecoder().decode(Spec.self, from: Data(contentsOf: cases))
        let diagram = try VisioFormat.readPublic(parts: VisioPackage.read(drawing), title: drawing.lastPathComponent).diagram
        let results = try evaluate(diagram, documentURL: drawing, hostID: hostID, cases: spec.cases, fields: spec.fields ?? [])
        let report: [String: Any] = ["schemaVersion": 1, "drawing": drawing.lastPathComponent, "cases": results.cases, "fields": results.fields]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
}
