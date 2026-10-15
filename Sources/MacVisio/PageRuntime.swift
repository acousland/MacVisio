import Foundation
import CoreGraphics

enum PageElementID: Hashable {
    case node(UUID)
    case edge(UUID)
}

struct RuntimeUpdateWork: Equatable {
    var nodeVisits = 0
    var edgeVisits = 0
    var hierarchyVisits = 0
    var spatialUpdates = 0
    var didRebuild = false
}

struct RuntimeQueryWork: Equatable {
    var bucketVisits = 0
    var candidateVisits = 0
    var overflowVisits = 0
    var usedFullScan = false
}

struct RuntimeQuery<Value> {
    var values: [Value]
    var work: RuntimeQueryWork
}

/// Derived indexes owned by one document's serial execution context. This class
/// does not own committed values, undo, source archives or UI state. Updates
/// invoke no callbacks; callers publish the resulting revision after apply.
/// All coordinates are drawing/page units, before paperScale and canvas zoom.
final class PageRuntime {
    private(set) var pageID: UUID
    private(set) var nodesByID: [UUID: DiagramNode] = [:]
    private(set) var edgesByID: [UUID: DiagramEdge] = [:]
    private(set) var nodeIndexByID: [UUID: Int] = [:]
    private(set) var edgeIndexByID: [UUID: Int] = [:]
    private(set) var parentByID: [UUID: UUID] = [:]
    private(set) var childrenByParent: [UUID: Set<UUID>] = [:]
    private(set) var edgeParentByID: [UUID: UUID] = [:]
    private(set) var edgesByParent: [UUID: Set<UUID>] = [:]
    private(set) var edgesByEndpoint: [UUID: Set<UUID>] = [:]
    private(set) var nodeDrawOrder: [UUID] = []
    private(set) var paintOrder: [PageElementID] = []
    private(set) var nodeBoundsByID: [UUID: CGRect] = [:]
    private(set) var edgeBoundsByID: [UUID: CGRect] = [:]
    private(set) var lastUpdateWork = RuntimeUpdateWork()

    private var nodePaintRank: [UUID: Int] = [:]
    private var edgePaintRank: [UUID: Int] = [:]
    private var preparedObstacleEdgeIDs: Set<UUID> = []
    private var visibleByID: [UUID: Bool] = [:]
    private var lockedByID: [UUID: Bool] = [:]
    private var snapByID: [UUID: Bool] = [:]
    private var layersByName: [String: DiagramLayer] = [:]
    private var nodeSpatial: SpatialBuckets
    private var edgeSpatial: SpatialBuckets
    private var paperScale: Double = 1

    init(page: DiagramPage, cellSize: CGFloat = 256, preparedRoutes: [UUID: [CGPoint]] = [:]) {
        pageID = page.id
        nodeSpatial = SpatialBuckets(cellSize: cellSize)
        edgeSpatial = SpatialBuckets(cellSize: cellSize)
        rebuild(page: page, preparedRoutes: preparedRoutes)
    }

    func descendants(of id: UUID) -> Set<UUID> {
        guard nodesByID[id] != nil else { return [] }
        var result: Set<UUID> = [id], pending = [id]
        while let parent = pending.popLast() {
            for child in childrenByParent[parent] ?? [] where result.insert(child).inserted { pending.append(child) }
        }
        return result
    }

    func selectionMembership(_ ids: Set<UUID>, includingDescendants: Bool = false) -> Set<UUID> {
        var result = ids.filter { nodesByID[$0] != nil }
        if includingDescendants { for id in ids { result.formUnion(descendants(of: id)) } }
        return result
    }

    func isVisible(nodeID: UUID) -> Bool { visibleByID[nodeID] ?? false }
    func isLocked(nodeID: UUID) -> Bool { lockedByID[nodeID] ?? true }
    func permitsShapeSnap(nodeID: UUID) -> Bool { snapByID[nodeID] ?? false }
    func isVisible(edgeID: UUID) -> Bool {
        guard let edge = edgesByID[edgeID] else { return false }
        if let name = edge.layer, layersByName[name]?.visible == false { return false }
        return edge.parentID.map { visibleByID[$0] ?? true } ?? true
    }
    func isLocked(edgeID: UUID) -> Bool {
        guard let edge = edgesByID[edgeID] else { return true }
        if let name = edge.layer, layersByName[name]?.locked == true { return true }
        return edge.parentID.map { lockedByID[$0] ?? false } ?? false
    }

