import AppKit
import XCTest
@testable import MacVisio

/// Discovery regressions for authored public content. These checks establish
/// preservation/local behavior only; the M3 reference acceptance remains open.
final class M3PublicFixtureTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func output(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-M3-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory.appendingPathComponent(name)
    }

    private func fixture() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "m3-intelligent", withExtension: "vsdx", subdirectory: "Fixtures/M3"))
    }

    private func publicCopy(_ source: URL) throws -> URL {
        var parts = try VisioPackage.read(source)
        NativeMetadataStorage.removeSegments(from: &parts)
        parts.removeValue(forKey: "macvisio/document.json")
        // Remove matching registrations as well as payloads. The validation copy
        // must not require native metadata or retain dangling native targets.
        if let data = parts["_rels/.rels"] {
            let document = try VisioXML.document(data)
            for relation in document.rootElement()?.elementsLocal("Relationship") ?? [] where relation.attr("Type") == "urn:macvisio:relationships:diagram" {
                relation.detach()
            }
            parts["_rels/.rels"] = document.xmlData(options: .nodePreserveAll)
        }
        let target = try output("public.vsdx")
        try VisioPackage.write(parts, to: target)
        return target
    }

    func testNoEditKeepsAllAuthoredPublicPartsByteForByte() throws {
        let source = try fixture()
        let imported = try VisioFormat.read(from: source)
        XCTAssertEqual(imported.diagram.pages.count, 2)
        XCTAssertEqual(imported.diagram.pages[0].edges.count, 1)
        let copy = try output("unchanged.vsdx")
        try VisioFormat.write(imported.diagram, to: copy)
        XCTAssertEqual(try VisioPackage.read(copy), try VisioPackage.read(source))
    }

    func testInstanceTextEditKeepsOtherMasterStyleThemeAndConnectorPayloads() throws {
        let source = try fixture(), original = try VisioPackage.read(source)
        var diagram = try VisioFormat.read(from: source).diagram
        let index = try XCTUnwrap(diagram.pages[0].nodes.firstIndex { $0.formatting.sourceShapeID == "20" })
        diagram.pages[0].nodes[index].text = "Edited local override"
        let edited = try output("edited.vsdx")
        try VisioFormat.write(diagram, to: edited)
        let parts = try VisioPackage.read(edited)
        for name in ["visio/document.xml", "visio/masters/masters.xml", "visio/masters/master1.xml", "visio/masters/master2.xml", "visio/theme/theme1.xml", "synthetic/opaque.bin", "visio/pages/page2.xml"] {
            XCTAssertEqual(parts[name], original[name], name)
        }
        let before = try VisioXML.document(XCTUnwrap(original["visio/pages/page1.xml"])).rootElement()
        let after = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"])).rootElement()
        for id in ["10", "30"] {
            XCTAssertEqual(before?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == id }?.xmlString,
                           after?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == id }?.xmlString, id)
        }
        let reopened = try VisioFormat.read(from: publicCopy(edited)).diagram
        XCTAssertEqual(reopened.pages[0].nodes.first { $0.formatting.sourceShapeID == "20" }?.text, "Edited local override")
        XCTAssertEqual(reopened.pages[0].edges.first?.label, "Link 東京")
        XCTAssertEqual(reopened.pages[0].nodes.first { $0.formatting.sourceShapeID == "10" }?.text, "Café 東京 🙂 bold\nSecond paragraph")
    }

    func testOneMetreAtOneToFiftyHas20mmPublicAndPDFGeometry() throws {
        _ = NSApplication.shared
        let source = try XCTUnwrap(Bundle.module.url(forResource: "m3-physical", withExtension: "vsdx", subdirectory: "Fixtures/M3"))
        let diagram = try VisioFormat.read(from: source).diagram, page = diagram.page
        let object = try XCTUnwrap(page.nodes.first { $0.formatting.sourceShapeID == "1" })
        XCTAssertEqual(object.width / 72 * 25.4, 1000, accuracy: 1e-6)
        XCTAssertEqual(object.width * page.paperScale / 72 * 25.4, 20, accuracy: 1e-6)
        XCTAssertEqual(page.paperWidth / 72 * 25.4, 210, accuracy: 1e-6)
        XCTAssertEqual(page.paperHeight / 72 * 25.4, 297, accuracy: 1e-6)
        let guide = try XCTUnwrap(page.nodes.first { $0.formatting.sourceShapeID == "2" })
        XCTAssertTrue(page.isVisible(guide)); XCTAssertFalse(page.isVisible(guide, printing: true))
        XCTAssertFalse(DiagramDrawing.svg(page).contains("Nonprinting guide"))

        let output = DiagramExport.pdf(page)
        let pdf = try XCTUnwrap(CGPDFDocument(CGDataProvider(data: output as CFData)!))
        let pdfPage = try XCTUnwrap(pdf.page(at: 1)), box = pdfPage.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width / 72 * 25.4, 210, accuracy: 1e-4)
        XCTAssertEqual(box.height / 72 * 25.4, 297, accuracy: 1e-4)
        // Measure the actual PDF render, so a missing or double-applied scale in
        // the output path cannot pass solely through matching native dimensions.
        let scale = 4.0, width = Int(ceil(box.width * scale)), height = Int(ceil(box.height * scale))
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale); context.drawPDFPage(pdfPage)
        }
        var left = width, right = -1
        for y in 0..<height { for x in 0..<width {
            let offset = (y * width + x) * 4
            if pixels[offset] < 40 && pixels[offset + 1] < 40 && pixels[offset + 2] < 40 {
                left = min(left, x); right = max(right, x)
            }
        } }
        XCTAssertGreaterThanOrEqual(right, left, "The one-metre object must actually be painted.")
        let measuredMM = Double(right - left + 1) / scale / 72 * 25.4
        XCTAssertEqual(measuredMM, 20, accuracy: 0.2, "PDF render at 100%; calibrated physical printer acceptance remains pending.")
    }
}
