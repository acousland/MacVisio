import AppKit
import CryptoKit
import XCTest
@testable import MacVisio

final class M3ConnectorFontTests: XCTestCase {
    func testInventoryIncludesConnectorBaseRunsAndEmptyFieldsOnEveryPage() throws {
        var shape = DiagramNode(text:"Shape")
        shape.formatting.fontName = "Missing base"
        var edge = DiagramEdge(source:shape.id,target:shape.id,label:"Link")
        edge.formatting.fontName = "Missing base"
        var character = ShapeCharacterStyle(node:edge.textNode)
        character.fontName = "Missing run";character.sourceIndex = 19
        character.cells["Font"] = ShapeSheetCell(value:"42",formula:"FONT(\"Original\")")
        edge.formatting.textRuns = [
            ShapeTextRun(text:"Link",character:character,paragraph:ShapeParagraphStyle()),
            ShapeTextRun(text:"",character:character,paragraph:ShapeParagraphStyle(),fieldIndex:7,fieldToken:UUID())]
        var drawing = Diagram();drawing.page.nodes = [shape];drawing.page.edges = [edge]
        var background = DiagramPage();background.isBackground = true
        var second = edge;second.id = UUID();background.edges = [second];drawing.pages.append(background)
        let before = drawing
        let inventory = FontSubstitution.inventory(in:drawing,using:.init(installedNames:["Arial"]))
        let base = try XCTUnwrap(inventory.first{$0.resolution.requestedName == "Missing base"})
        XCTAssertEqual(base.uses,[.init(pageID:drawing.page.id,nodeID:shape.id,runIndex:nil),
            .init(pageID:drawing.page.id,connectorID:edge.id,runIndex:nil),
            .init(pageID:background.id,connectorID:second.id,runIndex:nil)])
        let run = try XCTUnwrap(inventory.first{$0.resolution.requestedName == "Missing run"})
        XCTAssertEqual(run.uses,[.init(pageID:drawing.page.id,connectorID:edge.id,runIndex:0),
            .init(pageID:drawing.page.id,connectorID:edge.id,runIndex:1),
            .init(pageID:background.id,connectorID:second.id,runIndex:0),
            .init(pageID:background.id,connectorID:second.id,runIndex:1)])
        XCTAssertTrue(inventory.allSatisfy{$0.resolution.renderingName == "Arial"})
        XCTAssertEqual(drawing,before)
    }

    func testDiagnosticsKeepConnectorAndShapeOwnersDistinctEvenWithTheSameUUID() throws {
        var shape = DiagramNode(text:"Shape");shape.formatting.fontName = "Missing"
        var edge = DiagramEdge(source:shape.id,target:shape.id,label:"Link")
        edge.id = shape.id;edge.formatting.fontName = "Missing"
        var drawing = Diagram();drawing.page.nodes = [shape];drawing.page.edges = [edge]
        let issues = DrawingContentChecks.evaluate(drawing,catalog:.init(installedNames:["Arial"]),inputKey:"snapshot")
        XCTAssertEqual(issues.count,2);XCTAssertEqual(Set(issues.map(\.id)).count,2)
        XCTAssertEqual(Set(issues.map(\.target)),[.shape(page:drawing.page.id,shape:shape.id),.connector(page:drawing.page.id,connector:edge.id)])
        XCTAssertTrue(issues.allSatisfy{$0.code == "font.substituted" && $0.inputKey == "snapshot" && $0.source.cell == "Character.Font"})
    }

    func testInstalledAndSystemConnectorFontsDoNotProduceSubstitutionWarnings() {
        let node = DiagramNode()
        var edge = DiagramEdge(source:node.id,target:node.id,label:"Label")
        edge.formatting.fontName = "aRiAl"
        var character = ShapeCharacterStyle(node:edge.textNode);character.fontName = "System"
        edge.formatting.textRuns = [ShapeTextRun(text:edge.label,character:character,paragraph:ShapeParagraphStyle())]
        var drawing = Diagram();drawing.page.nodes = [node];drawing.page.edges = [edge]
        XCTAssertTrue(DrawingContentChecks.evaluate(drawing,catalog:.init(installedNames:["Arial"]),inputKey:"snapshot").isEmpty)
    }

