import XCTest
@testable import MacVisio

final class RichTextSynchronizationTests:XCTestCase {
    private func run(_ text:String,source:Int? = nil,color:String = "#20334F",size:Double = 14,alignment:TextAlignment = .center,field:Int? = nil) -> ShapeTextRun {
        var character = ShapeCharacterStyle(node:DiagramNode(text:text))
        character.fontName = "Arial"
        character.size = size
        character.color = color
        character.sourceIndex = source
        return ShapeTextRun(text:text,character:character,paragraph:ShapeParagraphStyle(alignment:alignment),fieldIndex:field)
    }

    private func node(_ id:UUID,text:String,runs:[ShapeTextRun]) -> DiagramNode {
        var node = DiagramNode(x:10,y:20,text:text)
        node.id = id
        node.formatting.textRuns = runs
        return node
    }

    private func diagram(pages:[DiagramPage],activePageID:UUID) -> Diagram {
        var diagram = Diagram()
        diagram.pages = pages
        diagram.activePageID = activePageID
        return diagram
    }

    func testSynchronizeMatchesReorderedPagesAndNodesByIdentity() {
        let firstPageID = UUID(),secondPageID = UUID(),aID = UUID(),bID = UUID(),cID = UUID()
        let oldA = node(aID,text:"Alpha",runs:[run("Alpha",source:2,color:"#111111")])
        let oldB = node(bID,text:"Beta",runs:[run("Beta",source:4,color:"#222222")])
        let oldC = node(cID,text:"Gamma",runs:[run("Gamma",source:8,color:"#333333")])
        var previousFirst = DiagramPage(id:firstPageID);previousFirst.nodes = [oldA,oldB]
        var previousSecond = DiagramPage(id:secondPageID);previousSecond.nodes = [oldC]
        let previous = diagram(pages:[previousFirst,previousSecond],activePageID:firstPageID)

        var nextFirst = DiagramPage(id:firstPageID);nextFirst.nodes = [oldB,oldA]
        nextFirst.nodes[1].textColor = "#AABBCC"
        var nextSecond = DiagramPage(id:secondPageID);nextSecond.nodes = [oldC]
        nextSecond.nodes[0].fontSize = 21
        let next = diagram(pages:[nextSecond,nextFirst],activePageID:secondPageID)

        let result = ShapeRichText.synchronize(next,previous:previous)
        let resultA = result.pages[1].nodes.first{$0.id == aID}!
        let resultB = result.pages[1].nodes.first{$0.id == bID}!
        let resultC = result.pages[0].nodes.first{$0.id == cID}!
        XCTAssertEqual(resultA.formatting.textRuns?.first?.character.color,"#AABBCC")
        XCTAssertEqual(resultB.formatting.textRuns?.first?.character.color,"#222222")
        XCTAssertEqual(resultC.formatting.textRuns?.first?.character.size,21)
    }

    func testSynchronizeLeavesNewNodesWithoutABaselineUntouched() {
        let pageID = UUID(),newID = UUID()
        var previousPage = DiagramPage(id:pageID)
        previousPage.nodes = [node(UUID(),text:"Existing",runs:[run("Existing")])]
        let previous = diagram(pages:[previousPage],activePageID:pageID)
        var added = node(newID,text:"Added",runs:[run("Added",source:11,color:"#ABCDEF",size:12)])
        added.fontSize = 24
        var nextPage = DiagramPage(id:pageID);nextPage.nodes = [added]

        let result = ShapeRichText.synchronize(diagram(pages:[nextPage],activePageID:pageID),previous:previous)
        let resultNode = result.page.nodes[0]
        XCTAssertEqual(resultNode.fontSize,24)
        XCTAssertEqual(resultNode.formatting.textRuns,[run("Added",source:11,color:"#ABCDEF",size:12)])
    }

