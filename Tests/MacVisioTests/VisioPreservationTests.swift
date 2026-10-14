import AppKit
import XCTest
@testable import MacVisio

final class VisioPreservationTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() { for url in directories { try? FileManager.default.removeItem(at:url) }; super.tearDown() }
    private func url(_ name:String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-preservation-\(UUID())",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true); directories.append(directory); return directory.appendingPathComponent(name)
    }
    private func removeMetadata(_ parts:inout [String:Data]) throws {
        parts.removeValue(forKey:"macvisio/document.json")
        let rels = try VisioXML.document(parts["_rels/.rels"]!)
        for r in rels.rootElement()!.elementsLocal("Relationship") where r.attr("Type")?.hasPrefix("urn:macvisio") == true { r.detach() }
        parts["_rels/.rels"] = rels.xmlData(options:.nodePreserveAll)
    }
    private func fixture() throws -> URL {
        let source = try url("independent.vsdx")
        var model = DiagramTemplate.flowchart.makeDiagram()
        model.page.nodes[0].formatting.data = [ShapeDataProperty(key:"Cost",label:"Cost",value:"125",type:2)]
        model.page.layers = [DiagramLayer(name:"Default"),DiagramLayer(name:"Hidden",visible:false)]
        try VisioFormat.write(model,to:source)
        var parts = try VisioPackage.read(source); try removeMetadata(&parts)
        parts["vendor/private.bin"] = Data([0,1,2,255,0,9])
        parts["visio/theme/theme1.xml"] = Data("<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Original theme\"/>".utf8)
        let page = try VisioXML.document(parts["visio/pages/page1.xml"]!)
        let first = page.rootElement()!.firstLocal("Shapes")!.elementsLocal("Shape")[0]
        let user = VisioXML.row(first,"User"); user.setAttr("N","FutureSetting"); VisioXML.set(user,"Value",37,formula:"GUARD(Sheet.2!Width*4)")
        first.addChild(try VisioXML.element("<v:Extension xmlns:v=\"urn:vendor:test\" preserved=\"yes\"><v:Payload>opaque &amp; important</v:Payload></v:Extension>"))
        parts["visio/pages/page1.xml"] = page.xmlData(options:.nodePreserveAll)
        try VisioPackage.write(parts,to:source); return source
    }
    func testUneditedImportPreservesEveryPackagePartByteForByte() throws {
        let source = try fixture(), destination = try url("saved.vsdx")
        let before = try VisioPackage.read(source), imported = try VisioFormat.read(from:source)
        XCTAssertNotNil(imported.diagram.visioArchive)
        try VisioFormat.write(imported.diagram,to:destination)
        XCTAssertEqual(try VisioPackage.read(destination),before)
    }
    func testTextAndPositionEditsKeepOpaquePartsAndShapeExtensions() throws {
        let source = try fixture(), destination = try url("edited.vsdx")
        var model = try VisioFormat.read(from:source).diagram
        let before = try VisioPackage.read(source)
        model.page.nodes[0].text = "Edited café & 東京"
        model.page.nodes[0].x += 35; model.page.nodes[0].y += 20
        try VisioFormat.write(model,to:destination)
        var after = try VisioPackage.read(destination)
        XCTAssertEqual(before["vendor/private.bin"],after["vendor/private.bin"])
        XCTAssertEqual(before["visio/theme/theme1.xml"],after["visio/theme/theme1.xml"])
        XCTAssertEqual(before["visio/document.xml"],after["visio/document.xml"])
        let xml = String(decoding:after["visio/pages/page1.xml"]!,as:UTF8.self)
        XCTAssertTrue(xml.contains("urn:vendor:test")); XCTAssertTrue(xml.contains("FutureSetting")); XCTAssertTrue(xml.contains("GUARD(Sheet.2!Width*4)"))
        // Read the actual public Visio XML rather than accepting our private model.
        try removeMetadata(&after); try VisioPackage.write(after,to:destination)
        let reopened = try VisioFormat.read(from:destination).diagram
        XCTAssertEqual(reopened.page.nodes[0].text,model.page.nodes[0].text)
        XCTAssertEqual(reopened.page.nodes[0].x,model.page.nodes[0].x,accuracy:0.0001)
        XCTAssertEqual(reopened.page.nodes[0].y,model.page.nodes[0].y,accuracy:0.0001)
    }
    func testShapeDeletionAndInsertionUpdateConnectionsWithoutLosingOtherData() throws {
        let source = try fixture(), destination = try url("structure.vsdx")
        var model = try VisioFormat.read(from:source).diagram
        let removed = model.page.nodes.remove(at:0).id
        model.page.edges.removeAll{$0.source == removed || $0.target == removed}
        let added = DiagramNode(kind:.hexagon,x:50,y:60,text:"New preparation")
        model.page.nodes.append(added); model.page.edges.append(DiagramEdge(source:added.id,target:model.page.nodes[0].id,label:"New link"))
        try VisioFormat.write(model,to:destination)
        var parts = try VisioPackage.read(destination); try removeMetadata(&parts); try VisioPackage.write(parts,to:destination)
        let restored = try VisioFormat.read(from:destination).diagram
        XCTAssertEqual(restored.page.nodes.count,model.page.nodes.count)
        XCTAssertEqual(restored.page.edges.count,model.page.edges.count)
        XCTAssertTrue(restored.page.nodes.contains{$0.text == "New preparation"})
        XCTAssertTrue(restored.page.edges.contains{$0.label == "New link"})
        XCTAssertNotNil(parts["vendor/private.bin"])
    }
    func testMultiplePagesCanBeAddedRenamedAndRemovedInPreservedPackage() throws {
        let source = try fixture(), destination = try url("pages.vsdx")
        var model = try VisioFormat.read(from:source).diagram
        let firstID = model.page.id
        var second = DiagramPage(name:"New & second"); second.nodes = [DiagramNode(x:35,y:45,text:"Second page")]
        model.pages.append(second); model.pages[0].name = "Renamed"
        try VisioFormat.write(model,to:destination)
        var parts = try VisioPackage.read(destination); try removeMetadata(&parts); try VisioPackage.write(parts,to:destination)
        model = try VisioFormat.read(from:destination).diagram
        XCTAssertEqual(model.pages.map(\.name),["Renamed","New & second"])
        XCTAssertEqual(model.pages[1].nodes[0].text,"Second page")
        model.pages.removeFirst(); model.activePageID = model.pages[0].id
        XCTAssertNotEqual(model.pages[0].id,firstID)
        try VisioFormat.write(model,to:destination)
        parts = try VisioPackage.read(destination); try removeMetadata(&parts); try VisioPackage.write(parts,to:destination)
        XCTAssertEqual(try VisioFormat.read(from:destination).diagram.pages.map(\.name),["New & second"])
    }
    func testNativeSaveAsVisioWritesPackageAndRetainsSourceAcrossNativeRecovery() throws {
        _ = NSApplication.shared
        let source = try fixture(), destination = try url("document.vsdx")
        let doc = MacVisioDocument(); try doc.read(from:source,ofType:MacVisioDocument.visioType)
        doc.diagram.page.nodes[0].text = "Saved through NSDocument"
        try doc.write(to:destination,ofType:MacVisioDocument.visioType)
        XCTAssertEqual(try VisioFormat.read(from:destination).diagram.page.nodes[0].text,"Saved through NSDocument")
        let native = try doc.data(ofType:MacVisioDocument.nativeType)
        let recovered = MacVisioDocument(); try recovered.read(from:native,ofType:MacVisioDocument.nativeType)
        XCTAssertEqual(recovered.diagram.visioArchive?.parts["vendor/private.bin"],doc.diagram.visioArchive?.parts["vendor/private.bin"])
        recovered.diagram.page.nodes[0].text = "After recovery"
        try recovered.write(to:destination,ofType:MacVisioDocument.visioType)
        XCTAssertNotNil(try VisioPackage.read(destination)["vendor/private.bin"])
    }
    func testGroupsCustomBezierLayersAndDataSurvivePublicInterchange() throws {
        var model = Diagram()
        var group = DiagramNode(x:100,y:100,text:""); group.width = 400; group.height = 300; group.formatting.isGroup = true
        var child = DiagramNode(x:140,y:150,text:"Grouped path"); child.parentID = group.id
        child.formatting.paths = [VectorPath(commands:[VectorCommand("M",0,1),VectorCommand("C",0,0,1,0,1,1),VectorCommand("Z")])]
        child.formatting.data = [ShapeDataProperty(key:"Owner",label:"Owner",value:"Alex")]
        child.formatting.hyperlinks = [ShapeHyperlink(address:"https://example.com",description:"Example")]
        child.layer = "Engineering"
        model.page.layers = [DiagramLayer(name:"Engineering",locked:true)]
        model.page.nodes = [group,child]
        let destination = try url("group.vsdx"); try VisioFormat.write(model,to:destination)
        var parts = try VisioPackage.read(destination); try removeMetadata(&parts); try VisioPackage.write(parts,to:destination)
        let imported = try VisioFormat.read(from:destination).diagram
        XCTAssertEqual(imported.page.nodes.count,2)
        let a = imported.page.nodes[0],b = imported.page.nodes[1]
        XCTAssertEqual(b.parentID,a.id); XCTAssertEqual(b.x,140,accuracy:0.0001); XCTAssertEqual(b.y,150,accuracy:0.0001)
        XCTAssertEqual(b.formatting.paths.first?.commands[1].kind,"C")
        XCTAssertEqual(b.formatting.data.first?.value,"Alex")
        XCTAssertEqual(b.formatting.hyperlinks.first?.address,"https://example.com")
        XCTAssertEqual(imported.page.layers?.first?.name,"Engineering"); XCTAssertTrue(imported.page.isLocked(b))
    }
    func testFreeLinesAreEditableAndExportWithoutFakeGlueRecords() throws {
        var model = Diagram(); var edge = DiagramEdge(source:UUID(),target:UUID(),label:"Free line",style:.straight)
        edge.sourcePosition = DiagramPoint(x:20,y:40); edge.targetPosition = DiagramPoint(x:220,y:140)
        model.page.edges = [edge]
        let destination = try url("free.vsdx"); try VisioFormat.write(model,to:destination)
        var parts = try VisioPackage.read(destination); try removeMetadata(&parts)
        let xml = String(decoding:parts["visio/pages/page1.xml"]!,as:UTF8.self)
        XCTAssertFalse(xml.contains("<Connect ")); XCTAssertFalse(xml.contains("Sheet.0"))
        try VisioPackage.write(parts,to:destination)
        let line = try XCTUnwrap(VisioFormat.read(from:destination).diagram.page.edges.first)
        XCTAssertEqual(line.label,"Free line"); XCTAssertEqual(try XCTUnwrap(line.sourcePosition).x,20,accuracy:0.001)
    }
}
