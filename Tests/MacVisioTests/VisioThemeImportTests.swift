import XCTest
@testable import MacVisio

final class VisioThemeImportTests:XCTestCase {
    private func fixture(_ name:String = "blue-box.vsdx") -> URL {
        URL(fileURLWithPath:#filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    }

    func testRealVSDXImportsSelectedOfficeThemeAndVisioColorScheme() throws {
        let diagram = try VisioFormat.read(from:fixture()).diagram
        let theme = try XCTUnwrap(diagram.visioArchive?.theme)

        XCTAssertEqual(theme.relationshipID,"rId4")
        XCTAssertEqual(theme.relationshipType,"http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme")
        XCTAssertEqual(theme.target,"theme/theme1.xml")
        XCTAssertEqual(theme.part,"visio/theme/theme1.xml")
        XCTAssertEqual(theme.name,"Office 2016")
        XCTAssertEqual(theme.colorSchemeName,"Office 2016")
        XCTAssertEqual(theme.schemeIndex,33)
        XCTAssertEqual(theme.effectSchemeIndex,33)
        XCTAssertEqual(theme.connectorSchemeIndex,33)
        XCTAssertEqual(theme.effectLineStyles.count,6)
        XCTAssertEqual(theme.connectorLineStyles.count,3)
        XCTAssertEqual(theme.effectLineStyles[3],VisioThemeLineStyle(widthEMU:3175,cap:"sq"))
        XCTAssertEqual(theme.connectorLineStyles[0],VisioThemeLineStyle(widthEMU:12700,cap:"rnd"))
        XCTAssertEqual(theme.effectLineExtensions.count,7)
        XCTAssertEqual(theme.connectorLineExtensions.count,4)
        XCTAssertEqual(theme.connectorLineExtensions[1],VisioThemeLineExtension(roundingEMU:0,beginArrow:0,beginSize:2,endArrow:4,endSize:2))
        XCTAssertEqual(theme.colors["Dark"],"#000000")
        XCTAssertEqual(theme.colors["Light"],"#FEFFFF")
        XCTAssertEqual(theme.colors["BackgroundColor"],"#FFFFFF")
        XCTAssertEqual(theme.colors["AccentColor1"],"#5B9BD5")
        XCTAssertEqual(theme.colors["AccentColor6"],"#70AD47")
        XCTAssertEqual(theme.colorScheme["accent1"],VisioThemeColor(type:"srgbClr",value:"5B9BD5",lastColor:nil))
        XCTAssertEqual(theme.variationColorSchemes.count,4)
        XCTAssertEqual(theme.variationColorSchemes[2]?["VariantColor1"],"#45B664")
        XCTAssertEqual(theme.variationColorSchemes[2]?["VariantColor4"],"#70AD47")
        XCTAssertEqual(theme.variationColorSchemeMonotone[0],true)
        XCTAssertEqual(theme.variationColorSchemeMonotone[1],false)
        XCTAssertEqual(theme.variationStyleSchemes[2]?.embellishment,3)
        XCTAssertEqual(theme.variationStyleSchemes[2]?.styles.first,VisioThemeVariationStyle(fillIndex:6,lineIndex:6,effectIndex:6,fontIndex:6))
        XCTAssertTrue(theme.values.isEmpty,"The fixture's Theme StyleSheet contains THEMEVAL() placeholders, not mapped results.")

        let pageTheme = try XCTUnwrap(diagram.page.theme)
        XCTAssertEqual(pageTheme.part,theme.part)
        XCTAssertEqual(pageTheme.colorScheme,theme.colorScheme)
        XCTAssertNil(pageTheme.variationColorIndex)
        XCTAssertEqual(pageTheme.colors["VariantColor1"],"#5B9BD5")
        XCTAssertEqual(pageTheme.colors["VariantColor4"],"#BDD0E9")
        XCTAssertEqual(diagram.page.sheet?["ThemeIndex"]?.value,"33")
        XCTAssertEqual(diagram.page.sheet?["ColorSchemeIndex"]?.value,"33")
    }

    func testRealVSDXPageSelectsVariationColorAndStyleSchemes() throws {
        let diagram = try VisioFormat.read(from:fixture("testfile1.vsdx")).diagram
        let theme = try XCTUnwrap(diagram.page.theme)

        XCTAssertEqual(diagram.page.sheet?["VariationColorIndex"]?.value,"2")
        XCTAssertEqual(diagram.page.sheet?["VariationStyleIndex"]?.value,"2")
        XCTAssertEqual(theme.variationColorIndex,2)
        XCTAssertEqual(theme.variationStyleIndex,2)
        XCTAssertEqual(theme.colors["VariantColor1"],"#45B664")
        XCTAssertEqual(theme.colors["VariantColor4"],"#70AD47")
        XCTAssertEqual(theme.variationStyleSchemes[0]?.embellishment,2)
        XCTAssertEqual(theme.variationStyleSchemes[1]?.embellishment,1)
        XCTAssertEqual(theme.variationStyleSchemes[2]?.embellishment,3)
        XCTAssertEqual(theme.variationStyleSchemes[3]?.embellishment,2)
    }

    func testNativeDocumentsFromBeforeLineThemeMetadataStillDecode() throws {
        let diagram = try VisioFormat.read(from:fixture()).diagram
        let addedKeys = Set(["effectSchemeIndex","connectorSchemeIndex","effectLineStyles","connectorLineStyles","effectLineExtensions","connectorLineExtensions"])
        func olderMetadata(_ value:Any) -> Any {
            if let dictionary = value as? [String:Any] {
                let isTheme = dictionary["relationshipID"] != nil && dictionary["colorScheme"] != nil
                return dictionary.filter { !isTheme || !addedKeys.contains($0.key) }.mapValues(olderMetadata)
            }
            if let array = value as? [Any] { return array.map(olderMetadata) }
            return value
        }
        let current = try JSONEncoder().encode(diagram)
        let old = olderMetadata(try JSONSerialization.jsonObject(with:current))
        let restored = try JSONDecoder().decode(Diagram.self,from:JSONSerialization.data(withJSONObject:old))
        let theme = try XCTUnwrap(restored.page.theme)
        XCTAssertEqual(theme.colors,diagram.page.theme?.colors)
        XCTAssertTrue(theme.effectLineStyles.isEmpty)
        XCTAssertTrue(theme.connectorLineExtensions.isEmpty)
        XCTAssertNil(theme.effectSchemeIndex)
        XCTAssertNotNil(restored.visioArchive?.theme)
        XCTAssertEqual(try JSONDecoder().decode(Diagram.self,from:JSONEncoder().encode(diagram)),diagram)
    }

    func testRealVSDXThemeMetadataDoesNotChangePackageRoundTrip() throws {
        let source = fixture(),destination = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-theme-\(UUID()).vsdx")
        defer { try? FileManager.default.removeItem(at:destination) }
        let before = try VisioPackage.read(source)
        let diagram = try VisioFormat.read(from:source).diagram

        try VisioFormat.write(diagram,to:destination)

        XCTAssertEqual(try VisioPackage.read(destination),before)
    }
}
