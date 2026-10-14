import Foundation
import XCTest
@testable import MacVisio

final class THEMEPROPTests:XCTestCase {
    private let selectors = ["ThemeIndex","ColorSchemeIndex","EffectSchemeIndex","ConnectorSchemeIndex","FontSchemeIndex"]

    private func cell(_ value:String,_ formula:String = "") -> ShapeSheetCell { ShapeSheetCell(value:value,formula:formula) }

    private func theme(schemeIndex:Int = 33,styleIndex:Int? = nil,colorIndex:Int? = nil) -> VisioTheme {
        VisioTheme(relationshipID:"rIdTheme",relationshipType:"http://schemas.microsoft.com/visio/2010/relationships/theme",
                   target:"../theme/theme1.xml",part:"visio/theme/theme1.xml",name:"Test",colorSchemeName:"Test",
                   schemeIndex:schemeIndex,colorScheme:[:],variationColorSchemes:[:],
                   variationColorSchemeMonotone:[0:true,1:false,2:true,3:false],
                   variationStyleSchemes:[0:VisioThemeVariationStyleScheme(embellishment:3,styles:[]),
                                          1:VisioThemeVariationStyleScheme(embellishment:6,styles:[]),
                                          2:VisioThemeVariationStyleScheme(embellishment:9,styles:[]),
                                          3:VisioThemeVariationStyleScheme(embellishment:11,styles:[])],
                   variationColorIndex:colorIndex,variationStyleIndex:styleIndex,values:[:],colors:[:])
    }

    private func activeShape(_ selectorValue:Int = 33) -> DiagramNode {
        var shape = DiagramNode(text:"THEMEPROP")
        for key in selectors { shape.formatting.sheet[key] = cell(String(selectorValue)) }
        return shape
    }

    private func page(with shape:DiagramNode,theme:VisioTheme? = nil,pageSelectors:[String:Int] = [:],pageValues:[String:Int] = [:]) -> DiagramPage {
        var page = DiagramPage();page.nodes = [shape];page.theme = theme
        var sheet = Dictionary(uniqueKeysWithValues:pageSelectors.map{($0.key,cell(String($0.value)))} )
        for (key,value) in pageValues { sheet[key] = cell(String(value)) }
        page.sheet = sheet
        return page
    }

    func testCaseInsensitiveEmbellishmentAndMultiFormatUseSelectedVariations() throws {
        var shape = activeShape()
        shape.formatting.sheet["EmbellishmentIndex"] = cell("0")
        shape.formatting.sheet["VariationStyleIndex"] = cell("1")
        shape.formatting.sheet["VariationColorIndex"] = cell("2")
        let context = ShapeSheetContext(page:page(with:shape,theme:theme()))

        XCTAssertEqual(try context.evaluate("themeprop(\"eMbElLiShMeNt\")",on:shape.id),.number(6))
        XCTAssertEqual(try context.evaluate("THEMEPROP(\"mUlTiFoRmAt\")",on:shape.id),.number(1))
    }

    func testExplicitAndPageInheritedEmbellishmentIndex() throws {
        var explicit = activeShape()
        explicit.formatting.sheet["EmbellishmentIndex"] = cell("7")
        XCTAssertEqual(try ShapeSheetContext(page:page(with:explicit,theme:theme())).evaluate("THEMEPROP(\"Embellishment\")",on:explicit.id),.number(7))

        var inherited = activeShape()
        inherited.formatting.sheet["EmbellishmentIndex"] = cell("65534")
        let parent = page(with:inherited,theme:theme(),pageSelectors:Dictionary(uniqueKeysWithValues:selectors.map{($0,33)}),pageValues:["EmbellishmentIndex":5])
        XCTAssertEqual(try ShapeSheetContext(page:parent).evaluate("THEMEPROP(\"Embellishment\")",on:inherited.id),.number(5))

        var inheritedVariantShape = inherited
        inheritedVariantShape.formatting.sheet["VariationStyleIndex"] = cell("65534")
        let inheritedVariant = page(with:inheritedVariantShape,theme:theme(),pageSelectors:Dictionary(uniqueKeysWithValues:selectors.map{($0,33)}),pageValues:["EmbellishmentIndex":0,"VariationStyleIndex":2])
        XCTAssertEqual(try ShapeSheetContext(page:inheritedVariant).evaluate("THEMEPROP(\"Embellishment\")",on:inheritedVariantShape.id),.number(9))

        var variant = activeShape()
        variant.formatting.sheet["EmbellishmentIndex"] = cell("0")
        variant.formatting.sheet["VariationStyleIndex"] = cell("65534")
        variant.formatting.sheet["VariationColorIndex"] = cell("65534")
        let selectedPage = page(with:variant,theme:theme(),pageSelectors:Dictionary(uniqueKeysWithValues:selectors.map{($0,33)}),pageValues:["VariationStyleIndex":2,"VariationColorIndex":1])
        let context = ShapeSheetContext(page:selectedPage)
        XCTAssertEqual(try context.evaluate("THEMEPROP(\"Embellishment\")",on:variant.id),.number(9))
        XCTAssertEqual(try context.evaluate("THEMEPROP(\"MultiFormat\")",on:variant.id),.number(0))
    }

