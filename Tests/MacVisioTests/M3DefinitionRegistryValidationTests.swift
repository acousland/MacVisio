import Foundation
import XCTest
@testable import MacVisio

final class M3DefinitionRegistryValidationTests: XCTestCase {
    private func fixture() throws -> Diagram {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/M3/m3-intelligent.vsdx")
        return try VisioFormat.read(from: url).diagram
    }

    private func changingSheet(_ registry: inout DefinitionRegistry, owner: Int,
                               change: (inout DefinitionSheet) -> Void) {
        switch owner {
        case 0: change(&registry.documentSheet!)
        case 1: change(&registry.masters[0].sheets[0])
        case 2: change(&registry.styles[1].sheets[0])
        default: change(&registry.uses[0].localSheet)
        }
    }

    func testRepeatedHydrationRetainsLineageScopedIdentitiesAcrossPartRebase() throws {
        var source = try fixture()
        source.definitions = nil
        let first = try DefinitionRegistry.hydrate(source)
        let second = try DefinitionRegistry.hydrate(source)
        XCTAssertEqual(first.definitions, second.definitions)
        XCTAssertEqual(first.definitions?.sourceDocumentID, source.visioArchive?.sourceLineageID)
        var archive = try XCTUnwrap(source.visioArchive)
        var parts = archive.parts
        parts["synthetic/rebase.bin"] = Data([1, 2, 3])
        archive.parts = parts
        source.visioArchive = archive
        XCTAssertEqual(try DefinitionRegistry.hydrate(source).definitions, first.definitions)
    }

    func testImplicitDescendantsHydrateInParentOrderRegardlessOfDictionaryAndSourceOrder() throws {
        let original = try fixture()
        var parts = try XCTUnwrap(original.visioArchive).parts
        let document = try VisioXML.document(try XCTUnwrap(parts["visio/masters/master1.xml"]))
        let root = try XCTUnwrap(document.rootElement()?.firstLocal("Shapes")?.firstLocal("Shape"))
        root.setAttr("Type", "Group")
        var owner = root
        for id in 2...10 {
            let shapes = try VisioXML.element("<Shapes/>")
            let shape = try VisioXML.element("<Shape ID=\"\(id)\" Type=\"Group\"><Cell N=\"Width\" V=\"1\"/><Cell N=\"Height\" V=\"1\"/><Cell N=\"PinX\" V=\"0.5\"/><Cell N=\"PinY\" V=\"0.5\"/></Shape>")
            shapes.addChild(shape)
            owner.addChild(shapes)
            owner = shape
        }
        parts["visio/masters/master1.xml"] = document.xmlData(options: .nodePreserveAll)
        var source = try VisioFormat.readPublic(parts: parts, title: "Nested provenance").diagram
        source.definitions = nil
        let initialBinding = try XCTUnwrap(source.visioArchive?.pages.first)
        let inheritance = try XCTUnwrap(initialBinding.inheritedShapes)
        XCTAssertGreaterThanOrEqual(inheritance.count, 9)
        var archive = try XCTUnwrap(source.visioArchive)
        // Deliberately present descendants before parents in retained arrays.
        archive.pages[0].original.nodes.reverse()
        archive.pages[0].inheritedShapes = Dictionary(uniqueKeysWithValues: inheritance.reversed().map { ($0.key, $0.value) })
        source.visioArchive = archive
        let registry = try XCTUnwrap(DefinitionRegistry.hydrate(source).definitions)
        let uses = Dictionary(uniqueKeysWithValues: registry.uses.filter { $0.pageID == initialBinding.pageID }.map { ($0.objectID, $0) })
        for (id, entry) in inheritance {
            let use = try XCTUnwrap(uses[id], "Missing inherited source object \(entry.masterShapeID)")
            XCTAssertEqual(use.masterShapeID, entry.masterShapeID)
            XCTAssertEqual(use.masterID, uses[entry.parentID]?.masterID)
        }
        XCTAssertNoThrow(try registry.validate())
    }

