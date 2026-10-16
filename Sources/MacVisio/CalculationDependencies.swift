import Foundation

/// Counts work performed, rather than estimating it from the number of inputs.
struct CalculationWork: Equatable {
    var geometryPasses = 0
    var geometryPages = 0
    var geometryNodes = 0
    var fieldPages = 0
    var fieldNodes = 0
    var cellRequests = 0
    var evaluatedCells = 0
    /// Typed-context and field formula evaluations; pin-default attempts are separate.
    var formulaEvaluations = 0
    var defaultPinFormulaEvaluations = 0
    var textMeasurements = 0
    var contexts = 0
    var dependencyNodesIndexed = 0
    var conservativePages = 0
    var inputComparisonNodes = 0
    var dependencySourcesCompared = 0
    var hostNodesPrepared = 0
    var richTextNodes = 0

    mutating func add(_ other: CalculationWork) {
        geometryPasses += other.geometryPasses
        geometryPages += other.geometryPages
        geometryNodes += other.geometryNodes
        fieldPages += other.fieldPages
        fieldNodes += other.fieldNodes
        cellRequests += other.cellRequests
        evaluatedCells += other.evaluatedCells
        formulaEvaluations += other.formulaEvaluations
        defaultPinFormulaEvaluations += other.defaultPinFormulaEvaluations
        textMeasurements += other.textMeasurements
        contexts += other.contexts
        dependencyNodesIndexed += other.dependencyNodesIndexed
        conservativePages += other.conservativePages
        inputComparisonNodes += other.inputComparisonNodes
        dependencySourcesCompared += other.dependencySourcesCompared
        hostNodesPrepared += other.hostNodesPrepared
        richTextNodes += other.richTextNodes
    }
}

/// A node-granularity dependency graph. The evaluator still resolves individual
/// cells lazily, with its existing local cycle and resource limits.
struct CalculationDependencyIndex {
    struct Source: Equatable {
        var id: UUID
        var parent: UUID?
        var publicID: String
        var sourceShapeID: String?
        var identifierAvailable: Bool
        var formulas: [String]
        var calculatesGeometry: Bool
        var hasFields: Bool
        var dependencySignature: [String]
        static func == (lhs: Source, rhs: Source) -> Bool {
            lhs.id == rhs.id && lhs.parent == rhs.parent && lhs.publicID == rhs.publicID
                && lhs.sourceShapeID == rhs.sourceShapeID
                && lhs.identifierAvailable == rhs.identifierAvailable
                && lhs.calculatesGeometry == rhs.calculatesGeometry && lhs.hasFields == rhs.hasFields
                && lhs.dependencySignature == rhs.dependencySignature
        }
    }
    let sources: [Source]
    private(set) var dependents: [UUID: Set<UUID>] = [:]
    private(set) var requiresFullPage = false
    private(set) var volatileNodes: Set<UUID> = []
    private(set) var nodeIndices: [UUID: Int] = [:]
    private(set) var identifiers: [String: UUID] = [:]
    private(set) var geometryNodeIDs: Set<UUID> = []
    private(set) var fieldNodeIDs: Set<UUID> = []

