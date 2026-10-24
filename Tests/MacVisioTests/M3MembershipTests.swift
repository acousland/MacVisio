import Foundation
import CryptoKit
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

/// Authored public XML, independent expected XML, and local native contracts.
/// These tests do not establish exact Microsoft Visio runtime acceptance.
enum M3MembershipFixture {
    static func resource(_ name: String, ext: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures/M3/wp-14-t01-c003"))
    }
    static func parts() throws -> [String: Data] { try VisioPackage.read(resource("source", ext: "vsdx")) }
    static func drawing() throws -> Diagram { try VisioFormat.readPublic(parts: parts(), title: "Authored memberships").diagram }
    static func id(_ publicID: String, in diagram: Diagram) throws -> UUID {
        if let node = diagram.page.nodes.first(where: { $0.formatting.sourceShapeID.flatMap(UInt32.init) == UInt32(publicID) }) { return node.id }
        return try XCTUnwrap(diagram.page.edges.first { $0.sourceShapeID.flatMap(UInt32.init) == UInt32(publicID) }?.id)
    }
    static func stripped(_ parts: [String: Data]) throws -> [String: Data] {
        var result = parts.filter { !$0.key.hasPrefix("macvisio/") }
        let types = try VisioXML.document(XCTUnwrap(result["[Content_Types].xml"]))
        for value in types.rootElement()?.elementsLocal("Override") ?? [] where value.attr("PartName")?.hasPrefix("/macvisio/") == true { value.detach() }
        if !result.keys.contains(where: { $0.hasSuffix(".json") }) {
            for value in types.rootElement()?.elementsLocal("Default") ?? [] where value.attr("Extension") == "json" { value.detach() }
        }
        result["[Content_Types].xml"] = types.xmlData(options: .nodePreserveAll)
        return result
    }
    static func signature(_ bytes: Data) throws -> String {
        func visit(_ value: XMLNode) -> String {
            if let element = value as? XMLElement {
                let attrs = (element.attributes ?? []).map { ($0.name ?? "") + "=" + ($0.stringValue ?? "") }.sorted().joined(separator: "|")
                return "<\(element.uri ?? ""):\(element.localName ?? "")|\(attrs)>" + (element.children ?? []).map(visit).joined() + "</>"
            }
            let text = value.stringValue ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "[\(value.kind.rawValue):\(text)]"
        }
        return visit(try XCTUnwrap(VisioXML.document(bytes).rootElement()))
    }
    enum RetainedOwnerCase: CaseIterable, Equatable {
        case master, masterShape, ancestorMaster, deletedShape, deletedAncestor
        case deletedUserRow, deletedUserSection, foreignUserSection, unknownUserRowAttribute
        case foreignShapeOwnershipAttribute, staleLexicalID, missingBoundOwner
    }

    /// Independently authored public XML paired with an older native cache.
    /// Shape12 has no local Relationships in either view. Source master/policy,
    /// tombstone and ownership changes must not be hidden by that absent cell.
    /// This deliberately adversarial input does not claim Visio qualification.
    static func retainedOwnerWithoutRelationships(_ variant: RetainedOwnerCase) throws -> Diagram {
        var result = try drawing(), source = try XCTUnwrap(result.visioArchive), parts = source.parts
        let xml = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        let shapes = try XCTUnwrap(xml.rootElement()?.firstLocal("Shapes"))
        let target = try XCTUnwrap(shapes.allShapes.first { $0.attr("ID") == "12" })
        let group = try XCTUnwrap(shapes.allShapes.first { $0.attr("ID") == "10" })
        let ns = DiagramMemberships.namespace
        if variant == .ancestorMaster || variant == .deletedAncestor {
            // Keep an unrelated existing Relationships owner outside the
            // uncertain ancestor so the nil-cell guard is the refusal cause.
            let unrelated = try XCTUnwrap(shapes.allShapes.first { $0.attr("ID") == "11" })
            unrelated.detach(); shapes.addChild(unrelated)
        }
        switch variant {
        case .master:
            target.setAttr("Master", "7")
            target.addChild(try VisioXML.element("<Section xmlns=\"\(ns)\" N=\"User\"><Row N=\"msvSDContainerResize\"><Cell N=\"Value\" V=\"0\"/></Row></Section>"))
        case .masterShape: target.setAttr("MasterShape", "1")
        case .ancestorMaster: group.setAttr("Master", "7")
        case .deletedShape: target.setAttr("Del", "1")
        case .deletedAncestor: group.setAttr("Del", "1")
        case .deletedUserRow:
            target.addChild(try VisioXML.element("<Section xmlns=\"\(ns)\" N=\"User\"><Row N=\"msvStructureType\" Del=\"1\"><Cell N=\"Value\" V=\"Container\" U=\"STR\"/></Row></Section>"))
        case .deletedUserSection:
            target.addChild(try VisioXML.element("<Section xmlns=\"\(ns)\" N=\"User\" Del=\"1\"><Row N=\"msvStructureType\"><Cell N=\"Value\" V=\"Container\" U=\"STR\"/></Row></Section>"))
        case .foreignUserSection:
            target.addChild(try VisioXML.element("<extra:Section xmlns:extra=\"urn:unproven-owner\" xmlns=\"\(ns)\" N=\"User\"><Row N=\"msvStructureType\"><Cell N=\"Value\" V=\"Container\" U=\"STR\"/></Row></extra:Section>"))
        case .unknownUserRowAttribute:
            target.addChild(try VisioXML.element("<Section xmlns=\"\(ns)\" N=\"User\"><Row N=\"msvStructureType\" UnknownOwner=\"7\"><Cell N=\"Value\" V=\"Container\" U=\"STR\"/></Row></Section>"))
        case .foreignShapeOwnershipAttribute: target.setAttr("ext:Master", "7")
        case .staleLexicalID: target.setAttr("ID", "012")
        case .missingBoundOwner: target.detach()
        }
        if [.master, .masterShape, .ancestorMaster].contains(variant) {
            let rel = "http://schemas.openxmlformats.org/package/2006/relationships"
            let vr = "http://schemas.microsoft.com/visio/2010/relationships/"
            let documentRels = try VisioXML.document(XCTUnwrap(parts["visio/_rels/document.xml.rels"]))
            documentRels.rootElement()?.addChild(try VisioXML.element("<Relationship xmlns=\"\(rel)\" Id=\"rIdOwnerProof\" Type=\"\(vr)masters\" Target=\"masters/masters.xml\"/>"))
            parts["visio/_rels/document.xml.rels"] = documentRels.xmlData(options: .nodePreserveAll)
            parts["visio/masters/masters.xml"] = Data("<Masters xmlns=\"\(ns)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><Master ID=\"7\" NameU=\"Unproven inherited owner\"><Rel r:id=\"rId1\"/></Master></Masters>".utf8)
            parts["visio/masters/_rels/masters.xml.rels"] = Data("<Relationships xmlns=\"\(rel)\"><Relationship Id=\"rId1\" Type=\"\(vr)master\" Target=\"master7.xml\"/></Relationships>".utf8)
            parts["visio/masters/master7.xml"] = Data("<MasterContents xmlns=\"\(ns)\" xmlns:extra=\"urn:retained-owner-proof\"><Shapes><Shape ID=\"1\" Type=\"Shape\"><Cell N=\"Relationships\" V=\"0\" F=\"0\" U=\"BOOL\"/><Cell N=\"LockDelete\" V=\"1\"/><Section N=\"User\"><Row N=\"msvStructureType\"><Cell N=\"Value\" V=\"Container\" U=\"STR\"/></Row><Row N=\"msvSDUnknownPolicy\"><Cell N=\"Value\" V=\"1\"/></Row></Section><extra:Policy extra:owner=\"7\">retained unknown policy</extra:Policy></Shape></Shapes></MasterContents>".utf8)
            let types = try VisioXML.document(XCTUnwrap(parts["[Content_Types].xml"]))
            for (part, contentType) in [("masters.xml", "masters"), ("master7.xml", "master")] {
                types.rootElement()?.addChild(try VisioXML.element("<Override xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\" PartName=\"/visio/masters/\(part)\" ContentType=\"application/vnd.ms-visio.\(contentType)+xml\"/>"))
            }
            parts["[Content_Types].xml"] = types.xmlData(options: .nodePreserveAll)
        }
        parts["visio/pages/page1.xml"] = xml.xmlData(options: .nodePreserveAll)
        source.parts = parts; result.visioArchive = source
        return result
    }

