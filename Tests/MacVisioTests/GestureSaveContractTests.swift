import AppKit
import XCTest
@testable import MacVisio

final class GestureSaveContractTests: XCTestCase {
    func testDragSaveEscapeSerializesCommittedState() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            document.diagram.page.nodes = [DiagramNode(x: 100, y: 100)]
            document.makeWindowControllers()
            defer { document.close() }
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            let canvas = editor.canvas
            canvas.zoom = 1
            canvas.snapsToGrid = false
            let baseline = document.diagram
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
                let position = CGPoint(x: canvas.pageOrigin.x + point.x * canvas.coordinateZoom,
                                       y: canvas.pageOrigin.y + point.y * canvas.coordinateZoom)
                return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(position, to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: editor.window!.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            canvas.mouseDown(with: try mouse(.leftMouseDown, CGPoint(x: 180, y: 140)))
            canvas.mouseDragged(with: try mouse(.leftMouseDragged, CGPoint(x: 220, y: 180)))
            let bytes = try document.data(ofType: MacVisioDocument.nativeType)
            let saved = try JSONDecoder().decode(Diagram.self, from: bytes)
            canvas.keyDown(with: try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: editor.window!.windowNumber,
                context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53)))
            XCTAssertEqual(document.diagram, baseline)
            XCTAssertEqual(saved, baseline, "Save during a gesture must serialize the committed baseline.")
            XCTAssertFalse(document.isDocumentEdited)
        }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
