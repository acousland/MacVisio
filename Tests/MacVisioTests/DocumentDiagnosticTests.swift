import Foundation
import XCTest
@testable import MacVisio

final class DocumentDiagnosticTests: XCTestCase {
    func testEqualMessagesRetainDistinctObjectAndCellProvenance() throws {
        let page = UUID(), first = UUID(), second = UUID()
        let source = DocumentDiagnostic.Source(part: "visio/pages/page1.xml", visioID: "17", cell: "Width", feature: "unsupported-formula")
        let a = DocumentDiagnostic(code: "calculation.unsupported", origin: .calculation, severity: .warning,
                                   dimension: .behavior, target: .shape(page: page, shape: first), source: source,
                                   displayState: .cached, message: "Cached value retained", inputKey: "committed-input-A",
                                   requestedActions: [.revealTarget, .inspectCell])
        var b = a
        b.target = .shape(page: page, shape: second); b.source.visioID = "18"
        var otherCell = a; otherCell.source.cell = "Height"
        XCTAssertEqual(Set([a.id, b.id, otherCell.id]).count, 3)
        let decoded = try JSONDecoder().decode([DocumentDiagnostic].self, from: JSONEncoder().encode([a, b, otherCell]))
        XCTAssertEqual(decoded, [a, b, otherCell])
        XCTAssertEqual(decoded[0].source.cell, "Width")
        XCTAssertEqual(decoded[1].source.visioID, "18")
        XCTAssertEqual(decoded[0].displayState, .cached)
        XCTAssertEqual(decoded[0].inputKey, "committed-input-A")
    }

    func testPresentationChangesKeepIssueIdentityButSourceFeaturesDoNotCollapse() {
        let page = UUID(), shape = UUID()
        let issue = DocumentDiagnostic(code: "render.unsupported", origin: .importer, severity: .warning,
                                       dimension: .rendering, target: .shape(page: page, shape: shape),
                                       displayState: .cached, message: "Original wording")
        var updated = issue
        updated.message = "Localized wording"; updated.severity = .error; updated.displayState = .stale
        updated.inputKey = "new-input"
        XCTAssertEqual(updated.id, issue.id)
        updated.source.feature = "theme-effect"
        XCTAssertNotEqual(updated.id, issue.id)
    }

    func testDocumentNotesNeverInventNavigationTargetsAndHarmlessInformationStaysQuiet() {
        var note = DocumentDiagnostic.legacyImportNote("General source note", code: "import.general")
        note.requestedActions = [.viewDetails, .revealTarget, .inspectCell, .reviewPolicy, .viewDetails]
        XCTAssertEqual(note.target, .document)
        XCTAssertNil(note.target.pageID); XCTAssertNil(note.target.objectID)
        XCTAssertEqual(note.actions, [.viewDetails, .reviewPolicy])
        XCTAssertEqual(note.displayState, .notApplicable)
        note.severity = .information; note.dimension = .preservation
        XCTAssertFalse(note.isMaterial)
    }

    func testPageAndConnectorActionsKeepExactTargetsAndExplicitCacheState() {
        let page = UUID(), edge = UUID()
        var issue = DocumentDiagnostic(code: "connector.route", origin: .calculation, severity: .error,
                                       dimension: .rendering, target: .connector(page: page, connector: edge),
                                       displayState: .unavailable, message: "No evaluated route",
                                       requestedActions: [.revealTarget, .inspectCell, .saveCopy])
        XCTAssertEqual(issue.target.pageID, page); XCTAssertEqual(issue.target.objectID, edge)
        XCTAssertEqual(issue.actions, [.revealTarget, .saveCopy])
        issue.source.cell = "BeginX"; issue.displayState = .stale
        XCTAssertEqual(issue.actions, [.revealTarget, .inspectCell, .saveCopy])
        XCTAssertTrue(issue.isMaterial)
        issue.target = .page(page)
        XCTAssertNil(issue.target.objectID); XCTAssertEqual(issue.target.pageID, page)
    }

    func testDefinitionDiagnosticsRequireStructuredCellAddressesAndRetainScopedIdentity() throws {
        let sheet = UUID()
        let address = DefinitionCellAddress(cell: "Value", section: "User", rowName: "Measure")
        var issue = DocumentDiagnostic(code: "definition.cell", origin: .calculation,
            severity: .warning, dimension: .behavior, target: .definition(sheet: sheet),
            source: .init(part: "visio/masters/master7.xml", visioID: "1", cell: "User.Measure"),
            displayState: .cached, message: "Unresolved cell",
            requestedActions: [.revealTarget, .inspectCell])
        XCTAssertNil(issue.target.pageID)
        XCTAssertEqual(issue.target.definitionSheetID, sheet)
        XCTAssertEqual(issue.actions, [.revealTarget])
        issue.source.definitionCell = address
        XCTAssertEqual(issue.actions, [.revealTarget, .inspectCell])
        var sameLabelDifferentRow = issue
        sameLabelDifferentRow.source.definitionCell?.rowIndex = "3"
        var sameCellDifferentSheet = issue
        sameCellDifferentSheet.target = .definition(sheet: UUID())
        XCTAssertEqual(Set([issue.id, sameLabelDifferentRow.id, sameCellDifferentSheet.id]).count, 3)
        XCTAssertEqual(try JSONDecoder().decode(DocumentDiagnostic.self,
            from: JSONEncoder().encode(issue)), issue)
    }
}
