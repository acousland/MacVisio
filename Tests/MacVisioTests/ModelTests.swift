import XCTest
@testable import MacVisio

final class ModelTests: XCTestCase {
    func testFreshDiagramHasAnActiveLandscapePage() throws {
        let diagram = Diagram()
        XCTAssertEqual(diagram.pages.count, 1)
        XCTAssertEqual(diagram.page.id, diagram.activePageID)
        XCTAssertEqual(diagram.page.width, 1120)
        XCTAssertEqual(diagram.page.height, 840)
        XCTAssertEqual(try diagram.validated(), diagram)
    }

    func testActivePageMutationPreservesOtherPages() {
        var diagram = Diagram()
        let original = diagram.page
        let second = DiagramPage(name: "Details")
        diagram.pages.append(second)
        diagram.activePageID = second.id
        diagram.page.name = "Updated details"
        diagram.page.nodes.append(DiagramNode(text: "On page two"))
        XCTAssertEqual(diagram.activePageIndex, 1)
        XCTAssertEqual(diagram.pages[0], original)
        XCTAssertEqual(diagram.pages[1].name, "Updated details")
        XCTAssertEqual(diagram.pages[1].nodes.count, 1)
    }

    func testValidationRejectsUnsupportedVersionEmptyPagesAndDuplicatePages() {
        var unsupported = Diagram()
        unsupported.version = 2
        XCTAssertThrowsError(try unsupported.validated())
        var empty = Diagram()
        empty.pages = []
        XCTAssertThrowsError(try empty.validated())
        var duplicate = Diagram()
        duplicate.pages.append(duplicate.page)
        XCTAssertThrowsError(try duplicate.validated())
    }

    func testValidationRejectsInvalidPageDimensions() {
        for invalid in [Double.nan, Double.infinity, -1, 0, 20001] {
            var diagram = Diagram()
            diagram.page.width = invalid
            XCTAssertThrowsError(try diagram.validated(), "Accepted page width \(invalid)")
            diagram = Diagram()
            diagram.page.height = invalid
            XCTAssertThrowsError(try diagram.validated(), "Accepted page height \(invalid)")
        }
    }

    func testValidationRejectsInvalidShapeGeometry() {
        let cases: [(String, (inout DiagramNode) -> Void)] = [
            ("nonfinite x", { $0.x = .nan }),
            ("nonfinite y", { $0.y = .infinity }),
            ("out of range x", { $0.x = 100000 }),
            ("out of range y", { $0.y = -100000 }),
            ("zero width", { $0.width = 0 }),
            ("oversized height", { $0.height = 20001 }),
            ("invalid font", { $0.fontSize = 0 }),
            ("nonfinite rotation", { $0.rotation = .infinity }),
            ("negative stroke", { $0.strokeWidth = -1 })
        ]
        for (name, mutate) in cases {
            var diagram = Diagram()
            var node = DiagramNode()
            mutate(&node)
            diagram.page.nodes = [node]
            XCTAssertThrowsError(try diagram.validated(), "Accepted \(name)")
        }
    }

    func testValidationRejectsDuplicateShapesConnectorsAndMissingEndpoints() {
        let source = DiagramNode()
        let target = DiagramNode(x: 400)
        var diagram = Diagram()
        diagram.page.nodes = [source, source]
        XCTAssertThrowsError(try diagram.validated())
        diagram.page.nodes = [source, target]
        let edge = DiagramEdge(source: source.id, target: target.id)
        diagram.page.edges = [edge, edge]
        XCTAssertThrowsError(try diagram.validated())
        diagram.page.edges = [DiagramEdge(source: UUID(), target: target.id)]
        XCTAssertThrowsError(try diagram.validated())
        diagram.page.edges = [DiagramEdge(source: source.id, target: UUID())]
        XCTAssertThrowsError(try diagram.validated())
        var invalidWidth = edge
        invalidWidth.width = .nan
        diagram.page.edges = [invalidWidth]
        XCTAssertThrowsError(try diagram.validated())
    }

    func testGridSnappingUsesNearestGridIntersection() {
        XCTAssertEqual(DiagramGeometry.snapped(24), 20)
        XCTAssertEqual(DiagramGeometry.snapped(25), 30)
        XCTAssertEqual(DiagramGeometry.snapped(-25), -30)
        XCTAssertEqual(DiagramGeometry.snapped(13, grid: 8), 16)
        XCTAssertEqual(DiagramGeometry.snapped(0), 0)
    }

