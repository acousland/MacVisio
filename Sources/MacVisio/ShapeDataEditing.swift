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
        guard property.type == 3 else { return property.value }
        switch property.value.trimmingCharacters(in:.whitespacesAndNewlines).uppercased() {
        case "1", "TRUE": return "TRUE"
        case "0", "FALSE": return "FALSE"
        default: return property.value
        }
    }

    /// Validates the types with explicit choice semantics and keeps untouched legacy values intact.
    /// Type 2 accepts simple finite numeric literals and recognized Visio measurements; its
    /// Format picture remains opaque. Types 0, 5, 6, and 7 are passed through unchanged.
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
}
