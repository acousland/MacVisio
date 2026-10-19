import AppKit
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class M3CustomStencilEditorTests: XCTestCase {
    private var temporary: [URL] = []
    override func tearDown() { temporary.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-stencil-editor-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); temporary.append(url); return url
    }
    private func source(parts: [String: Data]? = nil) throws -> StencilPackageSnapshot {
        let url = try folder().appendingPathComponent("Custom.vssx")
        try VisioPackage.write(parts ?? CustomStencilTestFixture.parts(), to: url)
        return try StencilPackageEditing.read(from: url)
    }
    private func dispose(_ controller: StencilPackageEditorController) {
        controller.closeDecision = { .discard }
        if controller.isBusy { controller.cancelJobButton.performClick(nil); try? pump { !controller.isBusy } }
        controller.close()
    }
    private func pump(until complete: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !complete() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        guard complete() else { throw DiagramError.invalid("Custom stencil native operation timed out") }
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
    private func selectCell(_ address: DefinitionCellAddress, in controller: StencilPackageEditorController) throws {
        let master = try XCTUnwrap(controller.snapshot?.masters.first { $0.id == controller.selectedMasterID })
        let row = try XCTUnwrap(master.cells.firstIndex { $0.address == address })
        controller.cellTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertEqual(controller.selectedCell?.address, address)
    }

    func testNativeRenameUndoRedoAndSaveAsWritePublicIdentityWithoutChangingSource() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), before = try Data(contentsOf: source.sourceURL)
            let controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source); defer { dispose(controller) }
            let originalState = controller.stateID
            XCTAssertFalse(controller.isDirty)
            controller.nameField.stringValue = "Native renamed master"; controller.renameButton.performClick(nil)
            try pump { !controller.isBusy }
            XCTAssertEqual(controller.snapshot?.masters[0].name, "Native renamed master")
            XCTAssertEqual(controller.snapshot?.masters[0].id, 7); XCTAssertTrue(controller.isDirty)
            XCTAssertTrue(controller.draftUndoManager.canUndo)
            controller.undoButton.performClick(nil)
            XCTAssertEqual(controller.stateID, originalState); XCTAssertEqual(controller.snapshot?.masters[0].name, "Same name")
            XCTAssertFalse(controller.isDirty)
            controller.redoButton.performClick(nil)
            XCTAssertEqual(controller.snapshot?.masters[0].name, "Native renamed master"); XCTAssertTrue(controller.isDirty)
            let output = try folder().appendingPathComponent("Native edited.vssx")
            controller.saveDestination = { output }; controller.saveAsButton.performClick(nil)
            try pump { !controller.isBusy }
            XCTAssertEqual(controller.lastSavedURL, output); XCTAssertFalse(controller.isDirty)
            try retainPublicPair(source: source.sourceURL, edited: output,
                testName: "testNativeRenameUndoRedoAndSaveAsWritePublicIdentityWithoutChangingSource")
            var parts = try VisioPackage.read(output); parts.removeValue(forKey: "macvisio/document.json"); try VisioPackage.write(parts, to: output)
            let publicMasters = try VisioStencil.read(from: output).items
            XCTAssertEqual(publicMasters.map(\.name), ["Native renamed master", "Same name"])
            XCTAssertEqual(publicMasters.compactMap { $0.source?.masterID }, ["007", "42"])
            XCTAssertEqual(try Data(contentsOf: source.sourceURL), before)
        }
    }

    func testNativeLiteralApplyTargetsExactMasterAndUndoRetainsOtherSourceCells() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(parts: CustomStencilTestFixture.parts(opaque: true))
            let controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source); defer { dispose(controller) }
            try selectCell(DefinitionCellAddress(cell: "Width"), in: controller)
            XCTAssertTrue(controller.applyButton.isEnabled)
            controller.valueField.stringValue = "4"; controller.applyButton.performClick(nil)
            try pump { !controller.isBusy }
            XCTAssertEqual(controller.selectedCell?.value, ShapeSheetCell(value: "4", unit: "IN"))
            XCTAssertEqual(controller.snapshot?.parts[source.masters[1].part], source.parts[source.masters[1].part])
            XCTAssertEqual(controller.snapshot?.parts["custom/payload.bin"], source.parts["custom/payload.bin"])
            controller.undoButton.performClick(nil)
            XCTAssertEqual(controller.selectedCell?.value.value, "2")
            XCTAssertEqual(controller.snapshot?.parts, source.parts)
            controller.redoButton.performClick(nil); XCTAssertEqual(controller.selectedCell?.value.value, "4")
            XCTAssertTrue(controller.snapshot?.masters[0].cells.contains { $0.address.rowName == "Code" && $0.value.formula == "No Formula" } == true)
        }
    }

    func testNativeDuplicateMoveDeleteAndUndoPreserveExistingIdentityOrder() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source)
            defer { dispose(controller) }
            controller.duplicateButton.performClick(nil); try pump { !controller.isBusy }
            XCTAssertEqual(controller.snapshot?.masters.map(\.id), [7, 42, 43]); XCTAssertEqual(controller.selectedMasterID, 43)
            controller.upButton.performClick(nil); try pump { !controller.isBusy }
            XCTAssertEqual(controller.snapshot?.masters.map(\.id), [7, 43, 42])
            controller.downButton.performClick(nil); try pump { !controller.isBusy }
            XCTAssertEqual(controller.snapshot?.masters.map(\.id), [7, 42, 43])
            controller.deleteButton.performClick(nil); try pump { !controller.isBusy }
            XCTAssertEqual(controller.snapshot?.masters.map(\.id), [7, 42])
            controller.undoButton.performClick(nil); XCTAssertEqual(controller.snapshot?.masters.map(\.id), [7, 42, 43])
            XCTAssertEqual(controller.snapshot?.masters[0].baseID, source.masters[0].baseID)
            XCTAssertEqual(controller.snapshot?.masters[1].uniqueID, source.masters[1].uniqueID)
            controller.revertButton.performClick(nil)
            XCTAssertEqual(controller.snapshot?.parts, source.parts); XCTAssertFalse(controller.isDirty); XCTAssertFalse(controller.draftUndoManager.canUndo)
        }
    }

    func testPendingNativeFieldsAreRetainedOnCancelledCloseAndRefuseOwnerSelectionUntilApplied() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source)
            defer { dispose(controller) }
            controller.nameField.stringValue = "Unapplied draft"
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.nameField))
            XCTAssertTrue(controller.isDirty)
            XCTAssertFalse(controller.tableView(controller.masterTable, shouldSelectRow: 1))
            controller.closeDecision = { .cancel }
            XCTAssertFalse(controller.confirmCanCloseForTermination()); XCTAssertEqual(controller.nameField.stringValue, "Unapplied draft")
            XCTAssertEqual(controller.snapshot?.masters[0].name, "Same name"); XCTAssertFalse(controller.draftUndoManager.canUndo)
            controller.revertButton.performClick(nil)
            XCTAssertEqual(controller.nameField.stringValue, "Same name"); XCTAssertFalse(controller.isDirty)
            XCTAssertEqual(try VisioPackage.read(source.sourceURL), source.parts)
        }
    }

    func testStaleApplyAndSavePanelDraftAreRefusedAndSaveAsCancellationRetainsUndo() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source)
            defer { dispose(controller) }
            let captured = controller.currentInput
            controller.nameField.stringValue = "Committed draft"; controller.renameButton.performClick(nil); try pump { !controller.isBusy }
            XCTAssertFalse(controller.submit(.rename(masterID: 7, name: "Stale"), expectedInput: captured))
            XCTAssertEqual(controller.snapshot?.masters[0].name, "Committed draft")
            controller.saveDestination = { nil }; controller.saveAsButton.performClick(nil)
            XCTAssertTrue(controller.isDirty); XCTAssertTrue(controller.draftUndoManager.canUndo); XCTAssertNil(controller.lastSavedURL)
            let output = try folder().appendingPathComponent("Stale.vssx")
            controller.saveDestination = { controller.revertDraft(); return output }
            controller.saveAsButton.performClick(nil)
            XCTAssertFalse(controller.isBusy); XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            XCTAssertTrue(controller.statusLabel.stringValue.contains("draft changed"))
            XCTAssertEqual(controller.snapshot?.parts, source.parts)
        }
    }

    func testFormulaCellIsNativeReadOnlyAndDirectProposalPreservesCacheAndUndo() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source)
            defer { dispose(controller) }
            let address = DefinitionCellAddress(cell: "X", section: "Geometry", sectionIndex: "0", rowIndex: "2")
            try selectCell(address, in: controller)
            let cell = try XCTUnwrap(controller.selectedCell)
            XCTAssertFalse(controller.valueField.isEnabled); XCTAssertFalse(controller.applyButton.isEnabled)
            XCTAssertTrue(controller.submit(.literal(masterID: 7, shapeID: "1", address: address, expected: cell.value, value: "9"), expectedInput: controller.currentInput))
            try pump { !controller.isBusy }
            XCTAssertEqual(controller.selectedCell?.value, cell.value); XCTAssertEqual(controller.snapshot?.resourceID, source.resourceID)
            XCTAssertFalse(controller.draftUndoManager.canUndo); XCTAssertTrue(controller.statusLabel.stringValue.contains("authored formula"))
        }
    }

    func testOversizedUndoProposalRefusesInstallationAndRetainsTypedDraft() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source, maximumUndoCharge: 1)
            defer { dispose(controller) }
            let initial = controller.stateID
            controller.nameField.stringValue = "Budget refused draft"; controller.renameButton.performClick(nil); try pump { !controller.isBusy }
            XCTAssertEqual(controller.stateID, initial); XCTAssertEqual(controller.snapshot?.resourceID, source.resourceID)
            XCTAssertFalse(controller.draftUndoManager.canUndo); XCTAssertEqual(controller.nameField.stringValue, "Budget refused draft")
            XCTAssertTrue(controller.statusLabel.stringValue.contains("undo budget")); XCTAssertEqual(try VisioPackage.read(source.sourceURL), source.parts)
        }
    }

    func testBusySaveCancellationMustDrainBeforeCloseOrRevertAndDoesNotPublishOutput() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source)
            defer { dispose(controller) }
            controller.nameField.stringValue = "Unsaved draft"; controller.renameButton.performClick(nil); try pump { !controller.isBusy }
            let dirtyState = controller.stateID
            let gate = DispatchSemaphore(value: 0), lock = NSLock()
            var started = 0, finished = 0
            for _ in 0..<2 {
                try LifecycleJobService.shared.submit(kind: .library,
                    input: LifecycleJobInput(ownerID: UUID(), snapshotID: UUID(), revision: 0), work: { _ in
                        lock.lock(); started += 1; lock.unlock()
                        _ = gate.wait(timeout: .now() + 20); return true
                    }, completion: { _ in finished += 1 })
            }
            defer { gate.signal(); gate.signal(); try? pump { finished == 2 && !controller.isBusy } }
            try pump { lock.lock(); defer { lock.unlock() }; return started == 2 }
            let output = try folder().appendingPathComponent("Must not publish.vssx")
            XCTAssertTrue(controller.saveCopy(to: output, expectedInput: controller.currentInput)); XCTAssertTrue(controller.isBusy)
            controller.closeDecision = { .discard }
            XCTAssertFalse(controller.confirmCanCloseForTermination())
            controller.revertDraft()
            XCTAssertTrue(controller.isBusy); XCTAssertEqual(controller.stateID, dirtyState)
            XCTAssertFalse(controller.confirmCanCloseForTermination())
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            gate.signal(); gate.signal(); try pump { finished == 2 && !controller.isBusy }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)); XCTAssertTrue(controller.isDirty)
            XCTAssertEqual(controller.stateID, dirtyState); XCTAssertTrue(controller.confirmCanCloseForTermination())
            controller.revertDraft(); XCTAssertFalse(controller.isDirty)
            XCTAssertEqual(try VisioPackage.read(source.sourceURL), source.parts)
        }
    }

    func testSaveAsCloseDecisionSavesCopyThenAllowsRetryWithoutDiscardingSource() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source)
            defer { dispose(controller) }
            controller.nameField.stringValue = "Saved on close"; controller.renameButton.performClick(nil); try pump { !controller.isBusy }
            let output = try folder().appendingPathComponent("Close copy.vssx")
            controller.closeDecision = { .saveAs }; controller.saveDestination = { output }
            XCTAssertFalse(controller.confirmCanCloseForTermination()); try pump { !controller.isBusy }
            XCTAssertEqual(controller.lastSavedURL, output); XCTAssertFalse(controller.isDirty)
            XCTAssertTrue(controller.confirmCanCloseForTermination())
            XCTAssertEqual(try VisioStencil.read(from: output).items.first?.name, "Saved on close")
            XCTAssertEqual(try VisioPackage.read(source.sourceURL), source.parts)
        }
    }

    func testNativeMarkedTextRefusesApplyRevertAndCloseWithoutEndingComposition() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source)
            defer { dispose(controller) }
            controller.showWindow(nil)
            XCTAssertTrue(controller.window?.makeFirstResponder(controller.nameField) == true)
            let field = try XCTUnwrap(controller.window?.firstResponder as? NSTextView)
            field.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let initial = controller.stateID
            controller.renameButton.performClick(nil); controller.revertDraft()
            controller.closeDecision = { .discard }; XCTAssertFalse(controller.confirmCanCloseForTermination())
            XCTAssertTrue(field.hasMarkedText()); XCTAssertEqual(controller.stateID, initial)
            XCTAssertEqual(controller.snapshot?.resourceID, source.resourceID); field.unmarkText()
        }
    }

    func testAppDelegateReusesWindowRefusesDirtyQuitAndReleasesClosedController() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), delegate = AppDelegate()
            let controller = delegate.openStencilPackageEditor(source.sourceURL); defer { dispose(controller) }
            try pump { !controller.isBusy }
            XCTAssertNotNil(controller.snapshot)
            XCTAssertTrue(delegate.openStencilPackageEditor(source.sourceURL.standardizedFileURL) === controller)
            let unrelated = MacVisioDocument(); NSDocumentController.shared.addDocument(unrelated); defer { unrelated.close() }
            let other = unrelated.diagram, otherState = unrelated.stateID, otherRevision = unrelated.revision
            controller.nameField.stringValue = "Dirty quit draft"; controller.renameButton.performClick(nil); try pump { !controller.isBusy }
            controller.closeDecision = { .cancel }
            XCTAssertEqual(delegate.applicationShouldTerminate(NSApp), .terminateCancel)
            XCTAssertEqual(unrelated.diagram, other); XCTAssertEqual(unrelated.stateID, otherState); XCTAssertEqual(unrelated.revision, otherRevision)
            XCTAssertTrue(controller.isDirty)
            controller.closeDecision = { .discard }; controller.close()
            let replacement = delegate.openStencilPackageEditor(source.sourceURL); defer { dispose(replacement) }
            XCTAssertFalse(replacement === controller); try pump { !replacement.isBusy }
            XCTAssertNotNil(replacement.snapshot); XCTAssertFalse(replacement.isDirty)
        }
    }

    func testActualCloseClearsRetainedUndoAndSourceSnapshotsAndClosedDraftCannotRestore() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try source(), controller = StencilPackageEditorController(sourceURL: source.sourceURL, snapshot: source)
            let retainedUndo = controller.draftUndoManager
            controller.nameField.stringValue = "Undoable change"; controller.renameButton.performClick(nil); try pump { !controller.isBusy }
            XCTAssertTrue(retainedUndo.canUndo)
            controller.closeDecision = { .cancel }; controller.close()
            XCTAssertNotNil(controller.snapshot); XCTAssertTrue(retainedUndo.canUndo)
            controller.closeDecision = { .discard }; controller.close()
            XCTAssertNil(controller.snapshot); XCTAssertFalse(retainedUndo.canUndo); XCTAssertFalse(retainedUndo.canRedo)
            retainedUndo.undo(); controller.revertDraft(); controller.undoButton.performClick(nil)
            XCTAssertNil(controller.snapshot); XCTAssertNil(controller.selectedMasterID)
            XCTAssertEqual(try VisioPackage.read(source.sourceURL), source.parts)
        }
    }

    private func retainPublicPair(source: URL, edited: URL, testName: String) throws {
        guard let configured = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"], !configured.isEmpty else { return }
        let directory = URL(fileURLWithPath: configured, isDirectory: true)
            .appendingPathComponent("M3CustomStencilEditorTests", isDirectory: true)
            .appendingPathComponent(testName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contentsOf: source).write(to: directory.appendingPathComponent("source.vssx"), options: .atomic)
        try Data(contentsOf: edited).write(to: directory.appendingPathComponent("edited.vssx"), options: .atomic)
    }
}
