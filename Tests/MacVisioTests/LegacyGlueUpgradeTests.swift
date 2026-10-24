import XCTest
@testable import MacVisio

final class LegacyGlueUpgradeTests: XCTestCase {
    private func page(_ connector: String, connects: String) throws -> XMLElement {
        try XCTUnwrap(VisioXML.element("""
        <PageContents xmlns="http://schemas.microsoft.com/office/visio/2012/main"><Shapes>\
        <Shape ID="1"><Cell N="PinX" V="1"/></Shape><Shape ID="2"><Cell N="PinX" V="3"/></Shape>\(connector)\
        </Shapes><Connects>\(connects)</Connects></PageContents>
        """))
    }

    func testLegacyMacVisioConnectorGainsVisioGlueFormulas() throws {
        let root = try page("""
        <Shape ID="3"><Cell N="BeginX" V="1" F="PAR(PNT(Sheet.1!PinX,Sheet.1!PinY))"/><Cell N="BeginY" V="1"/>\
        <Cell N="EndX" V="3" F="PAR(PNT(Sheet.2!Connections.X1,Sheet.2!Connections.Y1))"/><Cell N="EndY" V="1"/>\
        <Section N="Geometry"/></Shape>
        """, connects: """
        <Connect FromSheet="3" FromCell="BeginX" FromPart="9" ToSheet="1" ToCell="PinX" ToPart="3"/>\
        <Connect FromSheet="3" FromCell="EndX" FromPart="12" ToSheet="2" ToCell="Connections.X1" ToPart="100"/>
        """)
        VisioPreservation.upgradeLegacyGlue(root: root)
        let shape = try XCTUnwrap(root.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "3" })
        let formula = { (name: String) in shape.elementsLocal("Cell").first { $0.attr("N") == name }?.attr("F") }
        XCTAssertEqual(formula("BeginX"), "_WALKGLUE(BegTrigger,EndTrigger,WalkPreference)")
        XCTAssertEqual(formula("BeginY"), "_WALKGLUE(BegTrigger,EndTrigger,WalkPreference)")
        XCTAssertEqual(formula("BegTrigger"), "_XFTRIGGER(Sheet.1!EventXFMod)")
        XCTAssertEqual(formula("EndX"), "PAR(PNT(Sheet.2!Connections.X1,Sheet.2!Connections.Y1))")
        XCTAssertEqual(formula("EndTrigger"), "_XFTRIGGER(Sheet.2!EventXFMod)")
        XCTAssertEqual(shape.children?.last?.name, "Section", "Trigger cells stay before the shape's sections")
    }

    func testConnectorWithVisioTriggersIsUnchanged() throws {
        let connector = """
        <Shape ID="3"><Cell N="BeginX" V="1" F="CUSTOM()"/><Cell N="BegTrigger" V="2" F="_XFTRIGGER(Sheet.1!EventXFMod)"/></Shape>
        """
        let root = try page(connector, connects: """
        <Connect FromSheet="3" FromCell="BeginX" FromPart="9" ToSheet="1" ToCell="PinX" ToPart="3"/>
        """)
        let before = root.xmlString
        VisioPreservation.upgradeLegacyGlue(root: root)
        XCTAssertEqual(root.xmlString, before)
    }
}
