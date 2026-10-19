import XCTest
@testable import MacVisio

final class M3ConnectorCalculationTests: XCTestCase {
    private func fixture(unrelated: Int = 0) throws -> Diagram {
        var diagram = Diagram(), source = DiagramNode(text: "Source")
        source.formatting.sourceShapeID = "1"
        source.formatting.sheet["User.Base"] = ShapeSheetCell(value: "2")
        var follower = try TextFieldEngine.inserting(formula: "Sheet.30!User.Calc", picture: "0.0", into: DiagramNode(text: ""))
        follower.formatting.sourceShapeID = "2"
        follower.formatting.sheet["Width"] = ShapeSheetCell(value: "1", formula: "Sheet.30!User.Calc")
        var edge = DiagramEdge(source: source.id, target: follower.id, style: .straight)
        edge.sourceShapeID = "30"
        let text = try TextFieldEngine.inserting(formula: "User.Calc", picture: "0.0", into: edge.textNode)
        edge.details = text.details; edge.label = text.text
        edge.formatting.sheet["User.Calc"] = ShapeSheetCell(value: "1", formula: "Sheet.1!User.Base*2")
        edge.formatting.sheet["LineWeight"] = ShapeSheetCell(value: "0.01", formula: "User.Calc/144", unit: "IN")
        edge.formatting.sheet["LineColor"] = ShapeSheetCell(value: "#000000", formula: "RGB(255,0,0)")
        diagram.page.nodes = [source, follower]; diagram.page.edges = [edge]
        for index in 0..<unrelated {
            var node = DiagramNode(text: "Unrelated \(index)")
            node.formatting.sourceShapeID = String(100 + index*2)
            var other = DiagramEdge(source: node.id, target: node.id)
            other.sourceShapeID = String(101 + index*2)
            other.formatting.sheet["User.Local"] = ShapeSheetCell(value: "1", formula: "1+0")
            diagram.page.nodes.append(node); diagram.page.edges.append(other)
        }
        return diagram
    }

    func testConnectorAndShapeShareScalarDependenciesFieldsAndPublicIdentity() throws {
        let input = try fixture(), endpoints = input.page.edges[0]
        let result = DiagramCalculation.recalculate(input)
        XCTAssertTrue(result.issues.isEmpty, result.issues.joined(separator: "\n"))
        XCTAssertEqual(result.diagram.page.nodes[1].width, 288, accuracy: 1e-8)
        XCTAssertEqual(result.diagram.page.nodes[1].text, "4.0")
        XCTAssertEqual(result.diagram.page.edges[0].label, "4.0")
        XCTAssertEqual(result.diagram.page.edges[0].width, 2, accuracy: 1e-8)
        XCTAssertEqual(result.diagram.page.edges[0].color, "#FF0000")
        XCTAssertEqual(result.diagram.page.edges[0].formatting.sheet["User.Calc"]?.formula, "Sheet.1!User.Base*2")
        XCTAssertEqual(result.diagram.page.edges[0].formatting.textFields?.first?.cells["Value"]?.formula, "User.Calc")
        XCTAssertEqual(result.diagram.page.edges[0].source, endpoints.source)
        XCTAssertEqual(result.diagram.page.edges[0].target, endpoints.target)
        XCTAssertEqual(result.diagram.page.edges[0].points, endpoints.points)
        XCTAssertEqual(result.diagram.page.edges[0].sourcePosition, endpoints.sourcePosition)
        XCTAssertGreaterThan(result.work.connectorSheets, 0)
        XCTAssertGreaterThan(result.work.fieldConnectors, 0)
    }

    func testWarmConnectorChangeInvalidatesDependentShapeWithoutScanningUnrelatedSheets() throws {
        var records: [CalculationWork] = []
        for count in [40, 2000] {
            let session = CalculationSession(), initial = try fixture(unrelated: count)
            let settled = DiagramCalculation.recalculate(initial, session: session)
            var input = settled.diagram
            input.page.edges[0].formatting.sheet["User.Calc"]?.formula = "Sheet.1!User.Base*3"
            let changes = DocumentChangeSet.between(settled.diagram, input)
            let result = DiagramCalculation.recalculate(input, previous: settled.diagram,
                previousGeometryIssuesByPage: settled.geometryIssuesByPage,
                previousFieldIssuesByPage: settled.fieldIssuesByPage, session: session, changes: changes)
            let full = DiagramCalculation.recalculate(input, previous: settled.diagram)
            XCTAssertTrue(result.diagram == full.diagram)
            XCTAssertEqual(result.issues, full.issues)
            XCTAssertEqual(result.diagram.page.nodes[1].width, 432, accuracy: 1e-8)
            XCTAssertEqual(result.diagram.page.edges[0].label, "6.0")
            XCTAssertEqual(result.work.inputComparisonNodes, 0)
            XCTAssertEqual(result.work.inputComparisonConnectors, 0)
            XCTAssertLessThan(result.work.dependencySourcesCompared, 25)
            XCTAssertLessThan(result.work.hostConnectorsPrepared, 25)
            XCTAssertLessThan(result.work.connectorSheets, 10)
            records.append(result.work)
        }
        XCTAssertEqual(records[0].dependencySourcesCompared, records[1].dependencySourcesCompared)
        XCTAssertEqual(records[0].hostConnectorsPrepared, records[1].hostConnectorsPrepared)
        XCTAssertEqual(records[0].connectorSheets, records[1].connectorSheets)
    }

