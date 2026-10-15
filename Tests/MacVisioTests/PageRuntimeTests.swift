import XCTest
@testable import MacVisio

final class PageRuntimeTests: XCTestCase {
    func testChangeSetsSeparatePropertiesGeometryStructureAndPresentation() {
        var old = Diagram()
        old.pages[0].nodes = [DiagramNode(x: 0, y: 0), DiagramNode(x: 400, y: 0)]
        var new = old
        let id = old.page.nodes[0].id
        new.pages[0].nodes[0].fill = "#FF0000"
        let format = DocumentChangeSet.between(old, new)
        XCTAssertEqual(format.changedPageIDs, [old.page.id])
        XCTAssertEqual(format.pages[old.page.id]?.changedNodeIDs, [id])
        XCTAssertEqual(format.pages[old.page.id]?.geometryChangedNodeIDs, [])
        XCTAssertFalse(format.pages[old.page.id]!.requiresRuntimeRebuild)

        new = old; new.pages[0].nodes[0].x += 5
        XCTAssertEqual(DocumentChangeSet.between(old, new).pages[old.page.id]?.geometryChangedNodeIDs, [id])
        new = old; new.pages[0].nodes.reverse()
        let reorder = DocumentChangeSet.between(old, new).pages[old.page.id]!
        XCTAssertTrue(reorder.nodeOrderChanged)
        XCTAssertTrue(reorder.requiresRuntimeRebuild)
        XCTAssertTrue(reorder.changedNodeIDs.isEmpty)

        new = old; new.pages.append(DiagramPage()); new.activePageID = new.pages[1].id
        XCTAssertEqual(DocumentChangeSet.between(old, new).insertedPageIDs, [new.pages[1].id])
        old = new; new.activePageID = new.pages[0].id
        let activation = DocumentChangeSet.between(old, new)
        XCTAssertTrue(activation.activePageChanged)
        XCTAssertFalse(activation.hasSemanticChanges)
        XCTAssertTrue(activation.changedPageIDs.isEmpty)
    }

    func testHierarchyAdjacencySelectionAndDeleteUndoAreAtomic() {
        var group = DiagramNode(x: 0, y: 0); group.formatting.isGroup = true
        var child = DiagramNode(x: 20, y: 20); child.parentID = group.id
        let other = DiagramNode(x: 500, y: 20)
        let edge = DiagramEdge(source: child.id, target: other.id)
        let original = DiagramPage(nodes: [group, child, other], edges: [edge])
        let runtime = PageRuntime(page: original)
        XCTAssertEqual(runtime.childrenByParent[group.id], [child.id])
        XCTAssertEqual(runtime.descendants(of: group.id), [group.id, child.id])
        XCTAssertEqual(runtime.edgesByEndpoint[child.id], [edge.id])
        XCTAssertEqual(runtime.selectionMembership([group.id, UUID()], includingDescendants: true), [group.id, child.id])

        var removed = original; removed.nodes.removeAll { $0.id == child.id }; removed.edges = []
        let work = runtime.apply(page: removed, changes: .between(original, removed))
        XCTAssertTrue(work.didRebuild)
        XCTAssertNil(runtime.nodesByID[child.id])
        XCTAssertNil(runtime.childrenByParent[group.id])
        XCTAssertTrue(runtime.edgesByEndpoint.isEmpty)
        runtime.apply(page: original, changes: .between(removed, original))
        XCTAssertEqual(runtime.nodesByID[child.id], child)
        XCTAssertEqual(runtime.edgesByEndpoint[child.id], [edge.id])
        XCTAssertEqual(runtime.descendants(of: group.id), [group.id, child.id])
    }

    func testSingleFormatEditDoesNotWalkUnrelatedObjects() {
        let old = gridPage(count: 2_000)
        var new = old; new.nodes[1_000].fill = "#AABBCC"
        let runtime = PageRuntime(page: old)
        let work = runtime.apply(page: new, changes: .between(old, new))
        XCTAssertFalse(work.didRebuild)
        XCTAssertEqual(work.nodeVisits, 1)
        XCTAssertEqual(work.edgeVisits, 0)
        XCTAssertEqual(work.hierarchyVisits, 0)
        XCTAssertEqual(work.spatialUpdates, 1)
        XCTAssertEqual(runtime.nodesByID[new.nodes[1_000].id]?.fill, "#AABBCC")
        let query = runtime.nodeCandidates(at: new.nodes[1_000].center)
        XCTAssertEqual(query.values.map(\.id), [new.nodes[1_000].id])
        XCTAssertLessThan(query.work.candidateVisits, 8)
        XCTAssertFalse(query.work.usedFullScan)
    }

