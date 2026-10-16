import AppKit
import XCTest
@testable import MacVisio

final class NativeEditorPolicyTests: XCTestCase {
    func testInspectorUnitsAreExplicitAndDoNotConflatePaperAndDrawingLengths() {
        XCTAssertEqual(InspectorLengthUnit.parse("25.4 mm")!, 72, accuracy: 0.000001)
        XCTAssertEqual(InspectorLengthUnit.parse("2", defaultUnit: .inches), 144)
        XCTAssertEqual(InspectorLengthUnit.parse("12", defaultUnit: .inches, paperPoints: true), 12)
        XCTAssertEqual(InspectorLengthUnit.parse("3.141592653589793rad", angle: true)!, 180, accuracy: 0.000001)
        for invalid in ["nan", "inf", "1e999", "Sheet.1!Width", "RUNADDON(1)", "2px", "1+2"] {
            XCTAssertNil(InspectorLengthUnit.parse(invalid), invalid)
        }
        XCTAssertNil(InspectorLengthUnit.parse("2cm", paperPoints: true))
        XCTAssertNil(InspectorLengthUnit.parse("1in", angle: true))
        XCTAssertEqual(InspectorLengthUnit.millimeters.display(72), "25.4")
    }

    func testProtectionRejectsInheritedUnknownDuplicateAliasAndGuardedChanges() {
        var group = DiagramNode(); group.formatting.isGroup = true
        var node = DiagramNode(); node.parentID = group.id
        var page = DiagramPage(); page.nodes = [group, node]
        XCTAssertNil(NativeEditProtection.blockReason(for: "X", node: node, in: page))
        page.nodes[0].formatting.sheet["Protection.LockMoveX"] = ShapeSheetCell(value: "TRUE", formula: "")
        XCTAssertNotNil(NativeEditProtection.blockReason(for: "X", node: node, in: page))
        XCTAssertNil(NativeEditProtection.blockReason(for: "Y", node: node, in: page))
        node.formatting.sheet["LockMoveY"] = ShapeSheetCell(value: "0", formula: "Sheet.2!User.Unknown")
        XCTAssertNotNil(NativeEditProtection.blockReason(for: "Y", node: node, in: page))
        node.formatting.sheet["LockMoveY"] = ShapeSheetCell(value: "FALSE", formula: "FALSE")
        XCTAssertNil(NativeEditProtection.blockReason(for: "Y", node: node, in: page))
        node.formatting.sheet["Protection.LockMoveY"] = ShapeSheetCell(value: "1", formula: "")
        XCTAssertNotNil(NativeEditProtection.blockReason(for: "Y", node: node, in: page))
        node.formatting.sheet = ["Width": ShapeSheetCell(value: "2", formula: " = gUaRd (2 in)")]
        XCTAssertNotNil(NativeEditProtection.blockReason(for: "Width", node: node, in: page))
        node.formatting.sheet = ["LockAspect": ShapeSheetCell(value: "1", formula: "")]
        XCTAssertNotNil(NativeEditProtection.blockReason(for: "Height", node: node, in: page))
    }

    func testMissingFontRenderingPreservesRequestedMetadataAcrossNativeTextRoundTrip() throws {
        var node = DiagramNode(kind: .text, text: "אב e\u{301} 🙂")
        node.formatting.fontName = "MacVisio deliberately unavailable font 7F01"
        var style = ShapeCharacterStyle(node: node)
        style.cells["Font"] = ShapeSheetCell(value: node.formatting.fontName, formula: "FONT(\"Original\")")
        node.formatting.textRuns = [ShapeTextRun(text: node.text, character: style, paragraph: ShapeParagraphStyle(alignment: .left))]
        let rendered = ShapeRichText.attributed(node)
        XCTAssertNotNil(rendered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let result = ShapeRichText.applying(rendered, to: node)
        XCTAssertEqual(result.formatting.fontName, node.formatting.fontName)
        XCTAssertEqual(result.formatting.textRuns?.first?.character.fontName, node.formatting.fontName)
        XCTAssertEqual(result.formatting.textRuns?.first?.character.cells, style.cells)
        XCTAssertEqual(result.text, node.text)
    }

    func testContentChecksKeepObjectProvenanceAndDoNotWarnAboutOrdinaryOpaqueMetadata() {
        var diagram = Diagram(); var first = DiagramNode(text: "A")
        first.formatting.fontName = "Missing"; var second = first; second.id = UUID()
        diagram.page.nodes = [first, second]
        let records = DrawingContentChecks.evaluate(diagram, catalog: .init(installedNames: ["Arial"]), inputKey: "committed-key")
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.map(\.id)).count, 2)
        XCTAssertTrue(records.allSatisfy { $0.inputKey == "committed-key" && $0.origin == .font })
        XCTAssertEqual(diagram.page.nodes[0].formatting.fontName, "Missing")
        diagram.page.nodes = []
        XCTAssertTrue(DrawingContentChecks.evaluate(diagram, catalog: .init(installedNames: []), inputKey: "key").isEmpty)
    }

    func testSupportExportCapturesCommittedCountsAndOmitsAllDrawingStrings() throws {
        let document = MacVisioDocument()
        var diagram = Diagram(); diagram.title = "PRIVATE-DRAWING-TITLE"
        diagram.page.nodes = [DiagramNode(text: "PRIVATE-SHAPE-TEXT")]
        document.diagram = diagram
        let report = document.redactedSupportReport()
        let bytes = try JSONEncoder().encode(report)
        let json = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE"))
        XCTAssertEqual(report.counts.shapes, 1)
        XCTAssertEqual(report.timings.suppliedRecordCount, 0)
        document.close()
    }

    func testLightDarkAndInheritedAppearanceKeepPublishedDrawingColorsIdentical() throws {
        _ = NSApplication.shared
        var page = DiagramPage(width: 200, height: 100)
        var node = DiagramNode(x: 20, y: 20, text: "é אב 🙂")
        node.width = 130; node.height = 60; node.fill = "#123456"; node.stroke = "#ABCDEF"
        page.nodes = [node]
        func output(_ appearance: NSAppearance) throws -> (String, Data, Data) {
            var svg = "", png = Data(), pdf = Data(), failure: Error?
            appearance.performAsCurrentDrawingAppearance {
                svg = DiagramDrawing.svg(page)
                do { png = try DiagramExport.png(page, scale: 1) } catch { failure = error }
                pdf = DiagramExport.pdf(page)
            }
            if let failure { throw failure }
            let provider = try XCTUnwrap(CGDataProvider(data: pdf as CFData))
            let document = try XCTUnwrap(CGPDFDocument(provider))
            let pdfPage = try XCTUnwrap(document.page(at: 1))
            let context = try XCTUnwrap(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8,
                bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.drawPDFPage(pdfPage)
            return (svg, png, Data(bytes: try XCTUnwrap(context.data), count: 80_000))
        }
        let light = try output(try XCTUnwrap(NSAppearance(named: .aqua)))
        for appearance in [try XCTUnwrap(NSAppearance(named: .darkAqua)), NSApp.effectiveAppearance] {
            let actual = try output(appearance)
            XCTAssertEqual(actual.0, light.0); XCTAssertEqual(actual.1, light.1); XCTAssertEqual(actual.2, light.2)
        }
    }
}