    static func sources(page: DiagramPage, binding: VisioPageBinding?, fieldIdentifiers: Bool = false)
        -> [Source]
    {
        var fieldIDs: [UUID: String] = [:]
        if fieldIdentifiers {
            var allocator = try? VisioIDAllocator(
                reserved: Array(Set(page.nodes.compactMap { $0.formatting.sourceShapeID })))
            for node in page.nodes {
                fieldIDs[node.id] = node.formatting.sourceShapeID ?? (try? allocator?.allocate())
            }
        }
        return page.nodes.enumerated().map { offset, node in
            var cells = node.formatting.sheet
            for point in node.formatting.connectionPoints {
                cells[point.xCell] = point.x
                cells[point.yCell] = point.y
            }
            for name in GeometrySheet.names(node.formatting.geometry ?? []) {
                cells[name] = GeometrySheet.cell(name, on: node)
            }
            for control in node.formatting.controls {
                for (key, cell) in control.cells { cells["Controls.\(control.name).\(key)"] = cell }
            }
            for field in node.formatting.textFields ?? [] {
                for (key, cell) in field.cells { cells["Fields.\(field.index).\(key)"] = cell }
            }
            let formulas = cells.keys.sorted().compactMap { key -> String? in
                guard let cell = cells[key] else { return nil }
                let formula = cell.formula.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !formula.isEmpty, !["INH", "NO FORMULA"].contains(formula.uppercased()) else {
                    return nil
                }
                // The cell name participates in identity even when source matches.
                return key + "\u{0}" + formula
            }
            func packed(_ tag: String, _ parts: [String]) -> String {
                tag + parts.map { String($0.utf8.count) + ":" + $0 }.joined()
            }
            func signature(_ expression: ShapeSheet.Expression) -> String {
                switch expression {
                case .number, .measure: return "#"
                case .string(let text): return packed("s", [text])
                case .reference(let reference): return packed("r", [reference])
                case .omitted: return "_"
                case .unary(let op, let child): return packed("u", [op, signature(child)])
                case .binary(let op, let a, let b): return packed("b", [op, signature(a), signature(b)])
                case .call(let name, let arguments):
                    return packed("c", [name.uppercased()] + arguments.map(signature))
                }
            }
            let dependencySignature = formulas.map { entry -> String in
                let components = entry.split(
                    separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
                guard components.count == 2, let expression = try? ShapeSheet.parse(String(components[1]))
                else { return entry }
                return String(components[0]) + "\u{0}" + signature(expression)
            }
            return Source(
                id: node.id, parent: node.parentID,
                publicID: fieldIdentifiers
                    ? (fieldIDs[node.id] ?? "")
                    : (binding?.nodeIDs[node.id] ?? node.formatting.sourceShapeID ?? String(offset + 1)),
                sourceShapeID: node.formatting.sourceShapeID,
                identifierAvailable: !fieldIdentifiers || fieldIDs[node.id] != nil,
                formulas: formulas,
                calculatesGeometry: !node.formatting.sheet.isEmpty
                    || !node.formatting.connectionPoints.isEmpty || !node.formatting.controls.isEmpty
                    || node.formatting.geometry != nil,
                hasFields: node.formatting.textFields?.isEmpty == false,
                dependencySignature: dependencySignature)
        }
    }

    init(sources: [Source], pageHasFormulas: Bool) {
        self.sources = sources
        requiresFullPage = pageHasFormulas
        for (offset, source) in sources.enumerated() {
            nodeIndices[source.id] = offset
            if source.calculatesGeometry { geometryNodeIDs.insert(source.id) }
            if source.hasFields { fieldNodeIDs.insert(source.id) }
            if source.identifierAvailable {
                if identifiers[source.publicID] != nil {
                    requiresFullPage = true
                } else {
                    identifiers[source.publicID] = source.id
                }
            }
        }
        let safeFunctions: Set<String> = [
            "PI", "ABS", "SQRT", "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ATAN2", "LN", "EXP", "INT",
            "SIGN", "ROUND", "MODULUS", "DEG", "RAD", "POW", "MIN", "MAX", "SUM", "AND", "OR", "NOT", "IF",
            "IFERROR", "GUARD", "THEMEGUARD", "SETATREF", "SETATREFEXPR", "SETATREFEVAL", "BOUND", "REF",
            "STRSAME", "STRSAMEEX", "UPPER", "LOWER", "LEN", "LEFT", "RIGHT", "MID", "FIND", "REPLACE",
            "SUBSTITUTE", "REPT", "INDEX", "CHAR", "UNICHAR", "TRIM", "CONCATENATE", "FIELDPICTURE",
            "CEILING", "FLOOR", "RGB", "BITAND", "BITOR", "BITXOR", "HSL", "RED", "GREEN", "BLUE", "HUE",
            "SAT", "LUM", "LUMDIFF", "THEMEVAL", "THEMEPROP", "ISTHEMED", "SHAPETEXT", "TEXTWIDTH",
            "TEXTHEIGHT", "PAGENAME", "PAGENUMBER", "PAGECOUNT", "BKGPAGENAME", "ID", "DATE", "FORMAT",
        ]
        let volatileFunctions: Set<String> = ["NOW", "TODAY", "RAND", "RANDOM"]
        for source in sources {
            if let parent = source.parent { dependents[parent, default: []].insert(source.id) }
            func reference(_ name: String) {
                guard let mark = name.firstIndex(of: "!") else { return }
                let owner = String(name[..<mark])
                if owner.caseInsensitiveCompare("ThePage") == .orderedSame { return }
                let target: UUID?
                if owner.caseInsensitiveCompare("ParentShape") == .orderedSame {
                    target = source.parent
                } else if owner.uppercased().hasPrefix("SHEET.") {
                    let key = String(owner.dropFirst(6))
                    target = identifiers[key] ?? UInt32(key).flatMap { identifiers[String($0)] }
                } else {
                    target = nil
                }
                guard let target else {
                    requiresFullPage = true
                    return
                }
                dependents[target, default: []].insert(source.id)
            }
            func inspect(_ expression: ShapeSheet.Expression) {
                switch expression {
                case .reference(let name): reference(name)
                case .unary(_, let child): inspect(child)
                case .binary(_, let left, let right):
                    inspect(left)
                    inspect(right)
                case .call(let rawName, let arguments):
                    let name = rawName.uppercased()
                    if volatileFunctions.contains(name) {
                        volatileNodes.insert(source.id)
                    } else if !safeFunctions.contains(name) {
                        requiresFullPage = true
                    }
                    if name == "SETATREF", let first = arguments.first, case .string(let name) = first {
                        reference(name)
                    }
                    for argument in arguments { inspect(argument) }
                case .number, .measure, .string, .omitted: break
                }
            }
            for entry in source.formulas {
                let formula = String(
                    entry.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false).last ?? ""
                )
                if let expression = try? ShapeSheet.parse(formula) {
                    inspect(expression)
                } else {
                    requiresFullPage = true
                }
            }
        }
    }

