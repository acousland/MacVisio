import XCTest
@testable import MacVisio

final class DocumentSearchTests: XCTestCase {
    private func model(_ nodes: [DiagramNode]) -> Diagram {
        var diagram = Diagram(); diagram.page.nodes = nodes; return diagram
    }

    private func run(_ text: String, node: DiagramNode, font: String, index: Int) -> ShapeTextRun {
        var character = ShapeCharacterStyle(node: node)
        character.fontName = font; character.sourceIndex = index; character.bold = index.isMultiple(of: 2)
        character.cells = ["OpaqueFont": ShapeSheetCell(value: "requested-\(font)", formula: "THEMEVAL(17)")]
        var paragraph = ShapeParagraphStyle(alignment: .right)
        paragraph.sourceIndex = index; paragraph.cells = ["OpaqueParagraph": ShapeSheetCell(value: "keep", formula: "GUARD(1)")]
        return ShapeTextRun(text: text, character: character, paragraph: paragraph)
    }

    func testSearchAcrossPagesTextShapesDataAndConnectorsHasStableIdentityAndOrder() throws {
        var first = DiagramNode(text: "Token token")
        first.kind = .diamond; first.formatting.sourceShapeID = "42"
        first.formatting.data = [ShapeDataProperty(key: "token-key", label: "Token label", value: "Token value")]
        var diagram = model([first])
        let edge = DiagramEdge(source: first.id, target: first.id, label: "Token edge")
        diagram.page.edges = [edge]
        var second = DiagramPage(); second.name = "Other"; second.isBackground = true
        let other = DiagramNode(text: "Token on background"); second.nodes = [other]; diagram.pages.append(second)
        let query = DocumentSearch.Query(text: "token")
        let matches = DocumentSearch.find(query, in: diagram)
        XCTAssertEqual(matches.map(\.objectID), [first.id, first.id, first.id, first.id, first.id, edge.id, other.id])
        XCTAssertEqual(matches.map(\.surface), [.nodeText, .nodeText, .dataKey(index: 0, key: "token-key"),
                                               .dataLabel(index: 0, key: "token-key"), .dataValue(index: 0, key: "token-key"), .edgeLabel, .nodeText])
        XCTAssertEqual(matches.last?.pageID, second.id)
        XCTAssertEqual(matches.map(\.id), DocumentSearch.find(query, in: diagram).map(\.id))
        XCTAssertEqual(Set(matches.map(\.id)).count, matches.count)
        XCTAssertEqual(DocumentSearch.find(.init(text: "Decision", domains: [.shape]), in: diagram).first?.surface, .shapeKind)
        XCTAssertTrue(DocumentSearch.find(.init(text: "42", domains: [.shape]), in: diagram).contains { $0.surface == .sourceShapeID })
        XCTAssertEqual(DocumentSearch.find(.init(text: first.id.uuidString, domains: [.shape]), in: diagram).first?.objectID, first.id)
        XCTAssertTrue(DocumentSearch.find(.init(text: ""), in: diagram).isEmpty)
        XCTAssertTrue(DocumentSearch.find(.init(text: "Token", domains: []), in: diagram).isEmpty)
        XCTAssertEqual(DocumentSearch.find(.init(text: "Token", caseSensitive: true, domains: [.text]), in: diagram).count, 3)
    }

    func testUTF16SearchAndReplacementCoverRTLCombiningAndEmoji() throws {
        let text = "🙂 العربية cafe\u{301} 👩🏽‍💻 🇦🇺 שלום"
        let node = DiagramNode(text: text), diagram = model([node])
        for needle in ["العربية", "café", "👩🏽‍💻", "🇦🇺", "שלום"] {
            let match = try XCTUnwrap(DocumentSearch.find(.init(text: needle, domains: [.text]), in: diagram).first)
            XCTAssertEqual(match.range, (text as NSString).range(of: needle))
            let changed = try DocumentSearch.replacing(match, with: "✅", in: diagram)
            XCTAssertTrue(changed.page.nodes[0].text.utf8.elementsEqual((text as NSString).replacingCharacters(in: match.range, with: "✅").utf8))
        }
        for partial in ["👩", "🏽", "💻", "🇦", "e", "\u{301}"] {
            XCTAssertTrue(DocumentSearch.find(.init(text: partial, domains: [.text]), in: diagram).isEmpty, partial)
        }
    }

