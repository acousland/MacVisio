import XCTest
@testable import MacVisio

final class MetadataEncodingTests: XCTestCase {
    func testSmallMetadataEncodingRemainsByteStableAndDoesNotRegisterSegmentType() throws {
        var diagram = Diagram()
        diagram.pages[0].id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var node = DiagramNode(kind: .rectangle, x: 80, y: 90, text: "Small native metadata")
        node.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        diagram.page.nodes = [node]
        let firstURL = temporaryURL("first.vsdx")
        let secondURL = temporaryURL("second.vsdx")

        try VisioFormat.write(diagram, to: firstURL)
        try VisioFormat.write(diagram, to: secondURL)

        let first = try XCTUnwrap(VisioPackage.read(firstURL)["macvisio/document.json"])
        let second = try XCTUnwrap(VisioPackage.read(secondURL)["macvisio/document.json"])
        let parts = try VisioPackage.read(firstURL)
        XCTAssertEqual(first, second)
        XCTAssertFalse(try hasMetadataContentType(parts))
    }

    func testLargeMetadataPatchesOnlyTopLevelPublicHashesAndReopensWithValidIntegrity() throws {
        let escapedMember = #"literal "publicHashes":{"fake":"not a top-level member"} text"#
        let payload = String(repeating: "p", count: 3 * 1024 * 1024) + escapedMember
        var diagram = Diagram()
        for index in 0..<3 {
            var page = index == 0 ? diagram.pages[0] : DiagramPage()
            page.name = "Metadata page \(index + 1)"
            var node = DiagramNode(kind: .rectangle, x: 80, y: 90, text: "Escaped member fixture")
            node.formatting.sheet["User.Payload"] = ShapeSheetCell(value: payload)
            page.nodes = [node]
            if index == 0 { diagram.pages[0] = page } else { diagram.pages.append(page) }
        }
        diagram.activePageID = diagram.pages[0].id
        let originalPageIDs = diagram.pages.map(\.id)
        let url = temporaryURL("large.vsdx")

        try VisioFormat.write(diagram, to: url)

        let parts = try VisioPackage.read(url)
        let metadata = try XCTUnwrap(parts["macvisio/document.json"])
        let loaded = try NativeMetadataStorage.load(metadata, parts: parts)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: loaded.data) as? [String: Any])
        let publicHashes = try XCTUnwrap(envelope["publicHashes"] as? [String: String])
        XCTAssertGreaterThan(loaded.data.count, VisioPackage.partLimit)
        XCTAssertEqual(publicHashes["[Content_Types].xml"], VisioFormat.hash(try XCTUnwrap(parts["[Content_Types].xml"])))
        XCTAssertTrue(try hasMetadataContentType(parts))

        let imported = try VisioFormat.read(from: url)
        XCTAssertEqual(imported.diagram.pages.map(\.id), originalPageIDs)
        XCTAssertFalse(imported.warnings.contains(where: { $0.contains("changed outside MacVisio") }))
        for page in imported.diagram.pages {
            let cell = try XCTUnwrap(page.nodes.first?.formatting.sheet["User.Payload"])
            XCTAssertTrue(cell.value.hasSuffix(escapedMember))
        }
    }

    private func hasMetadataContentType(_ parts: [String: Data]) throws -> Bool {
        let document = try VisioXML.document(XCTUnwrap(parts["[Content_Types].xml"]))
        return document.rootElement()?.elementsLocal("Default").contains {
            $0.attr("Extension") == "mvmeta" && $0.attr("ContentType") == "application/octet-stream"
        } ?? false
    }

    private func temporaryURL(_ name: String) -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisioMetadataEncoding-\(UUID())", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(name)
    }
}
