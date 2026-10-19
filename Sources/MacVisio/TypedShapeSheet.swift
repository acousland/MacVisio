import Foundation

struct ShapeSheetColor:Equatable {
    let red:Int,green:Int,blue:Int
    private let hslComponents:(hue:Int,saturation:Int,luminosity:Int)?
    init(red:Int,green:Int,blue:Int,hsl:(hue:Int,saturation:Int,luminosity:Int)? = nil) { self.red = red;self.green = green;self.blue = blue;hslComponents = hsl }
    init?(hex:String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6,let value = UInt32(digits,radix:16) else { return nil }
        self.init(red:Int((value >> 16) & 0xFF),green:Int((value >> 8) & 0xFF),blue:Int(value & 0xFF))
    }
    var hex:String { String(format:"#%02X%02X%02X",red,green,blue) }
    var hsl:(hue:Int,saturation:Int,luminosity:Int) {
        if let hslComponents { return hslComponents }
        let r = Double(red)/255,g = Double(green)/255,b = Double(blue)/255
        let maximum = max(r,g,b),minimum = min(r,g,b),delta = maximum-minimum
        let luminosity = (maximum+minimum)/2
        let saturation = delta == 0 ? 0 : delta/(1-abs(2*luminosity-1))
        var hue = 0.0
        if delta != 0 {
            if maximum == r { hue = (g-b)/delta+(g < b ? 6 : 0) }
            else if maximum == g { hue = (b-r)/delta+2 }
            else { hue = (r-g)/delta+4 }
        }
        return (Int((hue*40).rounded()) % 240,Int((saturation*240).rounded()),Int((luminosity*240).rounded()))
    }
    static func fromHSL(hue:Int,saturation:Int,luminosity:Int) -> ShapeSheetColor {
        let h = Double(hue)/40,s = Double(saturation)/240,l = Double(luminosity)/240
        let chroma = (1-abs(2*l-1))*s,x = chroma*(1-abs(h.truncatingRemainder(dividingBy:2)-1))
        let (r,g,b):(Double,Double,Double)
        switch h {
        case 0..<1:(r,g,b) = (chroma,x,0)
        case 1..<2:(r,g,b) = (x,chroma,0)
        case 2..<3:(r,g,b) = (0,chroma,x)
        case 3..<4:(r,g,b) = (0,x,chroma)
        case 4..<5:(r,g,b) = (x,0,chroma)
        default:(r,g,b) = (chroma,0,x)
        }
        let m = l-chroma/2
        return ShapeSheetColor(red:Int(((r+m)*255).rounded()),green:Int(((g+m)*255).rounded()),blue:Int(((b+m)*255).rounded()),hsl:(hue,saturation,luminosity))
    }
    static func ==(lhs:ShapeSheetColor,rhs:ShapeSheetColor) -> Bool { lhs.red == rhs.red && lhs.green == rhs.green && lhs.blue == rhs.blue }
}

