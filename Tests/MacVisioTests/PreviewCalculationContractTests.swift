import AppKit
import XCTest

@testable import MacVisio

final class PreviewCalculationContractTests: XCTestCase {
    func testPreviewProjectsPreparedPortsThroughResizeRotationAndFlipWithoutFormulaEvaluation() throws {
        try onMain {
            _ = NSApplication.shared
            var page = fixture().page
            page.nodes[0].rotation = 25
            page.nodes[0].formatting.flipX = true
            page.nodes[0].formatting.connectionPoints[0].x.formula = "Width/4"
            page.nodes[0].formatting.connectionPoints[0].y.formula = "Height/4"
            let committed = RetainedRenderScene(scene: DiagramScene(page: page), revision: 8)
            let baseline = committed.snapshot
            let nodeID = page.nodes[0].id
            let portID = page.nodes[0].formatting.connectionPoints[0].id
            let formulas = page.nodes[0].formatting.connectionPoints
            let parser = ShapeSheetExpressionCache.shared.statistics
            let run = try XCTUnwrap(PerformanceEvidence.beginRun())
            defer { _ = PerformanceEvidence.endRun(run) }
            var preview: RetainedRenderScene? = RetainedRenderScene(previewPage: page, baseline: baseline)
            XCTAssertEqual(preview?.foreground.routes, committed.foreground.routes)
            XCTAssertEqual(preview?.foreground.connectionPoints, committed.foreground.connectionPoints)
            for index in 0..<20 {
                page.nodes[0].width = 180 + Double(index)
                page.nodes[0].height = 90 + Double(index)
                page.nodes[0].rotation = 40 + Double(index)
                page.nodes[0].formatting.flipX = false
                page.nodes[0].formatting.flipY = true
                preview = RetainedRenderScene(previewPage: page, baseline: baseline, previous: preview)
                let expected = DiagramCoordinates.world(
                    CGPoint(x: page.nodes[0].width / 4, y: page.nodes[0].height * 0.75), in: page.nodes[0])
                let actual = try XCTUnwrap(preview?.foreground.connectionPoints[nodeID]?[portID])
                XCTAssertEqual(actual.x, expected.x, accuracy: 1e-8)
                XCTAssertEqual(actual.y, expected.y, accuracy: 1e-8)
                XCTAssertEqual(preview?.foreground.page.nodes[0].formatting.connectionPoints, formulas)
                XCTAssertEqual(preview?.foreground.previewPortProjectionCount, 1)
                let routed = try XCTUnwrap(preview?.foreground.routes[page.edges[0].id]?.first)
                XCTAssertEqual(routed.x, expected.x, accuracy: 1e-8)
                XCTAssertEqual(routed.y, expected.y, accuracy: 1e-8)
            }
            let report = try XCTUnwrap(PerformanceEvidence.endRun(run))
            XCTAssertEqual(ShapeSheetExpressionCache.shared.statistics, parser)
            assertNoSemanticWork(report)
            XCTAssertEqual(committed.snapshot.layers.last?.page, baseline.layers.last?.page)
            XCTAssertEqual(committed.foreground.connectionPoints, baseline.layers.last?.connectionPoints)
        }
    }

