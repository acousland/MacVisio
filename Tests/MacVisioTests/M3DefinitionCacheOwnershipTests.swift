import Foundation
import XCTest
@testable import MacVisio

/// Public-input ownership regressions. A local Field.Format does not make the
/// master's Field.Value local, even when its evaluated cache changes on save.
final class M3DefinitionCacheOwnershipTests:XCTestCase {
    private var files:[URL] = []
    private let measure = DefinitionCellAddress(cell:"Value",section:"User",rowName:"Measure")
    private enum Subject:Equatable {
        case node,connector
        var sourceID:String { self == .node ? "10" : "30" }
        var masterID:String { self == .node ? "7" : "8" }
    }
    override func tearDown() { for file in files { try? FileManager.default.removeItem(at:file) };super.tearDown() }
    private func file() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-definition-field-cache-\(UUID()).vsdx")
        files.append(url);return url
    }
    private func fixture() throws -> Diagram {
        let seed = try XCTUnwrap(Bundle.module.url(forResource:"m3-intelligent",withExtension:"vsdx",subdirectory:"Fixtures/M3"))
        var parts = try VisioPackage.read(seed)
        XCTAssertNil(parts["macvisio/document.json"],"Author the regression in public XML, independently of native metadata.")
        let document = try VisioXML.document(XCTUnwrap(parts["visio/document.xml"]))
        let documentSheet = try XCTUnwrap(document.rootElement()?.firstLocal("DocumentSheet"))
        let row = XMLElement(name:"Row");row.setAttr("N","Measure")
        VisioXML.set(row,"Value","2").setAttr("U","IN")
        VisioXML.section(documentSheet,"User").addChild(row)
        parts["visio/document.xml"] = document.xmlData(options:.nodePreserveAll)
        // The field's formula and type are authored only in each master. Both
        // instances author a Format override and a cached local Text marker.
        let inheritedField = """
        <Section N="Field"><Row IX="0"><Cell N="Value" V="2" F="TheDoc!User.Measure" U="IN"/><Cell N="Format" V="0.0" U="STR"/><Cell N="Type" V="2"/></Row></Section>
        <Text><fld IX="0">2.0</fld></Text>
        """
        parts["visio/masters/master1.xml"] = Data("""
        <MasterContents xmlns="http://schemas.microsoft.com/office/visio/2012/main"><Shapes><Shape ID="1" Type="Shape" NameU="NodeFieldOwner">
        <Cell N="PinX" V="1"/><Cell N="PinY" V="0.5"/><Cell N="Width" V="2"/><Cell N="Height" V="1"/><Cell N="LocPinX" V="1" F="Width/2"/><Cell N="LocPinY" V="0.5" F="Height/2"/>
        <Section N="Geometry" IX="0"><Row T="MoveTo" IX="1"><Cell N="X" V="0"/><Cell N="Y" V="0"/></Row><Row T="LineTo" IX="2"><Cell N="X" V="2"/><Cell N="Y" V="0"/></Row><Row T="LineTo" IX="3"><Cell N="X" V="2"/><Cell N="Y" V="1"/></Row><Row T="LineTo" IX="4"><Cell N="X" V="0"/><Cell N="Y" V="1"/></Row><Row T="LineTo" IX="5"><Cell N="X" V="0"/><Cell N="Y" V="0"/></Row></Section>
        \(inheritedField)</Shape></Shapes></MasterContents>
        """.utf8)
        parts["visio/masters/master2.xml"] = Data("""
        <MasterContents xmlns="http://schemas.microsoft.com/office/visio/2012/main"><Shapes><Shape ID="1" Type="Shape" NameU="ConnectorFieldOwner">
        <Cell N="OneD" V="1"/><Cell N="BeginX" V="1"/><Cell N="BeginY" V="3"/><Cell N="EndX" V="4"/><Cell N="EndY" V="3"/><Cell N="PinX" V="2.5"/><Cell N="PinY" V="3"/><Cell N="Width" V="3"/><Cell N="Height" V="0"/><Cell N="LocPinX" V="1.5"/><Cell N="LocPinY" V="0"/>
        <Section N="Geometry" IX="0"><Cell N="NoFill" V="1"/><Row T="MoveTo" IX="1"><Cell N="X" V="0"/><Cell N="Y" V="0"/></Row><Row T="LineTo" IX="2"><Cell N="X" V="3"/><Cell N="Y" V="0"/></Row></Section>
        \(inheritedField)</Shape></Shapes></MasterContents>
        """.utf8)
        let instanceText = """
        <Section N="Character"><Row IX="0"><Cell N="Font" V="0"/><Cell N="Size" V="0.1666666666666667"/><Cell N="Color" V="#20334F"/></Row></Section>
        <Section N="Paragraph"><Row IX="0"><Cell N="HorzAlign" V="1"/></Row></Section>
        <Section N="Field"><Row IX="0"><Cell N="Format" V="0.00" U="STR"/></Row></Section>
        <Text><fld IX="0">2.00</fld></Text>
        """
        parts["visio/pages/page1.xml"] = Data("""
        <PageContents xmlns="http://schemas.microsoft.com/office/visio/2012/main" xml:space="preserve"><Shapes>
        <Shape ID="10" Type="Shape" Master="7"><Cell N="PinX" V="3"/><Cell N="PinY" V="7"/>\(instanceText)</Shape>
        <Shape ID="30" Type="Shape" Master="8">\(instanceText)</Shape>
        </Shapes><Connects/></PageContents>
        """.utf8)
        let input = file();try VisioPackage.write(parts,to:input)
        let drawing = try VisioFormat.read(from:input).diagram
        XCTAssertEqual(drawing.pages[0].nodes.count,1);XCTAssertEqual(drawing.pages[0].edges.count,1)
        for subject in [Subject.node,.connector] { try assertPublicOwnership(parts,subject:subject,display:"2.00") }
        return drawing
    }
    private func detail(_ drawing:Diagram,subject:Subject) throws -> ShapeDetails {
        switch subject {
        case .node:return try XCTUnwrap(drawing.pages[0].nodes.first{$0.formatting.sourceShapeID == subject.sourceID}).formatting
        case .connector:return try XCTUnwrap(drawing.pages[0].edges.first{$0.sourceShapeID == subject.sourceID}).formatting
        }
    }
    private func text(_ drawing:Diagram,subject:Subject) throws -> String {
        switch subject {
        case .node:return try XCTUnwrap(drawing.pages[0].nodes.first{$0.formatting.sourceShapeID == subject.sourceID}).text
        case .connector:return try XCTUnwrap(drawing.pages[0].edges.first{$0.sourceShapeID == subject.sourceID}).label
        }
    }
    private func assertPublicOwnership(_ parts:[String:Data],subject:Subject,display:String,file:StaticString = #filePath,line:UInt = #line) throws {
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        let instance = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first{$0.attr("ID") == subject.sourceID})
        XCTAssertEqual(instance.attr("Master"),subject.masterID,file:file,line:line)
        let fields = instance.elementsLocal("Section").filter{$0.attr("N") == "Field"}.flatMap{$0.elementsLocal("Row")}
        XCTAssertEqual(fields.count,1,file:file,line:line)
        let field = try XCTUnwrap(fields.first{$0.attr("IX") == "0"})
        XCTAssertNil(field.elementsLocal("Cell").first{$0.attr("N") == "Value"},"Refreshing the field display must retain the master's Value ownership.",file:file,line:line)
        XCTAssertNil(field.elementsLocal("Cell").first{$0.attr("N") == "Type"},file:file,line:line)
        XCTAssertEqual(VisioXML.value(field,"Format"),"0.00",file:file,line:line)
        XCTAssertEqual(instance.firstLocal("Text")?.stringValue,display,file:file,line:line)
        let masterPart = subject == .node ? "visio/masters/master1.xml" : "visio/masters/master2.xml"
        let master = try VisioXML.document(XCTUnwrap(parts[masterPart]))
        let row = try XCTUnwrap(master.rootElement()?.firstLocal("Shapes")?.allShapes.first?.elementsLocal("Section").first{$0.attr("N") == "Field"}?.elementsLocal("Row").first{$0.attr("IX") == "0"})
        let value = try XCTUnwrap(row.elementsLocal("Cell").first{$0.attr("N") == "Value"})
        XCTAssertEqual(value.attr("F"),"TheDoc!User.Measure",file:file,line:line);XCTAssertEqual(value.attr("U"),"IN",file:file,line:line)
        XCTAssertEqual(VisioXML.value(row,"Format"),"0.0",file:file,line:line)
    }
    private func exercise(_ subject:Subject) throws {
        let original = try fixture(),sheetID = try XCTUnwrap(original.definitions?.documentSheet?.id)
        let originalTokens = try detail(original,subject:subject).textRuns?.compactMap(\.fieldToken)
        let edited = try DefinitionEditing.settingCell(in:original,sheetID:sheetID,address:measure,value:ShapeSheetCell(value:"3",unit:"IN"))
        XCTAssertEqual(try text(edited,subject:subject),"3.00")
        XCTAssertEqual(try detail(edited,subject:subject).textFields?.first?.cells["Value"]?.formula,"TheDoc!User.Measure")
        XCTAssertEqual(try detail(edited,subject:subject).textRuns?.compactMap(\.fieldToken),originalTokens)
        let prepared = try VisioPreservation.prepared(edited)
        try assertPublicOwnership(prepared.parts,subject:subject,display:"3.00")
        let changedFile = file(),saved = try VisioFormat.writeRebased(edited,to:changedFile)
        let savedParts = try VisioPackage.read(changedFile)
        try assertPublicOwnership(savedParts,subject:subject,display:"3.00")
        let reopened = try VisioFormat.readPublic(parts:savedParts,title:"Independent public field cache").diagram
        XCTAssertEqual(try text(reopened,subject:subject),"3.00")
        XCTAssertEqual(try detail(reopened,subject:subject).textFields?.first?.cells["Value"]?.formula,"TheDoc!User.Measure")
        XCTAssertEqual(try detail(reopened,subject:subject).textFields?.first?.cells["Format"]?.value,"0.00")
        var installed = edited;installed.visioArchive = saved
        let undone = try DefinitionEditing.settingCell(in:installed,sheetID:sheetID,address:measure,value:ShapeSheetCell(value:"2",unit:"IN"))
        XCTAssertEqual(try text(undone,subject:subject),"2.00")
        XCTAssertEqual(try detail(undone,subject:subject).textRuns?.compactMap(\.fieldToken),originalTokens)
        let undoFile = file();try VisioFormat.write(undone,to:undoFile)
        let undoParts = try VisioPackage.read(undoFile)
        try assertPublicOwnership(undoParts,subject:subject,display:"2.00")
        let publicUndo = try VisioFormat.readPublic(parts:undoParts,title:"Independent public undo").diagram
        XCTAssertEqual(try text(publicUndo,subject:subject),"2.00")
        XCTAssertEqual(publicUndo.definitions?.documentSheet?.cell(measure)?.value,"2")
    }
    func testNodeFormatOnlyOverrideKeepsInheritedFieldValueThroughDefinitionSaveAndUndo() throws { try exercise(.node) }
    func testConnectorFormatOnlyOverrideKeepsInheritedFieldValueThroughDefinitionSaveAndUndo() throws { try exercise(.connector) }
}
