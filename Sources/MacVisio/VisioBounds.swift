import Foundation

enum VisioBounds {
    static func evaluate(_ arguments:[ShapeSheet.Expression],resolve:(ShapeSheet.Expression)throws->Double) throws -> Double {
        guard arguments.count >= 5,(arguments.count-2)%3 == 0 else { throw DiagramError.invalid("BOUND expects a value, type and one or more range triples.") }
        let value = try resolve(arguments[0]),type = try resolve(arguments[1])
        guard let mode = Int(exactly:type),(0...2).contains(mode) else { throw DiagramError.invalid("Invalid BOUND constraint type.") }
        if mode == 2 { return value }
        var ranges:[(Double,Double)] = []
        for i in stride(from:2,to:arguments.count,by:3) where try resolve(arguments[i]) == 0 { let a = try resolve(arguments[i+1]),b = try resolve(arguments[i+2]);ranges.append((min(a,b),max(a,b))) }
        if ranges.isEmpty { return value }
        let inside = ranges.contains{value >= $0.0 && value <= $0.1}
        if (mode == 0 && inside) || (mode == 1 && !inside) { return value }
        let candidates = ranges.flatMap{mode == 0 ? [$0.0,$0.1] : [$0.0.nextDown,$0.1.nextUp]}.filter{candidate in candidate.isFinite && (mode == 0 || !ranges.contains{candidate >= $0.0 && candidate <= $0.1})}
        guard let result = candidates.min(by:{abs($0-value)<abs($1-value)}) else { throw DiagramError.invalid("BOUND has no finite valid value.") };return result
    }
}
