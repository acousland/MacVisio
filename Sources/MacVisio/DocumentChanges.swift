import Foundation
import CoreGraphics

/// An affected set for one committed page revision. Inserted/deleted IDs are
/// separate from changed IDs, so consumers never have to infer object lifetime.
struct PageChangeSet: Equatable {
    var pageID: UUID
    var insertedNodeIDs: Set<UUID> = []
    var deletedNodeIDs: Set<UUID> = []
    var changedNodeIDs: Set<UUID> = []
    var geometryChangedNodeIDs: Set<UUID> = []
    var insertedEdgeIDs: Set<UUID> = []
    var deletedEdgeIDs: Set<UUID> = []
    var changedEdgeIDs: Set<UUID> = []
    var nodeOrderChanged = false
    var edgeOrderChanged = false
    var hierarchyChanged = false
    var layersChanged = false
    var pageGeometryChanged = false
    var pagePropertiesChanged = false

    var affectedNodeIDs: Set<UUID> { insertedNodeIDs.union(deletedNodeIDs).union(changedNodeIDs) }
    var affectedEdgeIDs: Set<UUID> { insertedEdgeIDs.union(deletedEdgeIDs).union(changedEdgeIDs) }
    var requiresRuntimeRebuild: Bool {
        nodeOrderChanged || edgeOrderChanged || hierarchyChanged || layersChanged || pageGeometryChanged
            || !insertedNodeIDs.isEmpty || !deletedNodeIDs.isEmpty
            || !insertedEdgeIDs.isEmpty || !deletedEdgeIDs.isEmpty
    }
    var isEmpty: Bool {
        affectedNodeIDs.isEmpty && affectedEdgeIDs.isEmpty && !requiresRuntimeRebuild && !pagePropertiesChanged
    }

    static func between(_ old: DiagramPage, _ new: DiagramPage) -> PageChangeSet {
        var result = PageChangeSet(pageID: new.id)
        let oldNodes = firstByID(old.nodes), newNodes = firstByID(new.nodes)
        let oldEdges = firstByID(old.edges), newEdges = firstByID(new.edges)
        let oldNodeIDs = Set(oldNodes.keys), newNodeIDs = Set(newNodes.keys)
        let oldEdgeIDs = Set(oldEdges.keys), newEdgeIDs = Set(newEdges.keys)
        result.insertedNodeIDs = newNodeIDs.subtracting(oldNodeIDs)
        result.deletedNodeIDs = oldNodeIDs.subtracting(newNodeIDs)
        result.insertedEdgeIDs = newEdgeIDs.subtracting(oldEdgeIDs)
        result.deletedEdgeIDs = oldEdgeIDs.subtracting(newEdgeIDs)
        for id in oldNodeIDs.intersection(newNodeIDs) {
            guard let before = oldNodes[id], let after = newNodes[id], before != after else { continue }
            result.changedNodeIDs.insert(id)
            if geometryDiffers(before, after) { result.geometryChangedNodeIDs.insert(id) }
            if before.parentID != after.parentID || before.formatting.isGroup != after.formatting.isGroup
                || before.kind != after.kind || before.formatting.sheet["DisplayMode"] != after.formatting.sheet["DisplayMode"] {
                result.hierarchyChanged = true
            }
        }
        for id in oldEdgeIDs.intersection(newEdgeIDs) where oldEdges[id] != newEdges[id] {
            result.changedEdgeIDs.insert(id)
            if oldEdges[id]?.parentID != newEdges[id]?.parentID { result.hierarchyChanged = true }
        }
        result.nodeOrderChanged = old.nodes.map(\.id) != new.nodes.map(\.id)
        result.edgeOrderChanged = old.edges.map(\.id) != new.edges.map(\.id)
        result.layersChanged = old.layers != new.layers
        result.pageGeometryChanged = old.width != new.width || old.height != new.height || old.drawingScale != new.drawingScale
        var oldProperties = old, newProperties = new
        oldProperties.nodes = []; oldProperties.edges = []
        newProperties.nodes = []; newProperties.edges = []
        result.pagePropertiesChanged = oldProperties != newProperties
        return result
    }

    private static func geometryDiffers(_ a: DiagramNode, _ b: DiagramNode) -> Bool {
        a.rect != b.rect || a.rotation != b.rotation || a.strokeWidth != b.strokeWidth
            || a.formatting.flipX != b.formatting.flipX || a.formatting.flipY != b.formatting.flipY
            || a.formatting.paths != b.formatting.paths || a.formatting.geometry != b.formatting.geometry
            || a.formatting.connectionPoints != b.formatting.connectionPoints || a.formatting.textBox != b.formatting.textBox
    }

    private static func firstByID<T: Identifiable>(_ values: [T]) -> [UUID: T] where T.ID == UUID {
        values.reduce(into: [:]) { if $0[$1.id] == nil { $0[$1.id] = $1 } }
    }
}

/// Diff construction intentionally scans immutable value snapshots once at a
/// commit boundary. Runtime consumers then update only the explicit affected set.
/// Selection, viewport and gesture previews do not construct semantic diffs.
struct DocumentChangeSet: Equatable {
    var pages: [UUID: PageChangeSet] = [:]
    var insertedPageIDs: Set<UUID> = []
    var deletedPageIDs: Set<UUID> = []
    var pageOrderChanged = false
    var documentPropertiesChanged = false
    var sourceResourcesChanged = false
    var activePageChanged = false

    var changedPageIDs: Set<UUID> { Set(pages.keys) }
    var affectedPageIDs: Set<UUID> { changedPageIDs.union(insertedPageIDs).union(deletedPageIDs) }
    var documentStructureChanged: Bool { pageOrderChanged || !insertedPageIDs.isEmpty || !deletedPageIDs.isEmpty }
    var hasSemanticChanges: Bool { documentStructureChanged || documentPropertiesChanged || !pages.isEmpty }
    var isEmpty: Bool { !hasSemanticChanges && !sourceResourcesChanged && !activePageChanged }

    static func between(_ old: Diagram, _ new: Diagram) -> DocumentChangeSet {
        var result = DocumentChangeSet()
        let oldPages = old.pages.reduce(into: [UUID: DiagramPage]()) { if $0[$1.id] == nil { $0[$1.id] = $1 } }
        let newPages = new.pages.reduce(into: [UUID: DiagramPage]()) { if $0[$1.id] == nil { $0[$1.id] = $1 } }
        result.insertedPageIDs = Set(newPages.keys).subtracting(oldPages.keys)
        result.deletedPageIDs = Set(oldPages.keys).subtracting(newPages.keys)
        for (id, page) in newPages {
            guard let oldPage = oldPages[id] else { continue }
            let change = PageChangeSet.between(oldPage, page)
            if !change.isEmpty { result.pages[id] = change }
        }
        result.pageOrderChanged = old.pages.map(\.id) != new.pages.map(\.id)
        result.documentPropertiesChanged = old.title != new.title || old.version != new.version
        result.sourceResourcesChanged = old.visioArchive != new.visioArchive || old.legacySource != new.legacySource
        result.activePageChanged = old.activePageID != new.activePageID
        return result
    }
}

/// Presentation notifications carry no semantic revision or calculation work.
enum DocumentPresentationEvent: Equatable {
    case selectionChanged(pageID: UUID, nodeIDs: Set<UUID>, edgeID: UUID?)
    case viewportChanged(pageID: UUID, zoom: Double, scrollOrigin: CGPoint)
    case previewChanged(pageID: UUID, nodeIDs: Set<UUID>, edgeIDs: Set<UUID>)
    case activePageChanged(UUID)
}
