import AppKit
import XCTest
@testable import MacVisio

final class EditorChromeTests: XCTestCase {
    func testRibbonToolButtonsChangeCanvasTool() throws {
        try withEditor { _, editor in
            let connector = try XCTUnwrap(button(identifier: "tool_1", in: editor.root.ribbon))
            connector.performClick(nil)
            XCTAssertEqual(editor.canvas.tool, .connector)
            XCTAssertEqual(connector.state, .on)

            let text = try XCTUnwrap(button(identifier: "tool_2", in: editor.root.ribbon))
            text.performClick(nil)
            XCTAssertEqual(editor.canvas.tool, .text)
            XCTAssertEqual(text.state, .on)
            XCTAssertEqual(connector.state, .off)
        }
    }

    func testRibbonBoldButtonChangesSelectedShapeAndUndoRestoresIt() throws {
        try withEditor(diagramWithShape()) { document, editor in
            let node = try XCTUnwrap(document.diagram.page.nodes.first)
            editor.canvas.select([node.id])
            document.undoManager?.removeAllActions()
            let before = document.diagram
            let bold = try XCTUnwrap(button(identifier: "fontBold", in: editor.root.ribbon))
            XCTAssertTrue(bold.isEnabled)

            document.undoManager?.beginUndoGrouping()
            bold.performClick(nil)
            document.undoManager?.endUndoGrouping()

            XCTAssertTrue(try XCTUnwrap(document.diagram.page.nodes.first).bold)
            XCTAssertEqual(bold.state, .on)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, before)
        }
    }

    func testRibbonTabsPreserveTheDocument() throws {
        try withEditor(diagramWithShape()) { document, editor in
            let before = document.diagram
            let svgBefore = DiagramDrawing.svg(document.diagram.scene())
            let viewTab = try XCTUnwrap(button(identifier: "tab_View", in: editor.root.ribbon))
            viewTab.performClick(nil)
            XCTAssertEqual(viewTab.state, .on)
            XCTAssertEqual(document.diagram, before)

            let homeTab = try XCTUnwrap(button(identifier: "tab_Home", in: editor.root.ribbon))
            homeTab.performClick(nil)
            XCTAssertEqual(homeTab.state, .on)
            XCTAssertEqual(document.diagram, before)
            XCTAssertEqual(DiagramDrawing.svg(document.diagram.scene()), svgBefore)
        }
    }

    func testAppearanceControlSwitchesWindowThemeWithoutChangingDocumentOrSVG() throws {
        try withEditor(diagramWithShape()) { document, editor in
            let ribbon = editor.root.ribbon
            // As in Visio, the Office theme is chosen in File > Account.
            editor.showBackstage(nil)
            let backstage = try XCTUnwrap(editor.root.subviews.compactMap { $0 as? BackstageView }.first)
            backstage.show("Account")
            let appearance = try XCTUnwrap(popup(identifier: "appearance", in: backstage))
            let before = document.diagram
            let svgBefore = DiagramDrawing.svg(document.diagram.scene())

            // The argument domain keeps the test preference volatile. The
            // callback reads that domain and applies the selected appearance.
            ribbon.onAppearanceChanged = { _ in EditorAppearance.apply() }
            setVolatileAppearance("light")
            appearance.selectItem(withTitle: "Light")
            try sendAction(from: appearance)
            XCTAssertEqual(editor.window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .aqua)

            setVolatileAppearance("dark")
            appearance.selectItem(withTitle: "Dark")
            try sendAction(from: appearance)
            XCTAssertEqual(editor.window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), .darkAqua)

            XCTAssertEqual(document.diagram, before)
            XCTAssertEqual(DiagramDrawing.svg(document.diagram.scene()), svgBefore)
        }
    }

    func testSelectionControlsDisableAndReenableWithShapeSelection() throws {
        try withEditor(diagramWithShape()) { _, editor in
            let ribbon = editor.root.ribbon
            let bold = try XCTUnwrap(button(identifier: "fontBold", in: ribbon))
            let fill = try XCTUnwrap(colorWell(identifier: "fillColor", in: ribbon))
            XCTAssertFalse(bold.isEnabled)
            XCTAssertFalse(fill.isEnabled)

            let node = try XCTUnwrap(editor.diagramDocument.diagram.page.nodes.first)
            editor.canvas.select([node.id])
            XCTAssertTrue(bold.isEnabled)
            XCTAssertTrue(fill.isEnabled)
        }
    }

    private func diagramWithShape() -> Diagram {
        var diagram = Diagram()
        diagram.title = "Editor chrome test"
        diagram.page.nodes = [DiagramNode(x: 120, y: 90, text: "Review")]
        return diagram
    }

    private func button(identifier: String, in view: NSView) -> NSButton? {
        descendants(of: view).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier }
    }

    private func popup(identifier: String, in view: NSView) -> NSPopUpButton? {
        descendants(of: view).compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == identifier }
    }

    private func colorWell(identifier: String, in view: NSView) -> NSColorWell? {
        descendants(of: view).compactMap { $0 as? NSColorWell }.first { $0.identifier?.rawValue == identifier }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func setVolatileAppearance(_ value: String) {
        var domain = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        domain[EditorAppearance.preferenceKey] = value
        UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
    }

    private func sendAction(from control: NSControl, file: StaticString = #filePath, line: UInt = #line) throws {
        let action = try XCTUnwrap(control.action, file: file, line: line)
        XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control), file: file, line: line)
    }

    private func withEditor(_ diagram: Diagram = Diagram(), _ body: (MacVisioDocument, EditorWindowController) throws -> Void) throws {
        try onMain {
            _ = NSApplication.shared
            let defaults = UserDefaults.standard
            let originalArgumentDomain = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            var testArgumentDomain = originalArgumentDomain
            testArgumentDomain[EditorAppearance.preferenceKey] = "dark"
            defaults.setVolatileDomain(testArgumentDomain, forName: UserDefaults.argumentDomain)
            let originalApplicationAppearance = NSApp.appearance
            defer {
                defaults.setVolatileDomain(originalArgumentDomain, forName: UserDefaults.argumentDomain)
                NSApp.appearance = originalApplicationAppearance
            }

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
