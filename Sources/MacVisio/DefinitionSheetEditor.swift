import AppKit
import MacVisioInfrastructure
import ObjectiveC

private var definitionSheetEditorKey: UInt8 = 0

extension EditorWindowController {
    var definitionSheetController: DefinitionSheetEditorController {
        if let controller = objc_getAssociatedObject(self, &definitionSheetEditorKey) as? DefinitionSheetEditorController { return controller }
        let controller = DefinitionSheetEditorController(editor:self)
        objc_setAssociatedObject(self,&definitionSheetEditorKey,controller,.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }
    var definitionSheetUnavailableReason: String? {
        guard lifecycleJobs.isActive else { return "The drawing window is closed." }
        guard !diagramDocument.isCalculating else { return "Wait for calculation to finish or cancel it." }
        if diagramDocument.windowControllers.contains(where:{($0.window?.firstResponder as? NSTextView)?.hasMarkedText() == true}) || (objc_getAssociatedObject(self,&definitionSheetEditorKey) as? DefinitionSheetEditorController)?.hasMarkedText == true {
            return "Finish text composition before opening Definition Sheets."
        }
        guard diagramDocument.diagram.visioArchive != nil,let registry = diagramDocument.diagram.definitions,
              registry.documentSheet != nil || registry.masters.contains(where:{!$0.sheets.isEmpty}) || registry.styles.contains(where:{!$0.sheets.isEmpty}) else {
            return "Open or save a VSDX drawing with public definition sheets first."
        }
        return nil
    }
    @objc func showDefinitionSheets(_ sender:Any?) { showDefinitionSheet(sheetID:nil,address:nil) }

    /// Exact typed entry point for native commands and diagnostic navigation.
    /// Finalize native text before the browser takes its source/revision snapshot.
    func showDefinitionSheet(sheetID:UUID?,address:DefinitionCellAddress?) {
        if let reason = definitionSheetUnavailableReason { root.showMessage(reason);return }
        let controller = definitionSheetController
        guard !controller.hasMarkedText else { controller.explain("Finish text composition before changing the inspected cell.");return }
        guard window?.makeFirstResponder(canvas) != false else { return }
        diagramDocument.commitTextEditing();canvas.finishPageInteraction()
        if let reason = definitionSheetUnavailableReason { root.showMessage(reason);return }
        guard !canvas.isEditingText else { root.showMessage("Finish text editing before opening Definition Sheets.");return }
        guard controller.reloadSnapshot(sheetID:sheetID,address:address) else { root.showMessage(controller.reasonLabel.stringValue);return }
        controller.showWindow(nil)
    }
}

/// A browser owns display snapshots and drafts only. One selected existing cell
/// enters the document's accepted cancellable definition transaction per Apply.
final class DefinitionSheetEditorController:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate {
    struct Owner {
        var id:UUID
        var title:String
        var part:String
        var sheets:[DefinitionSheet]
    }
    private struct Snapshot:Equatable {
        var input:LifecycleJobInput
        var resourceID:UUID
        var lineageID:UUID
        var registryID:UUID
        var documentPart:String
    }
    private struct Availability:Equatable {
        var active:Bool
        var visible:Bool
        var calculating:Bool
        var stateID:UUID?
        var revision:UInt64?
        var resourceID:UUID?
        var composition:Bool
        var cellID:UUID?
        var draft:ShapeSheetCell
    }
    private weak var editor:EditorWindowController?
    private weak var drawing:MacVisioDocument?
    private let jobOwner:LifecycleJobOwner
    private var parentCloseObserver:NSObjectProtocol?
    private var timer:Timer?
    private var snapshot:Snapshot?
    private var submitted:Snapshot?
    private var availability:Availability?
    private var selecting = false
    private(set) var owners:[Owner] = []
    private(set) var selectedOwnerID:UUID?
    private(set) var selectedSheetID:UUID?
    private(set) var selectedCell:DefinitionCell?
    private(set) var cells:[DefinitionCell] = []
    let ownerPicker = NSPopUpButton(frame:.zero,pullsDown:false)
    let sheetPicker = NSPopUpButton(frame:.zero,pullsDown:false)
    let table = NSTableView()
    let sourceLabel = NSTextField(wrappingLabelWithString:"")
    let valueField = NSTextField(string:"")
    let formulaField = NSTextField(string:"")
    let unitField = NSTextField(string:"")
    let reasonLabel = NSTextField(wrappingLabelWithString:"Select an existing cell to edit its cached value, formula or unit.")
    let applyButton = NSButton(title:"Apply Cell",target:nil,action:nil)
    let reloadButton = NSButton(title:"Reload",target:nil,action:nil)

