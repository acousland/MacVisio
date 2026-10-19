import AppKit
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

/// Local Union engineering. These fixtures do not assert an exact-build Visio
/// text/data/master merge policy or reference-application qualification.
final class M3BooleanGeometryTests: XCTestCase {
    private func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> DiagramNode {
        var node = DiagramNode(x: x, y: y, text: ""); node.width = width; node.height = height; return node
    }
    private func model(_ nodes: [DiagramNode]? = nil) -> Diagram {
        var diagram = Diagram(); diagram.page.nodes = nodes ?? [rectangle(100, 100, 120, 100), rectangle(180, 140, 140, 100)]
        diagram.page.edges = []; return diagram
    }
    private func ids(_ diagram: Diagram) -> Set<UUID> { Set(diagram.page.nodes.filter { !$0.formatting.isGroup }.map(\.id)) }
    private func united(_ diagram: Diagram) throws -> DiagramNode { try XCTUnwrap(BooleanGeometry.union(ids(diagram), in: diagram).page.nodes.first { !$0.formatting.isGroup }) }
    private func contains(_ node: DiagramNode, _ point: CGPoint) -> Bool {
        DiagramDrawing.outline(for: node).contains(point)
    }
    private func loop(_ x: Double, _ y: Double, _ width: Double, _ height: Double, reversed: Bool = false) -> [VectorCommand] {
        var points = [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y), CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
        if reversed { points.reverse() }
        return points.enumerated().map { VectorCommand($0.offset == 0 ? "M" : "L", $0.element.x, $0.element.y) } + [VectorCommand("Z")]
    }
    private func ring(evenOdd: Bool) -> DiagramNode {
        var node = rectangle(100, 100, 200, 200)
        node.formatting.paths = [VectorPath(commands: loop(0, 0, 1, 1) + loop(0.25, 0.25, 0.5, 0.5, reversed: !evenOdd), evenOdd: evenOdd)]
        return node
    }
    private func file() -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("M3-Union-\(UUID()).vsdx")
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }; return result
    }
    private func publicDiagram(_ diagram: Diagram) throws -> Diagram {
        let url = file(); try VisioFormat.write(diagram, to: url)
        var parts = try VisioPackage.read(url); parts.removeValue(forKey: "macvisio/document.json")
        return try VisioFormat.readPublic(parts: parts, title: "Public Union input").diagram
    }
    private func source(_ diagram: Diagram, edit: (inout [String: Data]) throws -> Void) throws -> Diagram {
        let url = file(); try VisioFormat.write(diagram, to: url)
        var parts = try VisioPackage.read(url); parts.removeValue(forKey: "macvisio/document.json"); try edit(&parts)
        return try VisioFormat.readPublic(parts: parts, title: "Union source guard").diagram
    }

    func testOverlappingRectanglesPreserveUnionOccupancyAndFirstShapeStyle() throws {
        var input = model(); input.page.nodes[0].fill = "#CC2200"; input.page.nodes[0].stroke = "#112233"
        input.page.nodes[0].strokeWidth = 3; input.page.nodes[1].fill = "#00CC44"
        let output = try BooleanGeometry.union(ids(input), in: input), node = try XCTUnwrap(output.page.nodes.first)
        XCTAssertEqual(output.page.nodes.count, 1); XCTAssertEqual(node.fill, "#CC2200"); XCTAssertEqual(node.stroke, "#112233"); XCTAssertEqual(node.strokeWidth, 3)
        XCTAssertEqual(node.rect, CGRect(x: 100, y: 100, width: 220, height: 140))
        for point in [CGPoint(x: 110, y: 110), CGPoint(x: 200, y: 160), CGPoint(x: 310, y: 230)] { XCTAssertTrue(contains(node, point)) }
        for point in [CGPoint(x: 280, y: 110), CGPoint(x: 110, y: 230), CGPoint(x: 99, y: 120)] { XCTAssertFalse(contains(node, point)) }
        XCTAssertFalse(ids(input).contains(node.id)); XCTAssertNotNil(node.formatting.geometry)
    }

    func testDisjointAndContainedInputsKeepBothComponentsWithoutXORHoles() throws {
        for second in [rectangle(300, 100, 50, 60), rectangle(130, 120, 40, 30)] {
            let input = model([rectangle(100, 100, 120, 100), second]), node = try united(input)
            XCTAssertTrue(contains(node, CGPoint(x: 140, y: 130)))
            XCTAssertTrue(contains(node, CGPoint(x: second.center.x, y: second.center.y)))
            XCTAssertFalse(contains(node, CGPoint(x: 260, y: 130)))
        }
    }

    func testEvenOddAndNonzeroHolePoliciesRemainIndependentAcrossOperands() throws {
        for evenOdd in [true, false] {
            let input = model([ring(evenOdd: evenOdd), rectangle(270, 100, 70, 45)]), node = try united(input)
            XCTAssertTrue(contains(node, CGPoint(x: 120, y: 200))); XCTAssertTrue(contains(node, CGPoint(x: 330, y: 120)))
            XCTAssertFalse(contains(node, CGPoint(x: 200, y: 200))); XCTAssertFalse(contains(node, CGPoint(x: 330, y: 200)))
            XCTAssertEqual(node.formatting.paths.first?.evenOdd, false)
        }
    }

    func testCurveResultContainsAnalyticInteriorAndKeepsCubicSegments() throws {
        var ellipse = rectangle(100, 100, 200, 200); ellipse.kind = .ellipse
        let node = try united(model([ellipse, rectangle(280, 180, 100, 80)]))
        XCTAssertTrue(node.formatting.paths.flatMap(\.commands).contains { $0.kind == "C" })
        for point in [CGPoint(x: 200, y: 200), CGPoint(x: 200, y: 110), CGPoint(x: 290, y: 200), CGPoint(x: 370, y: 250)] { XCTAssertTrue(contains(node, point)) }
        for point in [CGPoint(x: 105, y: 105), CGPoint(x: 290, y: 110), CGPoint(x: 375, y: 270)] { XCTAssertFalse(contains(node, point)) }
    }

    func testRotationFlipAndGroupWorldCoordinatesProduceTheOriginalFilledSet() throws {
        var a = rectangle(180, 180, 150, 100), b = rectangle(300, 200, 100, 130)
        a.rotation = 35; a.formatting.flipX = true
        a.formatting.paths = [VectorPath(commands: [VectorCommand("M", 0, 0), VectorCommand("L", 1, 0), VectorCommand("L", 0, 1), VectorCommand("Z")])]
        b.rotation = -20; b.formatting.flipY = true
        var group = rectangle(100, 100, 400, 300); group.formatting.isGroup = true; group.rotation = 25; group.formatting.flipX = true
        a.parentID = group.id; b.parentID = group.id
        let input = model([group, a, b]), node = try united(input)
        let publicOutput = try publicDiagram(BooleanGeometry.union(ids(input), in: input))
        let publicNode = try XCTUnwrap(publicOutput.page.nodes.first { !$0.formatting.isGroup })
        XCTAssertEqual(node.parentID, group.id); XCTAssertEqual(node.rotation, 0); XCTAssertFalse(node.formatting.flipX)
        for x in stride(from: 135.0, through: 435.0, by: 13) { for y in stride(from: 145.0, through: 350.0, by: 11) {
            let point = CGPoint(x: x, y: y)
            func expected(_ original: DiagramNode) -> Bool {
                let local = DiagramCoordinates.local(point, in: original)
                let untransformed = CGPoint(x: original.x + local.x, y: original.y + local.y)
                return DiagramDrawing.outline(for: original).contains(untransformed)
            }
            XCTAssertEqual(contains(node, point), expected(a) || expected(b), "\(point)")
            XCTAssertEqual(contains(publicNode, point), expected(a) || expected(b), "public \(point)")
        } }
    }

    func testResultGeometryRowsRemainEditableAndPublicReopenKeepsCurvesAndHoleOccupancy() throws {
        var ellipse = rectangle(380, 100, 100, 100); ellipse.kind = .ellipse
        let input = model([ring(evenOdd: true), ellipse]), output = try BooleanGeometry.union(ids(input), in: input)
        let url = file(); try VisioFormat.write(output, to: url)
        var parts = try VisioPackage.read(url); parts.removeValue(forKey: "macvisio/document.json"); try VisioPackage.write(parts, to: url)
        let read = try VisioFormat.read(from: url).diagram, node = try XCTUnwrap(read.page.nodes.first)
        XCTAssertEqual(read.page.nodes.count, 1); XCTAssertTrue(GeometrySheet.names(node.formatting.geometry ?? []).contains { $0.hasPrefix("Geometry1.X") })
        XCTAssertTrue(node.formatting.geometry!.flatMap(\.rows).contains { $0.type == "RelCubBezTo" })
        XCTAssertTrue(contains(node, CGPoint(x: 120, y: 200))); XCTAssertFalse(contains(node, CGPoint(x: 200, y: 200)))
        XCTAssertTrue(contains(node, CGPoint(x: 430, y: 150))); XCTAssertFalse(contains(node, CGPoint(x: 390, y: 110)))
        XCTAssertEqual(node.x, 100, accuracy: 1e-6); XCTAssertEqual(node.y, 100, accuracy: 1e-6)
        XCTAssertEqual(node.width, 380, accuracy: 1e-6); XCTAssertEqual(node.height, 200, accuracy: 1e-6)
        var edited = read; let address = try XCTUnwrap(GeometrySheet.names(node.formatting.geometry!).first { $0.hasPrefix("Geometry1.X") })
        let before = try XCTUnwrap(GeometrySheet.cell(address, on: node))
        try GeometrySheet.set(address, ShapeSheetCell(value: String((Double(before.value) ?? 0) + 0.01)), on: &edited.page.nodes[0])
        XCTAssertNotEqual(GeometrySheet.cell(address, on: edited.page.nodes[0]), before)
    }

    func testIndependentPublicReaderRetainsTheUnionHoleAndCurveSurface() throws {
        guard let converter = LegacyVisioFormat.converterURL else { throw XCTSkip("The independent libvisio converter is unavailable.") }
        var ellipse = rectangle(380, 100, 100, 100); ellipse.kind = .ellipse
        let input = model([ring(evenOdd: true), ellipse]), output = try BooleanGeometry.union(ids(input), in: input)
        let url = file(); try VisioFormat.write(output, to: url)
        var parts = try VisioPackage.read(url); parts.removeValue(forKey: "macvisio/document.json"); try VisioPackage.write(parts, to: url)
        let process = Process(), pipe = Pipe(); process.executableURL = converter; process.arguments = [url.path]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(decoding: data, as: UTF8.self), start = try XCTUnwrap(text.range(of: "<svg:svg")), end = try XCTUnwrap(text.range(of: "</svg:svg>"))
        let parsed = try SVGImport.page(Data(text[start.lowerBound..<end.upperBound].utf8), name: "Independent Union").page
        func filled(_ point: CGPoint) -> Bool { parsed.nodes.contains { node in node.formatting.paths.contains { $0.fill && DiagramDrawing.vectorPath($0, in: node.rect).contains(point) } } }
        XCTAssertTrue(filled(CGPoint(x: 120, y: 200))); XCTAssertFalse(filled(CGPoint(x: 200, y: 200)))
        XCTAssertTrue(filled(CGPoint(x: 430, y: 150))); XCTAssertFalse(filled(CGPoint(x: 390, y: 110)))
    }

    func testBarePublicSourceUnionPreservesUnrelatedShapeAndReservedPublicIDs() throws {
        var input = model(); var survivor = rectangle(450, 100, 40, 40)
        survivor.formatting.sourceShapeID = "90"; input.page.nodes.append(survivor)
        let imported = try publicDiagram(input), original = imported.page.nodes[2], selected = Set(imported.page.nodes.prefix(2).map(\.id))
        let originalPart = try XCTUnwrap(imported.visioArchive?.pages.first { $0.pageID == imported.page.id }?.part)
        let originalXML = try VisioXML.document(XCTUnwrap(imported.visioArchive?.parts[originalPart]))
        let preserved = try XCTUnwrap(originalXML.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == original.formatting.sourceShapeID }).xmlString
        let resultID = UUID(), output = try BooleanGeometry.union(selected, in: imported, resultID: resultID)
        let result = try XCTUnwrap(output.page.nodes.first { $0.id == resultID })
        XCTAssertEqual(output.page.nodes.first { $0.id == original.id }, original); XCTAssertNotEqual(result.formatting.sourceShapeID, "90")
        XCTAssertFalse(Set(imported.page.nodes.compactMap { $0.formatting.sourceShapeID }).contains(result.formatting.sourceShapeID!))
        let reopened = try publicDiagram(output); XCTAssertEqual(reopened.page.nodes.count, 2)
        // Preservation retains existing XML positions and appends the new
        // shape. Public IDs, rather than model-array order, own these checks.
        let publicSurvivor = try XCTUnwrap(reopened.page.nodes.first { $0.formatting.sourceShapeID == original.formatting.sourceShapeID })
        let publicResult = try XCTUnwrap(reopened.page.nodes.first { $0.formatting.sourceShapeID == result.formatting.sourceShapeID })
        XCTAssertEqual(publicSurvivor.x, original.x, accuracy: 1e-6); XCTAssertEqual(publicSurvivor.y, original.y, accuracy: 1e-6)
        XCTAssertEqual(publicSurvivor.width, original.width, accuracy: 1e-6); XCTAssertEqual(publicSurvivor.height, original.height, accuracy: 1e-6)
        XCTAssertTrue(contains(publicSurvivor, CGPoint(x: 460, y: 110))); XCTAssertFalse(contains(publicSurvivor, CGPoint(x: 200, y: 160)))
        XCTAssertTrue(contains(publicResult, CGPoint(x: 200, y: 160))); XCTAssertFalse(contains(publicResult, CGPoint(x: 280, y: 110)))
        let savedXML = try VisioXML.document(XCTUnwrap(reopened.visioArchive?.parts[originalPart]))
        XCTAssertEqual(savedXML.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == original.formatting.sourceShapeID }?.xmlString, preserved)
    }

    func testImportedNoStyleEnableDefaultsAreInertButAuthoredVariantsRefuse() throws {
        let imported = try publicDiagram(model())
        for key in ["EnableLineProps", "EnableFillProps", "EnableTextProps"] {
            XCTAssertEqual(imported.page.nodes[0].formatting.sheet[key], ShapeSheetCell(value: "1"))
            for cell in [ShapeSheetCell(value: "0"), ShapeSheetCell(value: "1", formula: "GUARD(1)"), ShapeSheetCell(value: "1", unit: "BOOL")] {
                var changed = imported; changed.page.nodes[0].formatting.sheet[key] = cell
                XCTAssertThrowsError(try BooleanGeometry.union(ids(changed), in: changed)) { XCTAssertTrue($0.localizedDescription.contains("style-enable")) }
            }
        }
        XCTAssertNil(BooleanGeometry.unavailableReason(ids(imported), in: imported))
        XCTAssertNoThrow(try BooleanGeometry.union(ids(imported), in: imported))
        var unknown = imported; unknown.page.nodes[0].formatting.sheet["EnableVendorProps"] = ShapeSheetCell(value: "1")
        XCTAssertThrowsError(try BooleanGeometry.union(ids(unknown), in: unknown)) { XCTAssertTrue($0.localizedDescription.contains("behavior cells")) }
    }

    func testRemovingImplicitIDsDoesNotRetargetAnUnrelatedSurvivingReference() throws {
        var input = model(), survivor = rectangle(450, 100, 80, 40), dependent = rectangle(450, 200, 80, 40)
        let selected = ids(input)
        survivor.formatting.sheet["User.SelfWidth"] = ShapeSheetCell(value: "1", formula: "Sheet.3!Width")
        dependent.formatting.sheet["User.OtherWidth"] = ShapeSheetCell(value: "1", formula: "Sheet.3!Width")
        input.page.nodes += [survivor, dependent]
        let output = try BooleanGeometry.union(selected, in: input)
        XCTAssertEqual(output.page.nodes.first { $0.id == survivor.id }?.formatting.sourceShapeID, "3")
        XCTAssertEqual(output.page.nodes.first { $0.id == dependent.id }?.formatting.sourceShapeID, "4")
        XCTAssertEqual(output.page.nodes.last?.formatting.sourceShapeID, "5")
        let reopened = try publicDiagram(output)
        XCTAssertNotNil(reopened.page.nodes.first { $0.formatting.sourceShapeID == "3" })
        XCTAssertEqual(reopened.page.nodes.first { $0.formatting.sourceShapeID == "4" }?.formatting.sheet["User.OtherWidth"]?.formula, "Sheet.3!Width")
    }

    func testRawPublicTombstonesReserveNumericIDsAcrossSaveAndNativeAndPublicReopen() throws {
        for rawID in ["4", "0004"] {
            var base = model(); base.page.nodes.append(rectangle(450, 100, 40, 40))
            let imported = try source(base) { parts in
                let xml = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
                xml.rootElement()?.firstLocal("Shapes")?.addChild(try VisioXML.element("<Shape ID=\"\(rawID)\" Del=\"1\"/>"))
                parts["visio/pages/page1.xml"] = xml.xmlData(options: .nodePreserveAll)
            }
            XCTAssertEqual(imported.page.nodes.count, 3)
            let selected = Set(imported.page.nodes.prefix(2).map(\.id)), resultID = UUID()
            let output = try BooleanGeometry.union(selected, in: imported, resultID: resultID)
            let result = try XCTUnwrap(output.page.nodes.first { $0.id == resultID }), publicID = try XCTUnwrap(result.formatting.sourceShapeID)
            XCTAssertEqual(publicID, "5", rawID)
            let url = file(), saved = try VisioFormat.writeRebased(output, to: url)
            XCTAssertEqual(saved.pages.first { $0.pageID == output.page.id }?.nodeIDs[result.id], publicID)
            let native = try VisioFormat.read(from: url).diagram
            XCTAssertEqual(native.page.nodes.first { $0.id == result.id }?.formatting.sourceShapeID, publicID)
            var parts = try VisioPackage.read(url); parts.removeValue(forKey: "macvisio/document.json")
            let xml = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
            let shapes = try XCTUnwrap(xml.rootElement()?.firstLocal("Shapes")).allShapes
            XCTAssertEqual(shapes.first { $0.attr("ID") == rawID }?.attr("Del"), "1")
            XCTAssertEqual(shapes.filter { $0.attr("ID").flatMap(UInt32.init) == UInt32(publicID) }.count, 1)
            try VisioPackage.write(parts, to: url)
            let reopened = try VisioFormat.read(from: url).diagram
            let publicNode = try XCTUnwrap(reopened.page.nodes.first { $0.formatting.sourceShapeID == publicID })
            XCTAssertEqual(reopened.page.nodes.count, 2); XCTAssertTrue(contains(publicNode, CGPoint(x: 200, y: 160)))
        }
    }

    func testIncomingFormulaReferencesAcrossFieldsRunsConnectorsPagesAndDefinitionsRefuse() throws {
        for scope in ["sheet", "field", "character", "paragraph", "connector", "page", "definition"] {
            var input = model(), survivor = rectangle(450, 100, 40, 40)
            let selected = ids(input), reference = ShapeSheetCell(value: "1", formula: "Sheet.0001!Width")
            switch scope {
            case "sheet": survivor.formatting.sheet["User.W"] = reference
            case "field": survivor.formatting.textFields = [ShapeTextField(index: 0, cells: ["Value": reference])]
            case "character", "paragraph":
                survivor.text = "Keep me"
                var run = try XCTUnwrap(ShapeRichText.runs(for: survivor).first)
                if scope == "character" { run.character.cells["Size"] = reference } else { run.paragraph.cells["IndFirst"] = reference }
                survivor.formatting.textRuns = [run]
            case "connector":
                var edge = DiagramEdge(source: UUID(), target: UUID(), sourcePosition: DiagramPoint(x: 400, y: 400), targetPosition: DiagramPoint(x: 450, y: 450))
                edge.formatting.sheet["User.W"] = reference; input.page.edges.append(edge)
            case "page": input.page.sheet = ["User.W": reference]
            default: break
            }
            input.page.nodes.append(survivor)
            if scope == "definition" {
                input = try source(input) { parts in
                    let xml = try VisioXML.document(XCTUnwrap(parts["visio/document.xml"]))
                    xml.rootElement()?.firstLocal("DocumentSheet")?.addChild(try VisioXML.element("<Cell N=\"User.Depend\" V=\"1\" F=\"Sheet.0001!Width\"/>"))
                    parts["visio/document.xml"] = xml.xmlData(options: .nodePreserveAll)
                }
            }
            let chosen = scope == "definition" ? Set(input.page.nodes.prefix(2).map(\.id)) : selected
            XCTAssertThrowsError(try BooleanGeometry.union(chosen, in: input), scope) { XCTAssertTrue($0.localizedDescription.contains("reference"), $0.localizedDescription) }
        }
    }

    func testQuotedSheetNamesAreDataButDynamicOrUnparsedSurvivingFormulasRefuse() throws {
        var input = model(), survivor = rectangle(450, 100, 40, 40)
        let selected = ids(input); survivor.formatting.sheet["User.Label"] = ShapeSheetCell(value: "Sheet.1!Width", formula: "\"Sheet.1!Width\"")
        input.page.nodes.append(survivor)
        XCTAssertNoThrow(try BooleanGeometry.union(selected, in: input))
        for formula in ["EVALTEXT(\"Sheet.1!Width\")", "Width+"] {
            input.page.nodes[2].formatting.sheet["User.Label"]?.formula = formula
            XCTAssertThrowsError(try BooleanGeometry.union(selected, in: input))
        }
    }

    func testOpaqueConsumedSourceAndUnqualifiedRelationshipsRefuseWithoutFlattening() throws {
        for kind in ["attribute", "child", "row", "part", "relationship", "survivor extension", "public connection", "theme extension", "metadata extension", "relationship extension", "relationship impostor", "survivor section", "survivor geometry"] {
            var base = model(); base.page.nodes.append(rectangle(450, 100, 40, 40))
            let imported = try source(base) { parts in
                let xml = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
                let shape = try XCTUnwrap(xml.rootElement()?.firstLocal("Shapes")?.elementsLocal("Shape").first)
                switch kind {
                case "attribute": shape.setAttr("VendorBehavior", "retain")
                case "child": shape.addChild(try VisioXML.element("<VendorPayload Target=\"3\">opaque</VendorPayload>"))
                case "row": shape.elementsLocal("Section").first { $0.attr("N") == "Geometry" }?.addChild(try VisioXML.element("<Row IX=\"999\" T=\"VendorGeometry\"><Cell N=\"X\" V=\"0\"/></Row>"))
                case "part": parts["vendor/payload.bin"] = Data([0x00, 0x01, 0x02])
                case "relationship":
                    parts["visio/pages/_rels/page1.xml.rels"] = Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"vendor1\" Type=\"urn:vendor:behavior\" Target=\"../document.xml\"/></Relationships>".utf8)
                case "theme extension": parts["visio/theme/theme1.xml"] = Data("<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><VendorDependency Target=\"1\"/></a:theme>".utf8)
                case "metadata extension":
                    let core = try VisioXML.document(XCTUnwrap(parts["docProps/core.xml"]))
                    core.rootElement()?.addChild(try VisioXML.element("<VendorDependency Target=\"1\"/>"))
                    parts["docProps/core.xml"] = core.xmlData(options: .nodePreserveAll)
                case "relationship extension", "relationship impostor":
                    let relationships = try VisioXML.document(XCTUnwrap(parts["visio/_rels/document.xml.rels"]))
                    relationships.rootElement()?.addChild(try VisioXML.element(kind == "relationship extension" ? "<VendorDependency Target=\"1\"/>" : "<Relationship Id=\"vendor1\" Type=\"urn:vendor/pages\" Target=\"pages/pages.xml\"/>"))
                    parts["visio/_rels/document.xml.rels"] = relationships.xmlData(options: .nodePreserveAll)
                case "survivor extension": xml.rootElement()?.firstLocal("Shapes")?.elementsLocal("Shape").last?.addChild(try VisioXML.element("<VendorDependency Target=\"1\"/>"))
                case "survivor section": xml.rootElement()?.firstLocal("Shapes")?.elementsLocal("Shape").last?.addChild(try VisioXML.element("<Section N=\"VendorBehavior\"><Row N=\"Target\"><Cell N=\"Value\" V=\"1\"/></Row></Section>"))
                case "survivor geometry": xml.rootElement()?.firstLocal("Shapes")?.elementsLocal("Shape").last?.elementsLocal("Section").first { $0.attr("N") == "Geometry" }?.addChild(try VisioXML.element("<Row IX=\"999\" T=\"VendorGeometry\"><Cell N=\"X\" V=\"1\"/></Row>"))
                case "public connection":
                    let connects = xml.rootElement()?.firstLocal("Connects") ?? XMLElement(name: "Connects")
                    if connects.parent == nil { xml.rootElement()?.addChild(connects) }
                    connects.addChild(try VisioXML.element("<Connect FromSheet=\"3\" FromCell=\"BeginX\" ToSheet=\"1\" ToCell=\"PinX\"/>"))
                default: break
                }
                parts["visio/pages/page1.xml"] = xml.xmlData(options: .nodePreserveAll)
            }
            let before = imported
            XCTAssertThrowsError(try BooleanGeometry.union(Set(imported.page.nodes.prefix(2).map(\.id)), in: imported), kind)
            XCTAssertEqual(imported, before)
        }
    }

    func testSavedNativeBasicDrawingUnitesButUnknownPrivatePrefixPartsAndRegistrationsRefuse() throws {
        let url = file(); try VisioFormat.write(model(), to: url)
        let native = try VisioFormat.read(from: url).diagram
        XCTAssertNoThrow(try BooleanGeometry.union(ids(native), in: native))
        for kind in ["macvisio/public.xml", "macvisio/metadata/public.xml", "external registration"] {
            let input = try source(model()) { parts in
                if kind == "external registration" {
                    let xml = try VisioXML.document(XCTUnwrap(parts["_rels/.rels"]))
                    xml.rootElement()?.elementsLocal("Relationship").first { $0.attr("Type") == "urn:macvisio:relationships:diagram" }?.setAttr("TargetMode", "External")
                    parts["_rels/.rels"] = xml.xmlData(options: .nodePreserveAll)
                } else { parts[kind] = Data("<PublicDependency ShapeID=\"1\"><Cell N=\"Value\" V=\"1\" F=\"Sheet.1!Width\"/></PublicDependency>".utf8) }
            }
            XCTAssertThrowsError(try BooleanGeometry.union(ids(input), in: input), kind)
        }
    }

    func testProtectionBehaviorAndOpenPathRefusalsPreserveEveryOriginal() throws {
        for kind in ["locked", "LockDelete", "LockVtxEdit", "LockFormat", "text", "data", "formula", "port", "open", "empty", "connector"] {
            var input = model()
            switch kind {
            case "locked": input.page.nodes[0].locked = true
            case "LockDelete", "LockVtxEdit", "LockFormat": input.page.nodes[0].formatting.sheet[kind] = ShapeSheetCell(value: "1")
            case "text": input.page.nodes[0].text = "Keep text"
            case "data": input.page.nodes[0].formatting.data = [ShapeDataProperty(key: "Keep", label: "Keep", value: "Data")]
            case "formula": input.page.nodes[0].formatting.sheet["Width"] = ShapeSheetCell(value: "1", formula: "GUARD(1)")
            case "port": input.page.nodes[0].formatting.connectionPoints = [ShapeConnectionPoint(index: 0, x: ShapeSheetCell(value: "0"), y: ShapeSheetCell(value: "0"))]
            case "open": input.page.nodes[0].formatting.paths = [VectorPath(commands: [VectorCommand("M", 0, 0), VectorCommand("L", 1, 0), VectorCommand("L", 1, 1)])]
            case "empty": input.page.nodes[0].formatting.paths = [VectorPath(commands: [VectorCommand("M", 0, 0), VectorCommand("L", 1, 1), VectorCommand("Z")])]
            case "connector": input.page.edges = [DiagramEdge(source: input.page.nodes[0].id, target: input.page.nodes[1].id)]
            default: break
            }
            let before = input; XCTAssertThrowsError(try BooleanGeometry.union(ids(input), in: input), kind); XCTAssertEqual(input, before)
        }
    }

    func testInputBudgetsNonfiniteAndPrecancelledRequestsFailBeforeReplacement() throws {
        var oversized = model()
        oversized.page.nodes[1].formatting.paths = [VectorPath(commands: [VectorCommand("M", 0, 0)] + (0..<BooleanGeometry.maximumInputCommands).map { VectorCommand("L", Double($0 % 2), Double(($0 / 2) % 2)) } + [VectorCommand("Z")])]
        XCTAssertThrowsError(try BooleanGeometry.union(ids(oversized), in: oversized)) { XCTAssertTrue($0.localizedDescription.contains("input limit")) }
        var tooMany = model((0...BooleanGeometry.maximumShapes).map { rectangle(Double($0 * 10), 100, 30, 30) })
        XCTAssertThrowsError(try BooleanGeometry.union(ids(tooMany), in: tooMany))
        tooMany = model(); tooMany.page.nodes[0].width = .infinity
        XCTAssertThrowsError(try BooleanGeometry.union(ids(tooMany), in: tooMany))
        let cancellation = LifecycleJobCancellation(); cancellation.cancel()
        let input = model()
        XCTAssertThrowsError(try BooleanGeometry.union(ids(input), in: input, cancellation: cancellation)) { XCTAssertEqual($0 as? LifecycleJobError, .cancelled) }
    }

    func testNativeUnionCommitsOneUndoAndRestoresCompleteOriginals() throws {
        try withEditor(model()) { document, editor in
            let before = document.diagram, state = document.stateID, selected = ids(before)
            editor.canvas.select(selected); XCTAssertNil(editor.unionUnavailableReason)
            editor.unionSelection(nil); XCTAssertTrue(document.isCalculating); wait(document)
            XCTAssertNil(document.lastCalculationJobError); XCTAssertEqual(document.diagram.page.nodes.count, 1)
            XCTAssertEqual(editor.canvas.selectedNodes, Set(document.diagram.page.nodes.map(\.id)))
            XCTAssertTrue(document.isDocumentEdited); XCTAssertEqual(document.undoManager?.undoActionName, "Union Shapes")
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state)
            XCTAssertFalse(document.isDocumentEdited); XCTAssertFalse(document.undoManager?.canUndo ?? true)
            document.undoManager?.redo(); XCTAssertEqual(document.diagram.page.nodes.count, 1)
        }
    }

    func testSourceBackedUnionIsTopmostAboveOverlappingSurvivorInNativeAndPublicPixels() throws {
        var base = model(), survivor = rectangle(170, 130, 180, 100)
        for index in base.page.nodes.indices { base.page.nodes[index].fill = "#FF0000"; base.page.nodes[index].stroke = "#00000000" }
        survivor.fill = "#0000FF"; survivor.stroke = "#00000000"; survivor.formatting.sourceShapeID = "90"
        base.page.nodes.append(survivor)
        let imported = try publicDiagram(base), selected = Set(imported.page.nodes.prefix(2).map(\.id))
        try withEditor(imported) { document, editor in
            func sample(_ diagram: Diagram) throws -> NSColor {
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: DiagramExport.png(diagram.scene(), scale: 1)))
                return try XCTUnwrap(bitmap.colorAt(x: 200, y: 160)?.usingColorSpace(.sRGB))
            }
            func assertRed(_ color: NSColor, file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertGreaterThan(color.redComponent, 0.9, file: file, line: line)
                XCTAssertLessThan(color.blueComponent, 0.1, file: file, line: line)
            }
            let originalPixel = try sample(document.diagram), state = document.stateID
            XCTAssertGreaterThan(originalPixel.blueComponent, 0.9); XCTAssertLessThan(originalPixel.redComponent, 0.1)
            editor.canvas.select(selected); editor.unionSelection(nil); wait(document)
            XCTAssertNil(document.lastCalculationJobError)
            let result = try XCTUnwrap(document.diagram.page.nodes.first { editor.canvas.selectedNodes.contains($0.id) })
            XCTAssertEqual(document.diagram.page.nodes.last?.id, result.id)
            assertRed(try sample(document.diagram))
            let reopened = try publicDiagram(document.diagram)
            XCTAssertEqual(reopened.page.nodes.last?.formatting.sourceShapeID, result.formatting.sourceShapeID)
            assertRed(try sample(reopened))
            document.undoManager?.undo(); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.diagram, imported)
            XCTAssertGreaterThan(try sample(document.diagram).blueComponent, 0.9)
        }
    }

    func testNativeCurvedHoledUnionWritesNativeAndPublicOnlyArtifacts() throws {
        var ellipse = rectangle(380, 100, 100, 100); ellipse.kind = .ellipse
        try withEditor(model([ring(evenOdd: true), ellipse])) { document, editor in
            editor.canvas.select(ids(document.diagram)); editor.unionSelection(nil); XCTAssertTrue(document.isCalculating); wait(document)
            XCTAssertNil(document.lastCalculationJobError); XCTAssertEqual(document.diagram.page.nodes.count, 1)
            let nativeURL = file(); try VisioFormat.write(document.diagram, to: nativeURL)
            var parts = try VisioPackage.read(nativeURL)
            let metadata = try XCTUnwrap(parts["macvisio/document.json"])
            let storage = try NativeMetadataStorage.load(metadata, parts: parts)
            for name in storage.storageParts.union(["macvisio/document.json"]) { parts.removeValue(forKey: name) }
            let rels = try VisioXML.document(XCTUnwrap(parts["_rels/.rels"]))
            for relationship in rels.rootElement()?.elementsLocal("Relationship") ?? [] where relationship.attr("Type") == "urn:macvisio:relationships:diagram" { relationship.detach() }
            parts["_rels/.rels"] = rels.xmlData(options: .nodePreserveAll)
            let types = try VisioXML.document(XCTUnwrap(parts["[Content_Types].xml"]))
            for entry in types.rootElement()?.elementsLocal("Override") ?? [] where entry.attr("PartName") == "/macvisio/document.json" { entry.detach() }
            parts["[Content_Types].xml"] = types.xmlData(options: .nodePreserveAll)
            XCTAssertFalse(parts.keys.contains { $0.hasPrefix("macvisio/") })
            let publicURL = file(); try VisioPackage.write(parts, to: publicURL)
            let node = try XCTUnwrap(VisioFormat.read(from: publicURL).diagram.page.nodes.first)
            XCTAssertTrue(contains(node, CGPoint(x: 120, y: 200))); XCTAssertFalse(contains(node, CGPoint(x: 200, y: 200)))
            XCTAssertTrue(contains(node, CGPoint(x: 430, y: 150))); XCTAssertFalse(contains(node, CGPoint(x: 390, y: 110)))
            if let directory = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"], !directory.isEmpty {
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data(contentsOf: nativeURL).write(to: destination.appendingPathComponent("m3-union-curves-holes-native.vsdx"), options: .atomic)
                try Data(contentsOf: publicURL).write(to: destination.appendingPathComponent("m3-union-curves-holes-public.vsdx"), options: .atomic)
            }
        }
    }

    func testNativeCancelAndStaleResultsCannotReplaceCommittedState() throws {
        for stale in [false, true] {
            try withEditor(model()) { document, editor in
                let selected = ids(document.diagram); editor.canvas.select(selected)
                editor.unionSelection(nil); XCTAssertTrue(document.isCalculating)
                if stale {
                    document.diagram.page.nodes[0].fill = "#AA0055"; document.updateChangeCount(.changeDone)
                    editor.canvas.select(selected)
                } else { document.cancelPendingCalculation() }
                let before = document.diagram, state = document.stateID, revision = document.revision, dirty = document.isDocumentEdited
                wait(document)
                XCTAssertEqual(document.lastCalculationJobError as? LifecycleJobError, stale ? .staleInput : .cancelled)
                XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
                XCTAssertEqual(document.isDocumentEdited, dirty); XCTAssertFalse(document.undoManager?.canUndo ?? true)
                XCTAssertEqual(editor.canvas.selectedNodes, selected)
            }
        }
    }

    func testNativeWorkerSourceRefusalRestoresSelectionAndDoesNotDirtyDrawing() throws {
        let input = try source(model()) { $0["vendor/opaque.bin"] = Data([1, 2, 3]) }
        try withEditor(input) { document, editor in
            let before = document.diagram, state = document.stateID, revision = document.revision, selected = ids(before)
            editor.canvas.select(selected); editor.unionSelection(nil); XCTAssertTrue(document.isCalculating); wait(document)
            XCTAssertNotNil(document.lastCalculationJobError); XCTAssertTrue(editor.root.status.stringValue.contains("retained part"))
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertEqual(editor.canvas.selectedNodes, selected); XCTAssertFalse(document.isDocumentEdited); XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testRetainedClosedEditorUnionEntryPointsDoNotReadReleasedDocument() throws {
        try onMain {
            _ = NSApplication.shared
            var document: MacVisioDocument? = MacVisioDocument(); document!.diagram = model(); document!.makeWindowControllers()
            let editor = try XCTUnwrap(document!.windowControllers.first as? EditorWindowController)
            document!.close(); document = nil
            XCTAssertEqual(editor.unionUnavailableReason, "The drawing window is closed.")
            editor.unionSelection(nil)
        }
    }

    func testNativeUnionPreservesMarkedTextAndRefusesWhileAnEditIsPending() throws {
        try withEditor(model()) { document, editor in
            let before = document.diagram, selected = ids(before), state = document.stateID
            editor.canvas.select(selected); editor.canvas.beginEditing(before.page.nodes[0].id)
            let inline = try XCTUnwrap(editor.window?.firstResponder as? NSTextView)
            inline.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            XCTAssertTrue(inline.hasMarkedText()); XCTAssertTrue(editor.unionUnavailableReason?.contains("composition") == true)
            editor.unionSelection(nil)
            XCTAssertTrue(inline.hasMarkedText()); XCTAssertFalse(document.isCalculating)
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state); XCTAssertEqual(editor.canvas.selectedNodes, selected)
            inline.unmarkText(); editor.canvas.finishEditing(commit: false)
            editor.unionSelection(nil); XCTAssertTrue(document.isCalculating)
            let provisional = editor.canvas.selectedNodes
            XCTAssertTrue(editor.unionUnavailableReason?.contains("Wait") == true)
            editor.unionSelection(nil); XCTAssertEqual(editor.canvas.selectedNodes, provisional)
            document.cancelPendingCalculation(); wait(document)
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(editor.canvas.selectedNodes, selected)
        }
    }

    private func withEditor(_ input: Diagram, _ body: (MacVisioDocument, EditorWindowController) throws -> Void) throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); document.diagram = input; document.updateChangeCount(.changeCleared)
            document.makeWindowControllers(); document.undoManager?.groupsByEvent = false; document.undoManager?.removeAllActions()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            defer { if document.isCalculating { document.cancelPendingCalculation(); wait(document) }; document.close() }
            try body(document, editor)
        }
    }
    private func wait(_ document: MacVisioDocument, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(15)
        while document.isCalculating && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(document.isCalculating, file: file, line: line)
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }; return try DispatchQueue.main.sync(execute: body)
    }
}
