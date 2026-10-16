import AppKit
import XCTest

@testable import MacVisio

final class DocumentDiagnosticIntegrationTests: XCTestCase {
    func testGeometryProducerPreservesDistinctShapeAndAuthoredCellProvenance() throws {
        var model = Diagram()
        model.page.nodes = [DiagramNode(), DiagramNode()]
        for index in model.page.nodes.indices {
            model.page.nodes[index].formatting.sheet["User.Bad"] = ShapeSheetCell(
                value: "7", formula: "UnsupportedFunction()")
            model.page.nodes[index].formatting.sheet["User.Other"] = ShapeSheetCell(
                value: "8", formula: "UnsupportedFunction()")
        }
        let binding = VisioPageBinding(
            pageID: model.page.id, visioID: "4", part: "visio/pages/page7.xml", original: model.page,
            nodeIDs: [model.page.nodes[0].id: "17", model.page.nodes[1].id: "18"], edgeIDs: [:])
        model.visioArchive = VisioDocumentArchive(
            parts: [:], pagesPart: "visio/pages/pages.xml", pages: [binding])
        let result = ShapeSheetEngine.recalculate(model)
        let records = try XCTUnwrap(result.diagnosticsByPage[model.page.id])
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(Set(records.map(\.id)).count, 4)
        XCTAssertEqual(Set(records.compactMap { $0.source.cell }), ["User.Bad", "User.Other"])
        XCTAssertEqual(Set(records.compactMap { $0.source.visioID }), ["17", "18"])
        XCTAssertTrue(
            records.allSatisfy {
                $0.source.part == binding.part && $0.displayState == .cached && $0.inputKey == nil
            })
        XCTAssertEqual(Set(records.map(\.message)), Set(result.issues))
    }

    func testFieldProducerDistinguishesValueAndFormatFailureAndKeepsCachedText() throws {
        var value = DiagramNode(text: "Cached value")
        var format = DiagramNode(text: "Cached format")
        value.formatting.textFields = [
            ShapeTextField(
                index: 2, cells: ["Value": ShapeSheetCell(value: "9", formula: "UnknownFieldFunction()")],
                cached: "Cached value")
        ]
        format.formatting.textFields = [
            ShapeTextField(
                index: 5,
                cells: [
                    "Value": ShapeSheetCell(value: "9"),
                    "Format": ShapeSheetCell(value: "", formula: "UnknownFieldFunction()"),
                ], cached: "Cached format")
        ]
        value.formatting.textRuns = [
            ShapeTextRun(
                text: value.text, character: ShapeCharacterStyle(node: value),
                paragraph: ShapeParagraphStyle(), fieldIndex: 2)
        ]
        format.formatting.textRuns = [
            ShapeTextRun(
                text: format.text, character: ShapeCharacterStyle(node: format),
                paragraph: ShapeParagraphStyle(), fieldIndex: 5)
        ]
        var model = Diagram()
        model.page.nodes = [value, format]
        let result = TextFieldEngine.recalculate(model)
        let records = try XCTUnwrap(result.diagnosticsByPage[model.page.id])
        XCTAssertEqual(Set(records.compactMap { $0.source.cell }), ["Fields.Value[3]", "Fields.Format[6]"])
        XCTAssertTrue(records.allSatisfy { $0.displayState == .cached })
        XCTAssertEqual(result.diagram.page.nodes.map(\.text), ["Cached value", "Cached format"])
        XCTAssertEqual(Set(records.map(\.message)), Set(result.issues))
    }

