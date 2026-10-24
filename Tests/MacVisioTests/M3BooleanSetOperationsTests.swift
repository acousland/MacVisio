import AppKit
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

/// Two-operand local engineering. Styling uses drawing order, Subtract's base
/// is chosen explicitly, and the new topmost result remains selected. These
/// policies do not assert exact-build Visio selection-order/identity parity.
final class M3BooleanSetOperationsTests: XCTestCase {
    private func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> DiagramNode {
        var node = DiagramNode(x: x, y: y, text: ""); node.width = width; node.height = height; return node
    }
    private func model(_ nodes: [DiagramNode]? = nil) -> Diagram {
        var result = Diagram(); result.page.nodes = nodes ?? [rectangle(100, 100, 200, 160), rectangle(200, 180, 180, 160)]
        result.page.nodes[0].fill = "#FF3300"; result.page.nodes[1].fill = "#0055FF"; result.page.edges = []; return result
    }
    private func ids(_ diagram: Diagram) -> Set<UUID> { Set(diagram.page.nodes.filter { !$0.formatting.isGroup }.map(\.id)) }
    private func contains(_ node: DiagramNode, _ x: Double, _ y: Double) -> Bool { DiagramDrawing.outline(for: node).contains(CGPoint(x: x, y: y)) }
    private func apply(_ operation: BooleanGeometry.Operation, _ diagram: Diagram, selected: Set<UUID>? = nil) throws -> Diagram {
        switch operation {
        case .intersect: return try BooleanGeometry.intersect(selected ?? ids(diagram), in: diagram)
        case .subtract(let baseID): return try BooleanGeometry.subtract(selected ?? ids(diagram), in: diagram, baseID: baseID)
        case .union: throw DiagramError.invalid("This suite exercises Intersect and Subtract.")
        }
    }
    private func operations(_ diagram: Diagram) -> [BooleanGeometry.Operation] { [.intersect, .subtract(baseID: diagram.page.nodes[0].id)] }
    private func loop(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [VectorCommand] {
        [VectorCommand("M", x, y), VectorCommand("L", x + width, y), VectorCommand("L", x + width, y + height), VectorCommand("L", x, y + height), VectorCommand("Z")]
    }
    private func file() -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("M3-SetOperation-\(UUID()).vsdx")
        addTeardownBlock { try? FileManager.default.removeItem(at: result) }; return result
    }
    private func publicParts(_ input: [String: Data]) throws -> [String: Data] {
        var parts = input
        if let metadata = parts["macvisio/document.json"] {
            let storage = try NativeMetadataStorage.load(metadata, parts: parts)
            for name in storage.storageParts.union(["macvisio/document.json"]) { parts.removeValue(forKey: name) }
        }
        let rels = try VisioXML.document(XCTUnwrap(parts["_rels/.rels"]))
        for item in rels.rootElement()?.elementsLocal("Relationship") ?? [] where item.attr("Type") == "urn:macvisio:relationships:diagram" { item.detach() }
        parts["_rels/.rels"] = rels.xmlData(options: .nodePreserveAll)
        let types = try VisioXML.document(XCTUnwrap(parts["[Content_Types].xml"]))
        for item in types.rootElement()?.elementsLocal("Override") ?? [] where item.attr("PartName") == "/macvisio/document.json" { item.detach() }
        parts["[Content_Types].xml"] = types.xmlData(options: .nodePreserveAll)
        return parts
    }
    private func publicReopen(_ diagram: Diagram, retain name: String? = nil) throws -> Diagram {
        let native = file(); try VisioFormat.write(diagram, to: native)
        let parts = try publicParts(VisioPackage.read(native)), output = file(); try VisioPackage.write(parts, to: output)
        XCTAssertFalse(parts.keys.contains { $0.hasPrefix("macvisio/") })
        if let name, let path = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"], !path.isEmpty {
            let directory = URL(fileURLWithPath: path, isDirectory: true); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(contentsOf: native).write(to: directory.appendingPathComponent(name + "-native.vsdx"), options: .atomic)
            try Data(contentsOf: output).write(to: directory.appendingPathComponent(name + "-public.vsdx"), options: .atomic)
        }
        return try VisioFormat.read(from: output).diagram
    }
    private func source(_ diagram: Diagram, edit: (inout [String: Data]) throws -> Void) throws -> Diagram {
        let url = file(); try VisioFormat.write(diagram, to: url)
        var parts = try publicParts(VisioPackage.read(url)); try edit(&parts)
        return try VisioFormat.readPublic(parts: parts, title: "Two-operand source fixture").diagram
    }

    func testIntersectUsesOnlyTheSharedAreaAndDrawingOrderStyle() throws {
        let input = model(), output = try apply(.intersect, input), node = try XCTUnwrap(output.page.nodes.last)
        XCTAssertEqual(output.page.nodes.count, 1); XCTAssertEqual(node.rect, CGRect(x: 200, y: 180, width: 100, height: 80))
        XCTAssertEqual(node.fill, input.page.nodes[0].fill)
        XCTAssertTrue(contains(node, 250, 220)); XCTAssertFalse(contains(node, 120, 120)); XCTAssertFalse(contains(node, 350, 300))
        XCTAssertNotNil(node.formatting.geometry); XCTAssertFalse(ids(input).contains(node.id))
    }

    func testSubtractExplicitBaseReversesGeometryWithoutChangingTheLocalStylePolicy() throws {
        let input = model()
        let first = try XCTUnwrap(apply(.subtract(baseID: input.page.nodes[0].id), input).page.nodes.last)
        let second = try XCTUnwrap(apply(.subtract(baseID: input.page.nodes[1].id), input).page.nodes.last)
        XCTAssertTrue(contains(first, 120, 120)); XCTAssertFalse(contains(first, 250, 220)); XCTAssertFalse(contains(first, 350, 300))
        XCTAssertTrue(contains(second, 350, 300)); XCTAssertFalse(contains(second, 250, 220)); XCTAssertFalse(contains(second, 120, 120))
        XCTAssertEqual(first.fill, input.page.nodes[0].fill); XCTAssertEqual(second.fill, input.page.nodes[0].fill)
    }

    func testSectionsAreUnitedWithinEachOperandBeforeSetOperations() throws {
        var pieces = rectangle(100, 100, 240, 100)
        pieces.formatting.paths = [VectorPath(commands: loop(0, 0, 0.33, 1)), VectorPath(commands: loop(0.66, 0, 0.34, 1))]
        let input = model([pieces, rectangle(80, 120, 300, 50)])
        let intersection = try XCTUnwrap(apply(.intersect, input).page.nodes.last)
        XCTAssertTrue(contains(intersection, 110, 145)); XCTAssertTrue(contains(intersection, 315, 145)); XCTAssertFalse(contains(intersection, 220, 145))
        let subtractPieces = try XCTUnwrap(apply(.subtract(baseID: input.page.nodes[0].id), input).page.nodes.last)
        XCTAssertTrue(contains(subtractPieces, 110, 110)); XCTAssertTrue(contains(subtractPieces, 315, 190)); XCTAssertFalse(contains(subtractPieces, 110, 145))
        let subtractCutters = try XCTUnwrap(apply(.subtract(baseID: input.page.nodes[1].id), input).page.nodes.last)
        XCTAssertTrue(contains(subtractCutters, 220, 145)); XCTAssertFalse(contains(subtractCutters, 110, 145)); XCTAssertFalse(contains(subtractCutters, 315, 145))
    }

    func testCurvedIntersectionAndSubtractedHoleSurvivePublicOnlyReopen() throws {
        var ellipse = rectangle(100, 100, 200, 200); ellipse.kind = .ellipse
        let intersectionInput = model([ellipse, rectangle(150, 50, 100, 300)])
        var innerEllipse = rectangle(140, 140, 120, 120); innerEllipse.kind = .ellipse
        let subtractionInput = model([rectangle(100, 100, 200, 200), innerEllipse])
        for (input, operation, name) in [(intersectionInput, BooleanGeometry.Operation.intersect, "m3-intersect-curves"), (subtractionInput, .subtract(baseID: subtractionInput.page.nodes[0].id), "m3-subtract-hole")] {
            let output = try apply(operation, input), node = try XCTUnwrap(output.page.nodes.last)
            XCTAssertTrue(node.formatting.paths.flatMap(\.commands).contains { $0.kind == "C" })
            let reopened = try publicReopen(output, retain: name), publicNode = try XCTUnwrap(reopened.page.nodes.last)
            XCTAssertFalse(GeometrySheet.names(publicNode.formatting.geometry ?? []).isEmpty)
            if operation == .intersect {
                for value in [node, publicNode] { XCTAssertTrue(contains(value, 200, 110)); XCTAssertTrue(contains(value, 200, 200)); XCTAssertFalse(contains(value, 155, 105)); XCTAssertFalse(contains(value, 110, 200)) }
            } else {
                for value in [node, publicNode] { XCTAssertTrue(contains(value, 120, 120)); XCTAssertFalse(contains(value, 200, 200)); XCTAssertTrue(contains(value, 140, 140)) }
            }
        }
    }

    func testEvenOddHoleParticipatesInIntersectionAsAnEmptyRegion() throws {
        var ring = rectangle(100, 100, 200, 200)
        ring.formatting.paths = [VectorPath(commands: loop(0, 0, 1, 1) + loop(0.25, 0.25, 0.5, 0.5), evenOdd: true)]
        let input = model([ring, rectangle(80, 160, 240, 80)]), output = try apply(.intersect, input)
        for value in [try XCTUnwrap(output.page.nodes.last), try XCTUnwrap(publicReopen(output).page.nodes.last)] {
            XCTAssertTrue(contains(value, 120, 200)); XCTAssertTrue(contains(value, 280, 200)); XCTAssertFalse(contains(value, 200, 200))
        }
    }

    func testTransformedSiblingResultsUseWorldCoordinatesAndKeepTheirParent() throws {
        var a = rectangle(180, 180, 150, 100), b = rectangle(240, 190, 140, 130), group = rectangle(100, 100, 400, 300)
        a.rotation = 35; a.formatting.flipX = true
        a.formatting.paths = [VectorPath(commands: [VectorCommand("M", 0, 0), VectorCommand("L", 1, 0), VectorCommand("L", 0, 1), VectorCommand("Z")])]
        b.kind = .ellipse; b.rotation = -20; b.formatting.flipY = true
        group.formatting.isGroup = true; group.formatting.sourceShapeID = "50"; group.rotation = 25; group.formatting.flipX = true
        a.parentID = group.id; b.parentID = group.id
        var input = model([a, b]); input.page.nodes.insert(group, at: 0)
        func expected(_ node: DiagramNode, _ point: CGPoint) -> Bool {
            let local = DiagramCoordinates.local(point, in: node)
            return DiagramDrawing.outline(for: node).contains(CGPoint(x: node.x + local.x, y: node.y + local.y))
        }
        for operation in [BooleanGeometry.Operation.intersect, .subtract(baseID: a.id)] {
            let output = try apply(operation, input), native = try XCTUnwrap(output.page.nodes.last)
            XCTAssertEqual(output.page.nodes.first { $0.id == group.id }, group); XCTAssertEqual(native.parentID, group.id)
            let reopened = try publicReopen(output), publicNode = try XCTUnwrap(reopened.page.nodes.first { !$0.formatting.isGroup })
            for x in stride(from: 155.0, through: 400.0, by: 17) { for y in stride(from: 145.0, through: 340.0, by: 13) {
                let point = CGPoint(x: x, y: y), insideA = expected(a, point), insideB = expected(b, point)
                let answer = operation == .intersect ? insideA && insideB : insideA && !insideB
                XCTAssertEqual(contains(native, x, y), answer); XCTAssertEqual(contains(publicNode, x, y), answer)
            } }
        }
    }

    func testSetOperationsKeepInputLimitsAndCancellationBeforeGeometryWork() throws {
        var input = model()
        input.page.nodes[1].formatting.paths = [VectorPath(commands: [VectorCommand("M", 0, 0)] + (0..<BooleanGeometry.maximumInputCommands).map { VectorCommand("L", Double($0 % 2), Double(($0 / 2) % 2)) } + [VectorCommand("Z")])]
        for operation in operations(input) { XCTAssertThrowsError(try apply(operation, input)) }
        let ordinary = model(), cancellation = LifecycleJobCancellation(); cancellation.cancel()
        XCTAssertThrowsError(try BooleanGeometry.intersect(ids(ordinary), in: ordinary, cancellation: cancellation)) { XCTAssertEqual($0 as? LifecycleJobError, .cancelled) }
        XCTAssertThrowsError(try BooleanGeometry.subtract(ids(ordinary), in: ordinary, baseID: ordinary.page.nodes[0].id, cancellation: cancellation)) { XCTAssertEqual($0 as? LifecycleJobError, .cancelled) }
    }

    func testEmptyResultsInvalidBaseAndNonPairSelectionsRefuse() throws {
        let disjoint = model([rectangle(100, 100, 100, 100), rectangle(300, 300, 100, 100)])
        XCTAssertThrowsError(try apply(.intersect, disjoint))
        let identical = model([rectangle(100, 100, 100, 100), rectangle(100, 100, 100, 100)])
        XCTAssertThrowsError(try apply(.subtract(baseID: identical.page.nodes[0].id), identical))
        let input = model(); XCTAssertThrowsError(try apply(.subtract(baseID: UUID()), input))
        for operation in operations(input) {
            XCTAssertThrowsError(try apply(operation, input, selected: [input.page.nodes[0].id]))
            var three = input; three.page.nodes.append(rectangle(150, 150, 100, 100))
            XCTAssertThrowsError(try apply(operation, three))
        }
    }

    func testBothOperationsRetainProtectionBehaviorAndIncomingReferenceRefusals() throws {
        for kind in ["locked", "LockDelete", "LockVtxEdit", "LockFormat", "guarded", "text", "reference"] {
            var input = model(), selected = ids(input)
            switch kind {
            case "locked": input.page.nodes[0].locked = true
            case "LockDelete", "LockVtxEdit", "LockFormat": input.page.nodes[0].formatting.sheet[kind] = ShapeSheetCell(value: "1")
            case "guarded": input.page.nodes[0].formatting.sheet["Width"] = ShapeSheetCell(value: "1", formula: "GUARD(1)")
            case "text": input.page.nodes[0].text = "Keep this text"
            default:
                var survivor = rectangle(450, 100, 40, 40); survivor.formatting.sheet["User.Dependent"] = ShapeSheetCell(value: "1", formula: "Sheet.1!Width"); input.page.nodes.append(survivor)
            }
            selected = Set(input.page.nodes.prefix(2).map(\.id)); let before = input
            for operation in operations(input) { XCTAssertThrowsError(try apply(operation, input, selected: selected), kind) }
            XCTAssertEqual(input, before)
        }
    }

    func testPublicSourceTombstoneIDAndSurvivorRemainStableForBothOperations() throws {
        var base = model(), survivor = rectangle(450, 100, 40, 40)
        // The fresh writer reserves explicit IDs before assigning implicit ones.
        // Keep operands at 1/2 so survivor 90 does not allocate them 91/92.
        base.page.nodes[0].formatting.sourceShapeID = "1"; base.page.nodes[1].formatting.sourceShapeID = "2"
        survivor.formatting.sourceShapeID = "90"; base.page.nodes.append(survivor)
        let input = try source(base) { parts in
            let xml = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
            let shapes = try XCTUnwrap(xml.rootElement()?.firstLocal("Shapes"))
            XCTAssertEqual(Set(shapes.allShapes.compactMap { $0.attr("ID").flatMap(UInt32.init) }), [1, 2, 90])
            XCTAssertFalse(shapes.allShapes.contains { $0.attr("ID").flatMap(UInt32.init) == 91 })
            shapes.addChild(try VisioXML.element("<Shape ID=\"00091\" Del=\"1\"/>")); parts["visio/pages/page1.xml"] = xml.xmlData(options: .nodePreserveAll)
        }
        let selected = Set(input.page.nodes.filter { ["1", "2"].contains($0.formatting.sourceShapeID ?? "") }.map(\.id))
        XCTAssertEqual(selected.count, 2)
        for operation in operations(input) {
            let output = try apply(operation, input, selected: selected), result = try XCTUnwrap(output.page.nodes.last), url = file()
            XCTAssertEqual(result.formatting.sourceShapeID, "92")
            let archive = try VisioFormat.writeRebased(output, to: url)
            XCTAssertEqual(archive.pages.first?.nodeIDs[result.id], "92")
            let xml = try VisioXML.document(XCTUnwrap(archive.parts["visio/pages/page1.xml"]))
            XCTAssertEqual(xml.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "00091" }?.attr("Del"), "1")
            let native = try VisioFormat.read(from: url).diagram
            XCTAssertEqual(native.page.nodes.first { $0.id == result.id }?.formatting.sourceShapeID, "92")
            let publicURL = file(); try VisioPackage.write(publicParts(VisioPackage.read(url)), to: publicURL)
            let reopened = try VisioFormat.read(from: publicURL).diagram
            XCTAssertEqual(reopened.page.nodes.last?.formatting.sourceShapeID, "92")
            XCTAssertEqual(reopened.page.nodes.first { $0.formatting.sourceShapeID == "90" }?.x ?? 0, 450, accuracy: 1e-6)
        }
        // A tombstone alias of a consumed ID still fails the source proof.
        let collision = try source(base) { parts in
            let xml = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
            xml.rootElement()?.firstLocal("Shapes")?.addChild(try VisioXML.element("<Shape ID=\"0001\" Del=\"1\"/>")); parts["visio/pages/page1.xml"] = xml.xmlData(options: .nodePreserveAll)
        }
        let before = collision, consumed = Set(collision.page.nodes.filter { ["1", "2"].contains($0.formatting.sourceShapeID ?? "") }.map(\.id))
        for operation in operations(collision) {
            XCTAssertThrowsError(try apply(operation, collision, selected: consumed)) { XCTAssertTrue($0.localizedDescription.contains("opaque source attributes")) }
        }
        XCTAssertEqual(collision, before)
    }

    func testOpaqueSourcePartStillRefusesForBothOperations() throws {
        let input = try source(model()) { $0["vendor/behavior.bin"] = Data([1, 2, 3]) }
        for operation in operations(input) { XCTAssertThrowsError(try apply(operation, input)) }
    }

    func testSourceBackedResultsStayTopmostAboveAnOverlappingSurvivorInNativeAndPublicPixels() throws {
        var base = model(), survivor = rectangle(100, 100, 280, 240)
        for index in base.page.nodes.indices { base.page.nodes[index].fill = "#FF0000"; base.page.nodes[index].stroke = "#00000000" }
        survivor.fill = "#0000FF"; survivor.stroke = "#00000000"; survivor.formatting.sourceShapeID = "90"; base.page.nodes.append(survivor)
        let input = try source(base) { _ in }, selected = Set(input.page.nodes.prefix(2).map(\.id))
        for command in ["intersect", "subtract"] {
            try withEditor(input) { drawing, editor in
                let point = command == "intersect" ? CGPoint(x: 250, y: 220) : CGPoint(x: 120, y: 120)
                func sample(_ diagram: Diagram) throws -> NSColor {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: DiagramExport.png(diagram.scene(), scale: 1)))
                    return try XCTUnwrap(bitmap.colorAt(x: Int(point.x), y: Int(point.y))?.usingColorSpace(.sRGB))
                }
                XCTAssertGreaterThan(try sample(drawing.diagram).blueComponent, 0.9)
                editor.canvas.select(selected)
                if command == "intersect" { editor.intersectSelection(nil) }
                else { editor.subtractSelection(nil); XCTAssertTrue(editor.subtractionChooserController.applySelectedBase()) }
                wait(drawing); XCTAssertNil(drawing.lastCalculationJobError)
                let result = try XCTUnwrap(drawing.diagram.page.nodes.last)
                XCTAssertEqual(editor.canvas.selectedNodes, [result.id]); XCTAssertTrue(contains(result, point.x, point.y))
                let reopened = try publicReopen(drawing.diagram)
                XCTAssertEqual(reopened.page.nodes.last?.formatting.sourceShapeID, result.formatting.sourceShapeID)
                for value in [drawing.diagram, reopened] {
                    let color = try sample(value); XCTAssertGreaterThan(color.redComponent, 0.9); XCTAssertLessThan(color.blueComponent, 0.1)
                }
                drawing.undoManager?.undo(); XCTAssertEqual(drawing.diagram, input); XCTAssertGreaterThan(try sample(drawing.diagram).blueComponent, 0.9)
            }
        }
    }

    func testNativeIntersectIsOneOwnedUndoTransaction() throws {
        try withEditor(model()) { drawing, editor in
            let before = drawing.diagram, state = drawing.stateID; editor.canvas.select(ids(before))
            editor.intersectSelection(nil); XCTAssertTrue(drawing.isCalculating); wait(drawing)
            XCTAssertNil(drawing.lastCalculationJobError); XCTAssertEqual(drawing.diagram.page.nodes.count, 1)
            XCTAssertEqual(drawing.undoManager?.undoActionName, "Intersect Shapes"); XCTAssertTrue(contains(drawing.diagram.page.nodes[0], 250, 220))
            drawing.undoManager?.undo(); XCTAssertEqual(drawing.diagram, before); XCTAssertEqual(drawing.stateID, state); XCTAssertFalse(drawing.isDocumentEdited)
            XCTAssertFalse(drawing.undoManager?.canUndo ?? true)
        }
    }

    func testNativeSubtractionChooserUsesTheExplicitReversedBaseAndOneUndo() throws {
        try withEditor(model()) { drawing, editor in
            let before = drawing.diagram, state = drawing.stateID; editor.canvas.select(ids(before)); editor.subtractSelection(nil)
            let chooser = editor.subtractionChooserController
            XCTAssertEqual(chooser.basePicker.numberOfItems, 2); XCTAssertFalse(drawing.isCalculating)
            XCTAssertTrue(chooser.selectBase(before.page.nodes[1].id)); XCTAssertEqual(chooser.selectedBaseID, before.page.nodes[1].id)
            XCTAssertTrue(chooser.applySelectedBase()); XCTAssertTrue(drawing.isCalculating); wait(drawing)
            XCTAssertNil(drawing.lastCalculationJobError); let result = try XCTUnwrap(drawing.diagram.page.nodes.last)
            XCTAssertTrue(contains(result, 350, 300)); XCTAssertFalse(contains(result, 120, 120)); XCTAssertEqual(result.fill, before.page.nodes[0].fill)
            XCTAssertEqual(drawing.undoManager?.undoActionName, "Subtract Shapes")
            drawing.undoManager?.undo(); XCTAssertEqual(drawing.diagram, before); XCTAssertEqual(drawing.stateID, state); XCTAssertFalse(drawing.isDocumentEdited)
        }
    }

    func testDuplicateChooserLabelsKeepBothUUIDsUntilTheWorkerRefusesAmbiguousPublicIDs() throws {
        var input = model(); input.page.nodes[0].formatting.sourceShapeID = "7"; input.page.nodes[1].formatting.sourceShapeID = "7"
        try withEditor(input) { drawing, editor in
            let selected = ids(input), state = drawing.stateID; editor.canvas.select(selected); editor.subtractSelection(nil)
            let chooser = editor.subtractionChooserController
            XCTAssertEqual(chooser.basePicker.numberOfItems, 2)
            XCTAssertEqual(chooser.basePicker.itemTitles.first, chooser.basePicker.itemTitles.last)
            let represented = Set(chooser.basePicker.itemArray.compactMap { ($0.representedObject as? NSUUID).map { $0 as UUID } })
            XCTAssertEqual(represented, selected)
            XCTAssertTrue(chooser.selectBase(input.page.nodes[1].id)); XCTAssertEqual(chooser.selectedBaseID, input.page.nodes[1].id)
            XCTAssertTrue(chooser.applySelectedBase()); wait(drawing)
            XCTAssertNotNil(drawing.lastCalculationJobError); XCTAssertEqual(drawing.diagram, input); XCTAssertEqual(drawing.stateID, state)
            XCTAssertEqual(editor.canvas.selectedNodes, selected); XCTAssertFalse(drawing.isDocumentEdited); XCTAssertFalse(drawing.undoManager?.canUndo ?? true)
        }
    }

    func testCommandSearchUsesNativeIntersectAndSubtractChooserRouting() throws {
        try withEditor(model()) { drawing, editor in
            let before = drawing.diagram; editor.canvas.select(ids(before))
            let search = editor.commandSearchController; defer { search.close() }
            search.searchField.stringValue = "boolean intersect"; search.filterCommands()
            XCTAssertEqual(search.selectedCommand?.action, #selector(EditorWindowController.intersectSelection(_:)))
            XCTAssertTrue(search.runButton.isEnabled); XCTAssertTrue(search.executeSelected()); wait(drawing)
            XCTAssertNil(drawing.lastCalculationJobError); XCTAssertEqual(drawing.diagram.page.nodes.count, 1)
            XCTAssertEqual(drawing.undoManager?.undoActionName, "Intersect Shapes")
            drawing.undoManager?.undo(); XCTAssertEqual(drawing.diagram, before)
            editor.canvas.select(ids(before)); search.searchField.stringValue = "boolean subtract"; search.filterCommands()
            XCTAssertEqual(search.selectedCommand?.action, #selector(EditorWindowController.subtractSelection(_:)))
            XCTAssertTrue(search.runButton.isEnabled); XCTAssertTrue(search.executeSelected())
            let chooser = editor.subtractionChooserController
            XCTAssertEqual(chooser.basePicker.numberOfItems, 2); XCTAssertFalse(drawing.isCalculating)
            chooser.cancelOperation(nil); XCTAssertEqual(drawing.diagram, before); XCTAssertFalse(drawing.isDocumentEdited)
        }
    }

    func testNativeChooserCancelAndEverySnapshotBoundaryPreserveCurrentState() throws {
        for change in ["cancel", "revision", "page", "selection", "connector"] {
            var input = model(); input.pages.append(DiagramPage(name: "Other page"))
            try withEditor(input) { drawing, editor in
                editor.canvas.select(ids(input)); editor.subtractSelection(nil); let chooser = editor.subtractionChooserController
                switch change {
                case "revision": drawing.diagram.title = "Newer title"; drawing.updateChangeCount(.changeDone)
                case "page": drawing.activatePage(input.pages[1].id)
                case "selection": editor.canvas.select([input.page.nodes[0].id])
                case "connector": editor.canvas.select(ids(input), edge: UUID())
                default: chooser.cancelOperation(nil)
                }
                let before = drawing.diagram, state = drawing.stateID, revision = drawing.revision, selected = editor.canvas.selectedNodes
                XCTAssertFalse(chooser.applySelectedBase(), change); XCTAssertFalse(drawing.isCalculating)
                XCTAssertEqual(drawing.diagram, before); XCTAssertEqual(drawing.stateID, state); XCTAssertEqual(drawing.revision, revision)
                XCTAssertEqual(editor.canvas.selectedNodes, selected); XCTAssertFalse(drawing.undoManager?.canUndo ?? true)
            }
        }
    }

    func testMarkedTextInChooserOrParentCannotApplyChangeBaseOrCancelComposition() throws {
        for scope in ["chooser", "parent"] {
            try withEditor(model()) { drawing, editor in
                let before = drawing.diagram; editor.canvas.select(ids(before)); editor.subtractSelection(nil)
                let chooser = editor.subtractionChooserController, text: NSTextView
                if scope == "chooser" {
                    text = NSTextView(frame: CGRect(x: 20, y: 90, width: 200, height: 40)); chooser.window?.contentView?.addSubview(text); chooser.window?.makeFirstResponder(text)
                } else { editor.canvas.beginEditing(before.page.nodes[0].id); text = try XCTUnwrap(editor.window?.firstResponder as? NSTextView) }
                text.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
                XCTAssertTrue(text.hasMarkedText()); XCTAssertFalse(chooser.applySelectedBase()); XCTAssertFalse(chooser.selectBase(before.page.nodes[1].id))
                XCTAssertFalse(chooser.presentCurrentSelection()); editor.intersectSelection(nil); editor.subtractSelection(nil)
                chooser.cancelOperation(nil); XCTAssertTrue(text.hasMarkedText()); XCTAssertEqual(drawing.diagram, before); XCTAssertFalse(drawing.isCalculating)
                text.unmarkText(); if scope == "parent" { editor.canvas.finishEditing(commit: false) } else { text.removeFromSuperview() }
                chooser.cancelOperation(nil)
            }
        }
    }

    func testClosedWeakOwnedChooserAndRetainedEditorCannotReadReleasedDrawing() throws {
        try onMain {
            _ = NSApplication.shared
            var drawing: MacVisioDocument? = MacVisioDocument(); drawing!.diagram = model(); drawing!.makeWindowControllers()
            let editor = try XCTUnwrap(drawing!.windowControllers.first as? EditorWindowController); editor.canvas.select(ids(drawing!.diagram))
            editor.subtractSelection(nil); let chooser = editor.subtractionChooserController
            drawing!.close(); drawing = nil
            XCTAssertEqual(chooser.unavailableReason, "The drawing window is closed."); XCTAssertFalse(chooser.presentCurrentSelection()); XCTAssertFalse(chooser.applySelectedBase())
            XCTAssertEqual(editor.intersectUnavailableReason, "The drawing window is closed."); XCTAssertEqual(editor.subtractUnavailableReason, "The drawing window is closed.")
            editor.intersectSelection(nil); editor.subtractSelection(nil)
        }
    }

    func testNativeWorkerCancelStaleAndEmptyResultsKeepTheirCommittedSnapshots() throws {
        for command in ["intersect", "subtract"] { for outcome in ["cancel", "stale", "empty"] {
            let input = outcome == "empty" ? (command == "intersect" ? model([rectangle(100, 100, 100, 100), rectangle(300, 300, 100, 100)]) : model([rectangle(100, 100, 100, 100), rectangle(100, 100, 100, 100)])) : model()
            try withEditor(input) { drawing, editor in
                let selected = ids(input); editor.canvas.select(selected)
                if command == "intersect" { editor.intersectSelection(nil) }
                else { editor.subtractSelection(nil); XCTAssertTrue(editor.subtractionChooserController.applySelectedBase()) }
                XCTAssertTrue(drawing.isCalculating)
                if outcome == "cancel" { drawing.cancelPendingCalculation() }
                if outcome == "stale" { drawing.diagram.title = "New committed title"; drawing.updateChangeCount(.changeDone); editor.canvas.select(selected) }
                let before = drawing.diagram, state = drawing.stateID, revision = drawing.revision, dirty = drawing.isDocumentEdited
                wait(drawing); XCTAssertNotNil(drawing.lastCalculationJobError)
                if outcome == "cancel" { XCTAssertEqual(drawing.lastCalculationJobError as? LifecycleJobError, .cancelled) }
                if outcome == "stale" { XCTAssertEqual(drawing.lastCalculationJobError as? LifecycleJobError, .staleInput) }
                XCTAssertEqual(drawing.diagram, before); XCTAssertEqual(drawing.stateID, state); XCTAssertEqual(drawing.revision, revision)
                XCTAssertEqual(drawing.isDocumentEdited, dirty); XCTAssertEqual(editor.canvas.selectedNodes, selected); XCTAssertFalse(drawing.undoManager?.canUndo ?? true)
            }
        } }
    }

    func testNativeSubmissionRejectsAnotherOwnerWithoutProvisionalSelectionDrift() throws {
        try withEditor(model()) { drawing, editor in
            let selected = ids(drawing.diagram), state = drawing.stateID; editor.canvas.select(selected)
            let wrong = LifecycleJobInput(ownerID: UUID(), snapshotID: state, revision: drawing.revision)
            XCTAssertFalse(editor.submitSetOperation(.intersect, selected: selected, expected: wrong, pageID: drawing.diagram.activePageID))
            XCTAssertFalse(drawing.isCalculating); XCTAssertEqual(drawing.stateID, state); XCTAssertEqual(editor.canvas.selectedNodes, selected)
        }
    }

    func testClosingDuringEitherNativeOperationCannotPublishItsPreparedResult() throws {
        for command in ["intersect", "subtract"] {
            try withEditor(model()) { drawing, editor in
                let before = drawing.diagram, state = drawing.stateID, revision = drawing.revision
                editor.canvas.select(ids(before))
                if command == "intersect" { editor.intersectSelection(nil) }
                else { editor.subtractSelection(nil); XCTAssertTrue(editor.subtractionChooserController.applySelectedBase()) }
                XCTAssertTrue(drawing.isCalculating); drawing.close(); wait(drawing)
                XCTAssertNotNil(drawing.lastCalculationJobError); XCTAssertEqual(drawing.diagram, before)
                XCTAssertEqual(drawing.stateID, state); XCTAssertEqual(drawing.revision, revision); XCTAssertFalse(drawing.isDocumentEdited)
                XCTAssertFalse(drawing.undoManager?.canUndo ?? true)
                XCTAssertEqual(editor.intersectUnavailableReason, "The drawing window is closed.")
                XCTAssertEqual(editor.subtractUnavailableReason, "The drawing window is closed.")
            }
        }
    }

    private func withEditor(_ input: Diagram, _ body: (MacVisioDocument, EditorWindowController) throws -> Void) throws {
        try onMain {
            _ = NSApplication.shared
            let drawing = MacVisioDocument(); drawing.diagram = input; drawing.updateChangeCount(.changeCleared); drawing.makeWindowControllers()
            drawing.undoManager?.groupsByEvent = false; drawing.undoManager?.removeAllActions()
            let editor = try XCTUnwrap(drawing.windowControllers.first as? EditorWindowController)
            defer { if drawing.isCalculating { drawing.cancelPendingCalculation(); wait(drawing) }; editor.detachBooleanOperandChooser(); drawing.close() }
            try body(drawing, editor)
        }
    }
    private func wait(_ drawing: MacVisioDocument, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(15)
        while drawing.isCalculating && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(drawing.isCalculating, file: file, line: line)
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }; return try DispatchQueue.main.sync(execute: body)
    }
}
