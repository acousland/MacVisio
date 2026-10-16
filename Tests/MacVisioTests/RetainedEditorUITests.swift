import AppKit
import XCTest

@testable import MacVisio

final class RetainedEditorUITests: XCTestCase {
    func testInspectorReusesControlsAcrossSelectionsAndCachedModes() throws {
        try withEditor { [self] document, editor in
            let pageName = try field("Page name", in: editor.root.inspector)
            editor.canvas.select([document.diagram.page.nodes[0].id])
            let text = try field("Text", in: editor.root.inspector)
            let controls = editor.root.inspector.subviews.map(ObjectIdentifier.init)
            let count = editor.root.inspector.layoutsCreatedCount
            for index in 0..<30 {
                editor.canvas.select([document.diagram.page.nodes[index % 2].id])
                XCTAssertTrue(try field("Text", in: editor.root.inspector) === text)
                XCTAssertEqual(editor.root.inspector.subviews.map(ObjectIdentifier.init), controls)
            }
            XCTAssertEqual(editor.root.inspector.layoutsCreatedCount, count)
            editor.canvas.select([])
            XCTAssertTrue(try field("Page name", in: editor.root.inspector) === pageName)
            editor.canvas.select([document.diagram.page.nodes[0].id])
            XCTAssertTrue(try field("Text", in: editor.root.inspector) === text)
            XCTAssertEqual(editor.root.inspector.layoutsCreatedCount, 2)
        }
    }

