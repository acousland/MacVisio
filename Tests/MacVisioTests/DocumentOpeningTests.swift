import AppKit
import XCTest
@testable import MacVisio

final class DocumentOpeningTests: XCTestCase {
    func testFitPageSettlesAfterLegacyScrollersHide() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            document.makeWindowControllers()
            defer { document.close() }
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            editor.window?.contentView?.layoutSubtreeIfNeeded()
            editor.scrollView.scrollerStyle = .legacy
            editor.scrollView.autohidesScrollers = true
            editor.canvas.setZoom(3)
            editor.scrollView.tile()
            let before = editor.scrollView.contentSize
            XCTAssertFalse(try XCTUnwrap(editor.scrollView.horizontalScroller).isHidden)
            XCTAssertFalse(try XCTUnwrap(editor.scrollView.verticalScroller).isHidden)
            editor.canvas.fitPage()
            editor.scrollView.tile()
            XCTAssertGreaterThan(editor.scrollView.contentSize.width, before.width)
            XCTAssertGreaterThan(editor.scrollView.contentSize.height, before.height)
            let size = editor.scrollView.contentSize, page = editor.canvas.page
            let expected = max(0.2, min(3, min((size.width - 88) / page.paperWidth, (size.height - 72) / page.paperHeight)))
            XCTAssertEqual(editor.canvas.zoom, expected, accuracy: 0.000001)
            XCTAssertFalse(document.isDocumentEdited)
        }
    }

    func testApplicationOpenUsesDocumentBookkeepingAndLeavesUntouchedSourceClean() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try fixture()
            let marker = Data([0x00, 0x41, 0xFF, 0x09])
            var parts = try VisioPackage.read(source)
            parts["vendor/opening-probe.bin"] = marker
            try VisioPackage.write(parts, to: source)
            let sourceBytes = try Data(contentsOf: source)
            let diskDate = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate]) as? Date)

            // Keep a probe of the old manual path: read(url) plus assigning the
            // visible URL/type does not establish NSDocument's modification baseline.
            let manual = MacVisioDocument()
            try manual.read(from: source, ofType: MacVisioDocument.visioType)
            manual.fileURL = source
            manual.fileType = MacVisioDocument.visioType
            XCTAssertNil(manual.fileModificationDate)
            XCTAssertFalse(manual.isDocumentEdited)

            // Exercise the same entry point used by the app's Open command.
            let suite = "MacVisioDocumentOpeningTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.removePersistentDomain(forName: suite)
            let appDelegate = AppDelegate()
            let workflow = DocumentWorkflow(delegate: appDelegate, recentStore: RecentDrawingStore(defaults: defaults), recordsSystemRecents: false)
            appDelegate.workflow = workflow
            defer {
                workflow.isTerminating = true
                workflow.welcome?.close()
                defaults.removePersistentDomain(forName: suite)
            }
            var opened:MacVisioDocument?,openError:Error?,openFinished = false
            appDelegate.open(source) { document,error in opened = document;openError = error;openFinished = true }
            let deadline = Date().addingTimeInterval(30)
            while !openFinished && Date() < deadline { RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.05)) }
            XCTAssertTrue(openFinished,"The asynchronous open request should complete.")
            XCTAssertNil(openError)
            let document = try XCTUnwrap(NSDocumentController.shared.documents.first { $0.fileURL?.standardizedFileURL == source.standardizedFileURL } as? MacVisioDocument)
            XCTAssertTrue(opened === document)
            XCTAssertFalse(document.isDocumentEdited, "A newly opened source should start clean before window interaction.")
            XCTAssertEqual(document.fileURL?.standardizedFileURL, source.standardizedFileURL)
            XCTAssertEqual(document.fileType, MacVisioDocument.visioType)
            XCTAssertEqual(document.fileModificationDate, diskDate, "NSDocument should track the source modification date for save conflict checks.")

            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            defer {
                document.close()
                NSDocumentController.shared.removeDocument(document)
            }
            editor.window?.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))

            XCTAssertFalse(document.isDocumentEdited, "Showing, focusing, and fitting an untouched document must not mark it edited.")
            XCTAssertEqual(document.fileURL?.standardizedFileURL, source.standardizedFileURL)
            XCTAssertEqual(document.fileType, MacVisioDocument.visioType)
            XCTAssertEqual(document.fileModificationDate, diskDate)
            assertFitted(editor.canvas, file: #filePath, line: #line)
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes, "Opening and fitting must leave the source file byte-for-byte unchanged.")
            XCTAssertEqual(try VisioPackage.read(source)["vendor/opening-probe.bin"], marker)
        }
    }

    private func assertFitted(_ canvas: CanvasView, file: StaticString, line: UInt) {
        guard let size = canvas.enclosingScrollView?.contentSize, size.width > 0, size.height > 0 else {
            XCTFail("The editor scroll view must have a laid-out viewport.", file: file, line: line)
            return
        }
        let page = canvas.page
        let expected = max(0.2, min(3, min((size.width - 88) / page.paperWidth, (size.height - 72) / page.paperHeight)))
        XCTAssertEqual(canvas.zoom, expected, accuracy: 0.02, "The page should be fit to the visible canvas.", file: file, line: line)
        XCTAssertGreaterThan(canvas.frame.width, 0, file: file, line: line)
        XCTAssertGreaterThan(canvas.frame.height, 0, file: file, line: line)
    }

    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisioOpeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic-source.vsdx")
        var diagram = Diagram()
        diagram.title = "Synthetic open-state fixture"
        diagram.page.nodes = [DiagramNode(kind: .diamond, x: 240, y: 180, text: "Source shapes")]
        try VisioFormat.write(diagram, to: source)
        return source
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
