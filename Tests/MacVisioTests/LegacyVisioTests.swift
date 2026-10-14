import AppKit
import XCTest
@testable import MacVisio

final class LegacyVisioTests: XCTestCase {
    private func fixture(_ name:String,_ ext:String = "vsd") throws -> URL { try XCTUnwrap(Bundle.module.url(forResource:name,withExtension:ext,subdirectory:"Fixtures")) }
    func testRealLegacyVisio5Visio6AndVisio11DocumentsProduceEditableVectors() throws {
        XCTAssertNotNil(LegacyVisioFormat.converterURL,"Install libvisio for interoperability tests")
        for name in ["no-bgcolor","Visio5PlanWithDimensions","Visio6TextFieldsWithUnits","Visio11FormatLine","bitmaps"] {
            let imported = try LegacyVisioFormat.read(from:fixture(name))
            XCTAssertFalse(imported.diagram.pages.isEmpty,name)
            XCTAssertTrue(imported.diagram.pages.contains{!$0.nodes.isEmpty},name)
            XCTAssertTrue(imported.diagram.pages.flatMap(\.nodes).contains{!$0.formatting.paths.isEmpty || $0.formatting.image != nil || $0.kind == .text},name)
            XCTAssertEqual(try imported.diagram.validated(),imported.diagram,name)
            XCTAssertTrue(imported.warnings.contains{$0.contains("Binary VSD writing")})
        }
    }
    func testConvertedLegacyDrawingExportsRealVisioXML() throws {
        let model = try LegacyVisioFormat.read(from:fixture("no-bgcolor")).diagram
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Legacy-export-\(UUID()).vsdx")
        defer { try? FileManager.default.removeItem(at:url) }
        try VisioFormat.write(model,to:url)
        var parts = try VisioPackage.read(url); parts.removeValue(forKey:"macvisio/document.json"); try VisioPackage.write(parts,to:url)
        let restored = try VisioFormat.read(from:url).diagram
        XCTAssertEqual(restored.pages.count,model.pages.count)
        XCTAssertEqual(restored.pages.map{$0.nodes.count},model.pages.map{$0.nodes.count})
        XCTAssertFalse(restored.page.nodes.flatMap{$0.formatting.paths}.isEmpty)
    }
    func testMismatchedFormatsAreRejectedInsteadOfRenamingZIPData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Never-fake-\(UUID()).vsd")
        XCTAssertThrowsError(try VisioFormat.write(Diagram(),to:url))
        let document = MacVisioDocument()
        XCTAssertTrue(try document.data(ofType:MacVisioDocument.legacyType).starts(with:CompoundFile.signature))
        XCTAssertThrowsError(try document.write(to:url,ofType:MacVisioDocument.visioType))
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
        XCTAssertTrue(MacVisioDocument.writableTypes.contains(MacVisioDocument.legacyType))
    }
    func testSVGPathRelativeSmoothCurvesAndEllipticalArcs() throws {
        let commands = try SVGPath.parse("M10 10 l20 0 h10 v20 c0 10 10 10 10 0 s10 -10 10 0 q10 10 20 0 t20 0 a10 20 30 0 1 20 30 z")
        XCTAssertEqual(commands.first,VectorCommand("M",10,10)); XCTAssertEqual(commands.last,VectorCommand("Z"))
        XCTAssertTrue(commands.allSatisfy(\.isValid)); XCTAssertGreaterThan(commands.filter{$0.kind == "C"}.count,2)
        XCTAssertEqual(commands[1],VectorCommand("L",30,10)); XCTAssertEqual(commands[2],VectorCommand("L",40,10))
        XCTAssertThrowsError(try SVGPath.parse("M 0 0 C 1 2")); XCTAssertThrowsError(try SVGPath.parse("L 0 0")); XCTAssertThrowsError(try SVGPath.parse("M 0 0 R 1 2"))
    }
    func testSVGParserPreservesTransformsTextAndCurves() throws {
        let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4in\" height=\"3in\" viewBox=\"0 0 288 216\"><g transform=\"translate(20 30)\"><path fill=\"#ff0000\" stroke=\"none\" d=\"M0 0 C0 40 60 40 60 0 Z\"/><text x=\"10\" y=\"80\"><tspan font-size=\"18\" fill=\"#0000ff\">Hello &amp; World</tspan></text></g></svg>"
        let result = try SVGImport.page(Data(svg.utf8),name:"Independent SVG")
        XCTAssertEqual(result.page.width,288); XCTAssertEqual(result.page.height,216)
        let node = try XCTUnwrap(result.page.nodes.first{$0.formatting.paths.count > 0})
        XCTAssertEqual(node.x,20,accuracy:0.001); XCTAssertEqual(node.y,30,accuracy:0.001); XCTAssertEqual(node.fill,"#FF0000")
        let text = try XCTUnwrap(result.page.nodes.first{$0.kind == .text})
        XCTAssertEqual(text.text,"Hello & World"); XCTAssertEqual(text.fontSize,18); XCTAssertEqual(text.textColor,"#0000FF")
    }
    func testIndependentRealVSDXFixturesLoad() throws {
        for name in ["blue-box","testfile1"] {
            let result = try VisioFormat.read(from:fixture(name,"vsdx"))
            XCTAssertFalse(result.diagram.pages.isEmpty)
            XCTAssertFalse(result.diagram.page.nodes.isEmpty)
            XCTAssertNotNil(result.diagram.visioArchive)
        }
    }
}
