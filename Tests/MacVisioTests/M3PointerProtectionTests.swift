import AppKit
import XCTest
@testable import MacVisio

final class M3PointerProtectionTests: XCTestCase {
    func testHorizontalProtectionRefusesDragButAllowsPureVerticalMovementAndUndo() throws {
        var model = single()
        model.page.nodes[0].formatting.sheet["LockMoveX"] = ShapeSheetCell(value: "1")
        model.page.nodes[0].formatting.sheet["LockMoveY"] = ShapeSheetCell(value: "0")
        try withEditor(model) { document, editor in
            let before = document.diagram, state = document.stateID, revision = document.revision
            let node = before.page.nodes[0]
            editor.canvas.select([node.id])
            try drag(from: node.center, to: CGPoint(x: node.center.x + 35, y: node.center.y), editor: editor)
            assertRefused(document, editor: editor, before: before, state: state, revision: revision, reason: "LockMoveX")
            try drag(from: node.center, to: CGPoint(x: node.center.x, y: node.center.y + 25), editor: editor)
            XCTAssertEqual(document.diagram.page.nodes[0].x, node.x, accuracy: 1e-8)
            XCTAssertEqual(document.diagram.page.nodes[0].y, node.y + 25, accuracy: 1e-8)
            XCTAssertEqual(document.diagram.page.nodes[0].formatting.sheet["LockMoveX"], node.formatting.sheet["LockMoveX"])
            XCTAssertTrue(document.undoManager?.canUndo ?? false)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state)
            XCTAssertFalse(document.isDocumentEdited)
        }
    }

    func testNativeResizeRefusesWidthAspectAndGuardedFormulaChanges() throws {
        for protection in ["LockWidth", "LockAspect", "guarded Width"] {
            var model = single()
            if protection == "guarded Width" {
                model.page.nodes[0].formatting.sheet["Width"] = ShapeSheetCell(value: "2.2222222222222223", formula: "GUARD(2.2222222222222223 in)", unit: "IN")
            } else { model.page.nodes[0].formatting.sheet[protection] = ShapeSheetCell(value: "1") }
            try withEditor(model) { document, editor in
                let before = document.diagram, state = document.stateID, revision = document.revision, node = before.page.nodes[0]
                editor.canvas.select([node.id])
                let right = CGPoint(x: node.rect.maxX, y: node.rect.midY)
                try drag(from: right, to: CGPoint(x: right.x + 40, y: right.y), editor: editor)
                assertRefused(document, editor: editor, before: before, state: state, revision: revision,
                              reason: protection == "guarded Width" ? "guarded" : protection)
            }
        }
    }

    func testProtectedGroupDescendantRefusesEntireNativeMoveOrResize() throws {
        for protection in ["locked", "LockMoveX", "guarded Width"] {
            var model = grouped()
            switch protection {
            case "locked": model.page.nodes[1].locked = true
            case "LockMoveX": model.page.nodes[1].formatting.sheet["LockMoveX"] = ShapeSheetCell(value: "1")
            default: model.page.nodes[1].formatting.sheet["Width"] = ShapeSheetCell(value: "0.8333333333333334", formula: "GUARD(0.8333333333333334 in)", unit: "IN")
            }
            try withEditor(model) { document, editor in
                let before = document.diagram, state = document.stateID, revision = document.revision, group = before.page.nodes[0]
                editor.canvas.select([group.id])
                let resize = protection == "guarded Width"
                let start = resize ? CGPoint(x: group.rect.maxX, y: group.rect.maxY) : group.center
                try drag(from: start, to: CGPoint(x: start.x + 40, y: start.y + (resize ? 20 : 0)), editor: editor)
                assertRefused(document, editor: editor, before: before, state: state, revision: revision, reason: "group member")
            }
        }
    }

    func testSecondaryLockedLayerOnGroupConnectorRefusesNativeTransform() throws {
        var model = grouped()
        model.page.layers = [DiagramLayer(name: "Visible"), DiagramLayer(name: "Restricted", locked: true)]
        model.page.edges[0].layer = "Visible"
        model.page.edges[0].formatting.layerNames = ["Visible", "Restricted"]
        try withEditor(model) { document, editor in
            let before = document.diagram, state = document.stateID, revision = document.revision, group = before.page.nodes[0]
            editor.canvas.select([group.id])
            try drag(from: group.center, to: CGPoint(x: group.center.x + 30, y: group.center.y), editor: editor)
            assertRefused(document, editor: editor, before: before, state: state, revision: revision, reason: "connector")
        }
    }

    func testMultiSelectionRefusalDoesNotPartiallyMoveUnprotectedShape() throws {
        var model = single(), other = DiagramNode(x: 400, y: 100)
        other.text = "Unprotected"
        model.page.nodes[0].formatting.sheet["LockMoveX"] = ShapeSheetCell(value: "1")
        model.page.nodes.append(other)
        try withEditor(model) { document, editor in
            let before = document.diagram, state = document.stateID, revision = document.revision
            editor.canvas.select(Set(before.page.nodes.map(\.id)))
            try drag(from: other.center, to: CGPoint(x: other.center.x + 35, y: other.center.y), editor: editor)
            assertRefused(document, editor: editor, before: before, state: state, revision: revision, reason: "LockMoveX")
        }
    }

    func testAllowedGroupVerticalDragKeepsHorizontalProtectionAndIsOneUndo() throws {
        var model = grouped()
        model.page.nodes[1].formatting.sheet["LockMoveX"] = ShapeSheetCell(value: "1")
        try withEditor(model) { document, editor in
            let before = document.diagram, state = document.stateID, group = before.page.nodes[0]
            editor.canvas.select([group.id])
            try drag(from: group.center, to: CGPoint(x: group.center.x, y: group.center.y + 24), editor: editor)
            for (old, new) in zip(before.page.nodes, document.diagram.page.nodes) {
                XCTAssertEqual(new.x, old.x, accuracy: 1e-8); XCTAssertEqual(new.y, old.y + 24, accuracy: 1e-8)
            }
            XCTAssertNotEqual(document.diagram.page.edges[0].points, before.page.edges[0].points)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testEscapeCancelsProtectedResizeWithoutCalculationOrFormulaChanges() throws {
        var model = single()
        model.page.nodes[0].formatting.sheet["Width"] = ShapeSheetCell(value: "2.2222222222222223", formula: "GUARD(2.2222222222222223 in)", unit: "IN")
        try withEditor(model) { document, editor in
            let before = document.diagram, state = document.stateID, revision = document.revision, node = before.page.nodes[0]
            editor.canvas.select([node.id])
            let parser = ShapeSheetExpressionCache.shared.statistics
            let start = CGPoint(x: node.rect.maxX, y: node.rect.maxY), end = CGPoint(x: node.rect.maxX + 40, y: node.rect.maxY + 20)
            editor.canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, editor: editor))
            editor.canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: end, editor: editor))
            XCTAssertNotEqual(editor.canvas.displayedDiagram, before)
            editor.canvas.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: editor.window!.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
            editor.canvas.mouseUp(with: try mouse(.leftMouseUp, at: end, editor: editor))
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(editor.canvas.displayedDiagram, before)
            XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertEqual(ShapeSheetExpressionCache.shared.statistics, parser)
            XCTAssertFalse(document.undoManager?.canUndo ?? true); XCTAssertFalse(document.isDocumentEdited)
        }
    }

    func testPageInteractionFinalizationCannotCommitProtectedPointerPreview() throws {
        var model = single(); model.page.nodes[0].formatting.sheet["LockMoveX"] = ShapeSheetCell(value: "1")
        try withEditor(model) { document, editor in
            let before = document.diagram, state = document.stateID, revision = document.revision, node = before.page.nodes[0]
            editor.canvas.select([node.id])
            editor.canvas.mouseDown(with: try mouse(.leftMouseDown, at: node.center, editor: editor))
            editor.canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: node.center.x + 30, y: node.center.y), editor: editor))
            editor.canvas.finishPageInteraction()
            assertRefused(document, editor: editor, before: before, state: state, revision: revision, reason: "LockMoveX")
        }
    }

    func testRefusalPreservesExistingDirtyStateAndUndoHistory() throws {
        var model = single(); model.page.nodes[0].formatting.sheet["LockWidth"] = ShapeSheetCell(value: "1")
        try withEditor(model) { document, editor in
            var styled = document.diagram; styled.page.nodes[0].fill = "#CC3300"
            document.replace(with: styled, action: "Earlier style")
            let before = document.diagram, state = document.stateID, revision = document.revision, node = before.page.nodes[0]
            let action = document.undoManager?.undoActionName
            XCTAssertTrue(document.isDocumentEdited)
            editor.canvas.select([node.id])
            let start = CGPoint(x: node.rect.maxX, y: node.rect.midY)
            try drag(from: start, to: CGPoint(x: start.x + 40, y: start.y), editor: editor)
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertEqual(document.undoManager?.undoActionName, action); XCTAssertTrue(document.isDocumentEdited)
            XCTAssertTrue(editor.root.status.stringValue.contains("LockWidth"))
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, model)
        }
    }

    private func assertRefused(_ document: MacVisioDocument, editor: EditorWindowController, before: Diagram, state: UUID, revision: UInt64,
                               reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(document.diagram, before, file: file, line: line)
        XCTAssertEqual(editor.canvas.displayedDiagram, before, file: file, line: line)
        XCTAssertEqual(document.stateID, state, file: file, line: line); XCTAssertEqual(document.revision, revision, file: file, line: line)
        XCTAssertFalse(document.undoManager?.canUndo ?? true, file: file, line: line)
        XCTAssertFalse(document.isDocumentEdited, file: file, line: line)
        XCTAssertTrue(editor.root.status.stringValue.contains(reason), editor.root.status.stringValue, file: file, line: line)
    }
    private func drag(from start: CGPoint, to end: CGPoint, editor: EditorWindowController) throws {
        // The production document owns a group only when it commits an edit.
        // Wrapping refused events here creates an empty AppKit undo action.
        XCTAssertEqual(editor.diagramDocument.undoManager?.groupingLevel, 0)
        editor.canvas.mouseDown(with: try mouse(.leftMouseDown, at: start, editor: editor))
        editor.canvas.mouseDragged(with: try mouse(.leftMouseDragged, at: end, editor: editor))
        editor.canvas.mouseUp(with: try mouse(.leftMouseUp, at: end, editor: editor))
        XCTAssertEqual(editor.diagramDocument.undoManager?.groupingLevel, 0)
    }
    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, editor: EditorWindowController) throws -> NSEvent {
        let canvas = editor.canvas
        let local = CGPoint(x: canvas.pageOrigin.x + point.x * canvas.coordinateZoom, y: canvas.pageOrigin.y + point.y * canvas.coordinateZoom)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(local, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    private func single() -> Diagram {
        var diagram = Diagram(); diagram.page.nodes = [DiagramNode(x: 100, y: 100)]
        return diagram
    }
    private func grouped() -> Diagram {
        var group = DiagramNode(x: 100, y: 100); group.width = 300; group.height = 200; group.formatting.isGroup = true
        var first = DiagramNode(x: 140, y: 140); first.width = 60; first.height = 40; first.parentID = group.id
        var second = DiagramNode(x: 260, y: 180); second.width = 60; second.height = 40; second.parentID = group.id
        var edge = DiagramEdge(source: first.id, target: second.id); edge.parentID = group.id
        var diagram = Diagram(); diagram.page.nodes = [group, first, second]; diagram.page.edges = [edge]
        return diagram
    }
    private func withEditor(_ model: Diagram, _ body: (MacVisioDocument, EditorWindowController) throws -> Void) throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); document.diagram = model; document.undoManager?.groupsByEvent = false
            defer { document.close() }
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            editor.canvas.snapsToGrid = false
            try body(document, editor)
        }
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
