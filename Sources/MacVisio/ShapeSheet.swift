import Foundation

/// A per-document view of Visio's indexed color table. RGB() returns a color
/// index, so callers evaluating several formulas should share this palette.
final class ShapeSheetColorPalette {
    private static let standardColors = [
        "#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#FFFF00", "#FF00FF", "#00FFFF",
        "#800000", "#008000", "#000080", "#808000", "#800080", "#008080", "#C0C0C0", "#E6E6E6",
        "#CDCDCD", "#B3B3B3", "#9A9A9A", "#808080", "#666666", "#4D4D4D", "#333333", "#1A1A1A"
    ]
    private var indices: [String: Int] = [:]
    private var colorsByIndex: [Int: String] = [:]
    private var nextIndex: UInt64
    private let allowsAddingColors: Bool

    convenience init(documentArchive: VisioDocumentArchive?) {
        self.init(entries: Self.documentEntries(documentArchive))
    }

    /// `entries` contains additional document ColorEntry indices and `#RRGGBB` values.
    /// Enable allocation only when the caller will persist new ColorEntry values.
    init(entries: [Int: String] = [:], allowsAddingColors: Bool = false) {
        self.allowsAddingColors = allowsAddingColors
        for (index, color) in Self.standardColors.enumerated() { indices[color] = index;colorsByIndex[index] = color }
        for (index, color) in entries.sorted(by: { $0.key < $1.key }) where index > 23 && index <= Int(UInt32.max) {
            guard let normalized = Self.normalize(color) else { continue }
            if indices[normalized] == nil { indices[normalized] = index }
            colorsByIndex[index] = normalized
        }
        nextIndex = UInt64(max(23, entries.keys.filter { (24...Int(UInt32.max)).contains($0) }.max() ?? 23)) + 1
    }

    private static func documentEntries(_ archive: VisioDocumentArchive?) -> [Int: String] {
        guard let archive else { return [:] }
        // Visio packages conventionally store the document part at this path.
        // Fall back to identifying a custom-path VisioDocument root when needed.
        let preferred = archive.parts["visio/document.xml"]
        let candidates = preferred.map { [$0] } ?? archive.parts.keys.sorted().compactMap { name -> Data? in
            guard name.lowercased().hasSuffix(".xml"), let data = archive.parts[name],
                  let text = String(data: data, encoding: .utf8),
                  text.range(of: "<(?:(?:[A-Za-z_][A-Za-z0-9_.-]*):)?VisioDocument(?:\\s|>)", options: .regularExpression) != nil else { return nil }
            return data
        }
        for data in candidates {
            guard let root = try? VisioXML.document(data).rootElement(), root.localTag == "VisioDocument" else { continue }
            return Dictionary(root.firstLocal("Colors")?.elementsLocal("ColorEntry").compactMap { entry -> (Int, String)? in
                guard let index = entry.attr("IX").flatMap(Int.init), let color = entry.attr("RGB") else { return nil }
                return (index, color)
            } ?? [], uniquingKeysWith: { first, _ in first })
        }
        return [:]
    }

    func index(for components: [Double]) throws -> Double {
        guard components.count == 3 else { throw DiagramError.invalid("RGB expects three color components.") }
        let bytes = try components.map { component -> Int in
            guard component.isFinite, let byte = Int(exactly: component), (0...255).contains(byte) else {
                throw DiagramError.invalid("RGB components must be whole numbers from 0 through 255.")
            }
            return byte
        }
        let color = String(format: "#%02X%02X%02X", bytes[0], bytes[1], bytes[2])
        if let index = indices[color] { return Double(index) }
        guard allowsAddingColors else { throw DiagramError.invalid("RGB color is absent from the supplied Visio color table.") }
        guard nextIndex <= UInt64(UInt32.max) else { throw DiagramError.invalid("The Visio color table is full.") }
        let index = Int(nextIndex)
        indices[color] = index
        nextIndex += 1
        return Double(index)
    }

    func color(at index:Double) -> ShapeSheetColor? {
        guard let integer = Int(exactly:index),integer >= 0,let hex = colorsByIndex[integer] else { return nil }
        return ShapeSheetColor(hex:hex)
    }

    func index(for color:ShapeSheetColor,function:String) throws -> Double {
        if let index = indices[color.hex] { return Double(index) }
        guard allowsAddingColors else {
            throw DiagramError.invalid("\(function) color is absent from the supplied Visio color table; palette allocation is unsupported.")
        }
        guard nextIndex <= UInt64(UInt32.max) else { throw DiagramError.invalid("The Visio color table is full.") }
        let index = Int(nextIndex)
        indices[color.hex] = index;colorsByIndex[index] = color.hex;nextIndex += 1
        return Double(index)
    }

