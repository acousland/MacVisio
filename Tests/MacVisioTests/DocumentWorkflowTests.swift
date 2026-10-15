import AppKit
import XCTest
@testable import MacVisio

final class DocumentWorkflowTests: XCTestCase {
    func testStartShowsHomeWithoutCreatingAnUntitledDrawing() throws {
        try withWorkflow { delegate, workflow, originalIDs in
            guard workflow.drawings.isEmpty else { throw XCTSkip("This workflow test needs an empty document controller.") }

            workflow.start()

            XCTAssertEqual(Set(NSDocumentController.shared.documents.map { ObjectIdentifier($0) }), originalIDs)
            XCTAssertTrue(workflow.drawings.isEmpty)
            XCTAssertTrue(workflow.welcome?.window?.isVisible == true)
            XCTAssertTrue(welcomeLabels(workflow.welcome).contains("Home"))

            workflow.showWelcome(.new)
            XCTAssertTrue(welcomeLabels(workflow.welcome).contains("New diagram"))
            delegate.openDocument(nil)
            XCTAssertTrue(welcomeLabels(workflow.welcome).contains("Open"))
            XCTAssertTrue(workflow.drawings.isEmpty)
            XCTAssertEqual(Set(NSDocumentController.shared.documents.map { ObjectIdentifier($0) }), originalIDs)
        }
    }

