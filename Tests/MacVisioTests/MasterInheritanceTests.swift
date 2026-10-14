import Foundation
import AppKit
import XCTest
@testable import MacVisio

final class MasterInheritanceTests:XCTestCase {
    private var directories:[URL] = []
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at:directory) };super.tearDown() }
    private func url(_ name:String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-master-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);directories.append(directory);return directory.appendingPathComponent(name)
    }
    private let ns = "http://schemas.microsoft.com/office/visio/2012/main"
    private let rns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private let base = "http://schemas.microsoft.com/visio/2010/relationships/"
    private func stripMetadata(_ parts:inout [String:Data]) { parts.removeValue(forKey:"macvisio/document.json") }
    private func shape(_ id:Int,_ text:String,_ pinX:Double,_ pinY:Double,_ width:Double,_ height:Double,_ extra:String = "") -> String {
        "<Shape ID=\"\(id)\"><Cell N=\"PinX\" V=\"\(pinX)\"/><Cell N=\"PinY\" V=\"\(pinY)\"/><Cell N=\"Width\" V=\"\(width)\"/><Cell N=\"Height\" V=\"\(height)\"/><Cell N=\"LocPinX\" V=\"\(width/2)\"/><Cell N=\"LocPinY\" V=\"\(height/2)\"/><Cell N=\"TxtWidth\" V=\"\(width)\"/><Cell N=\"TxtHeight\" V=\"\(height)\"/><Cell N=\"LeftMargin\" V=\"0\"/><Cell N=\"RightMargin\" V=\"0\"/><Cell N=\"TopMargin\" V=\"0\"/><Cell N=\"BottomMargin\" V=\"0\"/><Section N=\"Character\"><Row IX=\"0\"><Cell N=\"Size\" V=\"0.138888888888889\"/></Row></Section><Text>\(text)</Text>\(extra)</Shape>"
    }
    private func fixture(_ local:String = "",_ multiRoot:Bool = false) throws -> URL {
        let file = try url("masters.vsdx");try VisioFormat.write(Diagram(),to:file)
        var parts = try VisioPackage.read(file);stripMetadata(&parts)
        let property = "<Section N=\"Property\"><Row N=\"Cost\"><Cell N=\"Label\" V=\"Cost in dollars\"/><Cell N=\"Value\" V=\"45\"/><Cell N=\"Type\" V=\"2\"/></Row></Section><Section N=\"User\"><Row N=\"Span\"><Cell N=\"Value\" V=\"4\" F=\"Sheet.1!Width\"/></Row></Section><Section N=\"Hyperlink\"><Row N=\"Info\"><Cell N=\"Address\" V=\"https://example.com/master\"/></Row></Section>"
        let left = shape(2,"Inherited left",0.75,1,1,0.5,property)
        let inner = shape(4,"Inherited inner",0.5,0.5,1,0.5)
        let nested = shape(3,"",3,1,1,1,"<Shapes>\(inner)</Shapes>")
        let edge = "<Shape ID=\"5\"><Cell N=\"OneD\" V=\"1\"/><Cell N=\"BeginX\" V=\"1.25\"/><Cell N=\"BeginY\" V=\"1\"/><Cell N=\"EndX\" V=\"2.5\"/><Cell N=\"EndY\" V=\"1\"/><Text>Master link</Text></Shape>"
        let master = multiRoot ? left+nested+edge : shape(1,"",2,1,4,2,"<Shapes>\(left)\(nested)\(edge)</Shapes>")
        parts["visio/masters/masters.xml"] = Data("<Masters xmlns=\"\(ns)\" xmlns:r=\"\(rns)\"><Master ID=\"7\" NameU=\"Test group\"><Rel r:id=\"rId1\"/></Master></Masters>".utf8)
        parts["visio/masters/_rels/masters.xml.rels"] = Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(base)master\" Target=\"master1.xml\"/></Relationships>".utf8)
        parts["visio/masters/master1.xml"] = Data("<MasterContents xmlns=\"\(ns)\"><PageSheet><Cell N=\"PageWidth\" V=\"4\"/><Cell N=\"PageHeight\" V=\"2\"/></PageSheet><Shapes>\(master)</Shapes><Connects><Connect FromSheet=\"5\" FromCell=\"BeginX\" ToSheet=\"2\"/><Connect FromSheet=\"5\" FromCell=\"EndX\" ToSheet=\"4\"/></Connects></MasterContents>".utf8)
        let rels = try VisioXML.document(parts["visio/_rels/document.xml.rels"]!)
        rels.rootElement()!.addChild(try VisioXML.element("<Relationship Id=\"masterIndex\" Type=\"\(base)masters\" Target=\"masters/masters.xml\"/>"));parts["visio/_rels/document.xml.rels"] = rels.xmlData(options:.nodePreserveAll)
        let types = try VisioXML.document(parts["[Content_Types].xml"]!)
        for (part,type) in [("masters.xml","masters"),("master1.xml","master")] { types.rootElement()!.addChild(try VisioXML.element("<Override PartName=\"/visio/masters/\(part)\" ContentType=\"application/vnd.ms-visio.\(type)+xml\"/>")) }
        parts["[Content_Types].xml"] = types.xmlData(options:.nodePreserveAll)
        let first = "<Shape ID=\"10\" Master=\"7\"><Cell N=\"PinX\" V=\"3\"/><Cell N=\"PinY\" V=\"6\"/>\(local)</Shape>"
        let second = "<Shape ID=\"20\" Master=\"7\"><Cell N=\"PinX\" V=\"3\"/><Cell N=\"PinY\" V=\"3\"/></Shape>"
        parts["visio/pages/page1.xml"] = Data("<PageContents xmlns=\"\(ns)\"><Shapes>\(first)\(second)\(shape(55,"Unrelated",7,7,1,1))</Shapes><Connects/></PageContents>".utf8)
        try VisioPackage.write(parts,to:file);return file
    }
    private func publicRead(_ diagram:Diagram) throws -> (Diagram,[String:Data]) {
        let file = try url("edited.vsdx");try VisioFormat.write(diagram,to:file)
        var parts = try VisioPackage.read(file);stripMetadata(&parts);try VisioPackage.write(parts,to:file)
        return (try VisioFormat.read(from:file).diagram,parts)
    }
    func testWideMasterSheetsKeepCachedValuesAndInstanceScopedFormulas() throws {
        let source = try fixture("<Cell N=\"Custom13\" V=\"7\" F=\"Sheet.55!Width\"/>")
        var parts = try VisioPackage.read(source)
        let master = try VisioXML.document(parts["visio/masters/master1.xml"]!)
        let root = master.rootElement()!.elementsLocal("Shapes")[0].elementsLocal("Shape")[0]
        for index in 0..<300 {
            root.addChild(try VisioXML.element("<Cell N=\"Custom\(index)\" V=\"\(index+1)\" F=\"Sheet.1!Width\"/>"))
        }
        root.addChild(try VisioXML.element("<Cell N=\"CachedOnly\" V=\"123\"/>"))
        parts["visio/masters/master1.xml"] = master.xmlData(options:.nodePreserveAll)
        try VisioPackage.write(parts,to:source)
        let diagram = try VisioFormat.read(from:source).diagram
        for id in ["10","20"] {
            let node = try XCTUnwrap(diagram.page.nodes.first{$0.formatting.sourceShapeID == id})
            for index in 0..<300 {
                let cell = try XCTUnwrap(node.formatting.sheet["Custom\(index)"])
                let overridden = id == "10" && index == 13
                XCTAssertEqual(cell.value,overridden ? "7" : String(index+1))
                XCTAssertEqual(cell.formula,overridden ? "Sheet.55!Width" : "Sheet.\(id)!Width")
            }
            XCTAssertEqual(node.formatting.sheet["CachedOnly"],ShapeSheetCell(value:"123"))
        }
    }
    func testImplicitGroupsExpandAndConnectionsAreScopedToEachInstance() throws {
        let source = try fixture(),result = try VisioFormat.read(from:source),page = result.diagram.page
        XCTAssertEqual(page.nodes.count,9);XCTAssertEqual(page.edges.count,2)
        let roots = page.nodes.filter{$0.parentID == nil && $0.formatting.isGroup};XCTAssertEqual(roots.count,2)
        for root in roots {
            let descendants = page.descendants(of:root.id)
            let edge = try XCTUnwrap(page.edges.first{descendants.contains($0.source)})
            XCTAssertTrue(descendants.contains(edge.target));XCTAssertEqual(edge.label,"Master link")
            let left = try XCTUnwrap(page.nodes.first{$0.parentID == root.id && $0.text == "Inherited left"})
            XCTAssertEqual(left.width,72);XCTAssertEqual(left.formatting.data.first?.value,"45")
            XCTAssertEqual(left.formatting.hyperlinks.first?.address,"https://example.com/master")
            XCTAssertEqual(left.formatting.sheet["User.Span"]?.formula,"Sheet.\(root.formatting.sourceShapeID!)!Width")
            XCTAssertEqual(left.center.x-root.center.x,-90,accuracy:0.0001)
        }
        XCTAssertFalse(result.warnings.contains{$0.contains("partial native preview")})
        let copy = try url("unchanged.vsdx");try VisioFormat.write(result.diagram,to:copy)
        XCTAssertEqual(try VisioPackage.read(copy)["visio/pages/page1.xml"],try VisioPackage.read(source)["visio/pages/page1.xml"])
    }
    func testGeometryInheritanceKeepsLocalReferencesAndMinimalRowEdits() throws {
        let source = try fixture("<Section N=\"Geometry\" IX=\"0\"><Row IX=\"2\"><Cell N=\"X\" V=\"1\" F=\"Sheet.55!Width\"/></Row></Section>")
        var parts = try VisioPackage.read(source)
        let master = try VisioXML.document(parts["visio/masters/master1.xml"]!)
        let root = master.rootElement()!.elementsLocal("Shapes")[0].elementsLocal("Shape")[0]
        root.addChild(try VisioXML.element("<Section N=\"Geometry\" IX=\"0\"><Row IX=\"1\" T=\"MoveTo\"><Cell N=\"X\" V=\"0\"/><Cell N=\"Y\" V=\"0\"/></Row><Row IX=\"2\" T=\"LineTo\"><Cell N=\"X\" V=\"1\" F=\"Sheet.2!Width\"/><Cell N=\"Y\" V=\"2\" F=\"Height\"/></Row><Row IX=\"3\" T=\"LineTo\"><Cell N=\"X\" V=\"0\"/><Cell N=\"Y\" V=\"0\"/></Row></Section>"))
        parts["visio/masters/master1.xml"] = master.xmlData(options:.nodePreserveAll);try VisioPackage.write(parts,to:source)
        var diagram = try VisioFormat.read(from:source).diagram
        let local = try XCTUnwrap(diagram.page.nodes.first{$0.formatting.sourceShapeID == "10"}),i = try XCTUnwrap(diagram.page.nodes.firstIndex{$0.formatting.sourceShapeID == "20"})
        XCTAssertEqual(GeometrySheet.cell("Geometry1.X2",on:local)?.formula,"Sheet.55!Width")
        let child = try XCTUnwrap(diagram.page.nodes.first{$0.parentID == diagram.page.nodes[i].id && $0.text == "Inherited left"})
        XCTAssertEqual(GeometrySheet.cell("Geometry1.X2",on:diagram.page.nodes[i])?.formula,"Sheet.\(child.formatting.sourceShapeID!)!Width")
        try GeometrySheet.set("Geometry1.Y2",ShapeSheetCell(value:"1",formula:"Height/2"),on:&diagram.page.nodes[i])
        diagram.page.nodes[i].formatting.geometry![0].rows.removeAll{$0.index == 3}
        diagram = ShapeSheetEngine.recalculate(diagram).diagram
        let (read,output) = try publicRead(diagram)
        XCTAssertEqual(output["visio/masters/master1.xml"],parts["visio/masters/master1.xml"])
        let edited = try XCTUnwrap(read.page.nodes.first{$0.formatting.sourceShapeID == "20"})
        XCTAssertEqual(GeometrySheet.cell("Geometry1.Y2",on:edited)?.formula,"Height/2");XCTAssertNil(GeometrySheet.cell("Geometry1.X3",on:edited))
        let page = try VisioXML.document(output["visio/pages/page1.xml"]!),shape = try XCTUnwrap(page.rootElement()?.elementsLocal("Shapes").first?.elementsLocal("Shape").first{$0.attr("ID") == "20"})
        let section = try XCTUnwrap(shape.elementsLocal("Section").first{$0.attr("N") == "Geometry"})
        XCTAssertEqual(section.elementsLocal("Row").count,2);XCTAssertEqual(section.elementsLocal("Row").first{$0.attr("IX") == "3"}?.attr("Del"),"1")
    }
    func testUnrelatedEditDoesNotMaterializeMasterDescendants() throws {
        let source = try fixture();var diagram = try VisioFormat.read(from:source).diagram
        diagram.page.nodes[diagram.page.nodes.firstIndex{$0.text == "Unrelated"}!].text = "Unrelated edit"
        let (restored,parts) = try publicRead(diagram)
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!);XCTAssertEqual(xml.rootElement()!.firstLocal("Shapes")!.allShapes.count,3)
        XCTAssertEqual(restored.page.nodes.count,9);XCTAssertEqual(restored.page.edges.count,2)
        XCTAssertEqual(parts["visio/masters/master1.xml"],try VisioPackage.read(source)["visio/masters/master1.xml"])
    }
    func testEditingAnImplicitGrandchildEmitsOnlyMinimalAncestorOverrides() throws {
        var diagram = try VisioFormat.read(from:fixture()).diagram
        let index = diagram.page.nodes.firstIndex{$0.text == "Inherited inner"}!
        diagram.page.nodes[index].text = "Edited child"
        let (restored,parts) = try publicRead(diagram)
        XCTAssertEqual(restored.page.nodes.filter{$0.text == "Edited child"}.count,1)
        XCTAssertEqual(restored.page.nodes.filter{$0.text == "Inherited inner"}.count,1)
        let root = try VisioXML.document(parts["visio/pages/page1.xml"]!).rootElement()!,first = root.firstLocal("Shapes")!.elementsLocal("Shape")[0]
        let nested = try XCTUnwrap(first.firstLocal("Shapes")?.elementsLocal("Shape").first)
        XCTAssertEqual(nested.attr("MasterShape"),"3");XCTAssertEqual(nested.elementsLocal("Cell").count,0)
        let child = try XCTUnwrap(nested.firstLocal("Shapes")?.elementsLocal("Shape").first)
        XCTAssertEqual(child.attr("MasterShape"),"4");XCTAssertEqual(child.elementsLocal("Cell").count,0)
        XCTAssertEqual(first.firstLocal("Shapes")?.elementsLocal("Shape").count,1)
    }
    func testDeletedInheritedSubshapeStaysDeletedInPublicXML() throws {
        var diagram = try VisioFormat.read(from:fixture()).diagram
        let index = diagram.page.nodes.firstIndex{$0.text == "Inherited inner"}!,id = diagram.page.nodes[index].id
        diagram.page.nodes.remove(at:index);diagram.page.edges.removeAll{$0.source == id || $0.target == id}
        let (restored,parts) = try publicRead(diagram)
        XCTAssertEqual(restored.page.nodes.filter{$0.text == "Inherited inner"}.count,1)
        XCTAssertEqual(restored.page.edges.count,1)
        let deleted = try VisioXML.document(parts["visio/pages/page1.xml"]!).rootElement()!.firstLocal("Shapes")!.allShapes.filter{$0.attr("Del") == "1"}
        XCTAssertEqual(Set(deleted.compactMap{$0.attr("MasterShape")}),["4","5"])
    }
    func testPartialOverridesMergePropertiesAndSupplementMissingChildren() throws {
        let local = "<Shapes><Shape ID=\"31\" MasterShape=\"2\"><Text>Local label</Text><Section N=\"Property\"><Row N=\"Cost\"><Cell N=\"Value\" V=\"99\"/></Row></Section></Shape><Shape ID=\"32\" MasterShape=\"3\"><Shapes><Shape ID=\"33\" MasterShape=\"4\" Del=\"true\"/></Shapes></Shape></Shapes>"
        let diagram = try VisioFormat.read(from:fixture(local)).diagram
        XCTAssertEqual(diagram.page.nodes.count,8)
        let child = try XCTUnwrap(diagram.page.nodes.first{$0.text == "Local label"})
        XCTAssertEqual(child.formatting.sourceShapeID,"31");XCTAssertEqual(child.formatting.data.first?.value,"99");XCTAssertEqual(child.formatting.data.first?.label,"Cost in dollars")
        XCTAssertEqual(child.formatting.hyperlinks.count,1)
        XCTAssertEqual(diagram.page.nodes.filter{$0.text == "Inherited inner"}.count,1)
    }
    func testInheritedConnectorLabelEditKeepsNestedPlacementAndMasterIdentity() throws {
        var diagram = try VisioFormat.read(from:fixture()).diagram;diagram.page.edges[0].label = "Edited master link"
        let (restored,parts) = try publicRead(diagram)
        XCTAssertEqual(restored.page.edges.filter{$0.label == "Edited master link"}.count,1);XCTAssertEqual(restored.page.edges.count,2)
        let document = try VisioXML.document(parts["visio/pages/page1.xml"]!)
        let shape = try XCTUnwrap(document.rootElement()!.firstLocal("Shapes")!.allShapes.first{$0.attr("MasterShape") == "5"})
        XCTAssertEqual(shape.elementsLocal("Cell").count,0);XCTAssertEqual((shape.parent?.parent as? XMLElement)?.attr("ID"),"10")
    }
    func testMultiRootMasterBecomesAGroupRatherThanDroppingOtherRoots() throws {
        let diagram = try VisioFormat.read(from:fixture("",true)).diagram
        XCTAssertEqual(diagram.page.nodes.count,9);XCTAssertEqual(diagram.page.edges.count,2)
        XCTAssertEqual(diagram.page.nodes.filter{$0.parentID == nil && $0.formatting.isGroup}.count,2)
    }
    func testInheritedPropertyAndHyperlinkDeletionDoesNotRestoreMasterRows() throws {
        var diagram = try VisioFormat.read(from:fixture()).diagram
        let index = diagram.page.nodes.firstIndex{$0.text == "Inherited left"}!
        diagram.page.nodes[index].formatting.data = [];diagram.page.nodes[index].formatting.hyperlinks = []
        let (restored,_) = try publicRead(diagram)
        let root = restored.page.nodes.first{$0.formatting.sourceShapeID == "10"}!
        let child = try XCTUnwrap(restored.page.nodes.first{$0.parentID == root.id && $0.text == "Inherited left"})
        XCTAssertTrue(child.formatting.data.isEmpty);XCTAssertTrue(child.formatting.hyperlinks.isEmpty)
        let sibling = restored.page.nodes.first{$0.parentID != root.id && $0.text == "Inherited left"}!
        XCTAssertEqual(sibling.formatting.data.count,1);XCTAssertEqual(sibling.formatting.hyperlinks.count,1)
    }
    func testHyperlinkEditsOverrideTheExistingInheritedRow() throws {
        var diagram = try VisioFormat.read(from:fixture()).diagram
        let index = diagram.page.nodes.firstIndex{$0.text == "Inherited left"}!
        diagram.page.nodes[index].formatting.hyperlinks[0].address = "https://example.com/updated"
        let (restored,_) = try publicRead(diagram)
        let child = restored.page.nodes.first{$0.formatting.sourceShapeID == diagram.page.nodes[index].formatting.sourceShapeID}!
        XCTAssertEqual(child.formatting.hyperlinks.count,1);XCTAssertEqual(child.formatting.hyperlinks[0].address,"https://example.com/updated")
    }
    func testMovingAChildOfAFlippedRotatedMasterRoundTripsItsPhysicalGeometry() throws {
        var diagram = try VisioFormat.read(from:fixture("<Cell N=\"FlipX\" V=\"1\"/><Cell N=\"Angle\" V=\"1.570796326794897\"/>")).diagram
        let index = diagram.page.nodes.firstIndex{$0.text == "Inherited left"}!
        diagram.page.nodes[index].x += 18;diagram.page.nodes[index].y -= 11
        let expected = diagram.page.nodes[index],(restored,_) = try publicRead(diagram)
        let child = restored.page.nodes.first{$0.formatting.sourceShapeID == expected.formatting.sourceShapeID}!
        XCTAssertEqual(child.x,expected.x,accuracy:0.000001);XCTAssertEqual(child.y,expected.y,accuracy:0.000001)
        XCTAssertEqual(child.width,expected.width,accuracy:0.000001);XCTAssertEqual(child.rotation,expected.rotation,accuracy:0.000001)
    }
    func testExistingMasterOverrideDeletionEmitsATombstone() throws {
        var diagram = try VisioFormat.read(from:fixture("<Shapes><Shape ID=\"31\" MasterShape=\"2\"><Text>Local label</Text></Shape></Shapes>")).diagram
        let child = diagram.page.nodes.first{$0.text == "Local label"}!
        diagram.page.nodes.removeAll{$0.id == child.id};diagram.page.edges.removeAll{$0.source == child.id || $0.target == child.id}
        let (restored,parts) = try publicRead(diagram)
        XCTAssertEqual(restored.page.nodes.filter{$0.text == "Inherited left"}.count,1)
        let document = try VisioXML.document(parts["visio/pages/page1.xml"]!)
        XCTAssertEqual(document.rootElement()!.firstLocal("Shapes")!.allShapes.first{$0.attr("ID") == "31"}?.attr("Del"),"1")
    }
    func testDeletingAnInheritedGroupDoesNotMaterializeItsDescendants() throws {
        var diagram = try VisioFormat.read(from:fixture()).diagram
        let nested = diagram.page.nodes.first{$0.formatting.sourceShapeID != "10" && $0.formatting.sourceShapeID != "20" && $0.formatting.isGroup}!
        let removed = diagram.page.descendants(of:nested.id).union([nested.id])
        diagram.page.nodes.removeAll{removed.contains($0.id)};diagram.page.edges.removeAll{removed.contains($0.source) || removed.contains($0.target)}
        let (restored,parts) = try publicRead(diagram)
        XCTAssertEqual(restored.page.nodes.count,7)
        let document = try VisioXML.document(parts["visio/pages/page1.xml"]!)
        XCTAssertFalse(document.rootElement()!.firstLocal("Shapes")!.allShapes.contains{$0.attr("MasterShape") == "4"})
        XCTAssertTrue(document.rootElement()!.firstLocal("Shapes")!.allShapes.contains{$0.attr("MasterShape") == "3" && $0.attr("Del") == "1"})
    }
    func testMalformedMasterShapeIDsAndDuplicateOverridesAreRejected() throws {
        let source = try fixture();var parts = try VisioPackage.read(source)
        let xml = String(decoding:parts["visio/masters/master1.xml"]!,as:UTF8.self).replacingOccurrences(of:"ID=\"4\"",with:"ID=\"2\"")
        parts["visio/masters/master1.xml"] = Data(xml.utf8);try VisioPackage.write(parts,to:source)
        XCTAssertThrowsError(try VisioFormat.read(from:source))
        let duplicate = try fixture("<Shapes><Shape ID=\"31\" MasterShape=\"2\"/><Shape ID=\"32\" MasterShape=\"2\"/></Shapes>")
        XCTAssertThrowsError(try VisioFormat.read(from:duplicate))
    }
    func testPublicMasterOverrideAndExpandedBinaryOutputParseIndependently() throws {
        let helper = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/MacVisio.app/Contents/Helpers/vsd2xhtml")
        guard FileManager.default.isExecutableFile(atPath:helper.path) else { throw XCTSkip("Build the app with its independent reader first.") }
        let source = try fixture();var diagram = try VisioFormat.read(from:source).diagram
        diagram.page.nodes[diagram.page.nodes.firstIndex{$0.text == "Inherited inner"}!].text = "Edited master descendant"
        let edited = try url("master-edited.vsdx"),binary = try url("master-expanded.vsd")
        try VisioFormat.write(diagram,to:edited);var parts = try VisioPackage.read(edited);stripMetadata(&parts);try VisioPackage.write(parts,to:edited)
        try VSDBinaryFormat.write(diagram,to:binary)
        for file in [edited,binary] {
            let process = Process(),output = Pipe();process.executableURL = helper;process.arguments = [file.path];process.standardOutput = output
            try process.run();let data = output.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus,0);let text = String(decoding:data,as:UTF8.self)
            XCTAssertTrue(text.contains("Edited master descendant"));XCTAssertTrue(text.contains("<svg"))
            if file == binary { XCTAssertTrue(text.contains("Inherited left"));XCTAssertTrue(text.contains("Master link")) }
        }
        if let path = ProcessInfo.processInfo.environment["MACVISIO_MASTER_ARTIFACT_DIR"] {
            let directory = URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            for (file,name) in [(source,"masters-source.vsdx"),(edited,"masters-edited.vsdx"),(binary,"masters-expanded.vsd")] { try Data(contentsOf:file).write(to:directory.appendingPathComponent(name),options:.atomic) }
            let encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
            try encoder.encode(diagram).write(to:directory.appendingPathComponent("masters-editor.macvisio"),options:.atomic)
        }
    }
    func testMasterFormulasResolveWithinTheirInstanceAfterEditing() throws {
        let original = try VisioFormat.read(from:fixture()).diagram;var edited = original
        let root = edited.page.nodes.firstIndex{$0.formatting.sourceShapeID == "10"}!
        edited.page.nodes[root].width = 432
        let result = ShapeSheetEngine.recalculate(edited,previous:original)
        XCTAssertTrue(result.issues.isEmpty)
        let left = result.diagram.page.nodes.filter{$0.text == "Inherited left"}
        XCTAssertEqual(left.first{$0.parentID == edited.page.nodes[root].id}?.formatting.sheet["User.Span"]?.value,"6")
        XCTAssertEqual(left.first{$0.parentID != edited.page.nodes[root].id}?.formatting.sheet["User.Span"]?.value,"4")
    }
    func testRecalculationRetainsFlippedMasterDescendantFrames() throws {
        let diagram = try VisioFormat.read(from:fixture("<Cell N=\"FlipX\" V=\"1\"/><Cell N=\"Angle\" V=\"1.570796326794897\"/>")).diagram
        let result = ShapeSheetEngine.recalculate(diagram)
        XCTAssertTrue(result.issues.isEmpty)
        for node in diagram.page.nodes {
            let restored = result.diagram.page.nodes.first{$0.id == node.id}!
            XCTAssertEqual(node.x,restored.x,accuracy:0.000001);XCTAssertEqual(node.y,restored.y,accuracy:0.000001);XCTAssertEqual(node.rotation,restored.rotation,accuracy:0.000001)
        }
    }
    func testVirtualAndNewIDsWrapAtUnsignedMaximumWithoutColliding() throws {
        let source = try fixture();var parts = try VisioPackage.read(source)
        parts["visio/pages/page1.xml"] = Data(String(decoding:parts["visio/pages/page1.xml"]!,as:UTF8.self).replacingOccurrences(of:"ID=\"55\"",with:"ID=\"4294967295\"").utf8)
        try VisioPackage.write(parts,to:source);var diagram = try VisioFormat.read(from:source).diagram
        let existing = Set(diagram.visioArchive!.pages[0].nodeIDs.values)
        XCTAssertTrue(existing.contains("0"));XCTAssertEqual(diagram.page.nodes.count,9)
        diagram.page.nodes.append(DiagramNode(x:100,y:100,text:"Added safely"))
        let (restored,_) = try publicRead(diagram)
        XCTAssertEqual(restored.page.nodes.count,10);XCTAssertTrue(restored.page.nodes.contains{$0.text == "Added safely"})
    }
    func testOlderNativeMetadataCannotConcealImplicitMasterChildren() throws {
        var diagram = try VisioFormat.read(from:fixture()).diagram
        diagram.page.nodes[diagram.page.nodes.firstIndex{$0.text == "Unrelated"}!].text = "Saved by an older build"
        let file = try url("older-metadata.vsdx");try VisioFormat.write(diagram,to:file)
        var parts = try VisioPackage.read(file),envelope = try JSONSerialization.jsonObject(with:parts["macvisio/document.json"]!) as! [String:Any]
        diagram.visioArchive = nil;diagram.page.nodes.removeAll{$0.parentID != nil};diagram.page.edges = []
        envelope["diagram"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(diagram))
        envelope.removeValue(forKey:"masterExpansionVersion");envelope.removeValue(forKey:"bindings")
        parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:envelope);try VisioPackage.write(parts,to:file)
        let restored = try VisioFormat.read(from:file)
        XCTAssertEqual(restored.diagram.page.nodes.count,9);XCTAssertEqual(restored.diagram.page.edges.count,2)
        XCTAssertTrue(restored.warnings.contains{$0.contains("Older native metadata")})
    }
    func testNativeEditorEditsAndUndoesAnInheritedDescendant() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument();try document.read(from:fixture(),ofType:MacVisioDocument.visioType);document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        XCTAssertEqual(document.diagram.page.nodes.count,9)
        let index = document.diagram.page.nodes.firstIndex{$0.text == "Inherited inner"}!
        var edited = document.diagram;edited.page.nodes[index].text = "Edited master descendant"
        document.replace(with:edited,action:"Edit inherited text")
        XCTAssertEqual(document.diagram.page.nodes[index].text,"Edited master descendant")
        document.undoManager?.undo();XCTAssertEqual(document.diagram.page.nodes[index].text,"Inherited inner")
        document.undoManager?.redo();XCTAssertEqual(document.diagram.page.nodes[index].text,"Edited master descendant")
        if let path = ProcessInfo.processInfo.environment["MACVISIO_MASTER_ARTIFACT_DIR"],let view = controller.window?.contentView {
            view.layoutSubtreeIfNeeded();controller.canvas.fitPage();view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
            let data = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            try data.write(to:URL(fileURLWithPath:path).appendingPathComponent("masters-editor.png"),options:.atomic)
        }
    }
}
