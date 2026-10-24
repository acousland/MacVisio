import AppKit

/// Native controls expose every stored identity, including unavailable pins.
/// Retry never relinks a pin; Unpin removes only the selected stored key.
final class PinnedLibraryControls: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private weak var editor: EditorWindowController?
    private var coordinator: PinnedLibraryCoordinator?
    private var closeObserver: NSObjectProtocol?
    private(set) var rows: [PinnedLibraryRow] = []
    let table = NSTableView()
    let detail = NSTextField(wrappingLabelWithString: "")
    let retryButton = NSButton(title: "Retry Pinned Stencils", target: nil, action: nil)
    let removeButton = NSButton(title: "Unpin Selected", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel Loading", target: nil, action: nil)
    var selectedReference: PinnedLibraryReference? { rows.indices.contains(table.selectedRow) ? rows[table.selectedRow].reference : nil }
    var hasMarkedText: Bool {
        (window?.firstResponder as? NSTextView)?.hasMarkedText() == true || (editor?.window?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }

    init(editor: EditorWindowController, coordinator: PinnedLibraryCoordinator) {
        self.editor = editor; self.coordinator = coordinator
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 740, height: 460), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Pinned Libraries"; panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 640, height: 420)
        super.init(window: panel); panel.delegate = self
        panel.setAccessibilityIdentifier("MacVisioPinnedLibraries")
        buildUI(); coordinator.onChange = { [weak self] in self?.refresh() }
        if let parent = editor.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in self?.detach() }
        }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let note = NSTextField(wrappingLabelWithString: "Pinned public VSSX stencils load into Shapes automatically. Master pins load only their public IDs. Templates and binary stencils require an explicit Open.")
        note.frame = CGRect(x: 20, y: 398, width: 700, height: 46); note.autoresizingMask = [.width, .minYMargin]; content.addSubview(note)
        let scroll = NSScrollView(frame: CGRect(x: 20, y: 176, width: 700, height: 210))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        scroll.autoresizingMask = [.width, .height]; content.addSubview(scroll)
        for (identifier, title, width) in [("pin", "Pinned source / master", 240.0), ("status", "Status", 430.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 28; table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityLabel("Pinned library availability")
        detail.frame = CGRect(x: 20, y: 64, width: 700, height: 98); detail.autoresizingMask = [.width]; detail.font = .systemFont(ofSize: 11); detail.isSelectable = true
        detail.setAccessibilityLabel("Selected pin path and availability"); content.addSubview(detail)
        for (button, x, width, action) in [(retryButton, 20.0, 180.0, #selector(retry(_:))), (removeButton, 212.0, 144.0, #selector(remove(_:))), (cancelButton, 368.0, 154.0, #selector(cancelLoading(_:)))] {
            button.frame = CGRect(x: x, y: 18, width: width, height: 32); button.bezelStyle = .rounded; button.target = self; button.action = action; content.addSubview(button)
        }
    }
    override func showWindow(_ sender: Any?) {
        guard let editor, editor.lifecycleJobs.isActive, !hasMarkedText else { return }
        refresh()
        if let panel = window, let parent = editor.window, panel.parent == nil { parent.addChildWindow(panel, ordered: .above); panel.center() }
        super.showWindow(sender)
    }
    func refresh() {
        guard let coordinator else { return }
        let selected = selectedReference
        rows = coordinator.rows; table.reloadData()
        if let index = selected.flatMap({ selected in rows.firstIndex { $0.reference == selected } }) ?? (rows.isEmpty ? nil : 0) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        updateSelection()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let row = rows[row], text = tableColumn?.identifier.rawValue == "status" ? row.status.text : row.reference.title
        let label = NSTextField(labelWithString: text); label.lineBreakMode = .byTruncatingTail
        label.toolTip = row.reference.key + "\n" + row.status.text
        label.setAccessibilityLabel(row.reference.title + ", " + row.status.text + ", " + row.reference.key)
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateSelection() }
    private func updateSelection() {
        guard let coordinator else { return }
        let row = rows.indices.contains(table.selectedRow) ? rows[table.selectedRow] : nil
        detail.stringValue = row.map { [$0.reference.source?.url.path ?? $0.reference.key, $0.status.text] + $0.notes }.map { $0.joined(separator: "\n") } ?? "No pins. Use Pin in the library browser or Pin Master in Shapes."
        retryButton.isEnabled = !coordinator.isLoading && !rows.isEmpty
        removeButton.isEnabled = row != nil
        cancelButton.isEnabled = coordinator.isLoading
    }
    @discardableResult func retryPins() -> Bool {
        guard !hasMarkedText, let editor, editor.lifecycleJobs.isActive, let coordinator else { return refuseComposition() }
        coordinator.reload(); return true
    }
    @discardableResult func removeSelectedPin() -> Bool {
        guard !hasMarkedText, let editor, editor.lifecycleJobs.isActive, let coordinator,
              let selected = selectedReference, selected.isPresent(in: coordinator.pins.snapshot) else { return refuseComposition() }
        do { try coordinator.pins.remove(selected); return true }
        catch { detail.stringValue = error.localizedDescription; return false }
    }
    private func refuseComposition() -> Bool {
        if hasMarkedText { detail.stringValue = "Finish text composition before changing pinned libraries." }
        return false
    }
    @objc private func retry(_ sender: Any?) { _ = retryPins() }
    @objc private func remove(_ sender: Any?) { _ = removeSelectedPin() }
    @objc private func cancelLoading(_ sender: Any?) { coordinator?.cancel() }
    func detach() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
        coordinator?.onChange = nil; coordinator = nil; editor = nil
        table.delegate = nil; table.dataSource = nil; rows = []; table.reloadData()
        [retryButton, removeButton, cancelButton].forEach { $0.target = nil; $0.isEnabled = false }
        if let window { window.parent?.removeChildWindow(window); window.orderOut(nil) }
    }
}
