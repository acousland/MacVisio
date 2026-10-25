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
    /// Windows' integer HLS conversion (HLSMAX 240), which Visio uses: TONE(RGB(100,50,0),50) is
    /// RGB(89,50,11) exactly (reference case COLORX-4).
    static func fromHSL(hue:Int,saturation:Int,luminosity:Int) -> ShapeSheetColor {
        let scale = 240,maximum = 255
        guard saturation != 0 else { let value = luminosity*maximum/scale;return ShapeSheetColor(red:value,green:value,blue:value,hsl:(hue,saturation,luminosity)) }
        let second = luminosity <= scale/2 ? (luminosity*(scale+saturation)+scale/2)/scale : luminosity+saturation-(luminosity*saturation+scale/2)/scale
        let first = 2*luminosity-second
        func channel(_ input:Int) -> Int {
            var hue = input;if hue < 0 { hue += scale };if hue > scale { hue -= scale }
            let value:Int
            if hue < scale/6 { value = first+((second-first)*hue+scale/12)/(scale/6) }
            else if hue < scale/2 { value = second }
            else if hue < scale*2/3 { value = first+((second-first)*(scale*2/3-hue)+scale/12)/(scale/6) }
            else { value = first }
            return (value*maximum+scale/2)/scale
        }
        return ShapeSheetColor(red:channel(hue+scale/3),green:channel(hue),blue:channel(hue-scale/3),hsl:(hue,saturation,luminosity))
    }
    static func ==(lhs:ShapeSheetColor,rhs:ShapeSheetColor) -> Bool { lhs.red == rhs.red && lhs.green == rhs.green && lhs.blue == rhs.blue }
}

