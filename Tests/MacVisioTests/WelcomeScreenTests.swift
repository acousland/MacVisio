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
            window.setContentSize(WelcomeWindowLayout.minimumContentSize)
            window.contentView?.layoutSubtreeIfNeeded()

            XCTAssertEqual(window.contentMinSize.width, 480)
            XCTAssertEqual(window.contentMinSize.height, 440)
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

    func testWindowFrameFitsSmallScreensAndOffsetDisplays() {
        let oversized = NSRect(x: 100, y: 200, width: 1600, height: 1000)
        for screen in [NSRect(x: 0, y: 30, width: 800, height: 570),
                       NSRect(x: -1024, y: 100, width: 1024, height: 700)] {
            let frame = WelcomeWindowLayout.frame(oversized, fitting: screen)
            XCTAssertTrue(screen.insetBy(dx: 16, dy: 16).contains(frame))
        }
        XCTAssertEqual(WelcomeWindowLayout.templateColumns(for: 732), 3)
        XCTAssertEqual(WelcomeWindowLayout.templateColumns(for: 432), 2)
        XCTAssertEqual(WelcomeWindowLayout.templateColumns(for: 320), 1)
    }

    func testLongRecentPathsAndAllSectionsStayWithinCompactWindow() throws {
        try onMain {
            _ = NSApplication.shared
            let name = String(repeating: "A very long project name ", count: 12) + ".vsdx"
            let folder = String(repeating: "Projects / Planning / ", count: 12)
            let drawing = RecentDrawing(url: URL(fileURLWithPath: "/tmp/" + name), title: name,
                                        location: folder, isPinned: true)
            let controller = makeController()
            defer { controller.close() }
            controller.showWindow(nil)
            let window = try XCTUnwrap(controller.window)
            for width: CGFloat in [780, 480, 780] {
                window.setContentSize(NSSize(width: width, height: 440))
                for section: WelcomeSection in [.home, .new, .open] {
                    controller.refresh(recents: [drawing], section: section, canGoBack: true)
                    window.contentView?.layoutSubtreeIfNeeded()
                    let content = try XCTUnwrap(window.contentView)
                    XCTAssertEqual(content.bounds.width, width, accuracy: 1, "Long labels must not enlarge the window")
                    let scroll = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSScrollView }.first)
                    let body = try XCTUnwrap(scroll.documentView)
                    for view in descendants(of: body) where view is NSTextField || view is NSButton {
                        let rect = view.convert(view.bounds, to: body)
                        // AppKit text fields extend two points beyond their alignment rect.
                        XCTAssertGreaterThanOrEqual(rect.minX, -2)
                        XCTAssertLessThanOrEqual(rect.maxX, body.bounds.width + 2)
                    }
                    if section != .open {
                        let grid = try XCTUnwrap(descendants(of: body).first { $0.identifier?.rawValue == "welcomeTemplateGrid" } as? NSStackView)
                        let firstRow = try XCTUnwrap(grid.arrangedSubviews.first as? NSStackView)
                        XCTAssertEqual(firstRow.arrangedSubviews.count, width == 780 ? 3 : 2)
                    }
                    assertBodyAtTop(in: window)
                }
            }
            controller.refresh(recents: [], section: .home, canGoBack: false)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.contentView?.bounds.width ?? 0, 780, accuracy: 1)
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

    func testClickingRecentRowOpensItsDrawing() throws {
        try onMain {
            _ = NSApplication.shared
            let drawing = recentDrawing(isPinned: false)
            var openedURL: URL?
            let controller = makeController(onRecent: { openedURL = $0 })
            defer { controller.close() }
            controller.showWindow(nil)
            let window = try XCTUnwrap(controller.window)
            controller.refresh(recents: [drawing], section: .home, canGoBack: false)
            window.contentView?.layoutSubtreeIfNeeded()
            let open = try XCTUnwrap(button(identifier: "welcomeRecent.\(drawing.url.path)", in: window))
            let row = try XCTUnwrap(sequence(first: open.superview, next: { $0?.superview }).compactMap { $0 }
                .first { String(describing: type(of: $0)) == "RecentDrawingRow" })
            let point = row.convert(NSPoint(x: 30, y: row.bounds.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            row.mouseUp(with: event)
            XCTAssertEqual(openedURL, drawing.url)
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
