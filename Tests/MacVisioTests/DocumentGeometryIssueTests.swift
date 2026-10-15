import XCTest
@testable import MacVisio

final class DocumentGeometryIssueTests:XCTestCase {
    func testPageGeometryIssuesSurviveOtherPageEditsAndUndoRedo() {
        var first = DiagramPage(name:"First")
        first.nodes = [DiagramNode(x:100,y:100,text:"Initial")]
        var second = DiagramPage(name:"Second")
        var formulaNode = DiagramNode(x:200,y:160,text:"Unsupported formula")
        formulaNode.formatting.sheet["User.Bad"] = ShapeSheetCell(value:"7",formula:"UnsupportedFunction(0)")
        second.nodes = [formulaNode]
        var model = Diagram();model.pages = [first,second];model.activePageID = first.id

        let document = MacVisioDocument();document.diagram = model
        document.undoManager?.groupsByEvent = false

        func replace(_ mutate:(inout Diagram)->Void) {
            var next = document.diagram;mutate(&next)
            document.undoManager?.beginUndoGrouping()
            document.replace(with:next,action:"Edit test drawing")
            document.undoManager?.endUndoGrouping()
        }
        func hasUnsupportedFunctionIssue() -> Bool {
            document.calculationIssues.contains{$0.localizedCaseInsensitiveContains("UnsupportedFunction")}
        }

        // Editing the bad formula's own page discovers and records its warning.
        replace { $0.pages[1].nodes[0].formatting.sheet["User.Bad"]?.formula = "UnsupportedFunction()" }
        XCTAssertTrue(hasUnsupportedFunctionIssue(),document.calculationIssues.joined(separator:"\n"))

        // A later edit on page one may skip page two's expensive geometry pass,
        // but its retained warning must remain visible through undo and redo.
        replace { $0.pages[0].nodes[0].text = "First edit" }
        XCTAssertTrue(hasUnsupportedFunctionIssue(),document.calculationIssues.joined(separator:"\n"))
        document.undoManager?.undo()
        XCTAssertTrue(hasUnsupportedFunctionIssue(),"Undo should restore the matching per-page warning cache.")
        document.undoManager?.redo()
        XCTAssertTrue(hasUnsupportedFunctionIssue(),"Redo should restore the matching per-page warning cache.")

        // Fixing the formula recalculates its own page and clears the warning.
        replace { $0.pages[1].nodes[0].formatting.sheet["User.Bad"]?.formula = "2+3" }
        XCTAssertFalse(hasUnsupportedFunctionIssue(),document.calculationIssues.joined(separator:"\n"))
        document.undoManager?.undo()
        XCTAssertTrue(hasUnsupportedFunctionIssue(),"Undoing the formula fix should restore its warning and cache.")
        document.undoManager?.redo()
        XCTAssertFalse(hasUnsupportedFunctionIssue(),"Redoing the formula fix should clear the warning again.")
    }
}
