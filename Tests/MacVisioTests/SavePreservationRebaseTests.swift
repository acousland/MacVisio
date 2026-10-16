import AppKit
import XCTest
@testable import MacVisio

final class SavePreservationRebaseTests: XCTestCase {
    func testRepeatedSaveRebasesBindingsRetainsOpaquePartsAndKeepsSemanticIdentity() throws {
        try onMain {
            _ = NSApplication.shared
            let (document, url) = try importedDocument()
            defer { document.close() }
            let initialResource = try XCTUnwrap(document.diagram.visioArchive?.sourceResourceID)
            let nodeID = document.diagram.page.nodes[0].id
            document.diagram.page.nodes[0].text = "First edit"
            document.updateChangeCount(.changeDone)
            let identity = document.stateID, revision = document.revision
            let runtime = document.runtime()
            try save(document, to: url)
            let firstArchive = try XCTUnwrap(document.diagram.visioArchive)
            XCTAssertNotEqual(firstArchive.sourceResourceID, initialResource)
            XCTAssertEqual(firstArchive.pages[0].original.nodes[0].text, "First edit")
            XCTAssertEqual(document.stateID, identity)
            XCTAssertEqual(document.revision, revision)
            XCTAssertTrue(document.runtime() === runtime)
            XCTAssertFalse(document.isDocumentEdited)

            var next = document.diagram
            next.page.nodes.append(DiagramNode(x: 400, y: 200, text: "New source identity"))
            let newID = next.page.nodes[1].id
            document.undoManager?.groupsByEvent = false
            document.undoManager?.beginUndoGrouping()
            document.replace(with: next, action: "Insert")
            document.undoManager?.endUndoGrouping()
            try save(document, to: url)
            let secondArchive = try XCTUnwrap(document.diagram.visioArchive)
            XCTAssertEqual(secondArchive.pages[0].original.nodes.count, 2)
            XCTAssertEqual(secondArchive.pages[0].nodeIDs[nodeID], firstArchive.pages[0].nodeIDs[nodeID])
            let allocated = try XCTUnwrap(secondArchive.pages[0].nodeIDs[newID])
            XCTAssertEqual(secondArchive.parts["vendor/lifecycle.bin"], Data([0, 255, 16]))

            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.page.nodes.count, 1)
            XCTAssertEqual(document.diagram.visioArchive?.sourceResourceID, secondArchive.sourceResourceID,
                           "Undo restores editable state while retaining the latest compatible source baseline")
            XCTAssertTrue(document.isDocumentEdited)
            document.undoManager?.redo()
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertEqual(document.diagram.visioArchive?.pages[0].nodeIDs[newID], allocated)
            XCTAssertEqual(try VisioPackage.read(url)["vendor/lifecycle.bin"], Data([0, 255, 16]))
        }
    }

    func testNewerEditKeepsLivePagesAndDirtyStateWhileSavedSnapshotBecomesBaseline() throws {
        try onMain {
            _ = NSApplication.shared
            let (document, url) = try importedDocument()
            defer { document.close() }
            document.diagram.page.nodes[0].text = "Captured"
            document.updateChangeCount(.changeDone)
            var newerID: UUID?, newerRevision: UInt64?
            document.didCaptureSaveSnapshot = {
                document.diagram.page.nodes[0].text = "Newer"
                document.updateChangeCount(.changeDone)
                newerID = document.stateID
                newerRevision = document.revision
            }
            try save(document, to: url)
            document.didCaptureSaveSnapshot = nil
            XCTAssertEqual(document.diagram.page.nodes[0].text, "Newer")
            XCTAssertEqual(document.diagram.visioArchive?.pages[0].original.nodes[0].text, "Captured")
            XCTAssertEqual(document.stateID, newerID)
            XCTAssertEqual(document.revision, newerRevision)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertTrue(document.hasUnautosavedChanges)
            XCTAssertEqual(try VisioFormat.read(from: url).diagram.page.nodes[0].text, "Captured")
            try save(document, to: url)
            XCTAssertEqual(document.diagram.visioArchive?.pages[0].original.nodes[0].text, "Newer")
            XCTAssertFalse(document.isDocumentEdited)
        }
    }

    func testFailureAndSaveToDoNotReplaceLiveSourceBaseline() throws {
        try onMain {
            _ = NSApplication.shared
            let (document, url) = try importedDocument()
            defer { document.close() }
            let originalResource = document.diagram.visioArchive?.sourceResourceID
            let originalBytes = try Data(contentsOf: url)
            document.diagram.page.nodes[0].text = "Copy only"
            document.updateChangeCount(.changeDone)
            let copy = url.deletingLastPathComponent().appendingPathComponent("copy.vsdx")
            try save(document, to: copy, operation: .saveToOperation)
            XCTAssertEqual(document.diagram.visioArchive?.sourceResourceID, originalResource)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            document.diagram.page.nodes[0].width = -.infinity
            XCTAssertThrowsError(try save(document, to: url))
            XCTAssertEqual(document.diagram.visioArchive?.sourceResourceID, originalResource)
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            XCTAssertTrue(document.isDocumentEdited)
        }
    }

    func testRecoveryAutosaveAcknowledgesOnlyRecoveryState() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            defer { document.close() }
            document.diagram.page.nodes = [DiagramNode(text: "Untitled baseline")]
            document.fileType = MacVisioDocument.nativeType
            document.undoManager?.groupsByEvent = false
            let directory = try temporaryDirectory()
            let recovery = directory.appendingPathComponent("recovery.macvisio")
            let baselineID = document.stateID
            XCTAssertNil(document.fileURL)
            var next = document.diagram;next.page.nodes[0].text = "Recovered edit"
            document.undoManager?.beginUndoGrouping();document.replace(with: next, action: "Edit");document.undoManager?.endUndoGrouping()
            XCTAssertTrue(document.hasUnautosavedChanges)
            // NSDocument.h defines autosaveElsewhere for a subclass supporting
            // autosave-in-place only when the document has no permanent URL.
            // Do not force that operation on an already-saved document.
            try save(document, to: recovery, type: MacVisioDocument.nativeType, operation: .autosaveElsewhereOperation)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertFalse(document.hasUnautosavedChanges)
            XCTAssertNil(document.fileURL)
            XCTAssertEqual(document.autosavedContentsFileURL?.standardizedFileURL,recovery.standardizedFileURL)
            let recovered = try MacVisioDocument(for:nil,withContentsOf:recovery,ofType:MacVisioDocument.nativeType)
            defer { recovered.close() }
            XCTAssertEqual(recovered.diagram.page.nodes[0].text,"Recovered edit")
            XCTAssertTrue(recovered.isDocumentEdited,"Recovering untitled content must still require an explicit user save")
            document.undoManager?.undo()
            XCTAssertEqual(document.stateID,baselineID)
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertFalse(document.hasUnautosavedChanges)
            document.undoManager?.redo()
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertFalse(document.hasUnautosavedChanges)
        }
    }

    func testUntitledDraftAutosaveEstablishesCurrentSourceAndAcknowledgesOnlyCapturedState() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument();defer { document.close() }
            document.diagram.page.nodes = [DiagramNode(text:"Untitled draft baseline")]
            document.fileType = MacVisioDocument.nativeType
            let directory = try temporaryDirectory(),draft = directory.appendingPathComponent("draft.macvisio")
            var next = document.diagram;next.page.nodes[0].text = "Draft snapshot"
            document.replace(with:next,action:"Edit draft")
            let capturedID = document.stateID,capturedRevision = document.revision
            XCTAssertNil(document.fileURL)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertTrue(document.hasUnautosavedChanges)
            // Unlike autosaveElsewhere, autosaveAs makes the written file the
            // document's current file. NSDocument enables drafts by default.
            try save(document,to:draft,type:MacVisioDocument.nativeType,operation:.autosaveAsOperation)
            XCTAssertEqual(document.fileURL.map(DocumentSourceVersion.canonical),DocumentSourceVersion.canonical(draft))
            XCTAssertEqual(document.stateID,capturedID)
            XCTAssertEqual(document.revision,capturedRevision)
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertFalse(document.hasUnautosavedChanges)
            XCTAssertEqual(try JSONDecoder().decode(Diagram.self,from:Data(contentsOf:draft)).page.nodes[0].text,"Draft snapshot")

            next = document.diagram;next.page.nodes[0].text = "Later local draft edit"
            document.replace(with:next,action:"Continue editing draft")
            let laterID = document.stateID
            XCTAssertNotEqual(laterID,capturedID)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertTrue(document.hasUnautosavedChanges)
            var external = try JSONDecoder().decode(Diagram.self,from:Data(contentsOf:draft))
            external.page.nodes[0].text = "External draft replacement"
            let externalBytes = try JSONEncoder().encode(external)
            try externalBytes.write(to:draft,options:.atomic)
            XCTAssertThrowsError(try save(document,to:draft,type:MacVisioDocument.nativeType)) { error in
                var cause = error as NSError
                for _ in 0..<16 {
                    if cause.domain == DocumentSourceConflict.errorDomain { return }
                    guard let nested = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
                    cause = nested
                }
                XCTFail("Draft save did not preserve typed external conflict: \(error)")
            }
            XCTAssertEqual(try Data(contentsOf:draft),externalBytes)
            XCTAssertEqual(document.fileURL.map(DocumentSourceVersion.canonical),DocumentSourceVersion.canonical(draft))
            XCTAssertEqual(document.stateID,laterID)
            XCTAssertEqual(document.diagram.page.nodes[0].text,"Later local draft edit")
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertTrue(document.hasUnautosavedChanges)
        }
    }

    private func importedDocument() throws -> (MacVisioDocument, URL) {
        let directory = try temporaryDirectory()
        let source = directory.appendingPathComponent("source.vsdx")
        var diagram = Diagram();diagram.page.nodes = [DiagramNode(text: "Original")]
        try VisioFormat.write(diagram, to: source)
        var parts = try VisioPackage.read(source)
        parts["vendor/lifecycle.bin"] = Data([0, 255, 16])
        try VisioPackage.write(parts, to: source)
        return (try MacVisioDocument(contentsOf: source, ofType: MacVisioDocument.visioType), source)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M1-rebase-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func save(_ document: MacVisioDocument, to url: URL, type: String = MacVisioDocument.visioType,
                      operation: NSDocument.SaveOperationType = .saveOperation) throws {
        var completed = false
        var failure: Error?
        document.save(to: url, ofType: type, for: operation) { failure = $0;completed = true }
        let deadline = Date().addingTimeInterval(20)
        while !completed && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(completed)
        if !completed { throw DiagramError.invalid("Save completion timed out") }
        if let failure { throw failure }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
