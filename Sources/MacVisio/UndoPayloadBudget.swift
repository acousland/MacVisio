import Foundation
import MacVisioInfrastructure

/// A conservative retention charge, not a claim about exact allocator bytes.
/// Sources are charged in full per action even when Swift shares their storage.
/// Editable objects are encoded once initially, then only when affected.
final class UndoPayloadBudget {
    struct Decision {
        let discardOldHistory: Bool
        let actionCharge: Int
        let retainedCharge: Int
        let oversizedSingleAction: Bool
    }

    private struct ObjectKey: Hashable {
        let pageID: UUID
        let objectID: UUID
    }

    let maximumCharge: Int
    private(set) var retainedCharge = 0
    private(set) var historyDiscards = 0
    private(set) var lastEncodedObjectCount = 0
    private(set) var lastVisitedObjects = 0
    private var currentStateID: UUID?
    private var pageCosts: [UUID: Int] = [:]
    private var nodeCosts: [ObjectKey: Int] = [:]
    private var edgeCosts: [ObjectKey: Int] = [:]
    private var nodeIndices: [UUID: [UUID: Int]] = [:]
    private var edgeIndices: [UUID: [UUID: Int]] = [:]
    private var editableCost = 0
    private var chargedDefinitions: DefinitionRegistry?
    private var definitionCharge = 0
    private var recentDefinitionCharges: [(definitions: DefinitionRegistry?, charge: Int)] = []

    init(maximumCharge: Int = ResourceBudgets.undoPayload) {
        precondition(maximumCharge > 0)
        self.maximumCharge = maximumCharge
    }

    /// Call before registering a new ordinary commit. Undo/redo registration
    /// does not consume another charge: each action covers both directions.
    /// Clear NSUndoManager's old history when `discardOldHistory` is true,
    /// before registering this action. Keep the current action undoable even
    /// when one snapshot exceeds the budget, and expose that exception.
    func prepare(
        previous: Diagram, previousStateID: UUID, next: Diagram, changes: DocumentChangeSet,
        historyIsEmpty: Bool
    ) -> Decision {
        if historyIsEmpty { retainedCharge = 0 }
        lastEncodedObjectCount = 0
        lastVisitedObjects = 0
        if currentStateID != previousStateID { rebuild(previous) }
        let before = Self.add(Self.add(editableCost, sourceCharge(previous)), documentCharge(previous))
        apply(next, changes: changes)
        let after = Self.add(Self.add(editableCost, sourceCharge(next)), documentCharge(next))
        let charge = max(before, after)
        let discard = retainedCharge > maximumCharge - min(charge, maximumCharge)
        if discard {
            retainedCharge = 0
            historyDiscards += 1
        }
        retainedCharge = Self.add(retainedCharge, charge)
        currentStateID = nil
        return Decision(
            discardOldHistory: discard, actionCharge: charge,
            retainedCharge: retainedCharge, oversizedSingleAction: charge > maximumCharge)
    }

    /// Bind the prepared cost map to the exact committed identity.
    func didInstall(stateID: UUID) { currentStateID = stateID }
    func invalidateCurrentEstimate() { currentStateID = nil }
    /// Undo and redo install a known earlier state: follow it with the committed change set, as an ordinary
    /// edit does, instead of re-encoding the whole drawing at the next edit. No charge is taken: each action
    /// was charged once for both directions.
    func follow(previousStateID: UUID, next: Diagram, changes: DocumentChangeSet, nextStateID: UUID) {
        guard currentStateID == previousStateID else { currentStateID = nil; return }
        lastEncodedObjectCount = 0
        lastVisitedObjects = 0
        apply(next, changes: changes)
        currentStateID = nextStateID
    }

    private func rebuild(_ diagram: Diagram) {
        pageCosts = [:]
        nodeCosts = [:]
        edgeCosts = [:]
        nodeIndices = [:]
        edgeIndices = [:]
        editableCost = 0
        for page in diagram.pages {
            let metadata = metadataCharge(page)
            pageCosts[page.id] = metadata
            editableCost = Self.add(editableCost, metadata)
            var pageNodes: [UUID: Int] = [:]
            var pageEdges: [UUID: Int] = [:]
            for (index, node) in page.nodes.enumerated() {
                pageNodes[node.id] = index
                lastVisitedObjects += 1
                let cost = estimatedCharge(node)
                nodeCosts[ObjectKey(pageID: page.id, objectID: node.id)] = cost
                editableCost = Self.add(editableCost, cost)
            }
            for (index, edge) in page.edges.enumerated() {
                pageEdges[edge.id] = index
                lastVisitedObjects += 1
                let cost = estimatedCharge(edge)
                edgeCosts[ObjectKey(pageID: page.id, objectID: edge.id)] = cost
                editableCost = Self.add(editableCost, cost)
            }
            nodeIndices[page.id] = pageNodes
            edgeIndices[page.id] = pageEdges
        }
    }

