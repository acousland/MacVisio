import Foundation

/// Bounded string functions documented by the Visio ShapeSheet reference.
/// Positions and lengths use UTF-16 code units, as the current LEN evaluator does.
enum ShapeStringFunctions {
    private static let maximumTextBytes = 1_000_000
    private static let maximumSearchWork = 25_000_000

    static func evaluate(_ name: String, _ values: [SheetValue]) throws -> SheetValue {
        switch name {
        case "LEN":
            try arity(values, 1, name)
            return .number(Double(values[0].text.utf16.count))
        case "LEFT", "RIGHT":
            guard (1...2).contains(values.count) else { throw arityError(name, "one or two") }
            let text = values[0].text
            let units = text.utf16.count
            let amount = values.count == 2 ? try count(values[1], maximum: units, name: name) : min(1, units)
            let start = name == "LEFT" ? 0 : units - amount
            return .string(try substring(text, start: start, length: amount))
        case "MID":
            try arity(values, 3, name)
            let text = values[0].text
            let length = text.utf16.count
            let position = try positivePosition(values[1], name: name)
            let requested = try nonnegativeWhole(values[2], name: name)
            guard position <= length else { return .string("") }
            let start = position - 1
            let remaining = length - start
            let amount = requested >= Double(remaining) ? remaining : (Int(exactly: requested) ?? remaining)
            return .string(try substring(text, start: start, length: amount))
        case "FIND":
            guard (2...4).contains(values.count) else { throw arityError(name, "two to four") }
            let needle = values[0].text
            let text = values[1].text
            let length = text.utf16.count
            let position = values.count >= 3 ? try positivePosition(values[2], name: name) : 1
            guard position <= length else { throw invalid("FIND start_num is outside the text.") }
            let startOffset = position - 1
            let start = try index(atUTF16Offset: startOffset, in: text)
            if needle.isEmpty { return .number(Double(position)) }
            try boundSearchWork(text, needle)
            let ignoreCase: Bool
            if values.count == 4 { ignoreCase = try values[3].numeric() != 0 } else { ignoreCase = false }
            let options: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
            guard let match = text.range(of: needle, options: options, range: start..<text.endIndex) else {
                throw invalid("FIND could not locate the requested text.")
            }
            let offset = try utf16Offset(of: match.lowerBound, in: text)
            return .number(Double(offset + 1))
        case "REPLACE":
            try arity(values, 4, name)
            let old = values[0].text
            let units = old.utf16.count
            let position = try positivePosition(values[1], name: name)
            let requested = try nonnegativeWhole(values[2], name: name)
            guard position <= units + 1 else { throw invalid("REPLACE start_num is outside the text.") }
            let start = position - 1
            let remaining = units - start
            let amount = requested >= Double(remaining) ? remaining : (Int(exactly: requested) ?? remaining)
            let replacement = values[3].text
            let removedBytes = try substring(old, start: start, length: amount).utf8.count
            let resultBytes = try checkedResultBytes(old.utf8.count - removedBytes, replacement.utf8.count)
            guard resultBytes <= maximumTextBytes else { throw invalid("ShapeSheet text result exceeds the size limit.") }
            return .string(try substring(old, start: 0, length: start) + replacement + substring(old, start: start + amount, length: units - start - amount))
        case "SUBSTITUTE":
            guard (3...5).contains(values.count) else { throw arityError(name, "three to five") }
            let text = values[0].text
            let needle = values[1].text
            guard !needle.isEmpty else { throw invalid("SUBSTITUTE with an empty old_text is not supported.") }
            try boundSearchWork(text, needle)
            let replacement = values[2].text
            var occurrence: Int?
            if values.count >= 4 {
                let n = try values[3].numeric()
                guard n.isFinite, n > 0, n.rounded(.towardZero) == n else { throw invalid("SUBSTITUTE start_num must be a positive whole number.") }
                if n > Double(text.utf16.count) { return .string(text) }
                guard let exact = Int(exactly: n) else { return .string(text) }
                occurrence = exact
            }
            let ignoreCase: Bool
            if values.count == 5 { ignoreCase = try values[4].numeric() != 0 } else { ignoreCase = false }
            return .string(try substitute(text, needle: needle, replacement: replacement, occurrence: occurrence, ignoreCase: ignoreCase))
        case "REPT":
            try arity(values, 2, name)
            let text = values[0].text
            let rawCount = try values[1].numeric()
            guard rawCount.isFinite, rawCount >= 0 else { throw invalid("REPT count is outside the supported range.") }
            // Visio documents truncation toward zero for a fractional repeat count.
            let truncatedCount = rawCount.rounded(.towardZero)
            if text.isEmpty || truncatedCount == 0 { return .string("") }
            guard truncatedCount <= Double(maximumTextBytes), let repetitions = Int(exactly: truncatedCount) else {
                throw invalid("REPT count is outside the supported range.")
            }
            let (bytes, overflow) = text.utf8.count.multipliedReportingOverflow(by: repetitions)
            guard !overflow, bytes <= maximumTextBytes else { throw invalid("ShapeSheet text result exceeds the size limit.") }
            return .string(String(repeating: text, count: repetitions))
        case "INDEX":
            guard (2...4).contains(values.count) else { throw arityError(name, "two to four") }
            // The documented index is a zero-based Number. Do not guess at
            // Visio's coercion rules for strings, booleans, dates, or units.
            guard case .number(let rawIndex) = values[0], rawIndex.isFinite,
                  rawIndex.rounded(.towardZero) == rawIndex else {
                throw invalid("INDEX requires a finite whole-number index.")
            }
            let list = values[1].text
            guard list.utf8.count <= maximumTextBytes else { throw invalid("ShapeSheet text input exceeds the size limit.") }
            let delimiter = values.count >= 3 ? values[2].text : ";"
            guard !delimiter.isEmpty else { throw invalid("INDEX delimiter must not be empty.") }
            try boundSearchWork(list, delimiter)
            // Negative whole-number indexes are simply outside the list.
            // Very large finite indexes are also out of range without an Int
            // conversion that could overflow.
            guard rawIndex >= 0, let requested = Int(exactly: rawIndex),
                  let selected = try indexedItem(requested, in: list, delimiter: delimiter) else {
                return values.count == 4 ? values[3] : .string("")
            }
            return .string(selected)
        case "CHAR":
            try arity(values, 1, name)
            let n = try positivePosition(values[0], name: name)
            // ANSI bytes 128...255 depend on the Windows system code page. The
            // ASCII range is stable across ANSI code pages and is portable here.
            guard n <= 127, let scalar = UnicodeScalar(n) else { throw invalid("CHAR supports only code points 1 through 127 on this platform.") }
            return .string(String(scalar))
        case "UNICHAR":
            try arity(values, 1, name)
            let n = try positivePosition(values[0], name: name)
            guard n <= 65535, let scalar = UnicodeScalar(n) else { throw invalid("UNICHAR requires a Unicode scalar from 1 through 65535.") }
            return .string(String(scalar))
        default:
            throw invalid("Unsupported ShapeSheet string function: \(name).")
        }
    }

