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

    func testVisioRoundTripPreservesChoiceAndUninterpretedTypeValues() throws {
        var diagram = Diagram()
        let oldNumber = ShapeDataProperty(key:"Number",label:"Number",value:"00125",type:2,format:"0.00")
        let editedNumber = try XCTUnwrap(ShapeDataEditing.validated([ShapeDataProperty(key:"Number",label:"Number",value:"125.50",type:2,format:oldNumber.format)],previous:[oldNumber]).first)
        let properties = [
            ShapeDataProperty(key:"Fixed",label:"Fixed",value:"Ready",type:1,format:"Draft;Ready"),
            ShapeDataProperty(key:"Flag",label:"Flag",value:"FALSE",type:3),
            ShapeDataProperty(key:"Variable",label:"Variable",value:"Review",type:4,format:"Draft;Review"),
            editedNumber,
            ShapeDataProperty(key:"Dimension",label:"Dimension",value:"25.5 cm",type:2,format:"0.00 cm"),
            ShapeDataProperty(key:"Date",label:"Date",value:"not normalized",type:5,format:"custom"),
            ShapeDataProperty(key:"Duration",label:"Duration",value:"2d",type:6,format:"days"),
            ShapeDataProperty(key:"Currency",label:"Currency",value:"$001.20",type:7,format:"USD")
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
        node.formatting.data = [ShapeDataProperty(key:"Status",label:"Status",value:"Draft",type:4,format:"Draft"),originalNumber]
        diagram.page.nodes = [node]
        let document = MacVisioDocument();document.diagram = diagram;document.makeWindowControllers();document.undoManager?.groupsByEvent = false
        let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        defer { editor.window?.orderOut(nil);editor.window?.delegate = nil;document.removeWindowController(editor);editor.close() }
        editor.canvas.select([node.id])
        let changed = ShapeDataProperty(key:"Status",label:"Status",value:"Review",type:4,format:"Draft;Review")
        let changedNumber = try XCTUnwrap(ShapeDataEditing.validated([ShapeDataProperty(key:"Cost",label:"Cost",value:"125.50",type:2,format:originalNumber.format)],previous:[originalNumber]).first)
        let originalProperties = node.formatting.data
        let changedProperties = [changed,changedNumber]
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
