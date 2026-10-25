import Foundation

/// Counts work performed, rather than estimating it from the number of inputs.
struct CalculationWork: Equatable {
    var geometryPasses = 0
    var geometryPages = 0
    var geometryNodes = 0
    var fieldPages = 0
    var fieldNodes = 0
    var connectorSheets = 0
    var fieldConnectors = 0
    var dependencyConnectorsIndexed = 0
    var inputComparisonConnectors = 0
    var hostConnectorsPrepared = 0
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
        connectorSheets += other.connectorSheets
        fieldConnectors += other.fieldConnectors
        dependencyConnectorsIndexed += other.dependencyConnectorsIndexed
        inputComparisonConnectors += other.inputComparisonConnectors
        hostConnectorsPrepared += other.hostConnectorsPrepared
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
    enum Kind { case node, connector }
    struct Source: Equatable {
        var kind: Kind
        var objectIndex: Int
        var endpoints: Set<UUID>
        var id: UUID
        var parent: UUID?
        var publicID: String
        var sourceShapeID: String?
        var identifierAvailable: Bool
        var formulas: [String]
        var calculatesGeometry: Bool
        var hasFields: Bool
        var hasStructuralOwnerMetadata: Bool
        var dependencySignature: [String]
        static func == (lhs: Source, rhs: Source) -> Bool {
            lhs.kind == rhs.kind && lhs.objectIndex == rhs.objectIndex && lhs.endpoints == rhs.endpoints
                && lhs.id == rhs.id && lhs.parent == rhs.parent && lhs.publicID == rhs.publicID
                && lhs.sourceShapeID == rhs.sourceShapeID
                && lhs.identifierAvailable == rhs.identifierAvailable
                && lhs.calculatesGeometry == rhs.calculatesGeometry && lhs.hasFields == rhs.hasFields
                && lhs.hasStructuralOwnerMetadata == rhs.hasStructuralOwnerMetadata
                && lhs.dependencySignature == rhs.dependencySignature
        }
    }
    let sources: [Source]
    private(set) var dependents: [UUID: Set<UUID>] = [:]
    private(set) var requiresFullPage = false
    private(set) var volatileNodes: Set<UUID> = []
    private(set) var nodeIndices: [UUID: Int] = [:]
    private(set) var edgeIndices: [UUID: Int] = [:]
    private(set) var sourceIndices: [UUID: Int] = [:]
    private(set) var structuralNodeIDs: Set<UUID> = []
    private(set) var identifiers: [String: UUID] = [:]
    private(set) var publicIDsByObject: [UUID: String] = [:]
    private(set) var geometryNodeIDs: Set<UUID> = []
    private(set) var fieldNodeIDs: Set<UUID> = []
    private(set) var connectorSheetIDs: Set<UUID> = []
    private(set) var fieldConnectorIDs: Set<UUID> = []

    static func sources(page: DiagramPage, binding: VisioPageBinding?, fieldIdentifiers: Bool = false)
        -> [Source]
    {
        let nodes = page.nodes.enumerated().map { (Kind.node, $0.offset, $0.element) }
            + page.edges.enumerated().map { (Kind.connector, $0.offset, ConnectorSheetHost.sourceNode($0.element)) }
        let allocated = publicIDs(page: page, binding: binding)
        return nodes.map { kind, index, node in
            let publicID = allocated[node.id]
            let endpoints: Set<UUID> = kind == .connector
                ? [page.edges[index].source, page.edges[index].target] : []
            return source(node, kind: kind, objectIndex: index, endpoints: endpoints,
                          publicID: publicID ?? "", identifierAvailable: publicID != nil)
        }
    }

