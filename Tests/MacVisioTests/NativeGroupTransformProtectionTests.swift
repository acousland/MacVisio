import AppKit
import XCTest

@testable import MacVisio

final class NativeGroupTransformProtectionTests: XCTestCase {
    func testProtectedDescendantRejectsEntireParentTransformWithoutUndoOrDirtyChange() throws {
        try onMain {
            _ = NSApplication.shared
            for protection in ["locked", "LockMoveX", "guardedWidth"] {
                var model = fixture()
                switch protection {
                case "locked": model.page.nodes[1].locked = true
                case "LockMoveX":
                    model.page.nodes[1].formatting.sheet["LockMoveX"] = ShapeSheetCell(value: "1")
                default:
                    model.page.nodes[1].formatting.sheet["Width"] = ShapeSheetCell(
                        value: "0.8", formula: "GUARD(0.8)")
                }
                let document = MacVisioDocument()
                defer { document.close() }
                document.diagram = model
                document.makeWindowControllers()
                let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
                editor.canvas.select([model.page.nodes[0].id])
                let state = document.stateID
                editor.modifySelection("Transform group") { node in
                    if protection == "guardedWidth" { node.width += 60 } else { node.x += 20 }
                }
                XCTAssertEqual(document.diagram, model, protection)
                XCTAssertEqual(document.stateID, state)
                XCTAssertFalse(document.undoManager?.canUndo ?? true)
                XCTAssertFalse(document.isDocumentEdited)
                XCTAssertTrue(editor.root.status.stringValue.contains("group member"))
            }
        }
    }

    func testLockedGroupConnectorRejectsWholeTransform() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture()
            model.page.layers = [DiagramLayer(name: "Restricted", locked: true)]
            model.page.edges[0].layer = "Restricted"
            let document = MacVisioDocument()
            defer { document.close() }
            document.diagram = model
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            editor.canvas.select([model.page.nodes[0].id])
            let state = document.stateID
            editor.modifySelection("Move group") { $0.x += 30 }
            XCTAssertEqual(document.diagram, model)
            XCTAssertEqual(document.stateID, state)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
            XCTAssertTrue(editor.root.status.stringValue.contains("connector"))
        }
    }

    func testUnlockedGroupAndConnectorTransformAsOneUndoableEditAndLockToggleStillWorks() throws {
        try onMain {
            _ = NSApplication.shared
            let model = fixture()
            let document = MacVisioDocument()
            defer { document.close() }
            document.diagram = model
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            editor.canvas.select([model.page.nodes[0].id])
            let state = document.stateID
            editor.modifySelection("Move group") { $0.x += 20 }
            XCTAssertEqual(document.diagram.page.nodes[1].x, model.page.nodes[1].x + 20)
            XCTAssertNotEqual(document.diagram.page.edges[0].points, model.page.edges[0].points)
            XCTAssertNotEqual(document.stateID, state)
            XCTAssertTrue(document.undoManager?.canUndo ?? false)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, model)
            XCTAssertEqual(document.stateID, state)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
            editor.canvas.select([model.page.nodes[0].id])
            editor.toggleLock(nil)
            XCTAssertTrue(document.diagram.page.nodes[0].locked)
            XCTAssertEqual(document.diagram.page.nodes[1].x, model.page.nodes[1].x)
        }
    }

    private func fixture() -> Diagram {
        var group = DiagramNode(x: 100, y: 100)
        group.width = 300
        group.height = 200
        group.formatting.isGroup = true
        var first = DiagramNode(x: 140, y: 140)
        first.width = 60
        first.height = 40
        first.parentID = group.id
        var second = DiagramNode(x: 260, y: 180)
        second.width = 60
        second.height = 40
        second.parentID = group.id
        var edge = DiagramEdge(source: first.id, target: second.id)
        edge.parentID = group.id
        var model = Diagram()
        model.page.nodes = [group, first, second]
        model.page.edges = [edge]
        return model
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
