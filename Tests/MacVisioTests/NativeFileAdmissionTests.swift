import AppKit
import Darwin
import XCTest
@testable import MacVisio

final class NativeFileAdmissionTests: XCTestCase {
    func testRegularNativeTargetCanStillBeOpenedThroughSymbolicAlias() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M2-alias-admission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Source.macvisio"), alias = directory.appendingPathComponent("Alias.macvisio")
        var model = Diagram(); model.page.nodes = [DiagramNode(text: "Canonical target")]
        let bytes = try JSONEncoder().encode(model); try bytes.write(to: source)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let document = MacVisioDocument(); defer { document.close() }
        try document.read(from: alias, ofType: MacVisioDocument.nativeType)
        XCTAssertEqual(document.diagram.page.nodes[0].text, "Canonical target")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testSparseOversizedNativeFileRejectsBeforeReadingAndKeepsDocumentState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M2-file-admission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Oversized.macvisio")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        let file = try FileHandle(forWritingTo: url); defer { try? file.close() }
        try file.truncate(atOffset: 256_000_001)
        let document = MacVisioDocument(); defer { document.close() }
        let baseline = document.diagram, state = document.stateID
        XCTAssertThrowsError(try document.read(from: url, ofType: MacVisioDocument.nativeType)) { error in
            XCTAssertTrue(error.localizedDescription.contains("supported document size"))
        }
        XCTAssertEqual(document.diagram, baseline); XCTAssertEqual(document.stateID, state)
    }
    func testNamedPipeCannotEnterBlockingDrawingReader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M2-pipe-\(UUID()).macvisio")
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MacVisioDocument(); defer { document.close() }
        XCTAssertThrowsError(try document.read(from: url, ofType: MacVisioDocument.nativeType)) { error in
            XCTAssertTrue(error.localizedDescription.contains("regular drawing file"))
        }
    }
}