    static func publicIDs(page: DiagramPage, binding: VisioPageBinding?) -> [UUID: String] {
        let objects = page.nodes.map { ($0.id, binding?.nodeIDs[$0.id] ?? $0.formatting.sourceShapeID) }
            + page.edges.map { ($0.id, binding?.edgeIDs[$0.id] ?? $0.sourceShapeID) }
        let explicit = objects.compactMap { $0.1 }
        // Numeric public IDs share a page scope across shapes and connectors.
        // Preserve duplicate explicit IDs as ambiguous; never silently renumber them.
        var allocator = try? VisioIDAllocator(reserved: Array(Set(explicit)))
        var result: [UUID: String] = [:]
        for (id, explicitID) in objects {
            result[id] = explicitID ?? (try? allocator?.allocate())
        }
        return result
    }

    static func publicIdentifierMap(page: DiagramPage, binding: VisioPageBinding?) -> [String: UUID] {
        let allocated = publicIDs(page: page, binding: binding)
        var result: [String: UUID] = [:]
        for id in page.nodes.map(\.id) + page.edges.map(\.id) {
            if let key = allocated[id], result[key] == nil { result[key] = id }
        }
        return result
    }

    /// What a shape's dependency source derives from its formatting alone. Building it collects, sorts and
    /// parses every formula, so it is kept per shape and reused while the formatting is unchanged (unchanged
    /// shapes share storage, so the check is cheap). It outlives calculation sessions, which undo resets.
    private struct DerivedParts {
        var formatting: ShapeDetails
        var formulas: [String]
        var dependencySignature: [String]
        var calculatesGeometry: Bool
        var hasFields: Bool
        var hasStructuralOwnerMetadata: Bool
    }
    private static let derivedLock = NSLock()
    nonisolated(unsafe) private static var derived: [UUID: DerivedParts] = [:]
    private static let derivedLimit = 200_000

    /// Prepares every shape's dependency parts in the background after a drawing opens, so the first edit of
    /// a large drawing does not parse every formula on the main path. The diagram is an immutable copy.
    static func warm(_ diagram: Diagram) {
        guard diagram.pages.reduce(0, { $0 + $1.nodes.count + $1.edges.count }) > 500 else { return }
        DispatchQueue.global(qos: .utility).async {
            for page in diagram.pages {
                for node in page.nodes { _ = source(node, kind: .node, objectIndex: 0, publicID: "", identifierAvailable: false) }
                for edge in page.edges { _ = source(ConnectorSheetHost.sourceNode(edge), kind: .connector, objectIndex: 0, publicID: "", identifierAvailable: false) }
            }
        }
    }

    static func source(_ node: DiagramNode, kind: Kind, objectIndex: Int, endpoints: Set<UUID> = [],
                       publicID: String, identifierAvailable: Bool) -> Source {
        let formatting = node.formatting
        derivedLock.lock()
        let cached = derived[node.id]
        derivedLock.unlock()
        let parts: DerivedParts
        if let cached, cached.formatting == formatting { parts = cached }
        else {
            parts = derive(node)
            derivedLock.lock()
            if derived.count >= derivedLimit { derived.removeAll(keepingCapacity: true) }
            derived[node.id] = parts
            derivedLock.unlock()
        }
        return Source(
            kind: kind, objectIndex: objectIndex, endpoints: endpoints,
            id: node.id, parent: node.parentID, publicID: publicID,
            sourceShapeID: formatting.sourceShapeID,
            identifierAvailable: identifierAvailable,
            formulas: parts.formulas,
            calculatesGeometry: parts.calculatesGeometry,
            hasFields: parts.hasFields,
            hasStructuralOwnerMetadata: parts.hasStructuralOwnerMetadata,
            dependencySignature: parts.dependencySignature)
    }

    private static func derive(_ node: DiagramNode) -> DerivedParts {
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
                if DiagramMemberships.isRecognizedStructuralCell(key: key, cell: cell) { return nil }
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
            return DerivedParts(
                formatting: node.formatting,
                formulas: formulas,
                dependencySignature: dependencySignature,
                calculatesGeometry: !node.formatting.sheet.isEmpty
                    || !node.formatting.connectionPoints.isEmpty || !node.formatting.controls.isEmpty
                    || node.formatting.geometry != nil,
                hasFields: node.formatting.textFields?.isEmpty == false,
                hasStructuralOwnerMetadata: DiagramMemberships.hasStructuralOwnerMetadata(node))
    }

