import XCTest
import Foundation
@testable import MacVisio

final class StyleInheritanceCacheTests: XCTestCase {
    private let namespace = "http://schemas.microsoft.com/office/visio/2011/1/core"
    private let relationshipNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    private let visioRelationship = "http://schemas.microsoft.com/visio/2010/relationships/"

    func testInheritedStyleFamiliesAndSiblingOverridesRemainIndependent() throws {
        let styles = """
        <StyleSheets>
          <StyleSheet ID="0"><Cell N="LineColor" V="#000000"/><Cell N="LineWeight" V="0.0138888888888889"/><Cell N="FillForegnd" V="#FFFFFF"/><Section N="Character"><Row IX="0"><Cell N="Color" V="#000000"/><Cell N="Size" V="0.166666666666667"/></Row></Section></StyleSheet>
          <StyleSheet ID="50"><Cell N="LineColor" V="#123456"/><Cell N="LineWeight" V="0.0416666666666667"/><Cell N="FillForegnd" V="#22AA44"/><Cell N="QuickStyleLineMatrix" V="3"/><Cell N="QuickStyleType" V="1"/></StyleSheet>
          <StyleSheet ID="51" LineStyle="50" FillStyle="50" TextStyle="50"><Cell N="LineWeight" V="0.0277777777777778"/><Cell N="FillForegndTrans" V="0"/><Cell N="QuickStyleLineMatrix" V="5"/><Section N="Character"><Row IX="0"><Cell N="Color" V="#445566"/><Cell N="Size" V="0.25"/><Cell N="Style" V="1"/></Row></Section></StyleSheet>
        </StyleSheets>
        """
        let shapes = """
        <Shape ID="1" Type="Shape" LineStyle="51" FillStyle="51" TextStyle="51">
          <Cell N="PinX" V="2"/><Cell N="PinY" V="2"/><Cell N="Width" V="2"/><Cell N="Height" V="1"/><Text>Inherited</Text>
        </Shape>
        <Shape ID="2" Type="Shape" LineStyle="51" FillStyle="51" TextStyle="51">
          <Cell N="PinX" V="5"/><Cell N="PinY" V="2"/><Cell N="Width" V="2"/><Cell N="Height" V="1"/>
          <Cell N="LineColor" V="#AABBCC"/><Cell N="FillForegnd" V="#DDAA22"/>
          <Section N="Character"><Row IX="0"><Cell N="Color" V="#778899"/><Cell N="Size" V="0.5"/></Row></Section><Text>Overridden</Text>
        </Shape>
        """
        let url = try fixture(shapes: shapes, styles: styles)
        let nodes = try VisioFormat.read(from: url).diagram.page.nodes
        XCTAssertEqual(nodes.count, 2)

        let inherited = nodes[0]
        XCTAssertEqual(inherited.stroke, "#123456")
        XCTAssertEqual(inherited.strokeWidth, 2, accuracy: 0.0001)
        XCTAssertEqual(inherited.fill, "#22AA44")
        XCTAssertEqual(inherited.textColor, "#445566")
        XCTAssertEqual(inherited.fontSize, 18, accuracy: 0.0001)
        XCTAssertEqual(inherited.text, "Inherited")
        XCTAssertTrue(inherited.bold)
        XCTAssertEqual(inherited.formatting.sheet["QuickStyleLineMatrix"]?.value, "5")
        XCTAssertEqual(inherited.formatting.sheet["QuickStyleType"]?.value, "1")

        let overridden = nodes[1]
        XCTAssertEqual(overridden.stroke, "#AABBCC")
        XCTAssertEqual(overridden.strokeWidth, 2, accuracy: 0.0001)
        XCTAssertEqual(overridden.fill, "#DDAA22")
        XCTAssertEqual(overridden.textColor, "#778899")
        XCTAssertEqual(overridden.fontSize, 36, accuracy: 0.0001)
        XCTAssertEqual(overridden.text, "Overridden")
        XCTAssertTrue(overridden.bold)
        // The per-shape cells above must not alter the other shape's resolved style.
        XCTAssertEqual(inherited.stroke, "#123456")
        XCTAssertEqual(inherited.fill, "#22AA44")
        XCTAssertEqual(inherited.textColor, "#445566")
        XCTAssertEqual(inherited.formatting.sheet["QuickStyleLineMatrix"]?.value, "5")
    }

    func testReusedStyleIDsDoNotLeakResolvedCellsAcrossImports() throws {
        let first = try fixture(shapes: styledShape(), styles: singleStyle(line: "#123456", fill: "#AA1122", text: "#334455"))
        let second = try fixture(shapes: styledShape(), styles: singleStyle(line: "#654321", fill: "#22BB33", text: "#998877"))

        let firstNode = try XCTUnwrap(VisioFormat.read(from: first).diagram.page.nodes.first)
        let secondNode = try XCTUnwrap(VisioFormat.read(from: second).diagram.page.nodes.first)
        XCTAssertEqual(firstNode.stroke, "#123456")
        XCTAssertEqual(firstNode.fill, "#AA1122")
        XCTAssertEqual(firstNode.textColor, "#334455")
        XCTAssertEqual(secondNode.stroke, "#654321")
        XCTAssertEqual(secondNode.fill, "#22BB33")
        XCTAssertEqual(secondNode.textColor, "#998877")
    }