    /// Caller supplies a diff of the exact prior committed page. Structural
    /// changes rebuild once; a property edit visits changed IDs, their affected
    /// descendants and incident edges, never unrelated source-array entries.
    @discardableResult
    func apply(page: DiagramPage, changes: PageChangeSet, preparedRoutes: [UUID: [CGPoint]] = [:]) -> RuntimeUpdateWork {
        if page.id != pageID || changes.pageID != pageID || changes.requiresRuntimeRebuild {
            rebuild(page: page, preparedRoutes: preparedRoutes)
            return lastUpdateWork
        }
        // A mismatched caller contract falls back before any mutation.
        guard page.nodes.count == nodesByID.count, page.edges.count == edgesByID.count,
              changes.changedNodeIDs.allSatisfy({ id in
                  nodeIndexByID[id].map { page.nodes.indices.contains($0) && page.nodes[$0].id == id } ?? false
              }), changes.changedEdgeIDs.allSatisfy({ id in
                  edgeIndexByID[id].map { page.edges.indices.contains($0) && page.edges[$0].id == id } ?? false
              }) else {
            rebuild(page: page, preparedRoutes: preparedRoutes)
            return lastUpdateWork
        }
        var work = RuntimeUpdateWork()
        var inheritedChanges = Set<UUID>(), affectedEdges = changes.changedEdgeIDs
        // Any shape can be an orthogonal-route obstacle. Prepared automatic
        // routes lose their bounds until the renderer supplies a fresh route.
        if !changes.geometryChangedNodeIDs.isEmpty { affectedEdges.formUnion(preparedObstacleEdgeIDs) }
        for id in changes.changedNodeIDs {
            guard let index = nodeIndexByID[id], let old = nodesByID[id] else { continue }
            let node = page.nodes[index]
            if old.locked != node.locked || old.layer != node.layer || old.formatting.layerNames != node.formatting.layerNames {
                inheritedChanges.formUnion(descendants(of: id))
            }
            nodesByID[id] = node
            let bounds = Self.conservativeBounds(of: node, paperScale: paperScale)
            nodeBoundsByID[id] = bounds
            nodeSpatial.set(id, bounds: bounds)
            work.nodeVisits += 1; work.spatialUpdates += 1
            if changes.geometryChangedNodeIDs.contains(id) { affectedEdges.formUnion(edgesByEndpoint[id] ?? []) }
        }
        for id in inheritedChanges {
            work.hierarchyVisits += cacheEligibility(id)
        }
        for id in affectedEdges {
            guard let index = edgeIndexByID[id] else { continue }
            let old = edgesByID[id], edge = page.edges[index]
            if old?.source != edge.source || old?.target != edge.target {
                if let old { edgesByEndpoint[old.source]?.remove(id); edgesByEndpoint[old.target]?.remove(id) }
                if nodesByID[edge.source] != nil { edgesByEndpoint[edge.source, default: []].insert(id) }
                if nodesByID[edge.target] != nil { edgesByEndpoint[edge.target, default: []].insert(id) }
            }
            edgesByID[id] = edge
            setEdgeBounds(edge, route: preparedRoutes[id])
            work.edgeVisits += 1; work.spatialUpdates += 1
        }
        // A prepared renderer may supply newly computed routes without a model
        // change. Only those explicit entries are installed here.
        for (id, route) in preparedRoutes where !affectedEdges.contains(id) {
            guard let edge = edgesByID[id] else { continue }
            setEdgeBounds(edge, route: route)
            work.edgeVisits += 1; work.spatialUpdates += 1
        }
        lastUpdateWork = work
        return work
    }

