import AppKit
import XCTest
@testable import MacVisio

final class M3SharedSheetHostTests: XCTestCase {
    private let measure = DefinitionCellAddress(cell: "Value", section: "User", rowName: "Measure")

    /// Author the document/page references in public source, independently of
    /// the edit path, then reopen through the public reader.
    private func fixture() throws -> Diagram {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "m3-intelligent", withExtension: "vsdx", subdirectory: "Fixtures/M3"))
        var parts = try VisioPackage.read(url)
        let document = try VisioXML.document(XCTUnwrap(parts["visio/document.xml"]))
        let docSheet = try XCTUnwrap(document.rootElement()?.firstLocal("DocumentSheet"))
        let row = XMLElement(name: "Row"); row.setAttr("N","Measure")
        let value = VisioXML.set(row,"Value","2"); value.setAttr("U","IN")
        VisioXML.section(docSheet,"User").addChild(row)
        parts["visio/document.xml"] = document.xmlData(options:.nodePreserveAll)
        let index = try VisioXML.document(XCTUnwrap(parts["visio/pages/pages.xml"]))
        let pageSheet = try XCTUnwrap(index.rootElement()?.elementsLocal("Page").first?.firstLocal("PageSheet"))
        let height = XMLElement(name:"Row"); height.setAttr("N","LocalHeight")
        VisioXML.set(height,"Value","1",formula:"TheDoc!User.Measure/2")
        VisioXML.section(pageSheet,"User").addChild(height)
        parts["visio/pages/pages.xml"] = index.xmlData(options:.nodePreserveAll)
        let page = try VisioXML.document(XCTUnwrap(parts["visio/pages/page1.xml"]))
        let shape = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "10" })
        VisioXML.set(shape,"Width","2",formula:"TheDoc!User.Measure")
        VisioXML.set(shape,"Height","1",formula:"ThePage!User.LocalHeight")
        let connector = try XCTUnwrap(page.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "30" })
        // This fixture isolates shared scalar/property calculation. Attached
        // endpoint/routing formulas retain their separate save-policy coverage.
        for connection in page.rootElement()?.firstLocal("Connects")?.elementsLocal("Connect") ?? [] where connection.attr("FromSheet") == "30" { connection.detach() }
        for element in [shape, connector] {
            let property = XMLElement(name: "Row"); property.setAttr("N", "Measure")
            VisioXML.set(property, "Value", "2", formula: "TheDoc!User.Measure").setAttr("U", "IN")
            VisioXML.set(property, "Type", "2")
            VisioXML.section(element, "Property").addChild(property)
        }
        let field = VisioXML.row(shape,"Field")
        VisioXML.set(field,"Value","2",formula:"Width").setAttr("U","IN")
        VisioXML.set(field,"Format","0.00").setAttr("U","STR")
        VisioXML.set(field,"Type","2")
        shape.firstLocal("Text")?.detach()
        shape.addChild(try VisioXML.element("<Text><fld IX=\"0\">2.00</fld></Text>"))
        parts["visio/pages/page1.xml"] = page.xmlData(options:.nodePreserveAll)
        return try VisioFormat.readPublic(parts:parts,title:"Shared owners").diagram
    }

    private func node(_ diagram: Diagram) throws -> DiagramNode {
        try XCTUnwrap(diagram.pages[0].nodes.first { $0.formatting.sourceShapeID == "10" })
    }

    func testDocumentCellEditUpdatesGeometryPageFormulaAndFieldBeforeSave() throws {
        let before = try fixture()
        let id = try XCTUnwrap(before.definitions?.documentSheet?.id)
        let next = try DefinitionEditing.settingCell(in: before,sheetID:id,address:measure,value:ShapeSheetCell(value:"3",unit:"IN"))
        XCTAssertEqual(try node(next).width,216,accuracy:1e-9)
        XCTAssertEqual(try node(next).height,108,accuracy:1e-9)
        XCTAssertEqual(try node(next).text,"3.00")
        XCTAssertEqual(try node(next).formatting.textRuns?.compactMap(\.fieldToken), try node(before).formatting.textRuns?.compactMap(\.fieldToken))
        XCTAssertEqual(next.visioArchive,before.visioArchive,"Unsaved definitions remain separate from the successful-save baseline")
        let evaluated = DiagramCalculation.recalculate(next,previous:before)
        XCTAssertEqual(try node(evaluated.diagram).width,216,accuracy:1e-9)
        XCTAssertEqual(try node(evaluated.diagram).text,"3.00")
        XCTAssertFalse(evaluated.issues.contains { $0.contains("Unknown ShapeSheet reference") })
        let publicParts = try VisioPreservation.prepared(evaluated.diagram).parts
        let reopened = try VisioFormat.readPublic(parts:publicParts,title:"Public only").diagram
        let result = DiagramCalculation.recalculate(reopened).diagram
        XCTAssertEqual(try node(result).width,216,accuracy:1e-9)
        XCTAssertEqual(try node(result).text,"3.00")
        let raw = try VisioXML.document(XCTUnwrap(publicParts["visio/pages/page1.xml"]))
        let shape = try XCTUnwrap(raw.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "10" })
        XCTAssertEqual(shape.elementsLocal("Cell").first { $0.attr("N") == "Width" }?.attr("F"),"TheDoc!User.Measure")
    }

    func testDefinitionOnlyChangeInvalidatesBothCalculatorsWithoutChangingSourceBytes() throws {
        let source = try fixture()
        let before = DiagramCalculation.recalculate(source).diagram
        var next = before
        next.definitions?.documentSheet?.set(measure,to:ShapeSheetCell(value:"4",unit:"IN"))
        let changes = DocumentChangeSet.between(before,next)
        XCTAssertTrue(changes.definitionsChanged)
        XCTAssertTrue(changes.pages.isEmpty)
        let result = DiagramCalculation.recalculate(next,previous:before,changes:changes)
        XCTAssertEqual(try node(result.diagram).width,288,accuracy:1e-9)
        XCTAssertEqual(try node(result.diagram).height,144,accuracy:1e-9)
        XCTAssertEqual(try node(result.diagram).text,"4.00")
        XCTAssertEqual(result.diagram.visioArchive,source.visioArchive)
        let unchanged = DiagramCalculation.recalculate(result.diagram,previous:result.diagram)
        XCTAssertEqual(unchanged.work.geometryNodes,0)
        XCTAssertEqual(unchanged.work.fieldNodes,0)
    }

    func testTheDocReferenceDoesNotMakeUnrelatedWarmEditsConservative() throws {
        var drawing = Diagram(), node = DiagramNode()
        drawing.definitions = try fixture().definitions
        node.formatting.sheet["Width"] = ShapeSheetCell(value: "2", formula: "TheDoc!User.Measure")
        drawing.page.nodes = [node]
        for _ in 0..<1000 {
            var other = DiagramNode()
            other.formatting.sheet["User.Local"] = ShapeSheetCell(value: "1", formula: "1+0")
            drawing.page.nodes.append(other)
        }
        let session = CalculationSession(), settled = DiagramCalculation.recalculate(drawing, session: session)
        var next = settled.diagram; next.page.nodes[1000].text = "Unrelated edit"
        let result = DiagramCalculation.recalculate(next, previous: settled.diagram,
            previousGeometryIssuesByPage: settled.geometryIssuesByPage,
            previousFieldIssuesByPage: settled.fieldIssuesByPage, session: session,
            changes: DocumentChangeSet.between(settled.diagram, next))
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertLessThan(result.work.geometryNodes, 4)
        XCTAssertLessThan(result.work.dependencySourcesCompared, 5)
        XCTAssertEqual(result.work.conservativePages, 0)
        XCTAssertEqual(result.diagram.page.nodes[0].width, 144, accuracy: 1e-8)
    }

    func testPageFormulaUsesItsOwnRelativeCellsInGeometryAndFields() throws {
        var drawing = Diagram(); var shape = DiagramNode(text:"")
        drawing.page.sheet = ["User.Base":ShapeSheetCell(value:"3"),"User.Double":ShapeSheetCell(value:"6",formula:"User.Base*2")]
        shape.formatting.sheet["User.Base"] = ShapeSheetCell(value:"99")
        shape.formatting.sheet["Width"] = ShapeSheetCell(value:"6",formula:"ThePage!User.Double")
        shape = try TextFieldEngine.inserting(formula:"ThePage!User.Double",into:shape)
        drawing.page.nodes = [shape]
        let result = DiagramCalculation.recalculate(drawing)
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
        XCTAssertEqual(result.diagram.page.nodes[0].width,432,accuracy:1e-9)
        XCTAssertEqual(result.diagram.page.nodes[0].text,"6")
    }

    func testMasterShapeReferencesStayInTheirDefinitionScope() throws {
        var drawing = try fixture()
        let first = try XCTUnwrap(drawing.definitions?.masters[0].sheets[0].id)
        let second = try XCTUnwrap(drawing.definitions?.masters[1].sheets[0].id)
        drawing.definitions?.masters[1].sheets[0].set(DefinitionCellAddress(cell:"Width"),to:ShapeSheetCell(value:"5"))
        let context = ShapeSheetContext(page:drawing.pages[1],document:drawing)
        XCTAssertEqual(try context.value(first,"Sheet.1!Width").numeric(),2,accuracy:1e-9)
        XCTAssertEqual(try context.value(second,"Sheet.1!Width").numeric(),5,accuracy:1e-9)
    }

    func testCrossOwnerCycleKeepsFieldCacheAndProducesTypedFailure() throws {
        var drawing = try fixture()
        drawing.definitions?.documentSheet?.set(measure,to:ShapeSheetCell(value:"2",formula:"TheDoc!User.Measure",unit:"IN"))
        let result = DiagramCalculation.recalculate(drawing)
        XCTAssertEqual(try node(result.diagram).text,"2.00")
        XCTAssertFalse(result.issues.isEmpty)
        XCTAssertTrue(result.fieldDiagnosticsByPage.values.flatMap { $0 }.contains { $0.code == "calculation.field.cell" && $0.source.cell == "Fields.Value[1]" })
        let definition = try XCTUnwrap(result.fieldDiagnosticsByPage.values.flatMap { $0 }.first { $0.code == "calculation.definition.cell" })
        XCTAssertEqual(definition.target, .definition(sheet: try XCTUnwrap(drawing.definitions?.documentSheet?.id)))
        XCTAssertEqual(definition.source.definitionCell, measure)
        XCTAssertEqual(definition.source.part, drawing.definitions?.documentPart)
        XCTAssertTrue(definition.actions.contains(.inspectCell))
    }

    func testSharedFieldFunctionsRetainInjectedClockUnitsAndForegroundPageContext() throws {
        var drawing = Diagram(); drawing.page.name = "Foreground"
        var background = DiagramPage(name:"Background"); background.isBackground = true
        var foreground = drawing.page
        foreground.sheet = ["User.Base":ShapeSheetCell(value:"3"),"User.Double":ShapeSheetCell(value:"6",formula:"User.Base*2")]
        drawing.pages[0] = foreground
        var shape = DiagramNode(text:"")
        shape = try TextFieldEngine.inserting(formula:"PAGENAME() & \"/\" & ThePage!User.Double & \"/\" & FORMAT(NOW(),\"yyyy-MM-dd\")",into:shape)
        background.nodes = [shape]; drawing.pages.append(background)
        let now = try XCTUnwrap(FieldFormatting.date("2026-10-19"))
        let result = TextFieldEngine.recalculate(drawing,now:now,foreground:foreground)
        XCTAssertEqual(result.diagram.pages[1].nodes[0].text,"Foreground/6/2026-10-19")
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:"; "))
    }

    func testNativeDocumentCellWorkerUndoRedoAndSaveKeepDependentFormulas() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); defer { document.close() }
            document.diagram = try fixture()
            document.undoManager?.groupsByEvent = false
            let before = document.diagram, id = try XCTUnwrap(before.definitions?.documentSheet?.id)
            document.editDefinitionCell(sheetID: id, address: measure, value: ShapeSheetCell(value: "3", unit: "IN"))
            XCTAssertTrue(document.isCalculating)
            let deadline = Date().addingTimeInterval(15)
            while document.isCalculating && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
            XCTAssertFalse(document.isCalculating)
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(try node(document.diagram).width, 216, accuracy: 1e-9)
            XCTAssertEqual(try node(document.diagram).height, 108, accuracy: 1e-9)
            XCTAssertEqual(try node(document.diagram).text, "3.00")
            XCTAssertEqual(try node(document.diagram).formatting.sheet["Prop.Measure"]?.formula, "TheDoc!User.Measure")
            XCTAssertEqual(try node(document.diagram).formatting.data.first { $0.key == "Measure" }?.value, "3")
            XCTAssertEqual(document.diagram.pages[0].edges[0].formatting.sheet["Prop.Measure"]?.formula, "TheDoc!User.Measure")
            XCTAssertEqual(document.diagram.pages[0].edges[0].formatting.sheet["Prop.Measure"]?.unit, "IN")
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("M3-shared-\(UUID()).vsdx")
            defer { try? FileManager.default.removeItem(at: out) }
            try save(document, to: out, operation: .saveAsOperation)
            let firstPublic = try VisioFormat.readPublic(parts: VisioPackage.read(out), title: "Edited").diagram
            XCTAssertEqual(try node(firstPublic).text, "3.00")
            XCTAssertEqual(try node(firstPublic).width, 216, accuracy: 1e-9)
            XCTAssertEqual(firstPublic.pages[0].edges[0].formatting.data.first { $0.key == "Measure" }?.value, "3")
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.definitions?.documentSheet?.cell(measure)?.value, "2")
            XCTAssertEqual(try node(document.diagram).width, 144, accuracy: 1e-9)
            XCTAssertEqual(try node(document.diagram).text, "2.00")
            try save(document, to: out)
            XCTAssertEqual(try node(VisioFormat.readPublic(parts: VisioPackage.read(out), title: "Undo").diagram).text, "2.00")
            let savedPage = try VisioXML.document(XCTUnwrap(VisioPackage.read(out)["visio/pages/page1.xml"]))
            let sibling = try XCTUnwrap(savedPage.rootElement()?.firstLocal("Shapes")?.allShapes.first { $0.attr("ID") == "20" })
            XCTAssertNil(sibling.elementsLocal("Cell").first { $0.attr("N") == "LocPinX" }, "Refreshing an inherited cache must not create a local formula")
            XCTAssertNil(sibling.elementsLocal("Section").first { $0.attr("N") == "User" }, "Inherited User rows remain in the master")
            document.undoManager?.redo()
            XCTAssertEqual(try node(document.diagram).width, 216, accuracy: 1e-9)
            try save(document, to: out)
            let reopened = try VisioFormat.readPublic(parts: VisioPackage.read(out), title: "Redo").diagram
            XCTAssertEqual(try node(reopened).text, "3.00")
            XCTAssertEqual(try node(reopened).formatting.sheet["Width"]?.formula, "TheDoc!User.Measure")
            XCTAssertEqual(reopened.definitions?.documentSheet?.cell(measure)?.value, "3")
            XCTAssertEqual(try node(reopened).formatting.sheet["Prop.Measure"]?.formula, "TheDoc!User.Measure")
            XCTAssertEqual(reopened.pages[0].edges[0].formatting.sheet["Prop.Measure"]?.formula, "TheDoc!User.Measure")
            XCTAssertEqual(reopened.pages[0].edges[0].formatting.sheet["Prop.Measure"]?.unit, "IN")
        }
    }

    func testNativeDefinitionFailureNavigatesProducerAddressAndDeduplicatesConsumers() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); defer { document.close() }
            document.diagram = try fixture()
            var next = document.diagram
            next.definitions?.documentSheet?.set(measure, to: ShapeSheetCell(value: "2", formula: "TheDoc!User.Measure", unit: "IN"))
            document.replace(with: next, action: "Cyclic document cell")
            let records = document.currentDiagnostics.filter { $0.code == "calculation.definition.cell" }
            XCTAssertEqual(records.count, 1, "One definition error can be reached by geometry and field consumers")
            let issue = try XCTUnwrap(records.first)
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            defer { editor.definitionSheetController.close() }
            XCTAssertTrue(editor.navigateDocumentDiagnostic(issue))
            XCTAssertEqual(editor.definitionSheetController.selectedAddress, measure)
            XCTAssertEqual(editor.definitionSheetController.selectedSheetID, document.diagram.definitions?.documentSheet?.id)
        }
    }

    func testDirectTypedPropertyEditsReplaceFormulasWhileKeepingUnits() throws {
        let before = DiagramCalculation.recalculate(try fixture()).diagram
        var next = before
        let index = try XCTUnwrap(next.pages[0].nodes.firstIndex { $0.formatting.sourceShapeID == "10" })
        let property = try XCTUnwrap(next.pages[0].nodes[index].formatting.data.firstIndex { $0.key == "Measure" })
        next.pages[0].nodes[index].formatting.data[property].value = "7"
        let edgeProperty = try XCTUnwrap(next.pages[0].edges[0].formatting.data.firstIndex { $0.key == "Measure" })
        next.pages[0].edges[0].formatting.data[edgeProperty].value = "8"
        let result = DiagramCalculation.recalculate(next, previous: before)
        XCTAssertEqual(result.diagram.pages[0].nodes[index].formatting.sheet["Prop.Measure"], ShapeSheetCell(value: "7", unit: "IN"))
        XCTAssertEqual(result.diagram.pages[0].edges[0].formatting.sheet["Prop.Measure"], ShapeSheetCell(value: "8", unit: "IN"))
    }

    private func save(_ document: MacVisioDocument, to url: URL,
                      operation: NSDocument.SaveOperationType = .saveOperation) throws {
        var complete = false, failure: Error?
        document.save(to: url, ofType: MacVisioDocument.visioType, for: operation) { failure = $0; complete = true }
        let deadline = Date().addingTimeInterval(20)
        while !complete && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(complete)
        if !complete { throw DiagramError.invalid("Shared owner save timed out") }
        if let failure { throw failure }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
