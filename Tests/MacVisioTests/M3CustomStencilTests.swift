import AppKit
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

/// Public source is authored independently of the production stencil writer.
enum CustomStencilTestFixture {
    static let ns = "http://schemas.microsoft.com/office/visio/2012/main"
    static let rel = "http://schemas.microsoft.com/visio/2010/relationships/"
    static let opc = "http://schemas.openxmlformats.org/package/2006/relationships"
    static let r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static func parts(opaque: Bool = false) -> [String: Data] {
        let strings = [
            "[Content_Types].xml": """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="png" ContentType="image/png"/><Default Extension="bin" ContentType="application/octet-stream"/><Override PartName="/visio/document.xml" ContentType="application/vnd.ms-visio.stencil.main+xml"/><Override PartName="/visio/masters/masters.xml" ContentType="application/vnd.ms-visio.masters+xml"/><Override PartName="/visio/masters/master7.xml" ContentType="application/vnd.ms-visio.master+xml"/><Override PartName="/visio/masters/master42.xml" ContentType="application/vnd.ms-visio.master+xml"/></Types>
            """,
            "_rels/.rels": "<Relationships xmlns=\"\(opc)\"><Relationship Id=\"document\" Type=\"\(rel)document\" Target=\"visio/document.xml\"/></Relationships>",
            "visio/document.xml": """
            <VisioDocument xmlns="\(ns)" xmlns:r="\(r)"><Colors><ColorEntry IX="0" RGB="#000000"/><ColorEntry IX="1" RGB="#FFFFFF"/></Colors><FaceNames><FaceName NameU="Arial"/></FaceNames><StyleSheets><StyleSheet ID="0" Name="No Style" NameU="No Style"><Cell N="LineColor" V="#000000"/></StyleSheet></StyleSheets><DocumentSheet NameU="TheDoc"><Cell N="DocLangID" V="en-US"/></DocumentSheet></VisioDocument>
            """,
            "visio/_rels/document.xml.rels": "<Relationships xmlns=\"\(opc)\"><Relationship Id=\"masters\" Type=\"\(rel)masters\" Target=\"masters/masters.xml\"/></Relationships>",
            "visio/masters/masters.xml": """
            <Masters xmlns="\(ns)" xmlns:r="\(r)" xmlns:extra="urn:example:opaque"><Master ID="007" Name="Same name" NameU="Alpha" BaseID="{00000000-0000-0000-0000-000000000007}" UniqueID="{10000000-0000-0000-0000-000000000007}" MatchByName="0"><PageSheet><Cell N="PageWidth" V="4"/><Cell N="PageHeight" V="3"/></PageSheet><Rel r:id="first"/></Master><!--between masters--><Master ID="42" Name="Same name" NameU="Beta" BaseID="{00000000-0000-0000-0000-000000000042}" UniqueID="{10000000-0000-0000-0000-000000000042}" MatchByName="0"><PageSheet><Cell N="PageWidth" V="4"/><Cell N="PageHeight" V="3"/></PageSheet><Rel r:id="second"/></Master></Masters>
            """,
            "visio/masters/_rels/masters.xml.rels": "<Relationships xmlns=\"\(opc)\"><Relationship Id=\"first\" Type=\"\(rel)master\" Target=\"master7.xml\"/><Relationship Id=\"second\" Type=\"\(rel)master\" Target=\"master42.xml\"/></Relationships>",
            "visio/masters/master7.xml": content(width: "2", text: "First public master", opaque: opaque),
            "visio/masters/master42.xml": content(width: "3", text: "Second public master", opaque: false),
            "visio/masters/_rels/master7.xml.rels": "<Relationships xmlns=\"\(opc)\"><Relationship Id=\"media\" Type=\"\(rel)image\" Target=\"../media/pixel.png\"/></Relationships>"
        ]
        var result = strings.mapValues { Data($0.utf8) }
        result["visio/media/pixel.png"] = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8S8AAAAASUVORK5CYII=")!
        if opaque { result["custom/payload.bin"] = Data([0, 255, 19, 87, 0, 4]); result["custom/payload.xml"] = Data("<extra:Payload xmlns:extra=\"urn:example:opaque\" SourceMaster=\"42\">retained</extra:Payload>".utf8) }
        return result
    }
    private static func content(width: String, text: String, opaque: Bool) -> String {
        """
        <MasterContents xmlns="\(ns)" xmlns:r="\(r)" xmlns:extra="urn:example:opaque"><Shapes><Shape ID="1" Type="Shape" NameU="Root" LineStyle="0" FillStyle="0" TextStyle="0"><Cell N="PinX" V="2"/><Cell N="PinY" V="1.5"/><Cell N="Width" V="\(width)" U="IN"\(opaque ? " extra:flag=\"keep\"" : "")/><Cell N="Height" V="1"/><Cell N="LocPinX" V="1"/><Cell N="LocPinY" V="0.5"/><Cell N="LineColor" V="#000000"/><Cell N="LineWeight" V="0.01"/><Cell N="FillForegnd" V="#FF0000"/><Cell N="FillPattern" V="1"/><Section N="Geometry" IX="0"><Row IX="1" T="MoveTo"><Cell N="X" V="0"/><Cell N="Y" V="0"/></Row><Row IX="2" T="LineTo"><Cell N="X" V="\(width)" F="Width"/><Cell N="Y" V="0"/></Row><Row IX="3" T="LineTo"><Cell N="X" V="\(width)" F="Width"/><Cell N="Y" V="1" F="Height"/></Row><Row IX="4" T="LineTo"><Cell N="X" V="0"/><Cell N="Y" V="1" F="Height"/></Row><Row IX="5" T="LineTo"><Cell N="X" V="0"/><Cell N="Y" V="0"/></Row></Section><Section N="User"><Row N="Code"><Cell N="Value" V="007" U="STR" F="No Formula"/><Cell N="Prompt" V="Keep this prompt"/></Row></Section><Text>\(text)</Text>\(opaque ? "<extra:Payload extra:owner=\"unmodeled\"><extra:Data>keep</extra:Data></extra:Payload>" : "")</Shape></Shapes></MasterContents>
        """
    }
    static func mutate(_ part: String, in parts: inout [String: Data], _ body: (XMLElement) throws -> Void) throws {
        let document = try VisioXML.document(XCTUnwrap(parts[part])); try body(XCTUnwrap(document.rootElement()))
        parts[part] = document.xmlData(options: .nodePreserveAll)
    }
}

