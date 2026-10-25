import Foundation

/// Visio 2019's format-picture language, as used by FORMAT() and by text-field Format cells.
///
/// Every rule here was observed in Visio 2019 (16.0.10730) through the formula reference probe
/// (docs/evidence/reference/formulas): numeric pictures format a value in its own display unit,
/// date pictures read a value's canonical number as a day serial (30 December 1899 is day 0),
/// `esc(n)`/`{<n>}` select built-in formats, and text only shows through `@` pictures.
enum VisioPictureFormat {
    /// Locale for names, separators and the system date/time pictures (Visio uses the Windows locale).
    nonisolated(unsafe) static var locale = Locale.current

    struct Value {
        enum Kind { case number, date, text }
        var kind: Kind
        var canonical: Double        // inches, radians or day serials
        var display: Double         // in `unit`
        var unit: String            // display abbreviation, empty when unitless
        var text: String
    }

    static func value(_ input: SheetValue, unit fallback: String = "") -> Value {
        switch input {
        case .string(let text): return Value(kind: .text, canonical: 0, display: 0, unit: "", text: text)
        case .date: let serial = (try? input.numeric()) ?? 0; return Value(kind: .date, canonical: serial, display: serial, unit: "", text: "")
        // A field's Value cell unit sets the display unit (TextFieldTests: Width shown in mm).
        case .quantity(let number, let unit):
            let display = !fallback.isEmpty && input.dimension == SheetValue.quantity(0, fallback).dimension && SheetValue.factor(fallback) != nil ? fallback : unit
            return quantity(number, unit: display)
        default:
            let number = (try? input.numeric()) ?? 0
            return fallback.isEmpty ? Value(kind: .number, canonical: number, display: number, unit: "", text: "") : quantity(number, unit: fallback)
        }
    }

    private static func quantity(_ number: Double, unit: String) -> Value {
        let key = unit.uppercased()
        let names: [String: String] = ["IN": "in", "INCH": "in", "INCHES": "in", "MM": "mm", "CM": "cm", "M": "m", "FT": "ft", "YD": "yd",
                                       "PT": "pt", "DEG": "deg", "DA": "deg", "RAD": "rad", "DE": "ed.", "DL": "in", "DP": "in", "DT": "in",
                                       "KM": "km", "MI": "mi", "ED": "ed.", "EH": "eh.", "EM": "em.", "ES": "es.", "EW": "ew."]
        let factor = key == "DA" ? 180 / Double.pi : SheetValue.factor(key) ?? 1
        return Value(kind: .number, canonical: number, display: number * factor, unit: names[key] ?? unit.lowercased(), text: "")
    }

    /// The picture FIELDPICTURE(code) returns (FIELDPICTURE reference cases, all 256 codes).
    static func fieldPicture(_ code: Int) -> String {
        switch code {
        case 0...18: return "esc(\(code))"
        case 19: return ""
        case 20...81: return fieldPictures[code - 20]
        case 200...221: return "{<\(code)>}"
        default: return "0"
        }
    }

