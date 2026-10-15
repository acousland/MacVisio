import Foundation

/// Snapshot-based search over stored value models. The caller owns navigation,
/// committed editing, calculation and undo; this type never changes a document.
enum DocumentSearch {
    enum Domain: Hashable, CaseIterable { case text, shape, data }

    enum Surface: Hashable {
        case nodeText, edgeLabel, shapeKind, objectID, sourceShapeID
        case dataKey(index: Int, key: String)
        case dataLabel(index: Int, key: String)
        case dataValue(index: Int, key: String)
    }

    struct Query {
        var text: String
        var caseSensitive = false
        var domains: Set<Domain> = Set(Domain.allCases)
        var maxResults = 10_000
    }

    enum Completion: Equatable { case complete, truncated, invalidBudget }
    struct Results: RandomAccessCollection {
        typealias Index = Int
        var matches: [Match]
        var completion: Completion
        var isTruncated: Bool { completion == .truncated }
        var startIndex: Int { matches.startIndex }
        var endIndex: Int { matches.endIndex }
        subscript(position: Int) -> Match { matches[position] }
    }

    struct Match: Equatable, Identifiable {
        struct ID: Hashable {
            var pageID: UUID
            var objectID: UUID
            var surface: Surface
            var location: Int
            var length: Int
        }
        var pageID: UUID
        var objectID: UUID
        var surface: Surface
        /// AppKit-compatible offsets into `source`, never Character offsets.
        var range: NSRange
        /// Exact searched surface, used to reject stale replacement requests.
        var source: String
        var id: ID { ID(pageID: pageID, objectID: objectID, surface: surface,
                        location: range.location, length: range.length) }
    }

    enum ReplacementBlock: Error, Equatable, LocalizedError {
        case missingTarget, ambiguousTarget, staleResult, invalidRange
        case readOnlySurface, locked, textProtected, unresolvedTextProtection
        case fieldContent, invalidRichText, unmappedTextFields

        var errorDescription: String? {
            switch self {
            case .missingTarget: return "The search target no longer exists."
            case .ambiguousTarget: return "The search target has duplicate identifiers."
            case .staleResult: return "The text changed. Search again before replacing it."
            case .invalidRange: return "The match must contain complete text characters."
            case .readOnlySurface: return "This shape or data result supports navigation only."
            case .locked: return "The shape, its group or its layer is locked."
            case .textProtected: return "The shape or its group protects text editing."
            case .unresolvedTextProtection: return "Text protection needs calculation before this edit."
            case .fieldContent: return "The match crosses a text field. Edit the field explicitly."
            case .invalidRichText: return "The text runs do not match the stored text."
            case .unmappedTextFields: return "Text fields have no run mapping for a safe replacement."
            }
        }
    }