    static func mixedNative() -> Diagram {
        var container = DiagramNode(x: 80, y: 70, text: "Native container")
        container.formatting.sourceShapeID = "10"
        container.formatting.sheet["User.msvStructureType"] = ShapeSheetCell(value: "Container", formula: "\"Container\"", unit: "STR")
        container.formatting.sheet["User.msvSDContainerResize"] = ShapeSheetCell(value: "0")
        container.formatting.sheet["Relationships"] = ShapeSheetCell(value: "0", formula: "SUM(DEPENDSON(1))")
        var member = DiagramNode(x: 350, y: 150, text: "Implicit Sheet.2")
        member.formatting.sheet["Relationships"] = ShapeSheetCell(value: "0", formula: "SUM(DEPENDSON(4))")
        var reader = DiagramNode(x: 600, y: 300, text: "Incoming reference")
        reader.formatting.sourceShapeID = "30"
        reader.formatting.sheet["User.Incoming"] = ShapeSheetCell(value: "2.2222222222222223", formula: "Sheet.2!Width", unit: "IN")
        var edge = DiagramEdge(source: member.id, target: reader.id)
        edge.sourceShapeID = "50"
        edge.formatting.sheet["User.Incoming"] = ShapeSheetCell(value: "2.2222222222222223", formula: "Sheet.2!Width", unit: "IN")
        var result = Diagram(); result.page.nodes = [container, member, reader]; result.page.edges = [edge]
        return result
    }
}

/// Opt-in retention of actual files emitted by the existing save tests. Fixed
/// test directories bound the retained set; capture is evidence, not acceptance.
/// The helper never serializes or repairs a VSDX package.
enum M3MembershipEvidence {
    private static let packageLimit = 16 * 1_024 * 1_024
    private static let manifestLimit = 64 * 1_024
    private static let allowed: [String: Set<String>] = [
        "M3MembershipTests": [
            "testActualPublicSaveStripPrivateReopenPreservesIndependentMembership()",
            "testConnectorMembershipRetainsPrimaryPublicIdentityAndOrdinaryFormulaOnReopen()",
            "testMixedExplicitAndImplicitIDsFreezeExistingIncomingFormulaAddressThroughPublicReopen()",
            "testLastMemberDetachAuthorsZeroRatherThanAnEmptyClauseAndReopensPublicly()"
        ],
        "M3MembershipEditorTests": ["testNativeOneEdgeApplyUndoRedoAndActualPublicSaveReopen()"]
    ]
    fileprivate struct Artifact: Codable {
        let path: String
        let byteCount: Int
        let sha256: String
    }
    fileprivate struct ObjectIdentity: Codable {
        let kind: String
        let nativeUUID: UUID
        let publicID: String?
        let groupParentUUID: UUID?
        let sourceUUID: UUID?
        let targetUUID: UUID?
        let relationships: ShapeSheetCell?
        let structureType: ShapeSheetCell?
    }
    fileprivate struct Identity: Codable {
        let pageUUID: UUID
        let sourceResourceUUID: UUID?
        let sourceLineageUUID: UUID?
        let objects: [ObjectIdentity]
    }
    private struct Manifest: Codable {
        let schema: String
        let suite: String
        let test: String
        let inputKind: String
        let state: String
        let claim: String
        let native: Artifact
        var publicPackage: Artifact?
        let savedModel: Identity
        var publicReopen: Identity?
    }
    struct Capture {
        fileprivate let directory: URL
        fileprivate let suite: String
        fileprivate let test: String
        fileprivate let inputKind: String
        fileprivate let native: Artifact
        fileprivate let savedModel: Identity

