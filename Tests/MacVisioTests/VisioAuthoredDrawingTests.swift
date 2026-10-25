import XCTest
@testable import MacVisio

/// Regressions found by the Visio round-trip reference, on drawings Visio 2019 authored itself
/// (Fixtures/Reference/visio-*.vsdx, from scripts/windows/VisioRecipes.ps1).
final class VisioAuthoredDrawingTests: XCTestCase {
    private func open(_ name: String) throws -> MacVisioDocument {
        _ = NSApplication.shared
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "vsdx", subdirectory: "Fixtures/Reference"))
        let document = MacVisioDocument()
        try document.read(from: url, ofType: MacVisioDocument.visioType)
        return document
    }
    private func node(_ document: MacVisioDocument, _ shapeID: String) throws -> DiagramNode {
        let binding = try XCTUnwrap(document.diagram.visioArchive?.pages.first { $0.pageID == document.diagram.page.id })
        return try XCTUnwrap(document.diagram.page.nodes.first { binding.nodeIDs[$0.id] == shapeID })
    }
    private func savedPage(_ document: MacVisioDocument) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("visio-authored-\(UUID()).vsdx")
        defer { try? FileManager.default.removeItem(at: url) }
        try VisioFormat.write(document.diagram, to: url)
        return String(decoding: try XCTUnwrap(VisioPackage.read(url)["visio/pages/page1.xml"]), as: UTF8.self)
    }

    func testStencilShapesMoveAndKeepTheirTextDrivenHeight() throws {
        let document = try open("visio-flowchart")
        let step = try node(document, "2")
        XCTAssertEqual(step.height / 72, 15 / 25.4, accuracy: 1e-9)
        var next = document.diagram
        let index = try XCTUnwrap(next.page.nodes.firstIndex { $0.id == step.id })
        next.page.nodes[index].x += 72
        document.replace(with: next, action: "Move")
        XCTAssertNil(document.lastCalculationJobError, "An inherited Relationships cell must not make a master instance immovable.")
        let moved = try node(document, "2")
        XCTAssertEqual(moved.x, step.x + 72, accuracy: 1e-9)
        // Height = MAX(User.DefaultHeight,CEILING(TEXTHEIGHT(TheText,TxtWidth)+0MM,1)) rounds in millimetres.
        for id in ["1", "2", "3", "4", "5"] { XCTAssertLessThan(try node(document, id).height, 72, id) }
    }

    func testUnrelatedShapesAreNotRewrittenWhenAPageIsSaved() throws {
        let document = try open("visio-intelligent")
        var next = document.diagram
        let smart = try node(document, "2")
        next.page.nodes[try XCTUnwrap(next.page.nodes.firstIndex { $0.id == smart.id })].height += 36
        document.replace(with: next, action: "Resize")
        let page = try savedPage(document)
        // The field shape keeps Visio's single terminal paragraph mark and inherited theme cells.
        XCTAssertTrue(page.contains("<fld IX='0'>Shapes</fld>\n</Text>") || page.contains("<fld IX=\"0\">Shapes</fld>\n</Text>"))
        XCTAssertFalse(page.contains("<Cell N='LineColor' V='#1F477D'"), "A recalculated THEMEVAL() must not be materialized as a local cell.")
    }

    func testContainersMoveWithTheirMembersAndResizeStaysGuarded() throws {
        let document = try open("visio-structure")
        let container = try node(document, "3"), a = try node(document, "1"), b = try node(document, "2")
        XCTAssertEqual(DiagramMemberships.movingMembers(of: [container.id], in: document.diagram, pageID: document.diagram.page.id).intersection([a.id, b.id]), [a.id, b.id])
        var next = document.diagram
        let moving = next.page.descendants(of: container.id).union(DiagramMemberships.movingMembers(of: [container.id], in: next, pageID: next.page.id))
        for i in next.page.nodes.indices where moving.contains(next.page.nodes[i].id) { next.page.nodes[i].x += 36; next.page.nodes[i].y -= 18 }
        document.replace(with: next, action: "Move container")
        XCTAssertNil(document.lastCalculationJobError)
        XCTAssertEqual(try node(document, "1").x, a.x + 36, accuracy: 1e-9)
        XCTAssertEqual(try node(document, "3").x, container.x + 36, accuracy: 1e-9)
        // Moving the container alone would separate it from its members.
        var alone = document.diagram
        alone.page.nodes[try XCTUnwrap(alone.page.nodes.firstIndex { $0.id == container.id })].x += 36
        XCTAssertThrowsError(try DiagramMemberships.validateTransforms(from: document.diagram, to: alone))
    }

    /// Native release check (0.25.0): inserting a shape into Visio's flowchart recalculated the page, rewrote
    /// untouched terminators with last-bit float noise, and their stencil formulas
    /// (INDEX(0,Prop.Status.Format), CONTAINERSHEETREF(1,"Swimlane")!User.VISHEADINGTEXT) then failed, so an
    /// ordinary Save was refused as unsafe.
    func testInsertingAShapeLeavesStencilShapesUntouchedAndSaveSafe() throws {
        let document = try open("visio-flowchart")
        let before = document.diagram
        var next = before
        var node = DiagramNode(kind: .rectangle, x: 300, y: 300, text: "Process"); node.width = 120; node.height = 60
        next.pages[0].nodes.append(node)
        document.replace(with: next, action: "Insert")
        XCTAssertEqual(Array(document.diagram.pages[0].nodes.prefix(before.pages[0].nodes.count)), before.pages[0].nodes)
        XCTAssertEqual(document.diagram.pages[0].edges, before.pages[0].edges)
        let assessment = DocumentSaveImpact.assess(snapshot: document.diagram, baseline: nil, diagnostics: document.currentDiagnostics, format: .visio)
        XCTAssertEqual(assessment.risks.map(\.message), [])
        XCTAssertFalse(document.calculationIssues.contains { $0.contains("Prop.Status.Format") || $0.contains("closing parenthesis") })
    }
}