    func testRectangleBoundaryAttachesAtItsPerimeter() {
        let node = DiagramNode(x: 100, y: 80)
        XCTAssertEqual(DiagramGeometry.boundary(of: node, toward: CGPoint(x: 1000, y: 120)), CGPoint(x: 260, y: 120))
        XCTAssertEqual(DiagramGeometry.boundary(of: node, toward: CGPoint(x: 180, y: -100)), CGPoint(x: 180, y: 80))
        XCTAssertEqual(DiagramGeometry.boundary(of: node, toward: node.center), CGPoint(x: 180, y: 80))
    }

    func testEllipseAndDiamondBoundaryFollowTheirOutlines() {
        let target = CGPoint(x: 500, y: 400)
        let ellipse = DiagramNode(kind: .ellipse, x: 100, y: 100)
        let e = DiagramGeometry.boundary(of: ellipse, toward: target)
        let ex = (e.x - ellipse.center.x) / (ellipse.width / 2)
        let ey = (e.y - ellipse.center.y) / (ellipse.height / 2)
        XCTAssertEqual(ex * ex + ey * ey, 1, accuracy: 0.000001)
        let diamond = DiagramNode(kind: .diamond, x: 100, y: 100)
        let d = DiagramGeometry.boundary(of: diamond, toward: target)
        let dx = abs(d.x - diamond.center.x) / (diamond.width / 2)
        let dy = abs(d.y - diamond.center.y) / (diamond.height / 2)
        XCTAssertEqual(dx + dy, 1, accuracy: 0.000001)
    }

    func testOrthogonalRouteUpdatesEndpointsWhenShapeMoves() {
        let source = DiagramNode(x: 100, y: 100)
        var target = DiagramNode(x: 500, y: 120)
        let edge = DiagramEdge(source: source.id, target: target.id)
        var page = DiagramPage(nodes: [source, target], edges: [edge])
        let initial = DiagramGeometry.route(edge, in: page)
        XCTAssertEqual(initial.first, CGPoint(x: 260, y: 140))
        XCTAssertEqual(initial.last, CGPoint(x: 500, y: 160))
        assertOrthogonal(initial)
        target.x = 100
        target.y = 500
        page.nodes[1] = target
        let moved = DiagramGeometry.route(edge, in: page)
        XCTAssertEqual(moved.first, CGPoint(x: 180, y: 180))
        XCTAssertEqual(moved.last, CGPoint(x: 180, y: 500))
        XCTAssertNotEqual(initial, moved)
        assertOrthogonal(moved)
    }

    func testStraightRouteUsesUpdatedShapeBoundaries() {
        let source = DiagramNode(kind: .ellipse, x: 80, y: 80)
        var target = DiagramNode(kind: .diamond, x: 500, y: 400)
        let edge = DiagramEdge(source: source.id, target: target.id, style: .straight)
        var page = DiagramPage(nodes: [source, target], edges: [edge])
        let initial = DiagramGeometry.route(edge, in: page)
        XCTAssertEqual(initial.count, 2)
        XCTAssertEqual(initial.first, DiagramGeometry.boundary(of: source, toward: target.center))
        XCTAssertEqual(initial.last, DiagramGeometry.boundary(of: target, toward: source.center))
        target.x = 800
        target.y = 150
        page.nodes[1] = target
        let moved = DiagramGeometry.route(edge, in: page)
        XCTAssertEqual(moved.first, DiagramGeometry.boundary(of: source, toward: target.center))
        XCTAssertEqual(moved.last, DiagramGeometry.boundary(of: target, toward: source.center))
        XCTAssertNotEqual(initial, moved)
    }

    func testSelfLoopAndMissingEndpointRoutes() {
        let node = DiagramNode(x: 100, y: 100)
        let loop = DiagramEdge(source: node.id, target: node.id)
        let page = DiagramPage(nodes: [node], edges: [loop])
        let route = DiagramGeometry.route(loop, in: page)
        XCTAssertEqual(route.count, 5)
        XCTAssertEqual(route.first, CGPoint(x: 260, y: 140))
        XCTAssertEqual(route.last, CGPoint(x: 180, y: 100))
        assertOrthogonal(route)
        XCTAssertTrue(DiagramGeometry.route(DiagramEdge(source: node.id, target: UUID()), in: page).isEmpty)
    }

