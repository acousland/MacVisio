import XCTest
@testable import MacVisio

final class M3DefinitionIdentityTests: XCTestCase {
    private func fixture() throws -> Diagram {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/M3/m3-intelligent.vsdx")
        return try VisioFormat.read(from: url).diagram
    }

    func testCollidingDisplayNamesRetainScopedMasterStyleAndSheetIdentities() throws {
        let diagram = try fixture()
        let registry = try XCTUnwrap(diagram.definitions)
        XCTAssertEqual(registry.masters.map(\.publicID), ["7", "8"])
        XCTAssertEqual(Set(registry.masters.map(\.name)), ["Same display"])
        XCTAssertEqual(Set(registry.masters.map(\.universalName)), ["Intelligent.Blue", "Intelligent.Green"])
        XCTAssertNotEqual(registry.masters[0].id, registry.masters[1].id)
        XCTAssertEqual(registry.masters.map { $0.sheets[0].publicID }, ["1", "1"])
        XCTAssertNotEqual(registry.masters[0].sheets[0].id, registry.masters[1].sheets[0].id)
        let styles = registry.styles.filter { ["4", "5"].contains($0.publicID) }
        XCTAssertEqual(styles.count, 2)
        XCTAssertEqual(styles[0].name, styles[1].name)
        XCTAssertNotEqual(styles[0].id, styles[1].id)
        let instances = registry.uses.filter { $0.masterID != nil }
        XCTAssertEqual(Set(instances.compactMap(\.masterID)), Set(registry.masters.map(\.id)))
    }

    func testRootAndIndexedNamedCellsRetainFormulaCacheUnitAndRowIdentity() throws {
        let registry = try XCTUnwrap(fixture().definitions)
        let sheet = registry.masters[0].sheets[0]
        XCTAssertEqual(sheet.cell(DefinitionCellAddress(cell: "LocPinX"))?.formula, "Width/2")
        let control = DefinitionCellAddress(cell: "X", section: "Control", rowName: "Handle", rowIndex: "0")
        XCTAssertEqual(sheet.cell(control)?.formula, "Width/2")
        XCTAssertEqual(sheet.rows.first { $0.section == "Control" }?.name, "Handle")
        XCTAssertEqual(sheet.rows.first { $0.section == "Control" }?.index, "0")
        XCTAssertEqual(registry.documentSheet?.cell(DefinitionCellAddress(cell: "Value", section: "User", rowName: "Revision"))?.value, "1")
        let local = try XCTUnwrap(registry.uses.first { $0.localSheet.attributes["NameU"] == "Instance.Blue" })
        XCTAssertEqual(local.localSheet.cell(DefinitionCellAddress(cell: "Width"))?.formula, "GUARD(2 in)")
        XCTAssertNil(local.localSheet.cell(DefinitionCellAddress(cell: "LocPinX")))
    }

    func testNativeRoundTripAndOlderSourceBackedMigrationPreserveSemanticScope() throws {
        let diagram = try fixture()
        let data = try JSONEncoder().encode(diagram)
        XCTAssertEqual(try JSONDecoder().decode(Diagram.self, from: data).validated().definitions, diagram.definitions)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "definitions")
        let migrated = try JSONDecoder().decode(Diagram.self, from: JSONSerialization.data(withJSONObject: old)).validated()
        XCTAssertEqual(migrated.definitions?.masters.map(\.publicID), diagram.definitions?.masters.map(\.publicID))
        var sourceFree = Diagram()
        sourceFree.pages[0].nodes = [DiagramNode()]
        XCTAssertNil(try sourceFree.validated().definitions)
    }

    func testDefinitionOnlyEditParticipatesInSemanticChangeSet() throws {
        let old = try fixture()
        var next = old
        next.definitions!.styles[1].sheets[0].set(DefinitionCellAddress(cell: "LineColor"),
            to: ShapeSheetCell(value: "#010203"))
        let changes = DocumentChangeSet.between(old, next)
        XCTAssertTrue(changes.documentPropertiesChanged)
        XCTAssertTrue(changes.hasSemanticChanges)
        XCTAssertTrue(changes.pages.isEmpty)
        XCTAssertEqual(next.definitions?.styles[1].id, old.definitions?.styles[1].id)
    }

    func testDuplicatePublicDefinitionIDsAndInvalidHierarchyAreRejected() throws {
        var diagram = try fixture()
        diagram.definitions!.masters[1].publicID = "7"
        XCTAssertThrowsError(try diagram.validated())
        diagram = try fixture()
        let id = diagram.definitions!.masters[0].sheets[0].id
        diagram.definitions!.masters[0].sheets[0].parentID = id
        XCTAssertThrowsError(try diagram.validated())
    }
}