    private static func substitute(_ text: String, needle: String, replacement: String, occurrence: Int?, ignoreCase: Bool) throws -> String {
        let options: String.CompareOptions = ignoreCase ? [.caseInsensitive] : []
        var cursor = text.startIndex
        var seen = 0
        var replaced = 0
        var removedBytes = 0
        let end = text.endIndex

        while cursor < end, let match = text.range(of: needle, options: options, range: cursor..<end) {
            guard match.lowerBound >= cursor, match.upperBound > match.lowerBound else {
                throw invalid("SUBSTITUTE text search made no progress.")
            }
            seen += 1
            if occurrence == nil || seen == occurrence {
                let (sum, overflow) = removedBytes.addingReportingOverflow(text[match].utf8.count)
                guard !overflow else { throw invalid("SUBSTITUTE result size overflowed.") }
                removedBytes = sum
                replaced += 1
            }
            cursor = match.upperBound
            if let occurrence, seen == occurrence { break }
        }
        guard replaced > 0 else { return text }
        let replacements = replaced
        let (addedBytes, multiplicationOverflow) = replacement.utf8.count.multipliedReportingOverflow(by: replacements)
        let (baseBytes, subtractionOverflow) = text.utf8.count.subtractingReportingOverflow(removedBytes)
        guard !multiplicationOverflow, !subtractionOverflow else { throw invalid("SUBSTITUTE result size overflowed.") }
        let resultBytes = try checkedResultBytes(baseBytes, addedBytes)
        guard resultBytes <= maximumTextBytes else { throw invalid("ShapeSheet text result exceeds the size limit.") }

        var result = ""
        result.reserveCapacity(resultBytes)
        cursor = text.startIndex
        seen = 0
        while cursor < end, let match = text.range(of: needle, options: options, range: cursor..<end) {
            guard match.lowerBound >= cursor, match.upperBound > match.lowerBound else {
                throw invalid("SUBSTITUTE text search made no progress.")
            }
            seen += 1
            if occurrence == nil || seen == occurrence {
                result.append(contentsOf: text[cursor..<match.lowerBound])
                result.append(contentsOf: replacement)
            } else if occurrence != nil {
                // Keep earlier occurrences verbatim; start_num selects one
                // occurrence rather than replacing every occurrence up to it.
                result.append(contentsOf: text[cursor..<match.upperBound])
            }
            cursor = match.upperBound
            if let occurrence, seen == occurrence { break }
        }
        result.append(contentsOf: text[cursor..<end])
        return result
    }

