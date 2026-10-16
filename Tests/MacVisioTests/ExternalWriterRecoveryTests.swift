import AppKit
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class ExternalWriterRecoveryTests: XCTestCase {
    func testExternalReplacementAfterCaptureRefusesOverwriteAndSaveAsPreservesBothVersions() throws {
        try onMain {
            _ = NSApplication.shared
            let (document, source, external) = try fixture()
            defer { document.close() }
            var edited = document.diagram;edited.page.nodes[0].text = "Local unsaved edit"
            document.replace(with:edited,action:"Edit")
            let state = document.stateID,resource = document.diagram.visioArchive?.sourceResourceID
            var writerError:Error?
            document.didCaptureSaveSnapshot = { do { try self.copy(external,to:source) } catch { writerError = error } }
            let error = try XCTUnwrap(saveError(document,to:source))
            document.didCaptureSaveSnapshot = nil
            XCTAssertNil(writerError)
            XCTAssertTrue(isConflict(error),"\(error)")
            XCTAssertEqual(try VisioFormat.read(from:source).diagram.page.nodes[0].text,"External writer")
            XCTAssertEqual(document.diagram.page.nodes[0].text,"Local unsaved edit")
            XCTAssertEqual(document.stateID,state)
            XCTAssertEqual(document.diagram.visioArchive?.sourceResourceID,resource)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertTrue(document.hasUnautosavedChanges)
            // A direct subsequent API call must also refuse the stale source.
            XCTAssertTrue(isConflict(try XCTUnwrap(saveError(document,to:source))))
            let copyURL = source.deletingLastPathComponent().appendingPathComponent("local-copy.vsdx")
            XCTAssertNil(saveError(document,to:copyURL,operation:.saveAsOperation))
            XCTAssertEqual(try VisioFormat.read(from:copyURL).diagram.page.nodes[0].text,"Local unsaved edit")
            XCTAssertEqual(try VisioFormat.read(from:source).diagram.page.nodes[0].text,"External writer")
            XCTAssertFalse(document.isDocumentEdited)
        }
    }

    func testExternalReplacementReloadsWithoutStaleDirtyIdentityOrUndoHistory() throws {
        try onMain {
            _ = NSApplication.shared
            let (document,source,external) = try fixture()
            defer { document.close() }
            var edited = document.diagram;edited.page.nodes[0].text = "Discard this edit"
            document.replace(with:edited,action:"Edit")
            XCTAssertTrue(document.undoManager?.canUndo == true)
            try copy(external,to:source)
            XCTAssertTrue(isConflict(try XCTUnwrap(saveError(document,to:source))))
            try document.revert(toContentsOf:source,ofType:MacVisioDocument.visioType)
            XCTAssertEqual(document.diagram.page.nodes[0].text,"External writer")
            XCTAssertEqual(document.diagram.visioArchive?.parts["vendor/recovery.bin"],Data([7,8,9]))
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertFalse(document.hasUnautosavedChanges)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
            XCTAssertNil(saveError(document,to:source))
        }
    }

    func testQueuedSameSourceSaveChecksVersionWhenItStartsAndAliasCannotBypassConflict() throws {
        try onMain {
            _ = NSApplication.shared
            let (document,source,external) = try fixture()
            defer { document.close() }
            var edited = document.diagram;edited.page.nodes[0].text = "Captured before external writer"
            document.replace(with:edited,action:"Edit")
            let alias = source.deletingLastPathComponent().appendingPathComponent("source-alias.vsdx")
            try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:source)
            var queuedFinished = false,queuedError:Error?,firstFinished = false,firstError:Error?,copyError:Error?
            document.didCaptureSaveSnapshot = {
                document.didCaptureSaveSnapshot = nil
                document.save(to:source,ofType:MacVisioDocument.visioType,for:.saveOperation) {
                    queuedError = $0;queuedFinished = true
                }
            }
            document.save(to:source,ofType:MacVisioDocument.visioType,for:.saveOperation) { error in
                firstError = error
                do { try self.copy(external,to:source) } catch { copyError = error }
                firstFinished = true
            }
            try waitUntil { firstFinished && queuedFinished }
            XCTAssertNil(firstError);XCTAssertNil(copyError)
            XCTAssertTrue(isConflict(try XCTUnwrap(queuedError)))
            XCTAssertTrue(isConflict(try XCTUnwrap(saveError(document,to:alias))))
            XCTAssertEqual(try VisioFormat.read(from:source).diagram.page.nodes[0].text,"External writer")
        }
    }

    func testInterruptedWriterKeepsDestinationAndFreshCLIReopensIdentifiedUnsavedCheckpoint() throws {
        try onMain {
            _ = NSApplication.shared
            let (original,source,_) = try fixture()
            defer { original.close() }
            let directory = source.deletingLastPathComponent()
            let checkpoint = directory.appendingPathComponent("untitled-recovery.macvisio")
            let manifestURL = directory.appendingPathComponent("recovery.json")
            let output = directory.appendingPathComponent("recovered.vsdx")
            let marker = directory.appendingPathComponent("writer-ready")
            let originalBytes = try Data(contentsOf:source)
            let unsaved = MacVisioDocument();defer { unsaved.close() }
            unsaved.diagram = original.diagram;unsaved.fileType = MacVisioDocument.nativeType
            var next = unsaved.diagram;next.page.nodes[0].text = "Identified unsaved checkpoint"
            unsaved.replace(with:next,action:"Unsaved edit")
            var done = false,saveFailure:Error?
            unsaved.save(to:checkpoint,ofType:MacVisioDocument.nativeType,for:.autosaveElsewhereOperation) { saveFailure = $0;done = true }
            try waitUntil { done }
            if let saveFailure { throw saveFailure }
            XCTAssertTrue(unsaved.isDocumentEdited)
            XCTAssertFalse(unsaved.hasUnautosavedChanges)
            let manifest = RecoveryProbe(original:source.path,checkpoint:checkpoint.path,stateID:unsaved.stateID,unsaved:true)
            try JSONEncoder().encode(manifest).write(to:manifestURL,options:.atomic)
            var stagedURL:URL?
            XCTAssertThrowsError(try AtomicJobOutput.write(to:source) { staging in
                stagedURL = staging
                let writer = Process();writer.executableURL = URL(fileURLWithPath:"/bin/sh")
                // A real process reaches a deterministic partial-output checkpoint
                // before termination. Its sleep is never a timing-based success gate.
                writer.arguments = ["-c","printf partial > \"$1\"; printf ready > \"$2\"; exec /bin/sleep 30","m1-interrupted-writer",staging.path,marker.path]
                try writer.run()
                defer { if writer.isRunning { writer.terminate() };writer.waitUntilExit() }
                try waitUntil { FileManager.default.fileExists(atPath:marker.path) }
                writer.terminate();writer.waitUntilExit()
                XCTAssertNotEqual(writer.terminationStatus,0)
                throw InterruptedWriter.stopped
            }) { XCTAssertTrue($0 is InterruptedWriter) }
            XCTAssertFalse(FileManager.default.fileExists(atPath:try XCTUnwrap(stagedURL).path))
            XCTAssertEqual(try Data(contentsOf:source),originalBytes)
            let identified = try JSONDecoder().decode(RecoveryProbe.self,from:Data(contentsOf:manifestURL))
            XCTAssertTrue(identified.unsaved);XCTAssertEqual(identified.stateID,unsaved.stateID)
            let executable = Bundle(for:Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("MacVisio")
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath:executable.path),"Built CLI is required for fresh-process recovery evidence")
            let fresh = Process();fresh.executableURL = executable
            fresh.arguments = ["--convert",identified.checkpoint,output.path]
            let diagnostics = Pipe();fresh.standardOutput = diagnostics;fresh.standardError = diagnostics
            try fresh.run()
            defer { if fresh.isRunning { fresh.terminate() };fresh.waitUntilExit() }
            try waitUntil { !fresh.isRunning }
            let diagnosticText = String(decoding:diagnostics.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
            XCTAssertEqual(fresh.terminationStatus,0,diagnosticText)
            XCTAssertEqual(try VisioFormat.read(from:output).diagram.page.nodes[0].text,"Identified unsaved checkpoint")
            XCTAssertEqual(try Data(contentsOf:source),originalBytes)
        }
    }

    private struct RecoveryProbe:Codable {
        let original:String
        let checkpoint:String
        let stateID:UUID
        let unsaved:Bool
    }
    private enum InterruptedWriter:Error { case stopped }

    private func fixture() throws -> (MacVisioDocument,URL,URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M1-external-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        let source = directory.appendingPathComponent("source.vsdx"),external = directory.appendingPathComponent("external.vsdx")
        var model = Diagram();model.page.nodes = [DiagramNode(text:"Original")]
        try VisioFormat.write(model,to:source)
        let document = try MacVisioDocument(contentsOf:source,ofType:MacVisioDocument.visioType)
        model.page.nodes[0].text = "External writer"
        try VisioFormat.write(model,to:external)
        var parts = try VisioPackage.read(external);parts["vendor/recovery.bin"] = Data([7,8,9]);try VisioPackage.write(parts,to:external)
        return (document,source,external)
    }

    private func copy(_ source:URL,to destination:URL) throws {
        let process = Process();process.executableURL = URL(fileURLWithPath:"/bin/cp")
        process.arguments = [source.path,destination.path]
        try process.run();process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DiagramError.invalid("External writer failed") }
    }

    private func saveError(_ document:MacVisioDocument,to url:URL,operation:NSDocument.SaveOperationType = .saveOperation) -> Error? {
        var done = false,failure:Error?
        document.save(to:url,ofType:MacVisioDocument.visioType,for:operation) { failure = $0;done = true }
        do { try waitUntil { done } } catch { return error }
        return failure
    }

    private func waitUntil(_ condition:()->Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() && Date() < deadline { _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
        guard condition() else { throw DiagramError.invalid("Save completion timed out") }
    }

    private func isConflict(_ error:Error) -> Bool {
        var current = error as NSError
        for _ in 0..<16 {
            if current.domain == DocumentSourceConflict.errorDomain { return true }
            // NSDocument may detect the external version before the subclass's
            // coordinated write guard runs, preserving its own recovery UI.
            if current.domain == NSCocoaErrorDomain,current.code == 67000 { return true }
            guard let nested = current.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            current = nested
        }
        return false
    }

    private func onMain<T>(_ body:() throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute:body)
    }
}