    func testMixedPropertiesAreExplicitAndUntouchedActionsDoNotCommit() throws {
        try withEditor { [self] document, editor in
            editor.canvas.select(Set(document.diagram.page.nodes.map(\.id)))
            let inspector = editor.root.inspector
            let text = try field("Text", in: inspector)
            let x = try field("X", in: inspector)
            XCTAssertEqual(text.stringValue, "")
            XCTAssertEqual(text.placeholderString, "Mixed")
            XCTAssertEqual(x.placeholderString, "Mixed")
            let bold = try XCTUnwrap(
                inspector.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Bold text" })
            XCTAssertEqual(bold.state, .mixed)
            let fill = try XCTUnwrap(
                inspector.subviews.compactMap { $0 as? MixedColorWell }.first {
                    $0.identifier?.rawValue == "Fill"
                })
            XCTAssertTrue(fill.isMixed)
            let alignment = try XCTUnwrap(
                inspector.subviews.compactMap { $0 as? NSPopUpButton }.first {
                    $0.itemTitles.contains("Left aligned")
                })
            XCTAssertEqual(alignment.titleOfSelectedItem, "Mixed")
            XCTAssertEqual(alignment.selectedItem?.isEnabled, false)

            let original = document.diagram
            let revision = document.revision
            document.undoManager?.removeAllActions()
            try sendAction(text)
            try sendAction(x)
            try sendAction(alignment)
            XCTAssertEqual(document.diagram, original)
            XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.undoManager?.canUndo ?? false)

            document.undoManager?.beginUndoGrouping()
            text.stringValue = "Common text"
            try sendAction(text)
            document.undoManager?.endUndoGrouping()
            XCTAssertTrue(document.diagram.page.nodes.allSatisfy { $0.text == "Common text" })
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, original)

            document.undoManager?.beginUndoGrouping()
            fill.color = NSColor(hex: "#112233")
            try sendAction(fill)
            document.undoManager?.endUndoGrouping()
            XCTAssertFalse(fill.isMixed)
            XCTAssertTrue(document.diagram.page.nodes.allSatisfy { $0.fill == "#112233" })
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, original)
        }
    }

    func testInspectorRefreshPreservesActiveFieldEditor() throws {
        try withEditor { [self] document, editor in
            editor.canvas.select([document.diagram.page.nodes[0].id])
            let text = try field("Text", in: editor.root.inspector)
            XCTAssertTrue(editor.window!.makeFirstResponder(text))
            let fieldEditor = try XCTUnwrap(text.currentEditor())
            fieldEditor.string = "Uncommitted typing"
            editor.root.inspector.refresh()
            XCTAssertTrue(try field("Text", in: editor.root.inspector) === text)
            XCTAssertTrue(text.currentEditor() === fieldEditor)
            XCTAssertEqual(fieldEditor.string, "Uncommitted typing")
            editor.window?.makeFirstResponder(editor.canvas)
        }
    }

    func testPageButtonsSurviveLayoutRenameAndActivationAndRemoveDeletedPages() throws {
        try withEditor { [self] document, editor in
            editor.root.refreshPages()
            let first = try tab(document.diagram.pages[0].id, editor)
            let second = try tab(document.diagram.pages[1].id, editor)
            let count = editor.root.pageButtonsCreatedCount
            for _ in 0..<20 {
                editor.root.layout()
                editor.root.refreshPages()
            }
            XCTAssertTrue(try tab(document.diagram.pages[0].id, editor) === first)
            XCTAssertEqual(editor.root.pageButtonsCreatedCount, count)
            document.diagram.pages[0].name = "Renamed"
            document.activatePage(document.diagram.pages[1].id)
            editor.root.refreshPages()
            XCTAssertTrue(try tab(document.diagram.pages[0].id, editor) === first)
            XCTAssertEqual(first.title, "Renamed")
            XCTAssertFalse(first.isCurrent)
            XCTAssertTrue(second.isCurrent)
            document.diagram.pages.removeFirst()
            editor.root.refreshPages()
            XCTAssertNil(first.superview)
            XCTAssertTrue(try tab(document.diagram.pages[0].id, editor) === second)
            XCTAssertEqual(editor.root.pageButtonsCreatedCount, count)
        }
    }

    func testStencilLayoutAndFilteringReuseNativeAndMasterRows() throws {
        try withEditor { _, editor in
            let panel = editor.root.stencil
            let definition = StencilDefinition(
                name: "Reusable", family: "Test", fragment: DiagramPage(nodes: [DiagramNode()]))
            editor.stencils = [definition]
            panel.refreshCategories()
            let card = try XCTUnwrap(panel.list.subviews.compactMap { $0 as? MasterStencilCard }.first)
            let rectangle = try XCTUnwrap(
                panel.list.subviews.compactMap { $0 as? StencilCard }.first { $0.kind == .rectangle })
            let count = panel.cardsCreatedCount
            for _ in 0..<30 { panel.layout() }
            XCTAssertEqual(panel.cardsCreatedCount, count)
            XCTAssertTrue(card.superview === panel.list)
            panel.search.stringValue = "No match"
            panel.rebuild()
            XCTAssertTrue(panel.list.subviews.isEmpty)
            panel.search.stringValue = ""
            panel.rebuild()
            XCTAssertTrue(card.superview === panel.list)
            XCTAssertTrue(rectangle.superview === panel.list)
            XCTAssertEqual(panel.cardsCreatedCount, count)
            editor.stencils[0].name = "Updated"
            panel.rebuild()
            XCTAssertEqual(card.definition.name, "Updated")
            XCTAssertEqual(panel.cardsCreatedCount, count)
            editor.stencils = []
            panel.rebuild()
            XCTAssertNil(card.superview)
        }
    }

    func testPageViewStateRestoresZoomSelectionAndPrunesDeletedShapeIDs() throws {
        try withEditor { [self] document, editor in
            let firstID = document.diagram.pages[0].id
            let secondID = document.diagram.pages[1].id
            let selected = document.diagram.page.nodes[0].id
            editor.canvas.select([selected])
            editor.canvas.setZoom(1.4)
            editor.root.capturePageViewState()
            document.activatePage(secondID)
            editor.refresh()
            XCTAssertFalse(editor.root.restorePageViewState(for: secondID))
            editor.canvas.setZoom(0.6)
            editor.root.capturePageViewState()
            document.activatePage(firstID)
            editor.refresh()
            XCTAssertTrue(editor.root.restorePageViewState(for: firstID))
            XCTAssertEqual(editor.canvas.zoom, 1.4, accuracy: 0.0001)
            XCTAssertEqual(editor.canvas.selectedNodes, [selected])
            document.activatePage(secondID)
            editor.refresh()
            XCTAssertTrue(editor.root.restorePageViewState(for: secondID))
            XCTAssertEqual(editor.canvas.zoom, 0.6, accuracy: 0.0001)
            document.diagram.pages[0].nodes.removeAll { $0.id == selected }
            document.activatePage(firstID)
            editor.refresh()
            XCTAssertTrue(editor.root.restorePageViewState(for: firstID))
            XCTAssertTrue(editor.canvas.selectedNodes.isEmpty)
        }
    }

    func testPageSwitchCommitsActivePageNameBeforeChangingPages() throws {
        try withEditor { [self] document, editor in
            let firstID = document.diagram.pages[0].id
            let secondID = document.diagram.pages[1].id
            let name = try field("Page name", in: editor.root.inspector)
            XCTAssertTrue(editor.window!.makeFirstResponder(name))
            let fieldEditor = try XCTUnwrap(name.currentEditor())
            fieldEditor.string = "Edited original page"
            fieldEditor.didChangeText()

            editor.switchPage(secondID)

            XCTAssertEqual(document.diagram.activePageID, secondID)
            XCTAssertEqual(document.diagram.pages.first { $0.id == firstID }?.name, "Edited original page")
            XCTAssertEqual(document.diagram.pages.first { $0.id == secondID }?.name, "Second")
            XCTAssertEqual(try field("Page name", in: editor.root.inspector).stringValue, "Second")
            XCTAssertTrue(editor.window?.firstResponder === editor.canvas)
        }
    }

    func testPageSwitchCommitsActiveNodeTextToOriginalSelection() throws {
        try withEditor { [self] document, editor in
            let firstID = document.diagram.pages[0].id
            let secondID = document.diagram.pages[1].id
            let nodeID = document.diagram.page.nodes[0].id
            document.diagram.pages[1].nodes = [DiagramNode(text: "Destination unchanged")]
            editor.refresh()
            editor.canvas.select([nodeID])
            let text = try field("Text", in: editor.root.inspector)
            XCTAssertTrue(editor.window!.makeFirstResponder(text))
            let fieldEditor = try XCTUnwrap(text.currentEditor())
            fieldEditor.string = "Edited original shape"
            fieldEditor.didChangeText()

            editor.switchPage(secondID)

            XCTAssertEqual(document.diagram.activePageID, secondID)
            XCTAssertEqual(
                document.diagram.pages.first { $0.id == firstID }?.nodes.first { $0.id == nodeID }?.text,
                "Edited original shape")
            XCTAssertEqual(document.diagram.page.nodes[0].text, "Destination unchanged")
            XCTAssertTrue(editor.canvas.selectedNodes.isEmpty)
            XCTAssertEqual(try field("Page name", in: editor.root.inspector).stringValue, "Second")

            editor.switchPage(firstID)
            XCTAssertEqual(editor.canvas.selectedNodes, [nodeID])
            XCTAssertEqual(try field("Text", in: editor.root.inspector).stringValue, "Edited original shape")
        }
    }

    func testSaveCapturesActiveInspectorPageNameBeforeSnapshot() throws {
        try withEditor { [self] document, editor in
            let name = try field("Page name", in: editor.root.inspector)
            XCTAssertTrue(editor.window!.makeFirstResponder(name))
            let fieldEditor = try XCTUnwrap(name.currentEditor())
            fieldEditor.string = "Saved inspector page"
            fieldEditor.didChangeText()

            let persisted = try saveInspectorSnapshot(document)

            XCTAssertEqual(persisted.page.name, "Saved inspector page")
            XCTAssertEqual(document.diagram.page.name, persisted.page.name)
            XCTAssertTrue(editor.window?.firstResponder === editor.canvas)
        }
    }

    func testSaveCapturesActiveInspectorNodeTextBeforeSnapshot() throws {
        try withEditor { [self] document, editor in
            let nodeID = document.diagram.page.nodes[0].id
            editor.canvas.select([nodeID])
            let text = try field("Text", in: editor.root.inspector)
            XCTAssertTrue(editor.window!.makeFirstResponder(text))
            let fieldEditor = try XCTUnwrap(text.currentEditor())
            fieldEditor.string = "Saved inspector shape"
            fieldEditor.didChangeText()

            let persisted = try saveInspectorSnapshot(document)

            XCTAssertEqual(persisted.page.nodes.first { $0.id == nodeID }?.text, "Saved inspector shape")
            XCTAssertEqual(
                document.diagram.page.nodes.first { $0.id == nodeID }?.text, "Saved inspector shape")
            XCTAssertEqual(editor.canvas.selectedNodes, [nodeID])
        }
    }

    private func saveInspectorSnapshot(_ document: MacVisioDocument) throws -> Diagram {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacVisio-inspector-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("inspector.macvisio")
        var completion: Result<Void, Error>?
        document.save(to: url, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) { error in
            completion = error.map { .failure($0) } ?? .success(())
        }
        let deadline = Date().addingTimeInterval(10)
        while completion == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        try XCTUnwrap(completion, "Inspector save did not finish").get()
        return try JSONDecoder().decode(Diagram.self, from: Data(contentsOf: url))
    }

    private func field(_ key: String, in inspector: InspectorPanel) throws -> NSTextField {
        try XCTUnwrap(
            inspector.subviews.compactMap { $0 as? NSTextField }.first { $0.identifier?.rawValue == key })
    }
    private func tab(_ id: UUID, _ editor: EditorWindowController) throws -> PageTabButton {
        try XCTUnwrap(
            editor.root.pageStrip.subviews.compactMap { $0 as? PageTabButton }.first {
                $0.identifier?.rawValue == id.uuidString
            })
    }
    private func sendAction(_ control: NSControl) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(control.action), to: control.target, from: control))
    }
    private func withEditor(_ body: @escaping (MacVisioDocument, EditorWindowController) throws -> Void)
        throws
    {
        let work = {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            var a = DiagramNode(x: 123.49, y: 40, text: "Alpha")
            var b = DiagramNode(x: 500, y: 200, text: "Beta")
            a.bold = true
            a.fill = "#AA0000"
            a.formatting.alignment = .left
            b.fill = "#00AA00"
            b.formatting.alignment = .right
            var diagram = Diagram()
            diagram.pages[0].nodes = [a, b]
            diagram.pages.append(DiagramPage(name: "Second"))
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
        if Thread.isMainThread { try work() } else { try DispatchQueue.main.sync(execute: work) }
    }
}
