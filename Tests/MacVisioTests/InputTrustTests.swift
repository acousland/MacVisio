import Foundation
import XCTest
@testable import MacVisio

final class InputTrustTests: XCTestCase {
    func testXMLRejectsDTDExternalEntitiesInvalidEncodingAndOversizedParts() throws {
        let forbidden = [
            "<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><x>&secret;</x>",
            "<!doctype x SYSTEM 'https://127.0.0.1:1/private'><x/>",
            "<!ENTITY secret 'private'><x/>"
        ]
        for xml in forbidden {
            XCTAssertThrowsError(try VisioXML.document(Data(xml.utf8)))
        }
        XCTAssertThrowsError(try VisioXML.document(Data([0xFF, 0xFE, 0x00])))
        XCTAssertThrowsError(try VisioXML.document(Data(repeating: 0x20, count: VisioPackage.partLimit + 1)))
    }

    func testXMLStreamingPreflightEnforcesDepthAndNodeBudgets() throws {
        let allowed = String(repeating: "<x>", count: 100) + String(repeating: "</x>", count: 100)
        XCTAssertNotNil(try VisioXML.document(Data(allowed.utf8)).rootElement())
        let deep = "<x>" + allowed + "</x>"
        XCTAssertThrowsError(try VisioXML.document(Data(deep.utf8)))
        let wide = "<root>" + String(repeating: "<x/>", count: 500_000) + "</root>"
        XCTAssertThrowsError(try VisioXML.document(Data(wide.utf8)))
    }

    func testPreflightKeepsOrderedWhitespaceAndUnicodeTextRuns() throws {
        let xml = "<PageContents><Shapes><Shape><Text>א🙂<cp IX='2'/>  <cp IX='4'/>e\u{301}</Text></Shape></Shapes></PageContents>"
        let document = try VisioXML.document(Data(xml.utf8))
        let text = try XCTUnwrap(document.rootElement()?.firstLocal("Shapes")?.firstLocal("Shape")?.firstLocal("Text"))
        XCTAssertEqual(text.stringValue, "א🙂  e\u{301}")
        XCTAssertEqual(text.children?.count, 5)
        XCTAssertEqual(text.children?[2].stringValue, "  ")
    }

    func testPackageTargetsCannotEscapeOrBecomeExternalResources() throws {
        for target in ["../../../private.xml", "https://127.0.0.1:1/private.xml", "file:///etc/passwd", "..%2F..%2F..%2Fprivate.xml", "a%3Ab", "a\\b", "part.xml#secret", "part.xml?token=secret"] {
            XCTAssertThrowsError(try VisioFormat.resolve(target, relativeTo: "visio/pages/page1.xml"), target)
        }
        XCTAssertEqual(try VisioFormat.resolve("../media/image1.png", relativeTo: "visio/pages/page1.xml"), "visio/media/image1.png")
        for name in ["../escape", "/absolute", "a/./b", "a/../b", "a\\b", "a:b", "a\u{0}b"] {
            XCTAssertThrowsError(try VisioPackage.validatePath(name), name)
        }
    }

    func testCompoundCorruptionFailsWithoutFollowingAllocationCycles() throws {
        var data = try CompoundFile(streams: ["probe": Data(repeating: 1, count: 5000)]).encoded()
        // Header directory sector points beyond any sector in the document.
        data.set(UInt32.max - 5, at: 48)
        XCTAssertThrowsError(try CompoundFile.read(data))
        XCTAssertThrowsError(try CompoundFile.read(CompoundFile.signature))
    }

    func testActionFunctionsAndExcessiveFormulaNestingHaveNoExecutionPath() throws {
        for formula in ["RUNADDON(\"touch /tmp/MacVisio-untrusted\")", "SHELLEXEC(\"file:///private\")", "CALLTHIS(\"UntrustedMacro\")"] {
            XCTAssertThrowsError(try ShapeSheet.evaluate(formula, resolve: { _ in 0 }))
        }
        XCTAssertThrowsError(try ShapeSheet.parse(String(repeating: "(", count: 80) + "1" + String(repeating: ")", count: 80)))
    }

    func testOpeningImportedActionPreservesSourceWithoutLaunchingIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-trust-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("executed")
        let executable = directory.appendingPathComponent("untrusted.sh")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        var diagram = Diagram()
        diagram.page.nodes = [DiagramNode(kind: .rectangle, x: 30, y: 40, text: "Safe cached label")]
        let source = directory.appendingPathComponent("action.vsdx")
        try VisioFormat.write(diagram, to: source)
        var parts = try VisioPackage.read(source)
        parts.removeValue(forKey: "macvisio/document.json")
        let pagePart = "visio/pages/page1.xml"
        var xml = String(decoding: try XCTUnwrap(parts[pagePart]), as: UTF8.self)
        let action = "<Section N=\"Actions\"><Row IX=\"0\"><Cell N=\"Action\" F=\"RUNADDON(&quot;\(executable.path)&quot;)\" V=\"0\"/></Row></Section>"
        xml = xml.replacingOccurrences(of: "</Shape>", with: action + "</Shape>")
        parts[pagePart] = Data(xml.utf8)
        try VisioPackage.write(parts, to: source)
        let original = try Data(contentsOf: source)
        let imported = try VisioFormat.read(from: source)
        XCTAssertEqual(imported.diagram.page.nodes.first?.text, "Safe cached label")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(imported.diagram.visioArchive?.parts[pagePart], parts[pagePart])
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
