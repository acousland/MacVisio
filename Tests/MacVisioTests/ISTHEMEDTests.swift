import Foundation
import XCTest
@testable import MacVisio

final class ISTHEMEDTests:XCTestCase {
    private func cell(_ value:String,_ formula:String = "") -> ShapeSheetCell { ShapeSheetCell(value:value,formula:formula) }

    func testScalarISTHEMEDUsesTheHostCellResolver() throws {
        for (index,expected) in [(0.0,0.0),(2.0,1.0),(65534.0,1.0)] {
            var requested:[String] = []
            let result = try ShapeSheet.evaluate("ISTHEMED()",resolve:{reference in requested.append(reference);return index})
            XCTAssertEqual(result,expected)
            XCTAssertEqual(requested,["ColorSchemeIndex"])
        }
        for formula in ["ISTHEMED(0)","ISTHEMED(1,2)"] {
            XCTAssertThrowsError(try ShapeSheet.evaluate(formula,resolve:{_ in 0}),formula)
        }
    }

    func testTypedContextReadsEachFormulaHostsColorSchemeIndex() throws {
        var first = DiagramNode(text:"Not themed"),second = DiagramNode(text:"Themed")
        first.formatting.sourceShapeID = "17";second.formatting.sourceShapeID = "18"
        first.formatting.sheet["ColorSchemeIndex"] = cell("0")
        second.formatting.sheet["ColorSchemeIndex"] = cell("2")
        first.formatting.sheet["User.IsThemed"] = cell("0","ISTHEMED()")
        second.formatting.sheet["User.IsThemed"] = cell("0","ISTHEMED()")
        first.formatting.sheet["User.OtherShapeIsThemed"] = cell("0","Sheet.18!User.IsThemed")
        var page = DiagramPage();page.nodes = [first,second]
        let context = ShapeSheetContext(page:page)
        XCTAssertEqual(try context.evaluate("ISTHEMED()",on:first.id),.boolean(false))
        XCTAssertEqual(try context.evaluate("ISTHEMED()",on:second.id),.boolean(true))
        XCTAssertEqual(try context.value(first.id,"User.OtherShapeIsThemed"),.boolean(true))
        XCTAssertThrowsError(try context.evaluate("ISTHEMED(0)",on:second.id))
    }

    func testMissingColorSchemeIndexRemainsUnsupportedAndKeepsCachedValue() throws {
        var shape = DiagramNode(text:"Missing index")
        shape.formatting.sheet["User.IsThemed"] = cell("1","ISTHEMED()")
        var diagram = Diagram();diagram.page.nodes = [shape]
        let result = ShapeSheetEngine.recalculate(diagram)
        XCTAssertEqual(result.diagram.page.nodes[0].formatting.sheet["User.IsThemed"]?.value,"1")
        XCTAssertTrue(result.issues.contains{$0.localizedCaseInsensitiveContains("ColorSchemeIndex")},result.issues.joined())
        XCTAssertThrowsError(try ShapeSheetContext(page:diagram.page).evaluate("ISTHEMED()",on:shape.id))
    }

    func testInstallerISTHEMEDFormulaUsesExplicitZeroIndexBranch() throws {
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),source = root.appendingPathComponent("build/Visio2019-Libraries/BLDCOR_M.VSSX")
        guard FileManager.default.fileExists(atPath:source.path) else { throw XCTSkip("Installer assets are absent") }
        let imported = try VisioStencil.read(from:source)
        var match:(DiagramPage,DiagramNode,String)?
        for item in imported.items {
            for original in item.fragment.nodes {
                for formula in original.formatting.sheet.values.map(\.formula) where formula.localizedCaseInsensitiveContains("ISTHEMED()") && formula.range(of:",\\s*0\\s*\\)$",options:.regularExpression) != nil {
                    match = (item.fragment,original,formula);break
                }
                if match != nil { break }
            }
            if match != nil { break }
        }
        var (page,host,formula) = try XCTUnwrap(match)
        host.formatting.sheet["ColorSchemeIndex"] = cell("0")
        page.nodes[page.nodes.firstIndex{$0.id == host.id}!] = host
        XCTAssertEqual(try ShapeSheetContext(page:page).evaluate(formula,on:host.id),.number(0),formula)
        host.formatting.sheet["ColorSchemeIndex"] = cell("1")
        page.nodes[page.nodes.firstIndex{$0.id == host.id}!] = host
        XCTAssertEqual(try ShapeSheetContext(page:page).evaluate("ISTHEMED()",on:host.id),.boolean(true))
    }
}