enum SheetValue:Equatable {
    case number(Double),quantity(Double,String),string(String),boolean(Bool),date(Date),color(ShapeSheetColor)
    var text:String { switch self { case .number(let value),.quantity(let value,_):return ShapeSheetEngine.format(value);case .string(let value):return value;case .boolean(let value):return value ? "TRUE" : "FALSE";case .date(let value):return ISO8601DateFormatter().string(from:value);case .color(let value):return value.hex } }
    var unit:String? { if case .quantity(_,let unit) = self { return unit };return nil }
    var dimension:String? { unit.map{["DEG","RAD","DA"].contains($0.uppercased()) ? "angle" : $0.uppercased() == "DE" ? "duration" : "length"} }
    static func factor(_ unit:String) -> Double? { ["IN":1,"INCH":1,"INCHES":1,"PT":72,"MM":25.4,"CM":2.54,"M":0.0254,"FT":1/12,"YD":1/36,"DEG":180 / .pi,"RAD":1,"DL":1,"DP":1,"DT":1,"DA":1,"DE":1][unit.uppercased()] }
    func numeric() throws -> Double {
        switch self { case .number(let value),.quantity(let value,_):return value;case .boolean(let value):return value ? 1 : 0;case .date(let value):return value.timeIntervalSince1970/86400+25569;case .string(let value):if let n = Double(value),n.isFinite { return n };throw DiagramError.invalid("A numeric value was required.");case .color:throw DiagramError.invalid("A numeric value was required; a color result was supplied.") }
    }
    var valid:Bool { switch self { case .number(let n):return n.isFinite;case .quantity(let n,let u):return n.isFinite && Self.factor(u) != nil;case .string(let s):return s.utf8.count <= 1_000_000;case .date(let d):return d.timeIntervalSince1970.isFinite;case .boolean:return true;case .color(let c):return (0...255).contains(c.red) && (0...255).contains(c.green) && (0...255).contains(c.blue) } }
}
enum TypedShapeSheet {
    static func evaluate(_ formula:String,resolve:@escaping (String)throws->SheetValue,call:@escaping (String,[SheetValue])throws->SheetValue,scalar:Bool = false,specialCall:@escaping (String,[ShapeSheet.Expression],(ShapeSheet.Expression)throws->SheetValue)throws->SheetValue? = {_,_,_ in nil},colorPalette:ShapeSheetColorPalette = ShapeSheetColorPalette()) throws -> SheetValue {
        try evaluate(ShapeSheet.parse(formula),resolve:resolve,call:call,scalar:scalar,specialCall:specialCall,colorPalette:colorPalette)
    }
    static func evaluate(_ expression:ShapeSheet.Expression,resolve:@escaping (String)throws->SheetValue,call:@escaping (String,[SheetValue])throws->SheetValue,scalar:Bool = false,specialCall:@escaping (String,[ShapeSheet.Expression],(ShapeSheet.Expression)throws->SheetValue)throws->SheetValue? = {_,_,_ in nil},colorPalette:ShapeSheetColorPalette = ShapeSheetColorPalette()) throws -> SheetValue {
        var operations = 0
        func eval(_ expression:ShapeSheet.Expression,_ depth:Int = 0) throws -> SheetValue {
            operations += 1;guard operations < 10000,depth < 64 else { throw DiagramError.invalid("ShapeSheet calculation limit exceeded.") }
            let result:SheetValue
            switch expression {
            case .number(let n):result = .number(n)
            case .measure(let n,let u):result = .quantity(n,u)
            case .string(let s):result = .string(s)
            case .reference(let name):if name.uppercased() == "TRUE" { return .boolean(true) };if name.uppercased() == "FALSE" { return .boolean(false) };result = try resolve(name)
            case .omitted:throw DiagramError.invalid("An omitted argument is valid only in an optional function position.")
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
                if name == "INDEX" {
                    let values = try arguments.enumerated().map { offset, argument -> SheetValue in
                        if case .omitted = argument {
                            // Omitted optional delimiter means the documented
                            // semicolon default; an omitted errorvalue is empty.
                            return offset == 2 ? .string(";") : .string("")
                        }
                        return try eval(argument,depth+1)
                    }
                    let value = try ShapeStringFunctions.evaluate(name,values)
                    guard value.valid else { throw DiagramError.invalid("Invalid or oversized ShapeSheet result.") }
                    return value
                }
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
                case "GUARD","THEMEGUARD","SETATREFEXPR","SETATREFEVAL":try arity(1);result = values[0]
                case "STRSAME":guard (2...3).contains(values.count) else { throw DiagramError.invalid("STRSAME expects two or three arguments.") };let ignoreCase = values.count == 3 ? try values[2].numeric() != 0 : false;result = .boolean(values[0].text.compare(values[1].text,options:ignoreCase ? .caseInsensitive : []) == .orderedSame)
                case "STRSAMEEX":
                    try arity(4)
                    let locale = try values[2].numeric(),flags = try values[3].numeric()
                    guard let localeID = Int(exactly:locale),let options = Int(exactly:flags),localeID >= 0,options >= 0 else { result = .boolean(false);break }
                    // Visio specifies invalid locale IDs and comparison flags as FALSE.
                    let documentedFlags = 0x30007
                    guard options & ~documentedFlags == 0 else { result = .boolean(false);break }
                    // This portable subset handles invariant ASCII comparisons. Other
                    // locales, Unicode collation, and the remaining .NET options are
                    // deliberately left to a platform-compatible collation provider.
                    guard localeID == 0,options == 0 || options == 1 else { throw DiagramError.invalid("STRSAMEEX supports invariant ASCII comparisons with flags 0 or 1 only.") }
                    let first = Array(values[0].text.utf8),second = Array(values[1].text.utf8)
                    guard first.allSatisfy({$0 < 0x80}),second.allSatisfy({$0 < 0x80}) else { throw DiagramError.invalid("STRSAMEEX Unicode collation is not supported.") }
                    if options == 0 { result = .boolean(first == second) }
                    else { result = .boolean(first.count == second.count && zip(first,second).allSatisfy { asciiFold($0.0) == asciiFold($0.1) }) }
                case "UPPER":try arity(1);result = .string(values[0].text.uppercased())
                case "LOWER":try arity(1);result = .string(values[0].text.lowercased())
                case "LEN","LEFT","RIGHT","MID","FIND","REPLACE","SUBSTITUTE","REPT","INDEX","CHAR","UNICHAR":result = try ShapeStringFunctions.evaluate(name,values)
                case "TRIM":try arity(1);result = .string(values[0].text.split(whereSeparator:{$0.isWhitespace}).joined(separator:" "))
                case "CONCATENATE":result = .string(values.map(\.text).joined())
                case "FIELDPICTURE":try arity(1);let n = try values[0].numeric();guard let index = Int(exactly:n),index >= 0,index <= 10000 else { throw DiagramError.invalid("Invalid field format code.") };result = .string("esc(\(index))")
                case "SIGN":
                    guard (1...2).contains(values.count) else { throw DiagramError.invalid("SIGN expects one or two arguments.") }
                    if !scalar,values.count == 2,let fuzzDimension = values[1].dimension {
                        guard let numberDimension = values[0].dimension,numberDimension == fuzzDimension else { throw DiagramError.invalid("SIGN values use incompatible units.") }
                    }
                    result = .number(try ShapeSheet.sign(try values[0].numeric(),fuzz:values.count == 2 ? try values[1].numeric() : 1e-9))
                case "MODULUS":
                    try arity(2)
                    let remainder = try ShapeSheet.modulus(try values[0].numeric(),divisor:values[1].numeric())
                    // Unit numbers are evaluated in their canonical internal
                    // values; the first operand's unit remains result metadata.
                    result = !scalar ? values[0].unit.map{.quantity(remainder,$0)} ?? .number(remainder) : .number(remainder)
                case "CEILING","FLOOR":
                    guard (1...2).contains(values.count) else { throw DiagramError.invalid("\(name) expects one or two arguments.") }
                    let first = try values[0].numeric()
                    if scalar {
                        let multiple = values.count == 2 ? try values[1].numeric() : (first < 0 ? -1 : 1)
                        result = .number(try ShapeSheet.rounded(first,toMultiple:multiple,awayFromZero:name == "CEILING"))
                    } else if let unit = values[0].unit {
                        guard let factor = SheetValue.factor(unit) else { throw DiagramError.invalid("Rounding uses an unsupported unit.") }
                        // Invert the parser's literal-unit scale directly. A
                        // reciprocal multiply can push 26mm just below 26.
                        let displayNumber = first/(1/factor)
                        let displayMultiple:Double
                        if values.count == 2 {
                            let multiple = try values[1].numeric()
                            if let multipleUnit = values[1].unit {
                                guard values[0].dimension == values[1].dimension,SheetValue.factor(multipleUnit) != nil else { throw DiagramError.invalid("Rounding values use incompatible units.") }
                                displayMultiple = multiple/(1/factor)
                            } else { displayMultiple = multiple }
                        } else { displayMultiple = displayNumber < 0 ? -1 : 1 }
                        result = .quantity(try ShapeSheet.rounded(displayNumber,toMultiple:displayMultiple,awayFromZero:name == "CEILING")/factor,unit)
                    } else {
                        guard values.count == 1 || values[1].unit == nil else { throw DiagramError.invalid("Rounding values use incompatible units.") }
                        let multiple = values.count == 2 ? try values[1].numeric() : (first < 0 ? -1 : 1)
                        result = .number(try ShapeSheet.rounded(first,toMultiple:multiple,awayFromZero:name == "CEILING"))
                    }
                case "RGB":
                    try arity(3)
                    let components = try values.map { value -> Double in
                        guard case .number(let number) = value else { throw DiagramError.invalid("RGB components must be unitless numbers.") }
                        return number
                    }
                    result = .number(try colorPalette.index(for:components))
                case "BITAND","BITOR","BITXOR":
                    try arity(2)
                    guard !arguments.contains(where:ShapeSheet.containsMeasure) else { throw DiagramError.invalid("\(name) requires unitless whole-number operands from 0 through 65535.") }
                    let operands = try values.map { value -> Double in
                        guard case .number(let number) = value else { throw DiagramError.invalid("\(name) requires unitless whole-number operands from 0 through 65535.") }
                        return number
                    }
                    result = .number(try ShapeSheet.bitwise(name,operands))
                case "HSL":
                    try arity(3)
                    let components = try values.map { value -> Int in
                        let number = try value.numeric()
                        guard let integer = Int(exactly:number),integer >= 0 else { throw DiagramError.invalid("HSL components must be non-negative whole numbers.") }
                        return integer
                    }
                    guard components[0] <= 239,components[1] <= 240,components[2] <= 240 else { throw DiagramError.invalid("HSL components are outside the documented Visio ranges.") }
                    let color = ShapeSheetColor.fromHSL(hue:components[0],saturation:components[1],luminosity:components[2])
                    result = .number(try colorPalette.index(for:color,function:"HSL"))
                case "RED","GREEN","BLUE","HUE","SAT","LUM":
                    try arity(1)
                    let color = try colorValue(values[0],palette:colorPalette)
                    switch name {
                    case "RED":result = .number(Double(color.red))
                    case "GREEN":result = .number(Double(color.green))
                    case "BLUE":result = .number(Double(color.blue))
                    case "HUE":result = .number(Double(color.hsl.hue))
                    case "SAT":result = .number(Double(color.hsl.saturation))
                    default:result = .number(Double(color.hsl.luminosity))
                    }
                case "LUMDIFF":
                    try arity(2)
                    let first = try colorValue(values[0],palette:colorPalette).hsl.luminosity
                    let second = try colorValue(values[1],palette:colorPalette).hsl.luminosity
                    result = .number(Double(first-second))
                default:
                    let numeric = Set(["PI","ABS","SQRT","SIN","COS","TAN","ASIN","ACOS","ATAN","ATAN2","LN","EXP","INT","SIGN","ROUND","DEG","RAD","POW","MIN","MAX","SUM","AND","OR","NOT"])
                    if numeric.contains(name) {
                        let unit = values.first?.unit
                        let preserve = !scalar && ["ROUND","INT","ABS"].contains(name) && unit != nil
                        let factor = preserve ? SheetValue.factor(unit!)! : 1
                        let arguments = try values.enumerated().map { offset,value -> ShapeSheet.Expression in
                            let number = try value.numeric()
                            // ROUND shares CEILING/FLOOR's display-unit rule.
                            // Other existing numeric functions keep their path.
                            let operand = offset == 0 ? (name == "ROUND" ? number/(1/factor) : number*factor) : number
                            return .number(operand)
                        }
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

    private static func asciiFold(_ byte:UInt8) -> UInt8 { (0x41...0x5A).contains(byte) ? byte + 0x20 : byte }

    private static func colorValue(_ value:SheetValue,palette:ShapeSheetColorPalette) throws -> ShapeSheetColor {
        switch value {
        case .color(let color):return color
        case .number(let index):return palette.color(at:index) ?? ShapeSheetColor(red:0,green:0,blue:0)
        default:throw DiagramError.invalid("A color index or color result was required.")
        }
    }
}
