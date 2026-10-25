import XCTest
@testable import MacVisio

/// Regressions found by comparing MacVisio's renders and PDFs of the Visio-authored reference drawings
/// with Visio 2019's own PDF and PNG exports (docs/evidence/reference/visual).
final class VisioVisualReferenceTests: XCTestCase {
    private func open(_ name: String) throws -> MacVisioDocument {
        _ = NSApplication.shared
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "vsdx", subdirectory: "Fixtures/Reference"))
        let document = MacVisioDocument()
        try document.read(from: url, ofType: MacVisioDocument.visioType)
        return document
    }
    private func edge(_ document: MacVisioDocument, _ shapeID: String) throws -> DiagramEdge {
        let binding = try XCTUnwrap(document.diagram.visioArchive?.pages.first { $0.pageID == document.diagram.page.id })
        return try XCTUnwrap(document.diagram.page.edges.first { binding.edgeIDs[$0.id] == shapeID })
    }

    func testPositiveArcBowsDrawConvexRoundedCorners() throws {
        let document = try open("visio-intelligent")
        let node = try XCTUnwrap(document.diagram.page.nodes.first { $0.text == "Rounded" })
        let path = DiagramDrawing.vectorPath(try XCTUnwrap(node.formatting.paths.first), in: node.rect)
        let radius = 0.1574803149606299 * 72
        XCTAssertTrue(path.contains(CGPoint(x: node.rect.midX, y: node.rect.midY)))
        // Inside a convex corner's arc; a concave (inverted) bow would leave this point outside the shape.
        for corner in [CGPoint(x: node.rect.minX, y: node.rect.minY), CGPoint(x: node.rect.maxX, y: node.rect.minY),
                       CGPoint(x: node.rect.minX, y: node.rect.maxY), CGPoint(x: node.rect.maxX, y: node.rect.maxY)] {
            let inward = CGPoint(x: corner.x + (corner.x == node.rect.minX ? 1 : -1) * radius * 0.4,
                                 y: corner.y + (corner.y == node.rect.minY ? 1 : -1) * radius * 0.4)
            XCTAssertTrue(path.contains(inward), "corner \(corner)")
        }
    }

    func testOneDimensionalArcDrawsItsOwnGeometry() throws {
        let document = try open("visio-intelligent")
        let arc = try edge(document, "7")
        XCTAssertEqual(arc.formatting.paths.count, 1)
        XCTAssertNil(arc.points, "The arc is drawn from its geometry, not as a polyline route.")
        let page = document.diagram.page
        let route = DiagramGeometry.route(arc, in: page)
        let frame = try XCTUnwrap(OneDimensionalGeometry.frame(arc, route: route, pageHeight: page.height))
        // Begin (3 in, 3 in), end (5 in, 3 in), bow 1 in: the apex is at (4 in, 4 in).
        let apex = frame.point(normalized: 0.5, 0)
        XCTAssertEqual(apex.x, 4 * 72, accuracy: 1e-6)
        XCTAssertEqual(apex.y, page.height - 4 * 72, accuracy: 1e-6)
        // Moving the end point stretches the arc along its axis, as its Width formula does in Visio.
        var moved = arc; moved.targetPosition = DiagramPoint(CGPoint(x: 7 * 72, y: page.height - 3 * 72))
        let stretched = try XCTUnwrap(OneDimensionalGeometry.frame(moved, route: DiagramGeometry.route(moved, in: page), pageHeight: page.height))
        XCTAssertEqual(stretched.point(normalized: 0.5, 0).x, 5 * 72, accuracy: 1e-6)
        XCTAssertEqual(stretched.point(normalized: 0.5, 0).y, page.height - 4 * 72, accuracy: 1e-6)
    }

    func testSideBoxCalloutDrawsItsBoxAndPlacesTextInIt() throws {
        let document = try open("visio-structure")
        let callout = try XCTUnwrap(document.diagram.page.edges.first { $0.label == "Note" })
        XCTAssertEqual(callout.formatting.paths.count, 2, "Leader and box")
        let page = document.diagram.page
        let frame = try XCTUnwrap(OneDimensionalGeometry.frame(callout, route: DiagramGeometry.route(callout, in: page), pageHeight: page.height))
        // Visio: the box's left edge is at the end point (7 in, 4 in), text block 1.18 in wide, rotated -90 degrees
        // within the shape's 90 degree frame, so the text runs left to right from the end point.
        let center = try XCTUnwrap(OneDimensionalGeometry.textCenter(callout, frame: frame))
        XCTAssertEqual(center.x / 72, 7 + 1.181102362204725 / 2, accuracy: 1e-6)
        XCTAssertEqual((page.height - center.y) / 72, 4, accuracy: 1e-6)
        let leader = OneDimensionalGeometry.bezierPaths(callout, frame: frame)[0].path
        XCTAssertEqual(leader.bounds.minX / 72, 6.606299212598425, accuracy: 1e-6, "The leader starts at the begin point.")
    }

    func testThemedConnectorLabelsUseTheConnectorFontColor() throws {
        let document = try open("visio-flowchart")
        let label = try XCTUnwrap(document.diagram.page.edges.first { $0.label == "Yes" })
        // The theme's connector font paint is accent1 shaded 75%: Visio's export draws "Yes" in (61, 100, 172).
        XCTAssertEqual(label.formatting.textRuns?.first?.character.color.uppercased(), "#3D64AC")
    }

    func testScaledPagePrintsAtItsDrawingScale() throws {
        let document = try open("visio-pages")
        let plan = try XCTUnwrap(document.diagram.pages.first { $0.name == "Plan" })
        XCTAssertEqual(plan.paperScale, 0.02, accuracy: 1e-12, "1000 mm in the drawing is 20 mm on paper")
        // Visio's PDF of this page is 11.25 x 16.5 pt (210 x 297 mm of drawing at 1:50, rounded to whole pixels).
        XCTAssertEqual(plan.paperWidth, 210 / 25.4 * 72 * 0.02, accuracy: 1e-6)
        XCTAssertEqual(plan.paperHeight, 297 / 25.4 * 72 * 0.02, accuracy: 1e-6)
        // The 4 m room prints 80 mm wide, as Visio's 96 dpi export measures it (300 px).
        let room = try XCTUnwrap(plan.nodes.first { $0.text == "Room" })
        XCTAssertEqual(room.width * plan.paperScale / 72 * 25.4, 80, accuracy: 1e-6)
    }

    func testThinLinesDrawAtLeastOneDevicePixelInBitmaps() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4,
                                                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        XCTAssertEqual(visibleLineWidth(0.24), 1, accuracy: 1e-9)
        XCTAssertEqual(visibleLineWidth(2), 2, accuracy: 1e-9)
        XCTAssertEqual(visibleLineWidth(0), 0)
    }

    // Found on a customer drawing (Logical Definition): title-block labels and zone headings were missing or misplaced.

    private func ink(_ node: DiagramNode) -> (count: Int, top: Int) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 120, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let flip = NSAffineTransform(); flip.translateX(by: 0, yBy: 120); flip.scaleX(by: 1, yBy: -1); flip.concat()
        DiagramDrawing.drawNode(node, shadow: false)
        NSGraphicsContext.restoreGraphicsState()
        var count = 0, top = Int.max
        for y in 0..<120 { for x in 0..<300 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { count += 1; top = min(top, y) } }
        return (count, top)
    }
    private func label(_ text: String, height: Double, size: Double = 7) -> DiagramNode {
        var node = DiagramNode(kind: .text, x: 10, y: 10, text: text)
        node.width = 200; node.height = height; node.fontSize = size; node.fill = "#FFFFFF00"; node.stroke = "#FFFFFF00"
        node.formatting.sourceShapeID = "7"
        return node
    }

    func testTextTallerThanItsBlockOverflowsInsteadOfDisappearing() {
        // A 7 pt label in a 7.7 pt block: Visio's 4 pt margins exceed the block, and Visio still draws the text.
        XCTAssertGreaterThan(ink(label("Description:", height: 7.7)).count, 20)
    }

    func testVerticalAlignCellPlacesTextWithoutAnImportedTextBox() {
        var top = label("Zone 1", height: 100, size: 12); top.formatting.sheet["VerticalAlign"] = ShapeSheetCell(value: "0")
        var middle = top; middle.formatting.sheet["VerticalAlign"] = ShapeSheetCell(value: "1")
        XCTAssertLessThan(ink(top).top + 20, ink(middle).top, "VerticalAlign 0 puts the heading at the top")
    }

    func testRoundingCellRoundsLineGeometryCorners() {
        let square = VectorPath(commands: [VectorCommand("M", 0, 0), VectorCommand("L", 1, 0), VectorCommand("L", 1, 1), VectorCommand("L", 0, 1), VectorCommand("Z")])
        let rect = CGRect(x: 0, y: 0, width: 100, height: 60)
        let sharp = DiagramDrawing.vectorPath(square, in: rect), rounded = DiagramDrawing.vectorPath(square, in: rect, rounding: 10)
        XCTAssertTrue(sharp.contains(CGPoint(x: 1, y: 1)))
        XCTAssertFalse(rounded.contains(CGPoint(x: 1, y: 1)), "The corner is cut by the 10 pt radius")
        XCTAssertTrue(rounded.contains(CGPoint(x: 50, y: 30)))
    }

    func testCaseCellShowsCapitalsWithoutChangingStoredText() {
        var node = label("Pspf Security Zones", height: 20)
        var run = ShapeTextRun(text: node.text, character: ShapeCharacterStyle(node: node), paragraph: ShapeParagraphStyle())
        run.character.cells["Case"] = ShapeSheetCell(value: "1")
        node.formatting.textRuns = [run]
        XCTAssertEqual(ShapeRichText.attributed(node).string, "PSPF SECURITY ZONES")
        XCTAssertEqual(ShapeRichText.attributed(node, editing: true).string, "Pspf Security Zones")
    }

    /// Visio draws shapes and connectors interleaved in page order: a filled frame drawn first must not cover
    /// the connectors that follow it (a customer drawing showed no connectors).
    func testConnectorsFollowVisioPageOrderAmongShapes() {
        var page = DiagramPage()
        let frame = DiagramNode(text: "Frame"), box = DiagramNode(text: "Box"), late = DiagramNode(text: "Late")
        page.nodes = [frame, box, late]
        let edge = DiagramEdge(source: frame.id, target: box.id), added = DiagramEdge(source: box.id, target: late.id)
        page.edges = [edge, added]
        page.sourceOrder = [frame.id, edge.id, box.id, late.id]
        var drawn: [String] = []
        let order = DiagramDrawing.connectorOrder(page)!
        DiagramDrawing.interleave(nodes: page.nodes, edges: page.edges, order: order,
                                  drawNode: { drawn.append($0.text) }, drawEdge: { drawn.append($0.id == edge.id ? "edge" : "added") })
        XCTAssertEqual(drawn, ["Frame", "edge", "Box", "Late", "added"])
    }
}