    func testResultBudgetReportsTruncationAndExactLimitWithoutSilentIncompleteResults() {
        let first = DiagramNode(text: String(repeating: "🙂e ", count: 500)), second = DiagramNode(text: "e")
        let diagram = model([first, second])
        let capped = DocumentSearch.find(.init(text: "e", domains: [.text], maxResults: 3), in: diagram)
        XCTAssertEqual(capped.count, 3); XCTAssertTrue(capped.isTruncated); XCTAssertEqual(capped.completion, .truncated)
        XCTAssertEqual(capped.map(\.range), [NSRange(location: 2, length: 1), NSRange(location: 6, length: 1), NSRange(location: 10, length: 1)])
        XCTAssertTrue(capped.allSatisfy { $0.objectID == first.id })
        let exact = DocumentSearch.find(.init(text: "e", domains: [.text], maxResults: 501), in: diagram)
        XCTAssertEqual(exact.count, 501); XCTAssertFalse(exact.isTruncated); XCTAssertEqual(exact.completion, .complete)
        let acrossObjects = DocumentSearch.find(.init(text: "e", domains: [.text], maxResults: 500), in: diagram)
        XCTAssertEqual(acrossObjects.count, 500); XCTAssertTrue(acrossObjects.isTruncated)
        let noMatches = DocumentSearch.find(.init(text: "absent", maxResults: 1), in: diagram)
        XCTAssertTrue(noMatches.isEmpty); XCTAssertEqual(noMatches.completion, .complete)
        for budget in [Int.min, -1, 0, 100_001, Int.max] {
            let invalid = DocumentSearch.find(.init(text: "e", maxResults: budget), in: diagram)
            XCTAssertTrue(invalid.isEmpty); XCTAssertFalse(invalid.isTruncated); XCTAssertEqual(invalid.completion, .invalidBudget)
        }
    }

    func testSelectedRepeatedTextUsesSelectedRunsAndPreservesEveryUnselectedStyleAndField() throws {
        var node = DiagramNode(text: "same same 🙂 END")
        let a = run("same ", node: node, font: "Requested A", index: 3)
        let b = run("same", node: node, font: "Missing Requested B", index: 9)
        let c = run(" 🙂 ", node: node, font: "Requested C", index: 12)
        var field = run("END", node: node, font: "Requested Field", index: 27)
        field.fieldIndex = 4; field.fieldToken = UUID()
        let empty = ShapeTextRun(text: "", character: field.character, paragraph: field.paragraph, fieldIndex: 5, fieldToken: UUID())
        let fields = [ShapeTextField(index: 4, cells: ["Value": ShapeSheetCell(value: "END", formula: "PAGENAME()")], cached: "END"),
                      ShapeTextField(index: 5, cells: ["Value": ShapeSheetCell(value: "", formula: "Prop.Empty")], cached: "")]
        node.formatting.textFields = fields; node.formatting.textRuns = [a, b, c, field, empty]
        node.formatting.sheet["User.Opaque"] = ShapeSheetCell(value: "source", formula: "GUARD(UNSUPPORTED())")
        let diagram = model([node]), matches = DocumentSearch.find(.init(text: "same", domains: [.text]), in: diagram)
        let changed = try DocumentSearch.replacing(matches[1], with: "replacement", in: diagram)
        let output = try XCTUnwrap(changed.page.nodes[0].formatting.textRuns)
        XCTAssertEqual(changed.page.nodes[0].text, "same replacement 🙂 END")
        XCTAssertEqual(output[0], a)
        var inserted = b; inserted.text = "replacement"
        XCTAssertEqual(output, [a, inserted, c, field, empty])
        XCTAssertEqual(changed.page.nodes[0].formatting.textFields, fields)
        XCTAssertEqual(changed.page.nodes[0].formatting.sheet, node.formatting.sheet)
        XCTAssertEqual(diagram.page.nodes[0], node)
    }

