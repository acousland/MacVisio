import Foundation
import XCTest
@testable import MacVisio

final class PageShapeSheetTests:XCTestCase {
    private var directories:[URL] = []
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at:directory) };super.tearDown() }
    private func url(_ name:String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-page-sheet-\(UUID())",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);directories.append(directory);return directory.appendingPathComponent(name)
    }
    private func fixture() throws -> URL {
        var diagram = Diagram();diagram.page.nodes = [DiagramNode(text:"Page Sheet test")]
        let file = try url("source.vsdx");try VisioFormat.write(diagram,to:file)
        var parts = try VisioPackage.read(file)
        let index = try VisioXML.document(parts["visio/pages/pages.xml"]!),sheet = index.rootElement()!.firstLocal("Page")!.firstLocal("PageSheet")!
        VisioXML.set(sheet,"PageLeftMargin","0.25").setAttr("U","IN")
        VisioXML.set(sheet,"PageTopMargin","0.5",formula:"ThePage!PageLeftMargin*2").setAttr("U","IN")
        let user = VisioXML.section(sheet,"User"),userCode = XMLElement(name:"Row");userCode.setAttr("N","Code");userCode.setAttr("IX","0");VisioXML.set(userCode,"Value","4");user.addChild(userCode)
        let derived = XMLElement(name:"Row");derived.setAttr("N","Derived");derived.setAttr("IX","1");VisioXML.set(derived,"Value","0",formula:"ThePage!User.Code*3");user.addChild(derived)
        let property = VisioXML.section(sheet,"Property"),owner = XMLElement(name:"Row");owner.setAttr("N","Owner");owner.setAttr("IX","0");VisioXML.set(owner,"Value","Architecture",formula:nil).setAttr("U","STR");property.addChild(owner)
        parts["visio/pages/pages.xml"] = index.xmlData(options:.nodePreserveAll)
        try VisioPackage.write(parts,to:file);return file
    }
    private func stripMetadata(_ parts:inout [String:Data]) throws {
        parts.removeValue(forKey:"macvisio/document.json")
        if let data = parts["_rels/.rels"] {
            let rels = try VisioXML.document(data)
            for relation in rels.rootElement()!.elementsLocal("Relationship") where relation.attr("Type")?.hasPrefix("urn:macvisio") == true { relation.detach() }
            parts["_rels/.rels"] = rels.xmlData(options:.nodePreserveAll)
        }
    }
    func testImportsAndResolvesPageCellsAndPageUserPropertyRows() throws {
        let imported = try VisioFormat.read(from:fixture()).diagram,page = imported.page,id = try XCTUnwrap(page.nodes.first?.id)
        XCTAssertEqual(page.sheet?["PageLeftMargin"]?.unit,"IN")
        XCTAssertEqual(page.sheet?["PageTopMargin"]?.formula,"ThePage!PageLeftMargin*2")
        XCTAssertEqual(page.sheet?["User.Derived"]?.formula,"ThePage!User.Code*3")
        XCTAssertEqual(page.sheet?["Prop.Owner"]?.value,"Architecture")
        let context = ShapeSheetContext(page:page)
        XCTAssertEqual(try context.number(id,"ThePage!PageLeftMargin"),0.25,accuracy:1e-12)
        XCTAssertEqual(try context.number(id,"ThePage!PageTopMargin"),0.5,accuracy:1e-12)
        XCTAssertEqual(try context.number(id,"ThePage!User.Derived"),12,accuracy:1e-12)
        XCTAssertEqual(try context.value(id,"ThePage!Prop.Owner"),.string("Architecture"))
    }
    func testPageCellEditRoundTripsThroughPublicVSDXAndFormulaCyclesFailSafely() throws {
        let source = try fixture(),destination = try url("edited.vsdx");var diagram = try VisioFormat.read(from:source).diagram
        diagram.page.nodes[0].text = "edited"
        diagram.page.sheet?["PageLeftMargin"] = ShapeSheetCell(value:"0.75",unit:"IN")
        try VisioFormat.write(diagram,to:destination)
        var parts = try VisioPackage.read(destination);try stripMetadata(&parts);try VisioPackage.write(parts,to:destination)
        let page = try VisioFormat.read(from:destination).diagram.page
        XCTAssertEqual(page.sheet?["PageLeftMargin"]?.value,"0.75")
        XCTAssertEqual(page.sheet?["PageTopMargin"]?.formula,"ThePage!PageLeftMargin*2")
        XCTAssertEqual(page.sheet?["User.Derived"]?.formula,"ThePage!User.Code*3")
        var cyclic = page;cyclic.sheet?["User.A"] = ShapeSheetCell(value:"0",formula:"ThePage!User.B")
        cyclic.sheet?["User.B"] = ShapeSheetCell(value:"0",formula:"ThePage!User.A")
        let host = try XCTUnwrap(cyclic.nodes.first?.id)
        XCTAssertThrowsError(try ShapeSheetContext(page:cyclic).value(host,"ThePage!User.A"))
    }
}
