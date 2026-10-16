import XCTest
@testable import MacVisio

final class UndoPayloadBudgetTests: XCTestCase {
    func testWarmOrdinaryEditChargesOnlyAffectedObjectAndEvictsBeforeBudgetOverrun() {
        let budget = UndoPayloadBudget(maximumCharge: 500_000)
        var original = Diagram()
        original.page.nodes = (0..<100).map { DiagramNode(x:Double($0)*10,y:100,text:String($0)) }
        let firstID = UUID()
        var first = original;first.page.nodes[0].text = "first"
        let initial = budget.prepare(previous:original,previousStateID:firstID,next:first,
                                     changes:.between(original,first),historyIsEmpty:true)
        XCTAssertFalse(initial.oversizedSingleAction)
        let warmID = UUID();budget.didInstall(stateID:warmID)
        var second = first;second.page.nodes[99].text = "second"
        let next = budget.prepare(previous:first,previousStateID:warmID,next:second,
                                  changes:.between(first,second),historyIsEmpty:false)
        XCTAssertEqual(budget.lastEncodedObjectCount,1,"A warm single-object edit must not serialize every undoable shape")
        XCTAssertEqual(budget.lastVisitedObjects,1,"A warm single-object edit must use the retained index")
        if next.discardOldHistory { XCTAssertEqual(next.retainedCharge,next.actionCharge) }
        XCTAssertLessThanOrEqual(next.retainedCharge,budget.maximumCharge)
    }

    func testOneOversizedActionIsExplicitAndPriorHistoryIsDiscardedAtNextBoundary() {
        let budget = UndoPayloadBudget(maximumCharge: 64)
        var original = Diagram();original.page.nodes = [DiagramNode(text:"previous")]
        var next = original;next.page.nodes[0].text = "next"
        let first = budget.prepare(previous:original,previousStateID:UUID(),next:next,
                                   changes:.between(original,next),historyIsEmpty:true)
        XCTAssertTrue(first.oversizedSingleAction,"The current action stays undoable and must report its exception")
        let nextID = UUID();budget.didInstall(stateID:nextID)
        var final = next;final.page.nodes[0].text = "final"
        let second = budget.prepare(previous:next,previousStateID:nextID,next:final,
                                    changes:.between(next,final),historyIsEmpty:false)
        XCTAssertTrue(second.discardOldHistory)
        XCTAssertEqual(second.retainedCharge,second.actionCharge)
        XCTAssertEqual(budget.historyDiscards,1)
    }

    func testInsertedDeletedPagesAndChangedSourceAreIncludedInRetentionCharge() {
        let budget = UndoPayloadBudget(maximumCharge: 64 * 1024 * 1024)
        let original = Diagram()
        var inserted = original
        var page = DiagramPage();page.nodes = [DiagramNode(text:String(repeating:"large",count:1000))]
        inserted.pages.append(page)
        let first = budget.prepare(previous:original,previousStateID:UUID(),next:inserted,
                                   changes:.between(original,inserted),historyIsEmpty:true)
        let id = UUID();budget.didInstall(stateID:id)
        var withSource = inserted
        withSource.visioArchive = VisioDocumentArchive(parts:["opaque":Data(repeating:1,count:1024*1024)],pagesPart:"pages.xml",pages:[])
        let second = budget.prepare(previous:inserted,previousStateID:id,next:withSource,
                                    changes:.between(inserted,withSource),historyIsEmpty:false)
        XCTAssertGreaterThanOrEqual(second.actionCharge,first.actionCharge+4*1024*1024)
        let secondID = UUID();budget.didInstall(stateID:secondID)
        var removed = withSource;removed.pages.removeLast()
        let third = budget.prepare(previous:withSource,previousStateID:secondID,next:removed,
                                   changes:.between(withSource,removed),historyIsEmpty:false)
        XCTAssertGreaterThanOrEqual(third.actionCharge,second.actionCharge,"Undo must cover the larger side of a deletion")
    }
}