    func testConnectorFormulaFailuresRetainCachesAndExactTypedTarget() throws {
        var input = try fixture()
        input.page.edges[0].formatting.sheet["User.Calc"] = ShapeSheetCell(value: "7", formula: "UNSUPPORTED(1)")
        let result = DiagramCalculation.recalculate(input)
        let edge = result.diagram.page.edges[0]
        XCTAssertEqual(edge.formatting.sheet["User.Calc"]?.value, "7")
        XCTAssertEqual(edge.formatting.sheet["User.Calc"]?.formula, "UNSUPPORTED(1)")
        XCTAssertEqual(edge.label, input.page.edges[0].label)
        let diagnostics = result.geometryDiagnosticsByPage[input.page.id, default: []]
            + result.fieldDiagnosticsByPage[input.page.id, default: []]
        XCTAssertTrue(diagnostics.contains { $0.target == .connector(page: input.page.id, connector: edge.id)
            && $0.source.visioID == "30" && $0.source.cell == "User.Calc" && $0.displayState == .cached })
        XCTAssertTrue(diagnostics.contains { $0.target == .connector(page: input.page.id, connector: edge.id)
            && $0.source.cell == "Fields.Value[2]" })
    }

    func testConnectorIDsAreReservedForImplicitShapeAndFieldAllocation() throws {
        var diagram = Diagram(), node = try TextFieldEngine.inserting(formula: "ID()", into: DiagramNode(text: ""))
        var edge = DiagramEdge(source: node.id, target: node.id)
        edge.sourceShapeID = "1"
        let text = try TextFieldEngine.inserting(formula: "ID()", into: edge.textNode)
        edge.details = text.details
        node.formatting.sheet["Width"] = ShapeSheetCell(value: "1", formula: "Sheet.1!User.Size")
        edge.formatting.sheet["User.Size"] = ShapeSheetCell(value: "3")
        diagram.page.nodes = [node]; diagram.page.edges = [edge]
        let result = DiagramCalculation.recalculate(diagram)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.diagram.page.nodes[0].text, "2")
        XCTAssertEqual(result.diagram.page.nodes[0].width, 216, accuracy: 1e-8)
        XCTAssertEqual(result.diagram.page.edges[0].label, "1")
    }

    func testCalculatedConnectorCachesAndLineFormulasSurvivePreservingPublicSave() throws {
        let first = FileManager.default.temporaryDirectory.appendingPathComponent("M3-calc-\(UUID()).vsdx")
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("M3-calc-\(UUID()).vsdx")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try VisioFormat.write(DiagramCalculation.recalculate(fixture()).diagram, to: first)
        let source = try VisioFormat.read(from: first).diagram
        var input = source
        let index = try XCTUnwrap(input.page.nodes.firstIndex { $0.formatting.sourceShapeID == "1" })
        input.page.nodes[index].formatting.sheet["User.Base"]?.value = "5"
        let result = DiagramCalculation.recalculate(input, previous: source)
        XCTAssertTrue(result.issues.isEmpty, result.issues.joined(separator: "\n"))
        try VisioFormat.write(result.diagram, to: second)
        let parts = try VisioPackage.read(second)
        let reopened = try VisioFormat.readPublic(parts: parts, title: "Public connector caches").diagram
        let edge = try XCTUnwrap(reopened.page.edges.first { $0.sourceShapeID == "30" })
        XCTAssertEqual(edge.label, "10.0")
        XCTAssertEqual(edge.width, 5, accuracy: 1e-8)
        XCTAssertEqual(edge.formatting.sheet["User.Calc"]?.formula, "Sheet.1!User.Base*2")
        XCTAssertEqual(edge.formatting.sheet["LineWeight"]?.formula, "User.Calc/144")
        XCTAssertEqual(edge.formatting.sheet["LineColor"]?.formula, "RGB(255,0,0)")
        XCTAssertEqual(edge.formatting.textFields?.first?.cells["Value"]?.formula, "User.Calc")
        let unchanged = DiagramCalculation.recalculate(reopened)
        XCTAssertTrue(unchanged.issues.isEmpty, unchanged.issues.joined(separator: "\n"))
        XCTAssertEqual(unchanged.diagram.page.edges.first { $0.sourceShapeID == "30" }?.label, "10.0")
    }

    func testDocumentPageContextInvalidatesGeometryOnlyShapesAndConnectors() {
        for formula in ["PAGECOUNT()", "PAGENUMBER()", "LEN(BKGPAGENAME())"] {
            var input = Diagram(), node = DiagramNode(text: "No fields")
            node.formatting.sheet["Width"] = ShapeSheetCell(value: "1", formula: formula)
            var edge = DiagramEdge(source: node.id, target: node.id)
            edge.formatting.sheet["User.Context"] = ShapeSheetCell(value: "1", formula: formula)
            input.page.nodes = [node]; input.page.edges = [edge]
            var background = DiagramPage(name: "Back"); background.isBackground = true
            input.page.backgroundPageID = background.id; input.pages.append(background)
            let originalPageID = input.page.id, session = CalculationSession()
            let settled = DiagramCalculation.recalculate(input, session: session)
            var changed = settled.diagram
            if formula == "PAGECOUNT()" { changed.pages.append(DiagramPage(name: "Added")) }
            else if formula == "PAGENUMBER()" { changed.pages.insert(DiagramPage(name: "First"), at: 0) }
            else { changed.pages[1].name = "Longer background name" }
            let result = DiagramCalculation.recalculate(changed, previous: settled.diagram,
                previousGeometryIssuesByPage: settled.geometryIssuesByPage,
                previousFieldIssuesByPage: settled.fieldIssuesByPage, session: session,
                changes: DocumentChangeSet.between(settled.diagram, changed))
            let full = DiagramCalculation.recalculate(changed)
            XCTAssertTrue(result.diagram == full.diagram, formula)
            let page = result.diagram.pages.first { $0.id == originalPageID }!
            let expected = formula == "LEN(BKGPAGENAME())" ? 22.0 : 2.0
            XCTAssertEqual(page.nodes[0].width, expected*72, accuracy: 1e-8, formula)
            XCTAssertEqual(Double(page.edges[0].formatting.sheet["User.Context"]?.value ?? ""), expected, formula)
        }
    }

    func testFreeConnectorHostUsesSuppliedMapAndStoredEndpointPositions() {
        var page = DiagramPage(), node = DiagramNode(x: 400, y: 500)
        page.nodes = [node]
        var edge = DiagramEdge(source: node.id, target: node.id)
        // A supplied partial map is authoritative; resolving a missing endpoint
        // must not fall back to a page scan or a different snapshot.
        let absent = ConnectorSheetHost.node(edge, in: page, nodesByID: [:])
        XCTAssertEqual(absent.center.x, 0, accuracy: 1e-8)
        XCTAssertEqual(absent.center.y, 0, accuracy: 1e-8)
        edge.sourcePosition = DiagramPoint(x: 10, y: 20)
        edge.targetPosition = DiagramPoint(x: 82, y: 20)
        node.x = -100; node.y = -100
        let fixed = ConnectorSheetHost.node(edge, in: page, nodesByID: [node.id: node])
        XCTAssertEqual(fixed.center.x, 46, accuracy: 1e-8)
        XCTAssertEqual(fixed.center.y, 20, accuracy: 1e-8)
        XCTAssertEqual(fixed.width, 72, accuracy: 1e-8)
    }

    func testShapeAndConnectorDateCellsAndFieldsUseOneInjectedClock() throws {
        var input = Diagram(), node = DiagramNode(text: "")
        node.formatting.sheet["User.When"] = ShapeSheetCell(value: "Cached", formula: "NOW()")
        node.formatting.sheet["User.Day"] = ShapeSheetCell(value: "Cached", formula: "TODAY()")
        node = try TextFieldEngine.inserting(formula: "FORMAT(User.When,\"yyyy-MM-dd HH:mm:ss\")", into: node)
        var edge = DiagramEdge(source: node.id, target: node.id)
        let text = try TextFieldEngine.inserting(formula: "FORMAT(User.When,\"yyyy-MM-dd HH:mm:ss\")", into: edge.textNode)
        edge.details = text.details
        edge.formatting.sheet["User.When"] = ShapeSheetCell(value: "Cached", formula: "NOW()")
        edge.formatting.sheet["User.Day"] = ShapeSheetCell(value: "Cached", formula: "TODAY()")
        input.page.nodes = [node]; input.page.edges = [edge]
        let now = try XCTUnwrap(FieldFormatting.date("2020-01-02T03:04:05Z"))
        let result = DiagramCalculation.recalculate(input, now: now)
        XCTAssertTrue(result.issues.isEmpty, result.issues.joined(separator: "\n"))
        let expected = try FieldFormatting.format(.date(now), picture: "yyyy-MM-dd HH:mm:ss")
        XCTAssertEqual(result.diagram.page.nodes[0].text, expected)
        XCTAssertEqual(result.diagram.page.edges[0].label, expected)
        for sheet in [result.diagram.page.nodes[0].formatting.sheet, result.diagram.page.edges[0].formatting.sheet] {
            XCTAssertEqual(sheet["User.When"]?.value, ISO8601DateFormatter().string(from: now))
            XCTAssertEqual(sheet["User.Day"]?.value, ISO8601DateFormatter().string(from: Calendar(identifier: .gregorian).startOfDay(for: now)))
        }
    }
}