    init(sources: [Source], pageHasFormulas: Bool) {
        self.sources = sources
        requiresFullPage = pageHasFormulas
        for (offset, source) in sources.enumerated() {
            sourceIndices[source.id] = offset
            switch source.kind {
            case .node:
                nodeIndices[source.id] = source.objectIndex
                if source.hasStructuralOwnerMetadata { structuralNodeIDs.insert(source.id) }
                if source.calculatesGeometry { geometryNodeIDs.insert(source.id) }
                if source.hasFields { fieldNodeIDs.insert(source.id) }
            case .connector:
                edgeIndices[source.id] = source.objectIndex
                if source.calculatesGeometry { connectorSheetIDs.insert(source.id) }
                if source.hasFields { fieldConnectorIDs.insert(source.id) }
            }
            if source.identifierAvailable {
                publicIDsByObject[source.id] = source.publicID
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
            // Pure functions of their arguments or the theme (a theme change recalculates the document).
            "THEME", "MSOTINT", "TINT", "SHADE", "TONE", "BLEND", "HUEDIFF", "SATDIFF", "MAGNITUDE", "DATETIME",
            "DATEVALUE", "TIMEVALUE", "LOG10", "TRUNC", "ANG360", "ISERR", "ISERRNA", "ISERROR", "ISERRVALUE", "NA",
            "CELLISTHEMED",
            // A cell reference argument is a captured dependency.
            "FORMULAEXISTS", "DEPENDSON",
            // Document properties do not change while shapes are edited (a property edit recalculates the document).
            "FILENAME", "DOCCREATION", "DOCLASTSAVE", "DOCLASTPRINT", "DOCLASTEDIT", "CREATOR", "TITLE", "SUBJECT",
            "MANAGER", "COMPANY", "CATEGORY", "KEYWORDS", "DESCRIPTION",
            // Actions are not evaluated during calculation, so they read nothing.
            "OPENTEXTWIN", "DOCMD", "OPENSHEETWIN", "OPENGROUPWIN", "GOTOPAGE", "OPENPAGE", "OPENFILE", "HYPERLINK",
            "RUNMACRO", "CALLTHIS", "RUNADDON", "RUNADDONWARGS", "PLAYSOUND", "HELP", "QUEUEMARKEREVENT", "DEFAULTEVENT",
            "SETF", "GETREF", "SHEETREF",
            // Geometry and glue functions read their arguments, the shape itself, its parent or a connector's
            // endpoints, all of which are recorded as dependencies of the shape.
            "POLYLINE", "NURBS", "PNT", "PNTX", "PNTY", "PAR", "LOC", "LOCTOLOC", "LOCTOPAR", "ANGLETOLOC", "ANGLETOPAR",
            "_WALKGLUE", "_XFTRIGGER", "_ELLIPSE_THETA", "_ELLIPSE_ECC",
        ]
        let volatileFunctions: Set<String> = ["NOW", "TODAY", "RAND", "RANDOM"]
        for source in sources {
            if let parent = source.parent { dependents[parent, default: []].insert(source.id) }
            for endpoint in source.endpoints { dependents[endpoint, default: []].insert(source.id) }
            func reference(_ name: String) {
                guard let mark = name.firstIndex(of: "!") else { return }
                let owner = String(name[..<mark])
                if ["ThePage", "TheDoc"].contains(where: { owner.caseInsensitiveCompare($0) == .orderedSame }) { return }
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
                    var name = rawName.uppercased()
                    // A sheet-qualified call (Sheet.12054!SHEETREF()) depends on that sheet.
                    if let mark = rawName.lastIndex(of: "!") {
                        reference(rawName)
                        name = String(name[name.index(after: mark)...])
                    }
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
                } else if formula.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("USE(") {
                    // USE("pattern") / USE({GUID}) names a line, fill or arrow pattern master, not a shape.
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
        var edgeIndices: [UUID: Int]
        var endpoints: [UUID: Set<UUID>]
        var incident: [UUID: Set<UUID>]
    }
    private var hosts: [UUID: Host] = [:]
    private(set) var indexedConnectors = 0
    private(set) var preparedHostConnectors = 0
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
            guard let changes, !changes.affectedNodeIDs.isEmpty || !changes.affectedEdgeIDs.isEmpty || changes.pagePropertiesChanged else {
                return entry.index
            }
            sources = entry.sources
            var sourceChanged = false
            for id in changes.affectedNodeIDs.union(changes.affectedEdgeIDs) {
                guard let index = entry.index.sourceIndices[id] else {
                    return rebuildIndex(page: page, binding: binding, fieldIdentifiers: fieldIdentifiers)
                }
                let prior = entry.sources[index]
                let node: DiagramNode
                let endpoints: Set<UUID>
                switch prior.kind {
                case .node:
                    guard page.nodes.indices.contains(prior.objectIndex), page.nodes[prior.objectIndex].id == id else {
                        return rebuildIndex(page: page, binding: binding, fieldIdentifiers: fieldIdentifiers)
                    }
                    node = page.nodes[prior.objectIndex]; endpoints = []
                case .connector:
                    guard page.edges.indices.contains(prior.objectIndex), page.edges[prior.objectIndex].id == id else {
                        return rebuildIndex(page: page, binding: binding, fieldIdentifiers: fieldIdentifiers)
                    }
                    let edge = page.edges[prior.objectIndex]
                    node = ConnectorSheetHost.sourceNode(edge); endpoints = [edge.source, edge.target]
                }
                let explicit = (prior.kind == .node ? binding?.nodeIDs[id] : binding?.edgeIDs[id])
                    ?? node.formatting.sourceShapeID
                var source = CalculationDependencyIndex.source(node, kind: prior.kind,
                    objectIndex: prior.objectIndex, endpoints: endpoints,
                    publicID: explicit ?? prior.publicID, identifierAvailable: prior.identifierAvailable)
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
        } else if trustChanges, let entry = entries[key], let changes,
                  let appended = appendedSources(entry.sources, page: page, binding: binding, changes: changes) {
            sources = appended
        } else {
            sources = CalculationDependencyIndex.sources(
                page: page, binding: binding, fieldIdentifiers: fieldIdentifiers)
            comparedSources += sources.count
        }
        // Shapes' ThePage! references are not tracked, so a page formula that reads a shape forces whole-page
        // calculation. Other page formulas change only with the page, which recalculates the page anyway.
        let pageHasFormulas =
            page.sheet?.values.contains {
                let source = $0.formula.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                return !source.isEmpty && !["INH", "NO FORMULA"].contains(source) && source.contains("!")
            } ?? false
        if let entry = entries[key], entry.sources == sources, entry.pageHasFormulas == pageHasFormulas {
            return entry.index
        }
        let index = CalculationDependencyIndex(sources: sources, pageHasFormulas: pageHasFormulas)
        indexedNodes += sources.filter { $0.kind == .node }.count
        indexedConnectors += sources.filter { $0.kind == .connector }.count
        if entries.count >= maximumPages, entries[key] == nil { entries.removeAll(keepingCapacity: true) }
        entries[key] = Entry(sources: sources, pageHasFormulas: pageHasFormulas, index: index)
        return index
    }

    /// Shapes and connectors added after the existing ones (the usual insertion) extend the retained sources
    /// instead of rebuilding them from every object on the page. Existing objects must keep their positions
    /// and public IDs; anything else falls back to a full rebuild.
    private func appendedSources(_ retained: [CalculationDependencyIndex.Source], page: DiagramPage,
                                 binding: VisioPageBinding?, changes: PageChangeSet) -> [CalculationDependencyIndex.Source]? {
        guard !changes.nodeOrderChanged, !changes.edgeOrderChanged, changes.deletedNodeIDs.isEmpty, changes.deletedEdgeIDs.isEmpty,
              !changes.insertedNodeIDs.isEmpty || !changes.insertedEdgeIDs.isEmpty else { return nil }
        let oldNodes = retained.filter { $0.kind == .node }, oldEdges = retained.filter { $0.kind == .connector }
        guard oldNodes.count + changes.insertedNodeIDs.count == page.nodes.count,
              oldEdges.count + changes.insertedEdgeIDs.count == page.edges.count,
              Set(page.nodes.suffix(changes.insertedNodeIDs.count).map(\.id)) == changes.insertedNodeIDs,
              Set(page.edges.suffix(changes.insertedEdgeIDs.count).map(\.id)) == changes.insertedEdgeIDs,
              zip(oldNodes, page.nodes).allSatisfy({ $0.id == $1.id }), zip(oldEdges, page.edges).allSatisfy({ $0.id == $1.id }) else { return nil }
        let allocated = CalculationDependencyIndex.publicIDs(page: page, binding: binding)
        guard retained.allSatisfy({ ($0.identifierAvailable ? allocated[$0.id] == $0.publicID : allocated[$0.id] == nil) }) else { return nil }
        func make(_ node: DiagramNode, _ kind: CalculationDependencyIndex.Kind, _ index: Int, _ endpoints: Set<UUID>) -> CalculationDependencyIndex.Source {
            let publicID = allocated[node.id]
            return CalculationDependencyIndex.source(node, kind: kind, objectIndex: index, endpoints: endpoints,
                                                     publicID: publicID ?? "", identifierAvailable: publicID != nil)
        }
        var nodes = oldNodes, edges = oldEdges
        for index in oldNodes.count..<page.nodes.count { nodes.append(make(page.nodes[index], .node, index, [])) }
        for index in oldEdges.count..<page.edges.count {
            let edge = page.edges[index]; edges.append(make(ConnectorSheetHost.sourceNode(edge), .connector, index, [edge.source, edge.target]))
        }
        // Existing objects the edit also changed are re-read.
        for id in changes.affectedNodeIDs.subtracting(changes.insertedNodeIDs) {
            guard let i = nodes.firstIndex(where: { $0.id == id }) else { return nil }
            nodes[i] = make(page.nodes[nodes[i].objectIndex], .node, nodes[i].objectIndex, [])
        }
        for id in changes.affectedEdgeIDs.subtracting(changes.insertedEdgeIDs) {
            guard let i = edges.firstIndex(where: { $0.id == id }) else { return nil }
            let edge = page.edges[edges[i].objectIndex]
            edges[i] = make(ConnectorSheetHost.sourceNode(edge), .connector, edges[i].objectIndex, [edge.source, edge.target])
        }
        comparedSources += page.nodes.count - oldNodes.count + page.edges.count - oldEdges.count
        return nodes + edges
    }

    /// Undo and redo install an earlier state without calculating it: only the pages they changed lose their
    /// retained indices and host maps.
    func invalidate(pages: Set<UUID>) {
        entries = entries.filter { !pages.contains($0.key.pageID) }
        for id in pages { hosts[id] = nil }
    }

    private func rebuildIndex(page: DiagramPage, binding: VisioPageBinding?, fieldIdentifiers: Bool)
        -> CalculationDependencyIndex
    {
        entries.removeValue(forKey: Key(pageID: page.id, fieldIdentifiers: fieldIdentifiers))
        return index(for: page, binding: binding, fieldIdentifiers: fieldIdentifiers)
    }

    private func structural(_ changes: PageChangeSet?) -> Bool {
        guard let changes else { return false }
        return changes.nodeOrderChanged || changes.edgeOrderChanged
            || !changes.insertedNodeIDs.isEmpty || !changes.deletedNodeIDs.isEmpty
            || !changes.insertedEdgeIDs.isEmpty || !changes.deletedEdgeIDs.isEmpty
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
            var edges = changes?.affectedEdgeIDs ?? []
            for id in changes?.affectedNodeIDs ?? [] { edges.formUnion(host.incident[id] ?? []) }
            for id in edges {
                guard let index = host.edgeIndices[id], page.edges.indices.contains(index), page.edges[index].id == id else {
                    hosts.removeValue(forKey: page.id)
                    return nodes(for: page)
                }
                let edge = page.edges[index]
                for endpoint in host.endpoints[id] ?? [] { host.incident[endpoint]?.remove(id) }
                let endpoints: Set<UUID> = [edge.source, edge.target]
                host.endpoints[id] = endpoints
                for endpoint in endpoints { host.incident[endpoint, default: []].insert(id) }
                host.nodes[id] = ConnectorSheetHost.node(edge, in: page, nodesByID: host.nodes)
                preparedHostConnectors += 1
            }
            hosts[page.id] = host
            return host.nodes
        }
        var nodes = Dictionary(uniqueKeysWithValues: page.nodes.map { ($0.id, $0) })
        var edgeIndices: [UUID: Int] = [:], endpoints: [UUID: Set<UUID>] = [:], incident: [UUID: Set<UUID>] = [:]
        for (index, edge) in page.edges.enumerated() {
            edgeIndices[edge.id] = index
            endpoints[edge.id] = [edge.source, edge.target]
            for endpoint in endpoints[edge.id] ?? [] { incident[endpoint, default: []].insert(edge.id) }
            nodes[edge.id] = ConnectorSheetHost.node(edge, in: page, nodesByID: nodes)
        }
        preparedHostConnectors += page.edges.count
        let indices = Dictionary(
            uniqueKeysWithValues: page.nodes.enumerated().map { ($0.element.id, $0.offset) })
        preparedHostNodes += page.nodes.count
        if hosts.count >= maximumPages, hosts[page.id] == nil { hosts.removeAll(keepingCapacity: true) }
        hosts[page.id] = Host(nodes: nodes, indices: indices, edgeIndices: edgeIndices, endpoints: endpoints, incident: incident)
        return nodes
    }

    func retainedStructuralNodeIDs(pageID: UUID) -> Set<UUID>? {
        let geometry = entries[Key(pageID: pageID, fieldIdentifiers: false)]?.index.structuralNodeIDs
        let fields = entries[Key(pageID: pageID, fieldIdentifiers: true)]?.index.structuralNodeIDs
        guard geometry != nil || fields != nil else { return nil }
        // Geometry and field passes can retain different source generations.
        // A stale positive is conservative; preferring an older empty graph
        // could hide a newly authored/resolved structural owner.
        return (geometry ?? []).union(fields ?? [])
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
        metadata.edges = []
        oldMetadata.edges = []
        guard metadata == oldMetadata else { return nil }
        let oldIDs = previous.nodes.map(\.id)
        let newIDs = page.nodes.map(\.id)
        // Removing/reordering shapes can reassign implicit Sheet.N identifiers.
        guard newIDs.starts(with: oldIDs), page.edges.map(\.id) == previous.edges.map(\.id) else { return nil }
        let oldNodes = Dictionary(uniqueKeysWithValues: previous.nodes.map { ($0.id, $0) })
        let oldEdges = Dictionary(uniqueKeysWithValues: previous.edges.map { ($0.id, $0) })
        return Set(page.nodes.compactMap { oldNodes[$0.id] == $0 ? nil : $0.id })
            .union(page.edges.compactMap { oldEdges[$0.id] == $0 ? nil : $0.id })
    }
}