    private static let fieldPictures: [String] = [
        "ddddd", "dddddd", "M/d/y", "MM/dd/yy", "MMM d, yyyy", "MMMM d, yyyy", "d/M/YY", "dd/MM/yy", "d MMM, yyyy", "d MMMM, yyyy",
        "T", "h:mm", "hh:mm", "H:mm", "HH:mm", "h:mm tt", "hh:mm tt", "@", "@-", "@+",
        "ggg_je_j'年'M'月'd'日 'ww_j", "yyyy'年'M'月'd'日 'ww_j", "ggg_je_j'年'M'月'd'日'", "yyyy'年'M'月'd'日'", "yyyy/M/d", "yy/MM/dd",
        "t_j h:mm", "t_j h:mm", "t_j hh'時'm'分'", "HH'時'm'分'", "ggg_cE_c'年'MMMM_c'月'D_c'日'", "gg_cE_c'年'MMMM_c'月'D_c'日'",
        "nn_c'年'M'月'd'日 'w_c", "nn_c'年'M'月'd'日'", "ggg_je_j'年'M'月'd'日 'ww_j", "yyyy'年'M'月'd'日 'ww_j", "ggg_je_j'年'M'月'd'日'",
        "yyyy'年'M'月'd'日'", "e_c'年'MMMM_c'月'D_c'日 'w_c", "e_c'年'MMMM_c'月'D_c'日'", "ggg_ke_k'년'M'월'd'일 'w_k", "yyyy'년'M'월'd'일 'w_k",
        "ggg_ke_k'년'M'월'd'일'", "yyyy'년'M'월'd'일'", "yyyy-M-d", "yy-MM-dd", "t_c h:mm", "t_k h:mm", "t_j h'時'm'分'", "HH'時'm'分'",
        "t_c h'時'm'分'", "HH'時'm'分'", "t_k h'시'm'분'", "HH'시'm'분'", "h:mm tt_e", "hh:mm tt_e", "yyyy'年'M'月'd'日'", "yyyy' 'MM' 'dd",
        "w_s' 'yyyy' 'MM' 'dd", "w_s' 'yyyy'年'M'月'd'日'", "t_s h:mm", "t_s hh:mm",
    ]

    /// System date/time formats behind {<200>}...{<221>} (Visio reads them from the Windows locale;
    /// these are en-GB's, the reference build's locale).
    private static let systemPictures: [Int: String] = [
        200: "dd/MM/yyyy", 201: "dddd, dd MMMM yyyy", 202: "dd MMMM yyyy", 203: "dd/MM/yy", 204: "yyyy-MM-dd", 205: "dd-MMM-yy",
        206: "dd.MM.yyyy", 207: "dd MMM. yy", 208: "dd MMMM yyyy", 209: "MMMM yy", 210: "MMM-yy", 211: "dd/MM/yyyy HH:mm",
        212: "dd/MM/yyyy HH:mm:ss", 213: "h:mm tt", 214: "h:mm:ss tt", 215: "HH:mm", 216: "HH:mm:ss",
        217: "dd/MM/yyyy", 218: "dd/MM/yyyy", 219: "dd/MM/yyyy", 220: "dd/MM/yyyy", 221: "dd/MM/yyyy",
    ]

