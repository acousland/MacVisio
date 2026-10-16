import MacVisioInfrastructure
import AppKit
import XCTest
@testable import MacVisio

final class OwnedOpeningWorkflowTests: XCTestCase {
    func testAppearanceChangeDoesNotRefreshClosedControllerAfterDocumentRelease() throws {
        try onMain {
            _ = NSApplication.shared
            weak var closedDocument:MacVisioDocument?
            var retainedController:EditorWindowController?
            try autoreleasepool {
                let document = MacVisioDocument()
                closedDocument = document
                document.makeWindowControllers()
                retainedController = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
                document.showWindows()
                document.close()
            }
            XCTAssertNil(closedDocument)
            XCTAssertFalse(retainedController?.window?.isVisible ?? true)
            XCTAssertFalse(retainedController?.lifecycleJobs.isActive ?? true)
            EditorAppearance.apply()
            var callbackPassed = false
            DispatchQueue.main.async { callbackPassed = true }
            try pump(until:{callbackPassed})
            retainedController = nil
        }
    }

    func testClosingBeforeQueuedInitialFitCannotUseDestroyedDocument() throws {
        try onMain {
            _ = NSApplication.shared
            weak var closedDocument:MacVisioDocument?
            autoreleasepool {
                let document = MacVisioDocument()
                closedDocument = document
                document.makeWindowControllers()
                document.showWindows()
                document.close()
            }
            var callbackPassed = false
            DispatchQueue.main.async { callbackPassed = true }
            try pump(until:{callbackPassed})
            XCTAssertNil(closedDocument,"A queued fitting callback must not keep or access a closed document")
        }
    }

    func testLegacyAndTemplateRequestsReturnBeforeCompletionAndKeepSourceSemantics() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            var fixture = Diagram();fixture.page.nodes = [DiagramNode(text:"Owned open fixture")]
            let drawing = directory.appendingPathComponent("native.vsd")
            let binaryTemplate = directory.appendingPathComponent("template.vst")
            let packageTemplate = directory.appendingPathComponent("template.vstx")
            try VSDBinaryFormat.write(fixture,to:drawing)
            try FileManager.default.copyItem(at:drawing,to:binaryTemplate)
            try VisioReusableFormat.writeTemplate(fixture,to:packageTemplate)
            let delegate = AppDelegate()
            delegate.workflow = DocumentWorkflow(delegate:delegate,recordsSystemRecents:false)
            delegate.workflow.isTerminating = true
            for (url,isTemplate) in [(drawing,false),(binaryTemplate,true),(packageTemplate,true)] {
                let source = try Data(contentsOf:url)
                var finished = false
                var opened:MacVisioDocument?
                var failure:Error?
                delegate.open(url) { opened = $0;failure = $1;finished = true }
                XCTAssertFalse(finished,"A supported long open must return to the event loop before delivery")
                try pump(until:{finished})
                XCTAssertNil(failure)
                let document = try XCTUnwrap(opened)
                XCTAssertEqual(document.diagram.page.nodes[0].text,"Owned open fixture")
                XCTAssertEqual(document.fileURL?.standardizedFileURL,isTemplate ? nil : url.standardizedFileURL)
                XCTAssertEqual(document.fileType,isTemplate ? MacVisioDocument.visioType : MacVisioDocument.legacyType)
                XCTAssertEqual(document.isDocumentEdited,isTemplate)
                XCTAssertEqual(try Data(contentsOf:url),source)
                document.close();NSDocumentController.shared.removeDocument(document)
            }
        }
    }

    func testClosingStencilOwnerCancelsDeliveryWithoutInstallingLibraryItems() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            let stencil = directory.appendingPathComponent("owned.vssx")
            var fragment = DiagramPage();fragment.nodes = [DiagramNode(text:"Stencil item")]
            try VisioReusableFormat.writeStencil([StencilDefinition(name:"Owned master",family:"Owned",fragment:fragment)],to:stencil)
            let document = MacVisioDocument();document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            let initialItems = editor.stencils.count
            var finished = false
            var failure:Error?
            editor.loadStencil(stencil) { failure = $0;finished = true }
            XCTAssertFalse(finished)
            document.close()
            try pump(until:{finished})
            XCTAssertEqual(failure as? LifecycleJobError,.cancelled)
            XCTAssertEqual(editor.stencils.count,initialItems)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M1-owned-open-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        return directory
    }

    private func pump(until complete:()->Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !complete() && Date() < deadline { _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
        guard complete() else { throw DiagramError.invalid("Owned open completion timed out") }
    }

    private func onMain<T>(_ body:() throws ->T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute:body)
    }
}