    func nodeCandidates(at point: CGPoint, tolerance: CGFloat = 0, includeLocked: Bool = true) -> RuntimeQuery<DiagramNode> {
        let radius = tolerance.isFinite ? max(0, tolerance) : 0
        return nodes(intersecting: CGRect(x: point.x-radius, y: point.y-radius, width: radius*2, height: radius*2),
                     includeLocked: includeLocked, frontToBack: true)
    }

    /// Conservative broad phase. Exact path containment remains a caller-owned
    /// narrow phase using prepared paths, without formula evaluation.
    func nodes(intersecting rect: CGRect, includeLocked: Bool = true, frontToBack: Bool = false) -> RuntimeQuery<DiagramNode> {
        let query = nodeSpatial.query(rect)
        let ids = query.ids.filter { id in
            isVisible(nodeID: id) && (includeLocked || !isLocked(nodeID: id))
                && nodePaintRank[id] != nil && nodeBoundsByID[id].map { Self.intersects($0, rect) } == true
        }.sorted { a, b in frontToBack ? nodePaintRank[a, default: 0] > nodePaintRank[b, default: 0]
            : nodePaintRank[a, default: 0] < nodePaintRank[b, default: 0] }
        return RuntimeQuery(values: ids.compactMap { nodesByID[$0] }, work: query.work)
    }

    func edgeCandidates(intersecting rect: CGRect, includeLocked: Bool = true, frontToBack: Bool = true) -> RuntimeQuery<DiagramEdge> {
        let query = edgeSpatial.query(rect)
        let ids = query.ids.filter { id in
            isVisible(edgeID: id) && (includeLocked || !isLocked(edgeID: id))
                && (edgeBoundsByID[id].map { Self.intersects($0, rect) } ?? true)
        }.sorted { a, b in frontToBack ? edgePaintRank[a, default: 0] > edgePaintRank[b, default: 0]
            : edgePaintRank[a, default: 0] < edgePaintRank[b, default: 0] }
        return RuntimeQuery(values: ids.compactMap { edgesByID[$0] }, work: query.work)
    }

    /// The retained scene owns measured label/route bounds. Install only bounds
    /// prepared for this runtime's current committed revision, including arrows,
    /// strokes and labels. No model or semantic revision changes here.
    @discardableResult
    func installPreparedEdgeBounds(_ bounds: [UUID: CGRect]) -> RuntimeUpdateWork {
        var work = RuntimeUpdateWork()
        for (id, raw) in bounds {
            guard let edge = edgesByID[id] else { continue }
            let rect = raw.standardized
            preparedObstacleEdgeIDs.remove(id)
            if !rect.isNull, [rect.minX, rect.maxX, rect.minY, rect.maxY].allSatisfy(\.isFinite) {
                edgeBoundsByID[id] = rect; edgeSpatial.set(id, bounds: rect)
                if edge.style == .orthogonal && (edge.points?.count ?? 0) < 2 { preparedObstacleEdgeIDs.insert(id) }
            } else {
                edgeBoundsByID[id] = nil; edgeSpatial.set(id, bounds: nil)
            }
            work.edgeVisits += 1; work.spatialUpdates += 1
        }
        return work
    }

    /// Locality is an explicit product policy: a target's rotated geometric
    /// bounds must intersect moving bounds expanded by max(locality,tolerance).
    /// This intentionally excludes distant shapes that merely share an axis.
    /// Source order preserves alignmentDelta's deterministic equal-distance tie.
    func snapCandidates(near moving: CGRect, excluding: Set<UUID> = [], tolerance: CGFloat, locality: CGFloat = 160) -> RuntimeQuery<DiagramNode> {
        guard tolerance.isFinite, tolerance >= 0, locality.isFinite, locality >= 0 else {
            return RuntimeQuery(values: [], work: RuntimeQueryWork())
        }
        let radius = max(locality, tolerance), region = moving.standardized.insetBy(dx: -radius, dy: -radius)
        let query = nodeSpatial.query(region)
        let ids = query.ids.filter { id in
            guard !excluding.contains(id), nodePaintRank[id] != nil, isVisible(nodeID: id), !isLocked(nodeID: id), permitsShapeSnap(nodeID: id),
                  let node = nodesByID[id] else { return false }
            return Self.intersects(ShapeSnapping.bounds(of: node), region)
        }.sorted { nodeIndexByID[$0, default: 0] < nodeIndexByID[$1, default: 0] }
        return RuntimeQuery(values: ids.compactMap { nodesByID[$0] }, work: query.work)
    }

