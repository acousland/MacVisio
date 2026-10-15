import XCTest
@testable import MacVisio

final class CalculationAuditTests:XCTestCase {
    private var urls:[URL] = []
    override func tearDown() { for url in urls { try? FileManager.default.removeItem(at:url) };super.tearDown() }
    private func temporary(_ extensionName:String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-calculation-audit-\(UUID()).\(extensionName)")
        urls.append(url);return url
    }

    func testAuditsPublicFormulaCellsAndReportsFunctionCoverage() throws {
        var diagram = Diagram()
        var node = DiagramNode(x:50,y:60,text:"Audit")
        node.formatting.sheet["User.Supported"] = ShapeSheetCell(value:"",formula:"PI()")
        node.formatting.sheet["User.Unsupported"] = ShapeSheetCell(value:"",formula:"FUTUREFUNC(1)")
        diagram.page.nodes = [node]
        let source = temporary("vsdx")
        try VisioFormat.write(diagram,to:source)
        var parts = try VisioPackage.read(source)
        parts.removeValue(forKey:"macvisio/document.json")
        try VisioPackage.write(parts,to:source)

        let reportURL = temporary("json")
        try CalculationAudit.inspect(source,to:reportURL)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:reportURL)) as? [String:Any])
        XCTAssertGreaterThanOrEqual(report["formulaCells"] as? Int ?? 0,2)
        XCTAssertGreaterThanOrEqual(report["evaluated"] as? Int ?? 0,1)
        XCTAssertEqual(report["failed"] as? Int,1)
        XCTAssertEqual(report["filesScanned"] as? Int,1)
        let functions = try XCTUnwrap(report["functions"] as? [String:Int])
        XCTAssertEqual(functions["PI"],1)
        XCTAssertEqual(functions["FUTUREFUNC"],1)
        let sections = try XCTUnwrap(report["formulaCellsBySection"] as? [String:Int])
        XCTAssertEqual(sections["User"],2)
        XCTAssertEqual(report["windowsValidated"] as? Bool,false)
    }

    func testAuditsEveryFormulaSectionWithoutDoubleCountingAliases() throws {
        var diagram = Diagram()
        var node = DiagramNode(x:50,y:60,text:"Sections")
        node.formatting.sheet["Controls.Handle.X"] = ShapeSheetCell(value:"1",formula:"2")
        node.formatting.controls = [ShapeControl(name:"Handle",index:0,cells:["X":ShapeSheetCell(value:"1",formula:"2")])]
        node.formatting.geometry = [ShapeGeometrySection(index:0,cells:[:],rows:[ShapeGeometryRow(index:0,type:"MoveTo",cells:["X":ShapeSheetCell(value:"",formula:"3"),"Y":ShapeSheetCell(value:"",formula:"4")])])]
        diagram.page.nodes = [node]
        let source = temporary("vsdx")
        try VisioFormat.write(diagram,to:source)
        var parts = try VisioPackage.read(source)
        parts.removeValue(forKey:"macvisio/document.json")
        try VisioPackage.write(parts,to:source)

        let reportURL = temporary("json")
        try CalculationAudit.inspect(source,to:reportURL)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:reportURL)) as? [String:Any])
        XCTAssertGreaterThanOrEqual(report["formulaCells"] as? Int ?? 0,3)
        XCTAssertGreaterThanOrEqual(report["evaluated"] as? Int ?? 0,3)
        XCTAssertEqual(report["failed"] as? Int,0)
        let sections = try XCTUnwrap(report["formulaCellsBySection"] as? [String:Int])
        XCTAssertEqual(sections["Control"],1)
        XCTAssertEqual(sections["Geometry"],2)
    }

    func testStencilAuditEvaluatesRGBUsingItsOwnColorEntryTable() throws {
        func makeStencil(withFormula:Bool) throws -> URL {
            var diagram = Diagram()
            var node = DiagramNode(x:50,y:60,text:"Stencil palette")
            if withFormula {
                node.formatting.sheet["User.Color"] = ShapeSheetCell(value:"0",formula:"RGB(12,34,56)")
            }
            diagram.page.nodes = [node]
            let file = temporary("vssx")
            let master = try XCTUnwrap(VisioStencil.definitions([diagram.page],family:"Audit test").first)
            try VisioReusableFormat.writeStencil([master],to:file)

            var parts = try VisioPackage.read(file)
            let document = try VisioXML.document(XCTUnwrap(parts["visio/document.xml"]))
            let colors = document.rootElement()?.firstLocal("Colors") ?? XMLElement(name:"Colors")
            if colors.parent == nil { document.rootElement()?.addChild(colors) }
            let entry = XMLElement(name:"ColorEntry")
            entry.setAttr("IX","31");entry.setAttr("RGB","#0C2238");colors.addChild(entry)
            parts["visio/document.xml"] = document.xmlData(options:.nodePreserveAll)
            try VisioPackage.write(parts,to:file)
            return file
        }

        func report(for file:URL) throws -> [String:Any] {
            let output = temporary("json")
            try CalculationAudit.inspect(file,to:output)
            return try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])
        }

        let withoutFormula = try report(for:makeStencil(withFormula:false))
        let withFormula = try report(for:makeStencil(withFormula:true))
        XCTAssertEqual((withFormula["formulaCells"] as? Int ?? 0) - (withoutFormula["formulaCells"] as? Int ?? 0),1)
        XCTAssertEqual((withFormula["evaluated"] as? Int ?? 0) - (withoutFormula["evaluated"] as? Int ?? 0),1)
        let functions = try XCTUnwrap(withFormula["functions"] as? [String:Int])
        XCTAssertEqual(functions["RGB"],1)
        let failures = try XCTUnwrap(withFormula["failuresByMessage"] as? [String:Int])
        XCTAssertNil(failures["RGB color is absent from the supplied Visio color table."])
    }

    func testPackageInventoryIncludesFormulaCellsInMastersAndDocumentStyles() throws {
        var diagram = Diagram()
        var node = DiagramNode(x:50,y:60,text:"Package inventory")
        node.formatting.sheet["User.PageFormula"] = ShapeSheetCell(value:"1",formula:"PI()")
        diagram.page.nodes = [node]
        let source = temporary("vsdx")
        try VisioFormat.write(diagram,to:source)
        var parts = try VisioPackage.read(source)
        parts.removeValue(forKey:"macvisio/document.json")

        let document = try VisioXML.document(try XCTUnwrap(parts["visio/document.xml"]))
        let root = try XCTUnwrap(document.rootElement())
        let styles = root.firstLocal("StyleSheets") ?? XMLElement(name:"StyleSheets")
        if styles.parent == nil { root.addChild(styles) }
        let style = XMLElement(name:"StyleSheet")
        style.setAttr("ID","777")
        let styledFormula = XMLElement(name:"Cell")
        styledFormula.setAttr("N","LineWeight");styledFormula.setAttr("V","1");styledFormula.setAttr("F","SUM(1,2)")
        style.addChild(styledFormula);styles.addChild(style)
        parts["visio/document.xml"] = document.xmlData(options:.nodePreserveAll)
        parts["visio/masters/master1.xml"] = Data("<MasterContents><Shapes><Shape ID=\"1\"><Cell N=\"Width\" V=\"1\" F=\"MAX(1,2)\"/></Shape></Shapes></MasterContents>".utf8)
        try VisioPackage.write(parts,to:source)

        let reportURL = temporary("json")
        try CalculationAudit.inspect(source,to:reportURL)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:reportURL)) as? [String:Any])
        let inventory = try XCTUnwrap(report["packageFormulaInventory"] as? [String:Any])
        let packageFormulaCells = try XCTUnwrap(inventory["formulaCells"] as? Int)
        XCTAssertGreaterThanOrEqual(packageFormulaCells,3)
        XCTAssertEqual(inventory["parsedFormulas"] as? Int,packageFormulaCells)
        XCTAssertEqual(inventory["formulaParseFailures"] as? Int,0)
        let roles = try XCTUnwrap(inventory["formulaCellsByPartRole"] as? [String:Int])
        XCTAssertGreaterThanOrEqual(roles["pages"] ?? 0,1)
        XCTAssertEqual(roles["documentAndStyles"],1)
        XCTAssertEqual(roles["masters"],1)
        XCTAssertEqual(packageFormulaCells,roles.values.reduce(0,+))
        let packageFunctions = try XCTUnwrap(inventory["functionCalls"] as? [String:Int])
        XCTAssertGreaterThanOrEqual(packageFunctions["PI"] ?? 0,1)
        XCTAssertEqual(packageFunctions["SUM"],1)
        XCTAssertEqual(packageFunctions["MAX"],1)
        // Only formulas modeled in page shape context count as evaluated.
        XCTAssertGreaterThanOrEqual(report["formulaCells"] as? Int ?? 0,1)
        XCTAssertGreaterThanOrEqual(report["evaluated"] as? Int ?? 0,1)
    }
}