    init(editor:EditorWindowController) {
        self.editor = editor;drawing = editor.diagramDocument;jobOwner = editor.lifecycleJobs
        let panel = NSPanel(contentRect:CGRect(x:0,y:0,width:960,height:640),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title = "Definition Sheets";panel.minSize = CGSize(width:700,height:520)
        panel.isReleasedWhenClosed = false;panel.autorecalculatesKeyViewLoop = true
        super.init(window:panel);panel.delegate = self;panel.setAccessibilityIdentifier("MacVisioDefinitionSheets")
        buildUI()
        if let parent = editor.window {
            parentCloseObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:parent,queue:.main){[weak self] _ in self?.detach()}
        }
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { timer?.invalidate();if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) } }
    var hasMarkedText:Bool { (window?.firstResponder as? NSTextView)?.hasMarkedText() == true }
    var selectedAddress:DefinitionCellAddress? { selectedCell?.address }
    func explain(_ text:String) { reasonLabel.stringValue = text }

    override func showWindow(_ sender:Any?) {
        guard jobOwner.isActive,let parent = editor?.window,let window,drawing != nil else { return }
        if window.parent == nil { parent.addChildWindow(window,ordered:.above);window.center() }
        super.showWindow(sender);window.makeKeyAndOrderFront(sender);window.makeFirstResponder(table)
        timer?.invalidate();timer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in self?.refreshAvailability()}
        availability = nil;refreshAvailability()
    }
    override func cancelOperation(_ sender:Any?) { if !hasMarkedText { close() } }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        if hasMarkedText { explain("Finish text composition before closing Definition Sheets.");return false };return true
    }
    func windowWillClose(_ notification:Notification) {
        timer?.invalidate();timer = nil
        if let window { window.parent?.removeChildWindow(window) }
    }
    private func detach() {
        timer?.invalidate();timer = nil
        if let window { window.orderOut(nil);window.parent?.removeChildWindow(window) }
        editor = nil;drawing = nil;snapshot = nil;submitted = nil;applyButton.isEnabled = false
    }
    private var draft:ShapeSheetCell { ShapeSheetCell(value:valueField.stringValue,formula:formulaField.stringValue,unit:unitField.stringValue) }
    private var selectedOwner:Owner? { owners.first{$0.id == selectedOwnerID} }
    private var selectedSheet:DefinitionSheet? { selectedOwner?.sheets.first{$0.id == selectedSheetID} }

    @discardableResult func reloadSnapshot(sheetID:UUID? = nil,address:DefinitionCellAddress? = nil) -> Bool {
        guard !hasMarkedText else { explain("Finish text composition before reloading cells.");return false }
        guard let editor,let drawing,let source = drawing.diagram.visioArchive,let registry = drawing.diagram.definitions,
              editor.definitionSheetUnavailableReason == nil else {
            explain(editor?.definitionSheetUnavailableReason ?? "The definition source is unavailable.");applyButton.isEnabled = false;return false
        }
        var next:[Owner] = []
        if let sheet = registry.documentSheet {
            next.append(Owner(id:registry.sourceDocumentID,title:"Document · \(registry.documentPart)",part:registry.documentPart,sheets:[sheet]))
        }
        for definition in registry.masters + registry.styles {
            let kind = definition.kind == .master ? "Master" : "Style"
            let name = definition.name.isEmpty ? "Unnamed" : definition.name
            let universal = definition.universalName.isEmpty ? "" : " · \(definition.universalName)"
            next.append(Owner(id:definition.id,title:"\(kind) \(definition.publicID) · \(name)\(universal)",part:definition.part,sheets:definition.sheets))
        }
        owners = next.filter{!$0.sheets.isEmpty}
        snapshot = Snapshot(input:LifecycleJobInput(ownerID:drawing.lifecycleOwnerID,snapshotID:drawing.stateID,revision:drawing.revision),resourceID:source.sourceResourceID,lineageID:source.sourceLineageID,registryID:registry.sourceDocumentID,documentPart:registry.documentPart)
        ownerPicker.removeAllItems()
        for owner in owners { ownerPicker.addItem(withTitle:owner.title);ownerPicker.lastItem?.representedObject = owner.id as NSUUID }
        let requestedSheet = sheetID ?? selectedSheetID
        if let requestedSheet,!owners.contains(where:{$0.sheets.contains{$0.id == requestedSheet}}) {
            selectedOwnerID = nil;selectedSheetID = nil;selectedCell = nil;cells = [];sheetPicker.removeAllItems();table.reloadData();clearDraft()
            explain("The requested definition sheet is no longer available. Reload and choose a current owner.");applyButton.isEnabled = false;return false
        }
        let owner = owners.first{$0.sheets.contains{$0.id == requestedSheet}} ?? owners.first{$0.id == selectedOwnerID} ?? owners.first
        selectedOwnerID = owner?.id
        if let id = owner?.id,let item = ownerPicker.itemArray.first(where:{($0.representedObject as? NSUUID) == id as NSUUID}) { ownerPicker.select(item) }
        populateSheets(preferred:requestedSheet,address:address ?? selectedAddress)
        availability = nil;refreshAvailability()
        if address != nil,selectedAddress != address {
            explain("The requested authored cell is no longer available. Select an existing cell.");return false
        }
        return selectedSheetID != nil
    }
    private func populateSheets(preferred:UUID?,address:DefinitionCellAddress?) {
        sheetPicker.removeAllItems()
        for sheet in selectedOwner?.sheets ?? [] {
            let name = sheet.attributes["NameU"] ?? sheet.attributes["Name"] ?? ""
            sheetPicker.addItem(withTitle:"Sheet \(sheet.publicID)"+(name.isEmpty ? "" : " · "+name));sheetPicker.lastItem?.representedObject = sheet.id as NSUUID
        }
        let sheet = selectedOwner?.sheets.first{$0.id == preferred} ?? selectedOwner?.sheets.first
        selectedSheetID = sheet?.id
        if let id = sheet?.id,let item = sheetPicker.itemArray.first(where:{($0.representedObject as? NSUUID) == id as NSUUID}) { sheetPicker.select(item) }
        populateCells(address:address)
    }
    private func populateCells(address:DefinitionCellAddress?) {
        cells = (selectedSheet?.cells ?? []).sorted{$0.address.key < $1.address.key}
        sourceLabel.stringValue = "Source: \(selectedOwner?.part ?? "") · Sheet \(selectedSheet?.publicID ?? "")"
        selecting = true;table.reloadData();table.deselectAll(nil)
        if let address,let index = cells.firstIndex(where:{$0.address == address}) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);table.scrollRowToVisible(index) }
        selecting = false;loadSelectedCell()
    }
    @discardableResult func selectCell(sheetID:UUID,address:DefinitionCellAddress) -> Bool {
        guard !hasMarkedText,let owner = owners.first(where:{$0.sheets.contains{$0.id == sheetID}}) else { return false }
        selectedOwnerID = owner.id
        if let item = ownerPicker.itemArray.first(where:{($0.representedObject as? NSUUID) == owner.id as NSUUID}) { ownerPicker.select(item) }
        populateSheets(preferred:sheetID,address:address);return selectedAddress == address
    }
    private func clearDraft() { valueField.stringValue = "";formulaField.stringValue = "";unitField.stringValue = "" }
    private func loadSelectedCell() {
        selectedCell = cells.indices.contains(table.selectedRow) ? cells[table.selectedRow] : nil
        if let cell = selectedCell { valueField.stringValue = cell.value.value;formulaField.stringValue = cell.value.formula;unitField.stringValue = cell.value.unit }
        else { clearDraft() }
        availability = nil;refreshAvailability()
    }
    private func snapshotFailure(checkCell:Bool) -> String? {
        guard jobOwner.isActive,let drawing,let editor,editor.lifecycleJobs.isActive else { return "The drawing window is closed." }
        guard !drawing.isCalculating else { return "Wait for calculation to finish or cancel it." }
        guard let snapshot,let registry = drawing.diagram.definitions,let source = drawing.diagram.visioArchive else { return "Reload the public definition sheets." }
        guard snapshot.input.ownerID == drawing.lifecycleOwnerID,snapshot.input.snapshotID == drawing.stateID,snapshot.input.revision == drawing.revision,
              snapshot.resourceID == source.sourceResourceID,snapshot.lineageID == source.sourceLineageID,snapshot.registryID == registry.sourceDocumentID,snapshot.documentPart == registry.documentPart else {
            return "The drawing or source changed. Reload and review the current cell before applying."
        }
        guard let cell = selectedCell,let sheetID = selectedSheetID,let ownerID = selectedOwnerID else { return "Select an existing cell." }
        if checkCell {
            let sheet:DefinitionSheet?
            if ownerID == registry.sourceDocumentID { sheet = registry.documentSheet?.id == sheetID ? registry.documentSheet : nil }
            else { sheet = (registry.masters + registry.styles).first{$0.id == ownerID}?.sheets.first{$0.id == sheetID} }
            guard sheet?.cells.contains(where:{$0.id == cell.id && $0.address == cell.address && $0.value == cell.value}) == true else { return "The authored cell changed. Reload and review its current value." }
        }
        return nil
    }
    func refreshAvailability() {
        if let submitted,let drawing,!drawing.isCalculating {
            self.submitted = nil
            if drawing.lastCalculationJobError == nil,drawing.stateID != submitted.input.snapshotID {
                let sheetID = selectedSheetID,address = selectedAddress
                _ = reloadSnapshot(sheetID:sheetID,address:address);explain("Cell applied.");return
            }
            if let error = drawing.lastCalculationJobError { explain(error.localizedDescription) }
        }
        let composition = hasMarkedText || (drawing?.windowControllers.contains(where:{($0.window?.firstResponder as? NSTextView)?.hasMarkedText() == true}) ?? false)
        let key = Availability(active:jobOwner.isActive,visible:window?.isVisible == true,calculating:drawing?.isCalculating ?? false,stateID:drawing?.stateID,revision:drawing?.revision,resourceID:drawing?.diagram.visioArchive?.sourceResourceID,composition:composition,cellID:selectedCell?.id,draft:draft)
        guard key != availability else { return };availability = key
        let failure = snapshotFailure(checkCell:false)
        let editable = failure == nil && key.visible
        // Disabling an active field editor can finalize marked text. Leave its
        // native composition intact while disabling every submitting action.
        for field in [valueField,formulaField,unitField] { field.isEnabled = jobOwner.isActive && (editable || composition) }
        ownerPicker.isEnabled = jobOwner.isActive && !key.calculating && !composition
        sheetPicker.isEnabled = ownerPicker.isEnabled
        reloadButton.isEnabled = ownerPicker.isEnabled
        applyButton.isEnabled = editable && !composition && selectedCell?.value != draft
        if composition { explain("Finish text composition before applying a cell.") }
        else if let failure { explain(failure) }
        else if selectedCell?.value == draft { explain("Edit the selected cell's cached value, formula or unit, then apply it once.") }
        else { explain("Apply changes only the selected authored cell. Row and section editing is not available here.") }
    }
    @discardableResult func applySelectedCell() -> Bool {
        guard jobOwner.isActive,let editor,let drawing,window?.isVisible == true else { return false }
        if hasMarkedText || drawing.windowControllers.contains(where:{($0.window?.firstResponder as? NSTextView)?.hasMarkedText() == true}) {
            explain("Finish text composition before applying a cell.");return false
        }
        guard window?.makeFirstResponder(table) != false else { return false }
        drawing.commitTextEditing();editor.canvas.finishPageInteraction()
        if let failure = snapshotFailure(checkCell:true) {
            if !drawing.isCalculating { _ = reloadSnapshot(sheetID:selectedSheetID,address:selectedAddress) }
            explain(failure);applyButton.isEnabled = false;return false
        }
        guard let snapshot,let selectedCell,let sheetID = selectedSheetID,draft != selectedCell.value else { refreshAvailability();return false }
        let value = draft
        guard value.value.utf8.count <= VisioPackage.partLimit,value.formula.utf8.count <= 16384,value.unit.utf8.count <= 64 else {
            explain("The value, formula or unit exceeds the supported cell size.");return false
        }
        drawing.editDefinitionCell(sheetID:sheetID,address:selectedCell.address,value:value)
        guard drawing.isCalculating else { explain(drawing.lastCalculationJobError?.localizedDescription ?? "The cell was not submitted.");return false }
        submitted = snapshot;availability = nil;refreshAvailability();return true
    }
    func numberOfRows(in tableView:NSTableView) -> Int { cells.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard cells.indices.contains(row) else { return nil };let cell = cells[row]
        let text:String
        switch tableColumn?.identifier.rawValue {
        case "value":text = cell.value.value
        case "formula":text = cell.value.formula
        case "unit":text = cell.value.unit
        case "inheritance":text = cell.inherits ? "Inherits" : "Authored"
        default:text = Self.addressLabel(cell.address)
        }
        let label = NSTextField(labelWithString:text);label.lineBreakMode = .byTruncatingTail;label.toolTip = text;return label
    }
    func selectionShouldChange(in tableView:NSTableView) -> Bool { !hasMarkedText }
    func tableViewSelectionDidChange(_ notification:Notification) { if !selecting { loadSelectedCell() } }
    func controlTextDidChange(_ obj:Notification) { availability = nil;refreshAvailability() }
    private static func addressLabel(_ address:DefinitionCellAddress) -> String {
        var parts = [address.section.map{$0+(address.sectionIndex.map{"[\($0)]"} ?? "")} ?? "Root"]
        if let name = address.rowName { parts.append("Row \(name)"+(address.rowIndex.map{" [\($0)]"} ?? "")) }
        else if let index = address.rowIndex { parts.append("Row [\(index)]") }
        parts.append(address.cell);return parts.joined(separator:" · ")
    }
    @objc private func ownerChanged(_ sender:Any?) {
        guard !hasMarkedText,let id = ownerPicker.selectedItem?.representedObject as? NSUUID else { return }
        selectedOwnerID = id as UUID;populateSheets(preferred:nil,address:nil)
    }
    @objc private func sheetChanged(_ sender:Any?) {
        guard !hasMarkedText,let id = sheetPicker.selectedItem?.representedObject as? NSUUID else { return }
        selectedSheetID = id as UUID;populateCells(address:nil)
    }
    @objc private func applyCell(_ sender:Any?) { _ = applySelectedCell() }
    @objc private func reloadCells(_ sender:Any?) { _ = reloadSnapshot(sheetID:selectedSheetID,address:selectedAddress) }
    @objc private func closePanel(_ sender:Any?) { cancelOperation(sender) }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false;content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:16),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-16),stack.topAnchor.constraint(equalTo:content.topAnchor,constant:16),stack.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-16)])
        func row(_ views:[NSView]) -> NSStackView {
            let result = NSStackView(views:views);result.orientation = .horizontal;result.spacing = 8;result.alignment = .centerY;return result
        }
        ownerPicker.target = self;ownerPicker.action = #selector(ownerChanged(_:));ownerPicker.setAccessibilityLabel("Definition owner")
        sheetPicker.target = self;sheetPicker.action = #selector(sheetChanged(_:));sheetPicker.setAccessibilityLabel("Definition sheet")
        let selectors = row([NSTextField(labelWithString:"Owner"),ownerPicker,NSTextField(labelWithString:"Sheet"),sheetPicker])
        stack.addArrangedSubview(selectors);selectors.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        stack.addArrangedSubview(sourceLabel);sourceLabel.setAccessibilityLabel("Definition source")
        for (id,title,width) in [("address","Authored cell",300.0),("value","Cached value",150.0),("formula","Formula",220.0),("unit","Unit",70.0),("inheritance","State",85.0)] {
            let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));column.title = title;column.width = width;table.addTableColumn(column)
        }
        table.delegate = self;table.dataSource = self;table.usesAlternatingRowBackgroundColors = true;table.allowsMultipleSelection = false;table.rowHeight = 25;table.setAccessibilityLabel("Definition cells")
        let scroll = NSScrollView();scroll.documentView = table;scroll.hasVerticalScroller = true;scroll.hasHorizontalScroller = true;scroll.borderType = .bezelBorder
        stack.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:220).isActive = true
        for (label,field) in [("Cached value",valueField),("Formula",formulaField),("Unit",unitField)] {
            field.delegate = self;field.setAccessibilityLabel(label);field.font = .monospacedSystemFont(ofSize:12,weight:.regular)
            let labelView = NSTextField(labelWithString:label);labelView.widthAnchor.constraint(equalToConstant:100).isActive = true
            let line = row([labelView,field]);stack.addArrangedSubview(line);line.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(reasonLabel);reasonLabel.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true;reasonLabel.setAccessibilityLabel("Definition edit availability")
        applyButton.target = self;applyButton.action = #selector(applyCell(_:));applyButton.isEnabled = false
        reloadButton.target = self;reloadButton.action = #selector(reloadCells(_:))
        let close = NSButton(title:"Close",target:self,action:#selector(closePanel(_:)))
        let buttons = row([reloadButton,close,applyButton]);stack.addArrangedSubview(buttons)
    }
}