    func testMultiRootMasterUseDoesNotClaimItsFirstRealRoot() throws {
        let original = try fixture()
        var parts = try XCTUnwrap(original.visioArchive).parts
        let document = try VisioXML.document(try XCTUnwrap(parts["visio/masters/master1.xml"]))
        let shapes = try XCTUnwrap(document.rootElement()?.firstLocal("Shapes"))
        let second = try XCTUnwrap(shapes.firstLocal("Shape")?.copy() as? XMLElement)
        second.setAttr("ID", "2")
        shapes.addChild(second)
        parts["visio/masters/master1.xml"] = document.xmlData(options: .nodePreserveAll)
        let source = try VisioFormat.readPublic(parts: parts, title: "Multiple roots").diagram
        let registry = try XCTUnwrap(source.definitions)
        let use = try XCTUnwrap(registry.uses.first { $0.localSheet.attributes["NameU"] == "Instance.Blue" })
        XCTAssertNotNil(use.masterID)
        XCTAssertNil(use.masterShapeID)
        XCTAssertEqual(registry.masters.first { $0.id == use.masterID }?.sheets.filter { $0.parentID == nil }.count, 2)
        XCTAssertNoThrow(try registry.validate())
    }

    func testEverySheetOwnerRejectsDuplicateOrForgedCellAndRowIdentities() throws {
        let original = try XCTUnwrap(fixture().definitions)
        for owner in 0..<4 {
            var duplicate = original
            changingSheet(&duplicate, owner: owner) { sheet in
                if let cell = sheet.cells.first { sheet.cells.append(cell) }
            }
            XCTAssertThrowsError(try duplicate.validate(), "duplicate cell owner \(owner)")
            var forged = original
            changingSheet(&forged, owner: owner) { $0.cells[0].id = UUID() }
            XCTAssertThrowsError(try forged.validate(), "forged cell owner \(owner)")
            var rows = original
            changingSheet(&rows, owner: owner) { sheet in
                let address = DefinitionCellAddress(cell: "", section: "User", rowName: "Duplicate")
                let row = DefinitionRow(id: DefinitionRegistry.stableID(sheet.id, address.key), section: "User",
                                        sectionIndex: nil, name: "Duplicate", index: nil, type: nil, deleted: false)
                sheet.rows += [row, row]
            }
            XCTAssertThrowsError(try rows.validate(), "duplicate row owner \(owner)")
        }
    }

    func testDocumentAndLocalSheetsRejectInvalidAddressesAndOversizedFormulas() throws {
        let original = try XCTUnwrap(fixture().definitions)
        for owner in [0, 3] {
            var invalid = original
            changingSheet(&invalid, owner: owner) { sheet in
                sheet.set(DefinitionCellAddress(cell: "Value", rowName: "NoSection"), to: ShapeSheetCell(value: "1"))
            }
            XCTAssertThrowsError(try invalid.validate())
            var oversized = original
            changingSheet(&oversized, owner: owner) { $0.cells[0].value.formula = String(repeating: "1", count: 16385) }
            XCTAssertThrowsError(try oversized.validate())
            var identity = original
            changingSheet(&identity, owner: owner) { $0.id = UUID() }
            XCTAssertThrowsError(try identity.validate())
        }
    }

    func testDanglingDefinitionTargetsAndDuplicateProvenanceAreRejected() throws {
        let original = try XCTUnwrap(fixture().definitions)
        var master = original
        master.uses[0].masterID = UUID()
        XCTAssertThrowsError(try master.validate())
        var masterShape = original
        masterShape.uses[0].masterShapeID = "4294967295"
        XCTAssertThrowsError(try masterShape.validate())
        var style = original
        style.uses[0].styles["TextStyle"] = UUID()
        XCTAssertThrowsError(try style.validate())
        var role = original
        role.uses[0].styles["UnknownRole"] = original.styles[0].id
        XCTAssertThrowsError(try role.validate())
        var duplicate = original
        duplicate.uses.append(duplicate.uses[0])
        XCTAssertThrowsError(try duplicate.validate())
    }

    func testSourceProvenanceSurvivesLivePageDeletionAndCopies() throws {
        var source = try fixture()
        let registry = try XCTUnwrap(source.definitions)
        let copied = DiagramNode(text: "Copied local drawing")
        source.pages = [DiagramPage(name: "Replacement page")]
        source.pages[0].nodes = [copied]
        source.activePageID = source.pages[0].id
        XCTAssertFalse(registry.uses.contains { $0.pageID == source.activePageID || $0.objectID == copied.id })
        XCTAssertEqual(try source.validated().definitions, registry)
    }

    func testDeletedSectionKeepsItsRowsDeletedDespiteExplicitRowFlag() throws {
        let element = try VisioXML.element("<Shape ID=\"1\"><Section N=\"User\" Del=\"1\"><Row N=\"Hidden\" Del=\"0\"><Cell N=\"Value\" V=\"1\"/></Row></Section></Shape>")
        let sheet = DefinitionRegistry.sheet(element, scope: UUID(), publicID: "1")
        XCTAssertEqual(sheet.rows.first?.deleted, true)
    }
}
