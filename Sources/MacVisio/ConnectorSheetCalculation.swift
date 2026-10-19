import Foundation

/// The shared scalar and line-style slice of a connector sheet. Endpoint,
/// routing and glue updates remain owned by the connector geometry subsystem.
enum ConnectorSheetCalculation {
    struct Failure { var cell: String; var message: String }
    static let lineKeys: Set<String> = ["LineWeight", "LineColor", "LinePattern", "BeginArrow", "EndArrow"]

    static func prepare(_ input: DiagramEdge, previous: DiagramEdge?) -> DiagramEdge {
        guard let previous else { return input }
        var edge = input
        let current: [String: String] = ["LineWeight": ShapeSheetEngine.format(edge.width/72),
            "LineColor": edge.color, "LinePattern": String(edge.dash ?? 1),
            "BeginArrow": edge.startArrow == true ? "4" : "0", "EndArrow": edge.arrow ? "4" : "0"]
        let changed: [String: Bool] = ["LineWeight": edge.width != previous.width,
            "LineColor": edge.color != previous.color, "LinePattern": edge.dash != previous.dash,
            "BeginArrow": edge.startArrow != previous.startArrow, "EndArrow": edge.arrow != previous.arrow]
        for (key, didChange) in changed where didChange && edge.formatting.sheet[key] == previous.formatting.sheet[key] {
            if edge.formatting.sheet[key]?.formula.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("GUARD(") == true { continue }
            edge.formatting.sheet[key] = ShapeSheetCell(value: current[key]!)
        }
        for property in edge.formatting.data where previous.formatting.data.first(where: { $0.key == property.key })?.value != property.value {
            let key = "Prop." + property.key
            if edge.formatting.sheet[key] == previous.formatting.sheet[key] {
                edge.formatting.sheet[key] = ShapeSheetCell(value: property.value, unit: edge.formatting.sheet[key]?.unit ?? "")
            }
        }
        return edge
    }

    static func evaluate(_ input: DiagramEdge, context: ShapeSheetContext,
                         palette: ShapeSheetColorPalette) -> (edge: DiagramEdge, failures: [Failure]) {
        var edge = input, failures: [Failure] = []
        for key in edge.formatting.sheet.keys.sorted() where lineKeys.contains(key) || key.hasPrefix("User.") || key.hasPrefix("Prop.") {
            guard let cell = edge.formatting.sheet[key] else { continue }
            let formula = cell.formula.trimmingCharacters(in: .whitespacesAndNewlines)
            // Literal cells already supplied the imported presentation. Avoid
            // rewriting their source spellings and units on an unrelated edit.
            guard !formula.isEmpty, !["INH", "NO FORMULA"].contains(formula.uppercased()) else { continue }
            do {
                let value = try context.value(edge.id, key)
                switch key {
                case "LineWeight":
                    let points = try value.numeric()*72
                    guard (0...100).contains(points) else { throw DiagramError.invalid("Calculated connector line weight is outside the supported range.") }
                    edge.width = points
                case "LineColor":
                    let color: ShapeSheetColor?
                    if case .color(let resolved) = value { color = resolved }
                    else if case .string(let text) = value { color = ShapeSheetColor(hex: text) }
                    else { color = palette.color(at: try value.numeric()) }
                    guard let color else { throw DiagramError.invalid("Calculated connector color is unavailable in the document palette.") }
                    edge.color = color.hex
                case "LinePattern":
                    guard let pattern = Int(exactly: try value.numeric()), (0...24).contains(pattern) else { throw DiagramError.invalid("Calculated connector line pattern is outside the supported range.") }
                    edge.dash = pattern
                case "BeginArrow", "EndArrow":
                    guard let arrow = Int(exactly: try value.numeric()), (0...45).contains(arrow) else { throw DiagramError.invalid("Calculated connector arrow is outside the supported range.") }
                    if key == "BeginArrow" { edge.startArrow = arrow != 0 } else { edge.arrow = arrow != 0 }
                default: break
                }
                edge.formatting.sheet[key]?.value = ShapeSheetContext.cached(value)
            } catch { failures.append(Failure(cell: key, message: error.localizedDescription)) }
        }
        for index in edge.formatting.data.indices {
            let key = "Prop." + edge.formatting.data[index].key
            if let cell = edge.formatting.sheet[key], !cell.formula.isEmpty,
               !["INH", "NO FORMULA"].contains(cell.formula.uppercased()),
               !failures.contains(where: { $0.cell == key }) {
                edge.formatting.data[index].value = cell.value
            }
        }
        return (edge, failures)
    }
}