    func affected(by changed: Set<UUID>) -> Set<UUID> {
        var result = changed.union(volatileNodes)
        var pending = Array(result)
        while let id = pending.popLast() {
            for dependent in dependents[id, default: []] where result.insert(dependent).inserted {
                pending.append(dependent)
            }
        }
        return result
    }
}

/// Document-owned retained syntax/dependency data. This class never retains an
/// a per-context resolved-value cache, an AppKit object or another document.
/// Retained node maps are immutable input snapshots, replaced by exact changes.
final class CalculationSession {
    private struct Entry {
        var sources: [CalculationDependencyIndex.Source]
        var pageHasFormulas: Bool
        var index: CalculationDependencyIndex
    }
    private struct Key: Hashable {
        var pageID: UUID
        var fieldIdentifiers: Bool
    }
    private var entries: [Key: Entry] = [:]
    private struct Host {
        var nodes: [UUID: DiagramNode]
        var indices: [UUID: Int]
    }
    private var hosts: [UUID: Host] = [:]
    private(set) var indexedNodes = 0
    private(set) var comparedSources = 0
    private(set) var preparedHostNodes = 0
    let maximumPages: Int
    init(maximumPages: Int = 64) { self.maximumPages = max(1, maximumPages) }

    func index(
        for page: DiagramPage, binding: VisioPageBinding?, fieldIdentifiers: Bool = false,
        changes: PageChangeSet? = nil, trustChanges: Bool = false
    ) -> CalculationDependencyIndex {
        let key = Key(pageID: page.id, fieldIdentifiers: fieldIdentifiers)
        var sources: [CalculationDependencyIndex.Source]
        if trustChanges, let entry = entries[key], !structural(changes) {
            guard let changes, !changes.affectedNodeIDs.isEmpty || changes.pagePropertiesChanged else {
                return entry.index
            }
            sources = entry.sources
            var sourceChanged = false
            let indices = entry.index.nodeIndices
            for id in changes.affectedNodeIDs {
                guard let index = indices[id], page.nodes.indices.contains(index), page.nodes[index].id == id
                else {
                    return rebuildIndex(page: page, binding: binding, fieldIdentifiers: fieldIdentifiers)
                }
                var single = page
                single.nodes = [page.nodes[index]]
                var source = CalculationDependencyIndex.sources(
                    page: single, binding: binding, fieldIdentifiers: false)[0]
                if source.sourceShapeID != entry.sources[index].sourceShapeID {
                    // Field allocation can also reassign implicit IDs when an
                    // explicit source ID is inserted, removed or renamed.
                    return rebuildIndex(page: page, binding: binding, fieldIdentifiers: fieldIdentifiers)
                }
                if fieldIdentifiers || (binding?.nodeIDs[id] == nil && source.sourceShapeID == nil) {
                    source.publicID = entry.sources[index].publicID
                    source.identifierAvailable = entry.sources[index].identifierAvailable
                }
                if source != entry.sources[index] {
                    sources[index] = source
                    sourceChanged = true
                }
                comparedSources += 1
            }
            if !sourceChanged && !changes.pagePropertiesChanged { return entry.index }
        } else {
            sources = CalculationDependencyIndex.sources(
                page: page, binding: binding, fieldIdentifiers: fieldIdentifiers)
            comparedSources += sources.count
        }
        let pageHasFormulas =
            page.sheet?.values.contains {
                let source = $0.formula.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                return !source.isEmpty && !["INH", "NO FORMULA"].contains(source)
            } ?? false
        if let entry = entries[key], entry.sources == sources, entry.pageHasFormulas == pageHasFormulas {
            return entry.index
        }
        let index = CalculationDependencyIndex(sources: sources, pageHasFormulas: pageHasFormulas)
        indexedNodes += sources.count
        if entries.count >= maximumPages, entries[key] == nil { entries.removeAll(keepingCapacity: true) }
        entries[key] = Entry(sources: sources, pageHasFormulas: pageHasFormulas, index: index)
        return index
    }

