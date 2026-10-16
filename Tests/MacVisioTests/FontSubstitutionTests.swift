import XCTest
@testable import MacVisio

final class FontSubstitutionTests: XCTestCase {
    func testExactAndCaseInsensitiveInstalledNamesPreserveRequestedSpelling() {
        let catalog = FontSubstitution.Catalog(installedNames: ["Arial", "Courier New"])
        let exact = FontSubstitution.resolve("Courier New", using: catalog)
        XCTAssertEqual(exact.requestedName, "Courier New"); XCTAssertEqual(exact.renderingName, "Courier New")
        XCTAssertEqual(exact.reason, .installed); XCTAssertFalse(exact.isSubstituted)
        let folded = FontSubstitution.resolve("cOuRiEr NeW", using: catalog)
        XCTAssertEqual(folded.requestedName, "cOuRiEr NeW"); XCTAssertEqual(folded.renderingName, "Courier New")
        XCTAssertEqual(folded.reason, .installed); XCTAssertFalse(folded.isSubstituted)
    }

    func testExplicitAliasAndFallbackPolicyFollowPolicyOrderNotCatalogOrder() {
        var catalog = FontSubstitution.Catalog(installedNames: ["Helvetica", "Replacement B", "Replacement A", "Arial"])
        catalog.aliases = ["Missing Original": ["Unavailable", "Replacement B", "Replacement A"]]
        let alias = FontSubstitution.resolve("Missing Original", using: catalog)
        XCTAssertEqual(alias.renderingName, "Replacement B"); XCTAssertEqual(alias.reason, .alias)
        XCTAssertEqual(alias.requestedName, "Missing Original"); XCTAssertTrue(alias.isSubstituted)
        let fallback = FontSubstitution.resolve("Another missing font", using: catalog)
        XCTAssertEqual(fallback.renderingName, "Arial"); XCTAssertEqual(fallback.reason, .fallback)
        catalog.preferredFallbacks = ["Missing fallback", "Helvetica", "Arial"]
        XCTAssertEqual(FontSubstitution.resolve("Another missing font", using: catalog).renderingName, "Helvetica")
    }

    func testEmptyCatalogUsesSystemSentinelAndDoesNotClaimOriginalSystemIsMissing() {
        let empty = FontSubstitution.Catalog(installedNames: [])
        let missing = FontSubstitution.resolve("Missing Requested", using: empty)
        XCTAssertEqual(missing.renderingName, "System"); XCTAssertEqual(missing.reason, .system)
        XCTAssertTrue(missing.isSubstituted); XCTAssertEqual(missing.requestedName, "Missing Requested")
        let system = FontSubstitution.resolve("System", using: empty)
        XCTAssertEqual(system.reason, .system); XCTAssertFalse(system.isSubstituted)
        var catalog = FontSubstitution.Catalog(installedNames: ["Arial"])
        catalog.preferredFallbacks = ["System", "Arial"]
        XCTAssertEqual(FontSubstitution.resolve("Missing", using: catalog).renderingName, "System")
    }

    func testResolutionIsDeterministicWhenCatalogAndAliasDictionaryOrderingChange() {
        let a = FontSubstitution.Catalog(installedNames: ["arial", "Arial", "Helvetica", "Arial"],
                                         aliases: ["MISSING": ["Helvetica"], "missing": ["Arial"]])
        let b = FontSubstitution.Catalog(installedNames: ["Arial", "Helvetica", "arial"],
                                         aliases: ["missing": ["Arial"], "MISSING": ["Helvetica"]])
        for requested in ["ARIAL", "arial", "Missing", "Unknown"] {
            XCTAssertEqual(FontSubstitution.resolve(requested, using: a), FontSubstitution.resolve(requested, using: b))
        }
        XCTAssertEqual(FontSubstitution.resolve("arial", using: a).renderingName, "arial")
        XCTAssertEqual(FontSubstitution.resolve("ARIAL", using: a).renderingName, "Arial")
        XCTAssertEqual(FontSubstitution.resolve("Missing", using: a).renderingName, "Helvetica")
    }

    func testInventoryRetainsEveryBaseRunAndEmptyFieldUseWithoutChangingMetadata() throws {
        var node = DiagramNode(text: "العربية🙂")
        node.formatting.fontName = "Missing Base"
        var character = ShapeCharacterStyle(node: node)
        character.fontName = "Missing Requested"; character.sourceIndex = 27
        character.cells = ["Font": ShapeSheetCell(value: "83", formula: "THEMEVAL(3)")]
        let paragraph = ShapeParagraphStyle(alignment: .right)
        let run = ShapeTextRun(text: node.text, character: character, paragraph: paragraph)
        let empty = ShapeTextRun(text: "", character: character, paragraph: paragraph, fieldIndex: 4, fieldToken: UUID())
        node.formatting.textRuns = [run, empty]
        node.formatting.textFields = [ShapeTextField(index: 4, cells: ["Value": ShapeSheetCell(value: "", formula: "Prop.Empty")])]
        var diagram = Diagram(); diagram.page.nodes = [node]
        var otherPage = DiagramPage(); otherPage.nodes = [DiagramNode(text: "other")]; diagram.pages.append(otherPage)
        let before = try JSONEncoder().encode(diagram.page.nodes[0])
        let entries = FontSubstitution.inventory(in: diagram, using: .init(installedNames: ["Arial"]))
        XCTAssertEqual(entries.map { $0.resolution.requestedName }, ["Missing Base", "Missing Requested", "System"])
        let missing = try XCTUnwrap(entries.first { $0.resolution.requestedName == "Missing Requested" })
        XCTAssertEqual(missing.uses, [.init(pageID: diagram.page.id, nodeID: node.id, runIndex: 0),
                                      .init(pageID: diagram.page.id, nodeID: node.id, runIndex: 1)])
        XCTAssertEqual(missing.resolution.renderingName, "Arial")
        XCTAssertEqual(diagram.page.nodes[0], node)
        let afterNode = try JSONDecoder().decode(DiagramNode.self, from: before)
        XCTAssertEqual(afterNode.formatting.textRuns, diagram.page.nodes[0].formatting.textRuns)
        XCTAssertEqual(diagram.page.nodes[0].formatting.textRuns?.first?.character.cells["Font"]?.formula, "THEMEVAL(3)")
    }

    func testInventoryKeepsCanonicallyEquivalentRequestedNameBytesDistinct() {
        var first = DiagramNode(text: "first"), second = DiagramNode(text: "second")
        first.formatting.fontName = "Caf\u{e9}"; second.formatting.fontName = "Cafe\u{301}"
        var diagram = Diagram(); diagram.page.nodes = [first, second]
        let entries = FontSubstitution.inventory(in: diagram, using: .init(installedNames: []))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map { Data($0.resolution.requestedName.utf8) },
                       [Data("Cafe\u{301}".utf8), Data("Caf\u{e9}".utf8)])
        let a = FontSubstitution.Catalog(installedNames: ["Caf\u{e9}", "Cafe\u{301}"])
        let b = FontSubstitution.Catalog(installedNames: a.installedNames.reversed())
        for requested in ["Caf\u{e9}", "Cafe\u{301}", "CAFÉ"] {
            let first = FontSubstitution.resolve(requested, using: a)
            let second = FontSubstitution.resolve(requested, using: b)
            XCTAssertTrue(first.renderingName.utf8.elementsEqual(second.renderingName.utf8))
        }
    }
}