    func testPropertyUpdateMaintainsInheritedLocksAndEndpointAdjacency() {
        var group = DiagramNode(); group.formatting.isGroup = true
        var child = DiagramNode(); child.parentID = group.id
        let target = DiagramNode(x: 500, y: 0)
        let edge = DiagramEdge(source: child.id, target: target.id)
        let old = DiagramPage(nodes: [group, child, target], edges: [edge])
        let runtime = PageRuntime(page: old)
        var new = old; new.nodes[0].locked = true; new.edges[0].source = target.id
        let work = runtime.apply(page: new, changes: .between(old, new))
        XCTAssertFalse(work.didRebuild)
        XCTAssertTrue(runtime.isLocked(nodeID: child.id))
        XCTAssertFalse(runtime.edgesByEndpoint[child.id]?.contains(edge.id) ?? false)
        XCTAssertEqual(runtime.edgesByEndpoint[target.id], [edge.id])
        XCTAssertEqual(work.nodeVisits, 1)
        XCTAssertEqual(work.edgeVisits, 1)
        XCTAssertEqual(work.hierarchyVisits, 3)
    }

    func testPaintAndHitOrderFollowGroupsAndSwimlaneLayers() {
        var group = DiagramNode(); group.formatting.isGroup = true
        group.formatting.sheet["DisplayMode"] = ShapeSheetCell(value: "1")
        var child = DiagramNode(); child.parentID = group.id
        let lane = DiagramNode(kind: .swimlane)
        let edge = DiagramEdge(source: group.id, target: child.id)
        let page = DiagramPage(nodes: [group, child, lane], edges: [edge])
        let runtime = PageRuntime(page: page)
        XCTAssertEqual(runtime.paintOrder, [.node(lane.id), .edge(edge.id), .node(group.id), .node(child.id)])
        XCTAssertEqual(runtime.nodeCandidates(at: group.center).values.map(\.id), [child.id, group.id, lane.id])
        XCTAssertNotEqual(runtime.nodeCandidates(at: group.center).values.first?.id, page.nodes.reversed().first?.id)

        var next = page; next.nodes[0].formatting.sheet["DisplayMode"] = ShapeSheetCell(value: "2")
        runtime.apply(page: next, changes: .between(page, next))
        XCTAssertEqual(runtime.nodeCandidates(at: group.center).values.map(\.id), [group.id, child.id, lane.id])
        next.nodes[0].formatting.sheet["DisplayMode"] = ShapeSheetCell(value: "0")
        runtime.apply(page: next, changes: .between(page, next))
        XCTAssertEqual(runtime.nodeCandidates(at: group.center).values.map(\.id), [child.id, lane.id])
    }

    func testSpatialQueriesAgreeWithConservativeScanForRotatedNestedAndCustomShapes() {
        var page = gridPage(count: 300)
        var group = DiagramNode(x: -200, y: -200); group.formatting.isGroup = true
        group.formatting.sheet["DisplayMode"] = ShapeSheetCell(value: "1")
        var child = DiagramNode(x: -30, y: -20); child.parentID = group.id; child.rotation = 38
        child.formatting.paths = [VectorPath(commands: [VectorCommand("M", -1, -1), VectorCommand("C", -2, 0, 1, 2, 2, 1)])]
        var person = DiagramNode(kind: .person, x: 0, y: 500); person.rotation = -22
        page.nodes.insert(contentsOf: [group, child, person], at: 0)
        let runtime = PageRuntime(page: page, cellSize: 128)
        for index in 0..<100 {
            let region = CGRect(x: index*157 % 1_800-350, y: index*233 % 1_400-350, width: 140, height: 100)
            let expected = runtime.nodeDrawOrder.filter { id in
                guard let node = runtime.nodesByID[id] else { return false }
                return runtime.isVisible(nodeID: id) && PageRuntime.intersects(PageRuntime.conservativeBounds(of: node), region)
            }
            XCTAssertEqual(runtime.nodes(intersecting: region).values.map(\.id), expected)
        }
        let expanded = PageRuntime.conservativeBounds(of: child)
        let control = rotated(CGPoint(x: child.x-2*child.width, y: child.y), around: child.center, degrees: child.rotation)
        XCTAssertTrue(expanded.contains(control))
        // A point/zero-area rectangle on a bucket boundary must not disappear.
        let boundary = CGPoint(x: 256, y: 0)
        XCTAssertEqual(Set(runtime.nodeCandidates(at: boundary).values.map(\.id)), Set(runtime.nodes(intersecting: CGRect(origin: boundary, size: .zero)).values.map(\.id)))
    }

