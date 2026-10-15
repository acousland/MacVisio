import AppKit
import XCTest
@testable import MacVisio

/// Native window/responder routing evidence. This is not an input-method or
/// VoiceOver acceptance test and does not close the whole no-pointer journey.
final class NativeTextRoutingTests: XCTestCase {
    func testInlineTextReceivesToolLettersAndEscapeCancelsThroughWindowResponderChain() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            let node = DiagramNode(text: "Original")
            document.diagram.page.nodes = [node]
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            let window = try XCTUnwrap(editor.window)
            defer {
                editor.canvas.finishEditing(commit: false)
                window.orderOut(nil); window.delegate = nil
                document.removeWindowController(editor); editor.close()
            }
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            editor.canvas.select([node.id])
            editor.canvas.beginEditing(node.id)
            let field = try XCTUnwrap(window.firstResponder as? InlineTextView)
            XCTAssertEqual(field.selectedRange().length, node.text.utf16.count)
            for (text, code) in [("v", UInt16(9)), ("c", 8), ("t", 17), ("l", 37)] {
                let event = try key(text, code: code, window: window)
                window.sendEvent(event)
            }
            XCTAssertEqual(field.string, "vctl")
            XCTAssertEqual(editor.canvas.tool, .pointer)
            XCTAssertTrue(editor.canvas.isEditingText)
            XCTAssertEqual(document.diagram.page.nodes[0], node, "Text is still an uncommitted input session.")
            window.sendEvent(try key("\u{1b}", code: 53, window: window))
            XCTAssertFalse(editor.canvas.isEditingText)
            XCTAssertEqual(document.diagram.page.nodes[0], node)
            XCTAssertFalse(document.isDocumentEdited)
        }
    }

    private func key(_ text: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: text, charactersIgnoringModifiers: text,
                                      isARepeat: false, keyCode: code))
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