    private func rebuild(page: DiagramPage, preparedRoutes: [UUID: [CGPoint]]) {
        // Prepare a replacement off to the side, then publish the complete set.
        var nodes: [UUID: DiagramNode] = [:], edges: [UUID: DiagramEdge] = [:]
        var nodeIndices: [UUID: Int] = [:], edgeIndices: [UUID: Int] = [:]
        for (index, node) in page.nodes.enumerated() where nodes[node.id] == nil { nodes[node.id] = node; nodeIndices[node.id] = index }
        for (index, edge) in page.edges.enumerated() where edges[edge.id] == nil { edges[edge.id] = edge; edgeIndices[edge.id] = index }
        pageID = page.id; paperScale = page.paperScale
        nodesByID = nodes; edgesByID = edges; nodeIndexByID = nodeIndices; edgeIndexByID = edgeIndices
        parentByID = [:]; childrenByParent = [:]; edgeParentByID = [:]; edgesByParent = [:]; edgesByEndpoint = [:]
        layersByName = (page.layers ?? []).reduce(into: [:]) { if $0[$1.name] == nil { $0[$1.name] = $1 } }
        for node in nodes.values {
            if let parent = node.parentID, nodes[parent] != nil {
                parentByID[node.id] = parent; childrenByParent[parent, default: []].insert(node.id)
            }
        }
        for edge in edges.values {
            if let parent = edge.parentID, nodes[parent] != nil {
                edgeParentByID[edge.id] = parent; edgesByParent[parent, default: []].insert(edge.id)
            }
            // Dangling endpoints are not admitted to the node adjacency map.
            if nodes[edge.source] != nil { edgesByEndpoint[edge.source, default: []].insert(edge.id) }
            if nodes[edge.target] != nil { edgesByEndpoint[edge.target, default: []].insert(edge.id) }
        }
        nodeDrawOrder = ShapeDrawingOrder.ordered(page.nodes, id: \.id, parentID: \.parentID,
            isGroup: { $0.formatting.isGroup },
            displayMode: { Double($0.formatting.sheet["DisplayMode"]?.value ?? "").flatMap { Int(exactly: $0) } }).map(\.id)
        let lanes = nodeDrawOrder.filter { nodes[$0]?.kind == .swimlane }, foreground = nodeDrawOrder.filter { nodes[$0]?.kind != .swimlane }
        paintOrder = lanes.map(PageElementID.node) + page.edges.map { .edge($0.id) } + foreground.map(PageElementID.node)
        nodePaintRank = [:]; edgePaintRank = [:]
        for (rank, item) in paintOrder.enumerated() {
            switch item { case .node(let id): nodePaintRank[id] = rank; case .edge(let id): edgePaintRank[id] = rank }
        }
        visibleByID = [:]; lockedByID = [:]; snapByID = [:]
        nodeBoundsByID = [:]; edgeBoundsByID = [:]; preparedObstacleEdgeIDs = []
        nodeSpatial.removeAll(); edgeSpatial.removeAll()
        var hierarchyVisits = 0
        for node in nodes.values {
            hierarchyVisits += cacheEligibility(node.id)
            let bounds = Self.conservativeBounds(of: node, paperScale: paperScale)
            nodeBoundsByID[node.id] = bounds; nodeSpatial.set(node.id, bounds: bounds)
        }
        for edge in edges.values { setEdgeBounds(edge, route: preparedRoutes[edge.id]) }
        lastUpdateWork = RuntimeUpdateWork(nodeVisits: nodes.count, edgeVisits: edges.count,
            hierarchyVisits: hierarchyVisits, spatialUpdates: nodes.count+edges.count, didRebuild: true)
    }