    func testSnappingIsLocalAndMatchesPolicyScanWithVisibilityAndLocks() {
        var page = gridPage(count: 2_000)
        var moving = DiagramNode(x: 1, y: 1); moving.width = 100; moving.height = 50
        var near = DiagramNode(x: 104, y: 4); near.width = 100; near.height = 50; near.rotation = 12
        var distant = DiagramNode(x: 102, y: 50_000); distant.width = 100
        var hidden = DiagramNode(x: 105, y: 5); hidden.layer = "Hidden"
        var locked = DiagramNode(x: 106, y: 5); locked.locked = true
        var noSnap = DiagramNode(x: 107, y: 5); noSnap.layer = "NoSnap"
        page.nodes.insert(contentsOf: [moving, near, distant, hidden, locked, noSnap], at: 0)
        page.layers = [DiagramLayer(name: "Hidden", visible: false), DiagramLayer(name: "NoSnap", snap: false)]
        let runtime = PageRuntime(page: page)
        let region = moving.rect.insetBy(dx: -160, dy: -160)
        let expected = page.nodes.filter { node in
            node.id != moving.id && runtime.isVisible(nodeID: node.id) && !runtime.isLocked(nodeID: node.id)
                && runtime.permitsShapeSnap(nodeID: node.id) && PageRuntime.intersects(ShapeSnapping.bounds(of: node), region)
        }
        let query = runtime.snapCandidates(near: moving.rect, excluding: [moving.id], tolerance: 6)
        XCTAssertEqual(query.values.map(\.id), expected.map(\.id))
        XCTAssertTrue(query.values.contains { $0.id == near.id })
        XCTAssertFalse(query.values.contains { $0.id == distant.id || $0.id == hidden.id || $0.id == locked.id || $0.id == noSnap.id })
        XCTAssertLessThan(query.work.candidateVisits, 20)
        XCTAssertEqual(ShapeSnapping.alignmentDelta(moving: moving.rect, targets: query.values.map(ShapeSnapping.bounds(of:)), tolerance: 6),
                       ShapeSnapping.alignmentDelta(moving: moving.rect, targets: expected.map(ShapeSnapping.bounds(of:)), tolerance: 6))
    }

    func testPreparedRoutesAndUnknownFallbackAreConservativeAndObstacleSafe() {
        let source = DiagramNode(x: 0, y: 0), target = DiagramNode(x: 500, y: 0), obstacle = DiagramNode(x: 250, y: 200)
        let automatic = DiagramEdge(source: source.id, target: target.id)
        var straight = DiagramEdge(source: source.id, target: target.id); straight.style = .straight
        let old = DiagramPage(nodes: [source, target, obstacle], edges: [automatic, straight])
        let route = [CGPoint(x: 160, y: 40), CGPoint(x: 500, y: 40)]
        let runtime = PageRuntime(page: old, preparedRoutes: [automatic.id: route, straight.id: route])
        let far = CGRect(x: 10_000, y: 10_000, width: 10, height: 10)
        XCTAssertTrue(runtime.edgeCandidates(intersecting: far).values.isEmpty)
        var new = old; new.nodes[2].y += 20
        let work = runtime.apply(page: new, changes: .between(old, new))
        XCTAssertEqual(work.nodeVisits, 1)
        XCTAssertEqual(work.edgeVisits, 1)
        XCTAssertNil(runtime.edgeBoundsByID[automatic.id])
        XCTAssertNotNil(runtime.edgeBoundsByID[straight.id])
        let fallback = runtime.edgeCandidates(intersecting: far)
        XCTAssertEqual(fallback.values.map(\.id), [automatic.id])
        XCTAssertEqual(fallback.work.overflowVisits, 1)
        runtime.apply(page: new, changes: PageChangeSet(pageID: new.id), preparedRoutes: [automatic.id: route])
        XCTAssertTrue(runtime.edgeCandidates(intersecting: far).values.isEmpty)
    }

