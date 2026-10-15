import AppKit
import XCTest
@testable import MacVisio

final class ShapeDataEditingTests:XCTestCase {
    private var urls:[URL] = []
    override func tearDown() { for url in urls { try? FileManager.default.removeItem(at:url) };super.tearDown() }
    private func temp(_ ext:String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-shape-data-\(UUID()).\(ext)")
        urls.append(url);return url
    }

    func testFixedListRejectsValuesOutsideFormatAndKeepsAnUntouchedLegacyValue() throws {
        let old = ShapeDataProperty(key:"Status",label:"Status",value:"Archived",type:1,format:"Draft;Ready")
        XCTAssertThrowsError(try ShapeDataEditing.validated([ShapeDataProperty(key:"Status",label:"Status",value:"Blocked",type:1,format:old.format)],previous:[old]))
        XCTAssertEqual(try ShapeDataEditing.validated([old],previous:[old]),[old])
        let valid = ShapeDataProperty(key:"Status",label:"Status",value:"Ready",type:1,format:old.format)
        XCTAssertEqual(try ShapeDataEditing.validated([valid],previous:[old]),[valid])
    }

    func testVariableListAddsNewValueToSemicolonSeparatedFormat() throws {
        let old = ShapeDataProperty(key:"Stage",label:"Stage",value:"Design",type:4,format:"Draft;Design")
        let entered = ShapeDataProperty(key:"Stage",label:"Stage",value:"Review",type:4,format:old.format)
        let updated = try XCTUnwrap(ShapeDataEditing.validated([entered],previous:[old]).first)
        XCTAssertEqual(updated.value,"Review")
        XCTAssertEqual(updated.format,"Draft;Design;Review")
        XCTAssertEqual(ShapeDataEditing.formatChoices(updated.format),["Draft","Design","Review"])
    }

    func testNumberTypeValidatesChangedLiteralsWithoutRewritingFormatOrSpelling() throws {
        let old = ShapeDataProperty(key:"Length",label:"Length",value:"00125",type:2,format:"0.00 cm")
        XCTAssertEqual(try ShapeDataEditing.validated([old],previous:[old]),[old])
        let entered = ShapeDataProperty(key:"Length",label:"Length",value:"25.5 cm",type:2,format:old.format)
        XCTAssertEqual(try ShapeDataEditing.validated([entered],previous:[old]),[entered])
        let legacy = ShapeDataProperty(key:"Length",label:"Length",value:"legacy",type:2,format:"custom picture")
        XCTAssertEqual(try ShapeDataEditing.validated([legacy],previous:[legacy]),[legacy])
        for value in ["not a number","1+2","NaN","infinity"] {
            let invalid = ShapeDataProperty(key:"Length",label:"Length",value:value,type:2,format:old.format)
            XCTAssertThrowsError(try ShapeDataEditing.validated([invalid],previous:[old]),value)
        }
    }

    func testBooleanChoicesUseTrueFalseAndPreserveExistingVisioEncoding() throws {
        let old = ShapeDataProperty(key:"Approved",label:"Approved",value:"1",type:3)
        XCTAssertEqual(ShapeDataEditing.displayedValue(old),"TRUE")
        let unchanged = ShapeDataProperty(key:"Approved",label:"Approved",value:"TRUE",type:3)
        XCTAssertEqual(try ShapeDataEditing.validated([unchanged],previous:[old]).first?.value,"1")
        let falseValue = ShapeDataProperty(key:"Approved",label:"Approved",value:"FALSE",type:3)
        XCTAssertEqual(try ShapeDataEditing.validated([falseValue],previous:[old]).first?.value,"FALSE")
        XCTAssertThrowsError(try ShapeDataEditing.validated([ShapeDataProperty(key:"Approved",label:"Approved",value:"maybe",type:3)],previous:[old]))
    }

    func testDateDurationAndCurrencyEditorsPreserveDisplayValuesAndValidateChangedInput() throws {
        let old = [
            ShapeDataProperty(key:"Due",label:"Due date",value:"2017-09-12T10:51:53",type:5,format:"{<200>}"),
            ShapeDataProperty(key:"Elapsed",label:"Elapsed",value:"0",type:6,format:"[d] 'ed.'"),
            ShapeDataProperty(key:"Cost",label:"Cost",value:"0",type:7,format:"@")
        ]
        XCTAssertEqual(old.map(ShapeDataEditing.displayedValue),old.map(\.value))
        XCTAssertEqual(try ShapeDataEditing.validated(old,previous:old),old)

        let grid = PropertyGrid(columns:["Key","Label","Value","Type","Format","Prompt"],rows:old.map{[$0.key,$0.label,$0.value,String($0.type),$0.format,$0.prompt]},editsShapeData:true)
        let edits = ["2026-10-15T09:30:00","1.25","125.50"]
        for row in old.indices {
            let field = try XCTUnwrap(grid.tableView(grid.table,viewFor:grid.table.tableColumns[2],row:row) as? NSTextField)
            field.stringValue = edits[row]
            grid.changed(field)
            XCTAssertEqual(grid.rows[row][2],edits[row])
        }
        let entered = grid.rows.map{ShapeDataProperty(key:$0[0],label:$0[1],value:$0[2],type:Int($0[3]) ?? 0,format:$0[4],prompt:$0[5])}
        XCTAssertEqual(try ShapeDataEditing.validated(entered,previous:old).map(\.value),edits)
        XCTAssertEqual(try ShapeDataEditing.validated(entered,previous:old).map(\.format),old.map(\.format))

        let invalidDate = ShapeDataProperty(key:"Due",label:"Due date",value:"2026-02-30",type:5,format:old[0].format)
        XCTAssertThrowsError(try ShapeDataEditing.validated([invalidDate],previous:[old[0]]))
        let invalidDuration = ShapeDataProperty(key:"Elapsed",label:"Elapsed",value:"1 eh",type:6,format:old[1].format)
        XCTAssertThrowsError(try ShapeDataEditing.validated([invalidDuration],previous:[old[1]]))
        let infiniteCurrency = ShapeDataProperty(key:"Cost",label:"Cost",value:"infinity",type:7,format:old[2].format)
        XCTAssertThrowsError(try ShapeDataEditing.validated([infiniteCurrency],previous:[old[2]]))
    }

