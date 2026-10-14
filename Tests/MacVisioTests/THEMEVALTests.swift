import Foundation
import XCTest
@testable import MacVisio

final class THEMEVALTests:XCTestCase {
    private func cell(_ value:String,_ formula:String = "",_ unit:String = "") -> ShapeSheetCell { ShapeSheetCell(value:value,formula:formula,unit:unit) }

    private func theme(schemeIndex:Int = 33,values:[String:ShapeSheetCell] = [:],colors:[String:String]? = nil) -> VisioTheme {
        VisioTheme(relationshipID:"rIdTheme",relationshipType:"http://schemas.microsoft.com/visio/2010/relationships/theme",
                   target:"../theme/theme1.xml",part:"visio/theme/theme1.xml",name:"Test",colorSchemeName:"Test",
                   schemeIndex:schemeIndex,colorScheme:[:],variationColorSchemes:[:],variationColorIndex:0,values:values,
                   colors:colors ?? ["Dark":"#111111","Light":"#EEEEEE","BackgroundColor":"#FEFFFF",
                                     "AccentColor1":"#123456","AccentColor2":"#234567","AccentColor3":"#345678",
                                     "AccentColor4":"#456789","AccentColor5":"#56789A","AccentColor6":"#6789AB",
                                     "VariantColor1":"#45B664","VariantColor7":"#70AD47"])
    }

    private func page(with shape:DiagramNode,theme:VisioTheme? = nil,pageScheme:Int? = nil) -> DiagramPage {
        var page = DiagramPage();page.nodes = [shape];page.theme = theme
        if let pageScheme { page.sheet = ["ColorSchemeIndex":cell(String(pageScheme))] }
        return page
    }