enum SheetValue:Equatable {
    case number(Double),quantity(Double,String),string(String),boolean(Bool),date(Date),color(ShapeSheetColor),point(Double,Double)
    var text:String { switch self { case .number(let value),.quantity(let value,_):return ShapeSheetEngine.format(value);case .string(let value):return value;case .boolean(let value):return value ? "TRUE" : "FALSE";case .date(let value):return ISO8601DateFormatter().string(from:value);case .color(let value):return value.hex;case .point(let x,let y):return String(format:"PNT(%.4f,%.4f)",x,y) } }
    /// The text Visio's string functions see for a value (reference STRCOERCE): a number to 14 significant
    /// digits, a quantity in its own unit followed by its mark (" for inches, ' for feet, MM, DEG, ED. ...).
    var coercedText:String {
        func general(_ value:Double) -> String {
            var text = String(format:"%.14G",locale:Locale(identifier:"en_US_POSIX"),value)
            if let e = text.firstIndex(of:"E") {
                var exponent = String(text[text.index(after:e)...]);let negative = exponent.hasPrefix("-")
                exponent = String(exponent.drop{ $0 == "+" || $0 == "-" }.drop{ $0 == "0" })
                text = String(text[..<e])+"E"+(negative ? "-" : "")+(exponent.isEmpty ? "0" : exponent)
            }
            return text
        }
        switch self {
        case .number(let value):return general(value)
        case .quantity(let value,let unit):
            var shown = unit.uppercased();if ["INCH","INCHES","DL","DP","DT"].contains(shown) { shown = "IN" };if shown == "DA" { shown = "DEG" };if shown == "DE" { shown = "ED" }
            let number = general(value*(Self.factor(shown) ?? 1))
            switch shown { case "IN":return number+"\"";case "FT":return number+"'";case "ED","EH","EM","ES","EW":return number+shown+".";default:return number+shown }
        case .color(let color):return "RGB(\(color.red), \(color.green), \(color.blue))"
        case .date(let date):let f = DateFormatter();f.locale = Locale(identifier:"en_GB");f.dateFormat = "dd/MM/yyyy";return f.string(from:date)
        default:return text
        }
    }
    var unit:String? { if case .quantity(_,let unit) = self { return unit };return nil }
    var dimension:String? { unit.map{["DEG","RAD","DA"].contains($0.uppercased()) ? "angle" : ["DE","ED","EH","EM","ES","EW"].contains($0.uppercased()) ? "duration" : "length"} }
    static func factor(_ unit:String) -> Double? { ["IN":1,"INCH":1,"INCHES":1,"PT":72,"MM":25.4,"CM":2.54,"M":0.0254,"FT":1/12,"YD":1/36,"DEG":180 / .pi,"RAD":1,"DL":1,"DP":1,"DT":1,"DA":1,"DE":1,
                                                         "KM":0.0000254,"MI":1.0/63360,"ED":1,"EH":24,"EM":1440,"ES":86400,"EW":1.0/7][unit.uppercased()] }
    func numeric() throws -> Double {
        switch self { case .number(let value),.quantity(let value,_):return value;case .boolean(let value):return value ? 1 : 0;case .date(let value):return Self.serial(value);case .string(let value):if let n = Double(value),n.isFinite { return n };throw DiagramError.invalid("A numeric value was required.");case .color:throw DiagramError.invalid("A numeric value was required; a color result was supplied.");case .point:throw ShapeSheetError(kind:.value,message:"A numeric value was required; a point was supplied.") }
    }
    /// Visio date serials count local wall-clock days from 30 December 1899, independent of time zone.
    static func serial(_ date:Date) -> Double {
        (date.timeIntervalSince1970+Double(TimeZone.current.secondsFromGMT(for:date)))/86400+25569
    }
    static func date(serial:Double) -> Date {
        let utc = Date(timeIntervalSince1970:(serial-25569)*86400)
        return utc.addingTimeInterval(-Double(TimeZone.current.secondsFromGMT(for:utc)))
    }
    var valid:Bool { switch self { case .number(let n):return n.isFinite;case .quantity(let n,let u):return n.isFinite && Self.factor(u) != nil;case .string(let s):return s.utf8.count <= 1_000_000;case .date(let d):return d.timeIntervalSince1970.isFinite;case .boolean:return true;case .color(let c):return (0...255).contains(c.red) && (0...255).contains(c.green) && (0...255).contains(c.blue);case .point(let x,let y):return x.isFinite && y.isFinite } }
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
                func isText(_ value:SheetValue) -> Bool { if case .string(let text) = value { return Double(text) == nil };return false }
                if op == "&" { result = .string(x.text+y.text) }
                // Visio compares text case-insensitively.
                else if ["=","==","!=","<>"].contains(op) { guard scalar || x.dimension == nil || y.dimension == nil || x.dimension == y.dimension else { throw DiagramError.invalid("Incompatible dimensional comparison.") };let equal:Bool;if case .string = x { equal = x.text.caseInsensitiveCompare(y.text) == .orderedSame } else if case .string = y { equal = x.text.caseInsensitiveCompare(y.text) == .orderedSame } else { equal = try x.numeric() == y.numeric() };result = .boolean(op == "=" || op == "==" ? equal : !equal) }
                // Ordering comparisons read non-numeric text as zero ("b">"A" is FALSE).
                else if ["<",">","<=",">="].contains(op),isText(x) || isText(y) {
                    let p = isText(x) ? 0 : try x.numeric(),q = isText(y) ? 0 : try y.numeric()
                    result = .boolean(op == "<" ? p<q : op == ">" ? p>q : op == "<=" ? p<=q : p>=q)
                }
                else {
                    let p = try x.numeric(),q = try y.numeric()
                    func isDate(_ value:SheetValue) -> Bool { if case .date = value { return true };return false }
                    switch op {
                    case "+" where !scalar && (isDate(x) || isDate(y)),"-" where !scalar && (isDate(x) || isDate(y)):
                        // Date + days is a date; date - date is an elapsed duration in days.
                        if isDate(x),isDate(y) { guard op == "-" else { throw DiagramError.invalid("Dates cannot be added together.") };result = .quantity(p-q,"DE") }
                        else if isDate(x) { result = .date(SheetValue.date(serial:op == "+" ? p+q : p-q)) }
                        else { guard op == "+" else { throw DiagramError.invalid("A date cannot be subtracted from a number.") };result = .date(SheetValue.date(serial:p+q)) }
                    case "+","-":
                        // Visio adds internal values and keeps the first operand's unit: 1 in+1 is 2 in, and
                        // ATAN2(1,1)+1 in is an angle (reference cases EXPR-23, EXPR-36, EXPR-41).
                        // A drawing-unit (DL) operand adopts an explicit unit: TEXTHEIGHT(...)+0MM is in mm.
                        let unit = x.unit?.uppercased() == "DL" && y.unit != nil ? y.unit : x.unit ?? y.unit
                        let n = op == "+" ? p+q : p-q;result = unit.map{.quantity(n,$0)} ?? .number(n)
                    // Visio keeps a product of two lengths (an area) in the first operand's length unit.
                    case "*":result = (x.unit ?? y.unit).map{.quantity(p*q,$0)} ?? .number(p*q)
                    case "/":guard q != 0 else { throw DiagramError.invalid("Division by zero.") };if x.unit != nil,y.unit == nil { result = .quantity(p/q,x.unit!) } else if scalar { result = .number(p/q) } else if x.unit == nil,y.unit != nil { throw DiagramError.invalid("Reciprocal field units are not yet implemented.") } else { guard x.dimension == y.dimension else { throw DiagramError.invalid("Incompatible dimensional division.") };result = .number(p/q) }
                    case "^":guard scalar || x.unit == nil else { throw DiagramError.invalid("Compound field units are not yet implemented.") };result = .number(pow(p,q))
                    case "<",">","<=",">=":guard scalar || x.dimension == nil || y.dimension == nil || x.dimension == y.dimension else { throw DiagramError.invalid("Incompatible dimensional comparison.") };result = .boolean(op == "<" ? p<q : op == ">" ? p>q : op == "<=" ? p<=q : p>=q);default:throw DiagramError.invalid("Unsupported ShapeSheet operator.") }
                }
            case .call(let name,let given):
                let name = name.uppercased(),arguments = ShapeSheet.withoutSurplusArguments(name,given)
                try ShapeSheet.requireReferenceFunction(name)
                // Only the reference functions' no-target (#REF!) result is supported, so the qualified cell is #REF!.
                if name == ShapeSheet.sheetReferenceCell { _ = try eval(arguments[0],depth+1);throw ShapeSheetError(kind:.reference,message:"The referenced sheet has no supported target (#REF!).") }
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
                if ["ISERR","ISERRNA","ISERROR","ISERRVALUE"].contains(name) {
                    guard arguments.count == 1 else { throw DiagramError.invalid("\(name) expects one argument.") }
                    do { _ = try eval(arguments[0],depth+1);return .boolean(false) }
                    catch {
                        let kind = ShapeSheetError.kind(of:error)
                        return .boolean(name == "ISERROR" || name == "ISERR" && kind != .na || name == "ISERRNA" && kind == .na || name == "ISERRVALUE" && kind == .value)
                    }
                }
                // GETREF takes a cell reference; Visio rejects any other argument (VEC-GETREF-*).
                if name == "GETREF" { guard arguments.count == 1,case .reference = arguments[0] else { throw DiagramError.invalid("GETREF requires a cell reference.") } }
                // SETATREF of a literal is #VALUE! (VEC-SETATREF-length).
                if name == "SETATREF",let first = arguments.first { switch first { case .number,.measure: throw DiagramError.invalid("SETATREF requires a cell reference (#VALUE!)."); default: break } }
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
                // Visio maps case one character at a time, so ß stays ß (UPPER-2).
                case "UPPER":try arity(1);result = .string(String(values[0].coercedText.map { character -> String in let upper = String(character).uppercased();return upper.count == 1 ? upper : String(character) }.joined()))
                case "LOWER":try arity(1);result = .string(String(values[0].coercedText.map { character -> String in let lower = String(character).lowercased();return lower.count == 1 ? lower : String(character) }.joined()))
                case "LEN","LEFT","RIGHT","MID","FIND","REPLACE","SUBSTITUTE","REPT","INDEX","CHAR","UNICHAR":result = try ShapeStringFunctions.evaluate(name,values)
                case "TRIM":try arity(1);result = .string(values[0].coercedText.split(whereSeparator:{$0.isWhitespace}).joined(separator:" "))
                case "CONCATENATE":result = .string(values.map(\.coercedText).joined())
                case "FIELDPICTURE":try arity(1);let n = try values[0].numeric();guard n.isFinite,n >= 0,n < 65536 else { throw DiagramError.invalid("Invalid field format code.") };result = .string(VisioPictureFormat.fieldPicture(Int(n)))
                case "SIGN":
                    guard (1...2).contains(values.count) else { throw DiagramError.invalid("SIGN expects one or two arguments.") }
                    let signed = try ShapeSheet.sign(try values[0].numeric(),fuzz:values.count == 2 ? try values[1].numeric() : 1e-9)
                    // A unitless value takes the fuzz's unit: SIGN(0.05,1 mm) is 25.4 mm (ROUNDING-18).
                    result = !scalar ? (values[0].unit ?? (values.count == 2 ? values[1].unit : nil)).map{.quantity(signed,$0)} ?? .number(signed) : .number(signed)
                case "DEG","RAD","ANG360":
                    try arity(1)
                    let value = try values[0].numeric(),isAngle = values[0].dimension == "angle" || (scalar && ShapeSheet.isAngle(arguments[0]))
                    let radians = name == "RAD" && !isAngle ? value * .pi/180 : name == "ANG360" ? ShapeSheet.angle360(value) : value
                    result = scalar ? .number(radians) : .quantity(radians,name == "RAD" ? "RAD" : values[0].unit.flatMap{["DEG","RAD"].contains($0.uppercased()) ? $0 : nil} ?? "DEG")
                case "POW":
                    try arity(2)
                    let base = try values[0].numeric(),exponent = try values[1].numeric()
                    guard base != 0 || exponent != 0 else { throw DiagramError.invalid("POW(0,0) is undefined (#NUM!).") }
                    let power = pow(base,exponent)
                    result = !scalar ? values[0].unit.map{.quantity(power,$0)} ?? .number(power) : .number(power)
                case "SQRT" where !scalar && values.count == 1 && values[0].unit != nil:
                    throw DiagramError.invalid("SQRT of a dimensioned value has no dimension (#DIM!).")
                case "ASIN","ACOS","ATAN":
                    try arity(1)
                    // These functions return PtgAngDft, whose canonical value
                    // is radians with DA metadata. Reuse the scalar numerical
                    // path and its domain/non-finite failure behavior.
                    let angle = try ShapeSheet.evaluate(.call(name,[.number(try values[0].numeric())]),resolve:{_ in throw DiagramError.invalid("Unexpected inverse-trigonometric reference.")})
                    result = scalar ? .number(angle) : .quantity(angle,"DA")
                case "ATAN2":
                    try arity(2)
                    let angle = try ShapeSheet.arcTangent2(try values[0].numeric(),values[1].numeric())
                    // PtgAngDft uses radians internally with the DA unit. Keep
                    // this metadata in typed hosts; geometry still uses a scalar.
                    result = scalar ? .number(angle) : .quantity(angle,"DA")
                case "MODULUS":
                    try arity(2)
                    let remainder = try ShapeSheet.modulus(try values[0].numeric(),divisor:values[1].numeric())
                    // Unit numbers are evaluated in their canonical internal
                    // values; the first operand's unit remains result metadata.
                    if !scalar,case .date = values[0] { result = .date(SheetValue.date(serial:remainder)) }  // EXPR-47
                    else { result = !scalar ? values[0].unit.map{.quantity(remainder,$0)} ?? .number(remainder) : .number(remainder) }
                case "CEILING","FLOOR":
                    guard (1...2).contains(values.count) else { throw DiagramError.invalid("\(name) expects one or two arguments.") }
                    let first = try values[0].numeric()
                    // Geometry (scalar) hosts round in display units too; they only read the number.
                    if let unit = values[0].unit {
                        guard let factor = SheetValue.factor(unit) else { throw DiagramError.invalid("Rounding uses an unsupported unit.") }
                        // Invert the parser's literal-unit scale directly. A
                        // reciprocal multiply can push 26mm just below 26.
                        let displayNumber = first/(1/factor)
                        // Visio rounds the display value to a multiple taken in internal units:
                        // CEILING(2.5 cm,1 cm) is 2.7559 cm (COERCE-27).
                        let displayMultiple = values.count == 2 ? try values[1].numeric() : (displayNumber < 0 ? -1 : 1)
                        result = .quantity(try ShapeSheet.rounded(displayNumber,toMultiple:displayMultiple,awayFromZero:name == "CEILING")/factor,unit)
                    } else {
                        // A unit multiple is taken in internal units: CEILING(0.5,1 mm) is 0.5118 (ROUNDING-13).
                        let multiple = values.count == 2 ? try values[1].numeric() : (first < 0 ? -1 : 1)
                        result = .number(try ShapeSheet.rounded(first,toMultiple:multiple,awayFromZero:name == "CEILING"))
                    }
                case "RGB":
                    try arity(3)
                    // Components are internal values truncated and wrapped: RGB(72 pt,0,0) is RGB(1,0,0) (COERCE-3/4).
                    let components = try values.map { ShapeSheet.colorComponent(try $0.numeric()) }
                    // Typed results are colors, as in Visio; scalar hosts still need a color-table index.
                    if scalar { result = .number(try colorPalette.index(for:components.map(Double.init))) }
                    else { result = .color(ShapeSheetColor(red:components[0],green:components[1],blue:components[2])) }
                case "BITAND","BITOR","BITXOR":
                    try arity(2)
                    result = .number(try ShapeSheet.bitwise(name,values.map { try $0.numeric() }))  // internal values (COERCE-5)
                case "HSL":
                    try arity(3)
                    let components = try values.map { value -> Int in
                        let number = try value.numeric()
                        guard let integer = Int(exactly:number),integer >= 0 else { throw DiagramError.invalid("HSL components must be non-negative whole numbers.") }
                        return integer
                    }
                    guard components[0] <= 239,components[1] <= 240,components[2] <= 240 else { throw DiagramError.invalid("HSL components are outside the documented Visio ranges.") }
                    let color = ShapeSheetColor.fromHSL(hue:components[0],saturation:components[1],luminosity:components[2])
                    result = scalar ? .number(try colorPalette.index(for:color,function:"HSL")) : .color(color)
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
                    let numeric = Set(["PI","ABS","SQRT","SIN","COS","TAN","LN","EXP","LOG10","TRUNC","INT","SIGN","ROUND","DEG","RAD","POW","MIN","MAX","SUM","AND","OR","NOT"])
                    if numeric.contains(name) {
                        // MIN and MAX skip text that is not a number; with nothing left they are 0 (STRCOERCE, VEC-MAX-text).
                        var values = values
                        if ["MIN","MAX"].contains(name) { guard !values.isEmpty else { throw DiagramError.invalid("\(name) needs an argument.") };values = values.filter { (try? $0.numeric()) != nil };if values.isEmpty { values = [.number(0)] } }
                        let unit = values.first?.unit
                        // LN and LOG10 also keep their argument's unit: LN(2 in) is 0.6931 in (VEC-LN-length).
                        let preserve = ["ROUND","INT","ABS","LN","LOG10"].contains(name) && unit != nil
                        // LN and LOG10 work on the internal value (LN(25.4 mm) is 0 mm).
                        let factor = preserve && !["LN","LOG10"].contains(name) ? SheetValue.factor(unit!)! : 1
                        let arguments = try values.enumerated().map { offset,value -> ShapeSheet.Expression in
                            // MIN and MAX read text that is not a number as 0 (VEC-MAX-text).
                            let number = try value.numeric()
                            // ROUND shares CEILING/FLOOR's display-unit rule.
                            // Other existing numeric functions keep their path.
                            let operand = offset == 0 ? (name == "ROUND" ? number/(1/factor) : number*factor) : number
                            return .number(operand)
                        }
                        let n = try ShapeSheet.evaluate(.call(name,arguments),resolve:{_ in throw DiagramError.invalid("Unexpected numeric reference") })/factor
                        // MIN and MAX keep the unit of the operand they select; SUM keeps the first unit
                        // (COERCE-17/18/19). Mixed dimensions are not an error in Visio.
                        if !scalar,["MIN","MAX"].contains(name),let selected = values.first(where:{(try? $0.numeric()) == n}) { result = selected.unit.map{.quantity(n,$0)} ?? .number(n) }
                        else if !scalar,name == "SUM",let unit = values.first(where:{$0.unit != nil})?.unit { result = .quantity(n,unit) }
                        else { result = preserve ? .quantity(n,unit!) : .number(n) }
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
        // Other values are read as a color-table index; text that is not a number is index 0 (black).
        default:return palette.color(at:(try? value.numeric()) ?? 0) ?? ShapeSheetColor(red:0,green:0,blue:0)
        }
    }
}
