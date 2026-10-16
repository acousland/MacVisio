import AppKit
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class AsyncCalculationContractTests: XCTestCase {
    func testLargeNativeEditReturnsPendingServicesHeartbeatAndCommitsOneUndo() {
        onMain {
            let document = makeDocument()
            defer { document.close() }
            let baseline = document.diagram, identity = document.stateID, revision = document.revision
            var edited = baseline
            edited.page.nodes[0].formatting.sheet["User.Offset"]?.value = "1"
            let expected = DiagramCalculation.recalculate(edited, previous: baseline).diagram
            var heartbeat = false
            DispatchQueue.main.async { heartbeat = true }
            let started = ProcessInfo.processInfo.systemUptime
            document.replaceInEditor(with: edited, action: "Widen shape", forceAsync: true)
            let requestSeconds = ProcessInfo.processInfo.systemUptime - started
            XCTAssertTrue(document.isCalculating)
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
            waitUntil { heartbeat && !document.isCalculating }
            XCTAssertTrue(heartbeat)
            XCTAssertFalse(document.isCalculating)
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(document.diagram, expected)
            XCTAssertEqual(document.revision, revision + 1)
            XCTAssertTrue(document.undoManager?.canUndo ?? false)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertFalse(document.undoManager?.canUndo ?? true, "One completed calculation must create exactly one undo action.")
            document.undoManager?.redo()
            XCTAssertEqual(document.diagram, expected)
            print("WP07 native async nodes=\(baseline.page.nodes.count) requestMainSeconds=\(requestSeconds) heartbeat=\(heartbeat)")
        }
    }

    func testCancellingPendingNativeEditPreservesCommittedIdentityAndUndo() {
        onMain {
            let document = makeDocument()
            defer { document.close() }
            let baseline = document.diagram, identity = document.stateID, revision = document.revision
            let wasEdited = document.isDocumentEdited
            var edited = baseline
            edited.page.nodes[0].formatting.sheet["User.Offset"]?.value = "2"
            document.replaceInEditor(with: edited, action: "Cancelled edit", forceAsync: true)
            XCTAssertTrue(document.isCalculating)
            document.cancelPendingCalculation()
            waitUntil { !document.isCalculating }
            XCTAssertFalse(document.isCalculating)
            XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, .cancelled)
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            XCTAssertEqual(document.isDocumentEdited, wasEdited)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testNewCommittedRevisionRejectsPendingResultWithoutOverwritingIt() {
        onMain {
            let document = makeDocument()
            defer { document.close() }
            var edited = document.diagram
            edited.page.nodes[0].formatting.sheet["User.Offset"]?.value = "2"
            document.replaceInEditor(with: edited, action: "Superseded edit", forceAsync: true)
            XCTAssertTrue(document.isCalculating)
            // This deterministic external state change occurs before the main
            // queue can deliver the pending calculation result.
            document.diagram.page.nodes[1].text = "Newer committed content"
            document.updateChangeCount(.changeDone)
            let newer = document.diagram, identity = document.stateID, revision = document.revision
            waitUntil { !document.isCalculating }
            XCTAssertFalse(document.isCalculating)
            XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, .staleInput)
            XCTAssertEqual(document.diagram, newer)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testSaveWhileCalculationPendingCapturesCommittedSnapshotAndUndoReturnsToSavedState() throws {
        try onMain {
            let document = makeDocument()
            defer { document.close() }
            document.updateChangeCount(.changeDone)
            let baseline = document.diagram, savedIdentity = document.stateID
            var edited = baseline
            edited.page.nodes[0].formatting.sheet["User.Offset"]?.value = "1"
            let expected = DiagramCalculation.recalculate(edited, previous: baseline).diagram
            document.replaceInEditor(with: edited, action: "Pending saved edit", forceAsync: true)
            XCTAssertTrue(document.isCalculating)
            let immediate = try JSONDecoder().decode(Diagram.self, from: document.data(ofType: MacVisioDocument.nativeType))
            XCTAssertEqual(immediate, baseline)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("M1-pending-calculation-\(UUID()).macvisio")
            defer { try? FileManager.default.removeItem(at: url) }
            var saved = false, failure: Error?
            document.save(to: url, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) {
                failure = $0
                saved = true
            }
            waitUntil { saved && !document.isCalculating }
            XCTAssertTrue(saved)
            if let failure { throw failure }
            let disk = try JSONDecoder().decode(Diagram.self, from: Data(contentsOf: url))
            XCTAssertEqual(disk, baseline)
            XCTAssertEqual(document.diagram, expected)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertEqual(document.saveEvents.last?.snapshotStateID, savedIdentity)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, savedIdentity)
            XCTAssertFalse(document.isDocumentEdited)
        }
    }

    func testPublicSaveRebaseWhileWorkerQueuedSurvivesLaterCalculationCommit() throws {
        try onMain {
            _ = NSApplication.shared
            let gates = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
            let started = expectation(description: "Occupy both owned workers")
            started.expectedFulfillmentCount = 2
            let blockersFinished = expectation(description: "Release owned workers")
            blockersFinished.expectedFulfillmentCount = 2
            var blockers: [LifecycleJobHandle] = []
            defer {
                blockers.forEach { $0.cancel() }
                gates.forEach { $0.signal() }
            }
            for gate in gates {
                let input = LifecycleJobInput(ownerID: UUID(), snapshotID: UUID(), revision: 0)
                blockers.append(try LifecycleJobService.shared.submit(kind: .calculation, input: input, work: { context in
                    started.fulfill()
                    guard gate.wait(timeout: .now() + 30) == .success else { throw LifecycleJobError.cancelled }
                    try context.checkpoint()
                }, completion: { _ in blockersFinished.fulfill() }))
            }
            wait(for: [started], timeout: 5)
            let document = makeDocument()
            defer { document.close() }
            let baseline = document.diagram, identity = document.stateID
            var edited = baseline
            edited.page.nodes[0].formatting.sheet["User.Offset"]?.value = "1"
            var expected = DiagramCalculation.recalculate(edited, previous: baseline).diagram
            document.replaceInEditor(with: edited, action: "Public source pending edit", forceAsync: true)
            XCTAssertTrue(document.isCalculating)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("M1-public-pending-\(UUID()).vsdx")
            defer { try? FileManager.default.removeItem(at: url) }
            var saved = false, failure: Error?
            document.save(to: url, ofType: MacVisioDocument.visioType, for: .saveAsOperation) {
                failure = $0
                saved = true
            }
            waitUntil { saved }
            if let failure { throw failure }
            XCTAssertTrue(document.isCalculating, "The calculation is queued behind the deterministic worker gates.")
            XCTAssertEqual(document.stateID, identity)
            let savedArchive = try XCTUnwrap(document.diagram.visioArchive)
            XCTAssertFalse(savedArchive.parts.isEmpty)
            expected.visioArchive = savedArchive
            gates.forEach { $0.signal() }
            wait(for: [blockersFinished], timeout: 5)
            waitUntil { !document.isCalculating }
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(document.diagram, expected)
            XCTAssertEqual(document.diagram.visioArchive?.sourceResourceID, savedArchive.sourceResourceID)
            XCTAssertEqual(document.diagram.visioArchive?.sourceLineageID, savedArchive.sourceLineageID)
            XCTAssertEqual(document.diagram.visioArchive?.pages, savedArchive.pages)
            XCTAssertEqual(document.diagram.visioArchive?.parts, savedArchive.parts)
            XCTAssertTrue(document.isDocumentEdited)
        }
    }

    func testCancelledInsertionRestoresNodeAndEdgeSelectionsInEveryEditor() throws {
        try onMain {
            let document = makeDocument(nodeCount: 80)
            defer { document.close() }
            let sourceID = document.diagram.page.nodes[0].id, targetID = document.diagram.page.nodes[1].id
            let edge = DiagramEdge(source: sourceID, target: targetID, style: .straight)
            document.diagram.page.edges = [edge]
            document.makeWindowControllers()
            document.makeWindowControllers()
            let editors = document.windowControllers.compactMap { $0 as? EditorWindowController }
            XCTAssertEqual(editors.count, 2)
            let first = try XCTUnwrap(editors.first), second = try XCTUnwrap(editors.last)
            first.canvas.select([sourceID])
            second.canvas.select([], edge: edge.id)
            let baseline = document.diagram, identity = document.stateID, revision = document.revision
            var inserted = baseline
            let node = DiagramNode(text: "Uncommitted insertion")
            let pendingEdge = DiagramEdge(source: sourceID, target: node.id, style: .straight)
            inserted.page.nodes.append(node)
            inserted.page.edges.append(pendingEdge)
            document.replaceInEditor(with: inserted, action: "Cancelled insertion", forceAsync: true)
            XCTAssertTrue(document.isCalculating)
            first.canvas.select([node.id])
            second.canvas.select([], edge: pendingEdge.id)
            document.cancelPendingCalculation()
            waitUntil { !document.isCalculating }
            XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, .cancelled)
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            XCTAssertEqual(first.canvas.selectedNodes, [sourceID])
            XCTAssertNil(first.canvas.selectedEdge)
            XCTAssertTrue(second.canvas.selectedNodes.isEmpty)
            XCTAssertEqual(second.canvas.selectedEdge, edge.id)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testStaleInsertionCannotRestoreSelectionOverNewerCommittedEdit() throws {
        try onMain {
            let document = makeDocument(nodeCount: 80)
            defer { document.close() }
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            let previousSelection = document.diagram.page.nodes[0].id
            let newerSelection = document.diagram.page.nodes[2].id
            editor.canvas.select([previousSelection])
            var inserted = document.diagram
            let node = DiagramNode(text: "Superseded insertion")
            inserted.page.nodes.append(node)
            document.replaceInEditor(with: inserted, action: "Stale insertion", forceAsync: true)
            XCTAssertTrue(document.isCalculating)
            editor.canvas.select([node.id])
            document.diagram.page.nodes[1].text = "Newer committed edit"
            document.updateChangeCount(.changeDone)
            editor.canvas.select([newerSelection])
            let newer = document.diagram, identity = document.stateID, revision = document.revision
            waitUntil { !document.isCalculating }
            XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, .staleInput)
            XCTAssertEqual(document.diagram, newer)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            XCTAssertEqual(editor.canvas.selectedNodes, [newerSelection])
            XCTAssertNil(editor.canvas.selectedEdge)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testNativeLargeControlReleaseQueuesItsSolveAndCommitsOneUndo() throws {
        try onMain {
            let document = makeControlDocument(nodeCount: 2200)
            defer { document.close() }
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            let window = try XCTUnwrap(editor.window), canvas = editor.canvas
            window.contentView?.layoutSubtreeIfNeeded()
            canvas.zoom = 1
            canvas.snapsToGrid = false
            let baseline = document.diagram, identity = document.stateID, revision = document.revision
            let node = baseline.page.nodes[0], control = try XCTUnwrap(node.formatting.controls.first)
            let start = ControlGeometry.point(control, on: node), end = CGPoint(x: start.x + 48, y: start.y)
            let moved = try ControlEditing.moved(baseline, node: node.id, control: control.name, to: end)
            let expected = DiagramCalculation.recalculate(moved, previous: baseline).diagram
            canvas.select([node.id])
            func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                let position = CGPoint(x: canvas.pageOrigin.x + point.x * canvas.coordinateZoom,
                                       y: canvas.pageOrigin.y + point.y * canvas.coordinateZoom)
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(position, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            canvas.mouseDown(with: try event(.leftMouseDown, start))
            canvas.mouseDragged(with: try event(.leftMouseDragged, end))
            XCTAssertEqual(document.diagram, baseline)
            canvas.mouseUp(with: try event(.leftMouseUp, end))
            XCTAssertTrue(document.isCalculating, "Large native control preparation must be owned by the worker request.")
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            let saved = try JSONDecoder().decode(Diagram.self, from: document.data(ofType: MacVisioDocument.nativeType))
            XCTAssertEqual(saved, baseline)
            waitUntil { !document.isCalculating }
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(document.diagram, expected)
            XCTAssertEqual(document.revision, revision + 1)
            XCTAssertGreaterThan(document.lastCalculationWork.geometryNodes, 0)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testCancellingOwnedControlPreparationPreservesCommittedSnapshot() throws {
        try onMain {
            let document = makeControlDocument()
            defer { document.close() }
            let baseline = document.diagram, identity = document.stateID, revision = document.revision
            let node = baseline.page.nodes[0], control = try XCTUnwrap(node.formatting.controls.first)
            let start = ControlGeometry.point(control, on: node)
            document.adjustControlInEditor(baseline: document.prepareControlGesture(), node: node.id, control: control.name,
                                           to: CGPoint(x: start.x + 48, y: start.y), forceAsync: true)
            XCTAssertTrue(document.isCalculating)
            document.cancelPendingCalculation()
            waitUntil { !document.isCalculating }
            XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, .cancelled)
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testStaleControlGestureBaselineIsRejectedBeforeScheduling() throws {
        try onMain {
            let document = makeControlDocument()
            defer { document.close() }
            let baseline = document.prepareControlGesture(), node = document.diagram.page.nodes[0]
            let control = try XCTUnwrap(node.formatting.controls.first)
            document.diagram.page.nodes[1].text = "Newer edit before control release"
            document.updateChangeCount(.changeDone)
            let newer = document.diagram, identity = document.stateID, revision = document.revision
            document.adjustControlInEditor(baseline: baseline, node: node.id, control: control.name, to: CGPoint(x: 220, y: 144), forceAsync: true)
            XCTAssertFalse(document.isCalculating)
            XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, .staleInput)
            XCTAssertEqual(document.diagram, newer)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testPendingOrdinaryEditPreservesLatestPagePresentationAndUndo() {
        onMain {
            let document = makeDocument(nodeCount: 80)
            defer { document.close() }
            document.diagram.pages.append(DiagramPage(name: "Other view"))
            let baseline = document.diagram, identity = document.stateID, revision = document.revision
            let otherPage = baseline.pages[1].id
            var edited = baseline
            edited.pages[0].nodes[0].formatting.sheet["User.Offset"]?.value = "1"
            var expected = DiagramCalculation.recalculate(edited, previous: baseline).diagram
            expected.activePageID = otherPage
            document.replaceInEditor(with: edited, action: "Edit while viewing another page", forceAsync: true)
            XCTAssertTrue(document.isCalculating)
            document.activatePage(otherPage)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            waitUntil { !document.isCalculating }
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(document.diagram, expected)
            XCTAssertEqual(document.diagram.activePageID, otherPage)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.activePageID, otherPage)
            XCTAssertEqual(document.diagram.pages, baseline.pages)
            XCTAssertEqual(document.stateID, identity)
        }
    }

    func testPendingExplicitPageChangeRetainsCommandTargetOverViewActivation() {
        onMain {
            let document = makeDocument(nodeCount: 80)
            defer { document.close() }
            document.diagram.pages.append(DiagramPage(name: "Other view"))
            let baseline = document.diagram, identity = document.stateID, revision = document.revision
            let requested = DiagramPage(name: "Explicit new page")
            var edited = baseline
            edited.pages.append(requested)
            edited.activePageID = requested.id
            document.replaceInEditor(with: edited, action: "Add and activate page", forceAsync: true)
            XCTAssertTrue(document.isCalculating)
            document.activatePage(baseline.pages[1].id)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            waitUntil { !document.isCalculating }
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(document.diagram.activePageID, requested.id)
            XCTAssertEqual(document.diagram.pages, edited.pages)
            XCTAssertNotEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision + 1)
        }
    }

    func testControlBaselineSurvivesPresentationChangeWithoutNavigatingBack() throws {
        try onMain {
            let document = makeControlDocument()
            defer { document.close() }
            document.diagram.pages.append(DiagramPage(name: "Newly viewed page"))
            let baseline = document.prepareControlGesture(), identity = document.stateID, revision = document.revision
            let node = baseline.input.pages[0].nodes[0], control = try XCTUnwrap(node.formatting.controls.first)
            let start = ControlGeometry.point(control, on: node), end = CGPoint(x: start.x + 48, y: start.y)
            let viewedPage = document.diagram.pages[1].id
            document.activatePage(viewedPage)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            var moved = try ControlEditing.moved(baseline.input, node: node.id, control: control.name, to: end)
            moved.activePageID = viewedPage
            let expected = DiagramCalculation.recalculate(moved, previous: document.diagram).diagram
            document.adjustControlInEditor(baseline: baseline, node: node.id, control: control.name, to: end, forceAsync: true)
            XCTAssertTrue(document.isCalculating)
            waitUntil { !document.isCalculating }
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(document.diagram, expected)
            XCTAssertEqual(document.diagram.activePageID, viewedPage)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.activePageID, viewedPage)
            XCTAssertEqual(document.diagram.pages, baseline.input.pages)
            XCTAssertEqual(document.stateID, identity)
        }
    }

    func testSaveFinalizesLargeActiveInspectorTextBeforeCapturingAndDrainsQueuedSave() throws {
        try onMain {
            let document = makeDocument()
            defer { document.close() }
            let editor = try beginInspectorText("Text finalized by Save", in: document)
            let baseline = document.diagram, identity = document.stateID
            let directory = try makeSaveDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = directory.appendingPathComponent("first.macvisio"), second = directory.appendingPathComponent("queued.macvisio")
            var completions = [Result<Void, Error>]()
            document.save(to: first, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) { error in
                completions.append(error.map { .failure($0) } ?? .success(()))
            }
            XCTAssertTrue(document.isCalculating)
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertTrue(completions.isEmpty)
            XCTAssertEqual(document.saveEvents.last?.phase, "waiting-for-text")
            XCTAssertFalse(document.saveEvents.contains { $0.phase == "captured" })
            document.save(to: second, ofType: MacVisioDocument.nativeType, for: .saveToOperation) { error in
                completions.append(error.map { .failure($0) } ?? .success(()))
            }
            waitUntil { completions.count == 2 && !document.isCalculating }
            try completions.forEach { try $0.get() }
            let written = try JSONDecoder().decode(Diagram.self, from: Data(contentsOf: first))
            XCTAssertEqual(written.page.nodes[0].text, "Text finalized by Save")
            XCTAssertEqual(try JSONDecoder().decode(Diagram.self, from: Data(contentsOf: second)), written)
            XCTAssertEqual(document.diagram, written)
            XCTAssertNotEqual(document.stateID, identity)
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertTrue(editor.window?.firstResponder === editor.canvas)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testCancelledSaveTextCalculationFailsBeforeSnapshotThenDrainsNextSave() throws {
        try onMain {
            let document = makeDocument()
            defer { document.close() }
            try beginInlineText("Cancelled inline text", in: document)
            let baseline = document.diagram, identity = document.stateID
            let directory = try makeSaveDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let first = directory.appendingPathComponent("cancelled.macvisio"), second = directory.appendingPathComponent("next.macvisio")
            var firstCompletion: Result<Void, Error>?, secondCompletion: Result<Void, Error>?
            document.save(to: first, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) { error in
                firstCompletion = error.map { .failure($0) } ?? .success(())
            }
            XCTAssertTrue(document.isCalculating)
            XCTAssertNil(firstCompletion)
            document.save(to: second, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) { error in
                secondCompletion = error.map { .failure($0) } ?? .success(())
            }
            document.cancelPendingCalculation()
            waitUntil { firstCompletion != nil && secondCompletion != nil && !document.isCalculating }
            XCTAssertThrowsError(try XCTUnwrap(firstCompletion).get()) { error in
                XCTAssertEqual(error as? LifecycleJobError, .cancelled)
            }
            try XCTUnwrap(secondCompletion).get()
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
            XCTAssertEqual(try JSONDecoder().decode(Diagram.self, from: Data(contentsOf: second)), baseline)
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.saveEvents.filter { $0.phase == "captured" }.count, 1)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testStaleSaveTextCalculationFailsWithoutWritingOrAcknowledgingNewerEdit() throws {
        try onMain {
            let document = makeDocument()
            defer { document.close() }
            try beginInlineText("Superseded inline text", in: document)
            let directory = try makeSaveDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("stale.macvisio")
            var completion: Result<Void, Error>?
            document.save(to: url, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) { error in
                completion = error.map { .failure($0) } ?? .success(())
            }
            XCTAssertTrue(document.isCalculating)
            document.diagram.page.nodes[1].text = "Newer committed edit"
            document.updateChangeCount(.changeDone)
            let newer = document.diagram, identity = document.stateID
            waitUntil { completion != nil && !document.isCalculating }
            XCTAssertThrowsError(try XCTUnwrap(completion).get()) { error in
                XCTAssertEqual(error as? LifecycleJobError, .staleInput)
            }
            XCTAssertEqual(document.diagram, newer)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertFalse(document.saveEvents.contains { $0.phase == "captured" || $0.phase == "succeeded" })
        }
    }

    func testClosingDocumentFailsHeldTextSaveAndQueuedSaveExactlyOnce() throws {
        try onMain {
            let document = makeDocument()
            try beginInlineText("Text abandoned by close", in: document)
            let directory = try makeSaveDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let urls = ["held.macvisio", "queued.macvisio"].map { directory.appendingPathComponent($0) }
            var failures = [Error?]()
            for url in urls {
                document.save(to: url, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) { failures.append($0) }
            }
            XCTAssertTrue(document.isCalculating)
            XCTAssertTrue(failures.isEmpty)
            document.close()
            XCTAssertEqual(failures.count, 2)
            XCTAssertTrue(failures.allSatisfy { ($0 as? LifecycleJobError) == .cancelled })
            waitUntil { !document.isCalculating }
            XCTAssertEqual(failures.count, 2)
            XCTAssertTrue(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            XCTAssertFalse(document.saveEvents.contains { $0.phase == "captured" || $0.phase == "succeeded" })
        }
    }

    func testDirectSerializationRejectsNewAsyncTextCommitInsteadOfReturningPriorText() throws {
        try onMain {
            let document = makeDocument()
            defer { document.close() }
            try beginInlineText("Text requires asynchronous finalization", in: document)
            XCTAssertThrowsError(try document.data(ofType: MacVisioDocument.nativeType))
            XCTAssertTrue(document.isCalculating)
            waitUntil { !document.isCalculating }
            let encoded = try JSONDecoder().decode(Diagram.self, from: document.data(ofType: MacVisioDocument.nativeType))
            XCTAssertEqual(encoded.page.nodes[0].text, "Text requires asynchronous finalization")
        }
    }

    func testSaveTextSubmissionRejectionFailsWithoutWritingPriorText() throws {
        try onMain {
            let document = makeDocument()
            defer { document.close() }
            try beginInlineText("Text rejected at admission", in: document)
            let baseline = document.diagram, identity = document.stateID
            let directory = try makeSaveDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("rejected.macvisio")
            // Completion delivery owns queue removal on main. Filling admission
            // without pumping main deterministically rejects the text request,
            // even if these trivial worker records have already finished.
            var handles = [LifecycleJobHandle](), finished = 0, reachedCapacity = false
            defer { handles.forEach { $0.cancel() } }
            for _ in 0..<33 {
                do {
                    let input = LifecycleJobInput(ownerID: UUID(), snapshotID: UUID(), revision: 0)
                    handles.append(try LifecycleJobService.shared.submit(kind: .calculation, input: input,
                        work: { _ in }, completion: { _ in finished += 1 }))
                } catch LifecycleJobError.queueFull {
                    reachedCapacity = true
                    break
                }
            }
            XCTAssertTrue(reachedCapacity)
            var completion: Result<Void, Error>?
            document.save(to: url, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) { error in
                completion = error.map { .failure($0) } ?? .success(())
            }
            XCTAssertThrowsError(try XCTUnwrap(completion).get()) { error in
                XCTAssertEqual(error as? LifecycleJobError, .queueFull)
            }
            XCTAssertFalse(document.isCalculating)
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertFalse(document.saveEvents.contains { $0.phase == "captured" || $0.phase == "succeeded" })
            waitUntil { finished == handles.count }
        }
    }

    func testCloseWaitsForLargeActiveTextThenAutosavesNamedDocumentBeforeAllowingClose() throws {
        try onMain {
            let document = makeDocument()
            defer { document.close() }
            let directory = try makeSaveDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("close.macvisio")
            var saved: Result<Void, Error>?
            document.save(to: url, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) { error in
                saved = error.map { .failure($0) } ?? .success(())
            }
            waitUntil { saved != nil }
            try XCTUnwrap(saved).get()
            XCTAssertFalse(document.isDocumentEdited)
            try beginInspectorText("Accepted before close autosaves", in: document)
            let baseline = document.diagram, identity = document.stateID
            let recorder = CloseReplyRecorder()
            let context = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
            defer { context.deallocate() }
            document.canClose(withDelegate: recorder, shouldClose: #selector(CloseReplyRecorder.document(_:shouldClose:contextInfo:)), contextInfo: context)
            XCTAssertTrue(document.isCalculating)
            XCTAssertTrue(recorder.replies.isEmpty)
            XCTAssertEqual(document.diagram, baseline)
            waitUntil { !recorder.replies.isEmpty && !document.isCalculating }
            let reply = try XCTUnwrap(recorder.replies.first)
            XCTAssertEqual(recorder.replies.count, 1)
            XCTAssertTrue(reply.document === document)
            XCTAssertTrue(reply.shouldClose)
            XCTAssertEqual(reply.context, context)
            XCTAssertNotEqual(document.stateID, identity)
            XCTAssertEqual(document.diagram.page.nodes[0].text, "Accepted before close autosaves")
            let persisted = try JSONDecoder().decode(Diagram.self, from: Data(contentsOf: url))
            XCTAssertEqual(persisted, document.diagram)
            XCTAssertFalse(document.isDocumentEdited)
        }
    }

    func testCancelledCloseTextCalculationRefusesOriginalAndBoundsRepeatedAdmission() throws {
        try onMain {
            let document = makeDocument()
            defer { document.close() }
            XCTAssertFalse(document.isDocumentEdited)
            try beginInlineText("Unaccepted close text", in: document)
            let baseline = document.diagram, identity = document.stateID, revision = document.revision
            let recorder = CloseReplyRecorder()
            let context = UnsafeMutableRawPointer.allocate(byteCount: 2, alignment: 1)
            defer { context.deallocate() }
            let selector = #selector(CloseReplyRecorder.document(_:shouldClose:contextInfo:))
            document.canClose(withDelegate: recorder, shouldClose: selector, contextInfo: context)
            XCTAssertTrue(document.isCalculating)
            XCTAssertTrue(recorder.replies.isEmpty, "A clean document must not allow close before newly finalized text is accepted.")
            document.canClose(withDelegate: recorder, shouldClose: selector, contextInfo: context.advanced(by: 1))
            XCTAssertEqual(recorder.replies.count, 1)
            XCTAssertFalse(try XCTUnwrap(recorder.replies.first).shouldClose)
            XCTAssertEqual(recorder.replies.first?.context, context.advanced(by: 1))
            document.cancelPendingCalculation()
            waitUntil { !document.isCalculating && recorder.replies.count == 2 }
            XCTAssertEqual(recorder.replies.count, 2)
            XCTAssertTrue(recorder.replies.allSatisfy { $0.document === document && !$0.shouldClose })
            XCTAssertEqual(recorder.replies.last?.context, context)
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testDirectCloseRefusesWaitingTextDelegateExactlyOnce() throws {
        try onMain {
            let document = makeDocument()
            try beginInlineText("Text abandoned by direct close", in: document)
            let recorder = CloseReplyRecorder()
            document.canClose(withDelegate: recorder, shouldClose: #selector(CloseReplyRecorder.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            XCTAssertTrue(document.isCalculating)
            XCTAssertTrue(recorder.replies.isEmpty)
            document.close()
            XCTAssertEqual(recorder.replies.count, 1)
            XCTAssertFalse(try XCTUnwrap(recorder.replies.first).shouldClose)
            waitUntil { !document.isCalculating }
            XCTAssertEqual(recorder.replies.count, 1)
        }
    }

    func testStaleCloseTextCalculationRefusesWithoutChangingNewerCommittedState() throws {
        try onMain {
            let document = makeDocument()
            defer { document.close() }
            try beginInlineText("Superseded close text", in: document)
            let recorder = CloseReplyRecorder()
            document.canClose(withDelegate: recorder, shouldClose: #selector(CloseReplyRecorder.document(_:shouldClose:contextInfo:)), contextInfo: nil)
            XCTAssertTrue(document.isCalculating)
            document.diagram.page.nodes[1].text = "Newer content remains open"
            document.updateChangeCount(.changeDone)
            let newer = document.diagram, identity = document.stateID
            waitUntil { !document.isCalculating && !recorder.replies.isEmpty }
            XCTAssertEqual(recorder.replies.count, 1)
            XCTAssertFalse(try XCTUnwrap(recorder.replies.first).shouldClose)
            XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, .staleInput)
            XCTAssertEqual(document.diagram, newer)
            XCTAssertEqual(document.stateID, identity)
            XCTAssertTrue(document.isDocumentEdited)
        }
    }

    @discardableResult
    private func beginInspectorText(_ text: String, in document: MacVisioDocument) throws -> EditorWindowController {
        document.makeWindowControllers()
        let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        editor.canvas.select([document.diagram.page.nodes[0].id])
        let field = try XCTUnwrap(editor.root.inspector.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == "Text" })
        XCTAssertTrue(editor.window!.makeFirstResponder(field))
        let fieldEditor = try XCTUnwrap(field.currentEditor())
        fieldEditor.string = text
        fieldEditor.didChangeText()
        XCTAssertFalse(document.isCalculating)
        return editor
    }

    private func beginInlineText(_ text: String, in document: MacVisioDocument) throws {
        document.makeWindowControllers()
        let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        editor.canvas.beginEditing(document.diagram.page.nodes[0].id)
        let field = try XCTUnwrap(editor.canvas.subviews.compactMap { $0 as? NSTextView }.first)
        field.string = text
        field.didChangeText()
        XCTAssertFalse(document.isCalculating)
    }

    private func makeSaveDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M1-active-text-save-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeControlDocument(nodeCount: Int = 80) -> MacVisioDocument {
        let document = makeDocument(nodeCount: nodeCount)
        var diagram = document.diagram
        diagram.page.nodes[0].x = 100
        diagram.page.nodes[0].y = 100
        diagram.page.nodes[0].formatting.controls = [ShapeControl(name: "Handle", index: 0, cells: [
            "X": ShapeSheetCell(value: "1", formula: "SETATREFEXPR(1)"),
            "Y": ShapeSheetCell(value: "0.5"), "YCon": ShapeSheetCell(value: "1")
        ])]
        diagram.page.nodes[0].formatting.sheet["User.ControlX"] = ShapeSheetCell(value: "1", formula: "Controls.Handle.X")
        document.diagram = DiagramCalculation.recalculate(diagram).diagram
        document.undoManager?.removeAllActions()
        return document
    }

    private func makeDocument(nodeCount: Int = 2200) -> MacVisioDocument {
        _ = NSApplication.shared
        let document = MacVisioDocument()
        document.undoManager?.groupsByEvent = false
        var diagram = Diagram()
        diagram.page.nodes = (0..<nodeCount).map { index in
            var node = DiagramNode(x: Double(index % 30) * 200, y: Double(index / 30) * 100, text: "Shape \(index)")
            node.formatting.sourceShapeID = String(index + 1)
            node.formatting.sheet["User.Offset"] = ShapeSheetCell(value: "0")
            node.formatting.sheet["Width"] = ShapeSheetCell(value: "2", formula: "2+User.Offset")
            return node
        }
        document.diagram = DiagramCalculation.recalculate(diagram).diagram
        document.undoManager?.removeAllActions()
        return document
    }

    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(condition(), "The owned calculation did not finish within the test deadline.")
    }

    private func onMain<Value>(_ body: () throws -> Value) rethrows -> Value {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}

private final class CloseReplyRecorder: NSObject {
    struct Reply {
        let document: NSDocument
        let shouldClose: Bool
        let context: UnsafeMutableRawPointer?
    }
    var replies = [Reply]()
    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        replies.append(Reply(document: document, shouldClose: shouldClose, context: contextInfo))
    }
}
