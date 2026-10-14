import Foundation

enum SheetValue:Equatable {
    case number(Double),quantity(Double,String),string(String),boolean(Bool),date(Date)
    var text:String { switch self { case .number(let value),.quantity(let value,_):return ShapeSheetEngine.format(value);case .string(let value):return value;case .boolean(let value):return value ? "TRUE" : "FALSE";case .date(let value):return ISO8601DateFormatter().string(from:value) } }
    var unit:String? { if case .quantity(_,let unit) = self { return unit };return nil }
    var dimension:String? { unit.map{["DEG","RAD","DA"].contains($0.uppercased()) ? "angle" : $0.uppercased() == "DE" ? "duration" : "length"} }
    static func factor(_ unit:String) -> Double? { ["IN":1,"INCH":1,"INCHES":1,"PT":72,"MM":25.4,"CM":2.54,"M":0.0254,"FT":1/12,"YD":1/36,"DEG":180 / .pi,"RAD":1,"DL":1,"DP":1,"DT":1,"DA":1,"DE":1][unit.uppercased()] }
    func numeric() throws -> Double {
        switch self { case .number(let value),.quantity(let value,_):return value;case .boolean(let value):return value ? 1 : 0;case .date(let value):return value.timeIntervalSince1970/86400+25569;case .string(let value):if let n = Double(value),n.isFinite { return n };throw DiagramError.invalid("A numeric value was required.") }
    }
    var valid:Bool { switch self { case .number(let n):return n.isFinite;case .quantity(let n,let u):return n.isFinite && Self.factor(u) != nil;case .string(let s):return s.utf8.count <= 1_000_000;case .date(let d):return d.timeIntervalSince1970.isFinite;case .boolean:return true } }
}
enum TypedShapeSheet {
    static func evaluate(_ formula:String,resolve:@escaping (String)throws->SheetValue,call:@escaping (String,[SheetValue])throws->SheetValue,scalar:Bool = false,specialCall:@escaping (String,[ShapeSheet.Expression],(ShapeSheet.Expression)throws->SheetValue)throws->SheetValue? = {_,_,_ in nil}) throws -> SheetValue {
        try evaluate(ShapeSheet.parse(formula),resolve:resolve,call:call,scalar:scalar,specialCall:specialCall)
    }
    static func evaluate(_ expression:ShapeSheet.Expression,resolve:@escaping (String)throws->SheetValue,call:@escaping (String,[SheetValue])throws->SheetValue,scalar:Bool = false,specialCall:@escaping (String,[ShapeSheet.Expression],(ShapeSheet.Expression)throws->SheetValue)throws->SheetValue? = {_,_,_ in nil}) throws -> SheetValue {
        var operations = 0
        func eval(_ expression:ShapeSheet.Expression,_ depth:Int = 0) throws -> SheetValue {
            operations += 1;guard operations < 10000,depth < 64 else { throw DiagramError.invalid("ShapeSheet calculation limit exceeded.") }
            let result:SheetValue
            switch expression {
            case .number(let n):result = .number(n)
            case .measure(let n,let u):result = .quantity(n,u)
            case .string(let s):result = .string(s)
            case .reference(let name):if name.uppercased() == "TRUE" { return .boolean(true) };if name.uppercased() == "FALSE" { return .boolean(false) };result = try resolve(name)
            case .unary(let op,let value):let value = try eval(value,depth+1),n = try value.numeric(),number = op == "-" ? -n : n;result = value.unit.map{.quantity(number,$0)} ?? .number(number)
            case .binary(let op,let a,let b):
                let x = try eval(a,depth+1),y = try eval(b,depth+1)
                if op == "&" { result = .string(x.text+y.text) }
                else if ["=","==","!=","<>"].contains(op) { guard scalar || x.dimension == nil || y.dimension == nil || x.dimension == y.dimension else { throw DiagramError.invalid("Incompatible dimensional comparison.") };let equal:Bool;if case .string = x { equal = x.text == y.text } else if case .string = y { equal = x.text == y.text } else { equal = try x.numeric() == y.numeric() };result = .boolean(op == "=" || op == "==" ? equal : !equal) }
                else {
                    let p = try x.numeric(),q = try y.numeric()
                    switch op {
                    case "+","-":
                        guard scalar || x.dimension == y.dimension else { throw DiagramError.invalid("Incompatible dimensional field arithmetic.") }
                        let n = op == "+" ? p+q : p-q;result = scalar ? .number(n) : x.unit.map{.quantity(n,$0)} ?? .number(n)
                    case "*":guard scalar || x.unit == nil || y.unit == nil else { throw DiagramError.invalid("Area/compound field units are not yet implemented.") };result = scalar ? .number(p*q) : (x.unit ?? y.unit).map{.quantity(p*q,$0)} ?? .number(p*q)
                    case "/":guard q != 0 else { throw DiagramError.invalid("Division by zero.") };if scalar { result = .number(p/q) } else if x.unit != nil,y.unit == nil { result = .quantity(p/q,x.unit!) } else if x.unit == nil,y.unit != nil { throw DiagramError.invalid("Reciprocal field units are not yet implemented.") } else { guard x.dimension == y.dimension else { throw DiagramError.invalid("Incompatible dimensional division.") };result = .number(p/q) }
                    case "^":guard scalar || x.unit == nil else { throw DiagramError.invalid("Compound field units are not yet implemented.") };result = .number(pow(p,q))
                    case "<",">","<=",">=":guard scalar || x.dimension == nil || y.dimension == nil || x.dimension == y.dimension else { throw DiagramError.invalid("Incompatible dimensional comparison.") };result = .boolean(op == "<" ? p<q : op == ">" ? p>q : op == "<=" ? p<=q : p>=q);default:throw DiagramError.invalid("Unsupported ShapeSheet operator.") }
                }
            case .call(let name,let arguments):
                let name = name.uppercased()
                if name == "IF",arguments.count == 3 { return try eval(eval(arguments[0],depth+1).numeric() != 0 ? arguments[1] : arguments[2],depth+1) }
                if name == "IFERROR",arguments.count == 2 { do { return try eval(arguments[0],depth+1) } catch { return try eval(arguments[1],depth+1) } }
                if name == "SETATREF",(1...3).contains(arguments.count) { if arguments.count == 3,try eval(arguments[2],depth+1).numeric() != 0 { return .number(0) };if case .string(let reference) = arguments[0] { return try resolve(reference) };return try eval(arguments[0],depth+1) }
                if name == "SETATREFEXPR",arguments.isEmpty { return .number(0) }
                if name == "REF",arguments.isEmpty { throw DiagramError.invalid("ShapeSheet #REF! error.") }
                if name == "BOUND" { let n = try VisioBounds.evaluate(arguments){try eval($0,depth+1).numeric()},unit = try eval(arguments[0],depth+1).unit;return unit.map{.quantity(n,$0)} ?? .number(n) }
                if let value = try specialCall(name,arguments,{try eval($0,depth+1)}) { guard value.valid else { throw DiagramError.invalid("Invalid or oversized ShapeSheet result.") };return value }
                let values = try arguments.map{try eval($0,depth+1)}
                func arity(_ n:Int) throws { guard values.count == n else { throw DiagramError.invalid("\(name) expects \(n) arguments.") } }
                switch name {
                case "GUARD","SETATREFEXPR","SETATREFEVAL":try arity(1);result = values[0]
                case "STRSAME":guard (2...3).contains(values.count) else { throw DiagramError.invalid("STRSAME expects two or three arguments.") };let ignoreCase = values.count == 3 ? try values[2].numeric() != 0 : false;result = .boolean(values[0].text.compare(values[1].text,options:ignoreCase ? .caseInsensitive : []) == .orderedSame)
                case "UPPER":try arity(1);result = .string(values[0].text.uppercased())
                case "LOWER":try arity(1);result = .string(values[0].text.lowercased())
                case "LEN":try arity(1);result = .number(Double(values[0].text.utf16.count))
                case "LEFT","RIGHT":try arity(2);let n = try values[1].numeric();guard n >= 0,n <= 1_000_000 else { throw DiagramError.invalid("Invalid text length.") };let chars = values[0].text;result = .string(name == "LEFT" ? String(chars.prefix(Int(n))) : String(chars.suffix(Int(n))))
                case "TRIM":try arity(1);result = .string(values[0].text.split(whereSeparator:{$0.isWhitespace}).joined(separator:" "))
                case "CONCATENATE":result = .string(values.map(\.text).joined())
                case "FIELDPICTURE":try arity(1);let n = try values[0].numeric();guard let index = Int(exactly:n),index >= 0,index <= 10000 else { throw DiagramError.invalid("Invalid field format code.") };result = .string("esc(\(index))")
                default:
                    let numeric = Set(["PI","ABS","SQRT","SIN","COS","TAN","ASIN","ACOS","ATAN","ATAN2","LN","EXP","INT","SIGN","ROUND","MODULUS","DEG","RAD","POW","MIN","MAX","SUM","AND","OR","NOT"])
                    if numeric.contains(name) {
                        let unit = values.first?.unit
                        let preserve = !scalar && ["ROUND","INT","ABS"].contains(name) && unit != nil
                        let factor = preserve ? SheetValue.factor(unit!)! : 1
                        let arguments = try values.enumerated().map{ShapeSheet.Expression.number(try $0.element.numeric()*($0.offset == 0 ? factor : 1))}
                        let n = try ShapeSheet.evaluate(.call(name,arguments),resolve:{_ in throw DiagramError.invalid("Unexpected numeric reference") })/factor
                        if !scalar,["MIN","MAX","SUM"].contains(name),let unit = values.first(where:{$0.unit != nil})?.unit {
                            let dimensions = Set(values.compactMap(\.dimension));guard dimensions.count == 1,try values.allSatisfy({if $0.unit != nil { return true };return try $0.numeric() == 0}) else { throw DiagramError.invalid("Incompatible dimensional aggregate.") };result = .quantity(n,unit)
                        } else { result = preserve ? .quantity(n,unit!) : .number(n) }
                    }
                    else { result = try call(name,values) }
                }
            }
            guard result.valid else { throw DiagramError.invalid("Invalid or oversized ShapeSheet result.") };return result
        }
        return try eval(expression)
    }
}
