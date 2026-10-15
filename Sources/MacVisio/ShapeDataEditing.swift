import Foundation

enum ShapeDataEditing {
    static let supportedTypes:[Int] = Array(0...7)
    static let typeNames:[String] = ["Text","Fixed list","Number","Boolean","Variable list","Date","Duration","Currency"]

    static func formatChoices(_ format:String) -> [String] {
        format.split(separator:";",omittingEmptySubsequences:false)
            .map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func displayedValue(_ property:ShapeDataProperty) -> String {
        // Keep cached Date/Duration/Currency values literal because Format pictures are opaque here.
        guard property.type == 3 else { return property.value }
        switch property.value.trimmingCharacters(in:.whitespacesAndNewlines).uppercased() {
        case "1", "TRUE": return "TRUE"
        case "0", "FALSE": return "FALSE"
        default: return property.value
        }
    }

    /// Validates typed values while keeping untouched legacy values and source spelling intact.
    /// Date values use the ISO form found in Visio XML. Durations are numeric day values and
    /// currency values are numeric amounts; their Format pictures remain opaque.
    static func validated(_ properties:[ShapeDataProperty],previous:[ShapeDataProperty]) throws -> [ShapeDataProperty] {
        let oldByKey = Dictionary(previous.map{($0.key,$0)},uniquingKeysWith:{$1})
        var result = properties
        for index in result.indices {
            var property = result[index]
            let old = oldByKey[property.key]
            let valueWasUnchanged = old.map { $0.type == property.type && equivalentBoolean($0.value,property.value,for:property.type) } ?? false
            switch property.type {
            case 1:
                let choices = formatChoices(property.format)
                if !choices.contains(property.value),!valueWasUnchanged {
                    throw DiagramError.invalid("\(property.label.isEmpty ? property.key : property.label) must match one of its Format list entries.")
                }
            case 2:
                if !valueWasUnchanged && !isNumericLiteral(property.value) {
                    throw DiagramError.invalid("\(property.label.isEmpty ? property.key : property.label) must be a finite number or a supported Visio measurement.")
                }
            case 3:
                let value = property.value.trimmingCharacters(in:.whitespacesAndNewlines).uppercased()
                if valueWasUnchanged,let old {
                    property.value = old.value
                } else if ["TRUE","FALSE","1","0"].contains(value) {
                    property.value = value == "TRUE" || value == "1" ? "TRUE" : "FALSE"
                } else {
                    throw DiagramError.invalid("\(property.label.isEmpty ? property.key : property.label) must be TRUE or FALSE.")
                }
            case 4:
                if !valueWasUnchanged,!property.value.isEmpty {
                    let choices = formatChoices(property.format)
                    if !choices.contains(property.value) {
                        let existingFormat = property.format.trimmingCharacters(in:.whitespacesAndNewlines)
                        if existingFormat.isEmpty { property.format = property.value }
                        else if existingFormat.hasSuffix(";") { property.format += property.value }
                        else { property.format += ";" + property.value }
                    }
                }
            case 5:
                if !valueWasUnchanged && !isISODateOrDateTime(property.value) {
                    throw DiagramError.invalid("\(property.label.isEmpty ? property.key : property.label) must be an ISO date (YYYY-MM-DD) or date and time (YYYY-MM-DDTHH:MM:SS).")
                }
            case 6:
                if !valueWasUnchanged && !isFiniteScalar(property.value) {
                    throw DiagramError.invalid("\(property.label.isEmpty ? property.key : property.label) must be a finite duration in days.")
                }
            case 7:
                if !valueWasUnchanged && !isFiniteScalar(property.value) {
                    throw DiagramError.invalid("\(property.label.isEmpty ? property.key : property.label) must be a finite numeric currency amount.")
                }
            default:
                break
            }
            result[index] = property
        }
        return result
    }

    private static func equivalentBoolean(_ lhs:String,_ rhs:String,for type:Int) -> Bool {
        guard type == 3 else { return lhs == rhs }
        if lhs == rhs { return true }
        func value(_ raw:String) -> Bool? {
            switch raw.trimmingCharacters(in:.whitespacesAndNewlines).uppercased() {
            case "TRUE", "1": return true
            case "FALSE", "0": return false
            default: return nil
            }
        }
        return value(lhs) != nil && value(lhs) == value(rhs)
    }

    private static func isNumericLiteral(_ source:String) -> Bool {
        let text = source.trimmingCharacters(in:.whitespacesAndNewlines)
        if let value = Double(text) { return value.isFinite }
        guard let expression = try? ShapeSheet.parse(text) else { return false }
        switch expression {
        case .number(let value),.measure(let value,_): return value.isFinite
        case .unary(let operation,.number(let value)) where operation == "+" || operation == "-": return value.isFinite
        case .unary(let operation,.measure(let value,_)) where operation == "+" || operation == "-": return value.isFinite
        default: return false
        }
    }

    private static func isFiniteScalar(_ source:String) -> Bool {
        let text = source.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        if let value = Double(text) { return value.isFinite }
        guard let expression = try? ShapeSheet.parse(text) else { return false }
        switch expression {
        case .number(let value): return value.isFinite
        case .unary(let operation,.number(let value)) where operation == "+" || operation == "-": return value.isFinite
        default: return false
        }
    }

    private static func isISODateOrDateTime(_ source:String) -> Bool {
        let text = source.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        let localPatterns = [
            ("^\\d{4}-\\d{2}-\\d{2}$", "yyyy-MM-dd"),
            ("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{1,9})?$", "yyyy-MM-dd'T'HH:mm:ss")
        ]
        for (pattern,format) in localPatterns {
            guard text.range(of:pattern,options:.regularExpression) != nil else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier:"en_US_POSIX")
            formatter.calendar = Calendar(identifier:.gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT:0)
            formatter.isLenient = false
            formatter.dateFormat = format
            if formatter.date(from:text) != nil { return true }
            if format == "yyyy-MM-dd'T'HH:mm:ss",text.contains(".") {
                for fractionalFormat in ["yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS"] {
                    formatter.dateFormat = fractionalFormat
                    if formatter.date(from:text) != nil { return true }
                }
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        if iso.date(from:text) != nil { return true }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from:text) != nil
    }
}
