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

    func testThemeLineWeightAndCapUseSelectedRealLineMatrix() throws {
        let fixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/blue-box.vsdx")
        let imported = try VisioFormat.read(from:fixture).diagram
        var theme = try XCTUnwrap(imported.page.theme)
        theme.connectorSchemeIndex = 48
        var shape = DiagramNode(text:"Selected dynamic line")
        shape.formatting.sheet["EffectSchemeIndex"] = cell(String(try XCTUnwrap(theme.effectSchemeIndex)))
        shape.formatting.sheet["ConnectorSchemeIndex"] = cell("48")
        shape.formatting.sheet["QuickStyleType"] = cell("0")
        shape.formatting.sheet["QuickStyleLineMatrix"] = cell("4")
        shape.formatting.sheet["LineWeight"] = cell("0.01","THEMEVAL()")
        shape.formatting.sheet["LineCap"] = cell("0","THEMEVAL()")
        shape.formatting.sheet["User.ExplicitLineWeight"] = cell("0","THEMEVAL(\"LineWeight\")")
        shape.formatting.sheet["User.ExplicitLineCap"] = cell("0","THEMEVAL(\"LineCap\")")
        var page = imported.page;page.nodes = [shape];page.theme = theme
        let context = ShapeSheetContext(page:page)
        let matrixFourWeight = SheetValue.quantity(3175.0/914400.0,"IN")

        XCTAssertEqual(try context.value(shape.id,"LineWeight"),matrixFourWeight)
        XCTAssertEqual(try context.value(shape.id,"LineCap"),.number(1))
        XCTAssertEqual(try context.value(shape.id,"User.ExplicitLineWeight"),matrixFourWeight)
        XCTAssertEqual(try context.value(shape.id,"User.ExplicitLineCap"),.number(1))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"LineWeight\",1/0)",on:shape.id),matrixFourWeight)

        shape.formatting.sheet["QuickStyleLineMatrix"] = cell("2")
        shape.formatting.sheet["QuickStyleType"] = cell("2")
        shape.formatting.sheet["LineWeight"] = cell("0","THEMEVAL()")
        shape.formatting.sheet["LineCap"] = cell("0","THEMEVAL()")
        shape.formatting.sheet["User.ConnectorWeight"] = cell("0","THEMEVAL(\"ConnectorWeight\")")
        page.nodes = [shape]
        let connectorContext = ShapeSheetContext(page:page)
        XCTAssertEqual(try connectorContext.value(shape.id,"LineWeight"),.quantity(9525.0/914400.0,"IN"))
        XCTAssertEqual(try connectorContext.value(shape.id,"LineCap"),.number(1))
        XCTAssertEqual(try connectorContext.value(shape.id,"User.ConnectorWeight"),.quantity(12700.0/914400.0,"IN"))

        shape.formatting.sheet["QuickStyleLineMatrix"] = cell("3")
        shape.formatting.sheet["QuickStyleType"] = cell("3")
        page.nodes = [shape]
        let explicitConnectorContext = ShapeSheetContext(page:page)
        XCTAssertEqual(try explicitConnectorContext.value(shape.id,"LineWeight"),.quantity(25400.0/914400.0,"IN"))
        XCTAssertEqual(try explicitConnectorContext.value(shape.id,"LineCap"),.number(0))
    }

    func testThemeLineVariationSelectorsAndNoThemeFallbackAreBounded() throws {
        let fixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/testfile1.vsdx")
        let imported = try VisioFormat.read(from:fixture).diagram
        let theme = try XCTUnwrap(imported.page.theme)
        var shape = DiagramNode(text:"Variation-selected line")
        shape.formatting.sheet["EffectSchemeIndex"] = cell(String(try XCTUnwrap(theme.effectSchemeIndex)))
        shape.formatting.sheet["QuickStyleType"] = cell("1")
        shape.formatting.sheet["QuickStyleLineMatrix"] = cell("102")
        shape.formatting.sheet["User.VariationWeight"] = cell("0","THEMEVAL(\"LineWeight\")")
        var page = imported.page;page.nodes = [shape]
        let variation = try XCTUnwrap(theme.variationStyleSchemes[2]?.styles[2].lineIndex)
        let expectedEMU = try XCTUnwrap(theme.effectLineStyles[variation-1].widthEMU)
        XCTAssertEqual(try ShapeSheetContext(page:page).value(shape.id,"User.VariationWeight"),.quantity(Double(expectedEMU)/914400.0,"IN"))

        var noTheme = shape
        noTheme.formatting.sheet["EffectSchemeIndex"] = cell("0")
        noTheme.formatting.sheet["User.Fallback"] = cell("0","THEMEVAL(\"LineWeight\",0.25pt)")
        page.nodes = [noTheme]
        XCTAssertEqual(try ShapeSheetContext(page:page).value(noTheme.id,"User.Fallback"),.quantity(0.25/72.0,"PT"))

        noTheme.formatting.sheet["EffectSchemeIndex"] = cell(String(try XCTUnwrap(theme.effectSchemeIndex)))
        noTheme.formatting.sheet["QuickStyleLineMatrix"] = cell("0")
        page.nodes = [noTheme]
        XCTAssertThrowsError(try ShapeSheetContext(page:page).evaluate("THEMEVAL(\"LineWeight\",0.25pt)",on:noTheme.id))
        noTheme.formatting.sheet["QuickStyleLineMatrix"] = cell("7")
        page.nodes = [noTheme]
        XCTAssertThrowsError(try ShapeSheetContext(page:page).evaluate("THEMEVAL(\"LineWeight\")",on:noTheme.id))

        var mismatched = shape
        mismatched.formatting.sheet["EffectSchemeIndex"] = cell("34")
        mismatched.formatting.sheet["User.CachedWeight"] = cell("0.021","THEMEVAL(\"LineWeight\")")
        page.nodes = [mismatched]
        var diagram = Diagram();diagram.page = page
        let result = ShapeSheetEngine.recalculate(diagram)
        XCTAssertEqual(result.diagram.page.nodes[0].formatting.sheet["User.CachedWeight"]?.value,"0.021")
        XCTAssertTrue(result.issues.contains{$0.localizedCaseInsensitiveContains("does not match the imported theme")},result.issues.joined(separator:"\n"))
    }

    func testDrawingMLFlatAndDefaultCapsMapToVisioLineCapValues() throws {
        let source = try XCTUnwrap(VisioFormat.read(from:URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/blue-box.vsdx")).diagram.page.theme)
        var theme = source
        theme.effectLineStyles[0].cap = "flat"
        theme.effectLineStyles[1].cap = nil
        var shape = DiagramNode(text:"Cap enum")
        shape.formatting.sheet["EffectSchemeIndex"] = cell(String(try XCTUnwrap(theme.effectSchemeIndex)))
        shape.formatting.sheet["QuickStyleType"] = cell("1")
        shape.formatting.sheet["QuickStyleLineMatrix"] = cell("1")
        var page = page(with:shape,theme:theme)
        XCTAssertEqual(try ShapeSheetContext(page:page).evaluate("THEMEVAL(\"LineCap\")",on:shape.id),.number(2))
        shape.formatting.sheet["QuickStyleLineMatrix"] = cell("2")
        page.nodes = [shape]
        XCTAssertEqual(try ShapeSheetContext(page:page).evaluate("THEMEVAL(\"LineCap\")",on:shape.id),.number(1))
    }

    func testTwoArgumentColorDefaultIsLazyAndPreservesItsTypeWhenNoThemeIsApplied() throws {
        var shape = DiagramNode(text:"No Theme")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("0")
        shape.formatting.sheet["QuickStyleFillColor"] = cell("0","1/0")
        let context = ShapeSheetContext(page:page(with:shape))

        XCTAssertEqual(try context.evaluate("THEMEVAL(1,1.25in)",on:shape.id),.quantity(1.25,"IN"))
        XCTAssertEqual(try context.evaluate("THEMEVAL(QuickStyleFillColor,7)",on:shape.id),.number(7))
        // With no theme, Visio uses its default palette and explicit defaults (THEMEVALX-Dark, COERCE-15, THEMEVALX-default-2).
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"Dark\")",on:shape.id),.color(ShapeSheetColor(red:0,green:0,blue:0)))
        // Scalar hosts carry colors as color-table indexes; index 0 is black.
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"TextColor\",RGB(0,0,0))",on:shape.id),.number(0))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"LineWeight\",1.25pt)",on:shape.id),.quantity(1.25/72,"PT"))
    }

    func testOneArgumentStringAndIntegerResolveImportedThemeColors() throws {
        var shape = DiagramNode(text:"Page theme")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("65534")
        let context = ShapeSheetContext(page:page(with:shape,theme:theme(),pageScheme:33))

        XCTAssertEqual(try context.evaluate("THEMEVAL(\"Dark\")",on:shape.id),.color(ShapeSheetColor(red:17,green:17,blue:17)))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"AccentColor\")",on:shape.id),.color(ShapeSheetColor(red:18,green:52,blue:86)))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"AccentColor6\")",on:shape.id),.color(ShapeSheetColor(red:103,green:137,blue:171)))
        XCTAssertEqual(try context.evaluate("THEMEVAL(1)",on:shape.id),.color(ShapeSheetColor(red:17,green:17,blue:17)))
        XCTAssertEqual(try context.evaluate("THEMEVAL(8)",on:shape.id),.color(ShapeSheetColor(red:103,green:137,blue:171)))
        XCTAssertEqual(try context.evaluate("THEMEVAL(\"5\")",on:shape.id),.color(ShapeSheetColor(red:52,green:86,blue:120)))
        XCTAssertThrowsError(try context.evaluate("THEMEVAL(0)",on:shape.id))
        XCTAssertThrowsError(try context.evaluate("THEMEVAL(9)",on:shape.id))
    }

    func testColorComponentsAndLuminosityWorkThroughThemeFormulaChains() throws {
        var shape = DiagramNode(text:"Theme color arithmetic")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("33")
        shape.formatting.sheet["User.ThemeColor"] = cell("#000000","THEMEVAL(\"AccentColor1\")")
        shape.formatting.sheet["User.ThemeRed"] = cell("0","RED(User.ThemeColor)")
        shape.formatting.sheet["User.ThemeLum"] = cell("0","LUM(User.ThemeColor)")
        shape.formatting.sheet["User.ThemeTint"] = cell("#000000","HSL(HUE(User.ThemeColor),SAT(User.ThemeColor),MIN(LUM(User.ThemeColor)+100,240))")
        let context = ShapeSheetContext(page:page(with:shape,theme:theme(colors:["Dark":"#111111","Light":"#EEEEEE","BackgroundColor":"#FEFFFF",
            "AccentColor1":"#5B9BD5","AccentColor2":"#234567","AccentColor3":"#345678","AccentColor4":"#456789","AccentColor5":"#56789A","AccentColor6":"#6789AB"])))

        XCTAssertEqual(try context.value(shape.id,"User.ThemeColor"),.color(ShapeSheetColor(red:91,green:155,blue:213)))
        XCTAssertEqual(try context.value(shape.id,"User.ThemeRed"),.number(91))
        XCTAssertEqual(try context.value(shape.id,"User.ThemeLum"),.number(143))
        XCTAssertEqual(try context.value(shape.id,"User.ThemeTint"),.number(1))
        XCTAssertEqual(ShapeSheetContext.cached(.color(ShapeSheetColor(red:91,green:155,blue:213))),"#5B9BD5")
    }

    func testColorTransformsRetainNumericPaletteIndexSemantics() throws {
        var shape = DiagramNode(text:"Indexed colors")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("33")
        shape.formatting.sheet["FillForegnd"] = cell("#ADADAD")
        let context = ShapeSheetContext(page:page(with:shape,theme:theme()),colorPalette:ShapeSheetColorPalette(entries:[31:"#ADADAD"]))

        XCTAssertEqual(try context.evaluate("RGB(0,0,0)",on:shape.id),.number(0))
        XCTAssertEqual(try context.evaluate("LUM(6)",on:shape.id),.number(120))
        XCTAssertEqual(try context.evaluate("HUE(7)",on:shape.id),.number(120))
        XCTAssertEqual(try context.evaluate("SAT(31)",on:shape.id),.number(0))
        XCTAssertEqual(try context.evaluate("LUM(FillForegnd)",on:shape.id),.number(163))
        XCTAssertEqual(try context.evaluate("RED(HSL(160,240,120))",on:shape.id),.number(0))
        XCTAssertEqual(try context.evaluate("LUMDIFF(6,0)",on:shape.id),.number(120))
        XCTAssertEqual(try context.evaluate("HSL(160,240,120)",on:shape.id),.number(4))
        XCTAssertEqual(try context.evaluate("HSL(160,240,120)+1",on:shape.id),.number(5))
        XCTAssertEqual(try context.evaluate("HUE(HSL(160,240,120))",on:shape.id),.number(160))
        XCTAssertEqual(try context.evaluate("SAT(HSL(160,240,120))",on:shape.id),.number(240))
        XCTAssertEqual(try context.evaluate("LUM(HSL(160,240,120))",on:shape.id),.number(120))
        XCTAssertThrowsError(try context.evaluate("HSL(10,20,30)",on:shape.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("HSL color is absent"),error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("allocation is unsupported"),error.localizedDescription)
        }
    }

    func testUnquotedQuickStyleColorSelectorsUseVSDXIndicesAndSelectedVariants() throws {
        let expected = [0:"#111111",1:"#EEEEEE",8:"#FEFFFF",100:"#45B664",106:"#70AD47"]
        for (index,color) in expected {
            var shape = DiagramNode(text:"Quick style \(index)")
            shape.formatting.sheet["ColorSchemeIndex"] = cell("65534")
            shape.formatting.sheet["QuickStyleFillColor"] = cell(String(index))
            shape.formatting.sheet["User.QuickStyle"] = cell("0","THEMEVAL(QuickStyleFillColor)")
            let context = ShapeSheetContext(page:page(with:shape,theme:theme(),pageScheme:33))
            XCTAssertEqual(try context.value(shape.id,"User.QuickStyle"),.color(try XCTUnwrap(ShapeSheetColor(hex:color))))
        }

        var line = DiagramNode(text:"Quick style line")
        line.formatting.sheet["ColorSchemeIndex"] = cell("33")
        line.formatting.sheet["QuickStyleLineColor"] = cell("7")
        line.formatting.sheet["User.QuickStyle"] = cell("0","THEMEVAL(QuickStyleLineColor)")
        XCTAssertEqual(try ShapeSheetContext(page:page(with:line,theme:theme())).value(line.id,"User.QuickStyle"),.color(ShapeSheetColor(red:103,green:137,blue:171)))

        line.formatting.sheet["QuickStyleLineColor"] = cell("200")
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:line,theme:theme())).value(line.id,"User.QuickStyle"))
    }

    func testZeroArgumentResolvesOnlyPaletteHostCellsAndIgnoresGenericThemeValues() throws {
        var shape = DiagramNode(text:"Palette host")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("65534")
        shape.formatting.sheet["AccentColor1"] = cell("#000000","THEMEVAL()")
        let sourceTheme = theme(values:["LineWeight":cell("0.5","","PT"),"LineColor":cell("#ABCDEF"),"FillColor":cell("#FEDCBA")])
        let context = ShapeSheetContext(page:page(with:shape,theme:sourceTheme,pageScheme:33))

        XCTAssertEqual(try context.value(shape.id,"AccentColor1"),.color(ShapeSheetColor(red:18,green:52,blue:86)))

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
        XCTAssertEqual(try activeContext.evaluate("THEMEVAL(\"Dark\",1/0)",on:active.id),.color(ShapeSheetColor(red:17,green:17,blue:17)))
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
        XCTAssertEqual(try ShapeSheetContext(page:page(with:pageSelected,theme:theme(),pageScheme:33)).evaluate("THEMEVAL(\"Dark\")",on:pageSelected.id),.color(ShapeSheetColor(red:17,green:17,blue:17)))

        var pageNoTheme = DiagramNode(text:"Inherit no theme")
        pageNoTheme.formatting.sheet["ColorSchemeIndex"] = cell("65534")
        XCTAssertEqual(try ShapeSheetContext(page:page(with:pageNoTheme,pageScheme:0)).evaluate("THEMEVAL(\"Dark\",9)",on:pageNoTheme.id),.number(9))
        XCTAssertEqual(try ShapeSheetContext(page:page(with:pageNoTheme,pageScheme:0)).evaluate("THEMEVAL(\"Dark\")",on:pageNoTheme.id),.color(ShapeSheetColor(red:0,green:0,blue:0)))  // THEMEVALX-Dark

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
        XCTAssertEqual(try ShapeSheetContext(page:activePage).evaluate("THEMEVAL(\"Dark\",9)",on:inheritedActive.id),.color(ShapeSheetColor(red:17,green:17,blue:17)))
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
        var imported = try VisioFormat.read(from:fixture).diagram
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

        var themedShape = shape
        themedShape.formatting.sheet["ColorSchemeIndex"] = cell("33")
        themedShape.formatting.sheet["User.ThemeLum"] = cell("0","LUM(THEMEVAL(\"AccentColor1\"))")
        imported.page.nodes[0] = themedShape
        XCTAssertEqual(try ShapeSheetContext(page:imported.page).value(themedShape.id,"User.ThemeLum"),.number(143))
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
