import AppKit
import XCTest
@testable import MacVisio

final class GestureSaveContractTests: XCTestCase {
    func testEditExactlyBetweenSnapshotAndAppKitTokenRemainsDirty() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            defer { document.close() }
            document.diagram.page.nodes = [DiagramNode(text: "Captured")]
            document.updateChangeCount(.changeDone)
            document.didCaptureSaveSnapshot = {
                document.diagram.page.nodes[0].text = "Newer edit"
                document.updateChangeCount(.changeDone)
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("M1-token-\(UUID()).macvisio")
            defer { try? FileManager.default.removeItem(at: url) }
            try save(document, to: url)
            let disk = try JSONDecoder().decode(Diagram.self, from: Data(contentsOf: url))
            XCTAssertEqual(disk.page.nodes[0].text, "Captured")
            XCTAssertEqual(document.diagram.page.nodes[0].text, "Newer edit")
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertEqual(document.saveEvents.map(\.phase), ["captured", "succeeded"])
            let event = try XCTUnwrap(document.saveEvents.last)
            XCTAssertNotEqual(event.snapshotStateID, event.currentStateID)
            document.didCaptureSaveSnapshot = nil
            try save(document, to: url)
            XCTAssertFalse(document.isDocumentEdited)
        }
    }

    func testUndoRedoRestoresSavedIdentity() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            defer { document.close() }
            document.undoManager?.groupsByEvent = false
            document.diagram.page.nodes = [DiagramNode(text: "Before")]
            document.updateChangeCount(.changeDone)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("M1-undo-\(UUID()).macvisio")
            defer { try? FileManager.default.removeItem(at: url) }
            try save(document, to: url)
            let savedID = document.stateID
            var next = document.diagram
            next.page.nodes[0].text = "After"
            document.undoManager?.beginUndoGrouping()
            document.replace(with: next, action: "Text")
            document.undoManager?.endUndoGrouping()
            XCTAssertTrue(document.isDocumentEdited)
            document.undoManager?.undo()
            XCTAssertEqual(document.stateID, savedID)
            XCTAssertFalse(document.isDocumentEdited)
            document.undoManager?.redo()
            XCTAssertTrue(document.isDocumentEdited)
            try save(document, to: url)
            document.undoManager?.undo()
            XCTAssertTrue(document.isDocumentEdited)
            document.undoManager?.redo()
            XCTAssertFalse(document.isDocumentEdited)
        }
    }

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

    func testNativeAutosaveDuringDragCapturesCommittedStateAndEscapeKeepsSavedIdentity() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M1-native-autosave-\(UUID())")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
            defer { try? FileManager.default.removeItem(at:directory) }
            let document = MacVisioDocument()
            document.diagram.page.nodes = [DiagramNode(x:100,y:100)]
            document.undoManager?.groupsByEvent = false
            defer { document.close() }
            let destination = directory.appendingPathComponent("committed.macvisio")
            try save(document,to:destination)
            var edited = document.diagram;edited.page.nodes[0].fill = "#CC1122"
            document.replace(with:edited,action:"Style before drag")
            XCTAssertTrue(document.hasUnautosavedChanges)
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            let canvas = editor.canvas
            canvas.zoom = 1;canvas.snapsToGrid = false
            let committed = document.diagram,identity = document.stateID,revision = document.revision
            func mouse(_ type:NSEvent.EventType,_ point:CGPoint) throws -> NSEvent {
                let position = CGPoint(x:canvas.pageOrigin.x+point.x*canvas.coordinateZoom,y:canvas.pageOrigin.y+point.y*canvas.coordinateZoom)
                return try XCTUnwrap(NSEvent.mouseEvent(with:type,location:canvas.convert(position,to:nil),modifierFlags:[],timestamp:0,windowNumber:editor.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
            }
            canvas.mouseDown(with:try mouse(.leftMouseDown,CGPoint(x:180,y:140)))
            canvas.mouseDragged(with:try mouse(.leftMouseDragged,CGPoint(x:220,y:180)))
            XCTAssertNotEqual(canvas.displayedDiagram,committed)
            var done = false,failure:Error?
            document.autosave(withImplicitCancellability:false) { failure = $0;done = true }
            let deadline = Date().addingTimeInterval(20)
            while !done && Date()<deadline { _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.005)) }
            XCTAssertTrue(done)
            if let failure { throw failure }
            XCTAssertEqual(try JSONDecoder().decode(Diagram.self,from:Data(contentsOf:destination)),committed)
            canvas.keyDown(with:try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:editor.window!.windowNumber,context:nil,characters:"\u{1b}",charactersIgnoringModifiers:"\u{1b}",isARepeat:false,keyCode:53)))
            XCTAssertEqual(document.diagram,committed)
            XCTAssertEqual(document.stateID,identity);XCTAssertEqual(document.revision,revision)
            XCTAssertFalse(document.isDocumentEdited);XCTAssertFalse(document.hasUnautosavedChanges)
            XCTAssertEqual(document.saveEvents.last?.phase,"succeeded")
            XCTAssertEqual(document.saveEvents.last?.snapshotStateID,identity)
        }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }

    private func save(_ document: MacVisioDocument, to url: URL) throws {
        var completed = false
        var failure: Error?
        document.save(to: url, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) {
            failure = $0
            completed = true
        }
        let deadline = Date().addingTimeInterval(15)
        while !completed && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(completed)
        if let failure { throw failure }
    }
}
