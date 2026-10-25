import Foundation

/// A ShapeSheet error value. `kind` is the Visio error the formula shows, which ISERR, ISERRNA,
/// ISERROR and ISERRVALUE distinguish.
struct ShapeSheetError: LocalizedError {
    enum Kind: String { case value = "#VALUE!", na = "#N/A", divideByZero = "#DIV/0!", reference = "#REF!", number = "#NUM!", name = "#NAME?", dimension = "#DIM!" }
    let kind: Kind
    let message: String
    var errorDescription: String? { message }

    /// Classifies any evaluation failure the way Visio reports it.
    static func kind(of error: Error) -> Kind {
        if let error = error as? ShapeSheetError { return error.kind }
        let message = error.localizedDescription
        if message.contains("#N/A") { return .na }
        if message.contains("Division by zero") || message.contains("#DIV/0") { return .divideByZero }
        if message.contains("#NUM") || message.contains("non-finite") { return .number }
        if message.contains("#DIM") { return .dimension }
        if message.contains("#NAME") || message.contains("Unsupported ShapeSheet function") { return .name }
        if message.contains("#REF") || message.contains("Unknown ShapeSheet reference") || message.contains("Unknown ShapeSheet cell") { return .reference }
        return .value
    }
}

/// Visio 2019 functions with no side effects in evaluation, implemented from the reference probe
/// (docs/evidence/reference/formulas). Action functions (GOTOPAGE, RUNMACRO, ...) only act when a
/// user runs an action; evaluating them returns the value Visio reports.
extension ShapeSheetContext {
    func referenceFunction(_ name: String, values: [SheetValue], id: UUID) throws -> SheetValue? {
        func arity(_ range: ClosedRange<Int>) throws {
            guard range.contains(values.count) else { throw ShapeSheetError(kind: .value, message: "\(name) has the wrong number of arguments.") }
        }
        func number(_ index: Int) throws -> Double { try values[index].numeric() }
        switch name {
        // Date and time.
        case "DATETIME":
            try arity(1...1)
            return .date(SheetValue.date(serial: try serial(values[0])))
        case "DATEVALUE":
            try arity(1...2)
            return .date(SheetValue.date(serial: try serial(values[0]).rounded(.down)))
        case "TIMEVALUE":
            try arity(1...2)
            let value = try serial(values[0])
            return .date(SheetValue.date(serial: value - value.rounded(.down)))
        case "TIME":
            try arity(3...3)
            // Hours wrap as 16-bit values: TIME(-1,0,0) is 15:00 (TIME-4).
            let hours = Double(Int64(try number(0).rounded(.towardZero)) & 0xFFFF)
            let seconds = hours * 3600 + (try number(1)) * 60 + (try number(2))
            let day = (seconds / 86400).truncatingRemainder(dividingBy: 1)
            return .date(SheetValue.date(serial: day < 0 ? day + 1 : day))
        case "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND", "WEEKDAY", "DAYOFYEAR":
            try arity(1...2)
            let parts = Self.dateParts(try serial(values[0]))
            switch name {
            case "YEAR": return .number(Double(parts.year))
            case "MONTH": return .number(Double(parts.month))
            case "DAY": return .number(Double(parts.day))
            case "HOUR": return .number(Double(parts.hour))
            case "MINUTE": return .number(Double(parts.minute))
            case "SECOND": return .number(Double(parts.second))
            case "WEEKDAY": return .number(Double(parts.weekday))  // Monday is 1, Sunday 7 (WEEKDAY-1/3)
            default: return .number(Double(parts.dayOfYear))
            }
        // Document properties come from the drawing's public package parts.
        case "TITLE": return .string(documentProperty("core", "title") ?? document?.title ?? "")
        case "SUBJECT": return .string(documentProperty("core", "subject") ?? "")
        case "CREATOR": return .string(documentProperty("core", "creator") ?? "")
        case "KEYWORDS": return .string(documentProperty("core", "keywords") ?? "")
        case "DESCRIPTION": return .string(documentProperty("core", "description") ?? "")
        case "CATEGORY": return .string(documentProperty("core", "category") ?? "")
        case "MANAGER": return .string(documentProperty("app", "Manager") ?? "")
        case "COMPANY": return .string(documentProperty("app", "Company") ?? "")
        case "FILENAME": try arity(0...0); return .string(documentURL?.lastPathComponent ?? "")
        case "DIRECTORY": try arity(0...0); return .string(documentURL.map { $0.deletingLastPathComponent().path + "/" } ?? "")
        case "DOCCREATION", "DOCLASTSAVE", "DOCLASTEDIT", "DOCLASTPRINT":
            let key = ["DOCCREATION": "created", "DOCLASTPRINT": "lastPrinted"][name] ?? "modified"
            guard let text = documentProperty("core", key), let date = ISO8601DateFormatter().date(from: text) else { return .date(now) }
            return .date(date)
        case "HASCATEGORY":
            try arity(1...1)
            let categories = (try? value(id, "User.msvShapeCategories").text) ?? ""
            return .boolean(categories.split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(values[0].text) == .orderedSame })
        // Shape information.
        case "NAME": try arity(0...1); return .string(shapeAttribute(id, "NameU") ?? publicIDsByObject[id].map { "Sheet.\($0)" } ?? "")
        case "MASTERNAME": try arity(0...1); return .string(masterName(id) ?? "<no master>")
        case "TYPE": try arity(0...0); return .number(72)  // a shape (TYPE-7/8); groups and guides are not yet observed
        case "SHEETREF": throw ShapeSheetError(kind: .na, message: "SHEETREF has no target here (#N/A).")
        // Numbers.
        case "BITNOT": try arity(1...1); return .number(Double(~Int64(try number(0).rounded(.towardZero)) & 0xFFFF))
        case "COSH": try arity(1...1); return .number(cosh(try number(0)))
        case "SINH": try arity(1...1); return .number(sinh(try number(0)))
        case "TANH": try arity(1...1); return .number(tanh(try number(0)))
        case "INTUP":
            try arity(1...1)
            let value = try number(0)
            return values[0].unit.map { .quantity(ceil(value), $0) } ?? .number(ceil(value))
        case "MAGNITUDE":
            // MAGNITUDE(constA, A, constB, B) (MATHX-12); the two-argument form is rejected.
            guard values.count == 4 else { throw ShapeSheetError(kind: .value, message: "MAGNITUDE expects four arguments.") }
            return .number(hypot(try number(0) * number(1), try number(2) * number(3)))
        case "RAND": try arity(0...0); return .number(Double.random(in: 0..<1))
        case "LOOKUP":
            try arity(2...3)
            let separator = values.count == 3 ? values[2].text : ";"
            let items = separator.isEmpty ? [values[1].text] : values[1].text.components(separatedBy: separator)
            return .number(Double(items.firstIndex { $0.caseInsensitiveCompare(values[0].text) == .orderedSame } ?? -1))
        case "NA": try arity(0...0); throw ShapeSheetError(kind: .na, message: "#N/A")
        case "CY": try arity(1...2); return .number(try number(0))
        case "FORMATEX":
            try arity(4...4)
            let source = values[2].text.uppercased(), target = values[3].text.uppercased()
            guard let from = SheetValue.factor(source), SheetValue.factor(target) != nil else { throw ShapeSheetError(kind: .value, message: "FORMATEX needs known units.") }
            // The number is read in the source unit and shown in the target unit (MATHX-30/31).
            let display: Double
            if case .quantity(let canonical, let unit) = values[0] { display = canonical * (SheetValue.factor(unit) ?? 1) } else { display = try number(0) }
            return .string(try VisioPictureFormat.format(.quantity(display / from, target), picture: values[1].text))
        case "EVALTEXT":
            try arity(1...1)
            return (try? evaluate(values[0].text, on: id)) ?? .number(0)
        case "FONTTOID":
            // Font IDs index the running Visio's font table, which a drawing does not record.
            throw ShapeSheetError(kind: .value, message: "FONTTOID needs the host's installed-font table.")
        case "DEPENDSON": return .boolean(false)
        case "USERUI": try arity(3...3); return try number(0) == 0 ? values[1] : values[2]
        case "GRAVITY":
            try arity(1...3)
            let degrees = ShapeSheet.angle360(try number(0)) * 180 / .pi
            let lower = values.count == 3 ? try number(1) * 180 / .pi : 90, upper = values.count == 3 ? try number(2) * 180 / .pi : 270
            return .quantity(degrees > lower && degrees <= upper ? .pi : 0, "DEG")
        // Colors.
        case "BLEND":
            try arity(3...3)
            let first = try color(values[0]), second = try color(values[1]), t = try number(2)
            func mix(_ a: Int, _ b: Int) -> Int { Int((Double(a) * (1 - t) + Double(b) * t).rounded(.towardZero)) }
            return .color(ShapeSheetColor(red: mix(first.red, second.red), green: mix(first.green, second.green), blue: mix(first.blue, second.blue)))
        case "TINT", "TONE":
            try arity(2...2)
            let base = try color(values[0]).hsl, amount = Int(try number(1).rounded(.towardZero))
            let clamp = { (value: Int) in max(0, min(240, value)) }
            let result = name == "TINT"
                ? ShapeSheetColor.fromHSL(hue: base.hue, saturation: base.saturation, luminosity: clamp(base.luminosity + amount))
                : ShapeSheetColor.fromHSL(hue: base.hue, saturation: clamp(base.saturation - amount), luminosity: base.luminosity)
            return .color(result)
        case "HUEDIFF": try arity(2...2); return .number(Double(try color(values[0]).hsl.hue - color(values[1]).hsl.hue))
        case "SATDIFF": try arity(2...2); return .number(Double(try color(values[0]).hsl.saturation - color(values[1]).hsl.saturation))
        case "THEME": try arity(1...1); return .number(0)
        // Geometry values that need no path.
        case "PNT": try arity(2...2); return .point(try number(0), try number(1))
        case "PNTX", "PNTY":
            try arity(1...1)
            guard case .point(let x, let y) = values[0] else { return .number(try number(0)) }  // GEOM-20
            return .quantity(name == "PNTX" ? x : y, page.drawingScale?.drawingUnit ?? "IN")
        case "PAR", "LOC":
            try arity(1...1)
            guard case .point(let x, let y) = values[0] else { throw ShapeSheetError(kind: .value, message: "\(name) needs a point.") }
            guard name == "PAR", let frame = localFrame(id) else { return .point(x, y) }
            return .point(x - frame.locPinX + frame.pinX, y - frame.locPinY + frame.pinY)
        case "BOUNDINGBOXRECT":
            try arity(1...1)
            return .number(localFrame(id).map { $0.pinX - $0.locPinX } ?? 0)
        case "BOUNDINGBOXDIST":
            try arity(1...1)
            guard let frame = localFrame(id) else { return .number(0) }
            switch Int(try number(0)) {
            case 0: return .number(frame.width)
            case 1: return .number(frame.height)
            case 2: return .number(frame.locPinX)
            case 3: return .number(frame.width - frame.locPinX)
            case 4: return .number(frame.locPinY)
            default: return .number(frame.height - frame.locPinY)
            }
        case "INTERSECTX", "INTERSECTY":
            try arity(6...6)
            let x1 = try number(0), y1 = try number(1), a1 = try number(2), x2 = try number(3), y2 = try number(4), a2 = try number(5)
            let determinant = cos(a1) * sin(a2) - sin(a1) * cos(a2)
            guard abs(determinant) > 1e-12 else { throw ShapeSheetError(kind: .divideByZero, message: "Parallel lines do not intersect (#DIV/0!).") }
            let t = ((x2 - x1) * sin(a2) - (y2 - y1) * cos(a2)) / determinant
            return .number(name == "INTERSECTX" ? x1 + t * cos(a1) : y1 + t * sin(a1))
        case "RECTSECT":
            try arity(5...5)
            let width = abs(try number(0)), height = abs(try number(1)), x = try number(2), y = try number(3)
            if x == 0, y == 0 { return .number(0) }
            if abs(y) * width >= abs(x) * height { return .number(y > 0 ? 0 : 2) }
            return .number(x > 0 ? 1 : 3)
        // Structure: MacVisio records memberships explicitly; plain shapes have none.
        case "CONTAINERCOUNT", "CONTAINERMEMBERCOUNT", "LISTMEMBERCOUNT", "CALLOUTCOUNT": return .number(0)
        case "LISTORDER": return .number(-1)
        case "CONTAINERSHEETREF", "LISTSHEETREF", "CALLOUTTARGETREF": throw ShapeSheetError(kind: .reference, message: "\(name) has no target (#REF!).")
        // Action functions evaluate without acting.
        case "DEFAULTEVENT", "GOTOPAGE", "HELP", "OPENFILE", "OPENGROUPWIN", "OPENPAGE", "OPENSHEETWIN", "HYPERLINK":
            return .boolean(false)
        case "PLAYSOUND": return .number(1)
        case "QUEUEMARKEREVENT": return .boolean(true)
        case "RUNMACRO", "CALLTHIS", "RUNADDON", "RUNADDONWARGS":
            // These run VBA or add-in code in Visio. MacVisio never executes document code, so the
            // formula keeps its cached result (open blocker: unmodified VBA/COM/add-ins).
            throw DiagramError.invalid("\(name) runs document code, which MacVisio does not execute; the cached value is retained.")
        default: return nil
        }
    }

    /// Path functions read a Geometry section reference, so they run on unevaluated arguments.
    func referencePathFunction(_ name: String, arguments: [ShapeSheet.Expression], evaluate: (ShapeSheet.Expression) throws -> SheetValue, id: UUID) throws -> SheetValue? {
        guard ["PATHLENGTH", "SEGMENTCOUNT", "POINTALONGPATH", "ANGLEALONGPATH", "NEARESTPOINTONPATH", "PATHSEGMENT", "LOCTOLOC", "LOCTOPAR", "ANGLETOLOC", "ANGLETOPAR"].contains(name) else { return nil }
        if name.hasPrefix("LOCTO") || name.hasPrefix("ANGLETO") {
            guard arguments.count == 3, case .reference(let sourceReference) = arguments[1], case .reference(let targetReference) = arguments[2] else {
                throw ShapeSheetError(kind: .value, message: "\(name) needs a value and two cell references.")
            }
            let value = try evaluate(arguments[0])
            if name.hasPrefix("ANGLETO") { return value }  // no rotation is modelled between unrotated owners
            guard case .point(let x, let y) = value else { throw ShapeSheetError(kind: .value, message: "\(name) needs a point.") }
            let from = try target(sourceReference, from: id).0, to = try target(targetReference, from: id).0
            let origin = { (owner: UUID) -> (Double, Double) in self.localFrame(owner).map { ($0.pinX - $0.locPinX, $0.pinY - $0.locPinY) } ?? (0, 0) }
            let (fx, fy) = origin(from), (tx, ty) = origin(to)
            return .point(x + fx - tx, y + fy - ty)
        }
        guard let first = arguments.first, case .reference(let reference) = first else { throw ShapeSheetError(kind: .value, message: "\(name) needs a Geometry Path reference.") }
        let (owner, key) = try target(reference, from: id)
        guard let address = GeometrySheet.address(key), address.cell.caseInsensitiveCompare("Path") == .orderedSame, let node = nodes[owner] else {
            throw ShapeSheetError(kind: .reference, message: "\(name) needs a GeometryN.Path reference (#REF!).")
        }
        let segments = Self.pathSegments(node, section: address.section)
        let lengths = segments.map { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) }, total = lengths.reduce(0, +)
        func numberArgument(_ index: Int) throws -> Double { try evaluate(arguments[index]).numeric() }
        func locate(_ fraction: Double) -> (segment: Int, point: CGPoint, angle: Double) {
            var distance = max(0, min(1, fraction)) * total
            for (index, segment) in segments.enumerated() {
                if distance <= lengths[index] || index == segments.count - 1 {
                    let t = lengths[index] == 0 ? 0 : distance / lengths[index]
                    let point = CGPoint(x: segment.0.x + (segment.1.x - segment.0.x) * t, y: segment.0.y + (segment.1.y - segment.0.y) * t)
                    return (index, point, atan2(segment.1.y - segment.0.y, segment.1.x - segment.0.x))
                }
                distance -= lengths[index]
            }
            return (0, .zero, 0)
        }
        switch name {
        case "PATHLENGTH":
            guard arguments.count <= 2 else { throw ShapeSheetError(kind: .value, message: "PATHLENGTH expects a path and an optional segment.") }
            if arguments.count == 2 {
                let index = Int(try numberArgument(1))
                guard lengths.indices.contains(index - 1) else { throw ShapeSheetError(kind: .value, message: "PATHLENGTH segment is out of range.") }
                return .number(lengths[index - 1])
            }
            return .number(total)
        case "SEGMENTCOUNT": return .number(Double(segments.count))
        case "PATHSEGMENT":
            guard arguments.count == 2 else { throw ShapeSheetError(kind: .value, message: "PATHSEGMENT expects a path and a position.") }
            return .number(Double(locate(try numberArgument(1)).segment + 1))
        case "POINTALONGPATH", "ANGLEALONGPATH":
            guard (2...3).contains(arguments.count) else { throw ShapeSheetError(kind: .value, message: "\(name) expects a path, a position and an optional offset.") }
            let located = locate(try numberArgument(1))
            if name == "ANGLEALONGPATH" { return .quantity(ShapeSheet.angle360(located.angle), "DEG") }
            // A positive offset moves to the left of the direction of travel (GEOM-17).
            let offset = arguments.count == 3 ? try numberArgument(2) : 0
            return .point(located.point.x - sin(located.angle) * offset, located.point.y + cos(located.angle) * offset)
        default:  // NEARESTPOINTONPATH returns the position along the path, from 0 to 1 (GEOM-22).
            guard arguments.count == 3, total > 0 else { throw ShapeSheetError(kind: .value, message: "NEARESTPOINTONPATH expects a path and a point.") }
            let x = try numberArgument(1), y = try numberArgument(2)
            var best = (distance: Double.infinity, along: 0.0), before = 0.0
            for (index, segment) in segments.enumerated() {
                let dx = segment.1.x - segment.0.x, dy = segment.1.y - segment.0.y, length = lengths[index]
                let t = length == 0 ? 0 : max(0, min(1, ((x - segment.0.x) * dx + (y - segment.0.y) * dy) / (length * length)))
                let distance = hypot(segment.0.x + dx * t - x, segment.0.y + dy * t - y)
                if distance < best.distance - 1e-12 { best = (distance, before + t * length) }
                before += length
            }
            return .number(best.along / total)
        }
    }

    // MARK: Helpers

    private func serial(_ value: SheetValue) throws -> Double {
        if case .string(let text) = value {
            guard let serial = Self.serial(text) else { throw ShapeSheetError(kind: .value, message: "The text is not a date or time (#VALUE!).") }
            return serial
        }
        return try value.numeric()
    }

    /// Parses date and time text in the formatting locale's day/month order or ISO 8601.
    static func serial(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let dayFirst = (DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: VisioPictureFormat.locale) ?? "dd/MM/yyyy").hasPrefix("d")
        let patterns = [#"^(\d{4})-(\d{1,2})-(\d{1,2})"#, #"^(\d{1,2})[/.](\d{1,2})[/.](\d{2,4})"#]
        var day = 0.0, rest = Substring(trimmed)
        for (index, pattern) in patterns.enumerated() {
            guard let match = try? NSRegularExpression(pattern: pattern).firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else { continue }
            let numbers = (1...3).map { Int((trimmed as NSString).substring(with: match.range(at: $0)))! }
            var (year, month, date) = index == 0 ? (numbers[0], numbers[1], numbers[2]) : dayFirst ? (numbers[2], numbers[1], numbers[0]) : (numbers[2], numbers[0], numbers[1])
            if year < 100 { year += year < 30 ? 2000 : 1900 }
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
            guard (1...12).contains(month), (1...31).contains(date), let value = calendar.date(from: DateComponents(year: year, month: month, day: date)) else { return nil }
            day = (value.timeIntervalSince1970 + 2209161600) / 86400
            rest = trimmed[trimmed.index(trimmed.startIndex, offsetBy: match.range.length)...]
            break
        }
        let time = rest.trimmingCharacters(in: .whitespaces)
        if time.isEmpty { return day == 0 && trimmed.isEmpty ? nil : (day == 0 ? nil : day) }
        let parts = time.split(separator: ":").map { Double($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
        let seconds = parts[0]! * 3600 + parts[1]! * 60 + (parts.count == 3 ? parts[2]! : 0)
        return day + seconds / 86400
    }

    static func dateParts(_ serial: Double) -> (year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, weekday: Int, dayOfYear: Int) {
        let whole = serial.rounded(.down), seconds = Int(((serial - whole) * 86400).rounded())
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: whole * 86400 - 2209161600)
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
        return (parts.year!, parts.month!, parts.day!, seconds / 3600, seconds / 60 % 60, seconds % 60, (parts.weekday! + 5) % 7 + 1, dayOfYear)
    }

    private func color(_ value: SheetValue) throws -> ShapeSheetColor {
        if case .color(let color) = value { return color }
        let palette = ShapeSheetColorPalette()
        return palette.color(at: (try? value.numeric()) ?? 0) ?? ShapeSheetColor(red: 0, green: 0, blue: 0)
    }

    private func documentProperty(_ part: String, _ key: String) -> String? {
        guard let data = document?.visioArchive?.parts["docProps/\(part).xml"], let root = try? VisioXML.document(data).rootElement() else { return nil }
        return root.elementsLocal(key).first?.stringValue
    }

    private func shapeElement(_ id: UUID) -> XMLElement? {
        guard let binding = pageBinding, let shapeID = binding.nodeIDs[id] ?? binding.edgeIDs[id],
              let data = document?.visioArchive?.parts[binding.part], let root = try? VisioXML.document(data).rootElement() else { return nil }
        return root.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == shapeID }
    }

    private func shapeAttribute(_ id: UUID, _ name: String) -> String? { shapeElement(id)?.attr(name) ?? shapeElement(id)?.attr("Name") }

    private func masterName(_ id: UUID) -> String? {
        guard let master = shapeElement(id)?.attr("Master"), let parts = document?.visioArchive?.parts,
              let data = parts["visio/masters/masters.xml"], let root = try? VisioXML.document(data).rootElement() else { return nil }
        return root.elementsLocal("Master").first { $0.attr("ID") == master }.flatMap { $0.attr("NameU") ?? $0.attr("Name") }
    }

    /// A shape's pin and local pin in inches, in its parent's coordinates (y up).
    func localFrame(_ id: UUID) -> (pinX: Double, pinY: Double, locPinX: Double, locPinY: Double, width: Double, height: Double)? {
        guard let node = nodes[id] else { return nil }
        let width = node.width / 72, height = node.height / 72
        let pinX = (try? number(id, "PinX")) ?? (node.x / 72 + width / 2), pinY = (try? number(id, "PinY")) ?? (page.height - node.y) / 72 - height / 2
        let locPinX = (try? number(id, "LocPinX")) ?? width / 2, locPinY = (try? number(id, "LocPinY")) ?? height / 2
        return (pinX, pinY, locPinX, locPinY, width, height)
    }

    /// Straight segments of one Geometry section in local inches (y up); curves are flattened.
    static func pathSegments(_ node: DiagramNode, section: Int) -> [(CGPoint, CGPoint)] {
        let width = node.width / 72, height = node.height / 72
        if let geometry = node.formatting.geometry?.first(where: { $0.index == section }) {
            var points: [[CGPoint]] = [], current = CGPoint.zero
            for row in geometry.rows.sorted(by: { $0.index < $1.index }) {
                let relative = row.type.hasPrefix("Rel")
                let x = (Double(row.cells["X"]?.value ?? "") ?? 0) * (relative ? width : 1), y = (Double(row.cells["Y"]?.value ?? "") ?? 0) * (relative ? height : 1)
                let end = CGPoint(x: x, y: y)
                if row.type.hasSuffix("MoveTo") { points.append([end]) }
                else if row.cells["X"] != nil { if points.isEmpty { points.append([current]) }; points[points.count - 1].append(end) }
                current = end
            }
            return points.flatMap { stroke in zip(stroke, stroke.dropFirst()).map { ($0, $1) } }
        }
        // Built-in rectangles: Visio's own path runs counter-clockwise from the bottom-left corner.
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height), CGPoint(x: 0, y: 0)]
        return Array(zip(corners, corners.dropFirst()))
    }
}