        func finish(publicURL: URL, reopened: Diagram) throws {
            let publicData = try M3MembershipEvidence.boundedData(publicURL)
            let identity = try M3MembershipEvidence.identity(reopened)
            let artifact = M3MembershipEvidence.artifact("public.vsdx", publicData)
            let manifest = Manifest(schema: "macvisio.m3.membership-save.v1", suite: suite, test: test,
                inputKind: inputKind, state: "saved-and-stripped-files-captured",
                claim: "Actual local test outputs only. Consult the XCTest log for assertions; exact Visio/G2 acceptance remains unknown.",
                native: native, publicPackage: artifact, savedModel: savedModel, publicReopen: identity)
            let manifestData = try M3MembershipEvidence.encoded(manifest)
            try publicData.write(to: directory.appendingPathComponent("public.vsdx"), options: .atomic)
            try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }
    static func begin(suite: String, test: String, inputKind: String, nativeURL: URL, diagram: Diagram) throws -> Capture? {
        guard let path = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"], !path.isEmpty else { return nil }
        guard (path as NSString).isAbsolutePath, allowed[suite]?.contains(test) == true else {
            throw DiagramError.invalid("Membership evidence requires an absolute M3_EVIDENCE_DIR and a known save test.")
        }
        let nativeData = try boundedData(nativeURL), model = try identity(diagram)
        let native = artifact("native.vsdx", nativeData)
        let name = String(test.dropLast(2))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent(suite, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let manifest = Manifest(schema: "macvisio.m3.membership-save.v1", suite: suite, test: test,
            inputKind: inputKind, state: "saved-file-captured-before-strip",
            claim: "Actual local test output only; incomplete until public capture finishes. Consult the XCTest log; no acceptance claim.",
            native: native, publicPackage: nil, savedModel: model, publicReopen: nil)
        let manifestData = try encoded(manifest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Fixed names bound repeated runs and avoid a previous public file
        // masquerading as output from an incomplete current test.
        let publicURL = directory.appendingPathComponent("public.vsdx")
        if FileManager.default.fileExists(atPath: publicURL.path) { try FileManager.default.removeItem(at: publicURL) }
        try nativeData.write(to: directory.appendingPathComponent("native.vsdx"), options: .atomic)
        try manifestData.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return Capture(directory: directory, suite: suite, test: test, inputKind: inputKind, native: native, savedModel: model)
    }
    private static func boundedData(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let count = attributes[.size] as? NSNumber, count.int64Value > 0, count.int64Value <= Int64(packageLimit) else {
            throw DiagramError.invalid("A membership evidence package exceeds the 16 MiB retention limit.")
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty, data.count <= packageLimit else { throw DiagramError.invalid("Membership evidence grew past its 16 MiB retention limit.") }
        return data
    }
    private static func artifact(_ name: String, _ data: Data) -> Artifact {
        Artifact(path: name, byteCount: data.count, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    private static func encoded(_ manifest: Manifest) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= manifestLimit else { throw DiagramError.invalid("The membership evidence manifest exceeds 64 KiB.") }
        return data
    }
    private static func identity(_ diagram: Diagram) throws -> Identity {
        let page = diagram.page, binding = diagram.visioArchive?.pages.first { $0.pageID == page.id }
        guard page.nodes.count + page.edges.count <= 256 else { throw DiagramError.invalid("Membership evidence identities exceed the 256-object retention limit.") }
        var remainingTextBytes = 32 * 1_024
        func checked(_ publicID: String?, _ detail: ShapeDetails) throws {
            let cells = [detail.sheet["Relationships"], detail.sheet["User.msvStructureType"]].compactMap { $0 }
            for text in [publicID].compactMap({ $0 }) + cells.flatMap({ [$0.value, $0.formula, $0.unit] }) {
                guard text.utf8.count <= remainingTextBytes else { throw DiagramError.invalid("Membership evidence identity strings exceed 32 KiB.") }
                remainingTextBytes -= text.utf8.count
            }
        }
        var objects: [ObjectIdentity] = []
        for node in page.nodes {
            let publicID = binding?.nodeIDs[node.id] ?? node.formatting.sourceShapeID
            try checked(publicID, node.formatting)
            objects.append(ObjectIdentity(kind: "shape", nativeUUID: node.id, publicID: publicID, groupParentUUID: node.parentID,
                sourceUUID: nil, targetUUID: nil, relationships: node.formatting.sheet["Relationships"], structureType: node.formatting.sheet["User.msvStructureType"]))
        }
        for edge in page.edges {
            let publicID = binding?.edgeIDs[edge.id] ?? edge.sourceShapeID
            try checked(publicID, edge.formatting)
            objects.append(ObjectIdentity(kind: "connector", nativeUUID: edge.id, publicID: publicID, groupParentUUID: edge.parentID,
                sourceUUID: edge.source, targetUUID: edge.target, relationships: edge.formatting.sheet["Relationships"], structureType: edge.formatting.sheet["User.msvStructureType"]))
        }
        return Identity(pageUUID: page.id, sourceResourceUUID: diagram.visioArchive?.sourceResourceID,
            sourceLineageUUID: diagram.visioArchive?.sourceLineageID, objects: objects)
    }
}

final class M3MembershipTests: XCTestCase {
    private var files: [URL] = []
    override func tearDown() { files.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
    private func file() -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("M3-membership-\(UUID()).vsdx"); files.append(result); return result
    }
    private func edit(_ source: Diagram, member: String = "11", container: String = "40", included: Bool = true) throws -> Diagram {
        try DiagramMemberships.settingMembership(in: source, pageID: source.page.id, memberID: M3MembershipFixture.id(member, in: source), containerID: M3MembershipFixture.id(container, in: source), included: included)
    }
    private func alteringSource(_ diagram: Diagram, _ body: (XMLElement) throws -> Void) throws -> Diagram {
        var result = diagram, source = try XCTUnwrap(diagram.visioArchive)
        let document = try VisioXML.document(XCTUnwrap(source.parts["visio/pages/page1.xml"]))
        try body(XCTUnwrap(document.rootElement()))
        var parts = source.parts; parts["visio/pages/page1.xml"] = document.xmlData(options: .nodePreserveAll); source.parts = parts; result.visioArchive = source
        return result
    }

    func testIndexKeepsGroupContainerAndListMembershipIndependent() throws {
        let drawing = try M3MembershipFixture.drawing(), member = try M3MembershipFixture.id("11", in: drawing)
        let index = try DiagramMemberships.index(in: drawing, pageID: drawing.page.id)
        XCTAssertTrue(index.issues.isEmpty, index.issues.joined(separator: "; "))
        XCTAssertEqual(drawing.page.nodes.first { $0.id == member }?.parentID, try M3MembershipFixture.id("10", in: drawing))
        XCTAssertEqual(index.outgoing[member]?.filter { $0.kind == .containers }.map(\.target), [try M3MembershipFixture.id("20", in: drawing)])
        XCTAssertEqual(index.outgoing[member]?.filter { $0.kind == .list }.map(\.target), [try M3MembershipFixture.id("30", in: drawing)])
        XCTAssertEqual(index.containers.map(\.publicID), [20, 40])
        XCTAssertEqual(index.entries[try M3MembershipFixture.id("30", in: drawing)]?.role, .list)
    }

    func testOneReciprocalEdgeMatchesIndependentExpectedXMLAndRetainsOtherPublicParts() throws {
        let before = try M3MembershipFixture.drawing(), after = try edit(before)
        let prepared = try M3MembershipFixture.stripped(VisioPreservation.prepared(after).parts)
        let expected = try Data(contentsOf: M3MembershipFixture.resource("expected-add40-page", ext: "xml"))
        XCTAssertEqual(try M3MembershipFixture.signature(XCTUnwrap(prepared["visio/pages/page1.xml"])), try M3MembershipFixture.signature(expected))
        let original = try M3MembershipFixture.stripped(M3MembershipFixture.parts())
        XCTAssertEqual(Set(prepared.keys), Set(original.keys))
        for (name, data) in original where name != "visio/pages/page1.xml" {
            if name.hasSuffix(".xml") || name.hasSuffix(".rels") { XCTAssertEqual(try M3MembershipFixture.signature(XCTUnwrap(prepared[name])), try M3MembershipFixture.signature(data), name) }
            else { XCTAssertEqual(prepared[name], data, name) }
        }
        let member = try M3MembershipFixture.id("11", in: before)
        XCTAssertEqual(after.page.nodes.first { $0.id == member }?.parentID, before.page.nodes.first { $0.id == member }?.parentID)
    }

    func testRemoveChangesOnlyContainerClausesAndRetainsUnitsListOrderAndOpaqueSource() throws {
        let before = try M3MembershipFixture.drawing(), after = try edit(before, container: "20", included: false)
        let oldNode = try XCTUnwrap(before.page.nodes.first { $0.formatting.sourceShapeID == "11" })
        let newNode = try XCTUnwrap(after.page.nodes.first { $0.id == oldNode.id })
        XCTAssertEqual(newNode.parentID, oldNode.parentID); XCTAssertEqual(newNode.rect, oldNode.rect)
        XCTAssertEqual(newNode.formatting.sheet["Comment"], oldNode.formatting.sheet["Comment"])
        XCTAssertEqual(newNode.formatting.sheet["Relationships"]?.unit, "BOOL")
        XCTAssertEqual(newNode.formatting.sheet["Relationships"]?.formula, "SUM( DEPENDSON(5,Sheet.30!SheetRef()),DEPENDSON(7))")
        XCTAssertEqual(after.page.nodes.first { $0.formatting.sourceShapeID == "30" }, before.page.nodes.first { $0.formatting.sourceShapeID == "30" })
        let parts = try VisioPreservation.prepared(after).parts
        XCTAssertEqual(parts["custom/opaque.bin"], before.visioArchive?.parts["custom/opaque.bin"])
        XCTAssertTrue(String(decoding: try XCTUnwrap(parts["visio/pages/page1.xml"]), as: UTF8.self).contains("ext:Payload"))
    }

    func testActualPublicSaveStripPrivateReopenPreservesIndependentMembership() throws {
        let edited = try edit(M3MembershipFixture.drawing()), url = file()
        try VisioFormat.write(edited, to: url)
        let capture = try M3MembershipEvidence.begin(suite: "M3MembershipTests", test: #function, inputKind: "independently authored public membership fixture", nativeURL: url, diagram: edited)
        let stripped = try M3MembershipFixture.stripped(VisioPackage.read(url)); try VisioPackage.write(stripped, to: url)
        XCTAssertFalse(try VisioPackage.read(url).keys.contains { $0.hasPrefix("macvisio/") })
        let reopened = try VisioFormat.read(from: url).diagram, member = try M3MembershipFixture.id("11", in: reopened)
        let index = try DiagramMemberships.index(in: reopened, pageID: reopened.page.id)
        XCTAssertTrue(index.contains(member: member, container: try M3MembershipFixture.id("40", in: reopened)))
        XCTAssertTrue(index.contains(member: member, container: try M3MembershipFixture.id("20", in: reopened)))
        XCTAssertEqual(index.outgoing[member]?.filter { $0.kind == .list }.map(\.target), [try M3MembershipFixture.id("30", in: reopened)])
        XCTAssertEqual(reopened.page.nodes.first { $0.id == member }?.parentID, try M3MembershipFixture.id("10", in: reopened))
        try capture?.finish(publicURL: url, reopened: reopened)
    }

    func testConnectorMembershipRetainsPrimaryPublicIdentityAndOrdinaryFormulaOnReopen() throws {
        let source = try M3MembershipFixture.drawing(), edited = try edit(source, member: "50")
        let edge = try XCTUnwrap(edited.page.edges.first)
        XCTAssertEqual(edge.sourceShapeID, "50"); XCTAssertEqual(edge.formatting.sourceShapeID, "50")
        XCTAssertEqual(edge.formatting.sheet["User.Weight"], source.page.edges[0].formatting.sheet["User.Weight"])
        let url = file(); try VisioFormat.write(edited, to: url)
        let capture = try M3MembershipEvidence.begin(suite: "M3MembershipTests", test: #function, inputKind: "independently authored public connector membership fixture", nativeURL: url, diagram: edited)
        let parts = try M3MembershipFixture.stripped(VisioPackage.read(url)); try VisioPackage.write(parts, to: url)
        let reopened = try VisioFormat.read(from: url).diagram
        let index = try DiagramMemberships.index(in: reopened, pageID: reopened.page.id)
        XCTAssertTrue(index.contains(member: try M3MembershipFixture.id("50", in: reopened), container: try M3MembershipFixture.id("40", in: reopened)))
        XCTAssertEqual(reopened.page.edges.first?.formatting.sheet["User.Weight"]?.formula, "7")
        try capture?.finish(publicURL: url, reopened: reopened)
    }

    func testNativeCodableRoundTripNeedsNoNewMembershipGraphOrMigration() throws {
        let edited = try edit(M3MembershipFixture.drawing())
        let decoded = try JSONDecoder().decode(Diagram.self, from: JSONEncoder().encode(edited))
        XCTAssertEqual(decoded, edited)
        let index = try DiagramMemberships.index(in: decoded, pageID: decoded.page.id)
        XCTAssertTrue(index.contains(member: try M3MembershipFixture.id("11", in: decoded), container: try M3MembershipFixture.id("40", in: decoded)))
    }

    func testGroupingUngroupingAndMemberMotionRetainPublicRelationshipClauses() throws {
        let original = try M3MembershipFixture.drawing(), member = try M3MembershipFixture.id("11", in: original), sibling = try M3MembershipFixture.id("12", in: original)
        let retained = original.page.nodes.first { $0.id == member }?.formatting.sheet["Relationships"]
        var page = original.page
        let group = try DiagramOperations.group([member, sibling], in: &page, binding: original.visioArchive?.pages.first)
        XCTAssertEqual(page.nodes.first { $0.id == member }?.formatting.sheet["Relationships"], retained)
        let ids = DiagramOperations.ungroup([group], in: &page)
        XCTAssertEqual(ids, [member, sibling]); XCTAssertEqual(page.nodes.first { $0.id == member }?.formatting.sheet["Relationships"], retained)
        let offset = try XCTUnwrap(page.nodes.firstIndex { $0.id == member })
        XCTAssertNil(NativeEditProtection.blockReason(for: "X", node: page.nodes[offset], in: page))
        page.nodes[offset].x += 12
        XCTAssertEqual(page.nodes[offset].formatting.sheet["Relationships"], retained)
        try DiagramMemberships.validateRemoval([try M3MembershipFixture.id("10", in: original)], in: original, pageID: original.page.id)
    }

    func testContainerTransformAndReferencedIdentityRemovalRefuseAtomically() throws {
        let drawing = try M3MembershipFixture.drawing(), before = drawing
        let container = try XCTUnwrap(drawing.page.nodes.first { $0.formatting.sourceShapeID == "20" })
        for key in ["X", "Y", "Width", "Height", "Rotation"] { XCTAssertNotNil(NativeEditProtection.blockReason(for: key, node: container, in: drawing.page)) }
        XCTAssertThrowsError(try DiagramMemberships.validateRemoval([container.id], in: drawing, pageID: drawing.page.id))
        XCTAssertThrowsError(try DiagramMemberships.validateRemoval([try M3MembershipFixture.id("11", in: drawing)], in: drawing, pageID: drawing.page.id))
        XCTAssertEqual(drawing, before)
    }

    func testClosedCopyPasteRemapsContainerListAndConnectorReferencesWithoutRenumberingDestination() throws {
        let source = try M3MembershipFixture.drawing(), all = Set(source.page.nodes.map(\.id) + source.page.edges.map(\.id))
        try DiagramMemberships.validateCopy(all, in: source, pageID: source.page.id)
        let fragment = DiagramOperations.fragment(Set(source.page.nodes.map(\.id)), edges: Set(source.page.edges.map(\.id)), from: source.page, binding: source.visioArchive?.pages.first)
        var page = source.page; let oldNodeCount = page.nodes.count
        _ = try DiagramOperations.insert(fragment, into: &page)
        XCTAssertEqual(Array(page.nodes.prefix(oldNodeCount)), source.page.nodes)
        let copies = Array(page.nodes.dropFirst(oldNodeCount))
        let map = Dictionary(uniqueKeysWithValues: zip(source.page.nodes, copies).map { ($0.0.formatting.sourceShapeID!, $0.1.formatting.sourceShapeID!) })
        let member = try XCTUnwrap(copies.first { $0.formatting.sourceShapeID == map["11"] })
        let formula = try DiagramMemberships.parse(member.formatting.sheet["Relationships"])
        XCTAssertEqual(formula.targets(.containers), [try XCTUnwrap(map["20"].flatMap(UInt32.init))])
        XCTAssertEqual(formula.targets(.list), [try XCTUnwrap(map["30"].flatMap(UInt32.init))])
        XCTAssertEqual(member.parentID, copies.first { $0.formatting.sourceShapeID == map["10"] }?.id)
        let edge = try XCTUnwrap(page.edges.last)
        XCTAssertNotEqual(edge.sourceShapeID, "50"); XCTAssertEqual(edge.sourceShapeID, edge.formatting.sourceShapeID)
        XCTAssertEqual(edge.formatting.sheet["User.Weight"]?.formula, "7")
    }

    func testPartialAndUnknownClipboardClosuresRefuseBeforeDestinationMutation() throws {
        let source = try M3MembershipFixture.drawing(), member = try M3MembershipFixture.id("11", in: source)
        XCTAssertThrowsError(try DiagramMemberships.validateCopy([member], in: source, pageID: source.page.id))
        let fragment = DiagramOperations.fragment([member], from: source.page)
        var destination = source.page; let before = destination
        XCTAssertThrowsError(try DiagramOperations.insert(fragment, into: &destination)); XCTAssertEqual(destination, before)
        var unknown = fragment; unknown.nodes[0].formatting.sheet["Relationships"]?.formula = "VendorMembership(42)"
        XCTAssertThrowsError(try DiagramOperations.insert(unknown, into: &destination)); XCTAssertEqual(destination, before)
    }

    func testInheritedForeignNamespaceAndOpaqueCellOwnersRemainUnchangedAndReadOnly() throws {
        let source = try M3MembershipFixture.drawing()
        for change in 0..<3 {
            let drawing = try alteringSource(source) { root in
                let shape = try XCTUnwrap(root.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "11" })
                let cell = try XCTUnwrap(shape.elementsLocal("Cell").first { $0.attr("N") == "Relationships" })
                switch change {
                case 0: shape.setAttr("Master", "7"); cell.detach()
                case 1: cell.name = "ext:Cell"; cell.uri = "urn:unknown:owner"
                default: cell.setAttr("VendorRelationshipPolicy", "unknown")
                }
            }
            XCTAssertThrowsError(try edit(drawing)); XCTAssertEqual(drawing.page, source.page)
            XCTAssertEqual(try VisioPreservation.prepared(drawing).parts["visio/pages/page1.xml"], drawing.visioArchive?.parts["visio/pages/page1.xml"])
        }
    }

    func testUnknownAmbiguousAndDynamicRelationshipsRefuseWithoutReplacingRawSource() throws {
        let source = try M3MembershipFixture.drawing()
        for formula in ["SUM(DEPENDSON(12,Sheet.20!SheetRef()))", "SUM(DEPENDSON(4,OtherName!SheetRef()))", "SUM(DEPENDSON(4,Sheet.20!SheetRef()),DEPENDSON(4))", "SUM(DEPENDSON(4,Sheet.999!SheetRef()))", "VendorLookup(20)", "SUM(DEPENDSON(5,Sheet.20!SheetRef(),Sheet.30!SheetRef()))"] {
            var drawing = source
            let offset = try XCTUnwrap(drawing.page.nodes.firstIndex { $0.formatting.sourceShapeID == "11" })
            drawing.page.nodes[offset].formatting.sheet["Relationships"]?.formula = formula
            let before = drawing
            XCTAssertThrowsError(try edit(drawing)); XCTAssertEqual(drawing, before)
        }
        XCTAssertThrowsError(try DiagramMemberships.parse(ShapeSheetCell(value: "0", formula: String(repeating: "X", count: 16_385))))
    }

    func testKnownStructuralMetadataAvoidsNumericFallbackButUnknownMetadataDoesNot() throws {
        let drawing = try M3MembershipFixture.drawing()
        let sources = CalculationDependencyIndex.sources(page: drawing.page, binding: drawing.visioArchive?.pages.first)
        XCTAssertFalse(sources.flatMap(\.formulas).contains { $0.hasPrefix("Relationships\u{0}") })
        XCTAssertFalse(CalculationDependencyIndex(sources: sources, pageHasFormulas: false).requiresFullPage)
        var unknown = drawing.page
        unknown.nodes[0].formatting.sheet["Relationships"] = ShapeSheetCell(value: "0", formula: "VendorLookup(20)")
        let retained = CalculationDependencyIndex.sources(page: unknown, binding: drawing.visioArchive?.pages.first)
        XCTAssertTrue(CalculationDependencyIndex(sources: retained, pageHasFormulas: false).requiresFullPage)
    }

    func testMixedExplicitAndImplicitIDsFreezeExistingIncomingFormulaAddressThroughPublicReopen() throws {
        let source = M3MembershipFixture.mixedNative(), member = source.page.nodes[1].id, container = source.page.nodes[0].id
        let edited = try DiagramMemberships.settingMembership(in: source, pageID: source.page.id, memberID: member, containerID: container, included: true)
        XCTAssertEqual(edited.page.nodes[1].formatting.sourceShapeID, "2")
        XCTAssertEqual(edited.page.nodes[2].formatting.sheet["User.Incoming"]?.formula, "Sheet.2!Width")
        XCTAssertEqual(edited.page.edges[0].sourceShapeID, "50")
        XCTAssertEqual(edited.page.edges[0].formatting.sheet["User.Incoming"]?.formula, "Sheet.2!Width")
        let url = file(); try VisioFormat.write(edited, to: url)
        let capture = try M3MembershipEvidence.begin(suite: "M3MembershipTests", test: #function, inputKind: "native mixed explicit and implicit public identity page", nativeURL: url, diagram: edited)
        let publicParts = try M3MembershipFixture.stripped(VisioPackage.read(url)); try VisioPackage.write(publicParts, to: url)
        let reopened = try VisioFormat.read(from: url).diagram
        let index = try DiagramMemberships.index(in: reopened, pageID: reopened.page.id)
        XCTAssertTrue(index.contains(member: try M3MembershipFixture.id("2", in: reopened), container: try M3MembershipFixture.id("10", in: reopened)))
        let reader = try XCTUnwrap(reopened.page.nodes.first { $0.formatting.sourceShapeID == "30" })
        XCTAssertEqual(reader.formatting.sheet["User.Incoming"]?.formula, "Sheet.2!Width")
        XCTAssertEqual(try ShapeSheetContext(page: reopened.page).number(reader.id, "User.Incoming"), reopened.page.nodes.first { $0.formatting.sourceShapeID == "2" }!.width / 72, accuracy: 1e-8)
        try capture?.finish(publicURL: url, reopened: reopened)
    }

    func testImplicitCollisionWithPrimaryConnectorIDOrConflictingDetailIDRefuses() throws {
        var source = M3MembershipFixture.mixedNative(); source.page.edges[0].sourceShapeID = "2"
        let before = source
        XCTAssertThrowsError(try DiagramMemberships.settingMembership(in: source, pageID: source.page.id, memberID: source.page.nodes[1].id, containerID: source.page.nodes[0].id, included: true))
        XCTAssertEqual(source, before)
        source = M3MembershipFixture.mixedNative(); source.page.edges[0].formatting.sourceShapeID = "999"
        XCTAssertThrowsError(try DiagramMemberships.index(in: source, pageID: source.page.id))
        source = try M3MembershipFixture.drawing(); source.page.edges[0].sourceShapeID = "999"
        XCTAssertThrowsError(try DiagramMemberships.index(in: source, pageID: source.page.id))
    }

    func testLeadingZeroSourceAndRawTombstoneReservationsAreNotReallocated() throws {
        var source = try M3MembershipFixture.drawing()
        source = try alteringSource(source) { root in
            let shapes = try XCTUnwrap(root.firstLocal("Shapes"))
            let container = try XCTUnwrap(shapes.allShapes.first { $0.attr("ID") == "40" }); container.setAttr("ID", "040")
            shapes.addChild(try VisioXML.element("<Shape xmlns=\"\(DiagramMemberships.namespace)\" ID=\"002\" Type=\"Shape\" Del=\"1\"/>"))
        }
        let offset = try XCTUnwrap(source.page.nodes.firstIndex { $0.formatting.sourceShapeID == "40" })
        let id = source.page.nodes[offset].id; source.page.nodes[offset].formatting.sourceShapeID = "040"
        if let archiveIndex = source.visioArchive?.pages.firstIndex(where: { $0.pageID == source.page.id }) { source.visioArchive?.pages[archiveIndex].nodeIDs[id] = "040" }
        let edited = try edit(source)
        let publicPage = try VisioXML.document(XCTUnwrap(VisioPreservation.prepared(edited).parts["visio/pages/page1.xml"]))
        XCTAssertNotNil(publicPage.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "040" })
        var collision = source; collision.page.nodes.insert(DiagramNode(text: "Implicit two"), at: 1)
        XCTAssertThrowsError(try edit(collision))
    }

    func testProtectedUnresolvedAndAutomaticResizePoliciesRefuseTheWholeEdge() throws {
        let source = try M3MembershipFixture.drawing()
        for key in ["LockFormat", "User.msvSDContainerLocked", "User.msvSDContainerResize", "User.msvSDUnknownPolicy"] {
            var drawing = source
            let offset = try XCTUnwrap(drawing.page.nodes.firstIndex { $0.formatting.sourceShapeID == "40" })
            drawing.page.nodes[offset].formatting.sheet[key] = ShapeSheetCell(value: "1")
            let before = drawing; XCTAssertThrowsError(try edit(drawing)); XCTAssertEqual(drawing, before)
        }
        var unresolved = source
        let offset = try XCTUnwrap(unresolved.page.nodes.firstIndex { $0.formatting.sourceShapeID == "40" })
        unresolved.page.nodes[offset].formatting.sheet["User.msvSDContainerLocked"] = ShapeSheetCell(value: "0", formula: "VendorPolicy()")
        XCTAssertThrowsError(try edit(unresolved))
    }

    func testLastMemberDetachAuthorsZeroRatherThanAnEmptyClauseAndReopensPublicly() throws {
        let source = try M3MembershipFixture.drawing(), added = try edit(source, member: "50")
        let removed = try edit(added, member: "50", included: false)
        let prepared = try VisioPreservation.prepared(removed).parts
        let xml = try VisioXML.document(XCTUnwrap(prepared["visio/pages/page1.xml"]))
        for publicID in ["40", "50"] {
            let shape = try XCTUnwrap(xml.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == publicID })
            let cell = try XCTUnwrap(shape.elementsLocal("Cell").first { $0.attr("N") == "Relationships" })
            XCTAssertEqual(cell.attr("F"), "0"); XCTAssertEqual(cell.attr("V"), "0"); XCTAssertEqual(cell.attr("U"), "BOOL")
        }
        let url = file(); try VisioFormat.write(removed, to: url)
        let capture = try M3MembershipEvidence.begin(suite: "M3MembershipTests", test: #function, inputKind: "independently authored public last-member-detach fixture", nativeURL: url, diagram: removed)
        try VisioPackage.write(M3MembershipFixture.stripped(VisioPackage.read(url)), to: url)
        let reopened = try VisioFormat.read(from: url).diagram
        let index = try DiagramMemberships.index(in: reopened, pageID: reopened.page.id)
        XCTAssertFalse(index.contains(member: try M3MembershipFixture.id("50", in: reopened), container: try M3MembershipFixture.id("40", in: reopened)))
        XCTAssertEqual(reopened.page.edges.first?.formatting.sheet["Relationships"]?.formula, "0")
        try capture?.finish(publicURL: url, reopened: reopened)
    }

    func testDeletedStructuralRowsSectionsShapesAndUnknownOwnerAttributesCannotProvePolicy() throws {
        let source = try M3MembershipFixture.drawing()
        for variant in 0..<7 {
            let changed = try alteringSource(source) { root in
                let shapes = try XCTUnwrap(root.firstLocal("Shapes"))
                let shape = try XCTUnwrap(shapes.allShapes.first { $0.attr("ID") == "40" })
                let section = try XCTUnwrap(shape.elementsLocal("Section").first { $0.attr("N") == "User" })
                let role = try XCTUnwrap(section.elementsLocal("Row").first { $0.attr("N") == "msvStructureType" })
                switch variant {
                case 0: section.setAttr("Del", "1")
                case 1: role.setAttr("Del", "1")
                case 2: shape.setAttr("Del", "1")
                case 3: try XCTUnwrap(shapes.allShapes.first { $0.attr("ID") == "10" }).setAttr("Del", "1")
                case 4: section.setAttr("VendorOwnership", "unknown")
                case 5: role.setAttr("VendorOwnership", "unknown")
                default: role.name = "ext:Row"; role.uri = "urn:unknown:owner"
                }
            }
            let before = changed
            XCTAssertThrowsError(try edit(changed), "variant \(variant)"); XCTAssertEqual(changed, before)
            XCTAssertEqual(try VisioPreservation.prepared(changed).parts["visio/pages/page1.xml"], changed.visioArchive?.parts["visio/pages/page1.xml"])
        }
        let vendor = try alteringSource(source) { root in
            try XCTUnwrap(root.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "40" }).setAttr("VendorCaption", "unrelated")
        }
        let edited = try edit(vendor)
        let xml = try VisioXML.document(XCTUnwrap(VisioPreservation.prepared(edited).parts["visio/pages/page1.xml"]))
        XCTAssertEqual(xml.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "40" }?.attr("VendorCaption"), "unrelated")
    }

    func testMasterInstanceWithPartialLocalOverridesRefusesUnprovenInheritedPolicyClosure() throws {
        let ns = DiagramMemberships.namespace, rel = "http://schemas.openxmlformats.org/package/2006/relationships"
        let vr = "http://schemas.microsoft.com/visio/2010/relationships/"
        var parts = try M3MembershipFixture.parts()
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "40" }).setAttr("Master", "7")
        parts["visio/pages/page1.xml"] = page.xmlData(options: .nodePreserveAll)
        let docRels = try VisioXML.document(XCTUnwrap(parts["visio/_rels/document.xml.rels"]))
        docRels.rootElement()?.addChild(try VisioXML.element("<Relationship xmlns=\"\(rel)\" Id=\"rId2\" Type=\"\(vr)masters\" Target=\"masters/masters.xml\"/>"))
        parts["visio/_rels/document.xml.rels"] = docRels.xmlData(options: .nodePreserveAll)
        parts["visio/masters/masters.xml"] = Data("<Masters xmlns=\"\(ns)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><Master ID=\"7\" NameU=\"InheritedContainer\"><Rel r:id=\"rId1\"/></Master></Masters>".utf8)
        parts["visio/masters/_rels/masters.xml.rels"] = Data("<Relationships xmlns=\"\(rel)\"><Relationship Id=\"rId1\" Type=\"\(vr)master\" Target=\"master7.xml\"/></Relationships>".utf8)
        parts["visio/masters/master7.xml"] = Data("<MasterContents xmlns=\"\(ns)\"><Shapes><Shape ID=\"1\" Type=\"Shape\"><Section N=\"User\"><Row N=\"msvSDVendorInheritedPolicy\"><Cell N=\"Value\" V=\"1\"/></Row></Section></Shape></Shapes></MasterContents>".utf8)
        let types = try VisioXML.document(XCTUnwrap(parts["[Content_Types].xml"]))
        for (part, contentType) in [("masters.xml", "masters"), ("master7.xml", "master")] {
            types.rootElement()?.addChild(try VisioXML.element("<Override xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\" PartName=\"/visio/masters/\(part)\" ContentType=\"application/vnd.ms-visio.\(contentType)+xml\"/>"))
        }
        parts["[Content_Types].xml"] = types.xmlData(options: .nodePreserveAll)
        var drawing = try VisioFormat.readPublic(parts: parts, title: "Partial local policy").diagram
        let offset = try XCTUnwrap(drawing.page.nodes.firstIndex { $0.formatting.sourceShapeID == "40" })
        // An older native cache can have only the explicit local overrides.
        drawing.page.nodes[offset].formatting.sheet["User.msvSDVendorInheritedPolicy"] = nil
        let before = drawing
        XCTAssertEqual(drawing.page.nodes[offset].formatting.sheet["User.msvStructureType"]?.value, "Container")
        XCTAssertThrowsError(try edit(drawing)) { XCTAssertTrue($0.localizedDescription.contains("Inherited")) }
        XCTAssertEqual(drawing, before)
    }

    func testManagedRelationshipsCannotBeAuthoredOrClearedThroughGenericCellAPIs() throws {
        var node = DiagramNode(text: "Generic editor"), original = DiagramNode()
        node.formatting.sheet["Relationships"] = ShapeSheetCell(value: "0", formula: "0"); original = node
        for formula in ["", "0", "SUM(DEPENDSON(4,Sheet.10!SheetRef()))"] {
            XCTAssertThrowsError(try SheetCellEditing.set("Relationships", value: "0", formula: formula, unit: "BOOL", on: &node)) {
                XCTAssertTrue($0.localizedDescription.contains("managed by Memberships"))
            }
            XCTAssertEqual(node, original)
        }
        let source = try M3MembershipFixture.drawing()
        for value in [nil, ShapeSheetCell(value: "0", formula: "0")] as [ShapeSheetCell?] {
            XCTAssertThrowsError(try DefinitionEditing.settingCell(in: source, sheetID: UUID(), address: DefinitionCellAddress(cell: "Relationships"), value: value)) {
                XCTAssertTrue($0.localizedDescription.contains("managed by Memberships"))
            }
        }
        XCTAssertNil(DiagramMemberships.managedCellReason("User.Relationships"))
    }

    func testWarmMetadataFreeGuardUsesCachedEmptyOwnersWithoutNodeMapsOrScanning() throws {
        var before = Diagram(); before.page.nodes = (0..<1_000).map { DiagramNode(text: "Plain \($0)") }
        let oldSession = CalculationSession(); _ = oldSession.index(for: before.page, binding: nil)
        var next = before; next.page.nodes[500].text = "Warm text edit"
        let changes = DocumentChangeSet.between(before, next)
        XCTAssertFalse(DiagramMemberships.needsTransformGuard(from: before, proposed: next, changes: changes, session: oldSession))
        let newSession = oldSession.fork(); _ = newSession.index(for: next.page, binding: nil, changes: changes.pages[next.page.id], trustChanges: true)
        let work = try DiagramMemberships.validateTransforms(from: before, to: next, beforeSession: oldSession, afterSession: newSession)
        XCTAssertEqual(work.cachedPages, 1); XCTAssertEqual(work.candidateNodes, 0); XCTAssertEqual(work.fallbackNodes, 0); XCTAssertEqual(work.lookupMapsBuilt, 0)
        next.page.nodes[400].formatting.sheet["User.msvStructureType"] = ShapeSheetCell(value: "Container", formula: "VendorRole()", unit: "STR")
        XCTAssertTrue(DiagramMemberships.needsTransformGuard(from: before, proposed: next, changes: DocumentChangeSet.between(before, next), session: oldSession))
    }

    func testOldAndNewResolvedStructuralPoliciesGuardGeometryWithCachedCandidateIndices() throws {
        let source = M3MembershipFixture.mixedNative()
        let before = try DiagramMemberships.settingMembership(in: source, pageID: source.page.id, memberID: source.page.nodes[1].id, containerID: source.page.nodes[0].id, included: true)
        let oldSession = CalculationSession(); _ = oldSession.index(for: before.page, binding: nil)
        var unrelated = before; unrelated.page.nodes[2].text = "Warm non-owner edit"
        let newSession = oldSession.fork(); _ = newSession.index(for: unrelated.page, binding: nil, changes: DocumentChangeSet.between(before, unrelated).pages[before.page.id], trustChanges: true)
        let work = try DiagramMemberships.validateTransforms(from: before, to: unrelated, beforeSession: oldSession, afterSession: newSession)
        XCTAssertEqual(work.candidateNodes, 1); XCTAssertEqual(work.fallbackNodes, 0); XCTAssertEqual(work.lookupMapsBuilt, 0)
        var cleared = before; cleared.page.nodes[0].formatting.sheet["User.msvStructureType"] = nil; cleared.page.nodes[0].x += 10
        XCTAssertThrowsError(try DiagramMemberships.validateTransforms(from: before, to: cleared))
        var plain = Diagram(); plain.page.nodes = [DiagramNode(text: "Old ordinary owner")]
        var introduced = plain; introduced.page.nodes[0].x += 10
        introduced.page.nodes[0].formatting.sheet["User.msvStructureType"] = ShapeSheetCell(value: "Container", formula: "\"Container\"", unit: "STR")
        introduced.page.nodes[0].formatting.sheet["Relationships"] = ShapeSheetCell(value: "0", formula: "0")
        introduced.page.nodes[0].formatting.sheet["User.msvSDContainerResize"] = ShapeSheetCell(value: "1")
        XCTAssertThrowsError(try DiagramMemberships.validateTransforms(from: plain, to: introduced))
        introduced.page.nodes[0].formatting.sheet["User.msvStructureType"]?.formula = "VendorRole()"
        XCTAssertThrowsError(try DiagramMemberships.validateTransforms(from: plain, to: introduced))
    }

    func testUnknownOrIncompatibleStructuralUnitsRefuseRatherThanProveLocalPolicy() throws {
        let source = M3MembershipFixture.mixedNative()
        for (key, unit) in [("User.msvStructureType", "BOOL"), ("User.msvSDContainerResize", "IN"), ("User.msvSDContainerLocked", "VendorUnit"), ("User.msvSDContainerRequiredCategories", "BOOL"), ("Relationships", "STR")] {
            var changed = source
            if changed.page.nodes[0].formatting.sheet[key] == nil { changed.page.nodes[0].formatting.sheet[key] = ShapeSheetCell(value: key.hasSuffix("Categories") ? "Task" : "0") }
            changed.page.nodes[0].formatting.sheet[key]?.unit = unit
            XCTAssertThrowsError(try DiagramMemberships.settingMembership(in: changed, pageID: changed.page.id, memberID: changed.page.nodes[1].id, containerID: changed.page.nodes[0].id, included: true), key)
        }
        var category = source; category.page.nodes[1].formatting.sheet["User.msvShapeCategories"] = ShapeSheetCell(value: "Task", unit: "IN")
        XCTAssertThrowsError(try DiagramMemberships.settingMembership(in: category, pageID: category.page.id, memberID: category.page.nodes[1].id, containerID: category.page.nodes[0].id, included: true))
    }

    func testMixedListContainerContainmentCycleIsRefused() throws {
        var source = M3MembershipFixture.mixedNative()
        var list = DiagramNode(text: "Existing list"); list.formatting.sourceShapeID = "60"
        list.formatting.sheet["User.msvStructureType"] = ShapeSheetCell(value: "List", formula: "\"List\"", unit: "STR")
        list.formatting.sheet["Relationships"] = ShapeSheetCell(value: "0", formula: "SUM(DEPENDSON(2,Sheet.10!SheetRef()))", unit: "BOOL")
        source.page.nodes[0].formatting.sheet["Relationships"] = ShapeSheetCell(value: "0", formula: "SUM(DEPENDSON(5,Sheet.60!SheetRef()))", unit: "BOOL")
        source.page.nodes.append(list)
        let before = source
        XCTAssertThrowsError(try DiagramMemberships.settingMembership(in: source, pageID: source.page.id, memberID: list.id, containerID: source.page.nodes[0].id, included: true)) {
            XCTAssertTrue($0.localizedDescription.contains("cycle"))
        }
        XCTAssertEqual(source, before)
    }

    func testRetainedOwnerCandidatesUnionGeometryAndFieldIndexGenerations() throws {
        var plain = Diagram(); plain.page.nodes = [DiagramNode(text: "Old plain source")]
        let session = CalculationSession(); _ = session.index(for: plain.page, binding: nil, fieldIdentifiers: false)
        XCTAssertEqual(session.retainedStructuralNodeIDs(pageID: plain.page.id), [])
        var structural = plain
        structural.page.nodes[0].formatting.sheet["User.msvStructureType"] = ShapeSheetCell(value: "Container", unit: "STR")
        _ = session.index(for: structural.page, binding: nil, fieldIdentifiers: true)
        XCTAssertEqual(session.retainedStructuralNodeIDs(pageID: plain.page.id), [plain.page.nodes[0].id])
        XCTAssertTrue(session.retainedDependency(pageID: plain.page.id, fieldIdentifiers: false)?.structuralNodeIDs.isEmpty == true)
        XCTAssertFalse(session.retainedDependency(pageID: plain.page.id, fieldIdentifiers: true)?.structuralNodeIDs.isEmpty ?? true)
        structural.page.nodes[0].x += 20
        XCTAssertTrue(DiagramMemberships.needsTransformGuard(from: plain, proposed: structural, changes: DocumentChangeSet.between(plain, structural), session: session))
        XCTAssertThrowsError(try DiagramMemberships.validateTransforms(from: plain, to: structural, beforeSession: session, afterSession: session))
    }

    func testRetainedSourceOwnersWithoutRelationshipsRefuseAffectedCopyAndRemoval() throws {
        for variant in M3MembershipFixture.RetainedOwnerCase.allCases {
            let drawing = try M3MembershipFixture.retainedOwnerWithoutRelationships(variant)
            let affected = try M3MembershipFixture.id("12", in: drawing)
            let index = try DiagramMemberships.index(in: drawing, pageID: drawing.page.id)
            let entry = try XCTUnwrap(index.entries[affected])
            XCTAssertTrue(index.issues.isEmpty, "\(variant): \(index.issues)")
            XCTAssertNil(entry.cell, "\(variant)")
            XCTAssertNotNil(entry.sourceRefusal, "\(variant)")
            XCTAssertTrue(entry.unprovenRetainedOwnership, "\(variant)")
            let before = drawing
            XCTAssertThrowsError(try DiagramMemberships.validateCopy([affected], in: drawing, pageID: drawing.page.id)) {
                XCTAssertTrue($0.localizedDescription.contains("Retained source ownership"), "\(variant): \($0)")
            }
            XCTAssertThrowsError(try DiagramMemberships.validateRemoval([affected], in: drawing, pageID: drawing.page.id)) {
                XCTAssertTrue($0.localizedDescription.contains("Retained source ownership"), "\(variant): \($0)")
            }
            XCTAssertEqual(drawing, before)
        }
    }

    func testNewUnboundOrdinaryNativeObjectsStayUsableBesideUnprovenRetainedOwners() throws {
        var drawing = try M3MembershipFixture.retainedOwnerWithoutRelationships(.master)
        var group = DiagramNode(text: "New ordinary native group"); group.formatting.isGroup = true
        var child = DiagramNode(text: "New ordinary native child"); child.parentID = group.id
        var edge = DiagramEdge(source: child.id, target: UUID()); edge.sourceShapeID = "104"
        edge.parentID = group.id; edge.sourcePosition = DiagramPoint(x: 10, y: 10); edge.targetPosition = DiagramPoint(x: 70, y: 10)
        drawing.page.nodes += [group, child]; drawing.page.edges.append(edge)
        let ids: Set<UUID> = [group.id, child.id, edge.id]
        let index = try DiagramMemberships.index(in: drawing, pageID: drawing.page.id)
        XCTAssertTrue(index.issues.isEmpty)
        XCTAssertTrue(index.entries[try M3MembershipFixture.id("12", in: drawing)]?.unprovenRetainedOwnership == true)
        for id in ids {
            let entry = try XCTUnwrap(index.entries[id])
            XCTAssertNil(entry.cell); XCTAssertNotNil(entry.sourceRefusal)
            XCTAssertFalse(entry.unprovenRetainedOwnership)
        }
        XCTAssertNoThrow(try DiagramMemberships.validateCopy(ids, in: drawing, pageID: drawing.page.id))
        XCTAssertNoThrow(try DiagramMemberships.validateRemoval(ids, in: drawing, pageID: drawing.page.id))
    }

    func testNewUnboundChildCannotHideAnUnprovenRetainedAncestor() throws {
        var drawing = try M3MembershipFixture.retainedOwnerWithoutRelationships(.ancestorMaster)
        var child = DiagramNode(text: "Unsaved child of retained master group")
        child.parentID = try M3MembershipFixture.id("10", in: drawing); drawing.page.nodes.append(child)
        let index = try DiagramMemberships.index(in: drawing, pageID: drawing.page.id)
        let entry = try XCTUnwrap(index.entries[child.id])
        XCTAssertTrue(index.issues.isEmpty); XCTAssertNil(entry.cell)
        XCTAssertTrue(entry.unprovenRetainedOwnership)
        XCTAssertThrowsError(try DiagramMemberships.validateCopy([child.id], in: drawing, pageID: drawing.page.id))
        XCTAssertThrowsError(try DiagramMemberships.validateRemoval([child.id], in: drawing, pageID: drawing.page.id))
    }

    func testCancelledMembershipPreparationNeverMutatesInput() throws {
        let source = try M3MembershipFixture.drawing(), cancellation = LifecycleJobCancellation(); let before = source; cancellation.cancel()
        XCTAssertThrowsError(try DiagramMemberships.settingMembership(in: source, pageID: source.page.id, memberID: M3MembershipFixture.id("11", in: source), containerID: M3MembershipFixture.id("40", in: source), included: true, cancellation: cancellation)) { error in
            XCTAssertEqual(error as? LifecycleJobError, .cancelled)
        }
        XCTAssertEqual(source, before)
    }
}