    private func apply(_ diagram: Diagram, changes: DocumentChangeSet) {
        for id in changes.deletedPageIDs {
            editableCost -= pageCosts.removeValue(forKey: id) ?? 0
            for nodeID in nodeIndices.removeValue(forKey: id)?.keys ?? Dictionary<UUID, Int>().keys {
                editableCost -= nodeCosts.removeValue(forKey: ObjectKey(pageID: id, objectID: nodeID)) ?? 0
                lastVisitedObjects += 1
            }
            for edgeID in edgeIndices.removeValue(forKey: id)?.keys ?? Dictionary<UUID, Int>().keys {
                editableCost -= edgeCosts.removeValue(forKey: ObjectKey(pageID: id, objectID: edgeID)) ?? 0
                lastVisitedObjects += 1
            }
        }
        for page in diagram.pages {
            let inserted = changes.insertedPageIDs.contains(page.id)
            guard let change = changes.pages[page.id] ?? (inserted ? PageChangeSet(pageID: page.id) : nil)
            else { continue }
            if inserted || change.pagePropertiesChanged || pageCosts[page.id] == nil {
                let metadata = metadataCharge(page)
                editableCost -= pageCosts[page.id] ?? 0
                pageCosts[page.id] = metadata
                editableCost = Self.add(editableCost, metadata)
            }
            for id in change.deletedNodeIDs {
                editableCost -= nodeCosts.removeValue(forKey: ObjectKey(pageID: page.id, objectID: id)) ?? 0
            }
            for id in change.deletedEdgeIDs {
                editableCost -= edgeCosts.removeValue(forKey: ObjectKey(pageID: page.id, objectID: id)) ?? 0
            }
            if inserted || change.nodeOrderChanged || !change.insertedNodeIDs.isEmpty
                || !change.deletedNodeIDs.isEmpty
            {
                nodeIndices[page.id] = Dictionary(
                    uniqueKeysWithValues: page.nodes.enumerated().map { ($0.element.id, $0.offset) })
                lastVisitedObjects += page.nodes.count
            }
            if inserted || change.edgeOrderChanged || !change.insertedEdgeIDs.isEmpty
                || !change.deletedEdgeIDs.isEmpty
            {
                edgeIndices[page.id] = Dictionary(
                    uniqueKeysWithValues: page.edges.enumerated().map { ($0.element.id, $0.offset) })
                lastVisitedObjects += page.edges.count
            }
            let nodeIDs =
                inserted
                ? Set(nodeIndices[page.id]?.keys ?? Dictionary<UUID, Int>().keys) : change.affectedNodeIDs
            for id in nodeIDs {
                guard let index = nodeIndices[page.id]?[id], page.nodes.indices.contains(index) else {
                    continue
                }
                let node = page.nodes[index]
                lastVisitedObjects += 1
                let key = ObjectKey(pageID: page.id, objectID: node.id)
                editableCost -= nodeCosts[key] ?? 0
                let cost = estimatedCharge(node)
                nodeCosts[key] = cost
                editableCost = Self.add(editableCost, cost)
            }
            let edgeIDs =
                inserted
                ? Set(edgeIndices[page.id]?.keys ?? Dictionary<UUID, Int>().keys) : change.affectedEdgeIDs
            for id in edgeIDs {
                guard let index = edgeIndices[page.id]?[id], page.edges.indices.contains(index) else {
                    continue
                }
                let edge = page.edges[index]
                lastVisitedObjects += 1
                let key = ObjectKey(pageID: page.id, objectID: edge.id)
                editableCost -= edgeCosts[key] ?? 0
                let cost = estimatedCharge(edge)
                edgeCosts[key] = cost
                editableCost = Self.add(editableCost, cost)
            }
        }
    }