    func testPublicConnectorFontCheckAndRenderingPreserveRequestedNamesAndUnchangedPackage() throws {
        _ = NSApplication.shared
        let fixture = try XCTUnwrap(Bundle.module.url(forResource:"m3-intelligent",withExtension:"vsdx",subdirectory:"Fixtures/M3"))
        var parts = try VisioPackage.read(fixture)
        let document = try VisioXML.document(XCTUnwrap(parts["visio/document.xml"]))
        let faces = try XCTUnwrap(document.rootElement()?.firstLocal("FaceNames"))
        let firstFont = faces.elementsLocal("FaceName").count
        let names = ["MacVisio unavailable connector font A73F","MacVisio unavailable connector font B73F"]
        for name in names { let face = XMLElement(name:"FaceName");face.setAttr("NameU",name);faces.addChild(face) }
        parts["visio/document.xml"] = document.xmlData(options:.nodePreserveAll)
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        let shape = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first{$0.attr("ID") == "30"})
        for child in shape.children ?? [] {
            if let e = child as? XMLElement,e.localTag == "Text" || e.localTag == "Section" && ["Character","Paragraph","Field"].contains(e.attr("N") ?? "") { e.detach() }
        }
        let payload = try VisioXML.element("""
        <Shape>
        <Section N="Character"><Row IX="3"><Cell N="Font" V="\(firstFont)"/><Cell N="Size" V="0.1666666666666667"/><Cell N="LangID" V="1033"/></Row><Row IX="9"><Cell N="Font" V="\(firstFont+1)"/><Cell N="Size" V="0.1944444444444444"/><Cell N="LangID" V="1041"/></Row></Section>
        <Section N="Paragraph"><Row IX="4"><Cell N="HorzAlign" V="0"/></Row></Section>
        <Section N="Field"><Row IX="7"><Cell N="Value" V="5" F="GUARD(5)"/><Cell N="Type" V="2"/></Row></Section>
        <Text><cp IX="3"/><pp IX="4"/>Link <fld IX="7">5</fld><cp IX="9"/> 東京 אב🙂</Text>
        <FontProbe Keep="opaque"/>
        </Shape>
        """)
        for child in payload.children ?? [] { shape.addChild(child.copy() as! XMLNode) }
        parts["visio/pages/page1.xml"] = page.xmlData(options:.nodePreserveAll)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M3ConnectorFonts-\(UUID())",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let source = directory.appendingPathComponent("source.vsdx"),output = directory.appendingPathComponent("output.vsdx")
        try VisioPackage.write(parts,to:source)
        let drawing = try VisioFormat.read(from:source).diagram
        let edge = try XCTUnwrap(drawing.page.edges.first{$0.sourceShapeID == "30"})
        XCTAssertEqual(edge.formatting.textRuns?.first?.character.sourceIndex,3)
        XCTAssertEqual(edge.formatting.textRuns?.last?.character.sourceIndex,9)
        XCTAssertEqual(edge.formatting.textRuns?.first?.character.fontName,names[0])
        XCTAssertEqual(edge.formatting.textRuns?.last?.character.fontName,names[1])
        let inventory = FontSubstitution.inventory(in:drawing,using:.init(installedNames:["Arial"]))
        let missing = inventory.filter{names.contains($0.resolution.requestedName)}
        XCTAssertEqual(missing.count,2);XCTAssertTrue(missing.allSatisfy{$0.resolution.isSubstituted})
        XCTAssertTrue(missing.flatMap(\.uses).allSatisfy{$0.owner == .connector(edge.id)})
        let issues = DrawingContentChecks.evaluate(drawing,catalog:.init(installedNames:["Arial"]),inputKey:"public-source")
        let connectorIssues = issues.filter{$0.target == .connector(page:drawing.page.id,connector:edge.id)}
        XCTAssertEqual(connectorIssues.count,missing.flatMap(\.uses).count)
        XCTAssertTrue(connectorIssues.contains{$0.source.feature?.hasSuffix(":0") == true})
        let rendered = ShapeRichText.attributed(edge.textNode)
        XCTAssertEqual(rendered.string,edge.label)
        rendered.enumerateAttribute(.font,in:NSRange(location:0,length:rendered.length)){value,_,_ in XCTAssertNotNil(value as? NSFont)}
        XCTAssertEqual(drawing.page.edges.first{$0.id == edge.id},edge)
        try VisioFormat.write(drawing,to:output)
        let savedParts = try VisioPackage.read(output)
        XCTAssertEqual(savedParts,parts,"A read-only font check must retain every public package part.")
        let reopened = try VisioFormat.readPublic(parts:savedParts,title:"Font check").diagram
        let reopenedEdge = try XCTUnwrap(reopened.page.edges.first{$0.sourceShapeID == "30"})
        XCTAssertEqual(reopenedEdge.formatting.textRuns?.map{$0.character.fontName},edge.formatting.textRuns?.map{$0.character.fontName})
        XCTAssertEqual(reopenedEdge.formatting.textFields?.first?.cells["Value"]?.formula,"GUARD(5)")
        try retain(source:source,output:output,issues:connectorIssues,names:names)
    }

    private func retain(source:URL,output:URL,issues:[DocumentDiagnostic],names:[String]) throws {
        guard let path = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"],!path.isEmpty else { return }
        guard (path as NSString).isAbsolutePath else { throw DiagramError.invalid("Connector font evidence requires an absolute directory.") }
        let target = URL(fileURLWithPath:path,isDirectory:true).appendingPathComponent("M3ConnectorFontTests",isDirectory:true)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        var files:[[String:Any]] = []
        for (name,url) in [("source.vsdx",source),("output.vsdx",output)] {
            let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
            guard let size = attributes[.size] as? NSNumber,size.int64Value > 0,size.int64Value <= 16*1024*1024 else { throw DiagramError.invalid("Connector font evidence exceeds 16 MiB.") }
            let data = try Data(contentsOf:url);guard data.count <= 16*1024*1024 else { throw DiagramError.invalid("Connector font evidence grew past 16 MiB.") }
            try data.write(to:target.appendingPathComponent(name),options:.atomic)
            files.append(["path":name,"bytes":data.count,"sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()])
        }
        let diagnostics = try JSONEncoder().encode(issues)
        let manifest:[String:Any] = ["schema":"macvisio.m3.connector-fonts.v1","files":files,"requested_names":names,
            "diagnostics":try JSONSerialization.jsonObject(with:diagnostics),"reference_run":false,
            "scope":"Actual local public source and unchanged save after connector font check and rendering assertions."]
        let data = try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])
        guard data.count <= 64*1024 else { throw DiagramError.invalid("Connector font evidence manifest exceeds 64 KiB.") }
        try data.write(to:target.appendingPathComponent("manifest.json"),options:.atomic)
    }
}
