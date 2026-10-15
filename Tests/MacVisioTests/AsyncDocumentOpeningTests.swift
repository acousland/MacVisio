import AppKit
import XCTest
@testable import MacVisio

final class AsyncDocumentOpeningTests:XCTestCase {
    func testConcurrentReadingIsEnabledOnlyForSupportedAsyncDocumentTypes() {
        XCTAssertTrue(MacVisioDocument.canConcurrentlyReadDocuments(ofType:MacVisioDocument.visioType))
        XCTAssertTrue(MacVisioDocument.canConcurrentlyReadDocuments(ofType:MacVisioDocument.nativeType))
        XCTAssertFalse(MacVisioDocument.canConcurrentlyReadDocuments(ofType:MacVisioDocument.legacyType))
    }

    func testRepeatedInFlightOpenCreatesOneDocumentWindow() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisioAsyncOpenTests-\(UUID().uuidString)",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            let source = directory.appendingPathComponent("async-source.vsdx")
            var diagram = Diagram();diagram.page.nodes = [DiagramNode(kind:.ellipse,x:120,y:90,text:"Async source")]
            try VisioFormat.write(diagram,to:source)

            let suite = "MacVisioAsyncOpenTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName:suite));defaults.removePersistentDomain(forName:suite)
            let delegate = AppDelegate()
            let workflow = DocumentWorkflow(delegate:delegate,recentStore:RecentDrawingStore(defaults:defaults),recordsSystemRecents:false)
            delegate.workflow = workflow
            defer {
                workflow.isTerminating = true;workflow.welcome?.close()
                for document in NSDocumentController.shared.documents where document.fileURL?.standardizedFileURL == source.standardizedFileURL {
                    document.close();NSDocumentController.shared.removeDocument(document)
                }
                defaults.removePersistentDomain(forName:suite)
            }

            var results:[MacVisioDocument] = [],errors:[Error] = [],finished = 0
            let opened:((MacVisioDocument?,Error?)->Void) = { document,error in
                if let document { results.append(document) };if let error { errors.append(error) };finished += 1
            }
            delegate.open(source,completion:opened)
            delegate.open(source,completion:opened)
            let deadline = Date().addingTimeInterval(30)
            while finished < 2 && Date() < deadline { RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.05)) }

            XCTAssertEqual(finished,2,"Both callers should be released when the in-flight open finishes.")
            XCTAssertTrue(errors.isEmpty,errors.map(\.localizedDescription).joined(separator:"; "))
            XCTAssertEqual(results.count,2)
            guard results.count == 2 else { return }
            XCTAssertTrue(results[0] === results[1],"Repeated requests for one canonical source should share a document.")
            XCTAssertEqual(results[0].windowControllers.count,1,"A duplicate open must not create another editor window.")
            XCTAssertFalse(results[0].isDocumentEdited)
            XCTAssertNotNil(results[0].fileModificationDate)
        }
    }

    private func onMain<T>(_ body:() throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute:body)
    }
}
