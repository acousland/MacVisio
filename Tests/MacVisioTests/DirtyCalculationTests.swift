import XCTest
@testable import MacVisio

final class DirtyCalculationTests:XCTestCase {
    private func formulaNode(_ x:Double,_ id:String,padding:String) -> DiagramNode {
        var node = DiagramNode(x:x,y:100,text:"Formula shape")
        node.formatting.sourceShapeID = id
        var page = DiagramPage();page.nodes = [node]
        node.formatting.sheet = ShapeSheetEngine.defaults(node,page:page).mapValues{ShapeSheetCell(value:ShapeSheetEngine.format($0))}
        node.formatting.sheet["LocPinX"]?.formula = "Width*0.5"
        node.formatting.sheet["LocPinY"]?.formula = "Height*0.5"
        node.formatting.sheet["User.Padding"] = ShapeSheetCell(value:padding)
        node.formatting.sheet["Width"] = ShapeSheetCell(value:"2",formula:"2 in+User.Padding*2")
        node.formatting.sheet["Height"] = ShapeSheetCell(value:"1",formula:"Sheet.1!Width/2")
        return node
    }

    private func pageNumberNode() -> DiagramNode {
        var node = DiagramNode(text:"1")
        node.formatting.textFields = [ShapeTextField(index:0,cells:["Value":ShapeSheetCell(value:"1",formula:"PAGENUMBER()"),"Type":ShapeSheetCell(value:"0")],cached:"1")]
        node.formatting.textRuns = [ShapeTextRun(text:"1",character:ShapeCharacterStyle(node:node),paragraph:ShapeParagraphStyle(),fieldIndex:0,fieldToken:UUID())]
        return node
    }

    private func makeDiagram() -> Diagram {
        let ids = [UUID(),UUID(),UUID()]
        var pages:[DiagramPage] = []
        for index in ids.indices {
            var page = DiagramPage(id:ids[index],name:"Page \(index+1)")
            var widthNode = formulaNode(100,"1",padding:"0.25")
            var character = ShapeCharacterStyle(node:widthNode)
            character.size = widthNode.fontSize
            widthNode.formatting.textRuns = [ShapeTextRun(text:widthNode.text,character:character,paragraph:ShapeParagraphStyle())]
            let heightNode = formulaNode(400,"2",padding:"0.5")
            var field = pageNumberNode()
            if index == 2 {
                field.formatting.textFields![0].cells["Value"]?.formula = "PAGECOUNT()"
            }
            page.nodes = [widthNode,heightNode,field]
            pages.append(page)
        }
        var diagram = Diagram();diagram.pages = pages;diagram.activePageID = ids[0]
        return diagram
    }

    /// The former DiagramCalculation implementation: every pass evaluates
    /// ShapeSheet on every page, then evaluates text fields on every page.
    private func fullRecalculation(_ input:Diagram,previous:Diagram?) -> DiagramCalculation.Result {
        var next = input,issues = Set<String>()
        for pass in 0..<8 {
            let geometry = ShapeSheetEngine.recalculate(next,previous:pass == 0 ? previous : nil)
            let fields = TextFieldEngine.recalculate(geometry.diagram)
            issues = Set(geometry.issues+fields.issues)
            if fields.diagram == next { return DiagramCalculation.Result(diagram:fields.diagram,issues:issues.sorted()) }
            next = fields.diagram
        }
        issues.insert("Text and geometry dependencies did not settle within eight calculation passes; inspect the formulas for a circular dependency.")
        return DiagramCalculation.Result(diagram:next,issues:issues.sorted())
    }

    func testSettledPageSkippingMatchesFullCalculationWithPageAndFieldDependencies() {
        let imported = makeDiagram()
        let settled = fullRecalculation(imported,previous:nil)
        XCTAssertTrue(settled.issues.isEmpty,settled.issues.joined(separator:"\n"))

        var edited = settled.diagram
        edited.pages.reverse()
        let firstPageID = settled.diagram.pages[0].id
        let firstPageIndex = edited.pages.firstIndex{$0.id == firstPageID}!
        edited.pages[firstPageIndex].nodes[0].formatting.sheet["User.Padding"]?.value = "0.75"
        edited.pages[firstPageIndex].nodes[0].fontSize = 19
        edited.pages[firstPageIndex].nodes.append(DiagramNode(x:700,y:300,text:"Inserted"))
        let synchronized = ShapeRichText.synchronize(edited,previous:settled.diagram)

        let optimized = DiagramCalculation.recalculate(synchronized,previous:settled.diagram)
        let baseline = fullRecalculation(synchronized,previous:settled.diagram)
        XCTAssertEqual(optimized.issues,baseline.issues)
        XCTAssertEqual(optimized.diagram,baseline.diagram)

        let pageCountPageID = settled.diagram.pages[2].id
        for (index,page) in optimized.diagram.pages.enumerated() {
            let expected = page.id == pageCountPageID ? "3" : String(index+1)
            XCTAssertEqual(page.nodes.first{$0.formatting.textFields != nil}?.formatting.textFields?.first?.cached,expected)
        }
        XCTAssertEqual(optimized.diagram.pages.first{$0.id == firstPageID}?.nodes[0].fontSize ?? 0,19,accuracy:1e-8)
        XCTAssertEqual(optimized.diagram.pages.first{$0.id == firstPageID}?.nodes[0].formatting.textRuns?.first?.character.size ?? 0,19,accuracy:1e-8)
    }

