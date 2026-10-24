import AppKit
import MacVisioInfrastructure
import UniformTypeIdentifiers

enum StencilPackageCloseDecision { case cancel, discard, saveAs }

/// A separate, reversible package draft. No drawing document or imported
/// stencil cards are mutated, and the source file is never a save destination.
final class StencilPackageEditorController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private struct CellKey: Hashable {
        var masterID: UInt32
        var shapeID: String
        var address: DefinitionCellAddress
    }
    let sourceURL: URL
    var onClose: ((StencilPackageEditorController) -> Void)?
    /// Native decision seams allow close/cancel/save tests without modal alerts.
    var closeDecision: (() -> StencilPackageCloseDecision)?
    var saveDestination: (() -> URL?)?
    private(set) var snapshot: StencilPackageSnapshot?
    private var openedSnapshot: StencilPackageSnapshot?
    private var openedStateID = UUID()
    private var savedStateID: UUID?
    private(set) var stateID = UUID()
    private(set) var revision: UInt64 = 0
    private(set) var isBusy = false
    private(set) var selectedMasterID: UInt32?
    private(set) var selectedCell: StencilPackageCell?
    private(set) var lastSavedURL: URL?
    private let jobOwner = LifecycleJobOwner()
    private var pending: LifecycleJobHandle?
    private var requestID: UUID?
    private var selecting = false
    private var nameDrafts: [UInt32: String] = [:]
    private var cellDrafts: [CellKey: String] = [:]
    private var undoCharge = 0
    private let maximumUndoCharge: Int
    let draftUndoManager = UndoManager()
    let masterTable = NSTableView()
    let cellTable = NSTableView()
    let sourceLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "Reading custom stencil…")
    let nameField = NSTextField(string: "")
    let renameButton = NSButton(title: "Rename", target: nil, action: nil)
    let duplicateButton = NSButton(title: "Duplicate", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let upButton = NSButton(title: "Move Up", target: nil, action: nil)
    let downButton = NSButton(title: "Move Down", target: nil, action: nil)
    let cellLabel = NSTextField(wrappingLabelWithString: "Select an existing literal cell.")
    let valueField = NSTextField(string: "")
    let applyButton = NSButton(title: "Apply Literal", target: nil, action: nil)
    let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    let redoButton = NSButton(title: "Redo", target: nil, action: nil)
    let revertButton = NSButton(title: "Revert to Opened Source", target: nil, action: nil)
    let cancelJobButton = NSButton(title: "Cancel Operation", target: nil, action: nil)
    let saveAsButton = NSButton(title: "Save As…", target: nil, action: nil)

    convenience init(sourceURL: URL) {
        self.init(sourceURL: sourceURL, snapshot: nil)
        loadSource()
    }
    init(sourceURL: URL, snapshot: StencilPackageSnapshot?, maximumUndoCharge: Int = ResourceBudgets.undoPayload) {
        self.sourceURL = sourceURL.standardizedFileURL
        self.maximumUndoCharge = max(1, min(maximumUndoCharge, ResourceBudgets.undoPayload))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Custom Stencil — \(sourceURL.lastPathComponent)"
        window.isReleasedWhenClosed = false; window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self; window.setAccessibilityIdentifier("MacVisioCustomStencilEditor")
        draftUndoManager.groupsByEvent = false; draftUndoManager.levelsOfUndo = ResourceBudgets.undoCount
        buildUI()
        if let snapshot { installOpened(snapshot) }
        else { refresh() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var currentInput: LifecycleJobInput { LifecycleJobInput(ownerID: jobOwner.id, snapshotID: stateID, revision: revision) }
    var hasMarkedText: Bool { (window?.firstResponder as? NSTextView)?.hasMarkedText() == true }
    var isDirty: Bool { snapshot != nil && (stateID != savedStateID || !nameDrafts.isEmpty || !cellDrafts.isEmpty) }
    private var selectedMaster: StencilPackageMaster? { snapshot?.masters.first { $0.id == selectedMasterID } }
    private var cellKey: CellKey? { selectedMasterID.flatMap { master in selectedCell.map { CellKey(masterID: master, shapeID: $0.shapeID, address: $0.address) } } }

    private func buildUI() {
        guard let window else { return }
        let content = FlippedView(frame: NSRect(x: 0, y: 0, width: 900, height: 680)); window.contentView = content
        sourceLabel.stringValue = sourceURL.path; sourceLabel.toolTip = sourceURL.path
        sourceLabel.lineBreakMode = .byTruncatingMiddle; sourceLabel.frame = NSRect(x: 16, y: 12, width: 864, height: 22)
        statusLabel.frame = NSRect(x: 16, y: 38, width: 864, height: 36)
        content.addSubview(sourceLabel); content.addSubview(statusLabel)
        configureTable(masterTable, columns: [("name", "Master / public ID", 280)], frame: NSRect(x: 16, y: 78, width: 300, height: 342), in: content)
        configureTable(cellTable, columns: [("cell", "Source cell", 280), ("value", "Value", 100), ("formula", "Formula / unit", 150)], frame: NSRect(x: 330, y: 78, width: 550, height: 342), in: content)
        masterTable.setAccessibilityLabel("Custom stencil masters in public order")
        cellTable.setAccessibilityLabel("Selected master source cells")
        let nameLabel = NSTextField(labelWithString: "Display name (public identity stays unchanged):")
        nameLabel.frame = NSRect(x: 16, y: 432, width: 300, height: 20); content.addSubview(nameLabel)
        nameField.frame = NSRect(x: 16, y: 457, width: 300, height: 24); nameField.delegate = self
        nameField.setAccessibilityLabel("Master display name"); content.addSubview(nameField)
        add(renameButton, action: #selector(renameStencilMaster(_:)), frame: NSRect(x: 16, y: 490, width: 90, height: 28), to: content)
        add(duplicateButton, action: #selector(duplicateStencilMaster(_:)), frame: NSRect(x: 111, y: 490, width: 100, height: 28), to: content)
        add(deleteButton, action: #selector(deleteStencilMaster(_:)), frame: NSRect(x: 216, y: 490, width: 100, height: 28), to: content)
        add(upButton, action: #selector(moveStencilMasterUp(_:)), frame: NSRect(x: 16, y: 529, width: 105, height: 28), to: content)
        add(downButton, action: #selector(moveStencilMasterDown(_:)), frame: NSRect(x: 126, y: 529, width: 115, height: 28), to: content)
        cellLabel.frame = NSRect(x: 330, y: 432, width: 550, height: 46); content.addSubview(cellLabel)
        valueField.frame = NSRect(x: 330, y: 485, width: 550, height: 24); valueField.delegate = self
        valueField.setAccessibilityLabel("Literal cell value"); content.addSubview(valueField)
        add(applyButton, action: #selector(applyStencilLiteral(_:)), frame: NSRect(x: 330, y: 520, width: 130, height: 28), to: content)
        let note = NSTextField(wrappingLabelWithString: "Save As writes a public VSSX copy. The opened file stays unchanged. Formula, inherited-cell and visual master editing are unavailable here; shared and opaque package parts are retained.")
        note.frame = NSRect(x: 16, y: 580, width: 864, height: 38); note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor; content.addSubview(note)
        add(undoButton, action: #selector(undoStencilEdit(_:)), frame: NSRect(x: 16, y: 633, width: 75, height: 28), to: content)
        add(redoButton, action: #selector(redoStencilEdit(_:)), frame: NSRect(x: 96, y: 633, width: 75, height: 28), to: content)
        add(revertButton, action: #selector(revertStencilDraft(_:)), frame: NSRect(x: 180, y: 633, width: 190, height: 28), to: content)
        add(cancelJobButton, action: #selector(cancelStencilOperation(_:)), frame: NSRect(x: 380, y: 633, width: 145, height: 28), to: content)
        add(saveAsButton, action: #selector(saveStencilCopy(_:)), frame: NSRect(x: 765, y: 633, width: 115, height: 28), to: content)
    }
    private func configureTable(_ table: NSTableView, columns: [(String, String, Double)], frame: NSRect, in content: NSView) {
        for (id, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width
            table.addTableColumn(column)
        }
        table.frame = NSRect(origin: .zero, size: frame.size); table.dataSource = self; table.delegate = self
        table.allowsEmptySelection = false; table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(frame: frame); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.documentView = table; content.addSubview(scroll)
    }
    private func add(_ button: NSButton, action: Selector, frame: NSRect, to content: NSView) {
        button.frame = frame; button.target = self; button.action = action; button.bezelStyle = .rounded; content.addSubview(button)
    }

    private func loadSource() {
        let input = currentInput, request = UUID(); requestID = request; isBusy = true; refresh()
        do {
            pending = try StencilPackageJobs.load(sourceURL: sourceURL, input: input, owner: jobOwner,
                accepts: { [weak self] in self?.accepts($0) == true }, progress: { [weak self] in self?.explain($0.stage) }) { [weak self] result in
                guard let self, self.requestID == request else { return }
                self.pending = nil; self.requestID = nil; self.isBusy = false
                switch result {
                case .success(let source): self.installOpened(source)
                case .failure(let error): self.explain(error.localizedDescription); self.refresh()
                }
            }
        } catch { isBusy = false; requestID = nil; explain(error.localizedDescription); refresh() }
    }
    private func installOpened(_ source: StencilPackageSnapshot) {
        snapshot = source; openedSnapshot = source; stateID = UUID(); openedStateID = stateID; savedStateID = stateID; revision &+= 1
        selectedMasterID = source.masters.first?.id; selectedCell = nil; nameDrafts = [:]; cellDrafts = [:]
        draftUndoManager.removeAllActions(); undoCharge = 0
        explain("Select a master to rename, duplicate, reorder or inspect its existing literal cells."); refresh()
    }
    private func accepts(_ input: LifecycleJobInput) -> Bool { jobOwner.isActive && currentInput == input }
    private func finalizeFields() -> Bool {
        guard !hasMarkedText else { explain("Finish text composition before changing the stencil draft."); return false }
        guard window?.makeFirstResponder(nil) != false else { return false }
        captureDrafts(); return true
    }
    private func captureDrafts() {
        if let master = selectedMaster {
            if nameField.stringValue == master.name { nameDrafts.removeValue(forKey: master.id) }
            else { nameDrafts[master.id] = nameField.stringValue }
        }
        if let key = cellKey, let selectedCell {
            if valueField.stringValue == selectedCell.value.value { cellDrafts.removeValue(forKey: key) }
            else { cellDrafts[key] = valueField.stringValue }
        }
        window?.isDocumentEdited = isDirty
    }
    func controlTextDidChange(_ obj: Notification) { captureDrafts(); revision &+= 1; updateButtons() }

    @discardableResult
    func submit(_ edit: StencilPackageEdit, expectedInput: LifecycleJobInput) -> Bool {
        guard !isBusy, accepts(expectedInput), let before = snapshot else {
            explain("The stencil draft changed or an operation is running. Review the current selection and try again."); return false
        }
        let previousState = stateID, selected = selectedMasterID, request = UUID()
        requestID = request; isBusy = true; refresh()
        do {
            pending = try StencilPackageJobs.edit(edit, snapshot: before, input: expectedInput, owner: jobOwner,
                accepts: { [weak self] in self?.accepts($0) == true }, progress: { [weak self] in self?.explain($0.stage) }) { [weak self] result in
                guard let self, self.requestID == request else { return }
                self.pending = nil; self.requestID = nil; self.isBusy = false
                switch result {
                case .success(let next):
                    if next.resourceID != before.resourceID {
                        let charge = max(before.byteCount, next.byteCount)
                        guard charge <= self.maximumUndoCharge else {
                            self.explain("This edit exceeds the stencil undo budget. The draft and undo history are unchanged."); self.refresh(); return
                        }
                        if self.undoCharge > self.maximumUndoCharge - charge {
                            self.draftUndoManager.removeAllActions(); self.undoCharge = 0
                        }
                        self.undoCharge += charge
                        self.draftUndoManager.beginUndoGrouping()
                        self.draftUndoManager.registerUndo(withTarget: self) { $0.restore(before, stateID: previousState, selection: selected) }
                        self.draftUndoManager.setActionName("Edit Custom Stencil"); self.draftUndoManager.endUndoGrouping()
                        self.snapshot = next; self.stateID = UUID(); self.revision &+= 1
                        if case .duplicate = edit { self.selectedMasterID = next.masters.last?.id }
                    }
                    self.explain("Stencil draft updated. Save As writes an edited copy."); self.refresh()
                case .failure(let error): self.explain(error.localizedDescription); self.refresh()
                }
            }
            return true
        } catch { isBusy = false; requestID = nil; explain(error.localizedDescription); refresh(); return false }
    }
    private func restore(_ target: StencilPackageSnapshot, stateID targetState: UUID, selection: UInt32?) {
        guard jobOwner.isActive, !isBusy, let current = snapshot else { return }
        let currentState = stateID, currentSelection = selectedMasterID
        draftUndoManager.registerUndo(withTarget: self) { $0.restore(current, stateID: currentState, selection: currentSelection) }
        snapshot = target; stateID = targetState; revision &+= 1; selectedMasterID = selection
        nameDrafts = [:]; cellDrafts = [:]; explain("Restored stencil draft."); refresh()
    }
    @objc private func renameStencilMaster(_ sender: Any?) {
        guard !isBusy, finalizeFields(), let id = selectedMasterID else { return }
        _ = submit(.rename(masterID: id, name: nameField.stringValue), expectedInput: currentInput)
    }
    @objc private func duplicateStencilMaster(_ sender: Any?) {
        guard !isBusy, finalizeFields(), let master = selectedMaster else { return }
        guard nameDrafts.isEmpty, cellDrafts.isEmpty else { explain("Apply or Revert pending fields before duplicating a master."); return }
        _ = submit(.duplicate(masterID: master.id, name: master.name + " Copy"), expectedInput: currentInput)
    }
    @objc private func deleteStencilMaster(_ sender: Any?) {
        guard !isBusy, finalizeFields(), let id = selectedMasterID else { return }
        guard nameDrafts.isEmpty, cellDrafts.isEmpty else { explain("Apply or Revert pending fields before deleting a master."); return }
        _ = submit(.delete(masterID: id), expectedInput: currentInput)
    }
    @objc private func moveStencilMasterUp(_ sender: Any?) { moveSelected(by: -1) }
    @objc private func moveStencilMasterDown(_ sender: Any?) { moveSelected(by: 1) }
    private func moveSelected(by delta: Int) {
        guard !isBusy, finalizeFields(), let snapshot, let id = selectedMasterID,
              let index = snapshot.masters.firstIndex(where: { $0.id == id }), snapshot.masters.indices.contains(index + delta) else { return }
        _ = submit(.move(masterID: id, toIndex: index + delta), expectedInput: currentInput)
    }
    @objc private func applyStencilLiteral(_ sender: Any?) {
        guard !isBusy, finalizeFields(), let id = selectedMasterID, let cell = selectedCell else { return }
        _ = submit(.literal(masterID: id, shapeID: cell.shapeID, address: cell.address, expected: cell.value, value: valueField.stringValue), expectedInput: currentInput)
    }
    @objc private func undoStencilEdit(_ sender: Any?) {
        guard jobOwner.isActive, !isBusy, finalizeFields(), nameDrafts.isEmpty, cellDrafts.isEmpty else { explain("Apply or Revert pending fields before Undo."); return }
        draftUndoManager.undo(); updateButtons()
    }
    @objc private func redoStencilEdit(_ sender: Any?) {
        guard jobOwner.isActive, !isBusy, finalizeFields(), nameDrafts.isEmpty, cellDrafts.isEmpty else { explain("Apply or Revert pending fields before Redo."); return }
        draftUndoManager.redo(); updateButtons()
    }
    @objc private func revertStencilDraft(_ sender: Any?) { revertDraft() }
    func revertDraft() {
        guard jobOwner.isActive else { return }
        guard !isBusy else { explain("Cancel the current operation, wait for cleanup, then Revert the draft."); return }
        guard !hasMarkedText, let openedSnapshot else { explain("Finish text composition before reverting the draft."); return }
        snapshot = openedSnapshot; stateID = openedStateID; revision &+= 1; nameDrafts = [:]; cellDrafts = [:]
        draftUndoManager.removeAllActions(); undoCharge = 0; selectedCell = nil
        explain("Reverted to the opened source. The source file is unchanged."); refresh()
    }
    @objc private func cancelStencilOperation(_ sender: Any?) { pending?.cancel(); explain("Cancelling stencil operation…") }
    @objc private func saveStencilCopy(_ sender: Any?) { beginSaveAs() }
    func beginSaveAs() {
        guard !isBusy, finalizeFields(), snapshot != nil else { return }
        guard nameDrafts.isEmpty, cellDrafts.isEmpty else { explain("Apply or Revert pending fields before Save As."); return }
        let input = currentInput
        if let choose = saveDestination {
            if let destination = choose() { _ = saveCopy(to: destination, expectedInput: input) }
            else { explain("Save As cancelled. The draft is retained.") }
            return
        }
        guard let window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "vssx") ?? .data]
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + " Edited.vssx"
        panel.message = "Save the edited stencil as a copy. Choose a different path from the opened source."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            _ = self?.saveCopy(to: destination, expectedInput: input)
        }
    }
    @discardableResult
    func saveCopy(to destination: URL, expectedInput: LifecycleJobInput) -> Bool {
        guard !isBusy, accepts(expectedInput), let source = snapshot, !hasMarkedText,
              nameDrafts.isEmpty, cellDrafts.isEmpty else { explain("The stencil draft changed. Review it before Save As."); return false }
        let request = UUID(); requestID = request; isBusy = true; refresh()
        do {
            pending = try StencilPackageJobs.saveCopy(source, to: destination, input: expectedInput, owner: jobOwner,
                accepts: { [weak self] in self?.accepts($0) == true }, progress: { [weak self] in self?.explain($0.stage) }) { [weak self] result in
                guard let self, self.requestID == request else { return }
                self.pending = nil; self.requestID = nil; self.isBusy = false
                switch result {
                case .success(let url): self.savedStateID = expectedInput.snapshotID; self.lastSavedURL = url; self.explain("Saved edited copy: \(url.lastPathComponent)")
                case .failure(let error): self.explain(error.localizedDescription)
                }; self.refresh()
            }; return true
        } catch { isBusy = false; requestID = nil; explain(error.localizedDescription); refresh(); return false }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === masterTable ? snapshot?.masters.count ?? 0 : selectedMaster?.cells.count ?? 0 }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        if tableView === masterTable {
            guard let masters = snapshot?.masters, masters.indices.contains(row) else { return nil }
            return "\(masters[row].name) — ID \(masters[row].sourceID)"
        }
        guard let cells = selectedMaster?.cells, cells.indices.contains(row) else { return nil }
        let cell = cells[row]
        switch tableColumn?.identifier.rawValue {
        case "value": return cell.value.value
        case "formula": return [cell.value.formula, cell.value.unit].filter { !$0.isEmpty }.joined(separator: " · ")
        default: return cell.title
        }
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard !isBusy, !hasMarkedText else { return false }
        if !selecting, (!nameDrafts.isEmpty || !cellDrafts.isEmpty), tableView.selectedRow != row {
            explain("Apply or Revert pending fields before changing the selected source owner."); return false
        }
        return true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting else { return }
        if (notification.object as? NSTableView) === masterTable {
            guard let masters = snapshot?.masters, masters.indices.contains(masterTable.selectedRow) else { return }
            selectedMasterID = masters[masterTable.selectedRow].id; selectedCell = nil; refresh()
        } else if let cells = selectedMaster?.cells, cells.indices.contains(cellTable.selectedRow) {
            selectedCell = cells[cellTable.selectedRow]; refreshFields(); updateButtons()
        }
    }
    private func refresh() {
        selecting = true; defer { selecting = false }
        if let snapshot {
            nameDrafts = nameDrafts.filter { id, value in snapshot.masters.first(where: { $0.id == id }).map { $0.name != value } == true }
            cellDrafts = cellDrafts.filter { key, value in snapshot.masters.first(where: { $0.id == key.masterID })?.cells.first(where: { $0.shapeID == key.shapeID && $0.address == key.address }).map { $0.value.value != value } == true }
            if !snapshot.masters.contains(where: { $0.id == selectedMasterID }) { selectedMasterID = snapshot.masters.first?.id; selectedCell = nil }
        }
        masterTable.reloadData()
        if let row = snapshot?.masters.firstIndex(where: { $0.id == selectedMasterID }) { masterTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        cellTable.reloadData()
        if let cells = selectedMaster?.cells, !cells.isEmpty {
            let row = selectedCell.flatMap { old in cells.firstIndex { $0.shapeID == old.shapeID && $0.address == old.address } } ?? 0
            selectedCell = cells[row]; cellTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else { selectedCell = nil }
        refreshFields(); updateButtons()
    }
    private func refreshFields() {
        nameField.stringValue = selectedMaster.map { nameDrafts[$0.id] ?? $0.name } ?? ""
        valueField.stringValue = cellKey.flatMap { cellDrafts[$0] } ?? selectedCell?.value.value ?? ""
        cellLabel.stringValue = selectedCell.map { $0.title + "\n" + ($0.refusal ?? "Change this existing literal value only; its unit and source attributes are retained.") } ?? "Select an existing literal cell."
    }
    private func updateButtons() {
        let editable = jobOwner.isActive && !isBusy && selectedMaster != nil
        masterTable.isEnabled = !isBusy; cellTable.isEnabled = editable
        nameField.isEnabled = editable; renameButton.isEnabled = editable; duplicateButton.isEnabled = editable && (snapshot?.masters.count ?? 1000) < 1000
        deleteButton.isEnabled = editable && (snapshot?.masters.count ?? 0) > 1
        let index = snapshot?.masters.firstIndex { $0.id == selectedMasterID }
        upButton.isEnabled = editable && (index ?? 0) > 0
        downButton.isEnabled = editable && index.map { $0 + 1 < (snapshot?.masters.count ?? 0) } == true
        valueField.isEnabled = editable && selectedCell?.refusal == nil && selectedCell != nil; applyButton.isEnabled = valueField.isEnabled
        undoButton.isEnabled = !isBusy && draftUndoManager.canUndo; redoButton.isEnabled = !isBusy && draftUndoManager.canRedo
        revertButton.isEnabled = openedSnapshot != nil && isDirty && !isBusy; cancelJobButton.isEnabled = isBusy
        saveAsButton.isEnabled = jobOwner.isActive && !isBusy && snapshot != nil
        window?.isDocumentEdited = isDirty
    }
    private func explain(_ message: String) { statusLabel.stringValue = message }

    func confirmCanCloseForTermination() -> Bool {
        guard finalizeFields() else { return false }
        guard isDirty || isBusy else { return true }
        let decision: StencilPackageCloseDecision
        if let choose = closeDecision { decision = choose() }
        else {
            let alert = NSAlert(); alert.messageText = isBusy ? "Close this stencil operation?" : "Save the edited stencil copy before closing?"
            alert.informativeText = isBusy ? "Discard cancels the current operation and closes this draft. The opened source stays unchanged." : "Save As keeps the draft in a different VSSX file. Discard closes it without changing the opened source."
            alert.addButton(withTitle: "Cancel"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Save As…")
            let response = alert.runModal()
            decision = response == .alertSecondButtonReturn ? .discard : response == .alertThirdButtonReturn ? .saveAs : .cancel
        }
        switch decision {
        case .cancel: return false
        case .discard:
            if isBusy {
                pending?.cancel(); explain("Cancellation requested. Close this draft after the operation finishes cleaning up.")
                return false
            }
            return true
        case .saveAs:
            if isBusy { explain("Cancel or finish the current operation before Save As.") }
            else { beginSaveAs() }
            return false
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmCanCloseForTermination() }
    func windowWillClose(_ notification: Notification) {
        jobOwner.close(); pending = nil; requestID = nil; isBusy = false
        draftUndoManager.removeAllActions(); undoCharge = 0
        snapshot = nil; openedSnapshot = nil; selectedCell = nil; selectedMasterID = nil
        nameDrafts = [:]; cellDrafts = [:]; revision &+= 1
        nameField.stringValue = ""; valueField.stringValue = ""
        masterTable.reloadData(); cellTable.reloadData(); updateButtons()
        saveDestination = nil; closeDecision = nil
        onClose?(self); onClose = nil
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { isBusy || !nameDrafts.isEmpty || !cellDrafts.isEmpty ? nil : draftUndoManager }
    override func close() { if confirmCanCloseForTermination() { super.close() } }
    override func cancelOperation(_ sender: Any?) { window?.performClose(sender) }
}
