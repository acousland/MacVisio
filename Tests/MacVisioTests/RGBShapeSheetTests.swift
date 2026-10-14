import Foundation
import XCTest
@testable import MacVisio

final class RGBShapeSheetTests: XCTestCase {
    func testScalarRGBReturnsKnownPaletteIndex() throws {
        let palette = ShapeSheetColorPalette()
        func value(_ formula: String) throws -> Double {
            try ShapeSheet.evaluate(formula, resolve: { _ in throw DiagramError.invalid("Unexpected reference") }, colorPalette: palette)
        }

        XCTAssertEqual(try value("RGB(0,0,0)"), 0)
        XCTAssertEqual(try value("RGB(255,0,0)"), 2)
        XCTAssertEqual(try value("RGB(51,51,51)"), 22)
        XCTAssertThrowsError(try value("RGB(1,2,3)"))
    }

    func testTypedRGBUsesTheSameSharedDocumentPalette() throws {
        let palette = ShapeSheetColorPalette(entries: [31: "#ADADAD"])
        func value(_ formula: String) throws -> SheetValue {
            try TypedShapeSheet.evaluate(formula, resolve: { _ in throw DiagramError.invalid("Unexpected reference") }, call: { name, _ in throw DiagramError.invalid("Unexpected function: \(name)") }, colorPalette: palette)
        }

        XCTAssertEqual(try value("RGB(0,0,255)"), .number(4))
        XCTAssertEqual(try value("RGB(173,173,173)"), .number(31))
        XCTAssertThrowsError(try value("RGB(1,2,3)"))
    }

    func testDefaultEvaluatorsRejectUnknownColorsWithoutDocumentEntries() {
        XCTAssertThrowsError(try ShapeSheet.evaluate("RGB(1,2,3)", resolve: { _ in 0 }))
        XCTAssertThrowsError(try TypedShapeSheet.evaluate("RGB(1,2,3)", resolve: { _ in .number(0) }, call: { _, _ in .number(0) }))
    }

    func testShapeSheetEngineUsesImportedDocumentPaletteAndKeepsUnknownCachedValue() {
        let xml = "<VisioDocument><Colors><ColorEntry IX=\"31\" RGB=\"#ADADAD\"/></Colors></VisioDocument>"
        let archive = VisioDocumentArchive(parts:["visio/document.xml":Data(xml.utf8)],pagesPart:"visio/pages/pages.xml",pages:[])
        var node = DiagramNode(text:"Palette")
        node.formatting.sheet["User.Color"] = ShapeSheetCell(value:"0",formula:"RGB(173,173,173)")
        var page = DiagramPage();page.nodes = [node]
        var diagram = Diagram();diagram.pages = [page];diagram.activePageID = page.id;diagram.visioArchive = archive

        let calculated = ShapeSheetEngine.recalculate(diagram)
        XCTAssertTrue(calculated.issues.isEmpty,calculated.issues.joined(separator:"\n"))
        XCTAssertEqual(calculated.diagram.page.nodes[0].formatting.sheet["User.Color"]?.value,"31")

        diagram.page.nodes[0].formatting.sheet["User.Color"] = ShapeSheetCell(value:"17",formula:"RGB(1,2,3)")
        let unsupported = ShapeSheetEngine.recalculate(diagram)
        XCTAssertEqual(unsupported.diagram.page.nodes[0].formatting.sheet["User.Color"]?.value,"17")
        XCTAssertFalse(unsupported.issues.isEmpty)
    }

    func testNewPaletteEntriesRequireExplicitAllocationOptIn() throws {
        let palette = ShapeSheetColorPalette(entries: [31: "#ADADAD"], allowsAddingColors: true)
        XCTAssertEqual(try ShapeSheet.evaluate("RGB(1,2,3)", resolve: { _ in 0 }, colorPalette: palette), 32)
        XCTAssertEqual(try ShapeSheet.evaluate("RGB(1,2,3)", resolve: { _ in 0 }, colorPalette: palette), 32)
    }

    func testRGBRejectsUnsupportedChannelsAndArity() {
        for formula in ["RGB()", "RGB(1,2)", "RGB(1,2,3,4)", "RGB(-1,0,0)", "RGB(256,0,0)", "RGB(1.5,0,0)", "RGB(1,2,3pt)", "RGB(72pt,0,0)", "RGB(\"1\",0,0)"] {
            XCTAssertThrowsError(try ShapeSheet.evaluate(formula, resolve: { _ in 0 }), formula)
        }
        for formula in ["RGB()", "RGB(1,2)", "RGB(1,2,3,4)", "RGB(-1,0,0)", "RGB(256,0,0)", "RGB(1.5,0,0)", "RGB(1,2,3pt)", "RGB(72pt,0,0)", "RGB(TRUE,0,0)", "RGB(\"1\",0,0)"] {
            XCTAssertThrowsError(try TypedShapeSheet.evaluate(formula, resolve: { _ in .number(0) }, call: { _, _ in .number(0) }), formula)
        }
    }

    func testInstallerRGBFormulaUsesItsActualVSDXColorEntry() throws {
        let workspace = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = workspace.appendingPathComponent("build/Visio2019-Libraries/BLDCOR_M.VSSX")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Installer assets are absent") }
        let parts = try VisioPackage.read(source)
        let archive = VisioDocumentArchive(parts:parts,pagesPart:"visio/pages/pages.xml",pages:[])
        let palette = ShapeSheetColorPalette(documentArchive:archive)
        XCTAssertEqual(try palette.index(for:[173,173,173]),31)

        let master = try VisioXML.document(XCTUnwrap(parts["visio/masters/master10.xml"]))
        var pending = [try XCTUnwrap(master.rootElement())]
        var sourceFormula: String?
        while let element = pending.popLast() {
            if element.localTag == "Cell", let formula = element.attr("F"), formula.contains("RGB(173,173,173)") {
                sourceFormula = formula
                break
            }
            pending.append(contentsOf: (element.children ?? []).compactMap { $0 as? XMLElement })
        }
        let formula = try XCTUnwrap(sourceFormula)
        let colorRange = try XCTUnwrap(formula.range(of: "RGB\\([^)]*\\)", options: .regularExpression))
        let node = DiagramNode(text:"Installer palette")
        let context = ShapeSheetContext(page:{ var page = DiagramPage();page.nodes = [node];return page }(),colorPalette:palette)
        XCTAssertEqual(try context.evaluate(String(formula[colorRange]),on:node.id),.number(31))

        let stencil = try VisioStencil.read(from:source)
        let importedRGB = stencil.items.flatMap(\.fragment.nodes).flatMap { $0.formatting.sheet.values }
        XCTAssertTrue(importedRGB.contains{$0.formula.contains("RGB(173,173,173)") && $0.value == "31"},
                      "VSSX import should evaluate the supported custom RGB formula while its source palette is available")
    }
}
