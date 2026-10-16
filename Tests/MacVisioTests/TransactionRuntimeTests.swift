import AppKit
import XCTest
@testable import MacVisio

final class TransactionRuntimeTests: XCTestCase {
    func testPropertyTransactionUpdatesOneIndexAndRetainsOtherPage() throws {
        let document = MacVisioDocument()
        document.undoManager?.groupsByEvent = false
        document.diagram.page.nodes = (0..<1000).map { DiagramNode(x: Double($0)*200, y: 50) }
        document.diagram.pages.append(DiagramPage(name: "Other"))
        let first = document.runtime()
        let otherID = document.diagram.pages[1].id
        let other = document.runtime(for: otherID)
        var next = document.diagram
        next.page.nodes[100].fill = "#FF0000"
        let id = next.page.nodes[100].id
        document.undoManager?.beginUndoGrouping()
        document.replace(with: next, action: "Color")
        document.undoManager?.endUndoGrouping()
        XCTAssertTrue(document.runtime() === first)
        XCTAssertTrue(document.runtime(for: otherID) === other)
        XCTAssertEqual(document.lastCommittedChange?.pages[next.page.id]?.changedNodeIDs, [id])
        XCTAssertEqual(document.lastRuntimeWork[next.page.id]?.nodeVisits, 1)
        XCTAssertEqual(document.lastRuntimeWork[next.page.id]?.spatialUpdates, 1)
        document.undoManager?.undo()
        XCTAssertEqual(first.nodesByID[id]?.fill, "#E8F0FE")
    }

    func testPageActivationPreservesSavedIdentityAndIndexes() throws {
        let document = MacVisioDocument()
        document.diagram.pages.append(DiagramPage(name: "Other"))
        let firstID = document.diagram.page.id
        let runtime = document.runtime()
        let state = document.stateID, revision = document.revision
        document.activatePage(document.diagram.pages[1].id)
        XCTAssertEqual(document.stateID, state)
        XCTAssertEqual(document.revision, revision)
        document.activatePage(firstID)
        XCTAssertTrue(document.runtime() === runtime)
        XCTAssertNil(document.lastCommittedChange)
    }
}