    private func rebuildIndex(page: DiagramPage, binding: VisioPageBinding?, fieldIdentifiers: Bool)
        -> CalculationDependencyIndex
    {
        entries.removeValue(forKey: Key(pageID: page.id, fieldIdentifiers: fieldIdentifiers))
        return index(for: page, binding: binding, fieldIdentifiers: fieldIdentifiers)
    }

    private func structural(_ changes: PageChangeSet?) -> Bool {
        guard let changes else { return false }
        return changes.nodeOrderChanged || !changes.insertedNodeIDs.isEmpty || !changes.deletedNodeIDs.isEmpty
    }

    func nodes(for page: DiagramPage, changes: PageChangeSet? = nil, trustChanges: Bool = false) -> [UUID:
        DiagramNode]
    {
        if trustChanges, var host = hosts[page.id], !structural(changes) {
            for id in changes?.affectedNodeIDs ?? [] {
                guard let index = host.indices[id], page.nodes.indices.contains(index),
                    page.nodes[index].id == id
                else {
                    hosts.removeValue(forKey: page.id)
                    return nodes(for: page)
                }
                host.nodes[id] = page.nodes[index]
                preparedHostNodes += 1
            }
            hosts[page.id] = host
            return host.nodes
        }
        let nodes = Dictionary(uniqueKeysWithValues: page.nodes.map { ($0.id, $0) })
        let indices = Dictionary(
            uniqueKeysWithValues: page.nodes.enumerated().map { ($0.element.id, $0.offset) })
        preparedHostNodes += page.nodes.count
        if hosts.count >= maximumPages, hosts[page.id] == nil { hosts.removeAll(keepingCapacity: true) }
        hosts[page.id] = Host(nodes: nodes, indices: indices)
        return nodes
    }

    func retainedNodes(pageID: UUID) -> [UUID: DiagramNode]? { hosts[pageID]?.nodes }
    func retainedNodeIndices(pageID: UUID) -> [UUID: Int]? { hosts[pageID]?.indices }
    func fork() -> CalculationSession {
        let copy = CalculationSession(maximumPages: maximumPages)
        copy.entries = entries
        copy.hosts = hosts
        return copy
    }
    func retainedDependency(pageID: UUID, fieldIdentifiers: Bool = false) -> CalculationDependencyIndex? {
        entries[Key(pageID: pageID, fieldIdentifiers: fieldIdentifiers)]?.index
    }
}

/// Input comparison is a conservative adapter for callers without a WP-06
/// change set. A nil result means the entire page must be evaluated.
enum CalculationInvalidation {
    static func changedNodes(in page: DiagramPage, comparedTo previous: DiagramPage) -> Set<UUID>? {
        var metadata = page
        var oldMetadata = previous
        metadata.nodes = []
        oldMetadata.nodes = []
        // Edges do not supply cells in the current evaluator.
        metadata.edges = []
        oldMetadata.edges = []
        guard metadata == oldMetadata else { return nil }
        let oldIDs = previous.nodes.map(\.id)
        let newIDs = page.nodes.map(\.id)
        // Removing/reordering shapes can reassign implicit Sheet.N identifiers.
        guard newIDs.starts(with: oldIDs) else { return nil }
        let oldNodes = Dictionary(uniqueKeysWithValues: previous.nodes.map { ($0.id, $0) })
        return Set(page.nodes.compactMap { oldNodes[$0.id] == $0 ? nil : $0.id })
    }
}
