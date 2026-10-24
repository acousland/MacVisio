import AppKit
import XCTest
@testable import MacVisio

/// Native editor regressions for existing authored cells. Row/section lifecycle
/// and reference-Visio acceptance remain separate work.
final class M3DefinitionEditorTests:XCTestCase {
    private func fixture() throws -> Diagram {
        let url = try XCTUnwrap(Bundle.module.url(forResource:"m3-intelligent",withExtension:"vsdx",subdirectory:"Fixtures/M3"))
        var parts = try VisioPackage.read(url)
        let document = try VisioXML.document(XCTUnwrap(parts["visio/document.xml"]))
        if document.rootElement()?.firstLocal("DocumentSheet") == nil {
            document.rootElement()?.addChild(try VisioXML.element("<DocumentSheet><Section N=\"User\"><Row N=\"Revision\"><Cell N=\"Value\" V=\"1\"/></Row></Section></DocumentSheet>"))
        }
        parts["visio/document.xml"] = document.xmlData(options:.nodePreserveAll)
        return try VisioFormat.readPublic(parts:parts,title:"Definition editor fixture").diagram
    }
    private func withEditor(_ body:(MacVisioDocument,EditorWindowController) throws -> Void) throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument();document.diagram = try self.fixture();document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            document.undoManager?.groupsByEvent = false;document.undoManager?.removeAllActions()
            editor.window?.makeKeyAndOrderFront(nil)
            defer {
                if document.isCalculating { document.cancelPendingCalculation();self.waitForCalculation(document) }
                editor.definitionSheetController.close();editor.commandSearchController.close();document.close()
            }
            try body(document,editor)
        }
    }
    private func onMain<T>(_ body:() throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute:body)
    }
    private func waitForCalculation(_ document:MacVisioDocument,file:StaticString = #filePath,line:UInt = #line) {
        let deadline = Date().addingTimeInterval(15)
        while document.isCalculating && Date() < deadline { _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(document.isCalculating,file:file,line:line)
    }
    private func master(_ document:MacVisioDocument,_ id:String = "7") throws -> DiagramDefinition {
        try XCTUnwrap(document.diagram.definitions?.masters.first{$0.publicID == id})
    }
    private func openHeight(_ document:MacVisioDocument,_ editor:EditorWindowController) throws -> DefinitionSheetEditorController {
        let sheet = try master(document).sheets[0]
        editor.showDefinitionSheet(sheetID:sheet.id,address:DefinitionCellAddress(cell:"Height"))
        let controller = editor.definitionSheetController
        XCTAssertTrue(controller.window?.isVisible == true);XCTAssertEqual(controller.selectedSheetID,sheet.id)
        XCTAssertEqual(controller.selectedAddress,DefinitionCellAddress(cell:"Height"));return controller
    }

    func testNoSelectionCommandRoutesToScopedOwnersWithUnambiguousDuplicateNames() throws {
        try withEditor { document,editor in
            editor.canvas.select([])
            let command = try XCTUnwrap(EditorSearchCommand.all.first{$0.action == #selector(EditorWindowController.showDefinitionSheets(_:))})
            XCTAssertNil(command.disabledReason(in:editor))
            XCTAssertTrue(editor.validateMenuItem(NSMenuItem(title:command.title,action:command.action,keyEquivalent:"")))
            XCTAssertTrue(EditorSearchCommand.matching("master formula").contains{$0.action == command.action})
            let search = editor.commandSearchController
            search.searchField.stringValue = "Definition Sheets";search.filterCommands()
            XCTAssertTrue(search.executeSelected())
            let controller = editor.definitionSheetController
            XCTAssertTrue(controller.window?.isVisible == true)
            let registry = try XCTUnwrap(document.diagram.definitions)
            XCTAssertTrue(controller.owners.contains{$0.id == registry.sourceDocumentID})
            for definition in registry.masters + registry.styles {
                let owner = try XCTUnwrap(controller.owners.first{$0.id == definition.id})
                XCTAssertTrue(owner.title.contains(definition.publicID));XCTAssertTrue(owner.title.contains(definition.universalName))
                XCTAssertEqual(owner.sheets.map(\.id),definition.sheets.map(\.id))
            }
            let sameNames = controller.owners.filter{$0.title.contains("Same display")}
            XCTAssertGreaterThanOrEqual(sameNames.count,2);XCTAssertEqual(Set(sameNames.map(\.title)).count,sameNames.count)
            XCTAssertTrue(document.diagram.pages[0].nodes.allSatisfy{!editor.canvas.selectedNodes.contains($0.id)})
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testExactAddressSelectionDistinguishesRepeatedCellNamesAcrossRowsAndSheets() throws {
        try withEditor { document,editor in
            let definition = try master(document),sheet = definition.sheets[0]
            let first = try XCTUnwrap(sheet.cells.first{$0.address.cell == "X" && $0.address.section == "Geometry"})
            let second = try XCTUnwrap(sheet.cells.first{$0.address.cell == "X" && $0.address.section == "Control"})
            XCTAssertNotEqual(first.address,second.address)
            editor.showDefinitionSheet(sheetID:sheet.id,address:first.address)
            let controller = editor.definitionSheetController
            XCTAssertEqual(controller.selectedCell?.id,first.id)
            XCTAssertTrue(controller.selectCell(sheetID:sheet.id,address:second.address))
            XCTAssertEqual(controller.selectedCell?.id,second.id)
            XCTAssertEqual(controller.formulaField.stringValue,second.value.formula)
            let other = try master(document,"8").sheets[0]
            let height = try XCTUnwrap(other.cells.first{$0.address == DefinitionCellAddress(cell:"Height")})
            XCTAssertTrue(controller.selectCell(sheetID:other.id,address:height.address))
            XCTAssertEqual(controller.selectedCell?.id,height.id);XCTAssertEqual(controller.selectedOwnerID,try master(document,"8").id)
        }
    }

    func testSelectedMasterCellApplyUsesOwnedWorkerOneUndoAndPublicSourcePatch() throws {
        try withEditor { document,editor in
            let controller = try openHeight(document,editor),before = document.diagram
            let selected = before.pages[0].nodes[0].id;editor.canvas.select([selected])
            controller.valueField.stringValue = "1.5";controller.refreshAvailability()
            XCTAssertTrue(controller.applyButton.isEnabled);XCTAssertTrue(controller.applySelectedCell())
            XCTAssertTrue(document.isCalculating);XCTAssertEqual(document.diagram,before)
            XCTAssertFalse(controller.applySelectedCell(),"A second cell cannot enter the active transaction.")
            waitForCalculation(document);controller.refreshAvailability()
            XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(document.undoManager?.undoActionName,"Edit Definition")
            XCTAssertEqual(editor.canvas.selectedNodes,[selected])
            XCTAssertEqual(try master(document).sheets[0].cell(DefinitionCellAddress(cell:"Height"))?.value,"1.5")
            let publicParts = try VisioPreservation.prepared(document.diagram).parts
            let publicDrawing = try VisioFormat.readPublic(parts:publicParts,title:"Public editor result").diagram
            XCTAssertEqual(try XCTUnwrap(publicDrawing.pages[0].nodes.first{$0.formatting.sourceShapeID == "10"}).height,108,accuracy:1e-8)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.definitions,before.definitions);XCTAssertEqual(document.diagram.pages,before.pages)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
            document.undoManager?.redo()
            XCTAssertEqual(try master(document).sheets[0].cell(DefinitionCellAddress(cell:"Height"))?.value,"1.5")
        }
    }

    func testDocumentCellApplyTargetsDocumentOwnerWithoutSelectingAnInstance() throws {
        try withEditor { document,editor in
            let sheet = try XCTUnwrap(document.diagram.definitions?.documentSheet)
            let address = try XCTUnwrap(sheet.cells.first{$0.address.section == "User" && $0.address.rowName == "Revision"}).address
            editor.canvas.select([]);editor.showDefinitionSheet(sheetID:sheet.id,address:address)
            let controller = editor.definitionSheetController
            XCTAssertEqual(controller.selectedOwnerID,document.diagram.definitions?.sourceDocumentID)
            controller.valueField.stringValue = "2";XCTAssertTrue(controller.applySelectedCell());waitForCalculation(document)
            XCTAssertEqual(document.diagram.definitions?.documentSheet?.cell(address)?.value,"2")
            XCTAssertTrue(editor.canvas.selectedNodes.isEmpty)
            let parts = try VisioPreservation.prepared(document.diagram).parts
            let source = try VisioXML.document(XCTUnwrap(parts["visio/document.xml"]))
            let row = source.rootElement()?.firstLocal("DocumentSheet")?.elementsLocal("Section").first{$0.attr("N") == "User"}?.elementsLocal("Row").first{$0.attr("N") == "Revision"}
            XCTAssertEqual(VisioXML.value(row,"Value"),"2")
        }
    }

    func testStaleRevisionRefusesDraftAndReloadsExactCurrentCell() throws {
        try withEditor { document,editor in
            let controller = try openHeight(document,editor),sheetID = try XCTUnwrap(controller.selectedSheetID)
            controller.valueField.stringValue = "2"
            var next = document.diagram;next.pages[0].nodes[0].text = "Concurrent local edit"
            document.replace(with:next,action:"Concurrent edit")
            let revision = document.revision,state = document.stateID
            XCTAssertFalse(controller.applySelectedCell());XCTAssertFalse(document.isCalculating)
            XCTAssertEqual(document.revision,revision);XCTAssertEqual(document.stateID,state)
            XCTAssertEqual(controller.selectedSheetID,sheetID);XCTAssertEqual(controller.valueField.stringValue,"1")
            XCTAssertTrue(controller.reasonLabel.stringValue.contains("changed"))
            XCTAssertEqual(try master(document).sheets[0].cell(DefinitionCellAddress(cell:"Height"))?.value,"1")
        }
    }

    func testSourceOnlySaveRebaseInvalidatesDraftEvenWhenSemanticRevisionIsUnchanged() throws {
        try withEditor { document,editor in
            let controller = try openHeight(document,editor)
            controller.valueField.stringValue = "2"
            let revision = document.revision,state = document.stateID,resource = document.diagram.visioArchive?.sourceResourceID
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-definition-editor-\(UUID())")
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            var completed = false,failure:Error?
            document.save(to:directory.appendingPathComponent("saved.vsdx"),ofType:MacVisioDocument.visioType,for:.saveAsOperation){failure = $0;completed = true}
            let deadline = Date().addingTimeInterval(20)
            while !completed && Date() < deadline { _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(completed);if let failure { throw failure }
            XCTAssertEqual(document.revision,revision);XCTAssertEqual(document.stateID,state)
            XCTAssertNotEqual(document.diagram.visioArchive?.sourceResourceID,resource)
            XCTAssertFalse(controller.applySelectedCell());XCTAssertFalse(document.isCalculating)
            XCTAssertEqual(controller.valueField.stringValue,"1")
        }
    }

    func testMarkedTextCannotOpenApplyOrCloseOverNativeComposition() throws {
        try withEditor { document,editor in
            let controller = editor.definitionSheetController,node = document.diagram.pages[0].nodes[0]
            editor.canvas.select([node.id]);editor.canvas.beginEditing(node.id)
            let inline = try XCTUnwrap(editor.canvas.subviews.compactMap{$0 as? NSTextView}.first)
            inline.setMarkedText("あ",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            XCTAssertTrue(inline.hasMarkedText());editor.showDefinitionSheets(nil)
            XCTAssertFalse(controller.window?.isVisible ?? true);XCTAssertTrue(inline.hasMarkedText())
            inline.unmarkText();inline.string = "Committed before definitions"
            editor.showDefinitionSheets(nil)
            XCTAssertTrue(controller.window?.isVisible == true);XCTAssertFalse(editor.canvas.isEditingText)
            XCTAssertEqual(document.diagram.pages[0].nodes[0].text,"Committed before definitions")
            let master = try self.master(document)
            XCTAssertTrue(controller.selectCell(sheetID:master.sheets[0].id,address:DefinitionCellAddress(cell:"Height")))
            XCTAssertTrue(controller.window?.makeFirstResponder(controller.valueField) == true)
            let field = try XCTUnwrap(controller.valueField.currentEditor() as? NSTextView),before = document.diagram
            field.setMarkedText("あ",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            controller.refreshAvailability()
            XCTAssertTrue(field.hasMarkedText());XCTAssertFalse(controller.applyButton.isEnabled)
            XCTAssertFalse(controller.applySelectedCell());controller.cancelOperation(nil)
            XCTAssertTrue(field.hasMarkedText());XCTAssertTrue(controller.window?.isVisible == true)
            XCTAssertEqual(document.diagram,before);field.unmarkText()
        }
    }

    func testCancellationAndClosedOwnerCannotCommitBrowserDraft() throws {
        try withEditor { document,editor in
            let controller = try openHeight(document,editor),before = document.diagram,state = document.stateID
            let selected = before.pages[0].nodes[0].id;editor.canvas.select([selected])
            controller.valueField.stringValue = "2";XCTAssertTrue(controller.applySelectedCell())
            document.cancelPendingCalculation();waitForCalculation(document);controller.refreshAvailability()
            XCTAssertEqual(document.diagram,before);XCTAssertEqual(document.stateID,state)
            XCTAssertEqual(editor.canvas.selectedNodes,[selected]);XCTAssertFalse(document.undoManager?.canUndo ?? true)
            editor.close()
            XCTAssertFalse(controller.applySelectedCell());XCTAssertFalse(controller.applyButton.isEnabled)
        }
    }
    func testNativeRowAddRenameDeleteShareOwnedWorkerAndUndoWithoutCanvasSelection() throws {
        try withEditor { document,editor in
            editor.canvas.select([])
            let sheet = try XCTUnwrap(document.diagram.definitions?.documentSheet)
            editor.showDefinitionSheet(sheetID:sheet.id,address:nil)
            let controller = editor.definitionSheetController,before = document.diagram
            XCTAssertNil(controller.selectedCell)
            XCTAssertTrue(controller.submitRowEdit(.insert(section:"Property",name:"Project")))
            XCTAssertEqual(document.diagram,before);XCTAssertTrue(document.isCalculating)
            XCTAssertFalse(controller.submitRowEdit(.insert(section:"User",name:"Second")))
            waitForCalculation(document);controller.refreshAvailability()
            XCTAssertNil(document.lastCalculationJobError)
            let row = try XCTUnwrap(document.diagram.definitions?.documentSheet?.rows.first{$0.name == "Project"})
            XCTAssertEqual(controller.selectedAddress,DefinitionCellAddress(cell:"Value",section:"Property",rowName:"Project"))
            XCTAssertEqual(document.undoManager?.undoActionName,"Edit Definition Row")
            XCTAssertTrue(controller.submitRowEdit(.rename(rowID:row.id,name:"Workstream")))
            waitForCalculation(document);controller.refreshAvailability();XCTAssertNil(document.lastCalculationJobError)
            XCTAssertEqual(controller.selectedCell?.address.rowName,"Workstream")
            XCTAssertTrue(controller.submitRowEdit(.remove(rowID:row.id)))
            waitForCalculation(document);controller.refreshAvailability();XCTAssertNil(document.lastCalculationJobError)
            XCTAssertFalse(document.diagram.definitions?.documentSheet?.rows.contains{$0.id == row.id} ?? true)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.definitions?.documentSheet?.rows.first{$0.id == row.id}?.name,"Workstream")
            document.undoManager?.undo();document.undoManager?.undo()
            XCTAssertEqual(document.diagram.definitions,before.definitions)
            XCTAssertTrue(editor.canvas.selectedNodes.isEmpty)
        }
    }

    func testNativeRowDraftRefusesIMEStaleSnapshotAndClosedOwner() throws {
        try withEditor { document,editor in
            let sheet = try XCTUnwrap(document.diagram.definitions?.documentSheet)
            editor.showDefinitionSheet(sheetID:sheet.id,address:nil)
            let controller = editor.definitionSheetController,before = document.diagram
            XCTAssertTrue(controller.window?.makeFirstResponder(controller.rowNameField) == true)
            let field = try XCTUnwrap(controller.rowNameField.currentEditor() as? NSTextView)
            field.setMarkedText("あ",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
            XCTAssertFalse(controller.submitRowEdit(.insert(section:"User",name:"Draft")))
            XCTAssertTrue(field.hasMarkedText());XCTAssertEqual(document.diagram,before);field.unmarkText()
            var changed = document.diagram;changed.pages[0].name = "Concurrent page name"
            document.replace(with:changed,action:"Concurrent edit")
            XCTAssertFalse(controller.submitRowEdit(.insert(section:"User",name:"Draft")))
            XCTAssertFalse(document.isCalculating)
            XCTAssertTrue(controller.reasonLabel.stringValue.contains("changed"))
            editor.close();XCTAssertFalse(controller.submitRowEdit(.insert(section:"User",name:"Draft")))
        }
    }

    func testNativeEmptySectionLifecycleHasOneUndoPerCommand() throws {
        try withEditor { document,editor in
            let sheet = try XCTUnwrap(document.diagram.definitions?.documentSheet)
            editor.showDefinitionSheet(sheetID:sheet.id,address:nil)
            let controller = editor.definitionSheetController
            XCTAssertTrue(controller.submitRowEdit(.insertSection(name:"Property")))
            waitForCalculation(document);controller.refreshAvailability();XCTAssertNil(document.lastCalculationJobError)
            let section = try XCTUnwrap(document.diagram.definitions?.documentSheet?.sections?.first{$0.name == "Property"})
            XCTAssertTrue(controller.submitRowEdit(.removeSection(sectionID:section.id)))
            waitForCalculation(document);controller.refreshAvailability();XCTAssertNil(document.lastCalculationJobError)
            XCTAssertFalse(document.diagram.definitions?.documentSheet?.sections?.contains{$0.id == section.id} ?? true)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.definitions?.documentSheet?.sections?.first{$0.id == section.id},section)
            document.undoManager?.undo();XCTAssertEqual(document.diagram.definitions?.documentSheet,sheet)
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testReferencedRowWorkerFailureRemainsVisibleUntilNewDraft() throws {
        try withEditor { document,editor in
            let sheet = try XCTUnwrap(document.diagram.definitions?.documentSheet)
            let row = try XCTUnwrap(sheet.rows.first{$0.name == "Revision"})
            document.diagram.pages[0].nodes[1].formatting.sheet["Width"] = ShapeSheetCell(value:"3",formula:"TheDoc!User.Revision")
            editor.showDefinitionSheet(sheetID:sheet.id,address:DefinitionCellAddress(cell:"Value",section:"User",rowName:"Revision"))
            let controller = editor.definitionSheetController,before = document.diagram
            XCTAssertTrue(controller.submitRowEdit(.remove(rowID:row.id)))
            waitForCalculation(document);controller.refreshAvailability()
            XCTAssertNotNil(document.lastCalculationJobError)
            XCTAssertTrue(controller.reasonLabel.stringValue.contains("still referenced"),controller.reasonLabel.stringValue)
            controller.refreshAvailability()
            XCTAssertTrue(controller.reasonLabel.stringValue.contains("still referenced"))
            XCTAssertEqual(document.diagram,before);XCTAssertFalse(document.undoManager?.canUndo ?? true)
            controller.rowNameField.stringValue = "New draft"
            controller.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:controller.rowNameField))
            XCTAssertFalse(controller.reasonLabel.stringValue.contains("still referenced"))
        }
    }

}
