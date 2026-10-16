import AppKit
import XCTest
@testable import MacVisio

final class M3DefinitionEditingTests: XCTestCase {
    private func fixture() throws -> Diagram {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "m3-intelligent", withExtension: "vsdx", subdirectory: "Fixtures/M3"))
        return try VisioFormat.read(from: url).diagram
    }

    private func node(_ diagram: Diagram, _ source: String) throws -> DiagramNode {
        try XCTUnwrap(diagram.pages[0].nodes.first { $0.formatting.sourceShapeID == source })
    }

    private func masterEdit(_ diagram: Diagram, cell: String, value: String) throws -> Diagram {
        let master = try XCTUnwrap(diagram.definitions?.masters.first { $0.publicID == "7" })
        return try DefinitionEditing.settingCell(in: diagram, sheetID: master.sheets[0].id,
            address: DefinitionCellAddress(cell: cell), value: ShapeSheetCell(value: value))
    }

    func testMasterCellEditChangesInheritedValueWithoutFlatteningInstanceOverrides() throws {
        let old = try fixture()
        let next = try masterEdit(old, cell: "Height", value: "1.5")
        XCTAssertEqual(try node(next, "10").height, 108, accuracy: 1e-8)
        XCTAssertEqual(try node(next, "10").width, 144, accuracy: 1e-8)
        XCTAssertEqual(try node(next, "20").height, 72, accuracy: 1e-8)
        XCTAssertEqual(next.pages.map(\.id), old.pages.map(\.id))
        XCTAssertEqual(next.pages[0].nodes.map(\.id), old.pages[0].nodes.map(\.id))
        XCTAssertEqual(next.visioArchive, old.visioArchive, "An unsaved proposal must not advance source baselines")
        let saved = try VisioPreservation.prepared(next)
        let source = try XCTUnwrap(old.visioArchive)
        let changed = Set(saved.parts.keys.filter { saved.parts[$0] != source.parts[$0] })
        XCTAssertEqual(changed, ["visio/masters/master1.xml"])
        let publicOnly = try VisioFormat.readPublic(parts: saved.parts, title: next.title).diagram
        XCTAssertEqual(try node(publicOnly, "10").height, 108, accuracy: 1e-8)
        let xml = try VisioXML.document(XCTUnwrap(saved.parts["visio/pages/page1.xml"]))
        let instance = try XCTUnwrap(xml.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "10" })
        XCTAssertEqual(instance.attr("Master"), "7")
        XCTAssertNil(instance.elementsLocal("Cell").first { $0.attr("N") == "Height" })
        XCTAssertEqual(instance.elementsLocal("Cell").first { $0.attr("N") == "Width" }?.attr("F"), "GUARD(2 in)")
    }

    func testStyleCellEditUpdatesOnlyItsScopedConsumersAndRetainsOpaqueParts() throws {
        let old = try fixture()
        let style = try XCTUnwrap(old.definitions?.styles.first { $0.publicID == "4" })
        let next = try DefinitionEditing.settingCell(in: old, sheetID: style.sheets[0].id,
            address: DefinitionCellAddress(cell: "LineColor"), value: ShapeSheetCell(value: "#A12345"))
        XCTAssertEqual(try node(next, "10").stroke, "#A12345")
        XCTAssertEqual(try node(next, "20").stroke, try node(old, "20").stroke)
        XCTAssertEqual(next.pages[0].edges, old.pages[0].edges)
        let saved = try VisioPreservation.prepared(next)
        let source = try XCTUnwrap(old.visioArchive)
        XCTAssertEqual(Set(saved.parts.keys.filter { saved.parts[$0] != source.parts[$0] }), ["visio/document.xml"])
        XCTAssertEqual(saved.parts["synthetic/opaque.bin"], source.parts["synthetic/opaque.bin"])
        XCTAssertEqual(try node(VisioFormat.readPublic(parts: saved.parts, title: "Public").diagram, "10").stroke, "#A12345")
    }

    func testDefinitionProjectionPreservesUnsavedLocalTextAndNewObjectIdentities() throws {
        var old = try fixture()
        let index = try XCTUnwrap(old.pages[0].nodes.firstIndex { $0.formatting.sourceShapeID == "20" })
        old.pages[0].nodes[index].text = "Unsaved local text"
        let inserted = DiagramNode(x: 300, y: 200, text: "Unsaved insertion")
        old.pages[0].nodes.append(inserted)
        var page = DiagramPage(); page.name = "Unsaved page"; page.nodes = [DiagramNode(text: "New page object")]
        old.pages.append(page)
        let next = try masterEdit(old, cell: "Height", value: "1.5")
        XCTAssertEqual(try node(next, "20").text, "Unsaved local text")
        XCTAssertEqual(next.pages[0].nodes.last?.id, inserted.id)
        XCTAssertEqual(next.pages.last?.id, page.id)
        XCTAssertEqual(next.pages.last?.nodes[0].id, page.nodes[0].id)
        XCTAssertEqual(next.visioArchive, old.visioArchive)
    }

    func testDefinitionUndoAfterSaveUsesOldCellsAgainstLatestSourceBaseline() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); defer { document.close() }
            document.diagram = try fixture()
            document.undoManager?.groupsByEvent = false
            let initial = document.diagram
            let next = try masterEdit(initial, cell: "Height", value: "1.5")
            document.undoManager?.beginUndoGrouping()
            document.replace(with: next, action: "Edit master")
            document.undoManager?.endUndoGrouping()
            let url = try output()
            try save(document, to: url, operation: .saveAsOperation)
            let savedSource = document.diagram.visioArchive?.sourceResourceID
            XCTAssertFalse(document.isDocumentEdited)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.definitions, initial.definitions)
            XCTAssertEqual(document.diagram.visioArchive?.sourceResourceID, savedSource)
            XCTAssertEqual(try node(document.diagram, "10").height, 72, accuracy: 1e-8)
            XCTAssertTrue(document.isDocumentEdited)
            try save(document, to: url)
            let publicOnly = try VisioFormat.readPublic(parts: VisioPackage.read(url), title: "Undo").diagram
            XCTAssertEqual(try node(publicOnly, "10").height, 72, accuracy: 1e-8)
            document.undoManager?.redo()
            XCTAssertEqual(try node(document.diagram, "10").height, 108, accuracy: 1e-8)
            try save(document, to: url)
            XCTAssertEqual(try node(VisioFormat.readPublic(parts: VisioPackage.read(url), title: "Redo").diagram, "10").height, 108, accuracy: 1e-8)
        }
    }

    func testFirstVSDXSaveInstallsSameDefinitionIdentitiesAsSavedMetadataAndUndo() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); defer { document.close() }
            document.diagram.page.nodes = [DiagramNode(text: "First save")]
            document.undoManager?.groupsByEvent = false
            var next = document.diagram; next.page.nodes[0].text = "Before first save"
            document.undoManager?.beginUndoGrouping(); document.replace(with: next, action: "Edit"); document.undoManager?.endUndoGrouping()
            let url = try output()
            try save(document, to: url, operation: .saveAsOperation)
            let definitions = try XCTUnwrap(document.diagram.definitions)
            XCTAssertEqual(try VisioFormat.read(from: url).diagram.definitions, definitions)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.definitions, definitions)
            XCTAssertEqual(document.diagram.page.nodes[0].text, "First save")
            try save(document, to: url)
            XCTAssertEqual(document.diagram.definitions, definitions)
            XCTAssertEqual(try VisioFormat.read(from: url).diagram.definitions, definitions)
        }
    }

    func testOlderSaveCompletingAfterDefinitionEditKeepsNewerSemanticCells() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); defer { document.close() }
            document.diagram = try fixture()
            let next = try masterEdit(document.diagram, cell: "Height", value: "1.5")
            document.didCaptureSaveSnapshot = {
                document.replace(with: next, action: "Edit master during save")
            }
            let url = try output()
            try save(document, to: url, operation: .saveAsOperation)
            document.didCaptureSaveSnapshot = nil
            XCTAssertEqual(document.diagram.definitions, next.definitions)
            XCTAssertEqual(try node(document.diagram, "10").height, 108, accuracy: 1e-8)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertEqual(try node(VisioFormat.readPublic(parts: VisioPackage.read(url), title: "Captured").diagram, "10").height, 72, accuracy: 1e-8)
            try save(document, to: url)
            XCTAssertFalse(document.isDocumentEdited)
            XCTAssertEqual(try node(VisioFormat.readPublic(parts: VisioPackage.read(url), title: "Latest").diagram, "10").height, 108, accuracy: 1e-8)
        }
    }

    func testNativeDefinitionCommandUsesOwnedWorkerAndCancellationKeepsCommittedState() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); defer { document.close() }
            document.diagram = try fixture()
            let master = try XCTUnwrap(document.diagram.definitions?.masters.first { $0.publicID == "7" })
            let before = document.diagram
            document.editDefinitionCell(sheetID: master.sheets[0].id,
                address: DefinitionCellAddress(cell: "Height"), value: ShapeSheetCell(value: "1.5"))
            XCTAssertTrue(document.isCalculating)
            XCTAssertEqual(document.diagram, before)
            let deadline = Date().addingTimeInterval(10)
            while document.isCalculating && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            XCTAssertFalse(document.isCalculating)
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(try node(document.diagram, "10").height, 108, accuracy: 1e-8)
            let committed = document.diagram, state = document.stateID
            document.editDefinitionCell(sheetID: master.sheets[0].id,
                address: DefinitionCellAddress(cell: "Height"), value: ShapeSheetCell(value: "2"))
            XCTAssertTrue(document.isCalculating)
            document.cancelPendingCalculation()
            let cancellationDeadline = Date().addingTimeInterval(10)
            while document.isCalculating && Date() < cancellationDeadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            XCTAssertFalse(document.isCalculating)
            XCTAssertNotNil(document.lastCalculationJobError)
            XCTAssertEqual(document.diagram, committed)
            XCTAssertEqual(document.stateID, state)
        }
    }

    func testDefinitionOnlyEditIsIncludedInSignedSourceSaveAssessment() throws {
        var old = try fixture()
        old.visioArchive?.parts["_xmlsignatures/sig1.xml"] = Data("signature".utf8)
        var next = old
        next.definitions?.documentSheet?.set(DefinitionCellAddress(cell: "Value", section: "User", rowName: "Revision"), to: ShapeSheetCell(value: "2"))
        XCTAssertEqual(old.pages, next.pages)
        let assessment = DocumentSaveImpact.assess(snapshot: next, baseline: .init(snapshot: old), diagnostics: [], format: .visio)
        XCTAssertTrue(assessment.risks.contains { $0.feature == .signature })
        XCTAssertTrue(DocumentSaveImpact.assess(snapshot: next, baseline: nil, diagnostics: [], format: .visio).risks.contains { $0.feature == .signature })
    }

    private func output() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M3-definitions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("edited.vsdx")
    }

    private func save(_ document: MacVisioDocument, to url: URL,
                      operation: NSDocument.SaveOperationType = .saveOperation) throws {
        var completed = false; var failure: Error?
        document.save(to: url, ofType: MacVisioDocument.visioType, for: operation) { failure = $0; completed = true }
        let deadline = Date().addingTimeInterval(20)
        while !completed && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(completed)
        if !completed { throw DiagramError.invalid("Definition save timed out") }
        if let failure { throw failure }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
