import AppKit
import XCTest
@testable import MacVisio

final class EditorCommandSearchTests: XCTestCase {
    func testCatalogFiltersTitlesAndKeywordsAndExplainsSelectionAndLocks() throws {
        try withEditor { document, editor in
            let controller = editor.commandSearchController
            controller.searchField.stringValue = "arrange left"; controller.filterCommands()
            XCTAssertEqual(controller.commands.map(\.title), ["Align Left"])
            XCTAssertFalse(controller.runButton.isEnabled); XCTAssertTrue(controller.explanation.stringValue.contains("at least 2"))
            let passes = controller.availabilityEvaluations
            for _ in 0..<100 { controller.refreshEnabledState() }
            XCTAssertEqual(controller.availabilityEvaluations, passes)
            editor.canvas.select(Set(document.diagram.page.nodes.map(\.id))); controller.refreshEnabledState()
            XCTAssertTrue(controller.runButton.isEnabled); XCTAssertEqual(controller.availabilityEvaluations, passes + 1)
            var next = document.diagram; next.page.nodes[0].locked = true
            document.replaceInEditor(with: next, action: "Lock fixture"); controller.refreshEnabledState()
            XCTAssertFalse(controller.runButton.isEnabled); XCTAssertTrue(controller.explanation.stringValue.contains("Unlock"))
            controller.searchField.stringValue = "not-a-command"; controller.filterCommands()
            XCTAssertTrue(controller.commands.isEmpty); XCTAssertEqual(controller.explanation.stringValue, "No matching commands.")
        }
    }
    func testExecutionRevalidatesSelectionThenRoutesExistingCommandAndUndo() throws {
        try withEditor { document, editor in
            let controller = editor.commandSearchController
            editor.canvas.select(Set(document.diagram.page.nodes.map(\.id)))
            controller.searchField.stringValue = "Align Left"; controller.filterCommands()
            XCTAssertTrue(controller.runButton.isEnabled)
            editor.canvas.select([])
            XCTAssertFalse(controller.executeSelected()); XCTAssertTrue(controller.explanation.stringValue.contains("at least 2"))
            controller.searchField.stringValue = "Add Page"; controller.filterCommands()
            let original = document.diagram
            XCTAssertTrue(controller.executeSelected()); XCTAssertEqual(document.diagram.pages.count, original.pages.count + 1)
            XCTAssertEqual(document.undoManager?.undoActionName, "Add Page")
            document.undoManager?.undo(); XCTAssertEqual(document.diagram, original)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testTextCommandsExplainCurrentTextProtectionAndNewNativeHooksAreDiscoverable() throws {
        try withEditor { document, editor in
            let controller = editor.commandSearchController
            let id = document.diagram.page.nodes[0].id; editor.canvas.select([id])
            var next = document.diagram; next.page.nodes[0].formatting.sheet["LockTextEdit"] = ShapeSheetCell(value: "1")
            document.replaceInEditor(with: next, action: "Protection fixture")
            for query in ["Edit Text", "Insert Text Field"] {
                controller.searchField.stringValue = query; controller.filterCommands()
                XCTAssertFalse(controller.runButton.isEnabled)
                XCTAssertTrue(controller.explanation.stringValue.contains("protects text"))
                XCTAssertFalse(controller.executeSelected())
            }
            let commands = EditorSearchCommand.all
            for selector in [#selector(EditorWindowController.insertSubprocess(_:)), #selector(EditorWindowController.chooseOffPageTarget(_:)),
                             #selector(EditorWindowController.previewDrawingGrid(_:)), #selector(EditorWindowController.toggleShapeLibrary(_:)),
                             #selector(EditorWindowController.checkDrawingContent(_:)), #selector(EditorWindowController.exportRedactedSupportReport(_:))] {
                XCTAssertTrue(commands.contains { $0.action == selector })
            }
            let offPage = try XCTUnwrap(commands.first { $0.action == #selector(EditorWindowController.chooseOffPageTarget(_:)) })
            XCTAssertTrue(offPage.disabledReason(in: editor)?.contains("Add another page") == true)
            var unmapped = document.diagram
            unmapped.page.nodes[0].formatting.sheet.removeValue(forKey: "LockTextEdit")
            unmapped.page.nodes[0].formatting.textFields = [ShapeTextField(index: 7, cells: [:])]
            unmapped.page.nodes[0].formatting.textRuns = nil
            document.diagram = unmapped; editor.refresh()
            controller.searchField.stringValue = "Edit Text"; controller.filterCommands()
            XCTAssertFalse(controller.runButton.isEnabled)
            XCTAssertTrue(controller.explanation.stringValue.contains("no run mapping"))
            XCTAssertFalse(controller.executeSelected())
        }
    }
    func testPresentationCommandDoesNotDirtyDrawingOrCreateUndo() throws {
        try withEditor { document, editor in
            let controller = editor.commandSearchController
            controller.searchField.stringValue = "Hide Grid"; controller.filterCommands()
            let original = document.diagram, revision = document.revision, grid = editor.canvas.showsGrid
            XCTAssertTrue(controller.executeSelected()); XCTAssertEqual(editor.canvas.showsGrid, !grid)
            XCTAssertEqual(document.diagram, original); XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testLaterInlineEditCommitsBeforeExistingCommandAndItsUndoRemainsSeparate() throws {
        try withEditor { document, editor in
            let controller = editor.commandSearchController
            controller.searchField.stringValue = "Add Page"; controller.filterCommands()
            let firstPage = document.diagram.page.id, node = document.diagram.page.nodes[0].id
            editor.canvas.beginEditing(node)
            let inline = try XCTUnwrap(editor.canvas.subviews.compactMap { $0 as? NSTextView }.first)
            inline.string = "Typed before running command"
            XCTAssertTrue(controller.executeSelected())
            XCTAssertFalse(editor.canvas.isEditingText); XCTAssertEqual(document.diagram.pages.count, 2)
            XCTAssertEqual(document.diagram.pages[0].nodes[0].text, "Typed before running command")
            XCTAssertEqual(document.undoManager?.undoActionName, "Add Page")
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.pages.count, 1); XCTAssertEqual(document.diagram.activePageID, firstPage)
            XCTAssertEqual(document.diagram.page.nodes[0].text, "Typed before running command")
        }
    }

    func testChangedQueryCannotExecuteAnOlderDisplayedCommand() throws {
        try withEditor { document, editor in
            let controller = editor.commandSearchController
            controller.searchField.stringValue = "Add Page"; controller.filterCommands()
            XCTAssertEqual(controller.selectedCommand?.title, "Add Page")
            controller.searchField.stringValue = "Fit Page"
            let original = document.diagram
            XCTAssertFalse(controller.executeSelected()); XCTAssertEqual(document.diagram, original)
            XCTAssertEqual(controller.selectedCommand?.title, "Fit Page")
            XCTAssertTrue(controller.explanation.stringValue.contains("Review"))
        }
    }
    func testNativeCommandFieldEditorRetainsTypingAndMarkedTextCannotExecute() throws {
        try withEditor { document, editor in
            let controller = editor.commandSearchController; controller.showWindow(nil)
            XCTAssertTrue(controller.window!.makeFirstResponder(controller.searchField))
            let field = try XCTUnwrap(controller.searchField.currentEditor() as? NSTextView)
            let original = document.diagram, tool = editor.canvas.tool
            field.insertText("rct", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(document.diagram, original); XCTAssertEqual(editor.canvas.tool, tool)
            controller.searchField.stringValue = "Add Page"; controller.filterCommands()
            field.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(field.hasMarkedText()); XCTAssertFalse(controller.executeSelected())
            XCTAssertEqual(document.diagram, original)
            field.unmarkText(); controller.close()
        }
    }
    func testPanelOwnershipIsPerEditorAndClosedOwnerCannotExecute() throws {
        try withEditor { document, editor in
            let controller = editor.commandSearchController
            XCTAssertTrue(controller === editor.commandSearchController)
            let otherDocument = MacVisioDocument(); otherDocument.makeWindowControllers()
            let other = try XCTUnwrap(otherDocument.windowControllers.first as? EditorWindowController)
            defer { otherDocument.removeWindowController(other); other.close() }
            XCTAssertFalse(controller === other.commandSearchController)
            controller.searchField.stringValue = "Add Page"; controller.filterCommands()
            let count = document.diagram.pages.count, otherCount = otherDocument.diagram.pages.count
            editor.close(); XCTAssertFalse(controller.executeSelected())
            XCTAssertEqual(document.diagram.pages.count, count); XCTAssertEqual(otherDocument.diagram.pages.count, otherCount)
        }
    }
    private func withEditor(_ body: @escaping (MacVisioDocument, EditorWindowController) throws -> Void) throws {
        let work = {
            _ = NSApplication.shared
            let document = MacVisioDocument(); document.diagram.page.nodes = [DiagramNode(x: 100, text: "First"), DiagramNode(x: 400, text: "Second")]
            document.makeWindowControllers(); let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            document.undoManager?.groupsByEvent = false; document.undoManager?.removeAllActions()
            defer {
                editor.commandSearchController.close(); editor.window?.orderOut(nil); editor.window?.delegate = nil
                document.removeWindowController(editor); editor.close()
            }
            try body(document, editor)
        }
        if Thread.isMainThread { try work() } else { try DispatchQueue.main.sync(execute: work) }
    }
}