    /// A shape's undo charge from the size of what it holds (text, cells, paths, runs, image bytes) rather than
    /// by encoding it: encoding every shape of a large drawing took seconds on the first edit. Charges keep
    /// JSON's proportions (about four times the stored bytes).
    private func estimatedCharge(_ node: DiagramNode) -> Int {
        lastEncodedObjectCount += 1
        return Self.add(Self.multiply(Self.estimatedBytes(node), by: 4), MemoryLayout<DiagramNode>.stride)
    }
    private func estimatedCharge(_ edge: DiagramEdge) -> Int {
        lastEncodedObjectCount += 1
        var bytes = 160 + edge.label.utf8.count + (edge.points?.count ?? 0) * 40
        if let details = edge.details { bytes += Self.estimatedBytes(details) }
        return Self.add(Self.multiply(bytes, by: 4), MemoryLayout<DiagramEdge>.stride)
    }
    static func estimatedBytes(_ node: DiagramNode) -> Int {
        var bytes = 220 + node.text.utf8.count + node.fill.utf8.count + node.stroke.utf8.count + node.textColor.utf8.count
        if let details = node.details { bytes += estimatedBytes(details) }
        return bytes
    }
    static func estimatedBytes(_ details: ShapeDetails) -> Int {
        func cells(_ cells: [String: ShapeSheetCell]) -> Int {
            cells.reduce(0) { $0 + $1.key.utf8.count + $1.value.value.utf8.count + $1.value.formula.utf8.count + $1.value.unit.utf8.count + 36 }
        }
        var bytes = 200 + details.fontName.utf8.count + cells(details.sheet)
        bytes += details.paths.reduce(0) { $0 + 40 + $1.commands.reduce(0) { $0 + 16 + $1.values.count * 20 } }
        bytes += details.image.map { $0.data.count * 4 / 3 + $0.mimeType.utf8.count } ?? 0
        bytes += details.data.reduce(0) { $0 + 60 + $1.key.utf8.count + $1.label.utf8.count + $1.value.utf8.count + $1.format.utf8.count + $1.prompt.utf8.count }
        bytes += details.hyperlinks.reduce(0) { $0 + 60 + $1.address.utf8.count + $1.subAddress.utf8.count + $1.description.utf8.count }
        bytes += details.layerNames.reduce(0) { $0 + 4 + $1.utf8.count }
        bytes += details.connectionPoints.reduce(0) { $0 + 120 + ($1.name?.utf8.count ?? 0) + $1.x.formula.utf8.count + $1.y.formula.utf8.count }
        bytes += (details.textRuns ?? []).reduce(0) { $0 + 160 + $1.text.utf8.count + $1.character.fontName.utf8.count + cells($1.character.cells) + cells($1.paragraph.cells) }
        bytes += (details.textFields ?? []).reduce(0) { $0 + 40 + cells($1.cells) + ($1.cached?.utf8.count ?? 0) }
        bytes += (details.geometry ?? []).reduce(0) { $0 + 40 + cells($1.cells) + $1.rows.reduce(0) { $0 + 30 + $1.type.utf8.count + cells($1.cells) } }
        bytes += details.controls.reduce(0) { $0 + 40 + $1.name.utf8.count + cells($1.cells) }
        return bytes
    }

    private func metadataCharge(_ page: DiagramPage) -> Int {
        var metadata = page
        metadata.nodes = []
        metadata.edges = []
        return encodedCharge(metadata, inline: MemoryLayout<DiagramPage>.stride)
    }

    private func encodedCharge<Value: Encodable>(_ value: Value, inline: Int) -> Int {
        lastEncodedObjectCount += 1
        guard let bytes = try? JSONEncoder().encode(value).count else { return maximumCharge }
        return Self.add(Self.multiply(bytes, by: 4), inline)
    }

    private func sourceCharge(_ diagram: Diagram) -> Int {
        Self.multiply(
            Self.add(diagram.visioArchive?.sourceByteCount ?? 0, diagram.legacySource?.data.count ?? 0), by: 4
        )
    }

    private func documentCharge(_ diagram: Diagram) -> Int {
        if chargedDefinitions != diagram.definitions {
            // An edit compares its previous and next states; remember both so neither is encoded again.
            if let known = recentDefinitionCharges.first(where: { $0.definitions == diagram.definitions }) {
                definitionCharge = known.charge
            } else {
                definitionCharge = diagram.definitions.flatMap { try? JSONEncoder().encode($0).count } ?? 0
                recentDefinitionCharges = Array((recentDefinitionCharges + [(diagram.definitions, definitionCharge)]).suffix(2))
            }
            chargedDefinitions = diagram.definitions
        }
        return Self.add(Self.add(MemoryLayout<Diagram>.stride, Self.multiply(diagram.title.utf8.count, by: 4)),
                        Self.multiply(definitionCharge, by: 4))
    }

    private static func add(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func multiply(_ value: Int, by factor: Int) -> Int {
        let result = value.multipliedReportingOverflow(by: factor)
        return result.overflow ? Int.max : result.partialValue
    }
}
