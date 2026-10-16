import AppKit
import MacVisioInfrastructure
import XCTest

@testable import MacVisio

final class RetainedSceneTests: XCTestCase {
    func testValueSnapshotSurvivesReuseOfSerialUICaches() {
        var page = DiagramPage()
        page.nodes = [DiagramNode(x: 10, y: 20), DiagramNode(x: 500, y: 20)]
        page.edges = [DiagramEdge(source: page.nodes[0].id, target: page.nodes[1].id)]
        let first = RetainedRenderScene(scene: DiagramScene(page: page), revision: 1)
        let snapshot = first.snapshot
        page.nodes[0].x = 90
        let second = RetainedRenderScene(scene: DiagramScene(page: page), revision: 2, previous: first)
        XCTAssertEqual(first.snapshot.layers[0].page.nodes[0].x, 10)
        XCTAssertEqual(snapshot.layers[0].page.nodes[0].x, 10)
        XCTAssertEqual(second.snapshot.layers[0].page.nodes[0].x, 90)
        XCTAssertNotEqual(snapshot.layers[0].routes, second.snapshot.layers[0].routes)
    }

    func testSmallDirtyRegionVisitsLocalCandidatesAndReusesTextAndPaths() throws {
        _ = NSApplication.shared
        var page = DiagramPage(width: 20000, height: 20000)
        page.nodes = (0..<5000).map {
            DiagramNode(x: Double($0 % 100) * 190, y: Double($0 / 100) * 190, text: "Retained")
        }
        let retained = RetainedRenderPage(page)
        try drawing {
            retained.draw(in: CGRect(x: 10, y: 10, width: 16, height: 16), printing: false)
            XCTAssertEqual(retained.lastDrawWork.nodesDrawn, 1)
            XCTAssertLessThan(retained.lastDrawWork.candidates, 20)
            retained.draw(in: CGRect(x: 10, y: 10, width: 16, height: 16), printing: false)
            XCTAssertEqual(retained.lastDrawWork.nodePreparations, 0)
            XCTAssertEqual(retained.lastDrawWork.routePreparations, 0)
        }
        XCTAssertLessThanOrEqual(
            retained.cacheStatistics.cost, ResourceBudgets.retainedPaths + ResourceBudgets.retainedText)
    }

