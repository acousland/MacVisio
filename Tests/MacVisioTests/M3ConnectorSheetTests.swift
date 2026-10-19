import AppKit
import XCTest
@testable import MacVisio

/// Local public interchange regressions; these are not reference-Visio acceptance.
final class M3ConnectorSheetTests: XCTestCase {
    private var files:[URL] = []
    override func tearDown() { for file in files { try? FileManager.default.removeItem(at:file) };super.tearDown() }
    private func file() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-M3-connectors-\(UUID()).vsdx")
        files.append(url);return url
    }
    private func fixture(inherited:Bool = false) throws -> (Diagram,URL) {
        let source = try XCTUnwrap(Bundle.module.url(forResource:"m3-intelligent",withExtension:"vsdx",subdirectory:"Fixtures/M3"))
        var parts = try VisioPackage.read(source)
        let document = try VisioXML.document(XCTUnwrap(parts["visio/document.xml"]))
        let faces = try XCTUnwrap(document.rootElement()?.firstLocal("FaceNames"))
        faces.addChild(try VisioXML.element("<FaceName NameU=\"Courier New\"/>"))
        parts["visio/document.xml"] = document.xmlData(options:.nodePreserveAll)
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        let shapes = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes"))
        let connector = try XCTUnwrap(shapes.allShapes.first{$0.attr("ID") == "30"})
        let payload = try VisioXML.element("""
        <Shape>
        <Cell N="Comment" V="Connector source" F="&quot;Connector source&quot;" U="STR"/>
        <Section N="Property"><Row N="Cost"><Cell N="Label" V="Cost"/><Cell N="Value" V="5" F="GUARD(5)" U="NO"/><Cell N="Type" V="2"/><Cell N="Prompt" V="Keep this prompt"/><Cell N="Invisible" V="1"/></Row><Row N="Owner"><Cell N="Label" V="Owner"/><Cell N="Value" V="Initial"/><Cell N="Prompt" V="Owner prompt"/></Row></Section>
        <Section N="Hyperlink"><Row N="Docs"><Cell N="Address" V="https://example.test/connector"/><Cell N="Description" V="Docs"/><Cell N="NewWindow" V="1"/></Row></Section>
        <Section N="Character"><Row IX="3"><Cell N="Font" V="0"/><Cell N="Size" V="0.1388888888888889" F="GUARD(10pt)" U="PT"/><Cell N="Color" V="#123456"/><Cell N="LangID" V="1033"/></Row><Row IX="9"><Cell N="Font" V="1"/><Cell N="Size" V="0.25"/><Cell N="Color" V="#654321"/><Cell N="Style" V="2"/><Cell N="LangID" V="1041"/></Row></Section>
        <Section N="Paragraph"><Row IX="4"><Cell N="HorzAlign" V="0"/><Cell N="IndLeft" V="0.125" F="GUARD(0.125 in)" U="IN"/></Row><Row IX="7"><Cell N="HorzAlign" V="2"/><Cell N="SpAfter" V="0.05"/></Row></Section>
        <Section N="Field"><Row IX="7"><Cell N="Value" V="5" F="Prop.Cost"/><Cell N="Format" V="0.0" U="STR"/><Cell N="Type" V="0"/></Row></Section>
        <Text><cp IX="3"/><pp IX="4"/>Link <fld IX="7">5.0</fld><cp IX="9"/><pp IX="7"/> 東京</Text>
        <OpaqueConnectorFlag Keep="yes"/>
        </Shape>
        """)
        for child in connector.children ?? [] {
            if let element = child as? XMLElement,element.localTag == "Text" || element.localTag == "Section" && ["Character","Paragraph"].contains(element.attr("N") ?? "") { element.detach() }
        }
        if inherited {
            connector.setAttr("Master","7")
            let master = try VisioXML.document(XCTUnwrap(parts["visio/masters/master1.xml"]))
            let prototype = try XCTUnwrap(master.rootElement()?.firstLocal("Shapes")?.allShapes.first)
            for child in prototype.children ?? [] {
                if let element = child as? XMLElement,element.localTag == "Text" || element.localTag == "Section" && element.attr("N") == "Property" { element.detach() }
            }
            for child in payload.children ?? [] { prototype.addChild(child.copy() as! XMLNode) }
            parts["visio/masters/master1.xml"] = master.xmlData(options:.nodePreserveAll)
        } else {
            for child in payload.children ?? [] { connector.addChild(child.copy() as! XMLNode) }
        }
        let untouched = connector.copy() as! XMLElement
        untouched.setAttr("ID","31");untouched.setAttr("NameU","Untouched connector")
        shapes.addChild(untouched)
        parts["visio/pages/page1.xml"] = page.xmlData(options:.nodePreserveAll)
        let url = file();try VisioPackage.write(parts,to:url)
        return (try VisioFormat.read(from:url).diagram,url)
    }
    private func connector(_ diagram:Diagram,_ source:String = "30") throws -> DiagramEdge {
        try XCTUnwrap(diagram.pages[0].edges.first{$0.sourceShapeID == source})
    }
    private func publicRead(_ url:URL) throws -> Diagram {
        try VisioFormat.readPublic(parts:VisioPackage.read(url),title:"Public connector check").diagram
    }
    private func shape(_ parts:[String:Data],_ source:String = "30") throws -> XMLElement {
        try XCTUnwrap(VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"])).rootElement()?.firstLocal("Shapes")?.allShapes.first{$0.attr("ID") == source})
    }
    private func row(_ element:XMLElement,_ section:String,_ index:String) throws -> XMLElement {
        try XCTUnwrap(element.elementsLocal("Section").first{$0.attr("N") == section}?.elementsLocal("Row").first{$0.attr("IX") == index || $0.attr("N") == index})
    }

    func testPublicImportRetainsConnectorCellsSparseRunsFieldsAndNoEditBytes() throws {
        let (diagram,source) = try fixture(),edge = try connector(diagram)
        XCTAssertEqual(edge.formatting.sourceShapeID,"30");XCTAssertNil(edge.parentID)
        XCTAssertEqual(edge.label,"Link 5.0 東京")
        XCTAssertEqual(edge.formatting.sheet["User.Weight"]?.formula,"Sheet.10!Width+Sheet.20!Width")
        XCTAssertEqual(edge.formatting.sheet["Comment"]?.formula,"\"Connector source\"")
        XCTAssertEqual(edge.formatting.sheet["Prop.Cost"]?.unit,"NO")
        XCTAssertEqual(edge.formatting.sheet["Prop.Cost.Invisible"]?.value,"1")
        XCTAssertEqual(edge.formatting.data.first{$0.key == "Cost"}?.prompt,"Keep this prompt")
        XCTAssertEqual(edge.formatting.hyperlinks.first?.sourceRowName,"Docs")
        let runs = try XCTUnwrap(edge.formatting.textRuns)
        XCTAssertEqual(runs.map(\.text).joined(),edge.label)
        XCTAssertEqual(runs.first?.character.sourceIndex,3);XCTAssertEqual(runs.last?.character.sourceIndex,9)
        XCTAssertEqual(runs.first?.paragraph.sourceIndex,4);XCTAssertEqual(runs.last?.paragraph.sourceIndex,7)
        XCTAssertEqual(runs.first?.character.cells["Size"]?.formula,"GUARD(10pt)")
        XCTAssertEqual(runs.last?.character.fontName,"Courier New");XCTAssertTrue(runs.last?.character.italic == true)
        XCTAssertEqual(runs.first{$0.fieldIndex != nil}?.fieldIndex,7)
        XCTAssertEqual(edge.formatting.textFields?.first?.cells["Value"]?.formula,"Prop.Cost")
        let out = file();try VisioFormat.write(diagram,to:out)
        XCTAssertEqual(try VisioPackage.read(out),try VisioPackage.read(source))
    }

    func testPlainLabelEditSynchronizesRunsWithoutChangingOtherConnectorOrSourceCells() throws {
        var (diagram,source) = try fixture();let original = try connector(diagram),before = try VisioPackage.read(source)
        let index = try XCTUnwrap(diagram.pages[0].edges.firstIndex{$0.id == original.id})
        diagram.pages[0].edges[index].label = "Edited Link 5.0 東京"
        XCTAssertEqual(diagram.pages[0].edges[index].formatting.textRuns?.map(\.text).joined(),"Edited Link 5.0 東京")
        let out = file();try VisioFormat.write(diagram,to:out);let after = try VisioPackage.read(out),reopened = try connector(publicRead(out))
        XCTAssertEqual(reopened.label,"Edited Link 5.0 東京")
        XCTAssertEqual(reopened.formatting.textFields?.first?.cells["Value"]?.formula,"Prop.Cost")
        XCTAssertEqual(try shape(before,"31").xmlString,try shape(after,"31").xmlString)
        XCTAssertEqual(try row(shape(before),"Character","9").xmlString,try row(shape(after),"Character","9").xmlString)
        XCTAssertEqual(try row(shape(before),"Paragraph","4").xmlString,try row(shape(after),"Paragraph","4").xmlString)
        XCTAssertEqual(try shape(after).firstLocal("OpaqueConnectorFlag")?.attr("Keep"),"yes")
        XCTAssertEqual(before["visio/masters/master1.xml"],after["visio/masters/master1.xml"])
    }

    func testSelectedRunAndPropertyChangesPatchPublicCellsAndRetainUnrelatedPayload() throws {
        var (diagram,source) = try fixture();let index = try XCTUnwrap(diagram.pages[0].edges.firstIndex{$0.sourceShapeID == "30"})
        let before = try VisioPackage.read(source),original = diagram.pages[0].edges[index]
        let owner = try XCTUnwrap(diagram.pages[0].edges[index].formatting.data.firstIndex{$0.key == "Owner"})
        diagram.pages[0].edges[index].formatting.data[owner].value = "Changed owner"
        diagram.pages[0].edges[index].formatting.hyperlinks[0].description = "Changed docs"
        diagram.pages[0].edges[index].formatting.sheet["User.Weight"] = ShapeSheetCell(value:"8",formula:"Sheet.10!Width+6 in",unit:"IN")
        diagram.pages[0].edges[index].formatting.sheet["Prop.Cost.Prompt"] = ShapeSheetCell(value:"New prompt",unit:"STR")
        let selected = try XCTUnwrap(diagram.pages[0].edges[index].formatting.textRuns?.firstIndex{$0.text.contains("東京")})
        diagram.pages[0].edges[index].formatting.textRuns![selected].character.size = 24
        diagram.pages[0].edges[index].formatting.textRuns![selected].character.fontName = "Georgia"
        let out = file();try VisioFormat.write(diagram,to:out);let after = try VisioPackage.read(out),reopened = try connector(publicRead(out))
        XCTAssertEqual(reopened.formatting.data.first{$0.key == "Owner"}?.value,"Changed owner")
        XCTAssertEqual(reopened.formatting.data.first{$0.key == "Cost"}?.prompt,"New prompt")
        XCTAssertEqual(reopened.formatting.sheet["Prop.Cost"]?.formula,"GUARD(5)")
        XCTAssertEqual(reopened.formatting.sheet["User.Weight"]?.formula,"Sheet.10!Width+6 in")
        XCTAssertEqual(reopened.formatting.hyperlinks.first?.description,"Changed docs")
        let changed = try XCTUnwrap(reopened.formatting.textRuns?.first{$0.text.contains("東京")})
        XCTAssertEqual(changed.character.size,24,accuracy:1e-8);XCTAssertEqual(changed.character.fontName,"Georgia")
        XCTAssertEqual(changed.character.cells["LangID"]?.value,"1041")
        XCTAssertEqual(try row(shape(before),"Character","3").xmlString,try row(shape(after),"Character","3").xmlString)
        XCTAssertEqual(try row(shape(before),"Field","7").xmlString,try row(shape(after),"Field","7").xmlString)
        XCTAssertEqual(try row(shape(after),"Hyperlink","Docs").elementsLocal("Cell").first{$0.attr("N") == "NewWindow"}?.attr("V"),"1")
        XCTAssertEqual(try shape(before,"31").xmlString,try shape(after,"31").xmlString)
        let native = try connector(VisioFormat.read(from:out).diagram)
        XCTAssertEqual(native.id,original.id);XCTAssertEqual(native.formatting.sheet["Prop.Owner"]?.value,"Changed owner")
        XCTAssertEqual(native.formatting.data.first{$0.key == "Cost"}?.prompt,"New prompt")
    }

    func testFreshPublicExportRetainsConnectorDetailsWithoutPrivateMetadata() throws {
        var (diagram,_) = try fixture();diagram.visioArchive = nil;diagram.definitions = nil
        let out = file();try VisioFormat.write(diagram,to:out);let edge = try connector(publicRead(out))
        XCTAssertEqual(edge.label,"Link 5.0 東京")
        XCTAssertEqual(edge.formatting.sheet["User.Weight"]?.formula,"Sheet.10!Width+Sheet.20!Width")
        XCTAssertEqual(edge.formatting.textFields?.first?.cells["Value"]?.formula,"Prop.Cost")
        XCTAssertEqual(edge.formatting.textRuns?.last?.character.fontName,"Courier New")
        XCTAssertEqual(edge.formatting.data.first{$0.key == "Cost"}?.value,"5")
    }

    func testInheritedConnectorEditDoesNotMaterializeUntouchedTextOrPropertyRows() throws {
        var (diagram,source) = try fixture(inherited:true);let before = try VisioPackage.read(source)
        let index = try XCTUnwrap(diagram.pages[0].edges.firstIndex{$0.sourceShapeID == "30"})
        XCTAssertEqual(diagram.pages[0].edges[index].formatting.sheet["User.Span"]?.formula,"Width")
        let owner = try XCTUnwrap(diagram.pages[0].edges[index].formatting.data.firstIndex{$0.key == "Owner"})
        diagram.pages[0].edges[index].formatting.data[owner].value = "Local owner"
        diagram.pages[0].edges[index].label = "Edited Link 5.0 東京"
        let out = file();try VisioFormat.write(diagram,to:out);let after = try VisioPackage.read(out),local = try shape(after)
        XCTAssertEqual(local.attr("Master"),"7")
        XCTAssertNil(local.elementsLocal("Section").first{$0.attr("N") == "Character"})
        XCTAssertNil(local.elementsLocal("Section").first{$0.attr("N") == "Paragraph"})
        XCTAssertNil(local.elementsLocal("Section").first{$0.attr("N") == "Field"})
        let properties = try XCTUnwrap(local.elementsLocal("Section").first{$0.attr("N") == "Property"})
        XCTAssertEqual(properties.elementsLocal("Row").map{$0.attr("N")},["Owner"])
        XCTAssertEqual(properties.elementsLocal("Row").first?.elementsLocal("Cell").map{$0.attr("N")},["Value"])
        XCTAssertEqual(before["visio/masters/master1.xml"],after["visio/masters/master1.xml"])
        XCTAssertEqual(try shape(before,"31").xmlString,try shape(after,"31").xmlString)
        let reopened = try connector(publicRead(out))
        XCTAssertEqual(reopened.label,"Edited Link 5.0 東京")
        XCTAssertEqual(reopened.formatting.data.first{$0.key == "Owner"}?.value,"Local owner")
        XCTAssertEqual(reopened.formatting.sheet["Prop.Cost"]?.formula,"GUARD(5)")
        XCTAssertEqual(reopened.formatting.textRuns?.last?.character.sourceIndex,9)
    }

    func testConnectorFieldEditAndInheritedDataDeletionRemainPublicDeltas() throws {
        var (diagram,source) = try fixture(inherited:true)
        let index = try XCTUnwrap(diagram.pages[0].edges.firstIndex{$0.sourceShapeID == "30"})
        diagram.pages[0].edges[index].formatting.textFields![0].cells["Format"] = ShapeSheetCell(value:"0.00",unit:"STR")
        diagram.pages[0].edges[index].formatting.data.removeAll{$0.key == "Owner"}
        diagram.pages[0].edges[index].formatting.hyperlinks.removeAll()
        let out = file();try VisioFormat.write(diagram,to:out)
        let parts = try VisioPackage.read(out),local = try shape(parts),reopened = try connector(publicRead(out))
        let field = try row(local,"Field","7")
        XCTAssertEqual(field.elementsLocal("Cell").map{$0.attr("N")},["Format"])
        XCTAssertEqual(VisioXML.value(field,"Format"),"0.00")
        XCTAssertEqual(reopened.formatting.textFields?.first?.cells["Value"]?.formula,"Prop.Cost")
        XCTAssertEqual(reopened.formatting.textFields?.first?.cells["Format"]?.value,"0.00")
        XCTAssertFalse(reopened.formatting.data.contains{$0.key == "Owner"});XCTAssertTrue(reopened.formatting.hyperlinks.isEmpty)
        XCTAssertEqual(try row(local,"Property","Owner").attr("Del"),"1")
        XCTAssertEqual(try row(local,"Hyperlink","Docs").attr("Del"),"1")
        XCTAssertEqual(parts["visio/masters/master1.xml"],try VisioPackage.read(source)["visio/masters/master1.xml"])
    }

    func testImplicitGroupedConnectorRetainsParentIdentityAndRemapsInheritedCellAndFieldReferences() throws {
        let (_,source) = try fixture();var parts = try VisioPackage.read(source)
        parts["visio/masters/master1.xml"] = Data("""
        <MasterContents xmlns="http://schemas.microsoft.com/office/visio/2012/main"><Shapes>
        <Shape ID="1" Type="Group"><Cell N="PinX" V="1"/><Cell N="PinY" V="0.5"/><Cell N="Width" V="2"/><Cell N="Height" V="1"/><Cell N="LocPinX" V="1"/><Cell N="LocPinY" V="0.5"/><Shapes>
        <Shape ID="2"><Cell N="PinX" V="0.5"/><Cell N="PinY" V="0.5"/><Cell N="Width" V="0.5"/><Cell N="Height" V="0.5"/><Cell N="LocPinX" V="0.25"/><Cell N="LocPinY" V="0.25"/><Text>Child</Text></Shape>
        <Shape ID="3"><Cell N="OneD" V="1"/><Cell N="BeginX" V="0.5"/><Cell N="BeginY" V="0.5"/><Cell N="EndX" V="1.5"/><Cell N="EndY" V="0.5"/><Section N="User"><Row N="Peer"><Cell N="Value" V="0.5" F="Sheet.2!Width"/></Row></Section><Section N="Field"><Row IX="2"><Cell N="Value" V="0.5" F="Sheet.2!Width"/><Cell N="Format" V="0.0"/></Row></Section><Text>Width <fld IX="2">0.5</fld></Text></Shape>
        </Shapes></Shape></Shapes><Connects><Connect FromSheet="3" FromCell="BeginX" ToSheet="2" ToCell="PinX"/></Connects></MasterContents>
        """.utf8)
        let input = file();try VisioPackage.write(parts,to:input)
        var diagram = try VisioFormat.read(from:input).diagram
        let parent = try XCTUnwrap(diagram.pages[0].nodes.first{$0.formatting.sourceShapeID == "10"})
        let child = try XCTUnwrap(diagram.pages[0].nodes.first{$0.parentID == parent.id})
        let index = try XCTUnwrap(diagram.pages[0].edges.firstIndex{$0.parentID == parent.id})
        let edge = diagram.pages[0].edges[index],sourceID = try XCTUnwrap(edge.sourceShapeID)
        let childSource = try XCTUnwrap(child.formatting.sourceShapeID)
        XCTAssertEqual(edge.formatting.sourceShapeID,sourceID);XCTAssertEqual(edge.source,child.id)
        XCTAssertEqual(edge.formatting.sheet["User.Peer"]?.formula,"Sheet.\(childSource)!Width")
        XCTAssertEqual(edge.formatting.textFields?.first?.cells["Value"]?.formula,"Sheet.\(childSource)!Width")
        diagram.pages[0].edges[index].formatting.sheet["User.Peer"] = ShapeSheetCell(value:"1",formula:"2*Sheet.\(childSource)!Width")
        let out = file();try VisioFormat.write(diagram,to:out)
        let written = try VisioPackage.read(out),local = try shape(written,sourceID)
        XCTAssertEqual(local.attr("MasterShape"),"3")
        XCTAssertEqual(try shape(written,childSource).attr("MasterShape"),"2","A new local formula target needs a real public instance shell.")
        XCTAssertNil(local.firstLocal("Text"));XCTAssertNil(local.elementsLocal("Section").first{$0.attr("N") == "Field"})
        XCTAssertEqual(written["visio/masters/master1.xml"],parts["visio/masters/master1.xml"])
        let reopened = try publicRead(out),projected = try XCTUnwrap(reopened.pages[0].edges.first{$0.sourceShapeID == sourceID})
        XCTAssertNotNil(projected.parentID);XCTAssertEqual(projected.label,edge.label)
        XCTAssertEqual(projected.sourcePosition,edge.sourcePosition);XCTAssertEqual(projected.targetPosition,edge.targetPosition)
        XCTAssertEqual(projected.formatting.sheet["User.Peer"]?.formula,"2*Sheet.\(childSource)!Width")
    }

    private func removeConnectorDetails(_ object:Any) -> Any {
        if var dictionary = object as? [String:Any] {
            for (key,value) in dictionary {
                if key == "edges",let edges = value as? [[String:Any]] {
                    dictionary[key] = edges.map{edge in var copy = edge;copy.removeValue(forKey:"details");return copy}
                } else { dictionary[key] = removeConnectorDetails(value) }
            };return dictionary
        }
        if let array = object as? [Any] { return array.map(removeConnectorDetails) }
        return object
    }
    func testOldNativeCacheAndSourceDrawingHydrateDetailsWithoutChangingNativeIdentity() throws {
        var (diagram,_) = try fixture();diagram.pages[0].edges[0].label = "Cached Link 5.0 東京"
        let out = file();try VisioFormat.write(diagram,to:out)
        let expected = try connector(VisioFormat.read(from:out).diagram)
        var parts = try VisioPackage.read(out)
        var envelope = try XCTUnwrap(removeConnectorDetails(JSONSerialization.jsonObject(with:XCTUnwrap(parts["macvisio/document.json"]))) as? [String:Any])
        envelope.removeValue(forKey:"connectorDetailsVersion")
        parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:envelope)
        try VisioPackage.write(parts,to:out)
        let imported = try VisioFormat.read(from:out),edge = try connector(imported.diagram)
        XCTAssertEqual(edge.id,expected.id);XCTAssertEqual(edge.label,expected.label)
        XCTAssertEqual(edge.parentID,expected.parentID);XCTAssertEqual(edge.sourcePosition,expected.sourcePosition)
        XCTAssertEqual(edge.formatting.sheet["User.Weight"]?.formula,"Sheet.10!Width+Sheet.20!Width")
        XCTAssertEqual(edge.formatting.textRuns?.map(\.text).joined(),edge.label)
        XCTAssertTrue(imported.warnings.contains{$0.contains("public connector details were hydrated")})
        XCTAssertNotNil(imported.diagram.visioArchive?.pages.first?.original.edges.first?.details)
        let nativeJSON = try JSONSerialization.jsonObject(with:JSONEncoder().encode(imported.diagram))
        let older = try JSONDecoder().decode(Diagram.self,from:JSONSerialization.data(withJSONObject:removeConnectorDetails(nativeJSON)))
        let migrated = try connector(older.validated())
        XCTAssertEqual(migrated.id,edge.id);XCTAssertEqual(migrated.label,edge.label)
        XCTAssertEqual(migrated.formatting.textFields?.first?.cells["Value"]?.formula,"Prop.Cost")
    }

    func testCurrentNativeDefaultConnectorRetainsNilDetailsAndExactDrawing() throws {
        var diagram = Diagram()
        let first = DiagramNode(x:100,y:100),second = DiagramNode(x:400,y:100)
        diagram.pages[0].nodes = [first,second]
        diagram.pages[0].edges = [DiagramEdge(source:first.id,target:second.id,label:"Plain")]
        let out = file(),archive = try VisioFormat.writeRebased(diagram,to:out)
        XCTAssertEqual(try VisioFormat.read(from:out).diagram.pages,diagram.pages)
        diagram.visioArchive = archive
        let installed = try diagram.validated()
        XCTAssertNil(installed.pages[0].edges[0].details)
        XCTAssertNil(installed.visioArchive?.pages[0].original.edges[0].details)
    }

    func testConnectorDetailsValidationAndBackwardOptionalDecode() throws {
        var (diagram,_) = try fixture();diagram.visioArchive = nil
        let index = try XCTUnwrap(diagram.pages[0].edges.firstIndex{$0.sourceShapeID == "30"})
        var invalid = diagram;invalid.pages[0].edges[index].formatting.textRuns![0].text = "Mismatch"
        XCTAssertThrowsError(try invalid.validated())
        invalid = diagram;invalid.pages[0].edges[index].formatting.textFields!.append(invalid.pages[0].edges[index].formatting.textFields![0])
        XCTAssertThrowsError(try invalid.validated())
        let object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(diagram))
        let older = try JSONDecoder().decode(Diagram.self,from:JSONSerialization.data(withJSONObject:removeConnectorDetails(object)))
        XCTAssertNil(older.pages[0].edges[index].details)
        XCTAssertNoThrow(try older.validated())
    }
}