    /// Document order, node order, surface order, then connector order. Hidden,
    /// locked and background objects remain searchable, each stored page once.
    /// Matches are nonoverlapping and always cover complete grapheme clusters.
    /// Result storage is bounded; callers must present `completion` before
    /// treating a search as exhaustive. Invalid budgets are explicit failures.
    static func find(_ query: Query, in diagram: Diagram) -> Results {
        guard (1...100_000).contains(query.maxResults) else { return Results(matches: [], completion: .invalidBudget) }
        guard !query.text.isEmpty, !query.domains.isEmpty else { return Results(matches: [], completion: .complete) }
        var output: [Match] = []
        for page in diagram.pages {
            func add(_ source: String, object: UUID, surface: Surface) -> Bool {
                let text = source as NSString
                var boundary = source.startIndex, boundaryOffset = 0
                // Match offsets only move forwards. Walk boundaries on demand
                // so a small budget does not allocate an index for huge text.
                func isBoundary(_ requested: Int) -> Bool {
                    while boundaryOffset < requested, boundary < source.endIndex {
                        boundaryOffset += String(source[boundary]).utf16.count
                        boundary = source.index(after: boundary)
                    }
                    return boundaryOffset == requested
                }
                let options: String.CompareOptions = query.caseSensitive ? [] : [.caseInsensitive]
                var offset = 0
                while offset < text.length {
                    let range = text.range(of: query.text, options: options,
                                           range: NSRange(location: offset, length: text.length - offset),
                                           locale: Locale(identifier: "en_US_POSIX"))
                    guard range.location != NSNotFound, range.length > 0 else { break }
                    if isBoundary(range.location), isBoundary(NSMaxRange(range)) {
                        // One extra accepted match proves incompleteness. Stop
                        // immediately without allocating or scanning more hits.
                        if output.count == query.maxResults { return true }
                        output.append(Match(pageID: page.id, objectID: object, surface: surface,
                                            range: range, source: source))
                    }
                    offset = NSMaxRange(range)
                }
                return false
            }
            for node in page.nodes {
                if query.domains.contains(.text), add(node.text, object: node.id, surface: .nodeText) {
                    return Results(matches: output, completion: .truncated)
                }
                if query.domains.contains(.shape) {
                    if add(node.kind.title, object: node.id, surface: .shapeKind) ||
                        add(node.id.uuidString, object: node.id, surface: .objectID) {
                        return Results(matches: output, completion: .truncated)
                    }
                    if let source = node.formatting.sourceShapeID, add(source, object: node.id, surface: .sourceShapeID) {
                        return Results(matches: output, completion: .truncated)
                    }
                }
                if query.domains.contains(.data) {
                    for (index, property) in node.formatting.data.enumerated() {
                        if add(property.key, object: node.id, surface: .dataKey(index: index, key: property.key)) ||
                            add(property.label, object: node.id, surface: .dataLabel(index: index, key: property.key)) ||
                            add(property.value, object: node.id, surface: .dataValue(index: index, key: property.key)) {
                            return Results(matches: output, completion: .truncated)
                        }
                    }
                }
            }
            for edge in page.edges {
                if query.domains.contains(.text), add(edge.label, object: edge.id, surface: .edgeLabel) {
                    return Results(matches: output, completion: .truncated)
                }
                if query.domains.contains(.shape) {
                    if add(edge.id.uuidString, object: edge.id, surface: .objectID) {
                        return Results(matches: output, completion: .truncated)
                    }
                    if let source = edge.sourceShapeID, add(source, object: edge.id, surface: .sourceShapeID) {
                        return Results(matches: output, completion: .truncated)
                    }
                }
            }
        }
        return Results(matches: output, completion: .complete)
    }

    /// Revalidate immediately before committing. A result's original enabled
    /// state is never authority to edit a newer snapshot.
    static func replacementBlock(for match: Match, in diagram: Diagram) -> ReplacementBlock? {
        do { _ = try replacing(match, with: (match.source as NSString).safeSubstring(match.range) ?? "", in: diagram); return nil }
        catch let block as ReplacementBlock { return block }
        catch { return .invalidRange }
    }

    /// Produces a candidate snapshot only. Shape metadata and typed shape data
    /// are navigation-only: replacing those requires a dedicated typed edit.
    static func replacing(_ match: Match, with replacement: String, in diagram: Diagram) throws -> Diagram {
        guard match.surface == .nodeText || match.surface == .edgeLabel else { throw ReplacementBlock.readOnlySurface }
        let pages = diagram.pages.indices.filter { diagram.pages[$0].id == match.pageID }
        guard let pageIndex = pages.first else { throw ReplacementBlock.missingTarget }
        guard pages.count == 1 else { throw ReplacementBlock.ambiguousTarget }
        let page = diagram.pages[pageIndex]
        let nodes = page.nodes.indices.filter { page.nodes[$0].id == match.objectID }
        let edges = page.edges.indices.filter { page.edges[$0].id == match.objectID }
        guard nodes.count + edges.count <= 1 else { throw ReplacementBlock.ambiguousTarget }
        var result = diagram
        if match.surface == .edgeLabel {
            guard let index = edges.first else { throw ReplacementBlock.missingTarget }
            let edge = page.edges[index]
            guard !page.isLocked(edge) else { throw ReplacementBlock.locked }
            if let parent = edge.parentID {
                let parents = page.nodes.filter { $0.id == parent }
                guard let node = parents.first else { throw ReplacementBlock.missingTarget }
                guard parents.count == 1 else { throw ReplacementBlock.ambiguousTarget }
                try checkTextProtection(node, in: page)
            }
            try validate(match, current: edge.label)
            result.pages[pageIndex].edges[index].label = (edge.label as NSString).replacingCharacters(in: match.range, with: replacement)
        } else {
            guard let index = nodes.first else { throw ReplacementBlock.missingTarget }
            var node = page.nodes[index]
            guard !page.isLocked(node) else { throw ReplacementBlock.locked }
            try checkTextProtection(node, in: page)
            try validate(match, current: node.text)
            let oldRuns = node.formatting.textRuns
            if let runs = oldRuns {
                guard runs.map(\.text).joined().utf8.elementsEqual(node.text.utf8) else { throw ReplacementBlock.invalidRichText }
                try checkFields(runs, range: match.range)
            } else if node.formatting.textFields?.isEmpty == false {
                throw ReplacementBlock.unmappedTextFields
            }
            let text = (node.text as NSString).replacingCharacters(in: match.range, with: replacement)
            if text.utf8.elementsEqual(node.text.utf8) { return diagram }
            // DiagramNode's plain-text observer is intentionally superseded by
            // these exact slices; a common-prefix rewrite loses targeted style.
            node.text = text
            if let runs = oldRuns { node.formatting.textRuns = replacingRuns(runs, range: match.range, replacement: replacement) }
            result.pages[pageIndex].nodes[index] = node
        }
        return result
    }

