import XCTest
@testable import MacVisio

final class LayerSettingsTests:XCTestCase {
    private var files:[URL] = []
    override func tearDown() { for file in files { try? FileManager.default.removeItem(at:file) };super.tearDown() }
    private func file() -> URL { let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-layer-\(UUID()).vsdx");files.append(url);return url }
    private func publicParts(_ url:URL) throws -> [String:Data] { var parts = try VisioPackage.read(url);parts.removeValue(forKey:"macvisio/document.json");return parts }
    private func layerRow(_ url:URL) throws -> XMLElement {
        let parts = try VisioPackage.read(url),index = try VisioXML.document(parts["visio/pages/pages.xml"]!)
        let layer = index.rootElement()?.firstLocal("Page")?.firstLocal("PageSheet")?.elementsLocal("Section").first{$0.attr("N") == "Layer"}
        return try XCTUnwrap(layer?.elementsLocal("Row").first)
    }

    func testSnapAndGlueSurviveEditedAndFreshPublicVSDXExports() throws {
        var diagram = Diagram()
        diagram.page.layers = [DiagramLayer(name:"Work",snap:true,glue:false,sheet:["User.Unknown":ShapeSheetCell(value:"7",formula:"1+6",unit:"IN")])]
        let source = file();try VisioFormat.write(diagram,to:source);try VisioPackage.write(publicParts(source),to:source)
        var imported = try VisioFormat.read(from:source).diagram
        XCTAssertTrue(imported.page.layers![0].snap);XCTAssertFalse(imported.page.layers![0].glue)
        XCTAssertEqual(imported.page.layers![0].sheet["User.Unknown"],ShapeSheetCell(value:"7",formula:"1+6",unit:"IN"))

        imported.page.layers![0].snap = false;imported.page.layers![0].glue = true
        for fresh in [false,true] {
            var output = imported;if fresh { output.visioArchive = nil }
            let url = file();try VisioFormat.write(output,to:url);try VisioPackage.write(publicParts(url),to:url)
            let row = try layerRow(url)
            XCTAssertEqual(VisioXML.value(row,"Snap"),"0");XCTAssertEqual(VisioXML.value(row,"Glue"),"1")
            let unknown = try XCTUnwrap(row.elementsLocal("Cell").first{$0.attr("N") == "User.Unknown"})
            XCTAssertEqual(unknown.attr("F"),"1+6");XCTAssertEqual(unknown.attr("U"),"IN")
            XCTAssertNil(try VisioPackage.read(url)["macvisio/document.json"])
            let publicImport = try VisioFormat.read(from:url).diagram
            XCTAssertFalse(publicImport.page.layers![0].snap);XCTAssertTrue(publicImport.page.layers![0].glue)
            XCTAssertEqual(publicImport.page.layers![0].sheet["User.Unknown"],ShapeSheetCell(value:"7",formula:"1+6",unit:"IN"))
        }
    }

    func testLayerColorAndTransparencySurvivePublicRoundTripAndOverrideSingleLayerShapes() throws {
        var diagram = Diagram()
        diagram.page.layers = [DiagramLayer(name:"Red",color:"#CC3300",colorTransparency:25),DiagramLayer(name:"Blue",color:"#0066CC")]
        var single = DiagramNode(x:100,y:100,text:"Single");single.layer = "Red";single.fill = "#00FF00";single.stroke = "#0000FF";single.textColor = "#000000"
        var multiple = DiagramNode(x:350,y:100,text:"Multiple");multiple.layer = "Red";multiple.formatting.layerNames = ["Blue"];multiple.fill = "#00FF00"
        diagram.page.nodes = [single,multiple]
        let initial = file();try VisioFormat.write(diagram,to:initial);try VisioPackage.write(publicParts(initial),to:initial)
        var imported = try VisioFormat.read(from:initial).diagram
        XCTAssertEqual(imported.page.layers?.first?.color,"#CC3300");XCTAssertEqual(imported.page.layers?.first?.colorTransparency ?? -1,25,accuracy:0.001)
        let svg = DiagramDrawing.svg(imported.page)
        XCTAssertTrue(svg.contains("#CC3300BF"),"Single-layer shape should use the layer color and transparency")
        XCTAssertTrue(svg.contains("fill=\"#00FF00\""),"A shape assigned to multiple layers should retain its own fill")

        var parts = try publicParts(initial)
        let index = try VisioXML.document(parts["visio/pages/pages.xml"]!),layer = index.rootElement()!.firstLocal("Page")!.firstLocal("PageSheet")!.elementsLocal("Section").first{$0.attr("N") == "Layer"}!,row = layer.elementsLocal("Row").first{$0.attr("IX") == "0"}!
        row.elementsLocal("Cell").first{$0.attr("N") == "Color"}?.setAttr("F","RGB(204,51,0)")
        row.elementsLocal("Cell").first{$0.attr("N") == "ColorTrans"}?.setAttr("F","0.25")
        parts["visio/pages/pages.xml"] = index.xmlData(options:.nodePreserveAll);try VisioPackage.write(parts,to:initial)
        imported = try VisioFormat.read(from:initial).diagram;imported.page.layers![0].visible = false
        let edited = file();try VisioFormat.write(imported,to:edited);try VisioPackage.write(publicParts(edited),to:edited)
        let editedRow = try layerRow(edited),colorCell = try XCTUnwrap(editedRow.elementsLocal("Cell").first{$0.attr("N") == "Color"}),transCell = try XCTUnwrap(editedRow.elementsLocal("Cell").first{$0.attr("N") == "ColorTrans"})
        XCTAssertEqual(colorCell.attr("F"),"RGB(204,51,0)");XCTAssertEqual(transCell.attr("F"),"0.25")

        let publicImport = try VisioFormat.read(from:edited).diagram
        var rows = [[String]]()
        for layer in publicImport.page.layers! {
            rows.append([layer.name,layer.visible ? "Yes" : "No",layer.locked ? "Yes" : "No",layer.printable ? "Yes" : "No",layer.snap ? "Yes" : "No",layer.glue ? "Yes" : "No",layer.name == "Red" ? "#3155AA" : (layer.color ?? ""),layer.name == "Red" ? "40" : String(layer.colorTransparency)])
        }
        var changedLayers = try LayerPropertiesEditing.apply(rows,previous:publicImport.page.layers!)
        changedLayers[0].visible = true
        XCTAssertEqual(changedLayers.first?.color,"#3155AA");XCTAssertEqual(changedLayers.first?.colorTransparency,40)
        var changed = publicImport;changed.page.layers = changedLayers
        XCTAssertTrue(DiagramDrawing.svg(changed.page).contains("#3155AA99"),"Edited layer properties should affect the drawing preview")
        let recolored = file();try VisioFormat.write(changed,to:recolored);try VisioPackage.write(publicParts(recolored),to:recolored)
        let recoloredRow = try layerRow(recolored),recoloredColor = try XCTUnwrap(recoloredRow.elementsLocal("Cell").first{$0.attr("N") == "Color"}),recoloredTrans = try XCTUnwrap(recoloredRow.elementsLocal("Cell").first{$0.attr("N") == "ColorTrans"})
        XCTAssertEqual(recoloredColor.attr("V"),"#3155AA");XCTAssertNil(recoloredColor.attr("F"))
        XCTAssertEqual(recoloredTrans.attr("V"),"0.4");XCTAssertNil(recoloredTrans.attr("F"))
        XCTAssertNil(try VisioPackage.read(recolored)["macvisio/document.json"])
        let finalImport = try VisioFormat.read(from:recolored).diagram
        XCTAssertEqual(finalImport.page.layers?.first?.color,"#3155AA");XCTAssertEqual(finalImport.page.layers?.first?.colorTransparency ?? -1,40,accuracy:0.001)
        XCTAssertThrowsError(try LayerPropertiesEditing.apply([["Bad","Yes","No","Yes","Yes","Yes","#GG0000","50"]],previous:[]))
        XCTAssertThrowsError(try LayerPropertiesEditing.apply([["Bad","Yes","No","Yes","Yes","Yes","#AA0000","101"]],previous:[]))
    }
}