    static func format(_ input: SheetValue, picture: String, unit: String = "") throws -> String {
        let value = value(input, unit: unit)
        let trimmed = picture.trimmingCharacters(in: .whitespaces)
        if let code = escapeCode(trimmed) {
            if code.braces, let system = systemPictures[code.number] { return value.kind == .text ? "" : try datePicture(system, value) }
            return try escape(code.number, value)
        }
        switch trimmed {
        case "": return ""  // an empty picture shows nothing (FIELD-*-0)
        case "C": return value.kind == .text ? "" : try longDateTime(value)
        case "D":
            // An empty date picture, which still refuses a negative serial (FORMATX-neg-27).
            if value.kind != .text, value.canonical < 0 { throw DiagramError.invalid("A date picture needs a nonnegative day serial (#VALUE!).") }
            return ""
        case "T": return value.kind == .text ? "" : try datePicture("HH:mm:ss", value)
        case "ddddd": return value.kind == .text ? "" : try datePicture(shortDate, value)
        case "dddddd": return value.kind == .text ? "" : try datePicture(longDate, value)
        default: break
        }
        if trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}") { return value.kind == .text ? "" : try datePicture(String(trimmed.dropFirst(2).dropLast(2)), value) }
        if picture.contains("@") { return textPicture(picture, value) }
        if isDatePicture(picture) { return try datePicture(picture, value) }
        return numericPicture(picture, value)
    }

    // MARK: Built-in codes

    private static func escapeCode(_ picture: String) -> (number: Int, braces: Bool)? {
        if picture.hasPrefix("esc("), picture.hasSuffix(")"), let n = Int(picture.dropFirst(4).dropLast()) { return (n, false) }
        if picture.hasPrefix("{<"), picture.hasSuffix(">}"), let n = Int(picture.dropFirst(2).dropLast(2)) { return (n, true) }
        return nil
    }

    private static func escape(_ code: Int, _ value: Value) throws -> String {
        if value.kind == .text { return value.text }
        if value.kind == .date { return try general(value) }
        func withUnit(_ text: String, _ include: Bool) -> String { include && !value.unit.isEmpty ? text + " " + value.unit : text }
        switch code {
        case 0, 1: return withUnit(trimmedDecimals(value.display, 4), code == 1)
        case 2...9: return withUnit(fixed(value.display, (code - 2) / 2), code % 2 == 1)
        case 10, 13, 14: return feetInches(value.canonical, denominator: code == 10 ? nil : code == 13 ? 9 : 99)
        case 11: return trimmedDecimals(value.canonical, 4) + " rad"
        case 12: return trimmedDecimals(value.canonical * 180 / .pi, 2) + " deg"
        case 15...18: return withUnit(fraction(value.display, maximum: code < 17 ? 9 : 99), code % 2 == 0)
        default: return try general(value)
        }
    }

    /// Visio's default display: four decimals and the unit, or the short date and long time.
    static func general(_ value: Value) throws -> String {
        switch value.kind {
        case .text: return value.text
        case .date: return try datePicture(shortDate + " HH:mm:ss", value)
        case .number: return fixed(value.display, 4) + (value.unit.isEmpty ? "" : " " + value.unit)
        }
    }

    private static func longDateTime(_ value: Value) throws -> String {
        let time = try datePicture("HH:mm:ss", value)
        return value.canonical.rounded(.down) >= 1 ? try datePicture(longDate, value) + " " + time : time
    }

    private static var shortDate: String { DateFormatter.dateFormat(fromTemplate: "ddMMyyyy", options: 0, locale: locale) ?? "dd/MM/yyyy" }
    private static var longDate: String { DateFormatter.dateFormat(fromTemplate: "ddMMMMyyyy", options: 0, locale: locale) ?? "dd MMMM yyyy" }

    // MARK: Text pictures

    private static func textPicture(_ picture: String, _ value: Value) -> String {
        let text = value.kind == .text ? value.text : ((try? general(value)) ?? "")
        var result = "", index = picture.startIndex
        while index < picture.endIndex {
            let character = picture[index]; index = picture.index(after: index)
            guard character == "@" else { result.append(character); continue }
            if index < picture.endIndex, picture[index] == "-" { result += text.lowercased(); index = picture.index(after: index) }
            else if index < picture.endIndex, picture[index] == "+" { result += text.uppercased(); index = picture.index(after: index) }
            else { result += text }
        }
        return result
    }

    // MARK: Numeric pictures

    private static func sections(_ picture: String) -> [String] {
        var result: [String] = [], current = "", quoted = false
        for character in picture {
            if character == "\"" { quoted.toggle() }
            if character == ";", !quoted { result.append(current); current = "" } else { current.append(character) }
        }
        return result + [current]
    }

    private static func numericPicture(_ picture: String, _ value: Value) -> String {
        let parts = sections(picture)
        var number = value.display, section = parts[0]
        // Visio formats a negative value's magnitude in the negative section, dropping bare punctuation.
        // Text always uses the first section.
        if value.kind != .text, number < 0, parts.count > 1 { section = parts[1]; number = -number }
        else if value.kind != .text, number == 0, parts.count > 2 { section = parts[2] }
        var placeholders = "", literalsBefore: [(Int, String)] = [], position = 0, index = section.startIndex
        var unitToken: (index: Int, upper: Bool)?, scientific = false
        while index < section.endIndex {
            let character = section[index]; index = section.index(after: index)
            switch character {
            case "\"":
                var literal = ""
                while index < section.endIndex, section[index] != "\"" { literal.append(section[index]); index = section.index(after: index) }
                if index < section.endIndex { index = section.index(after: index) }
                literalsBefore.append((position, literal))
            case "\\": if index < section.endIndex { literalsBefore.append((position, String(section[index]))); index = section.index(after: index) }
            case "0", "#", "?", ".", ",", "/": placeholders.append(character); position += 1
            case "E", "e":
                scientific = true; placeholders.append("E"); position += 1
                while index < section.endIndex, "+-0".contains(section[index]) { placeholders.append(section[index]); position += 1; index = section.index(after: index) }
            case "u", "U": unitToken = (position, character == "U"); literalsBefore.append((position, "\u{0}"))
            case " ": literalsBefore.append((position, " "))
            default: break  // %, -, (, ) and other bare punctuation are not output
            }
        }
        var digits = ""
        if value.kind != .text, !placeholders.isEmpty {
            digits = placeholders.contains("/") ? fractionPlaceholder(number, value) : scientific ? scientificDigits(number, placeholders) : decimalDigits(number, placeholders)
        }
        // Literals before any placeholder lead; the rest follow the digits. A plain number's
        // fraction already carries its spacing ("6172839 /").
        var prefix = "", suffix = ""
        let plainFraction = placeholders.contains("/") && value.kind == .number && value.unit.isEmpty
        for (at, literal) in literalsBefore where !(plainFraction && literal == " ") {
            let text = literal == "\u{0}" ? (unitToken.map { $0.upper ? value.unit.uppercased() : value.unit } ?? "") : literal
            if at == 0, !placeholders.isEmpty { prefix += text } else { suffix += text }
        }
        return prefix + digits + suffix
    }

    private static func decimalDigits(_ number: Double, _ placeholders: String) -> String {
        let pieces = placeholders.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = pieces[0], fraction = pieces.count > 1 ? pieces[1] : ""
        let minimumFraction = fraction.filter { $0 == "0" }.count, maximumFraction = fraction.filter { "0#?".contains($0) }.count
        let rounded = round(number, maximumFraction)
        var text = String(format: "%.\(maximumFraction)f", abs(rounded))
        var parts = text.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        var decimals = parts.count > 1 ? parts[1] : ""
        while decimals.count > minimumFraction, decimals.hasSuffix("0") { decimals.removeLast() }
        var whole = parts[0]
        let minimumWhole = integer.filter { $0 == "0" }.count
        if whole == "0", minimumWhole == 0 { whole = "" }
        while whole.count < minimumWhole { whole = "0" + whole }
        if integer.contains(",") { whole = grouped(whole) }
        parts = [whole] + (decimals.isEmpty ? [] : [decimals])
        text = parts.joined(separator: decimalSeparator)
        if text.isEmpty { text = "0" }
        return (rounded < 0 ? "-" : "") + text
    }

    private static func scientificDigits(_ number: Double, _ placeholders: String) -> String {
        let mantissa = placeholders.prefix { $0 != "E" }, exponentDigits = placeholders.drop { $0 != "E" }.filter { $0 == "0" }.count
        let decimals = mantissa.split(separator: ".").dropFirst().first?.count ?? 0
        guard number != 0 else { return String(format: "%.\(decimals)fE+%0\(exponentDigits)d", 0.0, 0) }
        var exponent = Int(floor(log10(abs(number)))), scaled = number / pow(10, Double(exponent))
        if abs(round(scaled, decimals)) >= 10 { exponent += 1; scaled /= 10 }
        return String(format: "%.\(decimals)f", round(scaled, decimals)) + "E" + (exponent < 0 ? "-" : "+") + String(format: "%0\(exponentDigits)d", abs(exponent))
    }

    /// Visio prints a plain number's exact numerator over a bare slash ("# ?/?" turns 1234.5678 into
    /// "6172839 /"); unit values and dates print as whole numbers.
    private static func fractionPlaceholder(_ number: Double, _ value: Value) -> String {
        guard value.kind == .number, value.unit.isEmpty else { return decimalDigits(number, "#") }
        var denominator = 1.0, scaled = number
        while scaled != scaled.rounded(), denominator < 1e9 { scaled *= 10; denominator *= 10 }
        var numerator = scaled.rounded(), divisor = gcd(abs(numerator), denominator)
        if divisor == 0 { divisor = 1 }
        numerator /= divisor
        return String(format: "%.0f", numerator) + " /"
    }

    // MARK: Fractions and feet-inches

    private static func fraction(_ number: Double, maximum: Int) -> String {
        let negative = number < 0, magnitude = abs(number)
        var whole = magnitude.rounded(.down), remainder = magnitude - whole
        var best = (numerator: 0, denominator: 1, error: remainder)
        for denominator in 1...maximum {
            let numerator = Int((remainder * Double(denominator)).rounded())
            let error = abs(remainder - Double(numerator) / Double(denominator))
            if error < best.error - 1e-12 { best = (numerator, denominator, error) }
        }
        if best.numerator == best.denominator { whole += 1; best.numerator = 0 }
        var text = best.numerator == 0 ? String(format: "%.0f", whole) : whole == 0 ? "\(best.numerator)/\(best.denominator)" : String(format: "%.0f", whole) + " \(best.numerator)/\(best.denominator)"
        if negative, text != "0" { text = "-" + text }
        return text
    }

    private static func feetInches(_ inches: Double, denominator: Int?) -> String {
        let negative = inches < 0, magnitude = abs(inches)
        let feet = (magnitude / 12).rounded(.down), rest = magnitude - feet * 12
        let inchText = denominator.map { fraction(rest, maximum: $0) } ?? trimmedDecimals(rest, 3)
        return (negative ? "-" : "") + String(format: "%.0f", feet) + "' " + inchText + "\""
    }

    // MARK: Date pictures

    private static func isDatePicture(_ picture: String) -> Bool {
        var quoted = false, hasDate = false
        for character in picture {
            if character == "\"" || character == "'" { quoted.toggle(); continue }
            if quoted { continue }
            if "0#?".contains(character) { return false }
            if "yYMdDhHmst[w".contains(character) { hasDate = true }
        }
        return hasDate
    }

    static func datePicture(_ picture: String, _ value: Value) throws -> String {
        let serial = value.kind == .number ? value.canonical : value.canonical
        if value.kind == .text { return picture.filter { $0 == " " } }
        guard serial >= 0, serial < 2958466 else { throw DiagramError.invalid("A date picture needs a nonnegative day serial (#VALUE!).") }
        // Visio rounds the time to whole seconds without carrying into the date: a value just below
        // one day shows 30/12/1899 24:00:00.
        let day = serial.rounded(.down), seconds = Int(((serial - day) * 86400).rounded())
        let hour = seconds / 3600, minute = seconds / 60 % 60, second = seconds % 60
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(byAdding: .day, value: Int(day), to: Date(timeIntervalSince1970: -2209161600))!
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let symbols = DateFormatter(); symbols.locale = locale
        let totalSeconds = (serial * 86400).rounded()
        var result = "", index = picture.startIndex
        func run(_ character: Character) -> Int {
            var count = 0, cursor = index
            while cursor < picture.endIndex, picture[cursor] == character { count += 1; cursor = picture.index(after: cursor) }
            return count
        }
        func pad(_ number: Int, _ width: Int) -> String { String(format: "%0\(width)d", number) }
        while index < picture.endIndex {
            let character = picture[index], count = run(character)
            var consumed = count
            switch character {
            case "y", "Y": result += count >= 3 ? pad(parts.year!, 4) : pad(parts.year! % 100, 2)
            case "M":
                switch count {
                case 1: result += String(parts.month!)
                case 2: result += pad(parts.month!, 2)
                case 3: result += symbols.shortMonthSymbols[parts.month! - 1]
                default: result += symbols.monthSymbols[parts.month! - 1]
                }
            case "d", "D":
                switch count {
                case 1: result += String(parts.day!)
                case 2: result += pad(parts.day!, 2)
                case 3: result += symbols.shortWeekdaySymbols[parts.weekday! - 1]
                case 4: result += symbols.weekdaySymbols[parts.weekday! - 1]
                case 5: result += try datePicture(shortDate, value)
                default: result += try datePicture(longDate, value)
                }
            case "w": result += symbols.weekdaySymbols[parts.weekday! - 1]
            case "H": result += count >= 2 ? pad(hour, 2) : String(hour)
            case "h": let twelve = hour % 12 == 0 ? 12 : hour % 12; result += count >= 2 ? pad(twelve, 2) : String(twelve)
            case "m": result += count >= 2 ? pad(minute, 2) : String(minute)
            case "s": result += count >= 2 ? pad(second, 2) : String(second)
            case "t":
                let afternoon = hour % 24 >= 12
                result += count >= 2 ? (afternoon ? symbols.pmSymbol.uppercased() : symbols.amSymbol.uppercased()) : (afternoon ? "P" : "A")
            case "[":
                guard let close = picture[index...].firstIndex(of: "]") else { result.append(character); consumed = 1; break }
                let token = picture[picture.index(after: index)..<close]
                let elapsed = token.first == "h" ? totalSeconds / 3600 : token.first == "m" ? totalSeconds / 60 : totalSeconds
                // Visio holds elapsed counts in a 32-bit integer ([s] of a 2026 date overflows).
                result += elapsed > Double(Int32.max) ? String(Int32.min) : String(Int(elapsed.rounded(.down)))
                consumed = picture.distance(from: index, to: close) + 1
            case "'", "\"":
                var literal = "", cursor = picture.index(after: index)
                while cursor < picture.endIndex, picture[cursor] != character { literal.append(picture[cursor]); cursor = picture.index(after: cursor) }
                result += literal
                consumed = picture.distance(from: index, to: min(picture.endIndex, picture.index(after: cursor)))
            case "_": consumed = min(2, picture.distance(from: index, to: picture.endIndex))  // calendar markers such as _e
            case "q", "g", "e", "n": break
            default: result += String(repeating: character, count: count)
            }
            index = picture.index(index, offsetBy: consumed)
        }
        return result
    }

    // MARK: Number helpers

    private static var decimalSeparator: String { locale.decimalSeparator ?? "." }

    private static func grouped(_ digits: String) -> String {
        let separator = locale.groupingSeparator ?? ","
        var result = "", count = 0
        for character in digits.reversed() {
            if count > 0, count % 3 == 0 { result = separator + result }
            result = String(character) + result; count += 1
        }
        return result
    }

    static func round(_ number: Double, _ decimals: Int) -> Double {
        let scale = pow(10, Double(decimals))
        // Snap representation error (2.345 is 2.34499...) before rounding half away from zero.
        let scaled = (number * scale * 1e9).rounded() / 1e9
        return scaled.rounded(.toNearestOrAwayFromZero) / scale
    }

    static func fixed(_ number: Double, _ decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", round(number, decimals))
        return decimalSeparator == "." ? text : text.replacingOccurrences(of: ".", with: decimalSeparator)
    }

    static func trimmedDecimals(_ number: Double, _ decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", round(number, decimals))
        if text.contains(".") { while text.hasSuffix("0") { text.removeLast() }; if text.hasSuffix(".") { text.removeLast() } }
        if text == "-0" { text = "0" }
        return decimalSeparator == "." ? text : text.replacingOccurrences(of: ".", with: decimalSeparator)
    }

    private static func gcd(_ a: Double, _ b: Double) -> Double { b == 0 ? a : gcd(b, a.truncatingRemainder(dividingBy: b)) }
}
