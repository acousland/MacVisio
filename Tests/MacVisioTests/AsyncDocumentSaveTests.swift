import AppKit
import XCTest
@testable import MacVisio

final class AsyncDocumentSaveTests:XCTestCase {
    func testNativeSaveUnblocksMainAndWritesCapturedDiagramSnapshot() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at:directory) }
            let url = directory.appendingPathComponent("async-snapshot.macvisio")
            let document = MacVisioDocument()
            defer { document.close() }

            let originalText = String(repeating:"snapshot",count:512)
            var diagram = Diagram()
            diagram.page.nodes = (0..<10_000).map { index in
                DiagramNode(kind:.rectangle,x:Double(index % 100)*12,y:Double(index / 100)*12,text:originalText)
            }
            document.diagram = diagram
            document.updateChangeCount(.changeDone)

            var heartbeatCount = 0
            var editedDuringSave = false
            var saveCompleted = false
            var saveError:Error?
            let heartbeat = Timer(timeInterval:0.002,repeats:true) { _ in
                heartbeatCount += 1
                guard !editedDuringSave else { return }
                editedDuringSave = true
                document.diagram.page.nodes[0].text = "Edit made after the save snapshot"
                document.updateChangeCount(.changeDone)
            }
            RunLoop.main.add(heartbeat,forMode:.common)
            defer { heartbeat.invalidate() }

            document.save(to:url,ofType:MacVisioDocument.nativeType,for:.saveAsOperation) { error in
                saveError = error
                saveCompleted = true
            }
            try pumpMainRunLoop(until:{saveCompleted})

            XCTAssertGreaterThan(heartbeatCount,0,"The main run loop should continue while the background writer serializes the snapshot.")
            XCTAssertTrue(editedDuringSave,"The heartbeat should be able to edit after the immutable snapshot is released.")
            if let saveError { throw saveError }

            let reopened = try MacVisioDocument(contentsOf:url,ofType:MacVisioDocument.nativeType)
            defer { reopened.close() }
            XCTAssertEqual(reopened.diagram.page.nodes.first?.text,originalText)
            XCTAssertEqual(document.diagram.page.nodes.first?.text,"Edit made after the save snapshot")
            XCTAssertTrue(document.isDocumentEdited,"An edit made after snapshot capture must remain dirty after save completion.")
        }
    }

    func testFailedAsyncSaveReleasesSnapshotForNextSave() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at:directory) }
            let url = directory.appendingPathComponent("recovered.macvisio")
            let document = MacVisioDocument()
            defer { document.close() }
            var node = DiagramNode(kind:.rectangle,text:"Invalid first save")
            node.width = 0
            document.diagram.page.nodes = [node]
            document.updateChangeCount(.changeDone)

            let firstError = try saveResult(document,to:url)
            XCTAssertNotNil(firstError)
            XCTAssertTrue(document.isDocumentEdited)

            document.diagram.page.nodes[0].width = 120
            document.diagram.page.nodes[0].text = "Recovered save"
            document.updateChangeCount(.changeDone)
            let secondError = try saveResult(document,to:url)
            XCTAssertNil(secondError)
            XCTAssertFalse(document.isDocumentEdited)

            let reopened = try MacVisioDocument(contentsOf:url,ofType:MacVisioDocument.nativeType)
            defer { reopened.close() }
            XCTAssertEqual(reopened.diagram.page.nodes.first?.text,"Recovered save")
        }
    }

    func testOverlappingSaveRequestsQueueSnapshotsForSameURL() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at:directory) }
            let url = directory.appendingPathComponent("overlapping.macvisio")
            let document = MacVisioDocument()
            defer { document.close() }

            let originalText = String(repeating:"snapshot",count:512)
            var diagram = Diagram()
            diagram.page.nodes = (0..<10_000).map { index in
                DiagramNode(kind:.rectangle,x:Double(index % 100)*12,y:Double(index / 100)*12,text:originalText)
            }
            document.diagram = diagram
            document.updateChangeCount(.changeDone)

            var callbacks:[String] = []
            var firstError:Error?
            var secondError:Error?
            var firstRequestSnapshotText:String?
            var firstCompleted = false
            var secondRequested = false
            let heartbeat = Timer(timeInterval:0.002,repeats:true) { _ in
                guard !secondRequested else { return }
                secondRequested = true
                document.diagram.page.nodes[0].text = "Second save snapshot"
                document.updateChangeCount(.changeDone)
                XCTAssertFalse(firstCompleted,"The second request should arrive while the first snapshot is still being written.")
                document.save(to:url,ofType:MacVisioDocument.nativeType,for:.saveOperation) { error in
                    secondError = error
                    callbacks.append("second")
                }
                document.diagram.page.nodes[0].text = "Third edit before queued save starts"
                document.updateChangeCount(.changeDone)
            }
            RunLoop.main.add(heartbeat,forMode:.common)
            defer { heartbeat.invalidate() }

            document.save(to:url,ofType:MacVisioDocument.nativeType,for:.saveAsOperation) { error in
                firstError = error
                callbacks.append("first")
                firstCompleted = true
                if error == nil,
                   let data = try? Data(contentsOf:url),
                   let saved = try? JSONDecoder().decode(Diagram.self,from:data) {
                    firstRequestSnapshotText = saved.page.nodes.first?.text
                }
            }
            try pumpMainRunLoop(until:{callbacks.count == 2})

            if let firstError { throw firstError }
            if let secondError { throw secondError }
            XCTAssertTrue(secondRequested)
            XCTAssertEqual(callbacks,["first","second"],"Save completions should follow request order.")
            XCTAssertEqual(firstRequestSnapshotText,originalText,"The first write should finish with its own captured snapshot before the queued write starts.")
            XCTAssertFalse(document.isDocumentEdited,"The final queued save includes edits made before its actual NSDocument save begins.")

            let final = try JSONDecoder().decode(Diagram.self,from:Data(contentsOf:url))
            XCTAssertEqual(final.page.nodes.first?.text,"Third edit before queued save starts")
        }
    }

    private func saveResult(_ document:MacVisioDocument,to url:URL) throws -> Error? {
        var completed = false
        var result:Error?
        document.save(to:url,ofType:MacVisioDocument.nativeType,for:.saveAsOperation) { error in
            result = error
            completed = true
        }
        try pumpMainRunLoop(until:{completed})
        return result
    }

    private func pumpMainRunLoop(until completed:()->Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !completed() && Date() < deadline {
            _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.02))
        }
        guard completed() else { throw DiagramError.invalid("The asynchronous document save timed out.") }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVisioAsyncSaveTests-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        return directory
    }

    private func onMain<T>(_ body:() throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute:body)
    }
}