    func testCommittedKeysRetentionUndoAndStaleDirectAssignmentAreTruthful() throws {
        try onMain {
            let document = MacVisioDocument()
            document.undoManager?.groupsByEvent = false
            defer { document.close() }
            var model = Diagram()
            model.page.nodes = [DiagramNode()]
            model.page.nodes[0].formatting.sheet["User.Bad"] = ShapeSheetCell(
                value: "7", formula: "UnsupportedFunction()")
            model.pages.append(DiagramPage())
            document.diagram = model
            var next = model
            next.pages[0].nodes[0].text = "Discover issue"
            document.replace(with: next, action: "Discover")
            let discovered = try XCTUnwrap(document.currentDiagnostics.first { $0.source.cell == "User.Bad" })
            XCTAssertEqual(discovered.inputKey, document.diagnosticInputKey)
            XCTAssertEqual(discovered.displayState, .cached)
            XCTAssertFalse(document.currentDiagnostics.contains { $0.code == "calculation.anonymous" })
            document.calculationIssues.append("Anonymous additional calculation note")
            let anonymous = try XCTUnwrap(
                document.currentDiagnostics.first { $0.code == "calculation.anonymous" })
            XCTAssertEqual(anonymous.target, .document)
            XCTAssertNil(anonymous.source.cell)
            XCTAssertEqual(anonymous.displayState, .unavailable)
            next = document.diagram
            next.pages[1].name = "Other page edit"
            document.replace(with: next, action: "Other page")
            let retained = try XCTUnwrap(document.currentDiagnostics.first { $0.source.cell == "User.Bad" })
            XCTAssertEqual(retained.id, discovered.id)
            XCTAssertEqual(retained.inputKey, document.diagnosticInputKey)
            XCTAssertNotEqual(retained.inputKey, discovered.inputKey)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.pages[0].nodes[0].text, "Discover issue")
            XCTAssertEqual(document.diagram.pages[1].name, model.pages[1].name)
            let restored = try XCTUnwrap(document.currentDiagnostics.first { $0.source.cell == "User.Bad" })
            XCTAssertEqual(restored.inputKey, document.diagnosticInputKey)
            document.diagram.pages[0].nodes[0].formatting.sheet["User.Bad"]?.formula = "2+3"
            XCTAssertEqual(
                document.currentDiagnostics.first { $0.source.cell == "User.Bad" }?.displayState, .stale)
            next = document.diagram
            next.pages[1].name = "Recalculate after direct assignment"
            document.replace(with: next, action: "Refresh")
            XCTAssertFalse(document.currentDiagnostics.contains { $0.source.cell == "User.Bad" })
        }
    }

    func testSupplementalAdmissionAndPaneArePerDocumentAndAnonymousImportsStayDocumentScoped() throws {
        try onMain {
            _ = NSApplication.shared
            let first = MacVisioDocument()
            let second = MacVisioDocument()
            defer {
                first.close()
                second.close()
            }
            first.importWarnings = ["Anonymous legacy limitation"]
            first.diagram.page.nodes = [DiagramNode()]
            second.diagram = first.diagram
            let issue = DocumentDiagnostic(
                code: "content.label", origin: .content, severity: .warning, dimension: .editing,
                target: .shape(page: first.diagram.page.id, shape: first.diagram.page.nodes[0].id),
                displayState: .evaluated, message: "Label missing")
            XCTAssertTrue(first.setSupplementalDiagnostics([issue], inputKey: first.diagnosticInputKey))
            XCTAssertFalse(second.setSupplementalDiagnostics([issue], inputKey: first.diagnosticInputKey))
            let pane = DocumentIssuesController(document: first)
            defer { pane.close() }
            XCTAssertEqual(pane.records.count, 2)
            XCTAssertEqual(pane.records.first?.target, .document)
            XCTAssertNil(pane.records.first?.source.cell)
            XCTAssertFalse(pane.records.first!.actions.contains(.revealTarget))
            XCTAssertTrue(second.setSupplementalDiagnostics([issue], inputKey: second.diagnosticInputKey))
            pane.reload()
            XCTAssertEqual(pane.records.last?.inputKey, first.diagnosticInputKey)
            XCTAssertNotEqual(pane.records.last?.inputKey, second.currentDiagnostics.last?.inputKey)
        }
    }

    func testNativeRevealUsesDocumentMembershipAndDisplaysTheAuthoredCell() throws {
        try onMain {
            _ = NSApplication.shared
            let first = MacVisioDocument()
            let second = MacVisioDocument()
            defer {
                first.close()
                second.close()
            }
            first.diagram.page.nodes = [DiagramNode()]
            first.diagram.page.nodes[0].formatting.sheet["User.Bad"] = ShapeSheetCell(value: "7")
            second.diagram = first.diagram
            let issue = DocumentDiagnostic(
                code: "fixture.cell", origin: .calculation, severity: .warning,
                dimension: .rendering,
                target: .shape(page: first.diagram.page.id, shape: first.diagram.page.nodes[0].id),
                source: .init(cell: "User.Bad"), displayState: .cached, message: "Fixture issue")
            XCTAssertTrue(first.setSupplementalDiagnostics([issue], inputKey: first.diagnosticInputKey))
            XCTAssertTrue(second.setSupplementalDiagnostics([issue], inputKey: second.diagnosticInputKey))
            first.makeWindowControllers()
            let editor = try XCTUnwrap(first.windowControllers.first as? EditorWindowController)
            let owned = try XCTUnwrap(first.currentDiagnostics.first)
            XCTAssertTrue(editor.navigateDocumentDiagnostic(owned))
            XCTAssertEqual(editor.canvas.selectedNodes, [first.diagram.page.nodes[0].id])
            XCTAssertEqual(editor.root.status.toolTip, "Authored cell: User.Bad")
            XCTAssertFalse(editor.navigateDocumentDiagnostic(try XCTUnwrap(second.currentDiagnostics.first)))
        }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