    func testDistanceToConnectorSegmentClampsAtEndpoints() {
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 100, y: 0)
        XCTAssertEqual(DiagramGeometry.distance(CGPoint(x: 40, y: 30), to: a, b), 30)
        XCTAssertEqual(DiagramGeometry.distance(CGPoint(x: -3, y: 4), to: a, b), 5)
        XCTAssertEqual(DiagramGeometry.distance(CGPoint(x: 103, y: 4), to: a, b), 5)
        XCTAssertEqual(DiagramGeometry.distance(CGPoint(x: 3, y: 4), to: a, a), 5)
    }

    func testStarterTemplatesAreValidFitThePageAndHaveConnectedProcesses() throws {
        for template in DiagramTemplate.allCases {
            let diagram = template.makeDiagram()
            XCTAssertEqual(try diagram.validated(), diagram, template.rawValue)
            XCTAssertFalse(template.title.isEmpty)
            XCTAssertFalse(template.subtitle.isEmpty)
            XCTAssertFalse(template.symbol.isEmpty)
            for node in diagram.page.nodes {
                XCTAssertGreaterThanOrEqual(node.x, 0, template.rawValue)
                XCTAssertGreaterThanOrEqual(node.y, 0, template.rawValue)
                XCTAssertLessThanOrEqual(node.x + node.width, diagram.page.width, template.rawValue)
                XCTAssertLessThanOrEqual(node.y + node.height, diagram.page.height, template.rawValue)
            }
            let processes = diagram.page.nodes.filter { $0.kind != .swimlane && $0.kind != .text }
            let endpointIDs = Set(diagram.page.edges.flatMap { [$0.source, $0.target] })
            if template == .blank {
                XCTAssertTrue(processes.isEmpty)
                XCTAssertTrue(diagram.page.edges.isEmpty)
            } else {
                XCTAssertGreaterThan(processes.count, 1)
                XCTAssertEqual(Set(processes.map(\.id)), endpointIDs, template.rawValue)
                var reached = Set([processes[0].id])
                var changed = true
                while changed {
                    let priorCount = reached.count
                    for edge in diagram.page.edges where reached.contains(edge.source) || reached.contains(edge.target) {
                        reached.insert(edge.source)
                        reached.insert(edge.target)
                    }
                    changed = reached.count != priorCount
                }
                XCTAssertEqual(reached, endpointIDs, template.rawValue)
                XCTAssertTrue(diagram.page.edges.allSatisfy { !DiagramGeometry.route($0, in: diagram.page).isEmpty })
            }
        }
        let flowchart = DiagramTemplate.flowchart.makeDiagram()
        XCTAssertEqual(flowchart.title, "Purchase approval")
        XCTAssertEqual(flowchart.page.nodes.count, 8)
        XCTAssertTrue(flowchart.page.edges.contains { $0.label == "Yes" })
        XCTAssertTrue(flowchart.page.edges.contains { $0.label == "No" })
    }

    func testJSONRoundTripPreservesAllEditingPropertiesAndActivePage() throws {
        var diagram = DiagramTemplate.network.makeDiagram()
        var node = DiagramNode(kind: .triangle, x: 33.5, y: 77.25, text: "Unicode: café → 東京\nSecond line")
        node.width = 193
        node.height = 117
        node.fill = "#EECCAA80"
        node.stroke = "#123456"
        node.textColor = "#654321"
        node.strokeWidth = 3.25
        node.fontSize = 19
        node.bold = true
        node.rotation = 37.5
        node.locked = true
        node.layer = "Notes"
        let target = DiagramNode(kind: .person, x: 500, y: 500)
        let edge = DiagramEdge(source: node.id, target: target.id, label: "Reports to", color: "#ABCDEF", width: 2.75, style: .straight, arrow: false)
        let detail = DiagramPage(name: "Details", width: 840, height: 1120, nodes: [node, target], edges: [edge])
        diagram.pages.append(detail)
        diagram.activePageID = detail.id
        let data = try JSONEncoder().encode(diagram)
        let decoded = try JSONDecoder().decode(Diagram.self, from: data).validated()
        XCTAssertEqual(decoded, diagram)
        XCTAssertEqual(decoded.activePageIndex, 1)
        XCTAssertEqual(decoded.page.nodes[0], node)
        XCTAssertEqual(decoded.page.edges[0], edge)
    }

    private func assertOrthogonal(_ points: [CGPoint], file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(points, points.dropFirst()) {
            XCTAssertTrue(a.x == b.x || a.y == b.y, "Connector has a diagonal segment", file: file, line: line)
        }
    }
}