    func testUnchangedPageKeepsImportedCachedCellWhileDirectCalculationRemainsFull() {
        var previous = makeDiagram()
        let untouchedPageID = previous.pages[1].id
        previous.pages[1].nodes[0].formatting.sheet["User.Cached"] = ShapeSheetCell(value:"9",formula:"2+3")
        var input = previous
        input.pages[0].nodes.append(DiagramNode(x:700,y:300,text:"Inserted"))

        let optimized = ShapeSheetEngine.recalculate(input,previous:previous,skipUnchangedPagesComparedTo:previous)
        let full = ShapeSheetEngine.recalculate(input,previous:previous)
        let optimizedPage = optimized.diagram.pages.first{$0.id == untouchedPageID}!
        let fullPage = full.diagram.pages.first{$0.id == untouchedPageID}!
        XCTAssertEqual(optimizedPage.nodes[0].formatting.sheet["User.Cached"]?.value,"9")
        XCTAssertEqual(fullPage.nodes[0].formatting.sheet["User.Cached"]?.value,"5")
    }

    func testArchiveChangeAndPriorIssuesDisablePageSkipping() {
        var previous = makeDiagram()
        previous.pages[1].nodes[0].formatting.sheet["User.Bad"] = ShapeSheetCell(value:"cached",formula:"UnsupportedFunction()")
        previous.visioArchive = VisioDocumentArchive(parts:["opaque.bin":Data([1])],pagesPart:"visio/pages/pages.xml",pages:[])
        var changedArchive = previous
        changedArchive.pages[0].nodes.append(DiagramNode(x:700,y:300,text:"Inserted"))
        changedArchive.visioArchive?.parts["opaque.bin"] = Data([2])
        let archiveFallback = ShapeSheetEngine.recalculate(changedArchive,previous:previous,skipUnchangedPagesComparedTo:previous)
        XCTAssertFalse(archiveFallback.issues.isEmpty)

        var sameArchiveEdit = previous
        sameArchiveEdit.pages[0].nodes.append(DiagramNode(x:700,y:300,text:"Inserted"))
        let issueFallback = DiagramCalculation.recalculate(sameArchiveEdit,previous:previous,previousIssues:["Previously reported issue"])
        XCTAssertTrue(issueFallback.issues.contains{$0.localizedCaseInsensitiveContains("unsupportedfunction")},issueFallback.issues.joined(separator:"\n"))
    }

    func testGeometryWarningsPersistOnSkippedPagesAndClearWhenCorrected() {
        var imported = makeDiagram()
        let warningPageID = imported.pages[1].id
        imported.pages[1].nodes[0].formatting.sheet["User.Bad"] = ShapeSheetCell(value:"cached",formula:"UnsupportedFunction()")
        let initial = ShapeSheetEngine.recalculate(imported)
        XCTAssertTrue(initial.issues.contains{$0.localizedCaseInsensitiveContains("unsupportedfunction")},initial.issues.joined(separator:"\n"))
        XCTAssertEqual(Set(initial.issuesByPage.keys),Set(imported.pages.map(\.id)))
        XCTAssertFalse(initial.issuesByPage[warningPageID,default:[]].isEmpty)

        var edited = initial.diagram
        let movedPageID = edited.pages[0].id
        let pageCountPageID = edited.pages[2].id
        edited.pages.reverse()
        let movedPageIndex = edited.pages.firstIndex{$0.id == movedPageID}!
        edited.pages[movedPageIndex].nodes.append(DiagramNode(x:700,y:300,text:"Inserted"))
        let optimized = DiagramCalculation.recalculate(
            edited,
            previous:initial.diagram,
            previousIssues:initial.issues,
            previousGeometryIssuesByPage:initial.issuesByPage
        )
        let baseline = fullRecalculation(edited,previous:initial.diagram)
        XCTAssertEqual(optimized.issues,baseline.issues)
        XCTAssertEqual(optimized.diagram,baseline.diagram)
        XCTAssertEqual(optimized.geometryIssuesByPage[warningPageID],initial.issuesByPage[warningPageID])
        for (index,page) in optimized.diagram.pages.enumerated() {
            let expected = page.id == pageCountPageID ? "3" : String(index+1)
            XCTAssertEqual(page.nodes.first{$0.formatting.textFields != nil}?.formatting.textFields?.first?.cached,expected)
        }

        var corrected = optimized.diagram
        let correctedIndex = corrected.pages.firstIndex{$0.id == warningPageID}!
        corrected.pages[correctedIndex].nodes[0].formatting.sheet["User.Bad"]?.formula = "2+3"
        let fixed = DiagramCalculation.recalculate(
            corrected,
            previous:optimized.diagram,
            previousIssues:optimized.issues,
            previousGeometryIssuesByPage:optimized.geometryIssuesByPage
        )
        let fixedBaseline = fullRecalculation(corrected,previous:optimized.diagram)
        XCTAssertEqual(fixed.issues,fixedBaseline.issues)
        XCTAssertEqual(fixed.diagram,fixedBaseline.diagram)
        XCTAssertFalse(fixed.issues.contains{$0.localizedCaseInsensitiveContains("unsupportedfunction")},fixed.issues.joined(separator:"\n"))
        XCTAssertTrue(fixed.geometryIssuesByPage[warningPageID,default:[]].isEmpty)
    }
}
