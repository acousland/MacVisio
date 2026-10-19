import AppKit
import XCTest
@testable import MacVisio

final class M3CommandRoutingTests: XCTestCase {
    func testCommandSearchDispatchesUnionThroughOwnedTransactionAndUndo() throws {
        try withEditor { document,editor in
            let baseline = document.diagram
            editor.canvas.select(Set(baseline.page.nodes.map(\.id)))
            let search = editor.commandSearchController
            search.searchField.stringValue = "boolean union";search.filterCommands()
            XCTAssertEqual(search.selectedCommand?.action,#selector(EditorWindowController.unionSelection(_:)))
            XCTAssertTrue(search.runButton.isEnabled);XCTAssertTrue(search.executeSelected())
            XCTAssertTrue(document.isCalculating)
            self.pump(until:{!document.isCalculating})
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(document.diagram.page.nodes.count,1)
            XCTAssertEqual(document.undoManager?.undoActionName,"Union Shapes")
            document.undoManager?.undo();XCTAssertEqual(document.diagram,baseline)
        }
    }

    func testPrintSearchTracksPreparationAvailabilityWithoutChangingTheDrawing() throws {
        try withEditor { document,editor in
            let baseline = document.diagram,revision = document.revision
            var delivered = false
            editor.printSessionRunner = { session in
                XCTAssertEqual(session.prepared.pageIDs,[baseline.page.id]);delivered = true;return true
            }
            let search = editor.commandSearchController
            search.searchField.stringValue = "printer pages";search.filterCommands()
            XCTAssertEqual(search.selectedCommand?.action,#selector(EditorWindowController.printDiagram(_:)))
            XCTAssertTrue(search.executeSelected());XCTAssertTrue(editor.isPreparingPrint)
            search.refreshEnabledState();XCTAssertFalse(search.runButton.isEnabled)
            self.pump(until:{!editor.isPreparingPrint})
            XCTAssertTrue(delivered);XCTAssertNil(editor.lastPrintError)
            search.refreshEnabledState();XCTAssertTrue(search.runButton.isEnabled)
            XCTAssertEqual(document.diagram,baseline);XCTAssertEqual(document.revision,revision)
            XCTAssertFalse(document.isDocumentEdited);XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testPrintCommandPreventsReentrantPreparationDuringNativePublication() throws {
        try withEditor { document,editor in
            let baseline = document.diagram
            let search = editor.commandSearchController
            search.searchField.stringValue = "printer pages";search.filterCommands()
            var runs = 0
            editor.printSessionRunner = { _ in
                runs += 1
                guard runs == 1 else { return true }
                XCTAssertFalse(editor.isPreparingPrint)
                XCTAssertTrue(editor.isPrinting)
                search.refreshEnabledState();XCTAssertFalse(search.runButton.isEnabled)
                editor.printDiagram(nil)
                XCTAssertFalse(editor.isPreparingPrint)
                return true
            }
            XCTAssertTrue(search.executeSelected())
            self.pump(until:{!editor.isPrinting})
            XCTAssertEqual(runs,1);XCTAssertNil(editor.lastPrintError)
            search.refreshEnabledState();XCTAssertTrue(search.runButton.isEnabled)
            XCTAssertEqual(document.diagram,baseline)
            XCTAssertFalse(document.isDocumentEdited);XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    private func withEditor(_ body:(MacVisioDocument,EditorWindowController)throws->Void) throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            document.diagram.page.nodes = [DiagramNode(x:40,y:40,text:""),DiagramNode(x:90,y:40,text:"")]
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            document.undoManager?.groupsByEvent = false;document.undoManager?.removeAllActions()
            defer { editor.commandSearchController.close();document.close() }
            try body(document,editor)
        }
    }
    private func pump(until complete:()->Bool,file:StaticString = #filePath,line:UInt = #line) {
        let deadline = Date().addingTimeInterval(20)
        while !complete() && Date() < deadline { _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(complete(),file:file,line:line)
    }
    private func onMain<T>(_ body:()throws->T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute:body)
    }
}
