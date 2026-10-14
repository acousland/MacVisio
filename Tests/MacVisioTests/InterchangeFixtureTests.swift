import XCTest
@testable import MacVisio

final class InterchangeFixtureTests: XCTestCase {
    func testPublicOnlyCorpusAndAuthoredExpectations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-interchange-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try InterchangeFixtures.generate(in: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fixtures = try XCTUnwrap(manifest["fixtures"] as? [[String: Any]])
        XCTAssertEqual(fixtures.count, 14)
        for fixture in fixtures {
            let file = try XCTUnwrap(fixture["file"] as? String), url = directory.appendingPathComponent(file)
            let bytes = try Data(contentsOf: url)
            XCTAssertEqual(VisioFormat.hash(bytes), fixture["sha256"] as? String)
            if url.pathExtension == "vsdx" {
                let parts = try VisioPackage.read(url)
                XCTAssertNil(parts["macvisio/document.json"])
                XCTAssertFalse(String(decoding: parts["_rels/.rels"]!, as: UTF8.self).contains("urn:macvisio"))
                let model = try VisioFormat.read(from: url).diagram
                let expected = try XCTUnwrap(fixture["expected"] as? [String: Any])
                let pages = try XCTUnwrap(expected["pages"] as? [[String: Any]])
                XCTAssertEqual(model.pages.count, pages.count)
                for (page, authored) in zip(model.pages, pages) {
                    XCTAssertEqual(page.name, authored["name"] as? String)
                    XCTAssertEqual(page.nodes.count + page.edges.count, (authored["shapes"] as? [Any])?.count)
                }
            } else {
                let compound = try CompoundFile.read(bytes)
                XCTAssertNil(compound.streams[VSDBinaryFormat.nativeStream])
                XCTAssertNotNil(compound.streams["VisioDocument"])
            }
        }
        let oldManifest = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try InterchangeFixtures.generate(in: directory))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), oldManifest)
    }
}
