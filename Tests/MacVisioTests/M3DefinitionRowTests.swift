import AppKit
import XCTest
@testable import MacVisio

final class M3DefinitionRowTests: XCTestCase {
    private func fixture(connectors: Bool = true) throws -> Diagram {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "m3-intelligent", withExtension: "vsdx", subdirectory: "Fixtures/M3"))
        var parts = try VisioPackage.read(url)
        let document = try VisioXML.document(XCTUnwrap(parts["visio/document.xml"]))
        let sheet = try XCTUnwrap(document.rootElement()?.firstLocal("DocumentSheet"))
        sheet.firstLocal("Section")?.setAttr("Custom", "section-retained")
        sheet.firstLocal("Section")?.addChild(try VisioXML.element("""
        <Row N="Rate" T="User" Custom="retained"><Cell N="Value" V="2" U="IN" Custom="cell-retained"/><Opaque xmlns="urn:row-test">row payload</Opaque></Row>
        """))
        sheet.firstLocal("Section")?.addChild(try VisioXML.element("<Row N=\"Unused\" Custom=\"undo-me\"><Cell N=\"Value\" V=\"8\"/><Opaque xmlns=\"urn:row-test\">deleted payload</Opaque></Row>"))
        document.rootElement()?.addNamespace(XMLNode.namespace(withName:"extra",stringValue:"urn:row-test-extra") as! XMLNode)
        let payload = XMLElement(name:"extra:Payload");payload.stringValue = "namespaced row payload";payload.setAttr("extra:flag","retained")
        sheet.firstLocal("Section")?.elementsLocal("Row").first{$0.attr("N") == "Unused"}?.addChild(payload)
        parts["visio/document.xml"] = document.xmlData(options: .nodePreserveAll)
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        if !connectors {
            page.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "30" }?.detach()
            page.rootElement()?.firstLocal("Connects")?.detach()
        }
        let shape = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "20" })
        shape.elementsLocal("Cell").first { $0.attr("N") == "Width" }?.setAttr("F", "TheDoc!User.Rate")
        shape.addChild(try VisioXML.element("<Section N=\"User\"><Row N=\"Literal\"><Cell N=\"Value\" V=\"User.Rate\" F=\"&quot;TheDoc!User.Rate&quot;\"/></Row></Section>"))
        parts["visio/pages/page1.xml"] = page.xmlData(options: .nodePreserveAll)
        return try VisioFormat.readPublic(parts: parts, title: "Row editing").diagram
    }
    private func documentSheet(_ diagram: Diagram) throws -> DefinitionSheet { try XCTUnwrap(diagram.definitions?.documentSheet) }
    private func row(_ name: String, in sheet: DefinitionSheet) throws -> DefinitionRow { try XCTUnwrap(sheet.rows.first { $0.name == name }) }
    private func publicSheet(_ archive: VisioDocumentArchive) throws -> XMLElement {
        try XCTUnwrap(VisioXML.document(XCTUnwrap(archive.parts["visio/document.xml"])).rootElement()?.firstLocal("DocumentSheet"))
    }
    private func shape(_ diagram: Diagram, _ id: String) throws -> DiagramNode {
        try XCTUnwrap(diagram.pages[0].nodes.first { $0.formatting.sourceShapeID == id })
    }

    func testNamedRowRenamePreservesIDsOpaqueXMLAndScopedFormulasOnPublicReopen() throws {
        let old = try fixture(), sheet = try documentSheet(old), originalRow = try row("Rate", in: sheet)
        let address = DefinitionCellAddress(cell: "Value", section: "User", rowName: "Rate")
        let oldCell = try XCTUnwrap(sheet.cells.first { $0.address == address })
        let next = try DefinitionEditing.editingRow(in: old, sheetID: sheet.id, edit: .rename(rowID: originalRow.id, name: "Distance"))
        let renamed = try documentSheet(next)
        XCTAssertEqual(try row("Distance", in: renamed).id, originalRow.id)
        var renamedAddress = address; renamedAddress.rowName = "Distance"
        XCTAssertEqual(renamed.cells.first { $0.address == renamedAddress }?.id, oldCell.id)
        XCTAssertEqual(try shape(next, "20").formatting.sheet["Width"]?.formula, "TheDoc!User.Distance")
        XCTAssertEqual(try shape(next, "20").formatting.sheet["User.Literal"]?.formula, "\"TheDoc!User.Rate\"")
        XCTAssertEqual(try shape(next, "20").width, 144, accuracy: 1e-8)
        XCTAssertEqual(next.visioArchive, old.visioArchive)
        let saved = try VisioPreservation.prepared(next)
        let raw = try XCTUnwrap(DefinitionRowEditing.row(renamedAddress, in: publicSheet(saved)))
        XCTAssertEqual(raw.attr("Custom"), "retained")
        XCTAssertEqual(raw.firstLocal("Cell")?.attr("Custom"), "cell-retained")
        XCTAssertEqual(raw.firstLocal("Opaque")?.stringValue, "row payload")
        XCTAssertNil(DefinitionRowEditing.row(address, in: try publicSheet(saved)))
        XCTAssertEqual(saved.parts["synthetic/opaque.bin"], old.visioArchive?.parts["synthetic/opaque.bin"])
        let reopened = try VisioFormat.readPublic(parts: saved.parts, title: "Public only").diagram
        XCTAssertEqual(try shape(reopened, "20").formatting.sheet["Width"]?.formula, "TheDoc!User.Distance")
        XCTAssertEqual(try shape(reopened, "20").width, 144, accuracy: 1e-8)
        let encoded = try JSONEncoder().encode(next)
        let native = try JSONDecoder().decode(Diagram.self, from: encoded).validated()
        XCTAssertEqual(native.definitions, next.definitions)
    }

    func testDeleteReferencedRowRefusesWithoutChangingInput() throws {
        let old = try fixture(), sheet = try documentSheet(old), originalRow = try row("Rate", in: sheet)
        XCTAssertThrowsError(try DefinitionEditing.editingRow(in: old, sheetID: sheet.id, edit: .remove(rowID: originalRow.id))) { error in
            XCTAssertTrue(error.localizedDescription.contains("still referenced"), error.localizedDescription)
        }
        XCTAssertEqual(try documentSheet(old), sheet)
    }

    func testInsertPropertyAndDeleteUnusedRowArePublicOperations() throws {
        let old = try fixture(), sheet = try documentSheet(old)
        let added = try DefinitionEditing.editingRow(in: old, sheetID: sheet.id, edit: .insert(section: "Property", name: "Owner"))
        let address = DefinitionCellAddress(cell: "Value", section: "Property", rowName: "Owner")
        XCTAssertEqual(try documentSheet(added).cell(address)?.value, "0")
        let removed = try DefinitionEditing.editingRow(in: added, sheetID: sheet.id, edit: .remove(rowID: row("Unused", in: sheet).id))
        let saved = try VisioPreservation.prepared(removed)
        XCTAssertNotNil(DefinitionRowEditing.row(address, in: try publicSheet(saved)))
        XCTAssertNil(DefinitionRowEditing.row(DefinitionCellAddress(cell: "", section: "User", rowName: "Unused"), in: try publicSheet(saved)))
        XCTAssertTrue(saved.definitionRows?.contains { $0.rowID == (try? row("Unused", in: sheet).id) && $0.removedXML != nil } == true)
    }

    func testRenameThenReuseOldNameIsRejectedUntilIdentityReleased() throws {
        let old = try fixture(), sheet = try documentSheet(old), originalRow = try row("Rate", in: sheet)
        let renamed = try DefinitionEditing.editingRow(in: old, sheetID: sheet.id, edit: .rename(rowID: originalRow.id, name: "Renamed"))
        XCTAssertThrowsError(try DefinitionEditing.editingRow(in: renamed, sheetID: sheet.id, edit: .insert(section: "User", name: "Rate")))
        XCTAssertThrowsError(try DefinitionEditing.editingRow(in: old, sheetID: sheet.id, edit: .insert(section: "User", name: "rate")))
        XCTAssertThrowsError(try DefinitionEditing.editingRow(in: old, sheetID: sheet.id, edit: .insert(section: "User", name: "Bad.Name")))
    }

    func testMasterRowRenameDoesNotChangeSameNamedRowInAnotherMasterOrLocalOverride() throws {
        var old = try fixture()
        let originalParts = try XCTUnwrap(old.visioArchive?.parts)
        var parts = originalParts
        let master = try VisioXML.document(XCTUnwrap(parts["visio/masters/master1.xml"]))
        let body = try XCTUnwrap(master.rootElement()?.firstLocal("Shapes")?.allShapes.first)
        body.elementsLocal("Cell").first { $0.attr("N") == "Height" }?.setAttr("F", "User.Span/2")
        parts["visio/masters/master1.xml"] = master.xmlData(options: .nodePreserveAll)
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        let objects = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes)
        let instance = try XCTUnwrap(objects.first { $0.attr("ID") == "10" })
        instance.addChild(try VisioXML.element("<Section N=\"User\"><Row N=\"Probe\"><Cell N=\"Value\" V=\"2\" F=\"User.Span\"/></Row></Section>"))
        parts["visio/pages/page1.xml"] = page.xmlData(options: .nodePreserveAll)
        old = try VisioFormat.readPublic(parts: parts, title: "Master row").diagram
        let owner = try XCTUnwrap(old.definitions?.masters.first { $0.publicID == "7" }), sheet = owner.sheets[0]
        let renamed = try DefinitionEditing.editingRow(in: old, sheetID: sheet.id, edit: .rename(rowID: row("Span", in: sheet).id, name: "Breadth"))
        XCTAssertEqual(try shape(renamed, "10").formatting.sheet["User.Probe"]?.formula, "User.Breadth")
        XCTAssertEqual(renamed.definitions?.masters.first { $0.id == owner.id }?.sheets[0].cell(DefinitionCellAddress(cell: "Height"))?.formula, "User.Breadth/2")
        XCTAssertEqual(renamed.visioArchive?.parts["visio/masters/master2.xml"], parts["visio/masters/master2.xml"])
        let saved = try VisioPreservation.prepared(renamed)
        XCTAssertEqual(saved.parts["visio/masters/master2.xml"], parts["visio/masters/master2.xml"])
    }

    func testRenameAndDeleteUndoAfterSavedBaselineRestoresOpaqueRows() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); document.diagram = try fixture(); document.undoManager?.groupsByEvent = false
            defer { document.close() }
            let initial = document.diagram, sheet = try documentSheet(initial)
            let renamed = try DefinitionEditing.editingRow(in: initial, sheetID: sheet.id, edit: .rename(rowID: row("Rate", in: sheet).id, name: "Distance"))
            document.undoManager?.beginUndoGrouping(); document.replace(with: renamed, action: "Rename row"); document.undoManager?.endUndoGrouping()
            // Install exactly the source baseline returned by a successful save,
            // using the real NSDocument save path for its publication/rebase rules.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("m3-rows-\(UUID()).vsdx")
            defer { try? FileManager.default.removeItem(at: url) }
            try save(document, to: url, operation: .saveAsOperation)
            document.undoManager?.undo()
            try save(document, to: url)
            XCTAssertNotNil(try documentSheet(VisioFormat.readPublic(parts: VisioPackage.read(url), title: "Undo").diagram).rows.first { $0.name == "Rate" })
            document.undoManager?.redo(); try save(document, to: url)
            let current = document.diagram
            let deleted = try DefinitionEditing.editingRow(in: current, sheetID: sheet.id, edit: .remove(rowID: row("Unused", in: sheet).id))
            document.undoManager?.beginUndoGrouping(); document.replace(with: deleted, action: "Delete row"); document.undoManager?.endUndoGrouping()
            try save(document, to: url)
            document.undoManager?.undo(); try save(document, to: url)
            let archive = try XCTUnwrap(document.diagram.visioArchive)
            let restored = try XCTUnwrap(DefinitionRowEditing.row(DefinitionCellAddress(cell: "", section: "User", rowName: "Unused"), in: publicSheet(archive)))
            XCTAssertEqual(restored.attr("Custom"), "undo-me")
            XCTAssertEqual(restored.firstLocal("Opaque")?.stringValue, "deleted payload")
            document.undoManager?.redo(); try save(document, to: url)
            XCTAssertNil(DefinitionRowEditing.row(DefinitionCellAddress(cell: "", section: "User", rowName: "Unused"), in: try publicSheet(XCTUnwrap(document.diagram.visioArchive))))
        }
    }

    func testEmptySectionAddRemoveAndUndoRetainsSectionAndRowOpaquePayloads() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument();document.diagram = try fixture(connectors:false);document.undoManager?.groupsByEvent = false
            defer { document.close() }
            let initial = document.diagram,sheet = try documentSheet(initial)
            let added = try DefinitionEditing.editingRow(in:initial,sheetID:sheet.id,edit:.insertSection(name:"Property"))
            let property = try XCTUnwrap(added.definitions?.documentSheet?.sections?.first{$0.name == "Property"})
            let prepared = try VisioPreservation.prepared(added)
            let publicDrawing = try VisioFormat.readPublic(parts:prepared.parts,title:"Empty section").diagram
            XCTAssertNotNil(publicDrawing.definitions?.documentSheet?.sections?.first{$0.name == "Property"})
            XCTAssertFalse(try documentSheet(publicDrawing).rows.contains{$0.section == "Property"})
            XCTAssertThrowsError(try DefinitionEditing.editingRow(in:added,sheetID:sheet.id,edit:.insertSection(name:"Property")))
            let removedEmpty = try DefinitionEditing.editingRow(in:added,sheetID:sheet.id,edit:.removeSection(sectionID:property.id))
            XCTAssertFalse(try documentSheet(removedEmpty).sections?.contains{$0.name == "Property"} ?? true)
            // Remove User only after its page reference has been intentionally
            // changed. A referenced section must refuse before publication.
            let user = try XCTUnwrap(sheet.sections?.first{$0.name == "User"})
            XCTAssertThrowsError(try DefinitionEditing.editingRow(in:initial,sheetID:sheet.id,edit:.removeSection(sectionID:user.id)))
            var unreferenced = initial
            unreferenced.pages[0].nodes[1].formatting.sheet["Width"] = ShapeSheetCell(value:"3")
            document.diagram = unreferenced
            let removed = try DefinitionEditing.editingRow(in:unreferenced,sheetID:sheet.id,edit:.removeSection(sectionID:user.id))
            document.undoManager?.beginUndoGrouping();document.replace(with:removed,action:"Remove section");document.undoManager?.endUndoGrouping()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("m3-sections-\(UUID()).vsdx")
            addTeardownBlock { try? FileManager.default.removeItem(at:url) }
            try save(document,to:url,operation:.saveAsOperation)
            XCTAssertNil(try publicSheet(XCTUnwrap(document.diagram.visioArchive)).elementsLocal("Section").first{$0.attr("N") == "User"})
            document.undoManager?.undo();try save(document,to:url)
            let raw = try publicSheet(XCTUnwrap(document.diagram.visioArchive))
            XCTAssertEqual(raw.elementsLocal("Section").first{$0.attr("N") == "User"}?.attr("Custom"),"section-retained")
            let restored = try XCTUnwrap(DefinitionRowEditing.row(DefinitionCellAddress(cell:"",section:"User",rowName:"Unused"),in:raw))
            XCTAssertEqual(restored.attr("Custom"),"undo-me")
            XCTAssertEqual(restored.firstLocal("Opaque")?.stringValue,"deleted payload")
            XCTAssertEqual(restored.firstLocal("Payload")?.stringValue,"namespaced row payload")
            document.undoManager?.redo();try save(document,to:url)
            XCTAssertNil(try publicSheet(XCTUnwrap(document.diagram.visioArchive)).elementsLocal("Section").first{$0.attr("N") == "User"})
        }
    }

    func testLeadingZeroSheetReferencesRenameAndPreventReferencedRowDeletion() throws {
        let base = try fixture();var parts = try XCTUnwrap(base.visioArchive?.parts)
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        let shape = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first{$0.attr("ID") == "20"})
        shape.firstLocal("Section")?.addChild(try VisioXML.element("<Row N=\"Cross\"><Cell N=\"Value\" V=\"2\" F=\"Sheet.010!User.Span\"/></Row>"))
        parts["visio/pages/page1.xml"] = page.xmlData(options:.nodePreserveAll)
        let old = try VisioFormat.readPublic(parts:parts,title:"Leading zero").diagram
        let sheet = try XCTUnwrap(old.definitions?.masters.first{$0.publicID == "7"}?.sheets.first)
        let span = try row("Span",in:sheet)
        XCTAssertThrowsError(try DefinitionEditing.editingRow(in:old,sheetID:sheet.id,edit:.remove(rowID:span.id)))
        let next = try DefinitionEditing.editingRow(in:old,sheetID:sheet.id,edit:.rename(rowID:span.id,name:"Breadth"))
        XCTAssertEqual(try self.shape(next,"20").formatting.sheet["User.Cross"]?.formula,"Sheet.010!User.Breadth")
    }

    func testPartialAndExplicitInheritedPropertyOverridesRefuseStructuralDefinitionEdit() throws {
        for override in ["<Cell N=\"Label\" V=\"Local label\"/>","<Cell N=\"Value\" V=\"Inh\"/>","<Cell N=\"Value\" V=\"Synthetic\" F=\"Inh\"/>"] {
            let base = try fixture();var parts = try XCTUnwrap(base.visioArchive?.parts)
            let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
            let shape = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first{$0.attr("ID") == "10"})
            shape.addChild(try VisioXML.element("<Section N=\"Property\"><Row N=\"Owner\">\(override)</Row></Section>"))
            parts["visio/pages/page1.xml"] = page.xmlData(options:.nodePreserveAll)
            let old = try VisioFormat.readPublic(parts:parts,title:"Partial override").diagram
            let sheet = try XCTUnwrap(old.definitions?.masters.first{$0.publicID == "7"}?.sheets.first)
            let owner = try row("Owner",in:sheet)
            for edit in [DefinitionRowEdit.rename(rowID:owner.id,name:"Assigned"),.remove(rowID:owner.id)] {
                XCTAssertThrowsError(try DefinitionEditing.editingRow(in:old,sheetID:sheet.id,edit:edit)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("override"),error.localizedDescription)
                }
            }
        }
    }

    func testRetainedSourceMutationsCannotRedirectOrRestoreDifferentPublicRows() throws {
        let old = try fixture(),sheet = try documentSheet(old)
        let rate = try row("Rate",in:sheet),other = try row("Unused",in:sheet)
        let index = try XCTUnwrap(old.visioArchive?.definitionRows?.firstIndex{$0.rowID == rate.id})
        var wrongOwner = old
        wrongOwner.visioArchive?.definitionRows?[index].sheetID = try XCTUnwrap(old.definitions?.masters.first?.sheets.first?.id)
        XCTAssertThrowsError(try wrongOwner.validated())
        var wrongAddress = old
        wrongAddress.visioArchive?.definitionRows?[index].address.rowName = "Missing"
        XCTAssertThrowsError(try wrongAddress.validated())
        var duplicate = old
        var record = try XCTUnwrap(duplicate.visioArchive?.definitionRows?[index])
        var identity = record.address;identity.rowName = "AnotherIdentity"
        record.identityAddress = identity;record.rowID = DefinitionRegistry.stableID(sheet.id,identity.key)
        duplicate.visioArchive?.definitionRows?.append(record)
        XCTAssertThrowsError(try duplicate.validated())
        var redirected = old
        redirected.visioArchive?.definitionRows?[index].identityAddress = record.address
        redirected.visioArchive?.definitionRows?[index].address.rowName = "Unused"
        redirected.visioArchive?.definitionRows?.removeAll{$0.rowID == other.id}
        XCTAssertThrowsError(try redirected.validated())
        for xml in ["<Section N=\"Rate\"/>","<Row N=\"Another\"/>","<x:Row xmlns:x=\"urn:other\" N=\"Rate\"/>"] {
            var wrongPayload = old
            wrongPayload.visioArchive?.definitionRows?[index].removedXML = Data(xml.utf8)
            XCTAssertThrowsError(try wrongPayload.validated())
        }
    }

    func testAddingCellCreatesScopedOwnerMetadataBeforeSaveAndNativeReopen() throws {
        let old = try fixture(),sheet = try documentSheet(old)
        let address = DefinitionCellAddress(cell:"Value",section:"Property",rowName:"Estimate")
        let next = try DefinitionEditing.settingCell(in:old,sheetID:sheet.id,address:address,value:ShapeSheetCell(value:"12",unit:"NO"))
        XCTAssertEqual(try documentSheet(next).rows.first{$0.name == "Estimate"}?.section,"Property")
        XCTAssertNotNil(try documentSheet(next).sections?.first{$0.name == "Property"})
        let archive = try VisioPreservation.prepared(next)
        var saved = next;saved.visioArchive = archive
        XCTAssertNoThrow(try JSONDecoder().decode(Diagram.self,from:JSONEncoder().encode(saved)).validated())
        let publicOnly = try VisioFormat.readPublic(parts:archive.parts,title:"New owner").diagram
        XCTAssertEqual(try documentSheet(publicOnly).cell(address),ShapeSheetCell(value:"12",unit:"NO"))
    }

    func testNoOpRenameLeavesRegistryVersionIdentityAndSourceUnchanged() throws {
        let old = try fixture(),sheet = try documentSheet(old),rate = try row("Rate",in:sheet)
        let next = try DefinitionEditing.editingRow(in:old,sheetID:sheet.id,edit:.rename(rowID:rate.id,name:"Rate"))
        XCTAssertEqual(next,old)
    }

    func testLegacyNativeRegistryHydratesSectionsWithoutChangingRowIDs() throws {
        let current = try fixture()
        var legacy = current
        for sheet in try XCTUnwrap(current.definitions).editableSheets {
            try legacy.definitions?.editSheet(sheet.id) { $0.sections = nil }
        }
        legacy.visioArchive?.definitionRows = nil
        let decoded = try JSONDecoder().decode(Diagram.self,from:JSONEncoder().encode(legacy)).validated()
        XCTAssertEqual(decoded.definitions?.documentSheet?.sections,current.definitions?.documentSheet?.sections)
        XCTAssertEqual(decoded.definitions?.documentSheet?.rows,current.definitions?.documentSheet?.rows)
        XCTAssertEqual(decoded.visioArchive?.parts,current.visioArchive?.parts)
        XCTAssertEqual(decoded.visioArchive?.definitionRows?.count,DefinitionSourceRow.index(try XCTUnwrap(decoded.definitions)).count)
    }

    func testReferenceScannerPreservesDoubledQuotesAndRemapsWholeIdentifiers() throws {
        let input = "IF(1,\"TheDoc!User.A \"\"User.A\"\"\",TheDoc!User.A)+User.AA+User.A"
        let output = DefinitionReferenceEditing.replacingIdentifiers(in: input) { $0 == "User.A" ? "User.B" : $0 == "TheDoc!User.A" ? "TheDoc!User.B" : $0 }
        XCTAssertEqual(output, "IF(1,\"TheDoc!User.A \"\"User.A\"\"\",TheDoc!User.B)+User.AA+User.B")
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        Thread.isMainThread ? try body() : try DispatchQueue.main.sync(execute: body)
    }
    private func save(_ document: MacVisioDocument, to url: URL, operation: NSDocument.SaveOperationType = .saveOperation) throws {
        let done = expectation(description: "Row save"); var failure: Error?
        document.save(to: url, ofType: MacVisioDocument.visioType, for: operation) { error in failure = error; done.fulfill() }
        wait(for: [done], timeout: 20)
        if let failure { throw failure }
    }
}