    func testCyclicStyleChainStillResolvesCellsWithinImportDepthBound() throws {
        let styles = """
        <StyleSheets>
          <StyleSheet ID="0"><Cell N="LineColor" V="#000000"/><Cell N="LineWeight" V="0.0138888888888889"/><Cell N="FillForegnd" V="#FFFFFF"/></StyleSheet>
          <StyleSheet ID="40" LineStyle="41"><Cell N="LineColor" V="#654321"/></StyleSheet>
          <StyleSheet ID="41" LineStyle="40"><Cell N="LineWeight" V="0.05"/></StyleSheet>
        </StyleSheets>
        """
        let shape = "<Shape ID=\"1\" Type=\"Shape\" LineStyle=\"40\"><Cell N=\"PinX\" V=\"2\"/><Cell N=\"PinY\" V=\"2\"/><Cell N=\"Width\" V=\"2\"/><Cell N=\"Height\" V=\"1\"/></Shape>"
        let url = try fixture(shapes: shape, styles: styles)
        let node = try XCTUnwrap(VisioFormat.read(from: url).diagram.page.nodes.first)
        XCTAssertEqual(node.stroke, "#654321")
        XCTAssertEqual(node.strokeWidth, 3.6, accuracy: 0.0001)
    }

    private func styledShape() -> String {
        "<Shape ID=\"1\" Type=\"Shape\" LineStyle=\"1\" FillStyle=\"2\" TextStyle=\"3\"><Cell N=\"PinX\" V=\"2\"/><Cell N=\"PinY\" V=\"2\"/><Cell N=\"Width\" V=\"2\"/><Cell N=\"Height\" V=\"1\"/></Shape>"
    }

    private func singleStyle(line: String, fill: String, text: String) -> String {
        """
        <StyleSheets>
          <StyleSheet ID="0"><Cell N="LineColor" V="#000000"/><Cell N="LineWeight" V="0.0138888888888889"/><Cell N="FillForegnd" V="#FFFFFF"/><Section N="Character"><Row IX="0"><Cell N="Color" V="#000000"/><Cell N="Size" V="0.166666666666667"/></Row></Section></StyleSheet>
          <StyleSheet ID="1"><Cell N="LineColor" V="\(line)"/><Cell N="LineWeight" V="0.0277777777777778"/></StyleSheet>
          <StyleSheet ID="2"><Cell N="FillForegnd" V="\(fill)"/></StyleSheet>
          <StyleSheet ID="3"><Section N="Character"><Row IX="0"><Cell N="Color" V="\(text)"/><Cell N="Size" V="0.25"/></Row></Section></StyleSheet>
        </StyleSheets>
        """
    }

    private func fixture(shapes: String, styles: String) throws -> URL {
        let directory = temporaryDirectory()
        var parts: [String: String] = [:]
        parts["[Content_Types].xml"] = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/visio/document.xml\" ContentType=\"application/vnd.ms-visio.drawing.main+xml\"/></Types>"
        parts["_rels/.rels"] = relationships([("rId1", "document", "visio/document.xml")])
        parts["visio/document.xml"] = "<VisioDocument xmlns=\"\(namespace)\">\(styles)</VisioDocument>"
        parts["visio/_rels/document.xml.rels"] = relationships([("rId1", "pages", "pages/pages.xml")])
        parts["visio/pages/pages.xml"] = "<Pages xmlns=\"\(namespace)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><Page ID=\"0\" Name=\"Styles\"><PageSheet><Cell N=\"PageWidth\" V=\"8.5\"/><Cell N=\"PageHeight\" V=\"11\"/></PageSheet><Rel r:id=\"rId1\"/></Page></Pages>"
        parts["visio/pages/_rels/pages.xml.rels"] = relationships([("rId1", "page", "page1.xml")])
        parts["visio/pages/page1.xml"] = "<PageContents xmlns=\"\(namespace)\"><Shapes>\(shapes)</Shapes><Connects/></PageContents>"

        for (path, value) in parts {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url)
        }
        let output = directory.appendingPathComponent("style-inheritance.vsdx")
        try process("/usr/bin/zip", ["-q", output.path] + parts.keys.sorted(), directory: directory)
        return output
    }

    private func relationships(_ values: [(String, String, String)]) -> String {
        "<Relationships xmlns=\"\(relationshipNamespace)\">" + values.map {
            "<Relationship Id=\"\($0.0)\" Type=\"\(visioRelationship)\($0.1)\" Target=\"\($0.2)\"/>"
        }.joined() + "</Relationships>"
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisioStyleTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func process(_ path: String, _ arguments: [String], directory: URL) throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DiagramError.invalid("Style fixture archive operation failed.") }
        return data
    }
}