    @discardableResult
    private func cacheEligibility(_ id: UUID) -> Int {
        var current: UUID? = id, seen = Set<UUID>(), visible = true, locked = false, snap = true
        while let next = current, let node = nodesByID[next] {
            guard seen.insert(next).inserted, seen.count <= 64 else { visible = false; locked = true; snap = false; break }
            let names = Set(node.formatting.layerNames + [node.layer])
            locked = locked || node.locked
            for name in names {
                guard let layer = layersByName[name] else { continue }
                visible = visible && layer.visible; locked = locked || layer.locked; snap = snap && layer.snap
            }
            current = parentByID[next]
        }
        visibleByID[id] = visible; lockedByID[id] = locked; snapByID[id] = snap
        return seen.count
    }

    private func setEdgeBounds(_ edge: DiagramEdge, route: [CGPoint]?) {
        preparedObstacleEdgeIDs.remove(edge.id)
        // Orthogonal routing depends on obstacles and connection-point formulas.
        // Never evaluate them here. Missing prepared routes stay in overflow and
        // are returned by every edge query, preserving conservative correctness.
        guard let route, route.count >= 2, route.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), edge.label.isEmpty else {
            edgeBoundsByID[edge.id] = nil; edgeSpatial.set(edge.id, bounds: nil); return
        }
        let rect = route.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        let pad = (12+edge.width*2)/max(0.000001, paperScale)
        let bounds = rect.insetBy(dx: -pad, dy: -pad)
        edgeBoundsByID[edge.id] = bounds; edgeSpatial.set(edge.id, bounds: bounds)
        if edge.style == .orthogonal && (edge.points?.count ?? 0) < 2 { preparedObstacleEdgeIDs.insert(edge.id) }
    }

    /// Control-point hulls contain Bezier curves, including custom paths outside
    /// the node rectangle. Text block rotation is composed before node rotation.
    /// Padding covers built-in outsets, strokes and the screen shadow in page units.
    static func conservativeBounds(of node: DiagramNode, paperScale: Double = 1) -> CGRect {
        var local = node.rect
        if node.formatting.paths.isEmpty {
            // Cloud/document/cylinder control points extend beyond their rectangle.
            if [.cloud, .document, .cylinder].contains(node.kind) { local = local.insetBy(dx: -node.width*0.15, dy: -node.height*0.15) }
        } else {
            for path in node.formatting.paths {
                for command in path.commands {
                    let values = command.values
                    for i in stride(from: 0, to: values.count-1, by: 2) {
                        local = local.union(CGRect(x: node.x+values[i]*node.width, y: node.y+values[i+1]*node.height, width: 0, height: 0))
                    }
                }
            }
        }
        var bounds = transformedBounds(local, center: node.center, rotation: node.rotation,
            flipX: node.formatting.flipX, flipY: node.formatting.flipY)
        if !node.text.isEmpty, Double(node.formatting.sheet["HideText"]?.value ?? "0") != 1 {
            var text = node.formatting.textBox?.rect(in: node) ?? node.rect
            if node.kind == .person && node.formatting.textBox == nil {
                text = CGRect(x: node.x-30, y: node.y+node.height+5, width: node.width+60, height: 40)
            }
            func reflect(_ point: CGPoint) -> CGPoint {
                CGPoint(x: node.formatting.flipX ? 2*node.center.x-point.x : point.x,
                        y: node.formatting.flipY ? 2*node.center.y-point.y : point.y)
            }
            if let block = node.formatting.textBox {
                let center = reflect(CGPoint(x: node.x+block.centerX*node.width, y: node.y+block.centerY*node.height))
                text = CGRect(x: center.x-block.width*node.width/2+block.left,
                    y: center.y-block.height*node.height/2+block.top,
                    width: max(1, block.width*node.width-block.left-block.right),
                    height: max(1, block.height*node.height-block.top-block.bottom))
                text = transformedBounds(text, center: center,
                    rotation: block.rotation*(node.formatting.flipX != node.formatting.flipY ? -1 : 1))
            } else {
                let center = reflect(CGPoint(x: text.midX, y: text.midY))
                text = CGRect(x: center.x-text.width/2, y: center.y-text.height/2, width: text.width, height: text.height)
            }
            bounds = bounds.union(transformedBounds(text, center: node.center, rotation: node.rotation))
        }
        let pad = (10+max(0, node.strokeWidth))/max(0.000001, paperScale)
        return bounds.insetBy(dx: -pad, dy: -pad)
    }

    private static func transformedBounds(_ rect: CGRect, center: CGPoint, rotation: Double, flipX: Bool = false, flipY: Bool = false) -> CGRect {
        let radians = rotation * .pi/180, c = cos(radians), s = sin(radians)
        let points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY),
                      CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)]
        return points.reduce(CGRect.null) { result, point in
            let dx = (point.x-center.x)*(flipX ? -1 : 1), dy = (point.y-center.y)*(flipY ? -1 : 1)
            return result.union(CGRect(x: center.x+dx*c-dy*s, y: center.y+dx*s+dy*c, width: 0, height: 0))
        }
    }

    static func intersects(_ a: CGRect, _ b: CGRect) -> Bool {
        let a = a.standardized, b = b.standardized
        return a.minX <= b.maxX && a.maxX >= b.minX && a.minY <= b.maxY && a.maxY >= b.minY
    }
}

