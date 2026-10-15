import AppKit
import XCTest
@testable import MacVisio

final class InspectorCommitTests: XCTestCase {
    func testUntouchedPageInspectorFieldsDoNotCommitRoundedValues() throws {
        try withEditor(diagramWithFractionalGeometry()) { document, editor in
            let original = document.diagram
            document.undoManager?.removeAllActions()

            for identifier in ["inspector_Page name", "inspector_Page width", "inspector_Page height"] {
                try sendAction(from: field(identifier, in: editor.root.inspector))
                XCTAssertEqual(document.diagram, original, "Untouched \(identifier) field changed the diagram")
                XCTAssertFalse(document.isDocumentEdited, "Untouched \(identifier) field marked the document edited")
            }
            XCTAssertFalse(document.undoManager?.canUndo ?? false)
        }
    }

    func testUntouchedNodeInspectorFieldsDoNotCommitRoundedValues() throws {
        try withEditor(diagramWithFractionalGeometry()) { document, editor in
            let node = try XCTUnwrap(document.diagram.page.nodes.first)
            editor.canvas.select([node.id])
            document.undoManager?.removeAllActions()
            let original = document.diagram
            let identifiers = [
                "inspector_Text", "inspector_Font size", "inspector_Font", "inspector_Line width",
                "inspector_X", "inspector_Y", "inspector_Width", "inspector_Height", "inspector_Rotation"
            ]

            for identifier in identifiers {
                try sendAction(from: field(identifier, in: editor.root.inspector))
                XCTAssertEqual(document.diagram, original, "Untouched \(identifier) field changed the diagram")
                XCTAssertFalse(document.isDocumentEdited, "Untouched \(identifier) field marked the document edited")
            }
            XCTAssertFalse(document.undoManager?.canUndo ?? false)
        }
    }

    func testChangedInspectorFieldCommitsAndUndoRestoresDiagram() throws {
        try withEditor(diagramWithFractionalGeometry()) { document, editor in
            let node = try XCTUnwrap(document.diagram.page.nodes.first)
            editor.canvas.select([node.id])
            document.undoManager?.removeAllActions()
            let original = document.diagram
            let text = try field("inspector_Text", in: editor.root.inspector)
            text.stringValue = "Changed by inspector"

            document.undoManager?.beginUndoGrouping()
            try sendAction(from: text)
            document.undoManager?.endUndoGrouping()

            XCTAssertEqual(document.diagram.page.nodes.first?.text, "Changed by inspector")
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertTrue(document.undoManager?.canUndo ?? false)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, original)
        }
    }

    private func diagramWithFractionalGeometry() -> Diagram {
        var diagram = Diagram()
        diagram.title = "Inspector commit test"
        diagram.page.width = 1000.75
        diagram.page.height = 700.25
        var node = DiagramNode(x: 123.49, y: 240.51, text: "Original")
        node.width = 111.4
        node.height = 80.7
        node.fontSize = 12.8
        node.strokeWidth = 1.46
        node.rotation = 0.49
        diagram.page.nodes = [node]
        return diagram
    }

    private func field(_ identifier: String, in view: NSView, file: StaticString = #filePath, line: UInt = #line) throws -> NSTextField {
        let key = identifier.replacingOccurrences(of: "inspector_", with: "")
        return try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == key }, file: file, line: line)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func sendAction(from control: NSControl, file: StaticString = #filePath, line: UInt = #line) throws {
        let action = try XCTUnwrap(control.action, file: file, line: line)
        XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control), file: file, line: line)
    }

    private func withEditor(_ diagram: Diagram, _ body: (MacVisioDocument, EditorWindowController) throws -> Void) throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            document.diagram = diagram
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
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
