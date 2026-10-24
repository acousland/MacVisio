import Foundation

enum InspectorLengthUnit: String, CaseIterable {
    case points = "pt", millimeters = "mm", centimeters = "cm", inches = "in"
    var pointsPerUnit: Double {
        switch self { case .points: return 1; case .millimeters: return 72 / 25.4; case .centimeters: return 72 / 2.54; case .inches: return 72 }
    }
    func display(_ points: Double) -> String { String(format: "%.6g", locale: Locale(identifier: "en_US_POSIX"), points / pointsPerUnit) }

    /// A scalar with an optional explicit unit. Formula/reference editing stays
    /// in ShapeSheet; bare numbers use the unit displayed beside this field.
    static func parse(_ raw: String, defaultUnit: InspectorLengthUnit = .points, angle: Bool = false, paperPoints: Bool = false) -> Double? {
        let pattern = #"^\s*([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)\s*([A-Za-z]*)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let numberRange = Range(match.range(at: 1), in: raw),
              let unitRange = Range(match.range(at: 2), in: raw), let number = Double(raw[numberRange]), number.isFinite else { return nil }
        let unit = raw[unitRange].lowercased()
        let factor: Double
        if angle {
            switch unit { case "", "deg": factor = 1; case "rad": factor = 180 / .pi; default: return nil }
        } else if paperPoints {
            guard unit.isEmpty || unit == "pt" else { return nil }; factor = 1
        } else if unit.isEmpty { factor = defaultUnit.pointsPerUnit }
        else if let explicit = InspectorLengthUnit(rawValue: unit) { factor = explicit.pointsPerUnit }
        else { return nil }
        let result = number * factor
        return result.isFinite ? result : nil
    }
}

/// Shared native editing policy. Existing imported protection cells and guarded
/// target formulas stay authoritative; unresolved protection fails closed.
enum NativeEditProtection {
    static func blockReason(for key: String, node: DiagramNode, in page: DiagramPage) -> String? {
        if ["X", "Y", "Width", "Height", "Rotation", "FlipX", "FlipY"].contains(key),
           let reason = DiagramMemberships.transformBlockReason(node, in: page) { return reason }
        if page.isLocked(node) { return "The shape, its group or its layer is locked." }
        let protections: [String]
        let target: String?
        switch key {
        case "X": protections = ["LockMoveX"]; target = "PinX"
        case "Y": protections = ["LockMoveY"]; target = "PinY"
        case "Width": protections = ["LockWidth", "LockAspect"]; target = "Width"
        case "Height": protections = ["LockHeight", "LockAspect"]; target = "Height"
        case "Rotation": protections = ["LockRotate"]; target = "Angle"
        case "Text": protections = ["LockTextEdit"]; target = nil
        case "Connection": protections = ["LockGlue"]; target = nil
        case "Delete": protections = ["LockDelete"]; target = nil
        default: protections = ["LockFormat"]; target = nil
        }
        var current: DiagramNode? = node, seen = Set<UUID>()
        while let value = current {
            guard seen.insert(value.id).inserted else { return "The shape's group hierarchy needs repair before editing." }
            for name in protections {
                for (key, cell) in value.formatting.sheet where matches(cell: name, key: key) {
                    func constant(_ raw: String) -> Double? {
                        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
                        case "TRUE", "TRUE()": return 1
                        case "FALSE", "FALSE()": return 0
                        default: return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                    guard let flag = constant(cell.value), flag.isFinite else { return "\(name) has no evaluated protection value." }
                    if flag != 0 { return "\(name) protects this property. Review it in ShapeSheet." }
                    let formula = cell.formula.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !formula.isEmpty {
                        let evaluated = constant(formula) ?? (try? ShapeSheet.evaluate(formula, resolve: { _ in
                            throw DiagramError.invalid("Protection requires explicit evaluation.")
                        }))
                        guard let evaluated, evaluated.isFinite, evaluated == 0 else {
                            return "\(name)'s formula needs review before this property can change."
                        }
                    }
                }
            }
            if let parent = value.parentID {
                guard let found = page.nodes.first(where: { $0.id == parent }) else { return "The parent group is unavailable." }
                current = found
            } else { current = nil }
        }
        if let target {
            for (key, cell) in node.formatting.sheet where matches(cell: target, key: key) {
                if cell.formula.range(of: #"^\s*=?\s*(?:THEME)?GUARD\s*\("#, options: [.regularExpression, .caseInsensitive]) != nil {
                    return "\(target) is guarded. Review its formula in ShapeSheet."
                }
            }
        }
        let characterCell: String?
        switch key {
        case "Font": characterCell = "Font"
        case "Font size": characterCell = "Size"
        case "Text color": characterCell = "Color"
        case "Formatting": characterCell = "Style"
        default: characterCell = nil
        }
        if let characterCell {
            for run in node.formatting.textRuns ?? [] {
                for (name, cell) in run.character.cells where matches(cell: characterCell, key: name) {
                    if cell.formula.range(of: #"^\s*=?\s*(?:THEME)?GUARD\s*\("#, options: [.regularExpression, .caseInsensitive]) != nil {
                        return "Character.\(characterCell) is guarded. Review the text run's formula in ShapeSheet."
                    }
                }
            }
        }
        return nil
    }

    private static func matches(cell: String, key: String) -> Bool {
        (key.split(separator: ".").last.map(String.init) ?? key).caseInsensitiveCompare(cell) == .orderedSame
    }

    static func blockReason(changing old: DiagramNode, to new: DiagramNode, in page: DiagramPage) -> String? {
        let changed: [(String, Bool)] = [
            ("X", old.x != new.x), ("Y", old.y != new.y), ("Width", old.width != new.width),
            ("Height", old.height != new.height), ("Rotation", old.rotation != new.rotation),
            ("FlipX", old.formatting.flipX != new.formatting.flipX), ("FlipY", old.formatting.flipY != new.formatting.flipY),
            ("Text", old.text != new.text), ("Font", old.formatting.fontName != new.formatting.fontName),
            ("Font size", old.fontSize != new.fontSize), ("Fill", old.fill != new.fill),
            ("Line", old.stroke != new.stroke || old.strokeWidth != new.strokeWidth),
            ("Text color", old.textColor != new.textColor),
            ("Formatting", old.bold != new.bold || old.formatting.italic != new.formatting.italic
                || old.formatting.underline != new.formatting.underline || old.formatting.alignment != new.formatting.alignment
                || old.formatting.flipX != new.formatting.flipX || old.formatting.flipY != new.formatting.flipY
                || old.formatting.linePattern != new.formatting.linePattern || old.layer != new.layer
                || old.formatting.layerNames != new.formatting.layerNames || old.formatting.data != new.formatting.data
                || old.formatting.hyperlinks != new.formatting.hyperlinks
                || old.text == new.text && old.formatting.textRuns != new.formatting.textRuns)]
        return changed.first(where: { $0.1 && blockReason(for: $0.0, node: old, in: page) != nil })
            .flatMap { blockReason(for: $0.0, node: old, in: page) }
    }
}