    func testCrossRunReplacementKeepsUnselectedPrefixSuffixAndFirstSelectedStyle() throws {
        var node = DiagramNode(text: "abcdef")
        let a = run("abc", node: node, font: "A", index: 1), b = run("def", node: node, font: "B", index: 2)
        node.formatting.textRuns = [a, b]
        let diagram = model([node]), match = try XCTUnwrap(DocumentSearch.find(.init(text: "bcde", domains: [.text]), in: diagram).first)
        let changed = try DocumentSearch.replacing(match, with: "X", in: diagram)
        var prefix = a, insert = a, suffix = b
        prefix.text = "a"; insert.text = "X"; suffix.text = "f"
        XCTAssertEqual(changed.page.nodes[0].formatting.textRuns, [prefix, insert, suffix])
        let deleted = try DocumentSearch.replacing(match, with: "", in: diagram)
        XCTAssertEqual(deleted.page.nodes[0].text, "af")
        XCTAssertEqual(deleted.page.nodes[0].formatting.textRuns, [prefix, suffix])
        XCTAssertEqual(try DocumentSearch.replacing(match, with: "bcde", in: diagram), diagram)
    }

    func testFieldsCannotBeFlattenedAndEmptyFieldCannotBeCrossed() throws {
        var node = DiagramNode(text: "leftFIELDright")
        var field = run("FIELD", node: node, font: "Missing", index: 2)
        field.fieldIndex = 7; field.fieldToken = UUID()
        node.formatting.textRuns = [run("left", node: node, font: "A", index: 0), field, run("right", node: node, font: "B", index: 1)]
        node.formatting.textFields = [ShapeTextField(index: 7, cells: [:], cached: "FIELD")]
        for needle in ["FIELD", "tF", "Dr"] {
            let diagram = model([node]), match = try XCTUnwrap(DocumentSearch.find(.init(text: needle, domains: [.text]), in: diagram).first)
            XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: diagram), .fieldContent)
            XCTAssertThrowsError(try DocumentSearch.replacing(match, with: "x", in: diagram))
        }
        field.text = ""; node.text = "leftright"
        node.formatting.textRuns = [run("left", node: node, font: "A", index: 0), field, run("right", node: node, font: "B", index: 1)]
        let diagram = model([node]), crossing = try XCTUnwrap(DocumentSearch.find(.init(text: "tr", domains: [.text]), in: diagram).first)
        XCTAssertEqual(DocumentSearch.replacementBlock(for: crossing, in: diagram), .fieldContent)
        let adjacent = try XCTUnwrap(DocumentSearch.find(.init(text: "left", domains: [.text]), in: diagram).first)
        let changed = try DocumentSearch.replacing(adjacent, with: "L", in: diagram)
        XCTAssertEqual(changed.page.nodes[0].formatting.textRuns?.filter { $0.fieldIndex != nil }, [field])
    }

    func testStaleSnapshotsUseExactBytesAndRangesRejectPartialCharactersAndOverflow() throws {
        let node = DiagramNode(text: "é 🙂"), diagram = model([node])
        let match = try XCTUnwrap(DocumentSearch.find(.init(text: "é", domains: [.text]), in: diagram).first)
        var stale = diagram; stale.page.nodes[0].text = "e\u{301} 🙂"
        XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: stale), .staleResult)
        for range in [NSRange(location: 3, length: 1), NSRange(location: 2, length: 1), NSRange(location: 0, length: Int.max),
                      NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1), NSRange(location: 0, length: 0)] {
            var invalid = match; invalid.range = range
            XCTAssertEqual(DocumentSearch.replacementBlock(for: invalid, in: diagram), .invalidRange)
        }
        let combining = try XCTUnwrap(DocumentSearch.find(.init(text: "é", domains: [.text]), in: stale).first)
        var invalid = combining; invalid.range = NSRange(location: 0, length: 1)
        XCTAssertEqual(DocumentSearch.replacementBlock(for: invalid, in: stale), .invalidRange)
    }

    func testReplacementRevalidatesCurrentNodeLayerGroupAndTextProtection() throws {
        let node = DiagramNode(text: "find"), original = model([node])
        let match = try XCTUnwrap(DocumentSearch.find(.init(text: "find", domains: [.text]), in: original).first)
        XCTAssertNil(DocumentSearch.replacementBlock(for: match, in: original))
        var diagram = original; diagram.page.nodes[0].locked = true
        XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: diagram), .locked)
        diagram = original; diagram.page.layers = [DiagramLayer(name: "Default", locked: true)]
        XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: diagram), .locked)
        var group = DiagramNode(text: "group"); group.formatting.isGroup = true; group.locked = true
        diagram = original; diagram.page.nodes[0].parentID = group.id; diagram.page.nodes.append(group)
        XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: diagram), .locked)
        group.locked = false; group.formatting.sheet["lOcKtExTeDiT"] = ShapeSheetCell(value: "1")
        diagram.page.nodes[1] = group
        XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: diagram), .textProtected)
        diagram = original; diagram.page.nodes[0].formatting.sheet["LockTextEdit"] = ShapeSheetCell(value: "0", formula: "User.Locked")
        XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: diagram), .unresolvedTextProtection)
        diagram.page.nodes[0].formatting.sheet["LockTextEdit"] = ShapeSheetCell(value: "FALSE", formula: "FALSE()")
        XCTAssertNil(DocumentSearch.replacementBlock(for: match, in: diagram))
    }

    func testDataAndShapeResultsAreNavigationOnlyAndMissingOrDuplicateTargetsReject() throws {
        var node = DiagramNode(text: "find")
        node.formatting.data = [ShapeDataProperty(key: "find", label: "find", value: "find")]
        var diagram = model([node])
        let data = DocumentSearch.find(.init(text: "find", domains: [.data]), in: diagram)
        XCTAssertEqual(data.count, 3)
        for match in data { XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: diagram), .readOnlySurface) }
        let shape = try XCTUnwrap(DocumentSearch.find(.init(text: "Process", domains: [.shape]), in: diagram).first)
        XCTAssertEqual(DocumentSearch.replacementBlock(for: shape, in: diagram), .readOnlySurface)
        let text = try XCTUnwrap(DocumentSearch.find(.init(text: "find", domains: [.text]), in: diagram).first)
        diagram.page.nodes = []
        XCTAssertEqual(DocumentSearch.replacementBlock(for: text, in: diagram), .missingTarget)
        diagram = model([node, node]); diagram.pages[0].id = text.pageID
        XCTAssertEqual(DocumentSearch.replacementBlock(for: text, in: diagram), .ambiguousTarget)
        diagram.pages = [diagram.page, diagram.page]
        XCTAssertEqual(DocumentSearch.replacementBlock(for: text, in: diagram), .ambiguousTarget)
    }

    func testConnectorLabelsReplaceOnCorrectPageAndRespectLayerLock() throws {
        let node = DiagramNode(text: "find"), edge = DiagramEdge(source: node.id, target: node.id, label: "find")
        var diagram = model([node]); diagram.page.edges = [edge]
        let match = try XCTUnwrap(DocumentSearch.find(.init(text: "find", domains: [.text]), in: diagram).last)
        let changed = try DocumentSearch.replacing(match, with: "edge", in: diagram)
        XCTAssertEqual(changed.page.edges[0].label, "edge"); XCTAssertEqual(changed.page.nodes[0], node)
        diagram.page.edges[0].layer = "Locked"; diagram.page.layers = [DiagramLayer(name: "Locked", locked: true)]
        XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: diagram), .locked)
    }

    func testMalformedRunMappingAndUnmappedFieldsRejectRatherThanDiscardMetadata() throws {
        var node = DiagramNode(text: "find")
        node.formatting.textRuns = [run("other", node: node, font: "Missing", index: 7)]
        var diagram = model([node])
        let match = try XCTUnwrap(DocumentSearch.find(.init(text: "find", domains: [.text]), in: diagram).first)
        XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: diagram), .invalidRichText)
        diagram.page.nodes[0].formatting.textRuns = nil
        diagram.page.nodes[0].formatting.textFields = [ShapeTextField(index: 0, cells: [:])]
        XCTAssertEqual(DocumentSearch.replacementBlock(for: match, in: diagram), .unmappedTextFields)
    }
}
