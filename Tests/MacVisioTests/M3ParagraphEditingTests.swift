import AppKit
import XCTest
#if canImport(FoundationXML)
import FoundationXML
#endif
@testable import MacVisio

/// Local paragraph extraction/public-preservation evidence. Tabs, bullets and
/// reference-application layout qualification remain separate catalog slices.
final class M3ParagraphEditingTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        super.tearDown()
    }

    private func file() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-M3-paragraph-\(UUID()).vsdx")
        files.append(url)
        return url
    }

    private func node() -> DiagramNode {
        var node = DiagramNode(text: "First bold\nSecond paragraph")
        node.formatting.fontName = "Arial"
        var paragraph = ShapeParagraphStyle(alignment: .left, sourceIndex: 4)
        paragraph.cells = [
            "SpBefore": ShapeSheetCell(value: "0.1", formula: "0.1 in", unit: "IN"),
            "SpAfter": ShapeSheetCell(value: "0.2", formula: "0.2 in", unit: "IN"),
            "SpLine": ShapeSheetCell(value: "-1.5", formula: "-1.5"),
            "IndLeft": ShapeSheetCell(value: "0.25", formula: "0.25 in", unit: "IN"),
            "IndFirst": ShapeSheetCell(value: "0.1", unit: "IN"),
            "IndRight": ShapeSheetCell(value: "0.3", unit: "IN"),
            "Bullet": ShapeSheetCell(value: "0"),
            "CustomParagraphMetadata": ShapeSheetCell(value: "retained", formula: "\"retained\"", unit: "STR"),
        ]
        var character = ShapeCharacterStyle(node: node)
        character.sourceIndex = 3
        character.cells["LangID"] = ShapeSheetCell(value: "1033")
        var bold = character
        bold.sourceIndex = 9
        bold.bold = true
        node.formatting.textRuns = [
            ShapeTextRun(text: "First ", character: character, paragraph: paragraph),
            ShapeTextRun(text: "bold\n", character: bold, paragraph: paragraph),
            ShapeTextRun(text: "Second paragraph", character: character, paragraph: paragraph),
        ]
        return node
    }

    private func editingSecondParagraph(
        _ node: DiagramNode, scale: Double = 1, change: (NSMutableParagraphStyle) -> Void
    ) throws -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: ShapeRichText.attributed(node, scale: scale))
        let range = (text.string as NSString).range(of: "Second paragraph")
        let original = try XCTUnwrap(text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)
        let changed = try XCTUnwrap(original.mutableCopy() as? NSMutableParagraphStyle)
        change(changed)
        text.addAttribute(.paragraphStyle, value: changed, range: range)
        return text
    }

    private func publicParts(_ source: URL) throws -> [String: Data] {
        var parts = try VisioPackage.read(source)
        NativeMetadataStorage.removeSegments(from: &parts)
        parts.removeValue(forKey: "macvisio/document.json")
        if let bytes = parts["_rels/.rels"] {
            let document = try VisioXML.document(bytes)
            for relation in document.rootElement()?.elementsLocal("Relationship") ?? []
                where relation.attr("Type") == "urn:macvisio:relationships:diagram" {
                relation.detach()
            }
            parts["_rels/.rels"] = document.xmlData(options: .nodePreserveAll)
        }
        return parts
    }

    private func imported() throws -> (Diagram, [String: Data]) {
        let url = file()
        var diagram = Diagram()
        diagram.page.width = 720
        diagram.page.height = 480
        try VisioFormat.write(diagram, to: url)
        var parts = try publicParts(url)
        parts["visio/pages/page1.xml"] = Data("""
        <PageContents xmlns="http://schemas.microsoft.com/office/visio/2012/main" xml:space="preserve"><Shapes><Shape ID="1" Type="Shape">
        <Cell N="Width" V="6"/><Cell N="Height" V="3"/><Cell N="PinX" V="4"/><Cell N="PinY" V="3"/><Cell N="LocPinX" V="3"/><Cell N="LocPinY" V="1.5"/>
        <Section N="Character"><Row IX="3"><Cell N="Font" V="Arial"/><Cell N="Size" V="0.1944444444444444"/><Cell N="Style" V="0"/></Row><Row IX="9"><Cell N="Font" V="Arial"/><Cell N="Size" V="0.1944444444444444"/><Cell N="Style" V="1"/><Cell N="LangID" V="1033"/></Row></Section>
        <Section N="Paragraph"><Row IX="4"><Cell N="HorzAlign" V="0"/><Cell N="SpBefore" V="0.1" F="0.1 in" U="IN"/><Cell N="SpAfter" V="0.2" F="0.2 in" U="IN"/><Cell N="SpLine" V="-1.5" F="-1.5"/><Cell N="IndLeft" V="0.25" U="IN"/><Cell N="IndFirst" V="0.1" U="IN"/><Cell N="IndRight" V="0.3" U="IN"/><Cell N="Bullet" V="0"/><Cell N="CustomParagraphMetadata" V="retained" U="STR"/></Row></Section>
        <Text><cp IX="3"/><pp IX="4"/>First <cp IX="9"/>bold
        <cp IX="3"/><pp IX="4"/>Second paragraph</Text></Shape></Shapes></PageContents>
        """.utf8)
        try VisioPackage.write(parts, to: url)
        return (try VisioFormat.read(from: url).diagram, parts)
    }

    func testSelectedParagraphLengthsUseZoomAndRetainUntouchedRunsAndSourceCells() throws {
        try onMain {
            let original = node(), scale = 1.5
            let text = try editingSecondParagraph(original, scale: scale) { style in
                style.paragraphSpacingBefore = 0.2 * 72 * scale
                style.paragraphSpacing = 0.3 * 72 * scale
                style.minimumLineHeight = 0.4 * 72 * scale
                style.maximumLineHeight = style.minimumLineHeight
                style.headIndent = 0.5 * 72 * scale
                style.firstLineHeadIndent = (0.5 - 0.125) * 72 * scale
                style.tailIndent = -0.75 * 72 * scale
            }
            let result = ShapeRichText.applying(text, to: original, scale: scale)
            let runs = try XCTUnwrap(result.formatting.textRuns)
            XCTAssertEqual(result.text, original.text)
            XCTAssertEqual(Array(runs.prefix(2)), Array(try XCTUnwrap(original.formatting.textRuns).prefix(2)))
            XCTAssertEqual(runs.last?.character, original.formatting.textRuns?.last?.character)
            let paragraph = try XCTUnwrap(runs.last?.paragraph)
            for (name, expected) in ["SpBefore": 0.2, "SpAfter": 0.3, "SpLine": 0.4, "IndLeft": 0.5, "IndFirst": -0.125, "IndRight": 0.75] {
                let cell = try XCTUnwrap(paragraph.cells[name])
                XCTAssertEqual(try XCTUnwrap(Double(cell.value)), expected, accuracy: 1e-12, name)
                XCTAssertEqual(cell.formula, "", name)
                XCTAssertEqual(cell.unit, original.formatting.textRuns?.last?.paragraph.cells[name]?.unit, name)
            }
            XCTAssertEqual(paragraph.cells["Bullet"], original.formatting.textRuns?.last?.paragraph.cells["Bullet"])
            XCTAssertEqual(paragraph.cells["CustomParagraphMetadata"], original.formatting.textRuns?.last?.paragraph.cells["CustomParagraphMetadata"])
        }
    }

    func testUnchangedScaledParagraphKeepsRelativeLineFormulaUnitsAndAbsentDefaults() throws {
        try onMain {
            let original = node()
            let text = NSMutableAttributedString(attributedString: ShapeRichText.attributed(original, scale: 0.65))
            let range = (text.string as NSString).range(of: "Second paragraph")
            text.addAttribute(.foregroundColor, value: NSColor.red, range: range)
            let result = ShapeRichText.applying(text, to: original, scale: 0.65)
            XCTAssertEqual(result.formatting.textRuns?.map(\.paragraph), original.formatting.textRuns?.map(\.paragraph))
            let empty = ShapeParagraphStyle(alignment: .left)
            XCTAssertEqual(empty.applying(empty.native(fontSize: 14, scale: 2), fontSize: 14, scale: 2), empty)
        }
    }

    func testFirstLineIndentIsRelativeToParagraphLeftIndent() throws {
        let paragraph = try XCTUnwrap(node().formatting.textRuns?.first?.paragraph)
        let native = paragraph.native(fontSize: 14, scale: 2)
        XCTAssertEqual(native.headIndent, 0.25 * 72 * 2, accuracy: 1e-10)
        XCTAssertEqual(native.firstLineHeadIndent, (0.25 + 0.1) * 72 * 2, accuracy: 1e-10)
        let changed = try XCTUnwrap(native.mutableCopy() as? NSMutableParagraphStyle)
        changed.headIndent = 0.5 * 72 * 2
        let extracted = paragraph.applying(changed, fontSize: 14, scale: 2)
        XCTAssertEqual(try XCTUnwrap(Double(try XCTUnwrap(extracted.cells["IndFirst"]?.value))), -0.15, accuracy: 1e-10)
        XCTAssertEqual(extracted.native(fontSize: 14, scale: 2).firstLineHeadIndent, native.firstLineHeadIndent, accuracy: 1e-10)
    }

    func testUnsupportedNativeParagraphPropertiesDoNotRewriteSourceCells() throws {
        try onMain {
            let original = node()
            let text = try editingSecondParagraph(original) { style in
                style.minimumLineHeight = 18
                style.maximumLineHeight = 0
                style.lineSpacing = 7
                style.tabStops = [NSTextTab(textAlignment: .left, location: 30, options: [:])]
            }
            let result = ShapeRichText.applying(text, to: original)
            XCTAssertEqual(result.formatting.textRuns?.map(\.paragraph), original.formatting.textRuns?.map(\.paragraph))
        }
    }

    func testParagraphEditReopensFromPublicCellsAndKeepsSharedOriginalRow() throws {
        try onMain {
            var (diagram, originalParts) = try imported()
            let original = try XCTUnwrap(diagram.page.nodes.first)
            let text = try editingSecondParagraph(original) { $0.paragraphSpacing = 36 }
            diagram.page.nodes[0] = ShapeRichText.applying(text, to: original)
            let output = file()
            try VisioFormat.write(diagram, to: output)
            let parts = try publicParts(output)
            try VisioPackage.write(parts, to: output)

            func rows(_ parts: [String: Data]) throws -> [XMLElement] {
                let document = try VisioXML.document(try XCTUnwrap(parts["visio/pages/page1.xml"]))
                let shape = try XCTUnwrap(document.rootElement()?.firstLocal("Shapes")?.allShapes.first)
                return try XCTUnwrap(shape.elementsLocal("Section").first { $0.attr("N") == "Paragraph" }).elementsLocal("Row")
            }
            let originalRow = try XCTUnwrap(try rows(originalParts).first { $0.attr("IX") == "4" })
            let outputRows = try rows(parts)
            XCTAssertEqual(outputRows.first { $0.attr("IX") == "4" }?.xmlString, originalRow.xmlString)
            let changedRow = try XCTUnwrap(outputRows.first { $0.attr("IX") != "4" })
            XCTAssertEqual(VisioXML.number(changedRow, "SpAfter"), 0.5, accuracy: 1e-12)
            XCTAssertNil(changedRow.elementsLocal("Cell").first { $0.attr("N") == "SpAfter" }?.attr("F"))
            XCTAssertEqual(changedRow.elementsLocal("Cell").first { $0.attr("N") == "SpAfter" }?.attr("U"), "IN")
            XCTAssertEqual(changedRow.elementsLocal("Cell").first { $0.attr("N") == "SpBefore" }?.attr("F"), "0.1 in")
            XCTAssertEqual(VisioXML.value(changedRow, "CustomParagraphMetadata"), "retained")

            let reopened = try VisioFormat.read(from: output).diagram
            let runs = try XCTUnwrap(reopened.page.nodes.first?.formatting.textRuns)
            XCTAssertEqual(reopened.page.nodes.first?.text, original.text)
            XCTAssertEqual(try XCTUnwrap(Double(try XCTUnwrap(runs.first?.paragraph.cells["SpAfter"]?.value))), 0.2, accuracy: 1e-12)
            XCTAssertEqual(try XCTUnwrap(Double(try XCTUnwrap(runs.last?.paragraph.cells["SpAfter"]?.value))), 0.5, accuracy: 1e-12)
            XCTAssertTrue(runs.contains { $0.text.contains("bold") && $0.character.bold })
            let secondOutput = file()
            try VisioFormat.write(reopened, to: secondOutput)
            XCTAssertEqual(try publicParts(secondOutput), parts)
        }
    }

    func testNativeParagraphCommitUndoRedoAndCancelRetainTextState() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            document.diagram.page.nodes = [node()]
            document.makeWindowControllers()
            document.undoManager?.groupsByEvent = false
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            defer {
                editor.canvas.finishEditing(commit: false)
                editor.window?.orderOut(nil)
                editor.window?.delegate = nil
                document.removeWindowController(editor)
                editor.close()
            }
            let original = document.diagram
            let id = try XCTUnwrap(original.page.nodes.first?.id)
            editor.canvas.select([id])
            editor.canvas.beginEditing(id)
            let field = try XCTUnwrap(editor.canvas.subviews.compactMap { $0 as? InlineTextView }.first)
            // The window's fitted zoom also scales the inline paragraph style.
            // Supply editor-space points, then assert the same paper lengths.
            let scale = editor.canvas.zoom
            let changed = try editingSecondParagraph(try XCTUnwrap(original.page.nodes.first), scale: scale) { $0.headIndent = 36 * scale }
            field.undoManager?.beginUndoGrouping()
            field.applyFormatting(changed)
            field.undoManager?.endUndoGrouping()
            field.undoManager?.undo()
            let restoredStyle = try XCTUnwrap(field.textStorage?.attribute(.paragraphStyle, at: field.string.utf16.count - 1, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(restoredStyle.headIndent / scale, 18, accuracy: 1e-12)
            field.undoManager?.redo()
            document.undoManager?.beginUndoGrouping()
            editor.canvas.finishEditing(commit: true)
            document.undoManager?.endUndoGrouping()
            let committed = document.diagram
            XCTAssertEqual(committed.page.nodes.first?.formatting.textRuns?.last?.paragraph.cells["IndLeft"]?.value, "0.5")
            XCTAssertEqual(committed.page.nodes.first?.text, original.page.nodes.first?.text)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, original)
            document.undoManager?.redo()
            XCTAssertEqual(document.diagram, committed)
            editor.canvas.beginEditing(id)
            let cancelledField = try XCTUnwrap(editor.canvas.subviews.compactMap { $0 as? InlineTextView }.first)
            let cancelScale = editor.canvas.zoom
            cancelledField.applyFormatting(try editingSecondParagraph(try XCTUnwrap(committed.page.nodes.first), scale: cancelScale) { $0.headIndent = 54 * cancelScale })
            editor.canvas.finishEditing(commit: false)
            XCTAssertEqual(document.diagram, committed)
        }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