    func testTwoArgumentColorDefaultIsLazyAndPreservesItsTypeWhenNoThemeIsApplied() throws {
        var shape = DiagramNode(text:"No Theme")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("0")
        shape.formatting.sheet["QuickStyleFillColor"] = cell("0","1/0")
        let context = ShapeSheetContext(page:page(with:shape))

        XCTAssertEqual(try context.evaluate("THEMEVAL(1,1.25in)",on:shape.id),.quantity(1.25,"IN"))
        XCTAssertEqual(try context.evaluate("THEMEVAL(QuickStyleFillColor,7)",on:shape.id),.number(7))
        XCTAssertThrowsError(try context.evaluate("THEMEVAL(\"Dark\")",on:shape.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("No Theme column values are unavailable"),error.localizedDescription)
        }
        XCTAssertThrowsError(try context.evaluate("THEMEVAL(\"TextColor\",RGB(0,0,0))",on:shape.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsupported"),error.localizedDescription)
        }
        XCTAssertThrowsError(try context.evaluate("THEMEVAL(\"LineWeight\",1.25pt)",on:shape.id))
    }

    func testOneArgumentStringAndIntegerResolveImportedThemeColors() throws {
        var shape = DiagramNode(text:"Page theme")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("65534")
        let context = ShapeSheetContext(page:page(with:shape,theme:theme(),pageScheme:33))

        XCTAssertEqual(try context.evaluate("THEMEVAL(\"Dark\")",on:shape.id),.string("#111111"))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"AccentColor\")",on:shape.id),.string("#123456"))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"AccentColor6\")",on:shape.id),.string("#6789AB"))
        XCTAssertEqual(try context.evaluate("THEMEVAL(1)",on:shape.id),.string("#111111"))
        XCTAssertEqual(try context.evaluate("THEMEVAL(8)",on:shape.id),.string("#6789AB"))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"5\")",on:shape.id),.string("#345678"))
        XCTAssertThrowsError(try context.evaluate("THEMEVAL(0)",on:shape.id))
        XCTAssertThrowsError(try context.evaluate("THEMEVAL(9)",on:shape.id))
    }

    func testUnquotedQuickStyleColorSelectorsUseVSDXIndicesAndSelectedVariants() throws {
        let expected = [0:"#111111",1:"#EEEEEE",8:"#FEFFFF",100:"#45B664",106:"#70AD47"]
        for (index,color) in expected {
            var shape = DiagramNode(text:"Quick style \(index)")
            shape.formatting.sheet["ColorSchemeIndex"] = cell("65534")
            shape.formatting.sheet["QuickStyleFillColor"] = cell(String(index))
            shape.formatting.sheet["User.QuickStyle"] = cell("0","THEMEVAL(QuickStyleFillColor)")
            let context = ShapeSheetContext(page:page(with:shape,theme:theme(),pageScheme:33))
            XCTAssertEqual(try context.value(shape.id,"User.QuickStyle"),.string(color))
        }

        var line = DiagramNode(text:"Quick style line")
        line.formatting.sheet["ColorSchemeIndex"] = cell("33")
        line.formatting.sheet["QuickStyleLineColor"] = cell("7")
        line.formatting.sheet["User.QuickStyle"] = cell("0","THEMEVAL(QuickStyleLineColor)")
        XCTAssertEqual(try ShapeSheetContext(page:page(with:line,theme:theme())).value(line.id,"User.QuickStyle"),.string("#6789AB"))

        line.formatting.sheet["QuickStyleLineColor"] = cell("200")
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:line,theme:theme())).value(line.id,"User.QuickStyle"))
    }

    func testZeroArgumentResolvesOnlyPaletteHostCellsAndIgnoresGenericThemeValues() throws {
        var shape = DiagramNode(text:"Palette host")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("65534")
        shape.formatting.sheet["AccentColor1"] = cell("#000000","THEMEVAL()")
        let sourceTheme = theme(values:["LineWeight":cell("0.5","","PT"),"LineColor":cell("#ABCDEF"),"FillColor":cell("#FEDCBA")])
        let context = ShapeSheetContext(page:page(with:shape,theme:sourceTheme,pageScheme:33))

        XCTAssertEqual(try context.value(shape.id,"AccentColor1"),.string("#123456"))

        var unresolved = shape
        unresolved.formatting.sheet["LineColor"] = cell("#000000","THEMEVAL()")
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:unresolved,theme:sourceTheme,pageScheme:33)).value(unresolved.id,"LineColor")) { error in
            XCTAssertTrue(error.localizedDescription.contains("no supported palette mapping"),error.localizedDescription)
        }
    }

    func testTwoArgumentDefaultDoesNotMaskActiveThemeOrUnknownSelector() throws {
        var active = DiagramNode(text:"Themed")
        active.formatting.sheet["ColorSchemeIndex"] = cell("33")
        let activeContext = ShapeSheetContext(page:page(with:active,theme:theme(),pageScheme:33))
        XCTAssertEqual(try activeContext.evaluate("THEMEVAL(\"Dark\",1/0)",on:active.id),.string("#111111"))
        XCTAssertThrowsError(try activeContext.evaluate("THEMEVAL(\"FillColor\",7)",on:active.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsupported"),error.localizedDescription)
        }

        var inherited = DiagramNode(text:"Unknown selector")
        inherited.formatting.sheet["ColorSchemeIndex"] = cell("0","Inh")
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:inherited,theme:theme(),pageScheme:33)).evaluate("THEMEVAL(\"Dark\",7)",on:inherited.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unknown"),error.localizedDescription)
        }
    }

    func testPageAndAssociatedMasterSelectorsRequireTheirOwnSourceData() throws {
        var pageSelected = DiagramNode(text:"Inherit page")
        pageSelected.formatting.sheet["ColorSchemeIndex"] = cell("65534")
        XCTAssertEqual(try ShapeSheetContext(page:page(with:pageSelected,theme:theme(),pageScheme:33)).evaluate("THEMEVAL(\"Dark\")",on:pageSelected.id),.string("#111111"))

        var pageNoTheme = DiagramNode(text:"Inherit no theme")
        pageNoTheme.formatting.sheet["ColorSchemeIndex"] = cell("65534")
        XCTAssertEqual(try ShapeSheetContext(page:page(with:pageNoTheme,pageScheme:0)).evaluate("THEMEVAL(\"Dark\",9)",on:pageNoTheme.id),.number(9))
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:pageNoTheme,pageScheme:0)).evaluate("THEMEVAL(\"Dark\")",on:pageNoTheme.id))

        var associatedMaster = DiagramNode(text:"Associated master")
        associatedMaster.formatting.sheet["ColorSchemeIndex"] = cell("65535")
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:associatedMaster,theme:theme(),pageScheme:33)).evaluate("THEMEVAL(\"Dark\",9)",on:associatedMaster.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("associated-master"),error.localizedDescription)
        }
    }

    func testTwoArgumentFallbackChecksAllThemeComponentsButOnlyForColorSelectors() throws {
        for selector in ["ThemeIndex","EffectSchemeIndex","ConnectorSchemeIndex","FontSchemeIndex"] {
            var shape = DiagramNode(text:selector)
            shape.formatting.sheet["ColorSchemeIndex"] = cell("33")
            shape.formatting.sheet[selector] = cell("0")
            let context = ShapeSheetContext(page:page(with:shape,theme:theme()))
            XCTAssertEqual(try context.evaluate("THEMEVAL(\"Dark\",9)",on:shape.id),.number(9),selector)
            XCTAssertThrowsError(try context.evaluate("THEMEVAL(\"TextColor\",9)",on:shape.id),selector)
        }

        var inheritedNoTheme = DiagramNode(text:"Inherited page no theme")
        inheritedNoTheme.formatting.sheet["ColorSchemeIndex"] = cell("33")
        inheritedNoTheme.formatting.sheet["EffectSchemeIndex"] = cell("65534")
        var noThemePage = page(with:inheritedNoTheme,theme:theme(),pageScheme:33)
        noThemePage.sheet?["EffectSchemeIndex"] = cell("0")
        XCTAssertEqual(try ShapeSheetContext(page:noThemePage).evaluate("THEMEVAL(\"Dark\",9)",on:inheritedNoTheme.id),.number(9))

        var inheritedActive = DiagramNode(text:"Inherited active page component")
        inheritedActive.formatting.sheet["ColorSchemeIndex"] = cell("33")
        inheritedActive.formatting.sheet["EffectSchemeIndex"] = cell("65534")
        var activePage = page(with:inheritedActive,theme:theme(),pageScheme:33)
        activePage.sheet?["EffectSchemeIndex"] = cell("33")
        XCTAssertEqual(try ShapeSheetContext(page:activePage).evaluate("THEMEVAL(\"Dark\",9)",on:inheritedActive.id),.string("#111111"))
    }

    func testTHEMEPROPRejectsOutOfRangeEmbellishmentIndexAndKeepsCachedValue() {
        var shape = DiagramNode(text:"Invalid theme embellishment")
        for selector in ["ThemeIndex","ColorSchemeIndex","EffectSchemeIndex","ConnectorSchemeIndex","FontSchemeIndex"] {
            shape.formatting.sheet[selector] = cell("33")
        }
        shape.formatting.sheet["EmbellishmentIndex"] = cell("256")
        shape.formatting.sheet["User.ThemeProp"] = cell("42","THEMEPROP(\"Embellishment\")")
        var diagram = Diagram();diagram.page.nodes = [shape];diagram.page.theme = theme();diagram.page.sheet = ["ColorSchemeIndex":cell("33")]

        let result = ShapeSheetEngine.recalculate(diagram)
        XCTAssertEqual(result.diagram.page.nodes[0].formatting.sheet["User.ThemeProp"]?.value,"42")
        XCTAssertTrue(result.issues.contains{$0.localizedCaseInsensitiveContains("EmbellishmentIndex")},result.issues.joined(separator:"\n"))
    }

    func testUnsupportedThemeStateKeepsCachedFormulaCellValue() {
        var shape = DiagramNode(text:"Theme mapping missing")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("33")
        shape.formatting.sheet["User.Fallback"] = cell("23","THEMEVAL(\"FillColor\",7)")
        var diagram = Diagram();diagram.page.nodes = [shape];diagram.page.theme = theme();diagram.page.sheet = ["ColorSchemeIndex":cell("33")]

        let result = ShapeSheetEngine.recalculate(diagram)
        XCTAssertEqual(result.diagram.page.nodes[0].formatting.sheet["User.Fallback"]?.value,"23")
        XCTAssertTrue(result.issues.contains{$0.localizedCaseInsensitiveContains("unsupported")},result.issues.joined(separator:"\n"))
    }

    func testImportedVSDXThemeAndRealThemevalFormulaUseAvailableColorsOnly() throws {
        let fixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/blue-box.vsdx")
        let imported = try VisioFormat.read(from:fixture).diagram
        let shape = try XCTUnwrap(imported.page.nodes.first)
        XCTAssertEqual(imported.page.theme?.schemeIndex,33)
        XCTAssertEqual(imported.page.sheet?["ColorSchemeIndex"]?.value,"33")
        let themeColors = try XCTUnwrap(imported.page.theme?.colors)
        XCTAssertTrue(themeColors["VariantColor1"] != nil)
        XCTAssertTrue(themeColors["VariantColor4"] != nil)

        let parts = try VisioPackage.read(fixture)
        let pageXMLData = try XCTUnwrap(parts["visio/pages/page1.xml"])
        let pageXML = try XCTUnwrap(String(data:pageXMLData,encoding:.utf8))
        let realFormula = "THEMEVAL(\"TextColor\",RGB(0,0,0))"
        XCTAssertTrue(pageXML.contains("F='\(realFormula)'"),"The fixture should retain its real ShapeSheet THEMEVAL formula.")
        XCTAssertThrowsError(try ShapeSheetContext(page:imported.page).evaluate(realFormula,on:shape.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unsupported"),error.localizedDescription)
        }
        XCTAssertTrue(pageXML.contains("V='#feffff' F='\(realFormula)'"),"An unresolved real VSDX formula keeps its imported cached value.")
    }

    func testImportedPageVariationIndexesApplyWhenShapeSelectorsAreAbsent() throws {
        let fixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/testfile1.vsdx")
        var imported = try VisioFormat.read(from:fixture).diagram
        let theme = try XCTUnwrap(imported.page.theme)
        let shapeIndex = try XCTUnwrap(imported.page.nodes.indices.first)
        var shape = imported.page.nodes[shapeIndex]
        for selector in ["ThemeIndex","ColorSchemeIndex","EffectSchemeIndex","ConnectorSchemeIndex","FontSchemeIndex"] {
            shape.formatting.sheet[selector] = cell("33")
        }
        shape.formatting.sheet["EmbellishmentIndex"] = cell("0")
        shape.formatting.sheet.removeValue(forKey:"VariationStyleIndex")
        shape.formatting.sheet.removeValue(forKey:"VariationColorIndex")
        XCTAssertNil(shape.formatting.sheet["VariationStyleIndex"])
        XCTAssertNil(shape.formatting.sheet["VariationColorIndex"])
        imported.page.nodes[shapeIndex] = shape

        let styleIndex = try XCTUnwrap(Int(try XCTUnwrap(imported.page.sheet?["VariationStyleIndex"]).value))
        let colorIndex = try XCTUnwrap(Int(try XCTUnwrap(imported.page.sheet?["VariationColorIndex"]).value))
        let expectedEmbellishment = Double(try XCTUnwrap(theme.variationStyleSchemes[styleIndex]?.embellishment))
        let expectedMultiFormat = (try XCTUnwrap(theme.variationColorSchemeMonotone[colorIndex])) ? 1.0 : 0.0
        let context = ShapeSheetContext(page:imported.page)

        XCTAssertEqual(try context.evaluate("THEMEPROP(\"Embellishment\")",on:shape.id),.number(expectedEmbellishment))
        XCTAssertEqual(try context.evaluate("THEMEPROP(\"MultiFormat\")",on:shape.id),.number(expectedMultiFormat))
    }
}