    func testTwentyNativeDragResizeCancelCyclesDoNotParseOrCalculatePortFormulas() throws {
        try withEditor { document, editor in
            let canvas = editor.canvas
            let baseline = document.diagram
            let revision = document.revision
            let stateID = document.stateID
            let id = baseline.page.nodes[0].id
            let parser = ShapeSheetExpressionCache.shared.statistics
            let run = try XCTUnwrap(PerformanceEvidence.beginRun())
            defer { _ = PerformanceEvidence.endRun(run) }
            for index in 0..<20 {
                canvas.select([id])
                let node = baseline.page.nodes[0]
                let start =
                    index.isMultiple(of: 2) ? node.center : CGPoint(x: node.rect.maxX, y: node.rect.maxY)
                let finish = CGPoint(x: start.x + 35, y: start.y + 25)
                canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, editor: editor))
                canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: finish, editor: editor))
                let previewNode = try XCTUnwrap(canvas.page.nodes.first { $0.id == id })
                let port = try XCTUnwrap(canvas.renderScene.foreground.connectionPoints[id]?.values.first)
                XCTAssertEqual(port.x, previewNode.center.x, accuracy: 1e-8)
                XCTAssertEqual(port.y, previewNode.center.y, accuracy: 1e-8)
                XCTAssertNotNil(canvas.connectionPoint(at: port, on: previewNode))
                _ = canvas.edge(at: port)
                canvas.keyDown(with: try escape(editor))
                XCTAssertEqual(document.diagram, baseline)
                XCTAssertEqual(document.revision, revision)
                XCTAssertEqual(document.stateID, stateID)
            }
            let report = try XCTUnwrap(PerformanceEvidence.endRun(run))
            XCTAssertEqual(ShapeSheetExpressionCache.shared.statistics, parser)
            assertNoSemanticWork(report)
            XCTAssertGreaterThanOrEqual(report.stages["event"]?.count ?? 0, 60)
        }
    }

    func testResizeReleaseCalculatesExactCommittedOutputAndPreservesPortFormulas() throws {
        try withEditor { document, editor in
            let baseline = document.diagram
            let node = baseline.page.nodes[0]
            let id = node.id
            let canvas = editor.canvas
            canvas.select([id])
            let corner = CGPoint(x: node.rect.maxX, y: node.rect.maxY)
            let target = CGPoint(x: corner.x + 40, y: corner.y + 20)
            let parser = ShapeSheetExpressionCache.shared.statistics
            let run = try XCTUnwrap(PerformanceEvidence.beginRun())
            canvas.mouseDown(with: try mouse(.leftMouseDown, at: corner, editor: editor))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: target, editor: editor))
            let report = try XCTUnwrap(PerformanceEvidence.endRun(run))
            XCTAssertEqual(ShapeSheetExpressionCache.shared.statistics, parser)
            assertNoSemanticWork(report)
            let expected = DiagramCalculation.recalculate(canvas.displayedDiagram, previous: baseline).diagram
            document.undoManager?.beginUndoGrouping()
            canvas.mouseUp(with: try mouse(.leftMouseUp, at: target, editor: editor))
            document.undoManager?.endUndoGrouping()
            XCTAssertEqual(document.diagram, expected)
            XCTAssertEqual(document.diagram.page.nodes[0].width, node.width + 40, accuracy: 1e-8)
            XCTAssertEqual(document.diagram.page.nodes[0].height, node.height + 20, accuracy: 1e-8)
            XCTAssertEqual(document.diagram.page.nodes[0].formatting.connectionPoints[0].x.formula, "Width/2")
            XCTAssertEqual(
                document.diagram.page.nodes[0].formatting.connectionPoints[0].y.formula, "Height/2")
            let persisted = try JSONDecoder().decode(
                Diagram.self, from: document.data(ofType: MacVisioDocument.nativeType))
            XCTAssertEqual(persisted, document.diagram)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, baseline)
        }
    }

    func testTwentyGroupedFormulaPortDragResizeCancelCyclesUsePreparedRoutes() throws {
        try withEditor { document, editor in
            var grouped = document.diagram
            var group = DiagramNode(x: 80, y: 80, text: "")
            group.width = 680
            group.height = 160
            group.formatting.isGroup = true
            for index in grouped.page.nodes.indices { grouped.page.nodes[index].parentID = group.id }
            for index in grouped.page.edges.indices { grouped.page.edges[index].parentID = group.id }
            grouped.page.nodes.insert(group, at: 0)
            document.diagram = DiagramCalculation.recalculate(grouped).diagram
            editor.refresh()
            document.undoManager?.removeAllActions()
            let baseline = document.diagram
            let revision = document.revision
            let stateID = document.stateID
            let sourceID = baseline.page.nodes[1].id
            let portID = baseline.page.nodes[1].formatting.connectionPoints[0].id
            let formulas = baseline.page.nodes[1].formatting.connectionPoints
            let parser = ShapeSheetExpressionCache.shared.statistics
            let run = try XCTUnwrap(PerformanceEvidence.beginRun())
            defer { _ = PerformanceEvidence.endRun(run) }
            for index in 0..<20 {
                editor.canvas.select([group.id])
                let start =
                    index.isMultiple(of: 2)
                    ? group.center : CGPoint(x: group.rect.maxX, y: group.rect.maxY)
                let finish = CGPoint(x: start.x + 35, y: start.y + 25)
                editor.canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, editor: editor))
                editor.canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: finish, editor: editor))
                let previewNode = try XCTUnwrap(editor.canvas.page.nodes.first { $0.id == sourceID })
                XCTAssertNotEqual(previewNode.rect, baseline.page.nodes[1].rect)
                XCTAssertEqual(previewNode.formatting.connectionPoints, formulas)
                let port = try XCTUnwrap(
                    editor.canvas.renderScene.foreground.connectionPoints[sourceID]?[portID])
                let route = try XCTUnwrap(
                    editor.canvas.renderScene.foreground.routes[baseline.page.edges[0].id])
                XCTAssertEqual(try XCTUnwrap(route.first).x, port.x, accuracy: 1e-8)
                XCTAssertEqual(try XCTUnwrap(route.first).y, port.y, accuracy: 1e-8)
                XCTAssertNotNil(editor.canvas.page.edges[0].points)
                editor.canvas.keyDown(with: try escape(editor))
                XCTAssertEqual(document.diagram, baseline)
                XCTAssertEqual(document.revision, revision)
                XCTAssertEqual(document.stateID, stateID)
            }
            let report = try XCTUnwrap(PerformanceEvidence.endRun(run))
            XCTAssertEqual(ShapeSheetExpressionCache.shared.statistics, parser)
            assertNoSemanticWork(report)
            XCTAssertGreaterThanOrEqual(report.stages["event"]?.count ?? 0, 60)
        }
    }

    func testPortMapsAreSparseAndRootAppendRetainsUnrelatedStraightRouteBounds() {
        let diagram = fixture()
        let retained = RetainedRenderPage(diagram.page)
        XCTAssertEqual(Set(retained.connectionPoints.keys), [diagram.page.nodes[0].id])
        let straightID = diagram.page.edges[1].id
        let straight = retained.routes[straightID]
        let bounds = retained.routeBounds[straightID]
        var page = diagram.page
        page.nodes.append(DiagramNode(x: 300, y: 300))
        retained.update(page)
        XCTAssertFalse(retained.runtime.lastUpdateWork.didRebuild)
        XCTAssertEqual(retained.routePreparations, 1)
        XCTAssertEqual(retained.routes[straightID], straight)
        XCTAssertEqual(retained.routeBounds[straightID], bounds)
        XCTAssertEqual(retained.runtime.edgeBoundsByID[straightID], bounds)
    }

    private func fixture() -> Diagram {
        var diagram = Diagram()
        var source = DiagramNode(x: 100, y: 100, text: "Formula port")
        let target = DiagramNode(x: 500, y: 100, text: "Target")
        source.formatting.connectionPoints = [
            ShapeConnectionPoint(
                index: 0, name: "Center",
                x: ShapeSheetCell(value: "0", formula: "Width/2"),
                y: ShapeSheetCell(value: "0", formula: "Height/2"))
        ]
        diagram.page.nodes = [source, target]
        diagram.page.edges = [
            DiagramEdge(
                source: source.id, target: target.id, sourcePort: source.formatting.connectionPoints[0].id),
            DiagramEdge(source: source.id, target: target.id, style: .straight),
        ]
        return diagram
    }

    private func assertNoSemanticWork(
        _ report: PerformanceEvidence.Report, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(report.workCounts["evaluatedCells"] ?? 0, 0, file: file, line: line)
        XCTAssertEqual(report.workCounts["visitedObjects"] ?? 0, 0, file: file, line: line)
        XCTAssertEqual(report.workCounts["transactionsCommitted"] ?? 0, 0, file: file, line: line)
        XCTAssertNil(report.stages["calculation"], file: file, line: line)
        XCTAssertEqual(report.unfinishedSpans, 0, file: file, line: line)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, editor: EditorWindowController) throws
        -> NSEvent
    {
        let canvas = editor.canvas
        let position = CGPoint(
            x: canvas.pageOrigin.x + point.x * canvas.coordinateZoom,
            y: canvas.pageOrigin.y + point.y * canvas.coordinateZoom)
        return try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: canvas.convert(position, to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: editor.window!.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func escape(_ editor: EditorWindowController) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: editor.window!.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }

    private func withEditor(_ body: (MacVisioDocument, EditorWindowController) throws -> Void)
        throws
    {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            document.diagram = DiagramCalculation.recalculate(fixture()).diagram
            var background = document.diagram.page
            background.id = UUID()
            background.isBackground = true
            document.diagram.pages.append(background)
            document.diagram.pages[0].backgroundPageID = background.id
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            editor.canvas.zoom = 1
            editor.canvas.snapsToGrid = false
            document.undoManager?.groupsByEvent = false
            document.undoManager?.removeAllActions()
            defer {
                editor.window?.orderOut(nil)
                editor.window?.delegate = nil
                document.removeWindowController(editor)
                editor.close()
            }
            try body(document, editor)
        }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
