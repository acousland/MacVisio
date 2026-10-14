import Foundation

/// Visio page shape IDs are unsigned 32-bit values, including zero.
struct VisioIDAllocator {
    private var used:Set<UInt32>
    private var next:UInt64
    init(reserved:[String] = []) throws {
        guard reserved.allSatisfy({UInt32($0) != nil}) else { throw DiagramError.invalid("Invalid Visio shape identifier.") }
        used = Set(reserved.compactMap(UInt32.init));next = (used.max().map(UInt64.init) ?? 0)+1
    }
    mutating func allocate() throws -> String {
        guard used.count < 150000 else { throw DiagramError.invalid("The page has too many shape identifiers.") }
        if next > UInt32.max { next = 0 }
        while used.contains(UInt32(next)) { next += 1;if next > UInt32.max { next = 0 } }
        let result = String(next);used.insert(UInt32(next));next += 1;return result
    }
    static func remap(_ formula:String,using map:[String:String]) -> String {
        guard !map.isEmpty,let pattern = try? NSRegularExpression(pattern:"(?i)\\bSheet\\.([0-9]+)!") else { return formula }
        let units = Array(formula.utf16);var quoted = [Bool](repeating:false,count:units.count),inside = false,index = 0
        while index < units.count {
            quoted[index] = inside
            if units[index] == 34 {
                if inside,index+1 < units.count,units[index+1] == 34 { quoted[index+1] = true;index += 2;continue }
                inside.toggle()
            };index += 1
        }
        let canonical = map.reduce(into:[UInt32:String]()){if let id = UInt32($1.key) { $0[id] = $1.value }}
        var result = formula
        for match in pattern.matches(in:formula,range:NSRange(formula.startIndex...,in:formula)).reversed() {
            guard !quoted[match.range.location],let idRange = Range(match.range(at:1),in:formula),let id = UInt32(formula[idRange]),let replacement = canonical[id],let range = Range(match.range,in:result) else { continue }
            result.replaceSubrange(range,with:"Sheet.\(replacement)!")
        }
        return result
    }
}
