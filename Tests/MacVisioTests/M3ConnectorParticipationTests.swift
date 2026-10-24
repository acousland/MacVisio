import AppKit
import XCTest
@testable import MacVisio

/// Local connector copy/layer/scene regressions, independent of native metadata.
final class M3ConnectorParticipationTests: XCTestCase {
    private var files: [URL] = []
    override func tearDown() {
        for file in files { try? FileManager.default.removeItem(at: file) }
        super.tearDown()
    }
    private func file() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-connector-participation-\(UUID()).vsdx")
        files.append(url); return url
    }
    private func publicFixture() throws -> Diagram {
        let seed = try XCTUnwrap(Bundle.module.url(forResource: "m3-intelligent", withExtension: "vsdx", subdirectory: "Fixtures/M3"))
        var parts = try VisioPackage.read(seed)
        parts.removeValue(forKey: "macvisio/document.json")
        let index = try VisioXML.document(XCTUnwrap(parts["visio/pages/pages.xml"]))
        let sheet = try XCTUnwrap(index.rootElement()?.firstLocal("Page")?.firstLocal("PageSheet"))
        for section in sheet.elementsLocal("Section") where section.attr("N") == "Layer" { section.detach() }
        sheet.addChild(try VisioXML.element("""
        <Section N="Layer"><Row IX="4"><Cell N="Name" V="Visible"/><Cell N="Visible" V="1"/><Cell N="Lock" V="0"/><Cell N="Print" V="1"/></Row><Row IX="9"><Cell N="Name" V="Secondary"/><Cell N="Visible" V="1"/><Cell N="Lock" V="0"/><Cell N="Print" V="1"/></Row></Section>
        """))
        parts["visio/pages/pages.xml"] = index.xmlData(options: .nodePreserveAll)
        parts["visio/pages/page1.xml"] = Data("""
        <PageContents xmlns="http://schemas.microsoft.com/office/visio/2012/main" xml:space="preserve"><Shapes>
        <Shape ID="10" Type="Shape"><Cell N="PinX" V="2"/><Cell N="PinY" V="5"/><Cell N="Width" V="2"/><Cell N="Height" V="1"/>
        <Section N="User"><Row N="Base"><Cell N="Value" V="5"/></Row><Row N="Size"><Cell N="Value" V="0.2"/></Row><Row N="Margin"><Cell N="Value" V="0.1"/></Row><Row N="Edge"><Cell N="Value" V="12" F="Sheet.30!User.Weight"/></Row></Section><Text>A</Text></Shape>
        <Shape ID="20" Type="Shape"><Cell N="PinX" V="5"/><Cell N="PinY" V="5"/><Cell N="Width" V="2"/><Cell N="Height" V="1"/>
        <Section N="User"><Row N="Base"><Cell N="Value" V="7"/></Row><Row N="Margin"><Cell N="Value" V="0.1"/></Row></Section><Text>B</Text></Shape>
        <Shape ID="30" Type="Shape"><Cell N="OneD" V="1"/><Cell N="BeginX" V="2"/><Cell N="BeginY" V="5"/><Cell N="EndX" V="5"/><Cell N="EndY" V="5"/><Cell N="PinX" V="3.5"/><Cell N="PinY" V="5"/><Cell N="Width" V="3"/><Cell N="Height" V="0"/><Cell N="LayerMember" V="4;9"/>
        <Cell N="Comment" V="Sheet.10!User.Base" F="&quot;Sheet.10!User.Base&quot;" U="STR"/>
        <Section N="User"><Row N="Weight"><Cell N="Value" V="12" F="GUARD(Sheet.10!User.Base+Sheet.20!User.Base)" U="NO"/></Row></Section>
        <Section N="Property"><Row N="Cost"><Cell N="Value" V="7" F="Sheet.20!User.Base" U="NO"/><Cell N="Type" V="2"/><Cell N="Prompt" V="Keep this prompt"/></Row></Section>
        <Section N="Character"><Row IX="3"><Cell N="Font" V="0"/><Cell N="Size" V="0.2" F="GUARD(Sheet.10!User.Size)" U="IN"/><Cell N="Color" V="#123456"/></Row></Section>
        <Section N="Paragraph"><Row IX="4"><Cell N="HorzAlign" V="0"/><Cell N="IndLeft" V="0.1" F="GUARD(Sheet.20!User.Margin)" U="IN"/></Row></Section>
        <Section N="Field"><Row IX="7"><Cell N="Value" V="12" F="Sheet.30!User.Weight"/><Cell N="Format" V="0.0" U="STR"/><Cell N="Type" V="2"/></Row></Section>
        <Text><cp IX="3"/><pp IX="4"/><fld IX="7">12.0</fld></Text><OpaqueConnectorFlag Keep="yes"/>
        </Shape></Shapes><Connects><Connect FromSheet="30" FromCell="BeginX" ToSheet="10" ToCell="PinX"/><Connect FromSheet="30" FromCell="EndX" ToSheet="20" ToCell="PinX"/></Connects></PageContents>
        """.utf8)
        return try VisioFormat.readPublic(parts: parts, title: "Authored connector participation").diagram
    }
    private func publicSave(_ input: Diagram) throws -> (Diagram, [String: Data]) {
        let url = file(); try VisioFormat.write(input, to: url)
        let parts = try VisioPackage.read(url)
        return (try VisioFormat.readPublic(parts: parts, title: input.title).diagram, parts)
    }
    private func assertMembership(_ parts: [String: Data], names: Set<String>, file: StaticString = #filePath, line: UInt = #line) throws {
        let index = try VisioXML.document(XCTUnwrap(parts["visio/pages/pages.xml"]))
        let rows = index.rootElement()?.firstLocal("Page")?.firstLocal("PageSheet")?.elementsLocal("Section").first { $0.attr("N") == "Layer" }?.elementsLocal("Row") ?? []
        let byID = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, String)? in
            guard let id = row.attr("IX"), let name = VisioXML.value(row, "Name") else { return nil }; return (id, name)
        })
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        let edge = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "30" })
        let ids = (VisioXML.value(edge, "LayerMember") ?? "").split(separator: ";").map(String.init)
        XCTAssertEqual(ids.count, names.count, file: file, line: line)
        XCTAssertEqual(Set(ids.compactMap { byID[$0] }), names, file: file, line: line)
        if names.isEmpty { XCTAssertNil(VisioXML.value(edge, "LayerMember"), file: file, line: line) }
    }

    func testPasteRemapsConnectorAndNodeReferencesWithCollidingPublicIDs() throws {
        let source = try publicFixture(), before = source
        let fragment = DiagramOperations.fragment(Set(source.page.nodes.map(\.id)), from: source.page)
        var destination = source.page
        destination.nodes[0].formatting.sheet["User.Base"]?.value = "100"
        destination.nodes[1].formatting.sheet["User.Base"]?.value = "200"
        let selected = try DiagramOperations.insert(fragment, into: &destination)
        let first = try XCTUnwrap(destination.nodes.first { selected.contains($0.id) && $0.text == "A" })
        let second = try XCTUnwrap(destination.nodes.first { selected.contains($0.id) && $0.text == "B" })
        let edge = try XCTUnwrap(destination.edges.first { $0.id != source.page.edges[0].id })
        let a = try XCTUnwrap(first.formatting.sourceShapeID), b = try XCTUnwrap(second.formatting.sourceShapeID), e = try XCTUnwrap(edge.sourceShapeID)
        XCTAssertEqual(edge.formatting.sourceShapeID, e)
        XCTAssertEqual(edge.source, first.id); XCTAssertEqual(edge.target, second.id)
        XCTAssertEqual(first.formatting.sheet["User.Edge"]?.formula, "Sheet.\(e)!User.Weight")
        XCTAssertEqual(edge.formatting.sheet["User.Weight"], ShapeSheetCell(value: "12", formula: "GUARD(Sheet.\(a)!User.Base+Sheet.\(b)!User.Base)", unit: "NO"))
        XCTAssertEqual(edge.formatting.sheet["Prop.Cost"]?.formula, "Sheet.\(b)!User.Base")
        XCTAssertEqual(edge.formatting.sheet["Comment"]?.formula, "\"Sheet.10!User.Base\"")
        XCTAssertEqual(edge.formatting.textFields?.first?.cells["Value"]?.formula, "Sheet.\(e)!User.Weight")
        XCTAssertEqual(edge.formatting.textRuns?.first?.character.cells["Size"]?.formula, "GUARD(Sheet.\(a)!User.Size)")
        XCTAssertEqual(edge.formatting.textRuns?.first?.paragraph.cells["IndLeft"]?.formula, "GUARD(Sheet.\(b)!User.Margin)")
        XCTAssertEqual(edge.formatting.data, source.page.edges[0].formatting.data)
        XCTAssertEqual(source, before)

        var output = source; output.page = destination
        let calculated = DiagramCalculation.recalculate(output).diagram
        XCTAssertEqual(calculated.page.edges.first { $0.id == edge.id }?.label, "12.0", "The copy must resolve copied values 5+7, not destination values 100+200.")
        let (reopened, _) = try publicSave(calculated)
        let restored = try XCTUnwrap(reopened.page.edges.first { $0.sourceShapeID == e })
        XCTAssertEqual(restored.label, "12.0")
        XCTAssertEqual(restored.formatting.sheet["User.Weight"]?.formula, edge.formatting.sheet["User.Weight"]?.formula)
        XCTAssertEqual(restored.formatting.textFields?.first?.cells["Value"]?.formula, "Sheet.\(e)!User.Weight")
        XCTAssertEqual(Set(restored.formatting.layerNames), ["Visible", "Secondary"])
    }

    func testCopyUsesLegacyDetailSourceIDAndKeepsPlainConnectorDetailsOptional() throws {
        var node = DiagramNode(); node.formatting.sourceShapeID = "10"
        var edge = DiagramEdge(source: node.id, target: node.id)
        edge.formatting.sourceShapeID = "30"
        edge.formatting.sheet["User.Self"] = ShapeSheetCell(value: "2", formula: "Sheet.30!User.Value")
        var page = DiagramPage(nodes: [node], edges: [edge])
        let fragment = DiagramOperations.fragment([node.id], from: page)
        XCTAssertEqual(fragment.edges[0].sourceShapeID, "30")
        var destination = DiagramPage(); try DiagramOperations.insert(fragment, into: &destination, reservedIDs: ["30"])
        let copied = destination.edges[0], id = try XCTUnwrap(copied.sourceShapeID)
        XCTAssertEqual(copied.formatting.sourceShapeID, id)
        XCTAssertEqual(copied.formatting.sheet["User.Self"]?.formula, "Sheet.\(id)!User.Value")
        page.edges[0].details = nil
        let plain = DiagramOperations.fragment([node.id], from: page)
        XCTAssertNil(plain.edges[0].details)
        var plainDestination = DiagramPage(); try DiagramOperations.insert(plain, into: &plainDestination)
        XCTAssertNil(plainDestination.edges[0].details)
    }

    func testSecondaryLayerRestrictsModelRuntimeHitTestingAndOutput() throws {
        let input = try publicFixture(), edge = input.page.edges[0]
        for restriction in ["hidden", "locked", "nonprinting"] {
            var page = input.page
            page.layers![1].visible = restriction != "hidden"
            page.layers![1].locked = restriction == "locked"
            page.layers![1].printable = restriction != "nonprinting"
            let route = DiagramGeometry.route(edge, in: page)
            let runtime = PageRuntime(page: page, preparedRoutes: [edge.id: route])
            XCTAssertEqual(page.isVisible(edge), restriction != "hidden")
            XCTAssertEqual(runtime.isVisible(edgeID: edge.id), restriction != "hidden")
            XCTAssertEqual(page.isLocked(edge), restriction == "locked")
            XCTAssertEqual(runtime.isLocked(edgeID: edge.id), restriction == "locked")
            XCTAssertEqual(page.isVisible(edge, printing: true), restriction == "locked")
            if restriction != "nonprinting" {
                let bounds = route.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }.insetBy(dx: -5, dy: -5)
                XCTAssertFalse(runtime.edgeCandidates(intersecting: bounds, includeLocked: false).values.contains { $0.id == edge.id })
            }
            XCTAssertEqual(DiagramDrawing.svg(page).contains(">12.0</"), restriction == "locked")
        }
    }

    func testWarmMembershipEditVisitsOnlyChangedConnectorAndRetainsParentRestrictions() throws {
        var page = try publicFixture().page
        page.layers![1].locked = true
        let edge = page.edges[0], runtime = PageRuntime(page: page)
        XCTAssertTrue(runtime.isLocked(edgeID: edge.id))
        var changed = page; changed.edges[0].formatting.layerNames = ["Visible"]
        let work = runtime.apply(page: changed, changes: .between(page, changed))
        XCTAssertFalse(work.didRebuild); XCTAssertEqual(work.nodeVisits, 0); XCTAssertEqual(work.edgeVisits, 1)
        XCTAssertFalse(runtime.isLocked(edgeID: edge.id))
        let beforeParent = changed
        changed.nodes[0].locked = true; changed.edges[0].parentID = changed.nodes[0].id
        runtime.apply(page: changed, changes: .between(beforeParent, changed))
        XCTAssertTrue(changed.isLocked(changed.edges[0])); XCTAssertTrue(runtime.isLocked(edgeID: edge.id))
    }

    func testLayerRenameReorderAndDeletionRetainCompletePublicMembership() throws {
        let original = try publicFixture()
        XCTAssertEqual(try VisioPreservation.prepared(original).parts, original.visioArchive?.parts)
        var renamed = original
        let previous = try XCTUnwrap(original.page.layers)
        var updated = try LayerPropertiesEditing.apply([
            ["Renamed visible", "Yes", "No", "Yes", "Yes", "Yes", "", "0"],
            ["Renamed secondary", "Yes", "No", "Yes", "Yes", "Yes", "", "0"]
        ], previous: previous)
        updated.reverse()
        renamed.page = LayerPropertiesEditing.replacing(previous, with: updated, on: renamed.page)
        XCTAssertEqual(Set(renamed.page.edges[0].formatting.layerNames), ["Renamed visible", "Renamed secondary"])
        for fresh in [false, true] {
            var output = renamed
            if fresh { output.visioArchive = nil; output.definitions = nil }
            let (reopened, parts) = try publicSave(output)
            try assertMembership(parts, names: ["Renamed visible", "Renamed secondary"])
            XCTAssertEqual(Set(reopened.page.edges[0].formatting.layerNames), ["Renamed visible", "Renamed secondary"])
            var removed = output
            removed.page = LayerPropertiesEditing.replacing(updated, with: [], on: removed.page)
            XCTAssertNil(removed.page.edges[0].layer); XCTAssertEqual(removed.page.edges[0].formatting.layerNames, [])
            let (_, emptyParts) = try publicSave(removed)
            try assertMembership(emptyParts, names: [])
        }
    }

    func testMultiLayerConnectorRetainsOwnColorAndSingleLayerUsesOverride() {
        var page = DiagramPage()
        page.layers = [DiagramLayer(name: "Red", color: "#CC3300"), DiagramLayer(name: "Blue", color: "#0066CC")]
        var edge = DiagramEdge(source: UUID(), target: UUID()); edge.color = "#123456"; edge.layer = "Red"
        edge.formatting.layerNames = ["Red", "Blue"]
        XCTAssertEqual(DiagramDrawing.layerColored(edge, in: page).color, "#123456")
        edge.formatting.layerNames = ["Blue"]; edge.layer = nil
        XCTAssertEqual(DiagramDrawing.layerColored(edge, in: page).color, "#0066CC")
    }

    func testLayerPropertyEditDoesNotLocalizeInheritedConnectorMembership() throws {
        var parts = try XCTUnwrap(publicFixture().visioArchive).parts
        let master = try VisioXML.document(XCTUnwrap(parts["visio/masters/master1.xml"]))
        let prototype = try XCTUnwrap(master.rootElement()?.firstLocal("Shapes")?.firstLocal("Shape"))
        VisioXML.set(prototype, "LayerMember", "4;9")
        parts["visio/masters/master1.xml"] = master.xmlData(options: .nodePreserveAll)
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        let connector = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "30" })
        connector.setAttr("Master", "7")
        connector.elementsLocal("Cell").first { $0.attr("N") == "LayerMember" }?.detach()
        parts["visio/pages/page1.xml"] = page.xmlData(options: .nodePreserveAll)
        let original = try VisioFormat.readPublic(parts: parts, title: "Inherited connector layers").diagram
        XCTAssertEqual(Set(original.page.edges[0].formatting.layerNames), ["Visible", "Secondary"])
        var changed = original; changed.page.layers![1].color = "#CC3300"
        let (_, savedParts) = try publicSave(changed)
        let savedPage = try VisioXML.document(XCTUnwrap(savedParts["visio/pages/page1.xml"]))
        let saved = try XCTUnwrap(savedPage.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "30" })
        XCTAssertNil(VisioXML.value(saved, "LayerMember"))
        XCTAssertEqual(savedParts["visio/masters/master1.xml"], parts["visio/masters/master1.xml"])
        changed.page = LayerPropertiesEditing.replacing(try XCTUnwrap(changed.page.layers), with: [], on: changed.page)
        let (removed, removedParts) = try publicSave(changed)
        XCTAssertEqual(removed.page.edges[0].formatting.layerNames, [])
        let removedPage = try VisioXML.document(XCTUnwrap(removedParts["visio/pages/page1.xml"]))
        let cleared = try XCTUnwrap(removedPage.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "30" })
        XCTAssertEqual(VisioXML.value(cleared, "LayerMember"), "", "An explicit empty override must keep master membership from returning.")
    }

    func testConnectorOnlyBackgroundFieldsUseEachForegroundWithoutMutatingStoredCaches() throws {
        var diagram = Diagram(); diagram.page.name = "First"
        var second = DiagramPage(name: "Second"), background = DiagramPage(name: "Shared")
        background.isBackground = true
        var edge = DiagramEdge(source: UUID(), target: UUID(), style: .straight)
        edge.sourcePosition = DiagramPoint(x: 20, y: 30); edge.targetPosition = DiagramPoint(x: 220, y: 30)
        var text = try TextFieldEngine.inserting(formula: "PAGENAME() & \" · \" & PAGENUMBER() & \"/\" & PAGECOUNT()", into: edge.textNode)
        text.formatting.textRuns![0].text = "cached"
        text.formatting.textFields![0].cached = "cached"
        edge.details = text.details; edge.label = "cached"; background.edges = [edge]
        diagram.page.backgroundPageID = background.id; second.backgroundPageID = background.id
        diagram.pages += [second, background]
        let before = diagram
        XCTAssertTrue(background.nodes.isEmpty)
        XCTAssertEqual(diagram.scene().backgrounds[0].edges[0].label, "First · 1/2")
        XCTAssertEqual(diagram.scene(for: second.id).backgrounds[0].edges[0].label, "Second · 2/2")
        XCTAssertEqual(diagram, before)
        let (reopened, _) = try publicSave(diagram), saved = reopened
        let reopenedSecond = try XCTUnwrap(reopened.pages.first { $0.name == "Second" })
        XCTAssertEqual(reopened.scene().backgrounds[0].edges[0].label, "First · 1/2")
        XCTAssertEqual(reopened.scene(for: reopenedSecond.id).backgrounds[0].edges[0].label, "Second · 2/2")
        XCTAssertEqual(reopened, saved)
    }
}