final class M3CustomStencilTests: XCTestCase {
    private var temporary: [URL] = []
    override func tearDown() { temporary.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-custom-stencil-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); temporary.append(url); return url
    }
    private func source(_ parts: [String: Data]) throws -> StencilPackageSnapshot {
        let url = try folder().appendingPathComponent("Source.vssx"); try VisioPackage.write(parts, to: url)
        return try StencilPackageEditing.read(from: url)
    }

    func testNoEditAndRenameReorderPreservePublicIdentityGUIDsOrderAndOpaqueParts() throws {
        let original = try source(CustomStencilTestFixture.parts(opaque: true))
        XCTAssertEqual(original.masters.map(\.id), [7, 42]); XCTAssertEqual(original.masters.map(\.sourceID), ["007", "42"])
        let noEdit = try StencilPackageEditing.applying(.rename(masterID: 7, name: "Same name"), to: original)
        XCTAssertEqual(noEdit.resourceID, original.resourceID)
        var edited = try StencilPackageEditing.applying(.rename(masterID: 42, name: "Renamed"), to: original)
        edited = try StencilPackageEditing.applying(.move(masterID: 42, toIndex: 0), to: edited)
        XCTAssertEqual(edited.masters.map(\.id), [42, 7])
        XCTAssertEqual(edited.masters.first?.universalName, "Beta")
        for master in original.masters {
            let after = try XCTUnwrap(edited.masters.first { $0.id == master.id })
            XCTAssertEqual(after.part, master.part); XCTAssertEqual(after.sourceID, master.sourceID)
            XCTAssertEqual(after.baseID, master.baseID); XCTAssertEqual(after.uniqueID, master.uniqueID)
        }
        for (name, bytes) in original.parts where name != original.mastersPart { XCTAssertEqual(edited.parts[name], bytes, name) }
        XCTAssertTrue(String(decoding: edited.parts[edited.mastersPart]!, as: UTF8.self).contains("between masters"))
        let output = try folder().appendingPathComponent("Edited.vssx"); try VisioPackage.write(edited.parts, to: output)
        var publicParts = try VisioPackage.read(output); publicParts.removeValue(forKey: "macvisio/document.json")
        try VisioPackage.write(publicParts, to: output)
        let reloaded = try StencilPackageEditing.read(from: output)
        XCTAssertEqual(reloaded.masters.map(\.id), [42, 7]); XCTAssertEqual(reloaded.masters.map(\.name), ["Renamed", "Same name"])
        let publicMasters = try VisioStencil.read(from: output).items
        XCTAssertEqual(publicMasters.compactMap { $0.source?.masterID }, ["42", "007"])
        XCTAssertEqual(publicMasters.map(\.name), ["Renamed", "Same name"])
    }

    func testDuplicateAllocatesDistinctIdentityAndRetainsSamePackageMediaStylesAndOriginalBytes() throws {
        let original = try source(CustomStencilTestFixture.parts(opaque: true))
        let edited = try StencilPackageEditing.applying(.duplicate(masterID: 7, name: "Same name"), to: original)
        XCTAssertEqual(edited.masters.map(\.id), [7, 42, 43])
        let copy = try XCTUnwrap(edited.masters.last)
        XCTAssertNotEqual(copy.baseID, original.masters[0].baseID); XCTAssertNotEqual(copy.uniqueID, original.masters[0].uniqueID)
        XCTAssertNotEqual(copy.universalName, original.masters[0].universalName)
        XCTAssertNotEqual(copy.part, original.masters[0].part)
        XCTAssertEqual(edited.parts[copy.part], original.parts[original.masters[0].part])
        XCTAssertEqual(edited.parts[VisioXML.relationshipPart(copy.part)], original.parts[VisioXML.relationshipPart(original.masters[0].part)])
        XCTAssertEqual(edited.parts["visio/media/pixel.png"], original.parts["visio/media/pixel.png"])
        for (name, bytes) in original.parts where ![original.mastersPart, VisioXML.relationshipPart(original.mastersPart), "[Content_Types].xml"].contains(name) { XCTAssertEqual(edited.parts[name], bytes, name) }
        let output = try folder().appendingPathComponent("Duplicate.vssx"); try VisioPackage.write(edited.parts, to: output)
        let reopened = try VisioStencil.read(from: output).items
        XCTAssertEqual(reopened.count, 3); XCTAssertEqual(reopened[0].fragment.nodes.map(\.text), reopened[2].fragment.nodes.map(\.text))
    }

    func testLiteralEditPatchesOnlyExactMasterCellRetainsUnitFormulaMarkerAndUnknownXML() throws {
        let original = try source(CustomStencilTestFixture.parts(opaque: true))
        let cell = try XCTUnwrap(original.masters[0].cells.first { $0.address == DefinitionCellAddress(cell: "Width") })
        XCTAssertNil(cell.refusal)
        let edited = try StencilPackageEditing.applying(.literal(masterID: 7, shapeID: "1", address: cell.address, expected: cell.value, value: "4"), to: original)
        let part = try XCTUnwrap(edited.parts[original.masters[0].part])
        let root = try XCTUnwrap(VisioXML.document(part).rootElement()), shape = try XCTUnwrap(root.firstLocal("Shapes")?.firstLocal("Shape"))
        let width = try XCTUnwrap(shape.elementsLocal("Cell").first { $0.attr("N") == "Width" })
        XCTAssertEqual(width.attr("V"), "4"); XCTAssertEqual(width.attr("U"), "IN"); XCTAssertEqual(width.attr("extra:flag"), "keep")
        XCTAssertTrue(String(decoding: part, as: UTF8.self).contains("extra:Payload"))
        for (name, bytes) in original.parts where name != original.masters[0].part { XCTAssertEqual(edited.parts[name], bytes, name) }
        let code = try XCTUnwrap(edited.masters[0].cells.first { $0.address.section == "User" && $0.address.rowName == "Code" && $0.address.cell == "Value" })
        let next = try StencilPackageEditing.applying(.literal(masterID: 7, shapeID: "1", address: code.address, expected: code.value, value: "009"), to: edited)
        let after = try XCTUnwrap(next.masters[0].cells.first { $0.address == code.address })
        XCTAssertEqual(after.value.formula, "No Formula"); XCTAssertEqual(after.value.unit, "STR"); XCTAssertEqual(after.value.value, "009")
        let output = try folder().appendingPathComponent("Literal.vssx"); try VisioPackage.write(next.parts, to: output)
        var parts = try VisioPackage.read(output); parts.removeValue(forKey: "macvisio/document.json"); try VisioPackage.write(parts, to: output)
        let reopened = try VisioStencil.read(from: output).items
        XCTAssertEqual(reopened[0].fragment.nodes.first?.width, 4 * 72)
        XCTAssertEqual(reopened[1].fragment.nodes.first?.width, 3 * 72)
    }

    func testFormulaInheritanceAndStaleCellEditsAreRefusedWithoutChangingSource() throws {
        for formula in ["GUARD(2)", "Inh"] {
            var parts = CustomStencilTestFixture.parts()
            try CustomStencilTestFixture.mutate("visio/masters/master7.xml", in: &parts) { root in
                root.firstLocal("Shapes")!.firstLocal("Shape")!.elementsLocal("Cell").first { $0.attr("N") == "Width" }!.setAttr("F", formula)
            }
            let input = try source(parts), cell = try XCTUnwrap(input.masters[0].cells.first { $0.address.cell == "Width" })
            XCTAssertNotNil(cell.refusal)
            XCTAssertThrowsError(try StencilPackageEditing.applying(.literal(masterID: 7, shapeID: "1", address: cell.address, expected: cell.value, value: "9"), to: input))
            XCTAssertEqual(try VisioPackage.read(input.sourceURL), input.parts)
        }
        var parts = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("visio/masters/master42.xml", in: &parts) { $0.firstLocal("Shapes")!.firstLocal("Shape")!.setAttr("Master", "007") }
        let inherited = try source(parts), inheritedCell = try XCTUnwrap(inherited.masters[1].cells.first { $0.address.cell == "Width" })
        XCTAssertNotNil(inheritedCell.refusal)
        XCTAssertThrowsError(try StencilPackageEditing.applying(.literal(masterID: 42, shapeID: "1", address: inheritedCell.address, expected: inheritedCell.value, value: "9"), to: inherited))
        let plain = try source(CustomStencilTestFixture.parts()), width = try XCTUnwrap(plain.masters[0].cells.first { $0.address.cell == "Width" })
        XCTAssertThrowsError(try StencilPackageEditing.applying(.literal(masterID: 7, shapeID: "1", address: width.address, expected: ShapeSheetCell(value: "stale"), value: "9"), to: plain))
        XCTAssertThrowsError(try StencilPackageEditing.applying(.literal(masterID: 7, shapeID: "1", address: width.address, expected: width.value, value: " Inh "), to: plain))
        XCTAssertThrowsError(try StencilPackageEditing.applying(.literal(masterID: 7, shapeID: "1", address: width.address, expected: width.value, value: "nan"), to: plain))
    }

    func testInheritedStyleFormulaAndSharedMasterPartsRefuseLiteralEdits() throws {
        var parts = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("visio/document.xml", in: &parts) { root in
            root.firstLocal("StyleSheets")!.firstLocal("StyleSheet")!.addChild(try VisioXML.element("<Cell xmlns=\"\(CustomStencilTestFixture.ns)\" N=\"Width\" V=\"2\" F=\"1+1\"/>"))
        }
        let styled = try source(parts), width = try XCTUnwrap(styled.masters[0].cells.first { $0.address.cell == "Width" })
        XCTAssertNotNil(width.refusal)
        parts = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("visio/masters/_rels/masters.xml.rels", in: &parts) { $0.elementsLocal("Relationship")[1].setAttr("Target", "master7.xml") }
        let shared = try source(parts), sharedCell = try XCTUnwrap(shared.masters[0].cells.first { $0.address.cell == "Width" })
        XCTAssertThrowsError(try StencilPackageEditing.applying(.literal(masterID: 7, shapeID: "1", address: sharedCell.address, expected: sharedCell.value, value: "9"), to: shared))
        XCTAssertThrowsError(try StencilPackageEditing.applying(.delete(masterID: 7), to: shared))
    }

    func testSafeDeleteRetainsPartClosureAndReservesRemovedIDsForLaterDuplication() throws {
        let input = try source(CustomStencilTestFixture.parts())
        let deleted = try StencilPackageEditing.applying(.delete(masterID: 42), to: input)
        XCTAssertEqual(deleted.masters.map(\.id), [7]); XCTAssertEqual(deleted.parts["visio/masters/master42.xml"], input.parts["visio/masters/master42.xml"])
        XCTAssertEqual(deleted.parts["visio/media/pixel.png"], input.parts["visio/media/pixel.png"])
        let next = try StencilPackageEditing.applying(.duplicate(masterID: 7, name: "Copy"), to: deleted)
        XCTAssertEqual(next.masters.map(\.id), [7, 43])
        let output = try folder().appendingPathComponent("Deleted.vssx"); try VisioPackage.write(deleted.parts, to: output)
        XCTAssertEqual(try VisioStencil.read(from: output).items.count, 1)
        XCTAssertThrowsError(try StencilPackageEditing.applying(.delete(masterID: 7), to: deleted))
    }

    func testDeletionRefusesKnownMasterReferencesRelationshipsAndOpaqueDependencies() throws {
        var referenced = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("visio/masters/master42.xml", in: &referenced) { $0.firstLocal("Shapes")!.firstLocal("Shape")!.setAttr("Master", "007") }
        XCTAssertThrowsError(try StencilPackageEditing.applying(.delete(masterID: 7), to: source(referenced)))
        var relationship = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("visio/masters/_rels/master7.xml.rels", in: &relationship) {
            $0.addChild(try VisioXML.element("<Relationship xmlns=\"\(CustomStencilTestFixture.opc)\" Id=\"dependency\" Type=\"\(CustomStencilTestFixture.rel)master\" Target=\"master42.xml\"/>"))
        }
        XCTAssertThrowsError(try StencilPackageEditing.applying(.delete(masterID: 42), to: source(relationship)))
        let opaque = try source(CustomStencilTestFixture.parts(opaque: true))
        XCTAssertThrowsError(try StencilPackageEditing.applying(.delete(masterID: 42), to: opaque))
        XCTAssertEqual(try VisioPackage.read(opaque.sourceURL), opaque.parts)
    }

    func testShortcutIDsAndSourceIDsAreReservedAndShortcutDeletionIsRefused() throws {
        var parts = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("visio/masters/masters.xml", in: &parts) {
            $0.addChild(try VisioXML.element("<MasterShortcut xmlns=\"\(CustomStencilTestFixture.ns)\" ID=\"900\" Name=\"Shortcut\" SourceMaster=\"1000\" SourceDocument=\"external\"/>"))
        }
        let input = try source(parts), duplicate = try StencilPackageEditing.applying(.duplicate(masterID: 7, name: "Copy"), to: input)
        XCTAssertEqual(duplicate.masters.last?.id, 1001)
        XCTAssertTrue(String(decoding: duplicate.parts[input.mastersPart]!, as: UTF8.self).contains("MasterShortcut"))
        XCTAssertThrowsError(try StencilPackageEditing.applying(.delete(masterID: 42), to: input))
    }

    func testNamespaceLookalikesAreRetainedWithoutBecomingEditableOwners() throws {
        var parts = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("visio/masters/masters.xml", in: &parts) {
            $0.addChild(try VisioXML.element("<extra:Master xmlns:extra=\"urn:example:opaque\" ID=\"42\" Name=\"extension\"/>"))
        }
        try CustomStencilTestFixture.mutate("visio/masters/master7.xml", in: &parts) {
            $0.firstLocal("Shapes")!.firstLocal("Shape")!.addChild(try VisioXML.element("<extra:Cell xmlns:extra=\"urn:example:opaque\" N=\"Width\" V=\"999\"/>"))
        }
        let input = try source(parts)
        XCTAssertEqual(input.masters.count, 2)
        XCTAssertEqual(input.masters[0].cells.filter { $0.address.cell == "Width" }.count, 1)
        let renamed = try StencilPackageEditing.applying(.rename(masterID: 42, name: "Actual master"), to: input)
        let index = try XCTUnwrap(VisioXML.document(renamed.parts[renamed.mastersPart]!).rootElement())
        XCTAssertEqual(index.elementsLocal("Master").first { $0.uri == "urn:example:opaque" }?.attr("Name"), "extension")
        let width = try XCTUnwrap(input.masters[0].cells.first { $0.address.cell == "Width" })
        let edited = try StencilPackageEditing.applying(.literal(masterID: 7, shapeID: "1", address: width.address, expected: width.value, value: "4"), to: input)
        let shape = try XCTUnwrap(VisioXML.document(edited.parts[input.masters[0].part]!).rootElement()?.firstLocal("Shapes")?.firstLocal("Shape"))
        XCTAssertEqual(shape.elementsLocal("Cell").first { $0.uri == "urn:example:opaque" }?.attr("V"), "999")
        XCTAssertThrowsError(try StencilPackageEditing.applying(.delete(masterID: 42), to: input))
        var wrong = CustomStencilTestFixture.parts()
        wrong["visio/masters/_rels/masters.xml.rels"] = Data("<Relationships xmlns=\"urn:wrong\"><Relationship Id=\"first\" Target=\"master7.xml\" Type=\"\(CustomStencilTestFixture.rel)master\"/></Relationships>".utf8)
        XCTAssertThrowsError(try source(wrong))
    }

    func testOwnedSaveAsRejectsSourceAliasesAndStaleInputsAndWritesPublicSnapshot() throws {
        try onMain {
            _ = NSApplication.shared
            let input = try source(CustomStencilTestFixture.parts()), directory = try folder()
            let edited = try StencilPackageEditing.applying(.rename(masterID: 7, name: "Saved public name"), to: input)
            let owner = LifecycleJobOwner(), identity = LifecycleJobInput(ownerID: owner.id, snapshotID: UUID(), revision: 3)
            let alias = directory.appendingPathComponent("Alias.vssx")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: input.sourceURL)
            var result: Result<URL, Error>?
            try StencilPackageJobs.saveCopy(edited, to: alias, input: identity, owner: owner, accepts: { $0 == identity }) { result = $0 }
            try pump { result != nil }
            XCTAssertThrowsError(try XCTUnwrap(result).get()) { XCTAssertEqual($0 as? LifecycleJobError, .inputIsDestination) }
            XCTAssertEqual(try VisioPackage.read(input.sourceURL), input.parts)
            let output = directory.appendingPathComponent("Copy.vssx")
            XCTAssertThrowsError(try StencilPackageJobs.saveCopy(edited, to: output, input: identity, owner: owner, accepts: { _ in false }) { _ in XCTFail("Stale submission cannot publish") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            result = nil
            try StencilPackageJobs.saveCopy(edited, to: output, input: identity, owner: owner, accepts: { $0 == identity }) { result = $0 }
            try pump { result != nil }; _ = try XCTUnwrap(result).get()
            var publicParts = try VisioPackage.read(output); publicParts.removeValue(forKey: "macvisio/document.json"); try VisioPackage.write(publicParts, to: output)
            XCTAssertEqual(try VisioStencil.read(from: output).items.first?.name, "Saved public name")
            XCTAssertEqual(try VisioPackage.read(input.sourceURL), input.parts)
        }
    }

    func testHostileDocumentTypeRelationshipAndStyleOwnersAreRefused() throws {
        let ns = CustomStencilTestFixture.ns
        var wrongDocument = CustomStencilTestFixture.parts()
        wrongDocument["visio/document.xml"] = Data("<NotVisioDocument xmlns=\"\(ns)\"/>".utf8)
        XCTAssertThrowsError(try source(wrongDocument))
        var wrongTypes = CustomStencilTestFixture.parts()
        wrongTypes["[Content_Types].xml"] = Data("<NotTypes xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>".utf8)
        XCTAssertThrowsError(try source(wrongTypes))
        var duplicateType = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("[Content_Types].xml", in: &duplicateType) {
            $0.addChild($0.elementsLocal("Override")[0].copy() as! XMLElement)
        }
        XCTAssertThrowsError(try source(duplicateType))
        var foreignType = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("[Content_Types].xml", in: &foreignType) { root in
            root.elementsLocal("Override").first { $0.attr("PartName") == "/visio/document.xml" }!.detach()
            root.addChild(try VisioXML.element("<extra:Override xmlns:extra=\"urn:wrong\" PartName=\"/visio/document.xml\" ContentType=\"application/vnd.ms-visio.stencil.main+xml\"/>"))
        }
        XCTAssertThrowsError(try source(foreignType))
        var badRelationships = CustomStencilTestFixture.parts()
        badRelationships["_rels/.rels"] = Data("<Relationships xmlns=\"urn:wrong\"><Relationship Id=\"document\" Type=\"\(CustomStencilTestFixture.rel)document\" Target=\"visio/document.xml\"/></Relationships>".utf8)
        XCTAssertThrowsError(try source(badRelationships))
        var duplicateDocument = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("_rels/.rels", in: &duplicateDocument) {
            let copy = $0.firstLocal("Relationship")!.copy() as! XMLElement; copy.setAttr("Id", "second-document"); $0.addChild(copy)
        }
        XCTAssertThrowsError(try source(duplicateDocument))
        var duplicateStyle = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("visio/document.xml", in: &duplicateStyle) { root in
            let owner = root.firstLocal("StyleSheets")!, copy = owner.firstLocal("StyleSheet")!.copy() as! XMLElement
            copy.setAttr("ID", "000"); owner.addChild(copy)
        }
        XCTAssertThrowsError(try source(duplicateStyle))
        var duplicateStyleOwner = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate("visio/document.xml", in: &duplicateStyleOwner) { $0.addChild($0.firstLocal("StyleSheets")!.copy() as! XMLElement) }
        XCTAssertThrowsError(try source(duplicateStyleOwner))
        var foreignStyleOwner = CustomStencilTestFixture.parts()
        foreignStyleOwner["visio/document.xml"] = Data("<VisioDocument xmlns=\"\(ns)\"><extra:StyleSheets xmlns:extra=\"urn:wrong\"><extra:StyleSheet ID=\"0\"/></extra:StyleSheets><DocumentSheet/></VisioDocument>".utf8)
        let retained = try source(foreignStyleOwner)
        XCTAssertTrue(retained.masters[0].cells.allSatisfy { $0.refusal != nil }, "Foreign lookalike styles do not prove inherited cell ownership.")
    }

    func testDuplicateAvoidsCaseAliasPartNamesAndRefusesMissingDependencies() throws {
        var parts = CustomStencilTestFixture.parts()
        parts["visio/masters/MACVISIO-MASTER-43-1.XML"] = Data("occupied opaque part".utf8)
        let input = try source(parts), copy = try StencilPackageEditing.applying(.duplicate(masterID: 7, name: "Copy"), to: input)
        XCTAssertEqual(copy.masters.last?.part, "visio/masters/macvisio-master-43-2.xml")
        XCTAssertEqual(copy.parts["visio/masters/MACVISIO-MASTER-43-1.XML"], parts["visio/masters/MACVISIO-MASTER-43-1.XML"])
        var missing = CustomStencilTestFixture.parts(); missing.removeValue(forKey: "visio/media/pixel.png")
        XCTAssertThrowsError(try StencilPackageEditing.applying(.duplicate(masterID: 7, name: "Copy"), to: source(missing)))
    }

    func testDeletionRefusesOpaqueRelationshipPayloadsAndAttributesWhileRenamePreservesThem() throws {
        let part = "visio/masters/_rels/master7.xml.rels"
        for variant in ["nested", "attribute", "rootAttribute", "rootUnqualifiedAttribute", "relationshipUnqualifiedAttribute"] {
            var parts = CustomStencilTestFixture.parts()
            try CustomStencilTestFixture.mutate(part, in: &parts) { root in
                root.addNamespace(XMLNode.namespace(withName: "extra", stringValue: "urn:example:dependency") as! XMLNode)
                switch variant {
                case "nested":
                    root.firstLocal("Relationship")!.addChild(try VisioXML.element("<extra:Dependency xmlns:extra=\"urn:example:dependency\" SourceMaster=\"42\"/>"))
                case "attribute": root.firstLocal("Relationship")!.setAttr("extra:SourceMaster", "42")
                case "rootAttribute": root.setAttr("extra:SourceMaster", "42")
                case "rootUnqualifiedAttribute": root.setAttr("SourceMaster", "42")
                default: root.firstLocal("Relationship")!.setAttr("SourceMaster", "42")
                }
            }
            let input = try source(parts)
            XCTAssertThrowsError(try StencilPackageEditing.applying(.delete(masterID: 42), to: input), variant) {
                XCTAssertTrue($0.localizedDescription.localizedCaseInsensitiveContains("relationship"), variant)
            }
            let renamed = try StencilPackageEditing.applying(.rename(masterID: 7, name: "Source preserving rename"), to: input)
            XCTAssertEqual(renamed.parts[part], input.parts[part], variant)
            XCTAssertEqual(renamed.masters[0].name, "Source preserving rename")
            XCTAssertEqual(try VisioPackage.read(input.sourceURL), input.parts, variant)
        }
        var namespacesOnly = CustomStencilTestFixture.parts()
        try CustomStencilTestFixture.mutate(part, in: &namespacesOnly) {
            $0.addNamespace(XMLNode.namespace(withName: "extra", stringValue: "urn:unused:namespace") as! XMLNode)
        }
        let permitted = try StencilPackageEditing.applying(.delete(masterID: 42), to: source(namespacesOnly))
        XCTAssertEqual(permitted.masters.map(\.id), [7], "Namespace declarations alone do not assert an opaque dependency.")
    }

    func testDeletionRefusesUnknownCoreOwnersAttributesAndPropertyCarriersButRenameRetainsThem() throws {
        for variant in ["coreOwner", "shapeAttribute", "rowAttribute", "coreProperties", "extendedProperties", "unsupportedFormula"] {
            var parts = CustomStencilTestFixture.parts()
            var opaquePart = "visio/masters/master7.xml"
            if variant == "coreProperties" || variant == "extendedProperties" {
                let core = variant == "coreProperties"
                opaquePart = core ? "docProps/core.xml" : "docProps/app.xml"
                let uri = core ? "http://schemas.openxmlformats.org/package/2006/metadata/core-properties" : "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
                let owner = core ? "coreProperties" : "Properties"
                parts[opaquePart] = Data("<\(owner) xmlns=\"\(uri)\"><FutureDependency MasterRef=\"42\"/></\(owner)>".utf8)
                try CustomStencilTestFixture.mutate("_rels/.rels", in: &parts) { root in
                    let type = core ? "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" : CustomStencilTestFixture.r + "/extended-properties"
                    root.addChild(try VisioXML.element("<Relationship xmlns=\"\(CustomStencilTestFixture.opc)\" Id=\"properties\" Type=\"\(type)\" Target=\"\(opaquePart)\"/>"))
                }
            } else {
                try CustomStencilTestFixture.mutate(opaquePart, in: &parts) { root in
                    let shape = root.firstLocal("Shapes")!.firstLocal("Shape")!
                    switch variant {
                    case "coreOwner": root.addChild(try VisioXML.element("<FutureDependency xmlns=\"\(CustomStencilTestFixture.ns)\" MasterRef=\"42\"/>"))
                    case "shapeAttribute": shape.setAttr("VendorMasterRef", "42")
                    case "rowAttribute": shape.firstLocal("Section")!.firstLocal("Row")!.setAttr("VendorMasterRef", "42")
                    default: shape.elementsLocal("Cell").first { $0.attr("N") == "Width" }!.setAttr("F", "FutureMasterLookup(42)")
                    }
                }
            }
            let input = try source(parts)
            XCTAssertThrowsError(try StencilPackageEditing.applying(.delete(masterID: 42), to: input), variant)
            let renamed = try StencilPackageEditing.applying(.rename(masterID: 7, name: "Retain opaque owner"), to: input)
            XCTAssertEqual(renamed.parts[opaquePart], input.parts[opaquePart], variant)
            XCTAssertEqual(renamed.masters[0].name, "Retain opaque owner")
        }
    }

    func testDeletionFormulaProofParsesPureCallsAndQuotesButRefusesUnknownAndDynamicCalls() throws {
        for formula in ["GUARD(0.5)", "Width*0.5", "Sheet.1!Width*0.5", "GUARD(TheDoc!User.Code)",
                        "\"VendorLookup(42)\"", "\"Masters[42] INDIRECT(42)\"", "IF(1,\"VendorLookup(42)\",\"safe\")"] {
            var parts = CustomStencilTestFixture.parts()
            try CustomStencilTestFixture.mutate("visio/masters/master7.xml", in: &parts) {
                $0.firstLocal("Shapes")!.firstLocal("Shape")!.elementsLocal("Cell").first { $0.attr("N") == "Width" }!.setAttr("F", formula)
            }
            let input = try source(parts), deleted = try StencilPackageEditing.applying(.delete(masterID: 42), to: input)
            XCTAssertEqual(deleted.masters.map(\.id), [7], formula)
        }
        for formula in ["VendorLookup(42)", "VendorLookup(\"42\")", "IF(0,VendorLookup(42),1)",
                        "INDIRECT(\"Sheet.42!Width\")", "SETATREF(Width)", "Masters[42]!Width"] {
            var parts = CustomStencilTestFixture.parts()
            try CustomStencilTestFixture.mutate("visio/masters/master7.xml", in: &parts) {
                $0.firstLocal("Shapes")!.firstLocal("Shape")!.elementsLocal("Cell").first { $0.attr("N") == "Width" }!.setAttr("F", formula)
            }
            let input = try source(parts)
            XCTAssertThrowsError(try StencilPackageEditing.applying(.delete(masterID: 42), to: input), formula)
            let renamed = try StencilPackageEditing.applying(.rename(masterID: 7, name: "Keep original formula"), to: input)
            XCTAssertEqual(renamed.parts["visio/masters/master7.xml"], input.parts["visio/masters/master7.xml"], formula)
        }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
    private func pump(until complete: () -> Bool) throws {
        let end = Date().addingTimeInterval(30)
        while !complete() && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(complete(), "Owned custom stencil worker timed out")
    }
}