    func testPreparedRouteAndConnectionHitDrawingNeverEnterFormulaParser() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument()
        var a = DiagramNode(x: 100, y: 100)
        var b = DiagramNode(x: 500, y: 100)
        a.formatting.connectionPoints = [
            ShapeConnectionPoint(
                index: 0, name: "Port", x: ShapeSheetCell(value: "0", formula: "Width/2"),
                y: ShapeSheetCell(value: "0", formula: "Height/2"))
        ]
        b.text = "Target"
        document.diagram.page.nodes = [a, b]
        document.diagram.page.edges = [
            DiagramEdge(source: a.id, target: b.id, sourcePort: a.formatting.connectionPoints[0].id)
        ]
        document.makeWindowControllers()
        defer { document.close() }
        let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        let baseline = document.diagram
        let revision = document.revision
        let parser = ShapeSheetExpressionCache.shared.statistics
        try drawing {
            editor.retainedScene.foreground.draw(
                in: CGRect(x: 0, y: 0, width: 1000, height: 800), printing: false)
        }
        _ = editor.canvas.node(at: CGPoint(x: 150, y: 130))
        _ = editor.canvas.edge(at: CGPoint(x: 400, y: 140))
        XCTAssertEqual(ShapeSheetExpressionCache.shared.statistics, parser)
        XCTAssertEqual(document.diagram, baseline)
        XCTAssertEqual(document.revision, revision)
    }

    func testRouteDependenciesIncludeObstaclePortsAndFormattingAndReuseUnrelatedStraightRoute() {
        var page = DiagramPage()
        let a = DiagramNode(x: 20, y: 20)
        let b = DiagramNode(x: 600, y: 20)
        page.nodes = [a, b, DiagramNode(x: 300, y: 300)]
        page.edges = [
            DiagramEdge(source: a.id, target: b.id),
            DiagramEdge(source: a.id, target: b.id, style: .straight),
        ]
        let retained = RetainedRenderPage(page)
        let straight = retained.routes[page.edges[1].id]
        page.nodes[2].y = 100
        retained.update(page)
        XCTAssertEqual(retained.routePreparations, 1)
        XCTAssertEqual(retained.routes[page.edges[1].id], straight)
        page.nodes[0].x = 50
        retained.update(page)
        XCTAssertEqual(retained.routePreparations, 2)
        page.nodes[0].fill = "#FF0000"
        retained.update(page)
        XCTAssertEqual(retained.routePreparations, 0)
    }

    func testLayerColorAndOutputVisibilityAreShared() {
        var page = DiagramPage()
        page.layers = [
            DiagramLayer(name: "Colored", color: "#FF0000"), DiagramLayer(name: "Screen", printable: false),
        ]
        var a = DiagramNode(x: 10, y: 10)
        var b = DiagramNode(x: 300, y: 10)
        a.layer = "Colored"
        b.layer = "Screen"
        page.nodes = [a, b]
        let retained = RetainedRenderPage(page)
        XCTAssertEqual(retained.preparedNode(a).input.fill, "#FF0000")
        XCTAssertEqual(retained.preparedNode(a).input.textColor, "#FF0000")
        XCTAssertTrue(page.isVisible(b))
        XCTAssertFalse(page.isVisible(b, printing: true))
        XCTAssertTrue(DiagramDrawing.svg(page).contains("#FF0000"))
    }

    func testObstacleLayerMembershipInvalidatesAutomaticRouteAndRetainsUnrelatedStraightRoute() {
        var page = DiagramPage()
        page.layers = [DiagramLayer(name: "Hidden", visible: false)]
        let a = DiagramNode(x: 20, y: 20)
        let b = DiagramNode(x: 600, y: 20)
        page.nodes = [a, b, DiagramNode(x: 300, y: 20)]
        page.edges = [
            DiagramEdge(source: a.id, target: b.id),
            DiagramEdge(source: a.id, target: b.id, style: .straight),
        ]
        let retained = RetainedRenderPage(page)
        let automaticID = page.edges[0].id
        let straightID = page.edges[1].id
        let visibleRoute = retained.routes[automaticID]
        let straight = retained.routes[straightID]
        let straightBounds = retained.routeBounds[straightID]

        page.nodes[2].layer = "Hidden"
        retained.update(page)
        XCTAssertEqual(retained.routePreparations, 1)
        XCTAssertNotEqual(retained.routes[automaticID], visibleRoute)
        XCTAssertEqual(retained.routes, RetainedRenderPage(page).routes)
        XCTAssertEqual(retained.routes[straightID], straight)
        XCTAssertEqual(retained.routeBounds[straightID], straightBounds)

        page.nodes[2].layer = "Default"
        retained.update(page)
        XCTAssertEqual(retained.routePreparations, 1)
        XCTAssertEqual(retained.routes[automaticID], visibleRoute)
        XCTAssertEqual(retained.routes[straightID], straight)

        page.nodes[2].formatting.layerNames = ["Hidden"]
        retained.update(page)
        XCTAssertEqual(retained.routePreparations, 1)
        XCTAssertNotEqual(retained.routes[automaticID], visibleRoute)
        XCTAssertEqual(retained.routes, RetainedRenderPage(page).routes)
        XCTAssertEqual(retained.routes[straightID], straight)
        XCTAssertEqual(retained.routeBounds[straightID], straightBounds)
    }

    func testSignedDimensionsInvalidateIncidentPortRoutesAndRetainUnrelatedStraightRoute() throws {
        var page = DiagramPage()
        var source = DiagramNode(x: 20, y: 20)
        let target = DiagramNode(x: 600, y: 20)
        let unrelatedSource = DiagramNode(x: 20, y: 300)
        let unrelatedTarget = DiagramNode(x: 600, y: 300)
        let port = ShapeConnectionPoint(
            index: 0, name: "Literal", x: ShapeSheetCell(value: "0.5"), y: ShapeSheetCell(value: "0.25"))
        source.formatting.connectionPoints = [port]
        page.nodes = [source, target, unrelatedSource, unrelatedTarget]
        page.edges = [
            DiagramEdge(source: source.id, target: target.id, sourcePort: port.id),
            DiagramEdge(source: source.id, target: target.id, style: .straight, sourcePort: port.id),
            DiagramEdge(source: unrelatedSource.id, target: unrelatedTarget.id, style: .straight),
        ]
        let retained = RetainedRenderPage(page)
        let unrelatedID = page.edges[2].id
        let unrelated = retained.routes[unrelatedID]
        let unrelatedBounds = retained.routeBounds[unrelatedID]
        var before = page
        page.nodes[0].formatting.negativeWidth = true
        for axis in 0..<2 {
            if axis == 1 {
                before = page
                page.nodes[0].formatting.negativeHeight = true
            }
            XCTAssertEqual(PageChangeSet.between(before, page).geometryChangedNodeIDs, [source.id])
            retained.update(page)
            XCTAssertEqual(retained.routePreparations, 2)
            let expected = ConnectionGeometry.point(port, on: page.nodes[0])
            XCTAssertEqual(retained.connectionPoints[source.id]?[port.id], expected)
            for edge in page.edges.prefix(2) {
                let first = try XCTUnwrap(retained.routes[edge.id]?.first)
                XCTAssertEqual(first.x, expected.x, accuracy: 1e-8)
                XCTAssertEqual(first.y, expected.y, accuracy: 1e-8)
            }
            XCTAssertEqual(retained.routes, RetainedRenderPage(page).routes)
            XCTAssertEqual(retained.routes[unrelatedID], unrelated)
            XCTAssertEqual(retained.routeBounds[unrelatedID], unrelatedBounds)
        }
    }

    func testCoordinateBoundaryAppliesPaperScaleOnce() {
        let transform = ViewportCoordinates(pageOrigin: CGPoint(x: 80, y: 40), paperScale: 0.25, zoom: 2)
        let point = DrawingLocation(point: CGPoint(x: 300, y: 120))
        let canvas = transform.canvas(point)
        XCTAssertEqual(canvas.point, CGPoint(x: 230, y: 100))
        XCTAssertEqual(transform.drawing(canvas).point, point.point)
    }

    private func drawing(_ body: () throws -> Void) throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        defer { NSGraphicsContext.restoreGraphicsState() }
        try body()
    }
}