    func testUntouchedLegacyDateDurationAndCurrencyValuesRemainVerbatim() throws {
        let legacy = [
            ShapeDataProperty(key:"Due",label:"Due date",value:"local date",type:5,format:"legacy date picture"),
            ShapeDataProperty(key:"Elapsed",label:"Elapsed",value:"2d",type:6,format:"legacy duration picture"),
            ShapeDataProperty(key:"Cost",label:"Cost",value:"$001.20",type:7,format:"legacy currency picture")
        ]
        XCTAssertEqual(legacy.map(ShapeDataEditing.displayedValue),legacy.map(\.value))
        XCTAssertEqual(try ShapeDataEditing.validated(legacy,previous:legacy),legacy)
    }

    func testVisioRoundTripPreservesTypedShapeDataValuesAndFormats() throws {
        var diagram = Diagram()
        let oldNumber = ShapeDataProperty(key:"Number",label:"Number",value:"00125",type:2,format:"0.00")
        let editedNumber = try XCTUnwrap(ShapeDataEditing.validated([ShapeDataProperty(key:"Number",label:"Number",value:"125.50",type:2,format:oldNumber.format)],previous:[oldNumber]).first)
        let properties = [
            ShapeDataProperty(key:"Fixed",label:"Fixed",value:"Ready",type:1,format:"Draft;Ready"),
            ShapeDataProperty(key:"Flag",label:"Flag",value:"FALSE",type:3),
            ShapeDataProperty(key:"Variable",label:"Variable",value:"Review",type:4,format:"Draft;Review"),
            editedNumber,
            ShapeDataProperty(key:"Dimension",label:"Dimension",value:"25.5 cm",type:2,format:"0.00 cm"),
            ShapeDataProperty(key:"Date",label:"Date",value:"2026-10-15T10:30:00",type:5,format:"{<200>}"),
            ShapeDataProperty(key:"Duration",label:"Duration",value:"0.5",type:6,format:"[d] 'ed.'"),
            ShapeDataProperty(key:"Currency",label:"Currency",value:"001.20",type:7,format:"@")
        ]
        diagram.page.nodes = [DiagramNode(x:40,y:50,text:"Data")]
        diagram.page.nodes[0].formatting.data = properties
        let url = temp("vsdx")
        try VisioFormat.write(diagram,to:url)
        var parts = try VisioPackage.read(url)
        parts.removeValue(forKey:"macvisio/document.json")
        try VisioPackage.write(parts,to:url)
        let reopened = try VisioFormat.read(from:url).diagram.page.nodes[0].formatting.data
        XCTAssertEqual(reopened,properties)
    }

    func testShapeDataSelectionEditRemainsOneUndoableAction() throws {
        _ = NSApplication.shared
        var diagram = Diagram()
        var node = DiagramNode(x:40,y:50,text:"Data")
        let originalNumber = ShapeDataProperty(key:"Cost",label:"Cost",value:"00125",type:2,format:"$#,##0.00")
        let originalProperties = [
            ShapeDataProperty(key:"Status",label:"Status",value:"Draft",type:4,format:"Draft"),originalNumber,
            ShapeDataProperty(key:"Due",label:"Due date",value:"2024-01-02T03:04:05",type:5,format:"{<200>}"),
            ShapeDataProperty(key:"Elapsed",label:"Elapsed",value:"0.25",type:6,format:"[d] 'ed.'"),
            ShapeDataProperty(key:"Budget",label:"Budget",value:"001.20",type:7,format:"@")
        ]
        node.formatting.data = originalProperties
        diagram.page.nodes = [node]
        let document = MacVisioDocument();document.diagram = diagram;document.makeWindowControllers();document.undoManager?.groupsByEvent = false
        let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        defer { editor.window?.orderOut(nil);editor.window?.delegate = nil;document.removeWindowController(editor);editor.close() }
        editor.canvas.select([node.id])
        let changed = ShapeDataProperty(key:"Status",label:"Status",value:"Review",type:4,format:"Draft;Review")
        let changedNumber = try XCTUnwrap(ShapeDataEditing.validated([ShapeDataProperty(key:"Cost",label:"Cost",value:"125.50",type:2,format:originalNumber.format)],previous:[originalNumber]).first)
        let changedProperties = [
            changed,changedNumber,
            ShapeDataProperty(key:"Due",label:"Due date",value:"2025-02-03T04:05:06",type:5,format:"{<200>}"),
            ShapeDataProperty(key:"Elapsed",label:"Elapsed",value:"0.5",type:6,format:"[d] 'ed.'"),
            ShapeDataProperty(key:"Budget",label:"Budget",value:"2.40",type:7,format:"@")
        ]
        document.undoManager?.beginUndoGrouping()
        editor.modifySelection("Shape Data") { $0.formatting.data = changedProperties }
        document.undoManager?.endUndoGrouping()
        XCTAssertEqual(document.diagram.page.nodes[0].formatting.data,changedProperties)
        document.undoManager?.undo()
        XCTAssertEqual(document.diagram.page.nodes[0].formatting.data,originalProperties)
        document.undoManager?.redo()
        XCTAssertEqual(document.diagram.page.nodes[0].formatting.data,changedProperties)
    }
}