    func testFlippedTextBoxAndConnectorParentBoundsRemainIndexed() {
        var group = DiagramNode(x: 0, y: 0); group.formatting.isGroup = true
        group.formatting.flipX = true
        group.formatting.textBox = ShapeTextBox(centerX: 3, centerY: 0.5, width: 1, height: 1, rotation: 30)
        let edge = DiagramEdge(source: group.id, target: UUID(), parentID: group.id)
        let runtime = PageRuntime(page: DiagramPage(nodes: [group], edges: [edge]))
        XCTAssertEqual(runtime.edgeParentByID[edge.id], group.id)
        XCTAssertEqual(runtime.edgesByParent[group.id], [edge.id])
        let reflectedCenter = CGPoint(x: 2*group.center.x-3*group.width, y: group.height/2)
        XCTAssertTrue(runtime.nodeBoundsByID[group.id]!.contains(reflectedCenter))
        XCTAssertEqual(runtime.nodeCandidates(at: reflectedCenter).values.map(\.id), [group.id])
    }

    func testMeasuredLabelBoundsCanReplaceUnknownRouteFallback() {
        let node = DiagramNode()
        let edge = DiagramEdge(source: node.id, target: UUID(), label: "Measured label")
        let runtime = PageRuntime(page: DiagramPage(nodes: [node], edges: [edge]))
        let far = CGRect(x: 20_000, y: 20_000, width: 1, height: 1)
        XCTAssertEqual(runtime.edgeCandidates(intersecting: far).values.map(\.id), [edge.id])
        let work = runtime.installPreparedEdgeBounds([edge.id: CGRect(x: 0, y: 0, width: 500, height: 200)])
        XCTAssertEqual(work.edgeVisits, 1)
        XCTAssertTrue(runtime.edgeCandidates(intersecting: far).values.isEmpty)
        XCTAssertEqual(runtime.edgeCandidates(intersecting: CGRect(x: 490, y: 190, width: 5, height: 5)).values.map(\.id), [edge.id])
    }

    func testOversizedBoundsAndQueriesUseMeasuredFallbackWithoutMissingShapes() {
        var huge = DiagramNode(x: -100_000, y: -100_000); huge.width = 200_000; huge.height = 200_000
        let ordinary = DiagramNode(x: 400, y: 400)
        let runtime = PageRuntime(page: DiagramPage(nodes: [huge, ordinary]), cellSize: 64)
        let local = runtime.nodeCandidates(at: CGPoint(x: 1, y: 1))
        XCTAssertEqual(local.values.map(\.id), [huge.id])
        XCTAssertEqual(local.work.overflowVisits, 1)
        let full = runtime.nodes(intersecting: CGRect(x: -1_000_000, y: -1_000_000, width: 2_000_000, height: 2_000_000))
        XCTAssertEqual(Set(full.values.map(\.id)), [huge.id, ordinary.id])
        XCTAssertTrue(full.work.usedFullScan)
        XCTAssertEqual(full.work.candidateVisits, 2)
    }

    func testMalformedCyclesAndDanglingEndpointsTerminateWithoutDanglingIndexes() {
        var a = DiagramNode(), b = DiagramNode()
        a.parentID = b.id; b.parentID = a.id
        let dangling = UUID(), edge = DiagramEdge(source: a.id, target: dangling)
        let runtime = PageRuntime(page: DiagramPage(nodes: [a, b], edges: [edge]))
        XCTAssertEqual(runtime.descendants(of: a.id), [a.id, b.id])
        XCTAssertTrue(runtime.isLocked(nodeID: a.id))
        XCTAssertFalse(runtime.isVisible(nodeID: b.id))
        XCTAssertNil(runtime.edgesByEndpoint[dangling])
        XCTAssertEqual(Set(runtime.nodeDrawOrder), [a.id, b.id])
    }

    private func gridPage(count: Int) -> DiagramPage {
        DiagramPage(nodes: (0..<count).map { index in DiagramNode(x: Double(index%50)*600, y: Double(index/50)*400) })
    }

    private func rotated(_ point: CGPoint, around center: CGPoint, degrees: Double) -> CGPoint {
        let a = degrees * .pi/180, x = point.x-center.x, y = point.y-center.y
        return CGPoint(x: center.x+x*cos(a)-y*sin(a), y: center.y+x*sin(a)+y*cos(a))
    }
}
