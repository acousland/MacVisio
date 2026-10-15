import XCTest
@testable import MacVisio

final class ShapeSheetLookupTests:XCTestCase {
    func testCaseInsensitiveCellIndexRetainsUnicodeAndFirstMatchSemantics() throws {
        var page = DiagramPage(),node = DiagramNode()
        node.formatting.sheet = ["User.Size":ShapeSheetCell(value:"7"),"USER.SIZE":ShapeSheetCell(value:"9")]
        page.nodes = [node]
        let expected = node.formatting.sheet.first{$0.key.caseInsensitiveCompare("user.size") == .orderedSame}!.value.value
        let context = ShapeSheetContext(page:page)
        XCTAssertEqual(try context.number(node.id,"user.size"),Double(expected)!)
        XCTAssertEqual(try context.number(node.id,"user.size"),Double(expected)!)

        node.formatting.sheet = ["User.K":ShapeSheetCell(value:"11")]
        page.nodes = [node]
        XCTAssertEqual(try ShapeSheetContext(page:page).number(node.id,"user.k"),11)
        XCTAssertEqual(try ShapeSheetContext(page:page).number(node.id,"USER.K"),11)
    }
    func testIndexedLookupsMatchPageScansForNestedTransformedShapes() throws {
        var page = DiagramPage()
        var outer = DiagramNode(x:130,y:115,text:"Outer")
        outer.width = 340;outer.height = 220;outer.rotation = 37;outer.formatting.isGroup = true;outer.formatting.flipX = true
        var inner = DiagramNode(x:95,y:75,text:"Inner")
        inner.width = 190;inner.height = 120;inner.rotation = -19;inner.parentID = outer.id;inner.formatting.isGroup = true;inner.formatting.flipY = true
        var child = DiagramNode(x:48,y:36,text:"Child")
        child.width = 64;child.height = 48;child.rotation = 13;child.parentID = inner.id
        child.formatting.sheet["User.DefaultPinX"] = ShapeSheetCell(value:"0",formula:"PinX")
        page.nodes = [outer,inner,child]
        let nodesByID = Dictionary(uniqueKeysWithValues:page.nodes.map{($0.id,$0)})

        let scannedLocal = VisioPreservation.localNode(child,in:page)
        let indexedLocal = VisioPreservation.localNode(child,in:page,nodesByID:nodesByID)
        XCTAssertEqual(indexedLocal,scannedLocal)
        XCTAssertEqual(VisioPreservation.localNode(child,in:page,nodesByID:[:]),scannedLocal)

        let scannedDefaults = ShapeSheetEngine.defaults(child,page:page)
        let indexedDefaults = ShapeSheetEngine.defaults(child,page:page,nodesByID:nodesByID)
        XCTAssertEqual(indexedDefaults,scannedDefaults)
        XCTAssertEqual(ShapeSheetEngine.defaults(child,page:page,nodesByID:[:]),scannedDefaults)
        XCTAssertNotEqual(indexedDefaults["PinX"],0)

        let context = ShapeSheetContext(page:page)
        XCTAssertEqual(try context.number(child.id,"User.DefaultPinX"),indexedDefaults["PinX"]!,accuracy:1e-10)
        XCTAssertEqual(try context.number(child.id,"User.DefaultPinX"),indexedDefaults["PinX"]!,accuracy:1e-10)
    }
}
