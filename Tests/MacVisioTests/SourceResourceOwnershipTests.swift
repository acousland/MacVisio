import XCTest
@testable import MacVisio

final class SourceResourceOwnershipTests: XCTestCase {
    func testSnapshotsShareImmutableSourceButMutationDetachesAndCodableStaysCompatible() throws {
        let archive = VisioDocumentArchive(parts: ["vendor/opaque.bin": Data([0, 1, 255])], pagesPart: "visio/pages/pages.xml", pages: [])
        var snapshot = archive
        XCTAssertEqual(snapshot.sourceResourceID, archive.sourceResourceID)
        XCTAssertEqual(snapshot.sourceLineageID, archive.sourceLineageID)
        XCTAssertEqual(archive.sourceByteCount, 3)
        snapshot.parts["vendor/opaque.bin"] = Data([9])
        XCTAssertNotEqual(snapshot.sourceResourceID, archive.sourceResourceID)
        XCTAssertEqual(snapshot.sourceLineageID, archive.sourceLineageID,"A derived package retains lineage without retaining historical resource IDs")
        XCTAssertEqual(archive.parts["vendor/opaque.bin"], Data([0, 1, 255]))
        XCTAssertEqual(snapshot.parts["vendor/opaque.bin"], Data([9]))

        let encoded = try JSONEncoder().encode(archive)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["parts", "pagesPart", "pages"])
        let decoded = try JSONDecoder().decode(VisioDocumentArchive.self, from: encoded)
        XCTAssertEqual(decoded, archive)
        XCTAssertNotEqual(decoded.sourceResourceID, archive.sourceResourceID)
        XCTAssertNotEqual(decoded.sourceLineageID, archive.sourceLineageID,"A separately read source starts a distinct ownership lineage")
    }
}
