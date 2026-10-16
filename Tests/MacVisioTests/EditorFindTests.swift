import AppKit
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class EditorFindTests: XCTestCase {
    func testCrossPageFindUsesPresentationActivationAndLogicalUTF16Preview() throws {
        try withEditor { document, editor in
            let controller = editor.documentFindController
            let revision = document.revision, identity = document.stateID
            controller.queryField.stringValue = "needle"; controller.domainPicker.selectItem(at: 1)
            controller.performSearch(); try self.waitForSearch(controller)
            XCTAssertEqual(controller.results.count, 2)
            let match = controller.results[1]
            controller.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            XCTAssertEqual(document.diagram.activePageID, match.pageID)
            XCTAssertEqual(editor.canvas.selectedNodes, [match.objectID])
            XCTAssertEqual(controller.preview.selectedRange(), NSRange(location: 3, length: 6))
            XCTAssertEqual(controller.preview.string, "🙂 needle العربية e\u{301}")
            XCTAssertEqual(document.revision, revision); XCTAssertEqual(document.stateID, identity)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
            controller.previousResult(nil)
            XCTAssertEqual(document.diagram.activePageID, document.diagram.pages[0].id)
            XCTAssertEqual(document.revision, revision)
        }
    }

    func testAsyncFindTruncationAndQueryReplacementAreExplicit() throws {
        try withEditor { document, editor in
            let controller = editor.documentFindController
            var next = document.diagram; next.pages[0].nodes[0].text = String(repeating: "needle ", count: 20)
            document.replaceInEditor(with: next, action: "Fixture")
            controller.queryField.stringValue = "needle"; controller.resultBudget = 3
            controller.performSearch(); try self.waitForSearch(controller)
            XCTAssertEqual(controller.results.count, 3); XCTAssertTrue(controller.results.isTruncated)
            XCTAssertTrue(controller.summary.stringValue.contains("More results exist"))
            controller.resultBudget = 0; controller.performSearch(); try self.waitForSearch(controller)
            XCTAssertEqual(controller.results.completion, .invalidBudget)
            XCTAssertTrue(controller.summary.stringValue.contains("1 and 100,000"))
            controller.resultBudget = 10_000; controller.queryField.stringValue = "needle"; controller.performSearch()
            controller.queryField.stringValue = "not-present"; controller.performSearch(); try self.waitForSearch(controller)
            XCTAssertTrue(controller.results.isEmpty); XCTAssertEqual(controller.results.completion, .complete)
        }
    }

    func testSelectedReplacementKeepsRequestedStylesFieldsAndOneUndoRedo() throws {
        try withEditor { document, editor in
            var node = document.diagram.pages[0].nodes[0]
            node.text = "same same END"
            var first = ShapeCharacterStyle(node: node); first.fontName = "Requested First"; first.sourceIndex = 3
            var second = first; second.fontName = "Missing Requested Second"; second.sourceIndex = 8; second.bold = true
            second.cells["OpaqueFont"] = ShapeSheetCell(value: "requested", formula: "THEMEVAL(17)")
            let paragraph = ShapeParagraphStyle(alignment: .right)
            let a = ShapeTextRun(text: "same ", character: first, paragraph: paragraph)
            let b = ShapeTextRun(text: "same ", character: second, paragraph: paragraph)
            let field = ShapeTextRun(text: "END", character: first, paragraph: paragraph, fieldIndex: 4, fieldToken: UUID())
            node.formatting.textRuns = [a, b, field]
            node.formatting.textFields = [ShapeTextField(index: 4, cells: ["Value": ShapeSheetCell(value: "END", formula: "\"END\"")], cached: "END")]
            var setup = document.diagram; setup.pages[0].nodes[0] = node
            document.replaceInEditor(with: setup, action: "Fixture")
            document.undoManager?.removeAllActions()
            let original = document.diagram
            let controller = editor.documentFindController
            controller.queryField.stringValue = "same"; controller.performSearch(); try self.waitForSearch(controller)
            controller.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            controller.replacementField.stringValue = "🙂 العربية e\u{301}"
            XCTAssertNil(controller.replacementReason); XCTAssertTrue(controller.applyReplacement())
            try self.waitForSearch(controller)
            let output = try XCTUnwrap(document.diagram.pages[0].nodes[0].formatting.textRuns)
            XCTAssertEqual(output.first, a); XCTAssertEqual(output.last, field)
            XCTAssertEqual(output[1].character, second); XCTAssertEqual(output[1].paragraph, paragraph)
            XCTAssertEqual(document.undoManager?.undoActionName, "Replace Text")
            let changed = document.diagram
            document.undoManager?.undo(); XCTAssertEqual(document.diagram, original)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
            document.undoManager?.redo(); XCTAssertEqual(document.diagram, changed)
        }
    }

    func testStaleResultsAndCurrentProtectionsPreventReplacement() throws {
        try withEditor { document, editor in
            let controller = editor.documentFindController
            controller.queryField.stringValue = "needle"; controller.performSearch(); try self.waitForSearch(controller)
            var next = document.diagram; next.pages[0].nodes[0].text = "changed"
            document.replaceInEditor(with: next, action: "Other edit")
            let before = document.diagram, revision = document.revision
            controller.replacementField.stringValue = "replacement"
            XCTAssertTrue(controller.replacementReason?.contains("drawing changed") == true)
            XCTAssertFalse(controller.applyReplacement()); XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.revision, revision)
            next = document.diagram; next.pages[1].nodes[0].formatting.sheet["LockTextEdit"] = ShapeSheetCell(value: "1")
            document.replaceInEditor(with: next, action: "Protect text")
            controller.performSearch(); try self.waitForSearch(controller)
            XCTAssertTrue(controller.replacementReason?.contains("protects text") == true)
            XCTAssertFalse(controller.applyReplacement())
        }
    }

    func testLargeDrawingReplacementUsesAcceptedAsyncCommitAndSingleUndo() throws {
        try withEditor { document, editor in
            var fixture = document.diagram
            fixture.pages[0].nodes.append(contentsOf: (1..<2000).map { DiagramNode(x: Double($0 % 20) * 40, y: Double($0 / 20) * 10, text: "Other \($0)") })
            document.diagram = fixture; editor.refresh(); document.undoManager?.removeAllActions()
            let original = document.diagram, identity = document.stateID
            let controller = editor.documentFindController
            controller.queryField.stringValue = "needle"; controller.domainPicker.selectItem(at: 1)
            controller.performSearch(); try self.waitForSearch(controller)
            controller.replacementField.stringValue = "replacement"
            XCTAssertTrue(controller.applyReplacement()); XCTAssertTrue(document.isCalculating)
            XCTAssertEqual(document.diagram, original); XCTAssertEqual(document.stateID, identity)
            XCTAssertFalse(controller.replaceButton.isEnabled)
            let deadline = Date().addingTimeInterval(10)
            while document.isCalculating && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
            XCTAssertFalse(document.isCalculating); XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(document.diagram.pages[0].nodes[0].text, "first replacement")
            XCTAssertEqual(document.undoManager?.undoActionName, "Replace Text")
            let changed = document.diagram
            document.undoManager?.undo(); XCTAssertEqual(document.diagram, original); XCTAssertEqual(document.stateID, identity)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
            document.undoManager?.redo(); XCTAssertEqual(document.diagram, changed)
        }
    }

    func testSearchRejectsChangedSnapshotAndCancelChecksBeforeWork() throws {
        try withEditor { document, editor in
            let controller = editor.documentFindController
            controller.queryField.stringValue = "needle"; controller.performSearch()
            var next = document.diagram; next.pages[0].nodes[0].text = "revision changed"
            document.replaceInEditor(with: next, action: "During search")
            try self.waitForSearch(controller)
            XCTAssertTrue(controller.results.isEmpty); XCTAssertTrue(controller.summary.stringValue.contains("changed while searching"))
            let cancelled = LifecycleJobCancellation(); cancelled.cancel()
            XCTAssertThrowsError(try EditorFindController.search(.init(text: "needle"), snapshot: document.diagram, cancellation: cancelled)) {
                XCTAssertEqual($0 as? LifecycleJobError, .cancelled)
            }
        }
    }

    func testIdleEligibilityRefreshDoesNoRepeatedValidationAndExecutionRejectsNewStateDirectly() throws {
        try withEditor { document, editor in
            let controller = editor.documentFindController
            controller.queryField.stringValue = "needle"; controller.performSearch(); try self.waitForSearch(controller)
            controller.refreshEligibility(); let passes = controller.eligibilityEvaluations
            for _ in 0..<100 { controller.refreshEligibility() }
            XCTAssertEqual(controller.eligibilityEvaluations, passes)
            XCTAssertTrue(controller.replaceButton.isEnabled)
            var next = document.diagram; next.pages[0].nodes[0].formatting.sheet["LockTextEdit"] = ShapeSheetCell(value: "1")
            document.replaceInEditor(with: next, action: "Protection changes between timer ticks")
            let current = document.diagram, revision = document.revision
            controller.replacementField.stringValue = "unsafe"
            XCTAssertFalse(controller.applyReplacement())
            XCTAssertEqual(document.diagram, current); XCTAssertEqual(document.revision, revision)
            controller.refreshEligibility(); XCTAssertEqual(controller.eligibilityEvaluations, passes + 1)
            XCTAssertFalse(controller.replaceButton.isEnabled)
            controller.performSearch(); try self.waitForSearch(controller)
            XCTAssertTrue(controller.replacementReason?.contains("protects text") == true)
        }
    }

    func testLaterInlineEditIsFinishedBeforeNavigationChecksSnapshot() throws {
        try withEditor { document, editor in
            let controller = editor.documentFindController
            controller.queryField.stringValue = "needle"; controller.performSearch(); try self.waitForSearch(controller)
            let target = controller.results[1], firstPage = document.diagram.activePageID
            let firstNode = document.diagram.page.nodes[0].id
            editor.canvas.beginEditing(firstNode)
            let inline = try XCTUnwrap(editor.canvas.subviews.compactMap { $0 as? NSTextView }.first)
            inline.string = "Typed after the search"
            XCTAssertTrue(editor.canvas.isEditingText)
            XCTAssertFalse(controller.navigate(to: target))
            XCTAssertFalse(editor.canvas.isEditingText)
            XCTAssertEqual(document.diagram.pages[0].nodes[0].text, "Typed after the search")
            XCTAssertEqual(document.diagram.activePageID, firstPage)
            XCTAssertTrue(controller.replacementReason?.contains("drawing changed") == true)
        }
    }

    func testBackgroundCompletionHighlightsPreviewWithoutFinalizingLateInput() throws {
        try withEditor { document, editor in
            let controller = editor.documentFindController
            let original = document.diagram, identity = document.stateID
            controller.queryField.stringValue = "needle"; controller.performSearch()
            editor.canvas.beginEditing(original.page.nodes[0].id)
            let inline = try XCTUnwrap(editor.canvas.subviews.compactMap { $0 as? NSTextView }.first)
            inline.string = "Still typing while search completes"
            try self.waitForSearch(controller)
            XCTAssertEqual(controller.results.count, 2); XCTAssertEqual(controller.table.selectedRow, 0)
            XCTAssertEqual(controller.preview.selectedRange(), controller.results[0].range)
            XCTAssertTrue(editor.canvas.isEditingText); XCTAssertEqual(inline.string, "Still typing while search completes")
            XCTAssertEqual(document.diagram, original); XCTAssertEqual(document.stateID, identity)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
            editor.canvas.finishEditing(commit: false)
            controller.revealSelectedResult(nil)
            XCTAssertEqual(editor.canvas.selectedNodes, [original.page.nodes[0].id])
        }
    }

    func testShapeAndDataNavigationOnlyAndHiddenLayerIsExplained() throws {
        try withEditor { document, editor in
            var next = document.diagram
            next.pages[0].nodes[0].formatting.data = [ShapeDataProperty(key: "owner", label: "Owner", value: "A person")]
            next.pages[0].layers = [DiagramLayer(name: "Default", visible: false)]
            document.replaceInEditor(with: next, action: "Fixture")
            let controller = editor.documentFindController
            controller.queryField.stringValue = "person"; controller.domainPicker.selectItem(at: 3)
            controller.performSearch(); try self.waitForSearch(controller)
            XCTAssertEqual(controller.results.count, 1)
            XCTAssertEqual(controller.results.first?.surface, .dataValue(index: 0, key: "owner"))
            XCTAssertTrue(controller.replacementReason?.contains("navigation only") == true)
            XCTAssertFalse(controller.applyReplacement())
            controller.revealSelectedResult(nil)
            XCTAssertTrue(controller.summary.stringValue.contains("hidden layer"))
            XCTAssertFalse(document.diagram.pages[0].layers![0].visible)
        }
    }

    func testFindPanelFieldEditorTypingDoesNotInvokeCanvasToolsAndCloseCancelsJobs() throws {
        try withEditor { document, editor in
            let controller = editor.documentFindController
            controller.showWindow(nil)
            XCTAssertTrue(controller.window!.makeFirstResponder(controller.queryField))
            let fieldEditor = try XCTUnwrap(controller.queryField.currentEditor() as? NSTextView)
            let before = document.diagram, tool = editor.canvas.tool
            fieldEditor.insertText("rct", replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(editor.canvas.tool, tool)
            controller.queryField.stringValue = "needle"; controller.performSearch()
            editor.close()
            XCTAssertFalse(editor.lifecycleJobs.isActive); XCTAssertFalse(controller.isSearching)
            XCTAssertFalse(controller.window?.isVisible ?? true)
            XCTAssertFalse(controller.applyReplacement())
        }
    }

    private func waitForSearch(_ controller: EditorFindController) throws {
        let deadline = Date().addingTimeInterval(5)
        while controller.isSearching && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertFalse(controller.isSearching, "Search did not finish")
    }
    private func withEditor(_ body: @escaping (MacVisioDocument, EditorWindowController) throws -> Void) throws {
        let work = {
            _ = NSApplication.shared
            let document = MacVisioDocument(); var diagram = Diagram()
            diagram.pages[0].nodes = [DiagramNode(text: "first needle")]
            var second = DiagramPage(name: "Second"); second.nodes = [DiagramNode(text: "🙂 needle العربية e\u{301}")]
            diagram.pages.append(second); document.diagram = diagram; document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            document.undoManager?.groupsByEvent = false; document.undoManager?.removeAllActions()
            defer {
                editor.documentFindController.close(); editor.window?.orderOut(nil); editor.window?.delegate = nil
                document.removeWindowController(editor); editor.close()
            }
            try body(document, editor)
        }
        if Thread.isMainThread { try work() } else { try DispatchQueue.main.sync(execute: work) }
    }
}