    func testPinningInOpenSectionKeepsSidebarNavigation() throws {
        try withWorkflow { _, workflow, _ in
            let url = URL(fileURLWithPath: "/tmp/Workflow Navigation.vsdx")
            workflow.recentStore.record(url)
            workflow.showWelcome(.home)
            let view = try XCTUnwrap(workflow.welcome?.window?.contentView)
            func click(_ identifier: String) throws {
                let button = try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier })
                let action = try XCTUnwrap(button.action)
                XCTAssertTrue(NSApp.sendAction(action, to: button.target, from: button))
            }
            try click("welcomeSection.open")
            try click("welcomePin." + url.path)
            XCTAssertTrue(welcomeLabels(workflow.welcome).contains("Open"))
            XCTAssertTrue(welcomeLabels(workflow.welcome).contains("Browse files"))
            XCTAssertTrue(workflow.recents.first?.isPinned == true)
        }
    }

    func testClosingOneDrawingKeepsTheOtherAndClosingLastReturnsHome() throws {
        try withWorkflow { delegate, workflow, _ in
            guard workflow.drawings.isEmpty else { throw XCTSkip("This workflow test needs an empty document controller.") }
            let first = delegate.newDiagram(template: .blank)
            let second = delegate.newDiagram(template: .flowchart)
            XCTAssertFalse(first === second)
            XCTAssertFalse(first.windowControllers.first?.window === second.windowControllers.first?.window)
            XCTAssertEqual(workflow.drawings.count, 2)
            workflow.start()
            XCTAssertNil(workflow.welcome)

            first.close()
            drainMainQueue()
            XCTAssertFalse(workflow.drawings.contains { $0 === first })
            XCTAssertTrue(workflow.drawings.contains { $0 === second })
            XCTAssertNil(workflow.welcome, "Closing one of several drawings should leave the remaining drawing open.")

            second.close()
            drainMainQueue()
            XCTAssertTrue(workflow.drawings.isEmpty)
            XCTAssertTrue(workflow.welcome?.window?.isVisible == true, "Closing the final drawing should return to Home.")
            XCTAssertTrue(welcomeLabels(workflow.welcome).contains("Home"))
        }
    }

    func testOpeningNormalizedURLActivatesExistingDocumentAndPreservesCanvasState() throws {
        try withWorkflow { delegate, workflow, _ in
            guard workflow.drawings.isEmpty else { throw XCTSkip("This workflow test needs an empty document controller.") }
            var diagram = Diagram()
            diagram.page.nodes = [DiagramNode(x: 100, y: 80, text: "Selection")]
            let document = MacVisioDocument()
            document.diagram = diagram
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacVisioWorkflow-\(UUID().uuidString)")
                .appendingPathComponent("drawing.macvisio")
            document.fileURL = url
            document.fileType = MacVisioDocument.nativeType
            NSDocumentController.shared.addDocument(document)
            workflow.documentOpened(document, sourceURL: url)
            document.makeWindowControllers()
            document.showWindows()
            drainMainQueue()

            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            let nodeID = try XCTUnwrap(document.diagram.page.nodes.first?.id)
            editor.canvas.setZoom(1.37)
            editor.canvas.select([nodeID])
            let zoom = editor.canvas.zoom
            let selection = editor.canvas.selectedNodes
            let alias = URL(fileURLWithPath:url.deletingLastPathComponent().path + "/nested/../drawing.macvisio")
            XCTAssertNotEqual(alias.path, url.path)
            XCTAssertEqual(RecentDrawingStore.canonical(alias), RecentDrawingStore.canonical(url))

            delegate.open(alias)
            drainMainQueue()

            XCTAssertEqual(workflow.drawings.filter { $0.fileURL.map(RecentDrawingStore.canonical) == RecentDrawingStore.canonical(url) }.count, 1)
            XCTAssertTrue(workflow.activeDrawing === document)
            XCTAssertEqual(editor.canvas.zoom, zoom, accuracy: 0.0001)
            XCTAssertEqual(editor.canvas.selectedNodes, selection)
        }
    }

    func testSwitchingDocumentsPreservesDiagramAndDirtyState() throws {
        try withWorkflow { delegate, workflow, _ in
            guard workflow.drawings.isEmpty else { throw XCTSkip("This workflow test needs an empty document controller.") }
            let first = delegate.newDiagram(template: .blank)
            let second = delegate.newDiagram(template: .flowchart)
            first.diagram.title = "Changed drawing"
            first.updateChangeCount(.changeDone)
            let changedDiagram = first.diagram

            workflow.activate(first)
            XCTAssertTrue(workflow.activeDrawing === first)
            workflow.activate(second)
            XCTAssertTrue(workflow.activeDrawing === second)
            workflow.switchDrawing(forward: false)

            XCTAssertTrue(workflow.activeDrawing === first)
            XCTAssertEqual(first.diagram, changedDiagram)
            XCTAssertTrue(first.isDocumentEdited)
            workflow.switchDrawing(forward: true)
            XCTAssertTrue(workflow.activeDrawing === second)
            XCTAssertEqual(first.diagram, changedDiagram)
            XCTAssertTrue(first.isDocumentEdited)
        }
    }

    func testSwitchMenuTracksActiveDrawingAndRemovesClosedDrawing() throws {
        try withWorkflow { delegate, workflow, _ in
            guard workflow.drawings.isEmpty else { throw XCTSkip("This workflow test needs an empty document controller.") }
            let first = delegate.newDiagram(template: .blank)
            let second = delegate.newDiagram(template: .flowchart)
            workflow.activate(second)
            let menu = workflow.makeSwitchMenu()

            XCTAssertEqual(menu.items.count, 2)
            XCTAssertEqual(menu.items[drawingIndex(first, in: workflow)].state, .off)
            XCTAssertEqual(menu.items[drawingIndex(second, in: workflow)].state, .on)

            workflow.activate(first)
            workflow.menuNeedsUpdate(menu)
            XCTAssertEqual(menu.items[drawingIndex(first, in: workflow)].state, .on)
            XCTAssertEqual(menu.items[drawingIndex(second, in: workflow)].state, .off)

            second.close()
            workflow.menuNeedsUpdate(menu)
            XCTAssertEqual(menu.items.count, 1)
            XCTAssertEqual(menu.items.first?.state, .on)
            XCTAssertTrue(workflow.activeDrawing === first)
        }
    }

    private func drawingIndex(_ document: MacVisioDocument, in workflow: DocumentWorkflow) -> Int {
        workflow.drawings.firstIndex { $0 === document }!
    }

    private func welcomeLabels(_ welcome: WelcomeWindowController?) -> Set<String> {
        guard let view = welcome?.window?.contentView else { return [] }
        return Set(descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
    }

    private func withWorkflow(_ body: (AppDelegate, DocumentWorkflow, Set<ObjectIdentifier>) throws -> Void) throws {
        try onMain {
            _ = NSApplication.shared
            let controller = NSDocumentController.shared
            let originalIDs = Set(controller.documents.map { ObjectIdentifier($0) })
            let suite = "MacVisioDocumentWorkflowTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let delegate = AppDelegate()
            let workflow = DocumentWorkflow(delegate: delegate, recentStore: RecentDrawingStore(defaults: defaults), recordsSystemRecents: false)
            delegate.workflow = workflow
            defer {
                workflow.isTerminating = true
                for document in controller.documents.compactMap({ $0 as? MacVisioDocument }) where !originalIDs.contains(ObjectIdentifier(document)) {
                    document.windowControllers.forEach { $0.window?.orderOut(nil) }
                    document.close()
                    controller.removeDocument(document)
                }
                workflow.welcome?.close()
                defaults.removePersistentDomain(forName: suite)
            }
            try body(delegate, workflow, originalIDs)
        }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
