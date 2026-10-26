import AppKit
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class M3MembershipEditorTests: XCTestCase {
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }; return try DispatchQueue.main.sync(execute: body)
    }
    private func withEditor(_ model: Diagram? = nil, _ body: (MacVisioDocument, EditorWindowController) throws -> Void) throws {
        try onMain {
            _ = NSApplication.shared
            let input = try model ?? M3MembershipFixture.drawing()
            let document = MacVisioDocument(); document.diagram = DiagramCalculation.recalculate(input).diagram
            document.undoManager?.groupsByEvent = false; document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            editor.window?.makeKeyAndOrderFront(nil); editor.canvas.snapsToGrid = false
            document.commitTextEditing(); waitForDocument(document)
            document.undoManager?.removeAllActions(); document.updateChangeCount(.changeCleared)
            defer {
                editor.membershipController.cancelPendingWork(); waitForDocument(document)
                editor.membershipController.close(); editor.commandSearchController.close(); document.close()
            }
            try body(document, editor)
        }
    }
    private func waitForDocument(_ document: MacVisioDocument, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(15)
        while document.isCalculating && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(document.isCalculating, file: file, line: line)
    }
    private func waitForPanel(_ controller: MembershipEditorController, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(15)
        while controller.isBusy && Date() < deadline { controller.refreshAvailability(); _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        controller.refreshAvailability(); XCTAssertFalse(controller.isBusy, file: file, line: line)
    }
    private func open(_ editor: EditorWindowController) throws -> MembershipEditorController {
        editor.showMemberships(nil); let panel = editor.membershipController; waitForPanel(panel)
        XCTAssertTrue(panel.window?.isVisible == true); XCTAssertFalse(panel.entries.isEmpty, panel.reasonLabel.stringValue); return panel
    }
    private func choose(_ panel: MembershipEditorController, in document: MacVisioDocument, included: Bool = true) throws {
        XCTAssertTrue(panel.select(memberID: try M3MembershipFixture.id("11", in: document.diagram), containerID: try M3MembershipFixture.id("40", in: document.diagram), included: included))
    }
    private func blockPreparation(_ panel: MembershipEditorController) -> (started: DispatchSemaphore, release: DispatchSemaphore) {
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        panel.beforePreparation = { cancellation in
            started.signal(); _ = release.wait(timeout: .now() + 10); try cancellation.check()
        }
        return (started, release)
    }

    func testNoSelectionRoutesToNativeUUIDChoicesWithDuplicateNamesDisambiguated() throws {
        try withEditor { document, editor in
            editor.canvas.select([])
            let command = try XCTUnwrap(EditorSearchCommand.all.first { $0.action == #selector(EditorWindowController.showMemberships(_:)) })
            XCTAssertNil(command.disabledReason(in: editor))
            XCTAssertTrue(editor.validateMenuItem(NSMenuItem(title: "Memberships", action: command.action, keyEquivalent: "")))
            let panel = try open(editor)
            let duplicates = panel.entries.filter { $0.title.hasPrefix("Same name") }
            XCTAssertEqual(duplicates.count, 3); XCTAssertEqual(Set(duplicates.map(\.title)).count, 3)
            XCTAssertEqual(Set(panel.containers.map(\.publicID)), [20, 40]); XCTAssertFalse(panel.containers.contains { $0.publicID == 30 })
            for item in panel.memberPicker.itemArray { XCTAssertNotNil(item.representedObject as? NSUUID) }
            XCTAssertTrue(editor.canvas.selectedNodes.isEmpty); XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testNativeOneEdgeApplyUndoRedoAndActualPublicSaveReopen() throws {
        try withEditor { document, editor in
            let panel = try open(editor); try choose(panel, in: document)
            let before = document.diagram, state = document.stateID
            XCTAssertTrue(panel.applyButton.isEnabled); XCTAssertTrue(panel.applyMembership())
            XCTAssertTrue(document.isCalculating); XCTAssertEqual(document.diagram, before)
            XCTAssertFalse(panel.applyMembership())
            waitForDocument(document); waitForPanel(panel)
            XCTAssertNil(document.lastCalculationJobError); XCTAssertEqual(document.undoManager?.undoActionName, "Add Container Member")
            let edited = document.diagram
            let index = try DiagramMemberships.index(in: edited, pageID: edited.page.id)
            XCTAssertTrue(index.contains(member: try M3MembershipFixture.id("11", in: edited), container: try M3MembershipFixture.id("40", in: edited)))
            document.undoManager?.undo(); XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state)
            XCTAssertFalse(document.undoManager?.canUndo ?? true); XCTAssertFalse(document.isDocumentEdited)
            document.undoManager?.redo(); XCTAssertEqual(document.diagram, edited)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-membership-native-\(UUID()).vsdx")
            defer { try? FileManager.default.removeItem(at: url) }
            try VisioFormat.write(document.diagram, to: url)
            let capture = try M3MembershipEvidence.begin(suite: "M3MembershipEditorTests", test: #function, inputKind: "native Memberships Apply and undo/redo over authored public fixture", nativeURL: url, diagram: document.diagram)
            let publicParts = try M3MembershipFixture.stripped(VisioPackage.read(url)); try VisioPackage.write(publicParts, to: url)
            let reopened = try VisioFormat.read(from: url).diagram
            XCTAssertTrue(try DiagramMemberships.index(in: reopened, pageID: reopened.page.id).contains(member: M3MembershipFixture.id("11", in: reopened), container: M3MembershipFixture.id("40", in: reopened)))
            try capture?.finish(publicURL: url, reopened: reopened)
        }
    }

    func testStaleRawSelectionWithoutStateOrRevisionChangeRefusesApply() throws {
        try withEditor { document, editor in
            editor.canvas.select([try M3MembershipFixture.id("11", in: document.diagram)])
            let panel = try open(editor); try choose(panel, in: document)
            let before = document.diagram, state = document.stateID, revision = document.revision
            editor.canvas.select([try M3MembershipFixture.id("12", in: document.diagram)])
            XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(panel.applyMembership()); XCTAssertEqual(document.diagram, before); XCTAssertFalse(document.isCalculating)
            XCTAssertTrue(panel.reasonLabel.stringValue.contains("changed")); XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testStaleActivePageWithoutStateOrRevisionChangeRefusesApply() throws {
        var model = try M3MembershipFixture.drawing(); var second = DiagramPage(); second.name = "Other page"; model.pages.append(second)
        try withEditor(model) { document, editor in
            let panel = try open(editor); try choose(panel, in: document)
            let state = document.stateID, revision = document.revision
            document.activatePage(second.id)
            XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(panel.applyMembership()); XCTAssertFalse(document.isCalculating); XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testStaleSourceResourceWithoutSemanticRevisionRefusesApply() throws {
        try withEditor { document, editor in
            let panel = try open(editor); try choose(panel, in: document)
            let state = document.stateID, revision = document.revision, page = document.diagram.page
            let source = try XCTUnwrap(document.diagram.visioArchive)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M3-membership-source-rebase-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("saved.vsdx")
            var completed = false, failure: Error?
            // A successful save installs a new public preservation resource
            // while retaining the document's semantic state/revision. Directly
            // assigning diagram.visioArchive is a semantic model mutation.
            document.save(to: output, ofType: MacVisioDocument.visioType, for: .saveAsOperation) {
                failure = $0; completed = true
            }
            let deadline = Date().addingTimeInterval(20)
            while !completed && Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            XCTAssertTrue(completed)
            guard completed else { throw DiagramError.invalid("Membership source-rebase save timed out") }
            if let failure { throw failure }
            XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertEqual(document.diagram.page, page)
            XCTAssertNotEqual(document.diagram.visioArchive?.sourceResourceID, source.sourceResourceID)
            XCTAssertEqual(document.diagram.visioArchive?.sourceLineageID, source.sourceLineageID)
            XCTAssertEqual(try VisioPackage.read(output)["custom/opaque.bin"], source.parts["custom/opaque.bin"])
            let rebased = document.diagram
            XCTAssertFalse(panel.applyMembership()); XCTAssertFalse(document.isCalculating)
            XCTAssertTrue(panel.reasonLabel.stringValue.contains("changed"))
            XCTAssertEqual(document.diagram, rebased); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.undoManager?.canUndo ?? true); XCTAssertFalse(document.isDocumentEdited)
        }
    }

    func testMarkedTextBlocksOpenApplyReloadAndCloseWithoutFinalizingComposition() throws {
        try withEditor { document, editor in
            let panel = try open(editor); try choose(panel, in: document)
            let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
            panel.window?.contentView?.addSubview(text); panel.window?.makeFirstResponder(text)
            text.setMarkedText("編集中", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
            let before = document.diagram
            XCTAssertTrue(panel.hasMarkedText); XCTAssertFalse(panel.applyMembership()); XCTAssertFalse(panel.reloadSnapshot())
            panel.close(); XCTAssertFalse(panel.isClosed); XCTAssertTrue(text.hasMarkedText()); XCTAssertEqual(document.diagram, before)
            text.unmarkText(); panel.window?.makeFirstResponder(panel.memberPicker)
            XCTAssertTrue(panel.reloadSnapshot()); waitForPanel(panel)
        }
    }

    func testOtherDocumentChildCompositionBlocksOpeningWithoutFinalizingMarkedText() throws {
        try withEditor { document, editor in
            let child = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 180, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
            let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 160, height: 60))
            child.contentView?.addSubview(text); editor.window?.addChildWindow(child, ordered: .above)
            child.makeKeyAndOrderFront(nil); child.makeFirstResponder(text)
            text.setMarkedText("編集中", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
            defer { text.unmarkText(); child.close() }
            let before = document.diagram
            editor.showMemberships(nil)
            XCTAssertTrue(text.hasMarkedText()); XCTAssertFalse(editor.membershipController.window?.isVisible ?? true)
            XCTAssertEqual(document.diagram, before); XCTAssertFalse(document.isCalculating)
        }
    }

    func testOwnedCancellationDrainsWithoutPublishingOrChangingUndoAndDirtyState() throws {
        try withEditor { document, editor in
            let panel = try open(editor); try choose(panel, in: document)
            let before = document.diagram, state = document.stateID, revision = document.revision
            let gate = blockPreparation(panel); defer { gate.release.signal() }
            XCTAssertTrue(panel.applyMembership()); XCTAssertEqual(gate.started.wait(timeout: .now() + 5), .success)
            panel.cancelPendingWork(); gate.release.signal(); waitForDocument(document); waitForPanel(panel)
            XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, .cancelled)
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.undoManager?.canUndo ?? true); XCTAssertFalse(document.isDocumentEdited)
        }
    }

    func testSelectionChangeWhileWorkerRunsCannotPublishOrRestoreOverNewSelection() throws {
        try withEditor { document, editor in
            let member = try M3MembershipFixture.id("11", in: document.diagram), other = try M3MembershipFixture.id("12", in: document.diagram)
            editor.canvas.select([member]); let panel = try open(editor); try choose(panel, in: document)
            let before = document.diagram, gate = blockPreparation(panel); defer { gate.release.signal() }
            XCTAssertTrue(panel.applyMembership()); XCTAssertEqual(gate.started.wait(timeout: .now() + 5), .success)
            editor.canvas.select([other]); gate.release.signal(); waitForDocument(document); waitForPanel(panel)
            XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, .staleInput)
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(editor.canvas.selectedNodes, [other]); XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testClosingPanelCancelsOnlyItsOwnSubmittedJobAndCannotPublish() throws {
        try withEditor { document, editor in
            let panel = try open(editor); try choose(panel, in: document)
            let before = document.diagram, gate = blockPreparation(panel); defer { gate.release.signal() }
            XCTAssertTrue(panel.applyMembership()); XCTAssertEqual(gate.started.wait(timeout: .now() + 5), .success)
            panel.close(); XCTAssertTrue(panel.isClosed)
            gate.release.signal(); waitForDocument(document)
            XCTAssertEqual(document.diagram, before); XCTAssertFalse(document.undoManager?.canUndo ?? true)
            XCTAssertTrue(panel.entries.isEmpty); XCTAssertFalse(panel.applyMembership()); XCTAssertFalse(panel.reloadSnapshot())
            let reopened = editor.membershipController; XCTAssertFalse(reopened === panel)
        }
    }

    func testClosingIdlePanelDoesNotCancelAnotherNativeCalculation() throws {
        try withEditor { document, editor in
            let panel = try open(editor), frozen = document.diagram
            let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            document.replaceInEditor(with: frozen, action: "Other native edit", forceAsync: true, presentFailureAlert: false, preparation: { cancellation in
                started.signal(); _ = release.wait(timeout: .now() + 10); try cancellation.check()
                var next = frozen; next.page.nodes[0].text = "Other native edit"
                return (next, CalculationWork())
            })
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            let request = document.pendingCalculationID
            panel.close(); XCTAssertTrue(panel.isClosed); XCTAssertEqual(document.pendingCalculationID, request)
            release.signal(); waitForDocument(document)
            XCTAssertNil(document.lastCalculationJobError); XCTAssertEqual(document.diagram.page.nodes[0].text, "Other native edit")
        }
    }

    func testProtectedMemberRefusalKeepsDiagramHistoryAndNativeSelection() throws {
        var model = try M3MembershipFixture.drawing()
        let offset = try XCTUnwrap(model.page.nodes.firstIndex { $0.formatting.sourceShapeID == "11" })
        model.page.nodes[offset].formatting.sheet["LockFormat"] = ShapeSheetCell(value: "1")
        try withEditor(model) { document, editor in
            let member = try M3MembershipFixture.id("11", in: document.diagram); editor.canvas.select([member])
            let panel = try open(editor); try choose(panel, in: document)
            let before = document.diagram, state = document.stateID, revision = document.revision
            XCTAssertTrue(panel.applyMembership()); waitForDocument(document); waitForPanel(panel)
            XCTAssertTrue(document.lastCalculationJobError?.localizedDescription.contains("LockFormat") == true)
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertEqual(editor.canvas.selectedNodes, [member]); XCTAssertFalse(document.undoManager?.canUndo ?? true); XCTAssertFalse(document.isDocumentEdited)
        }
    }

    /// As in Visio: dragging a container carries its members in one undoable move.
    func testNativeContainerDragCarriesMembersAndMemberMotionKeepsMembership() throws {
        let source = M3MembershipFixture.mixedNative()
        let model = try DiagramMemberships.settingMembership(in: source, pageID: source.page.id, memberID: source.page.nodes[1].id, containerID: source.page.nodes[0].id, included: true)
        try withEditor(model) { document, editor in
            let container = document.diagram.page.nodes[0], member = document.diagram.page.nodes[1]
            editor.canvas.select([container.id])
            let before = document.diagram
            try drag(from: container.center, to: CGPoint(x: container.center.x + 30, y: container.center.y), editor: editor)
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(document.diagram.page.nodes[0].x, container.x + 30, accuracy: 1e-8)
            XCTAssertEqual(document.diagram.page.nodes[1].x, member.x + 30, accuracy: 1e-8)
            XCTAssertEqual(document.diagram.page.nodes[1].formatting.sheet["Relationships"], member.formatting.sheet["Relationships"])
            document.undoManager?.undo(); XCTAssertEqual(document.diagram, before)
            editor.canvas.select([member.id])
            try drag(from: member.center, to: CGPoint(x: member.center.x + 25, y: member.center.y), editor: editor)
            XCTAssertEqual(document.diagram.page.nodes[1].x, member.x + 25, accuracy: 1e-8)
            // This member lies outside its container's bounds, so dropping it leaves the container, as in
            // Visio; the move and the membership change undo together.
            XCTAssertFalse(document.diagram.page.nodes[0].formatting.sheet["Relationships"]?.formula.contains("Sheet.2!") ?? true)
            document.undoManager?.undo(); XCTAssertEqual(document.diagram, before)
        }
    }

    func testDistinctPickerItemsRetainDuplicateCaptionsAndSelectExplicitUUID() throws {
        try onMain {
            let picker = NSPopUpButton(frame: .zero, pullsDown: false), first = UUID(), second = UUID()
            MembershipEditorController.populatePicker(picker, choices: [(first, "Identical caption"), (second, "Identical caption")])
            XCTAssertEqual(picker.numberOfItems, 2); XCTAssertFalse(picker.itemArray[0] === picker.itemArray[1])
            XCTAssertEqual(picker.itemArray.map(\.title), ["Identical caption", "Identical caption"])
            MembershipEditorController.selectPicker(picker, id: second)
            XCTAssertEqual(picker.selectedItem?.representedObject as? NSUUID, second as NSUUID)
            MembershipEditorController.selectPicker(picker, id: first)
            XCTAssertEqual(picker.selectedItem?.representedObject as? NSUUID, first as NSUUID)
        }
    }

    func testPlainNativeCopyDuplicateDeleteAndUngroupRemainSynchronous() throws {
        var model = Diagram(); model.page.nodes = [DiagramNode(text: "One"), DiagramNode(x: 300, text: "Two")]
        try withEditor(model) { document, editor in
            XCTAssertFalse(DiagramMemberships.needsSourceProof(in: document.diagram, pageID: document.diagram.page.id))
            let first = document.diagram.page.nodes[0].id
            var completed = false
            editor.prepareMembershipFragment([first]) { fragment in completed = true; XCTAssertEqual(fragment.nodes.count, 1) }
            XCTAssertTrue(completed); XCTAssertFalse(document.isCalculating)
            editor.canvas.select([first]); editor.duplicateSelection(nil)
            XCTAssertFalse(document.isCalculating); XCTAssertEqual(document.diagram.page.nodes.count, 3)
            editor.deleteSelection(nil)
            XCTAssertFalse(document.isCalculating); XCTAssertEqual(document.diagram.page.nodes.count, 2)
            editor.canvas.select(Set(document.diagram.page.nodes.map(\.id))); editor.groupSelection(nil)
            XCTAssertFalse(document.isCalculating); XCTAssertEqual(document.diagram.page.nodes.count, 3)
            editor.ungroupSelection(nil)
            XCTAssertFalse(document.isCalculating); XCTAssertEqual(document.diagram.page.nodes.count, 2)
        }
    }

    func testSourceBackedNativeCutPublishesPreparedFragmentAndOneUndoableRemoval() throws {
        try withEditor { document, editor in
            let board = NSPasteboard.general
            let saved = (board.pasteboardItems ?? []).map { item in item.types.compactMap { type in item.data(forType: type).map { (type, $0) } } }
            defer {
                board.clearContents()
                let restored = saved.map { values -> NSPasteboardItem in let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item }
                if !restored.isEmpty { board.writeObjects(restored) }
            }
            board.clearContents(); board.setString("old clipboard", forType: .string)
            let member = try M3MembershipFixture.id("12", in: document.diagram)
            editor.canvas.select([member]); let before = document.diagram, state = document.stateID
            editor.canvas.cut(nil)
            XCTAssertTrue(document.isCalculating); XCTAssertEqual(document.diagram, before); XCTAssertEqual(board.string(forType: .string), "old clipboard")
            waitForDocument(document)
            XCTAssertNil(document.lastCalculationJobError); XCTAssertFalse(document.diagram.page.nodes.contains { $0.id == member })
            let data = try XCTUnwrap(board.data(forType: CanvasView.fragmentPasteboardType))
            let fragment = try JSONDecoder().decode(DiagramPage.self, from: data)
            XCTAssertEqual(fragment.nodes.map(\.id), [member]); XCTAssertTrue(fragment.edges.isEmpty)
            XCTAssertEqual(document.undoManager?.undoActionName, "Cut")
            document.undoManager?.undo(); XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state)
            XCTAssertEqual(board.data(forType: CanvasView.fragmentPasteboardType), data)
            document.undoManager?.redo(); XCTAssertFalse(document.diagram.page.nodes.contains { $0.id == member })
        }
    }

    func testStructuralAndProtectedCutRefusalsRetainDrawingClipboardHistoryAndSelection() throws {
        for protected in [false, true] {
            var model = try M3MembershipFixture.drawing()
            let publicID = protected ? "12" : "11", selected = try M3MembershipFixture.id(publicID, in: model)
            if protected {
                let offset = try XCTUnwrap(model.page.nodes.firstIndex { $0.id == selected })
                model.page.nodes[offset].formatting.sheet["LockDelete"] = ShapeSheetCell(value: "1")
            }
            try withEditor(model) { document, editor in
                let board = NSPasteboard(name: NSPasteboard.Name("M3CutRefusal-\(UUID())")); defer { board.releaseGlobally() }
                board.setString("retain me", forType: .string); let version = board.changeCount
                editor.canvas.select([selected]); let before = document.diagram, state = document.stateID, revision = document.revision
                editor.cutSelection(nil, pasteboard: board); waitForDocument(document)
                XCTAssertNotNil(document.lastCalculationJobError); XCTAssertEqual(document.diagram, before)
                XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision); XCTAssertEqual(editor.canvas.selectedNodes, [selected])
                XCTAssertEqual(board.changeCount, version); XCTAssertEqual(board.string(forType: .string), "retain me")
                XCTAssertFalse(document.undoManager?.canUndo ?? true); XCTAssertFalse(document.isDocumentEdited)
            }
        }
    }

    func testCutCancellationAndStaleSelectionCannotPublishClipboardOrRemoval() throws {
        for stale in [false, true] {
            try withEditor { document, editor in
                let board = NSPasteboard(name: NSPasteboard.Name("M3CutStale-\(UUID())")); defer { board.releaseGlobally() }
                board.setString("retain me", forType: .string); let version = board.changeCount
                let selected = try M3MembershipFixture.id("12", in: document.diagram), other = try M3MembershipFixture.id("10", in: document.diagram)
                editor.canvas.select([selected]); let before = document.diagram, state = document.stateID, revision = document.revision
                let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0); defer { release.signal() }
                editor.cutSelection(nil, pasteboard: board, beforePreparation: { cancellation in
                    started.signal(); _ = release.wait(timeout: .now() + 10); try cancellation.check()
                })
                XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
                if stale { editor.canvas.select([other]) } else { document.cancelPendingCalculation() }
                release.signal(); waitForDocument(document)
                XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, stale ? .staleInput : .cancelled)
                XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
                XCTAssertEqual(editor.canvas.selectedNodes, stale ? [other] : [selected]); XCTAssertEqual(board.changeCount, version)
                XCTAssertEqual(board.string(forType: .string), "retain me"); XCTAssertFalse(document.undoManager?.canUndo ?? true); XCTAssertFalse(document.isDocumentEdited)
            }
        }
    }

    func testCutRefusesIfClipboardChangesDuringPreparationWithoutOverwritingNewContent() throws {
        try withEditor { document, editor in
            let board = NSPasteboard(name: NSPasteboard.Name("M3CutClipboardStale-\(UUID())")); defer { board.releaseGlobally() }
            board.setString("old", forType: .string)
            editor.canvas.select([try M3MembershipFixture.id("12", in: document.diagram)])
            let before = document.diagram, started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0); defer { release.signal() }
            editor.cutSelection(nil, pasteboard: board, beforePreparation: { cancellation in
                started.signal(); _ = release.wait(timeout: .now() + 10); try cancellation.check()
            })
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            board.clearContents(); board.setString("new external clipboard", forType: .string); let version = board.changeCount
            release.signal(); waitForDocument(document)
            XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, .staleInput); XCTAssertEqual(document.diagram, before)
            XCTAssertEqual(board.changeCount, version); XCTAssertEqual(board.string(forType: .string), "new external clipboard")
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testMarkedTextBlocksCutWithoutFinalizingOrChangingClipboard() throws {
        try withEditor { document, editor in
            let board = NSPasteboard(name: NSPasteboard.Name("M3CutIME-\(UUID())")); defer { board.releaseGlobally() }
            board.setString("retain me", forType: .string); let version = board.changeCount
            editor.canvas.select([try M3MembershipFixture.id("12", in: document.diagram)])
            let child = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 180, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
            let text = NSTextView(frame: CGRect(x: 0, y: 0, width: 160, height: 60))
            child.contentView?.addSubview(text); editor.window?.addChildWindow(child, ordered: .above); child.makeKeyAndOrderFront(nil); child.makeFirstResponder(text)
            text.setMarkedText("編集中", selectedRange: NSRange(location: 0, length: 3), replacementRange: NSRange(location: NSNotFound, length: 0))
            defer { text.unmarkText(); child.close() }
            let before = document.diagram; editor.cutSelection(nil, pasteboard: board)
            XCTAssertTrue(text.hasMarkedText()); XCTAssertFalse(document.isCalculating); XCTAssertEqual(document.diagram, before)
            XCTAssertEqual(board.changeCount, version); XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testRetainedOwnerWithoutRelationshipsCutRefusalPreservesClipboardAndNativeHistory() throws {
        for variant in M3MembershipFixture.RetainedOwnerCase.allCases where !M3MembershipFixture.RetainedOwnerCase.ordinaryMasterInstances.contains(variant) {
            let model = try M3MembershipFixture.retainedOwnerWithoutRelationships(variant)
            try withEditor(model) { document, editor in
                let board = NSPasteboard(name: NSPasteboard.Name("M3RetainedOwnerCut-\(UUID())")); defer { board.releaseGlobally() }
                board.setString("retain clipboard", forType: .string); let clipboardVersion = board.changeCount
                let selected = try M3MembershipFixture.id("12", in: document.diagram)
                editor.canvas.select([selected])
                let entry = try XCTUnwrap(DiagramMemberships.index(in: document.diagram, pageID: document.diagram.page.id).entries[selected])
                XCTAssertNil(entry.cell); XCTAssertTrue(entry.unprovenRetainedOwnership)
                let before = document.diagram, state = document.stateID, revision = document.revision
                editor.cutSelection(nil, pasteboard: board); waitForDocument(document)
                XCTAssertTrue(document.lastCalculationJobError?.localizedDescription.contains("Retained source ownership") == true, "\(variant)")
                XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
                XCTAssertEqual(editor.canvas.selectedNodes, [selected]); XCTAssertFalse(document.undoManager?.canUndo ?? true)
                XCTAssertFalse(document.isDocumentEdited); XCTAssertEqual(board.changeCount, clipboardVersion)
                XCTAssertEqual(board.string(forType: .string), "retain clipboard")
            }
        }
    }

    func testNewUnboundOrdinaryNodeInSourceDrawingSupportsOwnedCopyAndCutUndo() throws {
        var model = try M3MembershipFixture.drawing()
        let added = DiagramNode(x: 430, y: 300, text: "Unsaved ordinary native object")
        model.page.nodes.append(added)
        try withEditor(model) { document, editor in
            editor.canvas.select([added.id])
            let entry = try XCTUnwrap(DiagramMemberships.index(in: document.diagram, pageID: document.diagram.page.id).entries[added.id])
            XCTAssertNil(entry.cell); XCTAssertNotNil(entry.sourceRefusal); XCTAssertFalse(entry.unprovenRetainedOwnership)
            var copied: DiagramPage?
            editor.prepareMembershipFragment([added.id]) { copied = $0 }
            let deadline = Date().addingTimeInterval(15)
            while copied == nil && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            XCTAssertEqual(try XCTUnwrap(copied).nodes.map(\.id), [added.id])
            let board = NSPasteboard(name: NSPasteboard.Name("M3UnboundOrdinaryCut-\(UUID())")); defer { board.releaseGlobally() }
            board.setString("old clipboard", forType: .string)
            let before = document.diagram, state = document.stateID
            editor.cutSelection(nil, pasteboard: board); waitForDocument(document)
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertFalse(document.diagram.page.nodes.contains { $0.id == added.id })
            let fragment = try JSONDecoder().decode(DiagramPage.self, from: XCTUnwrap(board.data(forType: CanvasView.fragmentPasteboardType)))
            XCTAssertEqual(fragment.nodes.map(\.id), [added.id]); XCTAssertEqual(document.undoManager?.undoActionName, "Cut")
            document.undoManager?.undo(); XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state)
            XCTAssertFalse(document.undoManager?.canUndo ?? true); XCTAssertFalse(document.isDocumentEdited)
        }
    }

    private func drag(from start: CGPoint, to end: CGPoint, editor: EditorWindowController) throws {
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            let canvas = editor.canvas
            let local = CGPoint(x: canvas.pageOrigin.x + point.x * canvas.coordinateZoom, y: canvas.pageOrigin.y + point.y * canvas.coordinateZoom)
            return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(local, to: nil), modifierFlags: [], timestamp: 0, windowNumber: editor.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        editor.canvas.mouseDown(with: try event(.leftMouseDown, start))
        editor.canvas.mouseDragged(with: try event(.leftMouseDragged, end))
        editor.canvas.mouseUp(with: try event(.leftMouseUp, end))
        waitForDocument(editor.diagramDocument)
    }
}