    private static func validate(_ match: Match, current: String) throws {
        guard current.utf8.elementsEqual(match.source.utf8) else { throw ReplacementBlock.staleResult }
        let range = match.range, length = current.utf16.count
        guard range.location >= 0, range.length > 0, range.location <= length,
              range.length <= length - range.location else { throw ReplacementBlock.invalidRange }
        let boundaries = characterBoundaries(in: current)
        guard boundaries.contains(range.location), boundaries.contains(NSMaxRange(range)) else { throw ReplacementBlock.invalidRange }
    }

    private static func characterBoundaries(in text: String) -> Set<Int> {
        var result: Set<Int> = [0]
        var offset = 0
        for character in text { offset += String(character).utf16.count; result.insert(offset) }
        return result
    }

    private static func checkTextProtection(_ node: DiagramNode, in page: DiagramPage) throws {
        var current: DiagramNode? = node
        var visited = Set<UUID>()
        while let target = current {
            guard visited.insert(target.id).inserted, visited.count <= 64 else { throw ReplacementBlock.textProtected }
            for (key, cell) in target.formatting.sheet where ["locktextedit", "protection.locktextedit"].contains(key.lowercased()) {
                let value = cell.value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let formula = cell.formula.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                if value == "TRUE" || Double(value).map({ $0 != 0 }) == true { throw ReplacementBlock.textProtected }
                guard value == "FALSE" || Double(value) == 0 else { throw ReplacementBlock.unresolvedTextProtection }
                guard ["", "NO FORMULA", "0", "FALSE", "FALSE()"].contains(formula) else { throw ReplacementBlock.unresolvedTextProtection }
            }
            if let parent = target.parentID {
                let parents = page.nodes.filter { $0.id == parent }
                guard let node = parents.first else { throw ReplacementBlock.missingTarget }
                guard parents.count == 1 else { throw ReplacementBlock.ambiguousTarget }
                current = node
            } else { current = nil }
        }
    }

    private static func checkFields(_ runs: [ShapeTextRun], range: NSRange) throws {
        var offset = 0
        for run in runs {
            let span = NSRange(location: offset, length: run.text.utf16.count)
            if run.fieldIndex != nil || run.fieldToken != nil {
                if NSIntersectionRange(span, range).length > 0 ||
                    (span.length == 0 && offset > range.location && offset < NSMaxRange(range)) {
                    throw ReplacementBlock.fieldContent
                }
            }
            offset += span.length
        }
    }

    private static func replacingRuns(_ runs: [ShapeTextRun], range: NSRange, replacement: String) -> [ShapeTextRun] {
        var prefix: [ShapeTextRun] = [], suffix: [ShapeTextRun] = []
        var inherited: ShapeTextRun?
        var offset = 0
        for run in runs {
            let length = run.text.utf16.count, end = offset + length
            if offset <= range.location, range.location < end { inherited = run }
            if length == 0 {
                if offset <= range.location { prefix.append(run) } else { suffix.append(run) }
            } else {
                if offset < range.location {
                    var part = run
                    part.text = (run.text as NSString).substring(to: min(length, range.location - offset))
                    prefix.append(part)
                }
                if end > NSMaxRange(range) {
                    var part = run
                    part.text = (run.text as NSString).substring(from: max(0, NSMaxRange(range) - offset))
                    suffix.append(part)
                }
            }
            offset = end
        }
        // A valid nonempty range always starts in a nonempty run.
        guard var inserted = inherited else { return prefix + suffix }
        inserted.text = replacement; inserted.fieldIndex = nil; inserted.fieldToken = nil
        return prefix + (replacement.isEmpty ? [] : [inserted]) + suffix
    }
}

private extension NSString {
    func safeSubstring(_ range: NSRange) -> String? {
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location else { return nil }
        return substring(with: range)
    }
}
