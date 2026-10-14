import Foundation

/// A bounded numeric ShapeSheet interpreter. Unsupported functions throw; callers
/// can retain a file's cached value without substituting a made-up calculation.
enum ShapeSheet {
    indirect enum Expression { case number(Double),measure(Double,String),string(String),reference(String),unary(String,Expression),binary(String,Expression,Expression),call(String,[Expression]) }
    enum Token: Equatable { case number(Double),measure(Double,String),string(String),name(String),op(String),left,right,comma,end }
    static func parse(_ formula:String,characterLimit:Int = 16384) throws -> Expression {
        var parser = try Parser(formula,characterLimit:characterLimit);let result = try parser.expression()
        guard parser.token == .end else { throw DiagramError.invalid("Unexpected ShapeSheet expression content.") };return result
    }
    static func evaluate(_ formula:String,resolve:(String)throws->Double) throws -> Double {
        try evaluate(parse(formula),resolve:resolve)
    }
    static func evaluate(_ expression:Expression,resolve:(String)throws->Double) throws -> Double {
        var operations = 0
        func eval(_ expression:Expression,_ depth:Int = 0) throws -> Double {
            operations += 1
            guard operations < 10000,depth < 64 else { throw DiagramError.invalid("ShapeSheet expression exceeds the calculation limit.") }
            let result:Double
            switch expression {
            case .number(let value): result = value
            case .measure(let value,_):result = value
            case .string: throw DiagramError.invalid("This cell requires a numeric ShapeSheet value.")
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
                if name == "SETATREF",(1...3).contains(arguments.count) { if arguments.count == 3,try eval(arguments[2],depth+1) != 0 { return 0 };if case .string(let reference) = arguments[0] { return try resolve(reference) };return try eval(arguments[0],depth+1) }
                if name == "SETATREFEXPR",arguments.isEmpty { return 0 }
                if name == "REF",arguments.isEmpty { throw DiagramError.invalid("ShapeSheet #REF! error.") }
                if name == "BOUND" { return try VisioBounds.evaluate(arguments){try eval($0,depth+1)} }
                if name == "IF",arguments.count == 3 { return try eval(eval(arguments[0],depth+1) != 0 ? arguments[1] : arguments[2],depth+1) }
                if name == "IFERROR",arguments.count == 2 { do { return try eval(arguments[0],depth+1) } catch { return try eval(arguments[1],depth+1) } }
                let values = try arguments.map{try eval($0,depth+1)}
                func arity(_ n:Int) throws { guard values.count == n else { throw DiagramError.invalid("\(name) expects \(n) arguments.") } }
                switch name {
                case "GUARD","SETATREFEXPR","SETATREFEVAL":try arity(1);result = values[0]
                case "PI":try arity(0);result = .pi
                case "ABS":try arity(1);result = abs(values[0])
                case "SQRT":try arity(1);result = sqrt(values[0])
                case "SIN":try arity(1);result = sin(values[0]); case "COS":try arity(1);result = cos(values[0]); case "TAN":try arity(1);result = tan(values[0])
                case "ASIN":try arity(1);result = asin(values[0]); case "ACOS":try arity(1);result = acos(values[0]); case "ATAN":try arity(1);result = atan(values[0])
                case "ATAN2":try arity(2);result = atan2(values[0],values[1])
                case "LN":try arity(1);result = log(values[0]); case "EXP":try arity(1);result = exp(values[0])
                case "INT":try arity(1);result = floor(values[0]); case "SIGN":try arity(1);result = values[0] == 0 ? 0 : values[0] > 0 ? 1 : -1
                case "ROUND":try arity(2);let digits = values[1].rounded(.towardZero);let scale = pow(10,digits);result = digits <= -9 || digits > 15 ? values[0] : (values[0]*scale).rounded()/scale
                case "MODULUS":try arity(2);guard values[1] != 0 else { throw DiagramError.invalid("MODULUS divisor cannot be zero.") };result = values[0]-values[1]*floor(values[0]/values[1])
                case "DEG":try arity(1);result = values[0]*180 / .pi
                case "RAD":try arity(1);result = values[0] * .pi/180
                case "POW":try arity(2);result = pow(values[0],values[1])
                case "MIN","MAX","SUM":guard !values.isEmpty else { throw DiagramError.invalid("\(name) needs an argument.") };result = name == "MIN" ? values.min()! : name == "MAX" ? values.max()! : values.reduce(0,+)
                case "AND":result = values.allSatisfy{$0 != 0} ? 1 : 0; case "OR":result = values.contains{$0 != 0} ? 1 : 0; case "NOT":try arity(1);result = values[0] == 0 ? 1 : 0
                default: throw DiagramError.invalid("Unsupported ShapeSheet function: \(name). The original formula and cached value are retained.")
                }
            }
            guard result.isFinite else { throw DiagramError.invalid("ShapeSheet calculation produced a non-finite value.") }; return result
        }; return try eval(expression)
    }
    private struct Parser {
        var tokens:[Token] = [],index = 0,depth = 0
        var token:Token { index < tokens.count ? tokens[index] : .end }
        init(_ source:String,characterLimit:Int) throws {
            let text = source.hasPrefix("=") ? String(source.dropFirst()) : source
            guard text.count <= characterLimit else { throw DiagramError.invalid("ShapeSheet expression is too long.") }
            let characters = Array(text)
            var i = 0
            let units:[String:Double] = ["in":1,"inch":1,"inches":1,"pt":1/72,"mm":1/25.4,"cm":1/2.54,"m":1000/25.4,"ft":12,"yd":36,"deg":Double.pi/180,"rad":1,"dl":1,"dp":1,"dt":1,"da":1,"de":1]
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
            case .op(let op) where op == "+" || op == "-":index += 1;left = .unary(op,try expression(3))
            case .left:index += 1;left = try expression();guard token == .right else { throw DiagramError.invalid("Missing closing parenthesis.") };index += 1
            case .name(let name):
                index += 1
                if token == .left {
                    index += 1;var arguments:[Expression] = []
                    if token != .right { while true { if name.uppercased() == "BOUND",arguments.isEmpty,token == .comma { arguments.append(.number(0)) } else { arguments.append(try expression()) };if token == .comma { index += 1;continue };break } }
                    guard token == .right else { throw DiagramError.invalid("Missing function closing parenthesis.") };index += 1;left = .call(name,arguments)
                } else { left = .reference(name) }
            default:throw DiagramError.invalid("Expected a ShapeSheet value.")
            }
            while case .op(let op) = token {
                let precedence = ["=":0,"==":0,"!=":0,"<>":0,"<":0,">":0,"<=":0,">=":0,"&":1,"+":1,"-":1,"*":2,"/":2,"^":4][op] ?? -1
                if precedence < minimum { break }
                index += 1;let right = try expression(precedence+(op == "^" ? 0 : 1));left = .binary(op,left,right)
            };return left
        }
    }
}
