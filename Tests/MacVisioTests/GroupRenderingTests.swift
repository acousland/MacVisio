import AppKit
import XCTest
@testable import MacVisio

final class GroupRenderingTests:XCTestCase {
    private func page(mode:Int? = nil,hidden:Bool = false) -> DiagramPage {
        var page = DiagramPage(name:"Group rendering")
        page.width = 260;page.height = 160
        var group = DiagramNode(kind:.rectangle,x:20,y:20,text:"GROUP TITLE")
        group.width = 220;group.height = 120;group.fontSize = 20
        group.textColor = "#000000";group.formatting.isGroup = true
        if let mode { group.formatting.sheet["DisplayMode"] = ShapeSheetCell(value:String(mode)) }
        if hidden { group.formatting.sheet["HideText"] = ShapeSheetCell(value:"1") }
        var background = DiagramNode(kind:.rectangle,x:20,y:20,text:"")
        background.width = 220;background.height = 120;background.fill = "#FFFFFF"
        background.stroke = "#FFFFFF00";background.parentID = group.id
        var footer = DiagramNode(kind:.text,x:70,y:110,text:"FOOTER")
        footer.width = 120;footer.height = 30;footer.fontSize = 10
        footer.fill = "#FFFFFF00";footer.stroke = "#FFFFFF00";footer.parentID = group.id
        page.nodes = [group,background,footer]
        return page
    }
    private func titlePixels(_ page:DiagramPage) throws -> Int {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(page,scale:1)))
        var count = 0
        for y in 50..<105 { for x in 35..<225 {
            let color = try XCTUnwrap(bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB))
            if max(color.redComponent,color.greenComponent,color.blueComponent) < 0.5 { count += 1 }
        } }
        return count
    }
    func testGroupTitleRendersAboveOpaqueMemberInPNGAndSVG() throws {
        let drawing = page()
        XCTAssertGreaterThan(try titlePixels(drawing),100)
        let svg = DiagramDrawing.svg(drawing)
        let title = try XCTUnwrap(svg.range(of:"GROUP TITLE"))
        let footer = try XCTUnwrap(svg.range(of:"FOOTER"))
        XCTAssertGreaterThan(title.lowerBound,footer.lowerBound)
        XCTAssertTrue(DiagramExport.pdf(drawing).starts(with:Data("%PDF".utf8)))
    }
    func testBehindAndHiddenGroupModesLeaveMembersVisible() throws {
        for mode in [0,1] { XCTAssertEqual(try titlePixels(page(mode:mode)),0) }
        let svg = DiagramDrawing.svg(page(mode:0))
        XCTAssertFalse(svg.contains("GROUP TITLE"));XCTAssertTrue(svg.contains("FOOTER"))
    }
    func testHideTextSuppressesOnlyTextInRasterAndSVG() throws {
        let drawing = page(hidden:true)
        XCTAssertEqual(try titlePixels(drawing),0)
        let svg = DiagramDrawing.svg(drawing)
        XCTAssertFalse(svg.contains("GROUP TITLE"));XCTAssertTrue(svg.contains("FOOTER"))
        XCTAssertTrue(svg.contains("<path"))
    }
}
