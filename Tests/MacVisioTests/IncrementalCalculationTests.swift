import MacVisioInfrastructure
import AppKit
import XCTest
@testable import MacVisio

final class IncrementalCalculationTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    private func formulaNode(_ id: String, formula: String = "2+User.Padding") -> DiagramNode {
        var node = DiagramNode(x: 100, y: 100, text: "")
        node.formatting.sourceShapeID = id
        node.formatting.sheet["User.Padding"] = ShapeSheetCell(value: "0")
        node.formatting.sheet["Width"] = ShapeSheetCell(value: "2", formula: formula)
        return node
    }

    private func fixture(nodeCount: Int = 40) -> Diagram {
        var diagram = Diagram()
        diagram.pages = (0..<3).map { index in
            var page = DiagramPage(name: "Page \(index + 1)")
            page.nodes = (1...nodeCount).map { formulaNode(String($0)) }
            page.nodes[1].formatting.sheet["Height"] = ShapeSheetCell(value: "1", formula: "Sheet.1!Width/2")
            var field = DiagramNode(text: "")
            field.formatting.sourceShapeID = String(nodeCount + 1000)
            field = try! TextFieldEngine.inserting(formula: "Sheet.1!Width", into: field)
            page.nodes.append(field)
            return page
        }
        diagram.activePageID = diagram.pages[0].id
        return diagram
    }

    private func full(_ input: Diagram, previous: Diagram? = nil) -> DiagramCalculation.Result {
        var next = input
        var issues = Set<String>()
        for pass in 0..<8 {
            let geometry = ShapeSheetEngine.recalculate(next, previous: pass == 0 ? previous : nil)
            let fields = TextFieldEngine.recalculate(geometry.diagram, now: clock)
            issues = Set(geometry.issues + fields.issues)
            if fields.diagram == next {
                return DiagramCalculation.Result(diagram: fields.diagram, issues: issues.sorted(), geometryIssuesByPage: geometry.issuesByPage, fieldIssuesByPage: fields.issuesByPage)
            }
            next = fields.diagram
        }
        issues.insert("Text and geometry dependencies did not settle within eight calculation passes; inspect the formulas for a circular dependency.")
        return DiagramCalculation.Result(diagram: next, issues: issues.sorted())
    }

    private func incremental(_ input: Diagram, previous: DiagramCalculation.Result, session: CalculationSession = CalculationSession()) -> DiagramCalculation.Result {
        DiagramCalculation.recalculate(input, previous: previous.diagram, previousIssues: previous.issues,
            previousGeometryIssuesByPage: previous.geometryIssuesByPage, previousFieldIssuesByPage: previous.fieldIssuesByPage,
            session: session, changes: DocumentChangeSet.between(previous.diagram, input), now: clock)
    }

    func testChangedCellEvaluatesOnlyDependentGeometryAndFields() {
        _ = NSApplication.shared
        let settled = full(fixture())
        XCTAssertTrue(settled.issues.isEmpty, settled.issues.joined(separator: "\n"))
        var edited = settled.diagram
        edited.pages[0].nodes[0].formatting.sheet["User.Padding"]?.value = "1"
        let result = incremental(edited, previous: settled)
        let baseline = full(edited, previous: settled.diagram)
        XCTAssertEqual(result.diagram, baseline.diagram)
        XCTAssertEqual(result.issues, baseline.issues)
        XCTAssertLessThanOrEqual(result.work.geometryNodes, 4)
        XCTAssertLessThanOrEqual(result.work.fieldNodes, 2)
        XCTAssertLessThanOrEqual(result.work.geometryPages, 2)
        XCTAssertGreaterThan(result.work.formulaEvaluations, 0)
        XCTAssertGreaterThan(result.work.evaluatedCells, 0)
        XCTAssertEqual(result.work.textMeasurements, 0)
    }

    func testPlainInsertionDoesNotEvaluateUnrelatedCellsOrFields() {
        let settled = full(fixture())
        var edited = settled.diagram
        edited.pages[0].nodes.append(DiagramNode(text: "Inserted"))
        let result = incremental(edited, previous: settled)
        XCTAssertEqual(result.diagram, full(edited, previous: settled.diagram).diagram)
        XCTAssertEqual(result.work.geometryNodes, 0)
        XCTAssertEqual(result.work.fieldNodes, 0)
        XCTAssertEqual(result.work.formulaEvaluations, 0)
        XCTAssertEqual(result.work.contexts, 0)
    }

    func testRetainedSessionReusesDependencyIndexButNeverCrossPageValues() throws {
        let input = fixture(), session = CalculationSession()
        let settled = DiagramCalculation.recalculate(input, session: session, now: clock)
        XCTAssertEqual(settled.diagram, full(input).diagram)
        var edit = settled.diagram
        edit.pages[0].nodes[0].formatting.sheet["User.Padding"]?.value = "1"
        let first = incremental(edit, previous: settled, session: session)
        edit = first.diagram
        edit.pages[1].nodes[0].formatting.sheet["User.Padding"]?.value = "2"
        let second = incremental(edit, previous: first, session: session)
        XCTAssertEqual(second.diagram, full(edit, previous: first.diagram).diagram)
        XCTAssertEqual(second.work.dependencyNodesIndexed, 0)
        XCTAssertEqual(second.work.inputComparisonNodes, 0)
        XCTAssertLessThan(second.work.dependencySourcesCompared, 20)
        XCTAssertLessThan(second.work.hostNodesPrepared, 20)
        XCTAssertEqual(second.diagram.pages[0].nodes[0].width, 216, accuracy: 1e-9)
        XCTAssertEqual(second.diagram.pages[1].nodes[0].width, 288, accuracy: 1e-9)
        let a = ShapeSheetContext(page: second.diagram.pages[0]), b = ShapeSheetContext(page: second.diagram.pages[1])
        XCTAssertEqual(try a.evaluate("Width*2", on: second.diagram.pages[0].nodes[0].id).numeric(), 6)
        XCTAssertEqual(try b.evaluate("Width*2", on: second.diagram.pages[1].nodes[0].id).numeric(), 8)
    }

    func testUnsupportedAndCircularDiagnosticsMatchFullAndRetainSourceCaches() {
        var input = fixture()
        input.pages[1].nodes[0].formatting.sheet["User.Bad"] = ShapeSheetCell(value: "retained", formula: "UnsupportedFunction()")
        input.pages[0].nodes[4].formatting.sheet["User.A"] = ShapeSheetCell(value: "7", formula: "User.B")
        input.pages[0].nodes[4].formatting.sheet["User.B"] = ShapeSheetCell(value: "8", formula: "User.A")
        let settled = full(input)
        XCTAssertFalse(settled.issues.isEmpty)
        var edited = settled.diagram
        edited.pages[0].nodes[0].formatting.sheet["User.Padding"]?.value = "1"
        edited.pages[1].nodes[1].text = "Changed"
        let result = incremental(edited, previous: settled), baseline = full(edited, previous: settled.diagram)
        XCTAssertEqual(result.diagram, baseline.diagram)
        XCTAssertEqual(result.issues, baseline.issues)
        XCTAssertGreaterThan(result.work.conservativePages, 0)
        XCTAssertEqual(result.diagram.pages[1].nodes[0].formatting.sheet["User.Bad"]?.value, "retained")
        XCTAssertEqual(result.diagram.pages[0].nodes[4].formatting.sheet["User.A"]?.value, "7")
    }

    func testPageMetadataAndOrdinalReorderingUseConservativePath() {
        let settled = full(fixture())
        var edited = settled.diagram
        edited.pages[0].width += 72
        edited.pages[1].nodes.swapAt(0, 1)
        let result = incremental(edited, previous: settled)
        XCTAssertEqual(result.diagram, full(edited, previous: settled.diagram).diagram)
        XCTAssertGreaterThanOrEqual(result.work.conservativePages, 2)
    }

    func testVolatileFieldUsesOneRequestClockAndUpdatesOnNextRequest() throws {
        var input = Diagram(), node = DiagramNode(text: "")
        let picture = "yyyy-MM-dd HH:mm:ss"
        node = try TextFieldEngine.inserting(formula: "NOW()", picture: picture, type: 5, into: node)
        input.page.nodes = [node]
        let first = DiagramCalculation.recalculate(input, now: clock)
        XCTAssertTrue(first.issues.isEmpty, first.issues.joined(separator: "\n"))
        let later = clock.addingTimeInterval(60)
        let second = DiagramCalculation.recalculate(first.diagram, previous: first.diagram,
            previousGeometryIssuesByPage: first.geometryIssuesByPage, previousFieldIssuesByPage: first.fieldIssuesByPage, now: later)
        XCTAssertEqual(second.diagram.page.nodes[0].formatting.textFields?[0].cells["Value"]?.value, ISO8601DateFormatter().string(from: later))
        XCTAssertEqual(second.diagram.page.nodes[0].formatting.textFields?[0].cached, try FieldFormatting.format(.date(later), picture: picture, type: 5))
        XCTAssertGreaterThan(second.work.fieldNodes, 0)
        XCTAssertTrue(second.issues.isEmpty, second.issues.joined(separator: "\n"))
    }

    func testTextMeasurementDependencyAndGroupParentMatchFullEvaluation() {
        _ = NSApplication.shared
        var input = fixture()
        input.pages[0].nodes[0].text = "Small label"
        input.pages[0].nodes[2].formatting.sheet["Width"] = ShapeSheetCell(value: "2", formula: "TEXTWIDTH(Sheet.1!TheText)+0.25")
        input.pages[0].nodes[3].formatting.isGroup = true
        input.pages[0].nodes[4].parentID = input.pages[0].nodes[3].id
        input.pages[0].nodes[4].formatting.sheet["Height"] = ShapeSheetCell(value: "1", formula: "ParentShape!Width/2")
        let settled = full(input)
        XCTAssertTrue(settled.issues.isEmpty, settled.issues.joined(separator: "\n"))
        var edited = settled.diagram
        edited.pages[0].nodes[0].text = "A considerably longer label that changes the dependent width"
        edited.pages[0].nodes[3].formatting.sheet["User.Padding"]?.value = "1"
        let result = incremental(edited, previous: settled), baseline = full(edited, previous: settled.diagram)
        XCTAssertEqual(result.diagram, baseline.diagram)
        XCTAssertEqual(result.issues, baseline.issues)
        XCTAssertGreaterThan(result.work.textMeasurements, 0)
        XCTAssertLessThan(result.work.geometryNodes, 20)
    }

    func testFieldDiagnosticsRetainOnUnchangedPageAndClearWhenFixed() throws {
        var input = fixture()
        input.pages[1].nodes[40] = try TextFieldEngine.inserting(formula: "UnsupportedField()", into: DiagramNode(text: "Cached"))
        let settled = full(input)
        XCTAssertFalse(settled.fieldIssuesByPage[input.pages[1].id, default: []].isEmpty)
        var edited = settled.diagram
        edited.pages[0].nodes[0].formatting.sheet["User.Padding"]?.value = "1"
        let result = incremental(edited, previous: settled), baseline = full(edited, previous: settled.diagram)
        XCTAssertEqual(result.diagram, baseline.diagram)
        XCTAssertEqual(result.issues, baseline.issues)
        XCTAssertEqual(result.fieldIssuesByPage[input.pages[1].id], settled.fieldIssuesByPage[input.pages[1].id])
        edited = result.diagram
        edited.pages[1].nodes[40].formatting.textFields?[0].cells["Value"]?.formula = "1+2"
        let fixed = incremental(edited, previous: result)
        XCTAssertEqual(fixed.diagram, full(edited, previous: result.diagram).diagram)
        XCTAssertTrue(fixed.fieldIssuesByPage[input.pages[1].id, default: []].isEmpty)
    }

    func testPureWorkerCalculationMatchesMainAndRejectsStaleInput() {
        let diagram = fixture(), expected = full(diagram), now = clock
        let identity = LifecycleJobInput(ownerID: UUID(), snapshotID: UUID(), revision: 3)
        let finished = expectation(description: "Pure calculation worker")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
                let output = try CalculationJobs.evaluate(diagram, input: identity, now: now, cancellation: LifecycleJobCancellation())
                XCTAssertEqual(try output.accepted(ifCurrent: identity).diagram, expected.diagram)
                XCTAssertEqual(try output.accepted(ifCurrent: identity).issues, expected.issues)
                let staleInputs = [
                    LifecycleJobInput(ownerID: UUID(), snapshotID: identity.snapshotID, revision: identity.revision),
                    LifecycleJobInput(ownerID: identity.ownerID, snapshotID: UUID(), revision: identity.revision),
                    LifecycleJobInput(ownerID: identity.ownerID, snapshotID: identity.snapshotID, revision: identity.revision + 1)
                ]
                for stale in staleInputs { XCTAssertThrowsError(try output.accepted(ifCurrent: stale)) }
            } catch { XCTFail("Pure worker failed: \(error)") }
        }
        wait(for: [finished], timeout: 10)
    }

    func testTextMeasurementWorkerUsesMainServiceAndCancellationReturnsNoResult() {
        _ = NSApplication.shared
        var diagram = fixture()
        diagram.pages[0].nodes[0].text = "Measure this label on the AppKit owner"
        diagram.pages[0].nodes[0].formatting.sheet["Width"]?.formula = "TEXTWIDTH(TheText)+0.25"
        XCTAssertEqual(CalculationExecutionPolicy.inspect(diagram), .mainThreadTextMeasurement)
        let expected = full(diagram), before = ShapeTextMeasurementService.statistics
        let identity = LifecycleJobInput(ownerID: UUID(), snapshotID: UUID(), revision: 3), immutable = diagram, now = clock
        let finished = expectation(description: "Text measurement worker"), heartbeat = expectation(description: "Main queue continues servicing events")
        DispatchQueue.main.async { heartbeat.fulfill() }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
                let output = try CalculationJobs.evaluate(immutable, input: identity, now: now, cancellation: LifecycleJobCancellation())
                let value = try output.accepted(ifCurrent: identity)
                XCTAssertEqual(value.diagram, expected.diagram)
                XCTAssertEqual(value.issues, expected.issues)
                XCTAssertGreaterThan(value.work.textMeasurements, 0)
            } catch { XCTFail("Text worker failed: \(error)") }
        }
        wait(for: [heartbeat, finished], timeout: 15)
        let after = ShapeTextMeasurementService.statistics
        XCTAssertGreaterThan(after.mainThreadRecords, before.mainThreadRecords)
        XCTAssertEqual(after.offMainThreadRecords, 0)
        print("WP07 text measurement records=\(after.mainThreadRecords - before.mainThreadRecords) maximumRecordSeconds=\(after.maximumRecordSeconds)")
        let cancellation = LifecycleJobCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(try CalculationJobs.evaluate(diagram, input: identity, cancellation: cancellation)) { error in
            XCTAssertEqual(error as? LifecycleJobError, .cancelled)
        }
        XCTAssertNil(DiagramCalculation.calculate(diagram, cancellation: cancellation))
    }

    func testCancellationDuringMainMeasurementDiscardsItsValue() {
        let cancellation = LifecycleJobCancellation(), finished = expectation(description: "Cancel active measurement")
        let before = ShapeTextMeasurementService.statistics
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
                let value: Int = try ShapeTextMeasurementService.perform(cancellation: cancellation) {
                    XCTAssertTrue(Thread.isMainThread)
                    cancellation.cancel()
                    return 123
                }
                XCTFail("Cancelled measurement published \(value)")
            } catch { XCTAssertEqual(error as? LifecycleJobError, .cancelled) }
        }
        wait(for: [finished], timeout: 10)
        let after = ShapeTextMeasurementService.statistics
        XCTAssertEqual(after.mainThreadRecords - before.mainThreadRecords, 1)
        XCTAssertEqual(after.offMainThreadRecords, 0)
    }

    func testKnownCommittedBaselineAndSelectedRichTextAvoidEvaluationAndBroadVisits() {
        _ = NSApplication.shared
        let session = CalculationSession(), settled = DiagramCalculation.recalculate(fixture(), session: session, now: clock)
        let baseline = ControlEditing.prepare(settled.diagram, geometryIssuesByPage: settled.geometryIssuesByPage, session: session)
        XCTAssertEqual(baseline.work, CalculationWork())
        var edited = settled.diagram
        edited.pages[0].nodes[0].fontSize = 18
        edited.pages[0].nodes[0].formatting.textRuns = [ShapeTextRun(text: "", character: ShapeCharacterStyle(node: settled.diagram.pages[0].nodes[0]), paragraph: ShapeParagraphStyle())]
        var before = settled.diagram
        before.pages[0].nodes[0].formatting.textRuns = edited.pages[0].nodes[0].formatting.textRuns
        let changes = DocumentChangeSet.between(before, edited)
        var visits = 0
        let selected = ShapeRichText.synchronize(edited, previous: before, changes: changes, session: session, onNodeVisits: { visits += $0 })
        XCTAssertEqual(selected, ShapeRichText.synchronize(edited, previous: before))
        XCTAssertEqual(visits, 1)
    }

    func testPublicSourceIdentityChangeInvalidatesRetainedReferences() {
        let session = CalculationSession()
        let settled = DiagramCalculation.recalculate(fixture(), session: session, now: clock)
        var edited = settled.diagram
        edited.pages[0].nodes[0].formatting.sourceShapeID = "500"
        let result = incremental(edited, previous: settled, session: session), baseline = full(edited, previous: settled.diagram)
        XCTAssertEqual(result.diagram, baseline.diagram)
        XCTAssertEqual(result.issues, baseline.issues)
        XCTAssertFalse(result.issues.isEmpty)
    }

    func testDependenciesIncludeInactiveBranchesBeforeConditionChanges() {
        var input = fixture()
        input.pages[0].nodes[1].formatting.sheet["Height"]?.formula = "IF(Sheet.1!User.Padding>1,Sheet.3!Width,Sheet.4!Width)"
        let settled = full(input)
        var edited = settled.diagram
        edited.pages[0].nodes[3].formatting.sheet["User.Padding"]?.value = "2"
        let first = incremental(edited, previous: settled)
        XCTAssertEqual(first.diagram, full(edited, previous: settled.diagram).diagram)
        edited = first.diagram
        edited.pages[0].nodes[0].formatting.sheet["User.Padding"]?.value = "2"
        edited.pages[0].nodes[2].formatting.sheet["User.Padding"]?.value = "3"
        let second = incremental(edited, previous: first)
        XCTAssertEqual(second.diagram, full(edited, previous: first.diagram).diagram)
    }

    func testWarmEditWorkIsIndependentOfUnrelatedNodeCount() {
        var records: [CalculationWork] = []
        for count in [40, 4000] {
            let session = CalculationSession()
            let settled = DiagramCalculation.recalculate(fixture(nodeCount: count), session: session, now: clock)
            XCTAssertTrue(settled.issues.isEmpty)
            var edited = settled.diagram
            edited.pages[0].nodes[0].formatting.sheet["User.Padding"]?.value = "1"
            let result = incremental(edited, previous: settled, session: session)
            records.append(result.work)
            XCTAssertEqual(result.work.inputComparisonNodes, 0)
            XCTAssertLessThan(result.work.dependencySourcesCompared, 20)
            XCTAssertLessThan(result.work.hostNodesPrepared, 20)
            XCTAssertLessThanOrEqual(result.work.geometryNodes, 4)
            XCTAssertLessThanOrEqual(result.work.fieldNodes, 2)
            print("WP07 warm nodesPerPage=\(count) geometryNodes=\(result.work.geometryNodes) fieldNodes=\(result.work.fieldNodes) evaluatedCells=\(result.work.evaluatedCells) formulaEvaluations=\(result.work.formulaEvaluations) inputComparisonNodes=\(result.work.inputComparisonNodes) dependencySourcesCompared=\(result.work.dependencySourcesCompared) hostNodesPrepared=\(result.work.hostNodesPrepared)")
        }
        XCTAssertEqual(records[0].geometryNodes, records[1].geometryNodes)
        XCTAssertEqual(records[0].fieldNodes, records[1].fieldNodes)
        XCTAssertEqual(records[0].evaluatedCells, records[1].evaluatedCells)
        XCTAssertEqual(records[0].formulaEvaluations, records[1].formulaEvaluations)
        XCTAssertEqual(records[0].dependencySourcesCompared, records[1].dependencySourcesCompared)
        XCTAssertEqual(records[0].hostNodesPrepared, records[1].hostNodesPrepared)
    }

    func testFieldIdentifierAllocationPreservesDuplicateAndInvalidSourceBehavior() throws {
        var diagram = Diagram(), first = DiagramNode(text: ""), duplicate = DiagramNode(text: "")
        first.formatting.sourceShapeID = "2"
        duplicate.formatting.sourceShapeID = "2"
        let field = try TextFieldEngine.inserting(formula: "ID()", into: DiagramNode(text: ""))
        diagram.page.nodes = [first, duplicate, field]
        let allocated = TextFieldEngine.recalculate(diagram)
        XCTAssertTrue(allocated.issues.isEmpty)
        XCTAssertEqual(allocated.diagram.page.nodes[2].text, "3")
        diagram.page.nodes[0].formatting.sourceShapeID = "invalid"
        let unavailable = TextFieldEngine.recalculate(diagram)
        XCTAssertFalse(unavailable.issues.isEmpty)
        XCTAssertEqual(unavailable.diagram.page.nodes[2].text, field.text)
        XCTAssertTrue(unavailable.issues.contains { $0.contains("Invalid shape ID") })
    }

    func testDefaultPinFormulaAttemptsAreMeasuredSeparately() {
        var input = fixture()
        input.pages[0].nodes[0].formatting.sheet["LocPinX"] = ShapeSheetCell(value: "1", formula: "Width/2")
        input.pages[0].nodes[0].formatting.sheet["LocPinY"] = ShapeSheetCell(value: "0.5", formula: "Height/2")
        let result = DiagramCalculation.recalculate(input, now: clock)
        XCTAssertEqual(result.diagram, full(input).diagram)
        XCTAssertGreaterThan(result.work.defaultPinFormulaEvaluations, 0)
        XCTAssertGreaterThan(result.work.formulaEvaluations, 0)
    }

    func testCompiledSyntaxCacheIsBoundedAndParserLimitIsPartOfIdentity() throws {
        let cache = ShapeSheetExpressionCache(maximumEntries: 2, maximumSourceBytes: 12)
        var compiled = 0
        func lookup(_ source: String, limit: Int = 16) throws {
            _ = try cache.expression(source, characterLimit: limit) { compiled += 1; return .reference(source) }
        }
        try lookup("Width"); try lookup("Width")
        XCTAssertEqual(compiled, 1)
        try lookup("Width", limit: 32)
        XCTAssertEqual(compiled, 2)
        try lookup("Height")
        XCTAssertLessThanOrEqual(cache.statistics.entries, 2)
        XCTAssertLessThanOrEqual(cache.statistics.sourceBytes, 12)
        try lookup("Width")
        XCTAssertEqual(compiled, 4)
        XCTAssertEqual(cache.statistics.hits, 1)
        // A permissive cached parse cannot bypass a stricter parser limit.
        _ = try ShapeSheet.parse("1+2", characterLimit: 100)
        XCTAssertThrowsError(try ShapeSheet.parse("1+2", characterLimit: 1))
    }

    func testRepeatedControlSolveKeepsRedirectEvaluationOnFrozenBaseline() throws {
        var input = Diagram()
        var node = DiagramNode(x:100,y:100)
        node.formatting.sheet["User.Target"] = ShapeSheetCell(value:"1")
        node.formatting.controls = [ShapeControl(name:"Redirect",index:0,cells:[
            "X":ShapeSheetCell(value:"1",formula:"SETATREF(User.Target,SETATREFEVAL(User.Target+SETATREFEXPR()))"),
            "Y":ShapeSheetCell(value:"0.5"),"YCon":ShapeSheetCell(value:"1")
        ])]
        input.page.nodes = [node]
        let settled = ShapeSheetEngine.recalculate(input).diagram
        let baseline = ControlEditing.prepare(settled)
        let original = settled.page.nodes[0]
        for value in [2.0,3.0,4.0] {
            let point = DiagramCoordinates.world(CGPoint(x:value*72-original.sheetOrigin.x,y:original.height-36+original.sheetOrigin.y),in:original)
            let repeated = try ControlEditing.preview(baseline:baseline,node:node.id,control:"Redirect",to:point).diagram
            let fresh = try ControlEditing.moved(settled,node:node.id,control:"Redirect",to:point)
            XCTAssertEqual(repeated,fresh)
            XCTAssertEqual(Double(repeated.page.nodes[0].formatting.sheet["User.Target"]!.value)!,1+value,accuracy:0.00001)
        }
    }

    func testControlBaselineReusesPriorDiagnosticsAcrossPreviewEvents() throws {
        var input = fixture()
        input.pages[0].nodes[0].formatting.controls = [ShapeControl(name: "Handle", index: 0, cells: [
            "X": ShapeSheetCell(value: "1", formula: "SETATREFEXPR(1)"), "Y": ShapeSheetCell(value: "1"), "YCon": ShapeSheetCell(value: "1")
        ])]
        let settled = full(input).diagram
        let baseline = ControlEditing.prepare(settled), id = settled.page.nodes[0].id
        for x in [180.0, 190.0, 200.0] {
            let point = CGPoint(x: x, y: 130)
            let preview = try ControlEditing.preview(baseline: baseline, node: id, control: "Handle", to: point)
            XCTAssertEqual(preview.diagram, try ControlEditing.moved(settled, node: id, control: "Handle", to: point))
            XCTAssertEqual(preview.work.geometryPages, 1)
            XCTAssertEqual(preview.work.geometryNodes, 2)
            XCTAssertLessThan(preview.work.evaluatedCells, baseline.work.evaluatedCells)
            XCTAssertEqual(preview.work.inputComparisonNodes, 0)
            XCTAssertEqual(preview.work.dependencyNodesIndexed, 0)
        }
    }

    /// Found on a large customer drawing: these functions (theme colours, dates, document properties, actions,
    /// line-pattern USE) made every edit recalculate every shape on the page.
    func testFunctionsWithoutHiddenDependenciesKeepEditsIncremental() {
        var input = fixture()
        let formulas = ["THEMEGUARD(MSOTINT(THEME(\"AccentColor\"),40))", "TINT(RGB(1,2,3),20)", "SHADE(RGB(1,2,3),20)",
                        "DATETIME(46000)", "DATEVALUE(\"1/1/2026\")", "MAGNITUDE(1,2,3,4)", "FORMULAEXISTS(Sheet.1!Width)",
                        "OPENTEXTWIN()", "DOCMD(1312)", "FILENAME()", "DOCLASTSAVE()", "USE({050ADB88-0004-0000-8E40-00608CF305B2})"]
        for (i, formula) in formulas.enumerated() {
            input.pages[0].nodes[i + 2].formatting.sheet["User.F\(i)"] = ShapeSheetCell(value: "0", formula: formula)
        }
        let settled = DiagramCalculation.recalculate(input, now: clock)
        var edit = settled.diagram
        edit.pages[0].nodes[0].formatting.sheet["User.Padding"]?.value = "1"
        let result = withDiagnostics(edit, previous: settled)
        XCTAssertEqual(result.work.conservativePages, 0, "No page needs whole-page calculation")
        XCTAssertLessThan(result.work.geometryNodes, 10)
    }

    private func withDiagnostics(_ edit: Diagram, previous settled: DiagramCalculation.Result) -> DiagramCalculation.Result {
        DiagramCalculation.recalculate(edit, previous: settled.diagram, previousIssues: settled.issues,
            previousGeometryIssuesByPage: settled.geometryIssuesByPage, previousFieldIssuesByPage: settled.fieldIssuesByPage,
            previousGeometryDiagnosticsByPage: settled.geometryDiagnosticsByPage, previousFieldDiagnosticsByPage: settled.fieldDiagnosticsByPage,
            changes: DocumentChangeSet.between(settled.diagram, edit), now: clock)
    }

    /// A page with calculation issues stays incremental when the issues' diagnostics are retained, and keeps
    /// the issues of the shapes it does not recalculate.
    func testPagesWithIssuesStayIncrementalAndKeepUntouchedIssues() {
        var input = fixture()
        input.pages[0].nodes[30].formatting.sheet["User.Bad"] = ShapeSheetCell(value: "retained", formula: "SQRT(-1)")
        let settled = DiagramCalculation.recalculate(input, now: clock)
        XCTAssertFalse(settled.issues.isEmpty)
        var edit = settled.diagram
        edit.pages[0].nodes[0].formatting.sheet["User.Padding"]?.value = "1"
        let result = withDiagnostics(edit, previous: settled)
        XCTAssertEqual(result.work.conservativePages, 0)
        XCTAssertLessThan(result.work.geometryNodes, 10)
        XCTAssertEqual(result.issues, settled.issues)
        XCTAssertEqual(result.geometryDiagnosticsByPage[edit.pages[0].id]?.map(\.message), settled.geometryDiagnosticsByPage[edit.pages[0].id]?.map(\.message))
    }
}
