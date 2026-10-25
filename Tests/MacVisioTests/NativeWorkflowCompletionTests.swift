import AppKit
import XCTest
@testable import MacVisio

final class NativeWorkflowCompletionTests: XCTestCase {
    func testTemplateChooserHasNativeKeyboardFocusAndReturnCreatesTemplate() throws {
        _ = NSApplication.shared
        var created: DiagramTemplate?
        let welcome = WelcomeWindowController(onNew: { created = $0 }, onOpen: {}, onRecent: { _ in }, onPin: { _ in }, onBack: {})
        defer { welcome.close() }
        welcome.refresh(recents: [], section: .new, canGoBack: false)
        welcome.showWindow(nil)
        let window = try XCTUnwrap(welcome.window)
        let first = try XCTUnwrap(window.firstResponder as? NSButton)
        XCTAssertEqual(first.identifier?.rawValue, "welcomeTemplate.blank")
        XCTAssertTrue(first.canBecomeKeyView)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        window.sendEvent(event)
        XCTAssertEqual(created, .blank)
    }
    func testRecentRowExposesLocateAndRemoveWithoutReadingOrDeletingSource() throws {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: "/missing/M2 owned recent fixture.vsdx")
        var located: URL?, removed: URL?
        let home = WelcomeWindowController(onNew: { _ in }, onOpen: {}, onRecent: { _ in }, onPin: { _ in }, onBack: {},
                                           onLocate: { located = $0 }, onRemove: { removed = $0 })
        defer { home.close() }
        home.refresh(recents: [.init(url: url, title: "Moved drawing", location: "/missing", isPinned: true)], section: .home, canGoBack: false)
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        let root = try XCTUnwrap(home.window?.contentView)
        let popup = try XCTUnwrap(views(root).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "welcomeRecentActions.\(url.path)" })
        for title in ["Locate…", "Remove from Recents"] {
            let item = try XCTUnwrap(popup.itemArray.first { $0.title == title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(located, url); XCTAssertEqual(removed, url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReadOnlyOriginalRefusesDirectOverwriteButAllowsSeparateCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M2-readonly-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("Original.macvisio"), copy = directory.appendingPathComponent("Copy.macvisio")
        var diagram = Diagram(); diagram.page.nodes = [DiagramNode(text: "Original")]
        let bytes = try JSONEncoder().encode(diagram); try bytes.write(to: original)
        let document = try MacVisioDocument(contentsOf: original, ofType: MacVisioDocument.nativeType)
        defer { document.close() }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: original.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: original.path) }
        var edited = document.diagram; edited.page.nodes[0].text = "Changed"
        document.replace(with: edited, action: "Edit")
        XCTAssertThrowsError(try document.write(to: original, ofType: MacVisioDocument.nativeType)) { error in
            guard case DocumentWritePolicy.Failure.readOnlySource = error else { return XCTFail("Unexpected error: \(error)") }
        }
        try document.write(to: copy, ofType: MacVisioDocument.nativeType)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try JSONDecoder().decode(Diagram.self, from: Data(contentsOf: copy)).page.nodes[0].text, "Changed")
    }

    func testBranchingSubprocessAndOffPageLinkSurvivePublicReadbackAndRename() throws {
        var diagram = Diagram(); var target = DiagramPage(name: "Destination")
        target.nodes = [DiagramNode(text: "Target")]
        let decision = DiagramNode(kind: .diamond, x: 40, y: 40, text: "Approved?")
        let process = BasicFlowchart.subprocess(at: CGPoint(x: 300, y: 40))
        let link = BasicFlowchart.offPage(to: target, at: CGPoint(x: 300, y: 220))
        diagram.page.nodes = [decision, process, link]
        var yes = DiagramEdge(source: decision.id, target: process.id); yes.label = "Yes"
        var no = DiagramEdge(source: decision.id, target: link.id); no.label = "No"
        diagram.page.edges = [yes, no]; diagram.pages.append(target)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M2-flow-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Branch.vsdx")
        try VisioFormat.write(diagram, to: url)
        var parts = try VisioPackage.read(url); parts.removeValue(forKey: "macvisio/document.json")
        NativeMetadataStorage.removeSegments(from: &parts); try VisioPackage.write(parts, to: url)
        var imported = try VisioFormat.read(from: url).diagram
        XCTAssertEqual(imported.pages.count, 2)
        XCTAssertEqual(Set(imported.page.edges.map(\.label)), ["Yes", "No"])
        let importedLink = try XCTUnwrap(imported.page.nodes.first(where: BasicFlowchart.isOffPage))
        let targetID = try XCTUnwrap(BasicFlowchart.targetID(for: importedLink, in: imported))
        XCTAssertEqual(imported.pages.first { $0.id == targetID }?.name, "Destination")
        let previous = imported
        imported.pages[1].name = "Renamed destination"
        BasicFlowchart.refreshLinkNames(in: &imported, previous: previous)
        let renamedLink = try XCTUnwrap(imported.page.nodes.first(where: BasicFlowchart.isOffPage))
        XCTAssertEqual(BasicFlowchart.targetID(for: renamedLink, in: imported), targetID)
        XCTAssertEqual(renamedLink.formatting.hyperlinks.first?.subAddress, "Renamed destination")
        let document = MacVisioDocument(); document.diagram = imported
        let editor = EditorWindowController(document: document); document.addWindowController(editor)
        defer { editor.close(); document.close() }
        editor.canvas.select([renamedLink.id]); editor.followHyperlink(nil)
        XCTAssertEqual(document.diagram.activePageID, targetID)
        XCTAssertNotEqual(document.diagram.activePageID, previous.activePageID)
        XCTAssertTrue(imported.page.nodes.first { $0.text == "Subprocess" }?.formatting.paths.isEmpty == false)
    }

    func testDocumentWidePreviewCancelStaleRefusalApplyAndSingleUndo() throws {
        let document = MacVisioDocument(); var diagram = Diagram()
        diagram.page.nodes = [DiagramNode(x: 51, y: 53, text: "A")]
        var second = DiagramPage(name: "Second"); second.nodes = [DiagramNode(x: 91, y: 93, text: "B")]
        diagram.pages.append(second); document.diagram = diagram
        let editor = EditorWindowController(document: document); document.addWindowController(editor)
        defer { editor.close(); document.close() }
        let proposal = try DrawingOperationProposal.grid(document.diagram, stateID: document.stateID)
        XCTAssertEqual(proposal.changedShapes, 2)
        XCTAssertEqual(document.diagram, diagram, "Creating/cancelling a preview does not install proposed values.")
        XCTAssertTrue(editor.applyDrawingProposal(proposal))
        XCTAssertEqual(document.diagram.pages[0].nodes[0].x, 40)
        XCTAssertEqual(document.diagram.pages[1].nodes[0].x, 80)
        document.undoManager?.undo()
        XCTAssertEqual(document.diagram.pages.map { $0.nodes.map(\.rect) }, diagram.pages.map { $0.nodes.map(\.rect) })
        var changed = document.diagram; changed.title = "Newer edit"
        document.replace(with: changed, action: "Rename")
        XCTAssertFalse(editor.applyDrawingProposal(proposal))
        XCTAssertEqual(document.diagram.title, "Newer edit")
    }

    func testNarrowEditorKeepsInspectorAndCanvasVisibleAndCanRevealLibrary() throws {
        let document = MacVisioDocument(); let editor = EditorWindowController(document: document)
        document.addWindowController(editor); defer { editor.root.showsFormatPane = false; editor.close(); document.close() }
        // The Format Shape pane is hidden until opened, as in Visio; opened, it keeps its width.
        editor.root.showsFormatPane = true
        editor.root.frame = CGRect(x: 0, y: 0, width: 760, height: 560)
        editor.root.layoutSubtreeIfNeeded()
        XCTAssertTrue(editor.root.stencil.isHidden)
        XCTAssertGreaterThan(editor.scrollView.frame.width, 400)
        XCTAssertGreaterThan(editor.root.inspectorScroll.frame.width, 240)
        editor.toggleShapeLibrary(nil); editor.root.layoutSubtreeIfNeeded()
        XCTAssertFalse(editor.root.stencil.isHidden)
        XCTAssertGreaterThan(editor.scrollView.frame.width, 250)
    }
}