    func testAnyNoThemeComponentSelectorReturnsZero() throws {
        for key in selectors {
            var shape = activeShape()
            shape.formatting.sheet[key] = cell("0")
            let context = ShapeSheetContext(page:page(with:shape))
            XCTAssertEqual(try context.evaluate("THEMEPROP(\"Embellishment\")",on:shape.id),.number(0),key)
            XCTAssertEqual(try context.evaluate("THEMEPROP(\"MultiFormat\")",on:shape.id),.number(0),key)
        }

        let inherited = activeShape(65534)
        let selectedPage = page(with:inherited,pageSelectors:["ThemeIndex":33,"ColorSchemeIndex":0,"EffectSchemeIndex":33,"ConnectorSchemeIndex":33,"FontSchemeIndex":33])
        XCTAssertEqual(try ShapeSheetContext(page:selectedPage).evaluate("THEMEPROP(\"MultiFormat\")",on:inherited.id),.number(0))

        var inheritedActive = activeShape(65534)
        inheritedActive.formatting.sheet["EmbellishmentIndex"] = cell("4")
        let activePage = page(with:inheritedActive,theme:theme(),pageSelectors:Dictionary(uniqueKeysWithValues:selectors.map{($0,33)}))
        XCTAssertEqual(try ShapeSheetContext(page:activePage).evaluate("THEMEPROP(\"Embellishment\")",on:inheritedActive.id),.number(4))
    }

    func testUnavailableSelectorsVariationsAndArgumentsRemainErrors() throws {
        var missingSelector = DiagramNode(text:"Missing selector")
        missingSelector.formatting.sheet["ColorSchemeIndex"] = cell("33")
        let missingContext = ShapeSheetContext(page:page(with:missingSelector,theme:theme()))
        XCTAssertThrowsError(try missingContext.evaluate("THEMEPROP(\"Embellishment\")",on:missingSelector.id)) { error in
            XCTAssertTrue(error.localizedDescription.contains("selectors are missing or unresolved"),error.localizedDescription)
        }

        var missingVariation = activeShape()
        missingVariation.formatting.sheet["EmbellishmentIndex"] = cell("0")
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:missingVariation,theme:theme(styleIndex:9))).evaluate("THEMEPROP(\"Embellishment\")",on:missingVariation.id))
        let withoutTheme = activeShape()
        XCTAssertThrowsError(try ShapeSheetContext(page:page(with:withoutTheme,theme:nil)).evaluate("THEMEPROP(\"Embellishment\")",on:withoutTheme.id))
        XCTAssertThrowsError(try missingContext.evaluate("THEMEPROP(\"other\")",on:missingSelector.id))
        XCTAssertThrowsError(try missingContext.evaluate("THEMEPROP(\"Embellishment\",1)",on:missingSelector.id))
    }

    func testUnavailableThemePropKeepsCachedValue() {
        var shape = DiagramNode(text:"Cached THEMEPROP")
        shape.formatting.sheet["ThemeIndex"] = cell("33")
        shape.formatting.sheet["ColorSchemeIndex"] = cell("33")
        shape.formatting.sheet["User.ThemeProp"] = cell("42","THEMEPROP(\"MultiFormat\")")
        var diagram = Diagram();diagram.page.nodes = [shape];diagram.page.theme = theme()

        let result = ShapeSheetEngine.recalculate(diagram)
        XCTAssertEqual(result.diagram.page.nodes[0].formatting.sheet["User.ThemeProp"]?.value,"42")
        XCTAssertTrue(result.issues.contains{$0.localizedCaseInsensitiveContains("THEMEPROP")},result.issues.joined(separator:"\n"))
    }

    func testImportedThemeMetadataResolvesRealVariationEntries() throws {
        let fixture = URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/blue-box.vsdx")
        let imported = try VisioFormat.read(from:fixture).diagram
        var shape = try XCTUnwrap(imported.page.nodes.first)
        for key in selectors { shape.formatting.sheet[key] = cell("33") }
        shape.formatting.sheet["EmbellishmentIndex"] = cell("0")
        shape.formatting.sheet["VariationStyleIndex"] = cell("0")
        shape.formatting.sheet["VariationColorIndex"] = cell("0")
        let importedTheme = try XCTUnwrap(imported.page.theme)
        let expectedEmbellishment = Double(try XCTUnwrap(importedTheme.variationStyleSchemes[0]?.embellishment))
        let expectedMultiFormat = (try XCTUnwrap(importedTheme.variationColorSchemeMonotone[0])) ? 1.0 : 0.0
        let context = ShapeSheetContext(page:page(with:shape,theme:importedTheme))

        XCTAssertEqual(try context.evaluate("THEMEPROP(\"Embellishment\")",on:shape.id),.number(expectedEmbellishment))
        XCTAssertEqual(try context.evaluate("THEMEPROP(\"MultiFormat\")",on:shape.id),.number(expectedMultiFormat))
    }
}