private struct SpatialBuckets {
    private struct Key: Hashable { var x: Int; var y: Int }
    private var buckets: [Key: Set<UUID>] = [:]
    private var keysByID: [UUID: [Key]] = [:]
    private var overflow: Set<UUID> = []
    private let cellSize: CGFloat
    private let maximumObjectBuckets = 64
    private let maximumQueryBuckets = 4096

    init(cellSize: CGFloat) { self.cellSize = cellSize.isFinite && cellSize > 0 ? cellSize : 256 }
    mutating func removeAll() { buckets = [:]; keysByID = [:]; overflow = [] }

    mutating func set(_ id: UUID, bounds: CGRect?) {
        if let previous = keysByID.removeValue(forKey: id) {
            for key in previous { buckets[key]?.remove(id); if buckets[key]?.isEmpty == true { buckets[key] = nil } }
        }
        overflow.remove(id)
        guard let bounds, let keys = keys(for: bounds, limit: maximumObjectBuckets) else { overflow.insert(id); return }
        keysByID[id] = keys
        for key in keys { buckets[key, default: []].insert(id) }
    }

    func query(_ rect: CGRect) -> (ids: Set<UUID>, work: RuntimeQueryWork) {
        guard let keys = keys(for: rect, limit: maximumQueryBuckets) else {
            let ids = Set(keysByID.keys).union(overflow)
            return (ids, RuntimeQueryWork(candidateVisits: ids.count, overflowVisits: overflow.count, usedFullScan: true))
        }
        var ids = overflow
        for key in keys { ids.formUnion(buckets[key] ?? []) }
        return (ids, RuntimeQueryWork(bucketVisits: keys.count, candidateVisits: ids.count, overflowVisits: overflow.count))
    }

    private func keys(for raw: CGRect, limit: Int) -> [Key]? {
        let rect = raw.standardized
        guard !rect.isNull, [rect.minX, rect.maxX, rect.minY, rect.maxY].allSatisfy({ $0.isFinite && abs($0/cellSize) < CGFloat(Int.max/4) }) else { return nil }
        let x0 = Int(floor(rect.minX/cellSize)), x1 = Int(floor(rect.maxX/cellSize))
        let y0 = Int(floor(rect.minY/cellSize)), y1 = Int(floor(rect.maxY/cellSize))
        guard x1-x0 < limit, y1-y0 < limit, (x1-x0+1)*(y1-y0+1) <= limit else { return nil }
        return (x0...x1).flatMap { x in (y0...y1).map { Key(x: x, y: $0) } }
    }
}