    private static func normalize(_ value: String) -> String? {
        let text = value.hasPrefix("#") ? String(value.dropFirst()) : value
        guard text.count == 6, text.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + text.uppercased()
    }
}

/// A bounded numeric ShapeSheet interpreter. Unsupported functions throw; callers
/// can retain a file's cached value without substituting a made-up calculation.
enum ShapeSheet {
    indirect enum Expression { case number(Double),measure(Double,String),string(String),reference(String),omitted,unary(String,Expression),binary(String,Expression,Expression),call(String,[Expression]) }
    enum Token: Equatable { case number(Double),measure(Double,String),string(String),name(String),op(String),left,right,comma,end }
    static func parse(_ formula:String,characterLimit:Int = 16384) throws -> Expression {
        try ShapeSheetExpressionCache.shared.expression(formula, characterLimit: characterLimit) {
            var parser = try Parser(formula,characterLimit:characterLimit)
            let result = try parser.expression()
            guard parser.token == .end else { throw DiagramError.invalid("Unexpected ShapeSheet expression content.") }
            return result
        }
    }
    static func evaluate(_ formula:String,resolve:(String)throws->Double,colorPalette:ShapeSheetColorPalette = ShapeSheetColorPalette()) throws -> Double {
        try evaluate(parse(formula),resolve:resolve,colorPalette:colorPalette)
    }
    static func evaluate(_ expression:Expression,resolve:(String)throws->Double,colorPalette:ShapeSheetColorPalette = ShapeSheetColorPalette()) throws -> Double {
        var operations = 0
        func eval(_ expression:Expression,_ depth:Int = 0) throws -> Double {
            operations += 1
            guard operations < 10000,depth < 64 else { throw DiagramError.invalid("ShapeSheet expression exceeds the calculation limit.") }
            let result:Double
            switch expression {
            case .number(let value): result = value
            case .measure(let value,_):result = value
            case .string: throw DiagramError.invalid("This cell requires a numeric ShapeSheet value.")
            case .omitted: throw DiagramError.invalid("An omitted argument is valid only in an optional function position.")
            case .reference(let name):
                if name.uppercased() == "TRUE" { return 1 }; if name.uppercased() == "FALSE" { return 0 }
                result = try resolve(name)
            case .unary(let op,let expression): let value = try eval(expression,depth+1); result = op == "-" ? -value : value
            case .binary(let op,let a,let b):
                let x = try eval(a,depth+1),y = try eval(b,depth+1)
                switch op {
                case "+":result = x+y; case "-":result = x-y; case "*":result = x*y
                case "/":guard y != 0 else { throw DiagramError.invalid("Division by zero in ShapeSheet.") }; result = x/y
                case "^":result = pow(x,y)
                case "=","==":result = x == y ? 1 : 0; case "!=","<>":result = x != y ? 1 : 0
                case "<":result = x < y ? 1 : 0; case ">":result = x > y ? 1 : 0; case "<=":result = x <= y ? 1 : 0; case ">=":result = x >= y ? 1 : 0
                default:throw DiagramError.invalid("Unsupported ShapeSheet operator.")
                }
            case .call(let name,let arguments):
                let name = name.uppercased()
                try requireReferenceFunction(name)
                if name == "SETATREF",(1...3).contains(arguments.count) { if arguments.count == 3,try eval(arguments[2],depth+1) != 0 { return 0 };if case .string(let reference) = arguments[0] { return try resolve(reference) };return try eval(arguments[0],depth+1) }
                if name == "SETATREFEXPR",arguments.isEmpty { return 0 }
                if name == "REF",arguments.isEmpty { throw DiagramError.invalid("ShapeSheet #REF! error.") }
                if name == "BOUND" { return try VisioBounds.evaluate(arguments){try eval($0,depth+1)} }
                if name == "IF",arguments.count == 3 { return try eval(eval(arguments[0],depth+1) != 0 ? arguments[1] : arguments[2],depth+1) }
                if name == "IFERROR",arguments.count == 2 { do { return try eval(arguments[0],depth+1) } catch { return try eval(arguments[1],depth+1) } }
                let values = try arguments.map{try eval($0,depth+1)}
                func arity(_ n:Int) throws { guard values.count == n else { throw DiagramError.invalid("\(name) expects \(n) arguments.") } }
                switch name {
                case "GUARD","THEMEGUARD","SETATREFEXPR","SETATREFEVAL":try arity(1);result = values[0]
                case "ISTHEMED":try arity(0);result = try eval(.reference("ColorSchemeIndex"),depth+1) > 0 ? 1 : 0
                case "PI":try arity(0);result = .pi
                case "ABS":try arity(1);result = abs(values[0])
                case "SQRT":try arity(1);result = sqrt(values[0])
                case "SIN":try arity(1);result = sin(values[0]); case "COS":try arity(1);result = cos(values[0]); case "TAN":try arity(1);result = tan(values[0])
                case "ASIN":try arity(1);result = asin(values[0]); case "ACOS":try arity(1);result = acos(values[0]); case "ATAN":try arity(1);result = atan(values[0])
                case "ATAN2":try arity(2);result = try arcTangent2(values[0],values[1])
                case "LN":try arity(1);result = log(values[0]); case "EXP":try arity(1);result = exp(values[0])
                case "LOG10":try arity(1);result = log10(values[0])
                case "TRUNC":
                    try arity(2)  // Visio 2019 rejects TRUNC without its digit count (TRUNC-3).
                    result = truncated(values[0],digits:values[1])
                case "ANG360":try arity(1);result = angle360(values[0])
                case "INT":try arity(1);result = floor(values[0]); case "SIGN":
                    guard (1...2).contains(values.count) else { throw DiagramError.invalid("SIGN expects one or two arguments.") }
                    result = try sign(values[0],fuzz:values.count == 2 ? values[1] : 1e-9)
                case "ROUND":try arity(2);result = try decimalRounded(values[0],digits:values[1])
                case "CEILING","FLOOR":
                    guard (1...2).contains(values.count) else { throw DiagramError.invalid("\(name) expects one or two arguments.") }
                    let multiple = values.count == 2 ? values[1] : (values[0] < 0 ? -1 : 1)
                    result = try rounded(values[0],toMultiple:multiple,awayFromZero:name == "CEILING")
                case "BITAND","BITOR","BITXOR":
                    try arity(2)
                    result = try bitwise(name,values)
                case "RGB":
                    try arity(3)
                    result = try colorPalette.index(for:values.map { Double(colorComponent($0)) })
                case "MODULUS":try arity(2);result = try modulus(values[0],divisor:values[1])
                // DEG and RAD retype a value as an angle; its internal (radian) value is unchanged,
                // except that RAD reads a plain number as degrees.
                case "DEG":try arity(1);result = values[0]
                case "RAD":try arity(1);result = isAngle(arguments[0]) ? values[0] : values[0] * .pi/180
                case "POW":
                    try arity(2)
                    guard values[0] != 0 || values[1] != 0 else { throw DiagramError.invalid("POW(0,0) is undefined (#NUM!).") }
                    result = pow(values[0],values[1])
                case "MIN","MAX","SUM":guard !values.isEmpty else { throw DiagramError.invalid("\(name) needs an argument.") };result = name == "MIN" ? values.min()! : name == "MAX" ? values.max()! : values.reduce(0,+)
                case "AND":result = values.allSatisfy{$0 != 0} ? 1 : 0; case "OR":result = values.contains{$0 != 0} ? 1 : 0; case "NOT":try arity(1);result = values[0] == 0 ? 1 : 0
                default: throw DiagramError.invalid("Unsupported ShapeSheet function: \(name). The original formula and cached value are retained.")
                }
            }
            guard result.isFinite else { throw DiagramError.invalid("ShapeSheet calculation produced a non-finite value.") }; return result
        }; return try eval(expression)
    }
    /// Visio wraps RGB/HSL components to 0...255 after truncating them toward zero: RGB(300,0,0) is RGB(44,0,0).
    static func colorComponent(_ value:Double) -> Int { guard value.isFinite,abs(value) < 1e15 else { return 0 };return Int(Int64(value.rounded(.towardZero)) & 0xFF) }
    /// TRUNC drops digits toward zero; negative digit counts truncate to tens, hundreds and so on.
    static func truncated(_ value:Double,digits:Double) -> Double {
        let places = max(-15,min(15,Int(digits.rounded(.towardZero)))),scale = pow(10,Double(places))
        return (value*scale).rounded(.towardZero)/scale
    }
    /// ANG360 normalizes an angle (radians internally) to [0, 2pi).
    static func angle360(_ value:Double) -> Double {
        let turn = 2 * Double.pi,result = value.truncatingRemainder(dividingBy:turn)
        return result < 0 ? result+turn : result
    }
    /// MS-VSDX ATan2 returns a default-angle value in (-pi, pi]. The
    /// platform atan2 also accepts signed zero and includes -pi, so its axis
    /// and rounded endpoint results need canonicalization for this contract.
    static func arcTangent2(_ y:Double,_ x:Double) throws -> Double {
        guard y.isFinite,x.isFinite else { throw DiagramError.invalid("ATAN2 requires finite numeric vector components.") }
        if y == 0,x == 0 { return 0 }
        // Call atan2 directly; forming y/x first can overflow or underflow
        // even when the angle of the finite vector is representable.
        let angle = atan2(y,x)
        guard angle.isFinite else { throw DiagramError.invalid("ATAN2 produced a non-finite angle.") }
        if angle <= -Double.pi { return Double.pi }
        return angle
    }
    static func bitwise(_ name:String,_ operands:[Double]) throws -> Double {
        let function = name.uppercased()
        guard operands.count == 2 else { throw DiagramError.invalid("\(function) expects two arguments.") }
        // Visio truncates operands toward zero and uses their low 16 bits: BITOR(-1,0) is 65535.
        guard operands.allSatisfy(\.isFinite) else { throw DiagramError.invalid("\(function) requires finite operands.") }
        // Values beyond the integer range convert to 0, as in Visio (BITAND(1e308,1) is 0).
        func bits(_ value:Double) -> Int64 { abs(value) < 9e18 ? Int64(value.rounded(.towardZero)) & 0xFFFF : 0 }
        let lhs = bits(operands[0]),rhs = bits(operands[1])
        let result:Int64
        switch function {
        case "BITAND":result = lhs & rhs
        case "BITOR":result = lhs | rhs
        case "BITXOR":result = lhs ^ rhs
        default:throw DiagramError.invalid("Unsupported ShapeSheet bitwise function: \(function).")
        }
        return Double(result)
    }
    /// MODULUS uses a range-qualified vFloat divisor, without narrowing the
    /// original Double value. Remainder arithmetic avoids quotient overflow
    /// and cancellation in number - divisor * floor(number / divisor).
    static func modulus(_ number:Double,divisor:Double) throws -> Double {
        guard number.isFinite,divisor.isFinite else { throw DiagramError.invalid("MODULUS requires finite numeric operands.") }
        guard divisor != 0 else { throw DiagramError.invalid("MODULUS divisor cannot be zero.") }
        let magnitude = abs(divisor)
        guard magnitude >= Double(Float.leastNonzeroMagnitude),magnitude <= Double(Float.greatestFiniteMagnitude) else {
            throw DiagramError.invalid("MODULUS divisor is outside the finite single-precision range.")
        }
        let remainder = number.truncatingRemainder(dividingBy:divisor)
        if remainder == 0 { return 0 }
        let result = remainder.sign == divisor.sign ? remainder : remainder+divisor
        // Opposite-sign correction can round a tiny remainder onto the divisor
        // boundary. Do not fabricate zero or a neighboring interior value.
        guard result.isFinite,result != 0,result.sign == divisor.sign,abs(result) < magnitude else {
            throw DiagramError.invalid("MODULUS result cannot be represented within the divisor magnitude.")
        }
        return result
    }
    /// ROUND's precision is a vSignedInt: truncate towards zero, then range-check.
    /// Its documented identity range is separate from floating-point scaling.
    static func decimalRounded(_ number:Double,digits:Double) throws -> Double {
        guard number.isFinite,digits.isFinite else { throw DiagramError.invalid("ROUND requires finite numeric operands.") }
        let places = digits.rounded(.towardZero)
        guard (-32768...32767).contains(places) else { throw DiagramError.invalid("ROUND precision is outside the signed 16-bit range.") }
        if places <= -9 || places > 15 { return number }
        // An integral Double already has no decimal places to discard. Avoid
        // overflowing an otherwise unnecessary scale multiplication.
        if places >= 0,number.rounded(.towardZero) == number { return number }
        let scale = pow(10,places),scaled = number*scale,whole = scaled.rounded()
        guard scaled.isFinite else { throw DiagramError.invalid("Rounded ShapeSheet value is outside the supported range.") }
        // Scaling can make an already representable value integral. Returning
        // it directly avoids a lossy or overflowing reverse scale.
        if scaled == whole { return number }
        let result = whole/scale
        guard result.isFinite else { throw DiagramError.invalid("Rounded ShapeSheet value is outside the supported range.") }
        return result
    }
    static func rounded(_ number:Double,toMultiple multiple:Double,awayFromZero:Bool) throws -> Double {
        guard number.isFinite,multiple.isFinite else { throw DiagramError.invalid("Rounding requires finite values.") }
        if number == 0 || multiple == 0 { return 0 }
        guard number.sign == multiple.sign else { throw DiagramError.invalid("Rounding values must have the same sign.") }
        let quotient = number/multiple
        guard quotient.isFinite else { throw DiagramError.invalid("Rounded ShapeSheet value is outside the supported range.") }
        // Nonzero same-sign operands have a positive mathematical quotient.
        // If Double division underflows to zero, CEILING still takes one step.
        if quotient == 0,awayFromZero { return multiple }
        let count = awayFromZero ? ceil(quotient) : quotient.rounded(.towardZero)
        let result = count*multiple
        guard result.isFinite else { throw DiagramError.invalid("Rounded ShapeSheet value is outside the supported range.") }
        return result
    }
    static func sign(_ number:Double,fuzz:Double) throws -> Double {
        guard number.isFinite,fuzz.isFinite else { throw DiagramError.invalid("SIGN requires finite values.") }
        guard fuzz >= 0 else { throw DiagramError.invalid("SIGN fuzz must be nonnegative.") }
        if abs(number) <= fuzz { return 0 }
        return number > 0 ? 1 : -1
    }
    /// Functions later Visio versions added, which Visio 2019 (16.0.10730) rejects as unknown names
    /// (reference cases CONCATENATE-*, EXP-*, TODAY-1). Formulas using them would fail in Visio 2019.
    static let unavailableInReference: Set<String> = ["CONCATENATE","EXP","TODAY"]
    static func requireReferenceFunction(_ name:String) throws {
        if unavailableInReference.contains(name) { throw DiagramError.invalid("\(name) is not available in Visio 2019 (#NAME?).") }
    }
    static func isAngle(_ expression:Expression) -> Bool {
        switch expression {
        case .measure(_,let unit):return ["DEG","RAD","DA","AD","DEGREE","DEGREES","RADIAN","RADIANS"].contains(unit.uppercased())
        case .unary(_,let child):return isAngle(child)
        case .call(let name,_):return ["DEG","RAD","ANG360","ASIN","ACOS","ATAN","ATAN2"].contains(name.uppercased())
        default:return false
        }
    }
    static func containsMeasure(_ expression:Expression) -> Bool {
        switch expression {
        case .measure:return true
        case .unary(_,let child):return containsMeasure(child)
        case .binary(_,let lhs,let rhs):return containsMeasure(lhs) || containsMeasure(rhs)
        case .call(_,let arguments):return arguments.contains(where:containsMeasure)
        case .omitted:return false
        default:return false
        }
    }
    private struct Parser {
        var tokens:[Token] = [],index = 0,depth = 0
        var token:Token { index < tokens.count ? tokens[index] : .end }
        init(_ source:String,characterLimit:Int) throws {
            let text = source.hasPrefix("=") ? String(source.dropFirst()) : source
            guard text.count <= characterLimit else { throw DiagramError.invalid("ShapeSheet expression is too long.") }
            let characters = Array(text)
            var i = 0
            let units:[String:Double] = ["in":1,"inch":1,"inches":1,"pt":1/72,"mm":1/25.4,"cm":1/2.54,"m":1000/25.4,"ft":12,"yd":36,"deg":Double.pi/180,"rad":1,"dl":1,"dp":1,"dt":1,"da":1,"de":1,
                                         "km":1e6/25.4,"mi":63360,"ed":1,"eh":1.0/24,"em":1.0/1440,"es":1.0/86400,"ew":7]
            while i < characters.count {
                let c = characters[i]
                if c.isWhitespace { i += 1; continue }
                if c == "\"" {
                    i += 1;var value = "",closed = false
                    while i < characters.count {
                        if characters[i] == "\"" { if i+1 < characters.count,characters[i+1] == "\"" { value.append("\"");i += 2 } else { i += 1;closed = true;break } }
                        else { value.append(characters[i]);i += 1 }
                    }
                    guard closed else { throw DiagramError.invalid("Unclosed ShapeSheet string.") };tokens.append(.string(value));continue
                }
                if c.isNumber || c == "." && i+1 < characters.count && characters[i+1].isNumber {
                    let start = i; i += 1
                    while i < characters.count && (characters[i].isNumber || characters[i] == ".") { i += 1 }
                    if i < characters.count && (characters[i] == "e" || characters[i] == "E") { i += 1; if i < characters.count && (characters[i] == "+" || characters[i] == "-") { i += 1 }; while i < characters.count && characters[i].isNumber { i += 1 } }
                    guard var value = Double(String(characters[start..<i])),value.isFinite else { throw DiagramError.invalid("Invalid ShapeSheet number.") }
                    var next = i;var unit:String?; while next < characters.count && characters[next].isWhitespace { next += 1 }
                    if next < characters.count && characters[next] == "%" { value /= 100; i = next+1 }
                    else { let begin = next; while next < characters.count && characters[next].isLetter { next += 1 }; if next > begin,let factor = units[String(characters[begin..<next]).lowercased()] { unit = String(characters[begin..<next]).uppercased();value *= factor; i = next } }
                    tokens.append(unit.map{.measure(value,$0)} ?? .number(value)); continue
                }
                if c.isLetter || c == "_" {
                    let start = i; i += 1
                    while i < characters.count && (characters[i].isLetter || characters[i].isNumber || ["_",".","[","]"].contains(characters[i]) || characters[i] == "!" && !(i+1 < characters.count && characters[i+1] == "=")) { i += 1 }
                    tokens.append(.name(String(characters[start..<i]))); continue
                }
                switch c {
                case "(":tokens.append(.left); case ")":tokens.append(.right); case ",",";":tokens.append(.comma)
                case "+","-","*","/","^","&":tokens.append(.op(String(c)))
                case "=","<",">","!":
                    var op = String(c)
                    if i+1 < characters.count && (characters[i+1] == "=" || c == "<" && characters[i+1] == ">") { i += 1;op.append(characters[i]) }
                    tokens.append(.op(op))
                default: throw DiagramError.invalid("Unsupported ShapeSheet syntax.")
                }; i += 1
            }; tokens.append(.end)
        }
        mutating func expression(_ minimum:Int = 0) throws -> Expression {
            depth += 1; defer { depth -= 1 }; guard depth < 64 else { throw DiagramError.invalid("ShapeSheet nesting limit exceeded.") }
            var left:Expression
            switch token {
            case .number(let value):index += 1;left = .number(value)
            case .measure(let value,let unit):index += 1;left = .measure(value,unit)
            case .string(let value):index += 1;left = .string(value)
            // As in Visio (and Excel), negation binds tighter than ^: -2^2 is 4.
            case .op(let op) where op == "+" || op == "-":index += 1;left = .unary(op,try expression(6))
            case .left:index += 1;left = try expression();guard token == .right else { throw DiagramError.invalid("Missing closing parenthesis.") };index += 1
            case .name(let name):
                index += 1
                if token == .left {
                    index += 1;var arguments:[Expression] = []
                    if name.uppercased() == "INDEX" {
                        // INDEX permits an omitted delimiter while specifying
                        // errorvalue, as in INDEX(54,";1;2;3;,,"ERROR").
                        if token != .right {
                            while true {
                                if token == .comma { arguments.append(.omitted) }
                                else { arguments.append(try expression()) }
                                if token == .comma {
                                    index += 1
                                    if token == .right { arguments.append(.omitted);break }
                                    continue
                                }
                                break
                            }
                        }
                    } else if token != .right { while true { if name.uppercased() == "BOUND",arguments.isEmpty,token == .comma { arguments.append(.number(0)) } else { arguments.append(try expression()) };if token == .comma { index += 1;continue };break } }
                    guard token == .right else { throw DiagramError.invalid("Missing function closing parenthesis.") };index += 1;left = .call(name,arguments)
                } else { left = .reference(name) }
            default:throw DiagramError.invalid("Expected a ShapeSheet value.")
            }
            while case .op(let op) = token {
                // Visio's binary operators are all left-associative (2^3^2 is 64); & binds below + and -.
                let precedence = ["=":0,"==":0,"!=":0,"<>":0,"<":0,">":0,"<=":0,">=":0,"&":1,"+":2,"-":2,"*":3,"/":3,"^":5][op] ?? -1
                if precedence < minimum { break }
                index += 1;let right = try expression(precedence+1);left = .binary(op,left,right)
            };return left
        }
    }
}