    func testSynchronizeAppliesInspectorTypographyChangesAcrossRuns() {
        let pageID = UUID(),id = UUID()
        let old = node(id,text:"OneTwo",runs:[run("One",source:1),run("Two",source:5,alignment:.left)])
        var previousPage = DiagramPage(id:pageID);previousPage.nodes = [old]
        var changed = old
        changed.fontSize = 22
        changed.textColor = "#C62828"
        changed.bold = true
        changed.formatting.fontName = "Courier New"
        changed.formatting.italic = true
        changed.formatting.underline = true
        changed.formatting.alignment = .right
        var nextPage = DiagramPage(id:pageID);nextPage.nodes = [changed]

        let result = ShapeRichText.synchronize(
            diagram(pages:[nextPage],activePageID:pageID),
            previous:diagram(pages:[previousPage],activePageID:pageID)
        )
        let runs = result.page.nodes[0].formatting.textRuns!
        XCTAssertEqual(runs.count,2)
        for run in runs {
            XCTAssertEqual(run.character.size,22)
            XCTAssertEqual(run.character.color,"#C62828")
            XCTAssertTrue(run.character.bold)
            XCTAssertEqual(run.character.fontName,"Courier New")
            XCTAssertTrue(run.character.italic)
            XCTAssertTrue(run.character.underline)
            XCTAssertEqual(run.paragraph.alignment,.right)
        }
    }

    func testSynchronizePreservesExplicitRunFormattingAndPlainTextReplacement() {
        let pageID = UUID(),explicitID = UUID(),replacementID = UUID()
        let originalExplicit = node(explicitID,text:"Explicit",runs:[run("Explicit",source:3,size:14)])
        let originalReplacement = node(replacementID,text:"Original",runs:[run("Original",source:7,field:7)])
        var previousPage = DiagramPage(id:pageID);previousPage.nodes = [originalExplicit,originalReplacement]
        var explicit = originalExplicit
        explicit.fontSize = 24
        explicit.formatting.textRuns![0].character.color = "#00AA55"
        var replacement = originalReplacement
        replacement.text = "Literal"
        var nextPage = DiagramPage(id:pageID);nextPage.nodes = [explicit,replacement]

        let result = ShapeRichText.synchronize(
            diagram(pages:[nextPage],activePageID:pageID),
            previous:diagram(pages:[previousPage],activePageID:pageID)
        )
        let explicitRun = result.page.nodes.first{$0.id == explicitID}!.formatting.textRuns![0]
        XCTAssertEqual(explicitRun.character.size,14)
        XCTAssertEqual(explicitRun.character.color,"#00AA55")
        let replacementNode = result.page.nodes.first{$0.id == replacementID}!
        XCTAssertEqual(replacementNode.text,"Literal")
        XCTAssertEqual(replacementNode.formatting.textRuns?.map(\.text).joined(),"Literal")
        XCTAssertNil(replacementNode.formatting.textRuns?.first?.fieldIndex)
        XCTAssertEqual(replacementNode.formatting.textRuns?.first?.character.sourceIndex,7)
    }

    func testCalculationSynchronizationUsesFirstRunSourceIndexSemantics() {
        let pageID = UUID(),id = UUID()
        let old = node(id,text:"ABC",runs:[run("A",source:4,size:10),run("B",source:8,size:20),run("C",source:4,size:30)])
        var previousPage = DiagramPage(id:pageID);previousPage.nodes = [old]
        var changed = old;changed.fontSize = 18
        var nextPage = DiagramPage(id:pageID);nextPage.nodes = [changed]

        let result = ShapeRichText.synchronizeCalculation(
            diagram(pages:[nextPage],activePageID:pageID),
            previous:diagram(pages:[previousPage],activePageID:pageID)
        )
        let runs = result.page.nodes[0].formatting.textRuns!
        XCTAssertEqual(runs.map(\.character.size),[18,20,18])
        XCTAssertEqual(runs.map(\.character.sourceIndex),[4,8,4])
    }

    func testCalculationSynchronizationWithoutSourceIndexUpdatesOnlyFirstRun() {
        let pageID = UUID(),id = UUID()
        let old = node(id,text:"AB",runs:[run("A",size:10),run("B",size:20)])
        var previousPage = DiagramPage(id:pageID);previousPage.nodes = [old]
        var changed = old;changed.fontSize = 18
        var nextPage = DiagramPage(id:pageID);nextPage.nodes = [changed]

        let result = ShapeRichText.synchronizeCalculation(
            diagram(pages:[nextPage],activePageID:pageID),
            previous:diagram(pages:[previousPage],activePageID:pageID)
        )
        XCTAssertEqual(result.page.nodes[0].formatting.textRuns?.map(\.character.size),[18,20])
    }
}