    /// Selects a zero-based field while preserving null entries at either end
    /// and between adjacent delimiters. Searching by String ranges supports
    /// delimiters containing multiple or multibyte characters.
    private static func indexedItem(_ requested: Int, in text: String, delimiter: String) throws -> String? {
        var start = text.startIndex
        var item = 0
        while let match = text.range(of: delimiter, range: start..<text.endIndex) {
            if item == requested { return String(text[start..<match.lowerBound]) }
            item += 1
            start = match.upperBound
        }
        return item == requested ? String(text[start..<text.endIndex]) : nil
    }

    private static func substring(_ text: String, start: Int, length: Int) throws -> String {
        let units = Array(text.utf16)
        guard start >= 0, length >= 0, start <= units.count, length <= units.count - start else {
            throw invalid("Text range is outside the string.")
        }
        let end = start + length
        guard !splitsSurrogatePair(units, at: start), !splitsSurrogatePair(units, at: end) else {
            throw invalid("Text range splits a UTF-16 surrogate pair.")
        }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    private static func index(atUTF16Offset offset: Int, in text: String) throws -> String.Index {
        let units = Array(text.utf16)
        guard offset >= 0, offset <= units.count, !splitsSurrogatePair(units, at: offset) else {
            throw invalid("Text position splits a UTF-16 surrogate pair.")
        }
        return String.Index(utf16Offset: offset, in: text)
    }

    private static func utf16Offset(of index: String.Index, in text: String) throws -> Int {
        guard let utf16Index = index.samePosition(in: text.utf16) else { throw invalid("Invalid text position.") }
        return text.utf16.distance(from: text.utf16.startIndex, to: utf16Index)
    }

    private static func boundSearchWork(_ text: String, _ needle: String) throws {
        let (work, overflow) = text.utf16.count.multipliedReportingOverflow(by: needle.utf16.count)
        guard !overflow, work <= maximumSearchWork else { throw invalid("ShapeSheet text search limit exceeded.") }
    }

    private static func splitsSurrogatePair(_ units: [UInt16], at offset: Int) -> Bool {
        guard offset > 0, offset < units.count else { return false }
        let previous = units[offset - 1], next = units[offset]
        return (0xD800...0xDBFF).contains(previous) && (0xDC00...0xDFFF).contains(next)
    }

    private static func count(_ value: SheetValue, maximum: Int, name: String) throws -> Int {
        let n = try nonnegativeWhole(value, name: name)
        return n >= Double(maximum) ? maximum : Int(exactly: n) ?? maximum
    }

    private static func positivePosition(_ value: SheetValue, name: String) throws -> Int {
        let n = try value.numeric()
        guard n.isFinite, n >= 1, n.rounded(.towardZero) == n else { throw invalid("\(name) requires a positive whole-number position.") }
        guard let exact = Int(exactly: n) else { return Int.max }
        return exact
    }

    private static func nonnegativeWhole(_ value: SheetValue, name: String) throws -> Double {
        let n = try value.numeric()
        guard n.isFinite, n >= 0, n.rounded(.towardZero) == n else { throw invalid("\(name) requires a nonnegative whole-number length.") }
        return n
    }

    private static func checkedResultBytes(_ base: Int, _ added: Int) throws -> Int {
        let (result, overflow) = base.addingReportingOverflow(added)
        guard !overflow else { throw invalid("ShapeSheet text result size overflowed.") }
        return result
    }

    private static func arity(_ values: [SheetValue], _ expected: Int, _ name: String) throws {
        guard values.count == expected else { throw arityError(name, "\(expected)") }
    }

    private static func arityError(_ name: String, _ expected: String) -> DiagramError {
        .invalid("\(name) expects \(expected) arguments.")
    }

    private static func invalid(_ message: String) -> DiagramError { .invalid(message) }
}
