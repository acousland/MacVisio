import AppKit
import XCTest
@testable import MacVisio

final class WelcomeScreenTests: XCTestCase {
    func testRefreshBuildsHomeNewAndOpenWithPinnedRecentRows() throws {
        try onMain {
            _ = NSApplication.shared
            let drawing = recentDrawing(isPinned: true)
            let controller = makeController()
            defer { controller.close() }

            controller.refresh(recents: [drawing], section: .home, canGoBack: false)
            controller.showWindow(nil)
            let window = try XCTUnwrap(controller.window)
            window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: 1000, height: 680)), display: true)
            window.contentView?.layoutSubtreeIfNeeded()

            XCTAssertEqual(window.minSize.width, 1000)
            XCTAssertEqual(window.minSize.height, 680)
            XCTAssertGreaterThan(window.contentView?.bounds.width ?? 0, 0)
            XCTAssertGreaterThan(window.contentView?.bounds.height ?? 0, 0)
            assertBodyAtTop(in: window)
            XCTAssertTrue(labels(in: window).contains("Home"))
            XCTAssertTrue(labels(in: window).contains(drawing.title))
            XCTAssertNotNil(button(identifier: "welcomePin.\(drawing.url.path)", in: window))
            XCTAssertNotNil(button(identifier: "welcomeTemplate.blank", in: window))

            controller.refresh(recents: [drawing], section: .new, canGoBack: false)
            window.contentView?.layoutSubtreeIfNeeded()
            assertBodyAtTop(in: window)
            XCTAssertTrue(labels(in: window).contains("New diagram"))
            XCTAssertNotNil(button(identifier: "welcomeTemplate.swimlane", in: window))

            controller.refresh(recents: [drawing], section: .open, canGoBack: false)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(labels(in: window).contains("Open"))
            XCTAssertTrue(labels(in: window).contains("Browse files"))
            XCTAssertNotNil(button(identifier: "welcomeRecent.\(drawing.url.path)", in: window))
            assertBodyAtTop(in: window)
        }
    }

    func testTemplateRecentAndPinActionsDispatchTheirModels() throws {
        try onMain {
            _ = NSApplication.shared
            let drawing = recentDrawing(isPinned: false)
            var createdTemplate: DiagramTemplate?
            var openedURL: URL?
            var pinnedURL: URL?
            let controller = makeController(
                onNew: { createdTemplate = $0 },
                onRecent: { openedURL = $0 },
                onPin: { pinnedURL = $0 }
            )
            defer { controller.close() }
            controller.showWindow(nil)

            let window = try XCTUnwrap(controller.window)
            controller.refresh(recents: [drawing], section: .new, canGoBack: false)
            try sendAction(from: XCTUnwrap(button(identifier: "welcomeTemplate.flowchart", in: window)))
            XCTAssertEqual(createdTemplate?.rawValue, DiagramTemplate.flowchart.rawValue)

            controller.refresh(recents: [drawing], section: .home, canGoBack: false)
            try sendAction(from: XCTUnwrap(button(identifier: "welcomeRecent.\(drawing.url.path)", in: window)))
            try sendAction(from: XCTUnwrap(button(identifier: "welcomePin.\(drawing.url.path)", in: window)))
            XCTAssertEqual(openedURL, drawing.url)
            XCTAssertEqual(pinnedURL, drawing.url)
        }
    }

    private func makeController(onNew: @escaping (DiagramTemplate) -> Void = { _ in },
                                onRecent: @escaping (URL) -> Void = { _ in },
                                onPin: @escaping (URL) -> Void = { _ in }) -> WelcomeWindowController {
        WelcomeWindowController(
            onNew: onNew,
            onOpen: {},
            onRecent: onRecent,
            onPin: onPin,
            onBack: {},
            onSave: {},
            onSaveAs: {},
            onClose: {}
        )
    }

    private func recentDrawing(isPinned: Bool) -> RecentDrawing {
        let url = URL(fileURLWithPath: "/tmp/MacVisio Welcome Screen Test.vsdx")
        return RecentDrawing(url: url, title: "Annual plan.vsdx", location: "Projects / Planning", isPinned: isPinned)
    }

    private func button(identifier: String, in window: NSWindow) -> NSButton? {
        descendants(of: window.contentView ?? NSView())
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == identifier }
    }

    private func labels(in window: NSWindow) -> Set<String> {
        Set(descendants(of: window.contentView ?? NSView()).compactMap { ($0 as? NSTextField)?.stringValue })
    }

    private func assertBodyAtTop(in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        guard let scroll = descendants(of: window.contentView ?? NSView()).compactMap({ $0 as? NSScrollView }).first,
              let documentView = scroll.documentView else {
            XCTFail("Welcome body scroll view should be present", file: file, line: line)
            return
        }
        XCTAssertEqual(documentView.bounds.width, scroll.contentView.bounds.width, accuracy: 1, file: file, line: line)
        if let first = (documentView as? NSStackView)?.arrangedSubviews.first {
            let visibleRect = first.convert(first.bounds, to: scroll.contentView)
            XCTAssertEqual(scroll.contentView.isFlipped ? visibleRect.minY : visibleRect.maxY, scroll.contentView.isFlipped ? scroll.contentView.bounds.minY : scroll.contentView.bounds.maxY, accuracy: 1, file: file, line: line)
        }
        let expectedY = documentView.isFlipped ? CGFloat.zero : max(documentView.bounds.height - scroll.contentView.bounds.height, 0)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, expectedY, accuracy: 1, file: file, line: line)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func sendAction(from control: NSControl, file: StaticString = #filePath, line: UInt = #line) throws {
        let action = try XCTUnwrap(control.action, file: file, line: line)
        XCTAssertTrue(NSApp.sendAction(action, to: control.target, from: control), file: file, line: line)
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
