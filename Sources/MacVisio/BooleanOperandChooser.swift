import AppKit
import MacVisioInfrastructure
import ObjectiveC

private var subtractChooserKey: UInt8 = 0

extension EditorWindowController {
    var hasMarkedBooleanOperandText: Bool {
        (objc_getAssociatedObject(self, &subtractChooserKey) as? BooleanOperandChooserController)?.hasMarkedText == true
    }
    var subtractionChooserController: BooleanOperandChooserController {
        if let value = objc_getAssociatedObject(self, &subtractChooserKey) as? BooleanOperandChooserController { return value }
        let value = BooleanOperandChooserController(editor: self)
        objc_setAssociatedObject(self, &subtractChooserKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }
    /// Call before the existing editor teardown closes its lifecycle owner.
    /// Avoid constructing a new controller while detaching a closed window.
    func detachBooleanOperandChooser() {
        (objc_getAssociatedObject(self, &subtractChooserKey) as? BooleanOperandChooserController)?.detachEditor()
        objc_setAssociatedObject(self, &subtractChooserKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

/// A weak-owned native chooser. A base must be reviewed explicitly because
/// the canvas selection is an unordered set and does not preserve click order.
final class BooleanOperandChooserController: NSWindowController, NSWindowDelegate {
    private struct Snapshot {
        let input: LifecycleJobInput
        let windowOwnerID: UUID
        let pageID: UUID
        let selected: Set<UUID>
        let selectedEdge: UUID?
    }
    private weak var editor: EditorWindowController?
    private weak var drawing: MacVisioDocument?
    private let jobOwner: LifecycleJobOwner
    private var snapshot: Snapshot?
    private var closeObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    let basePicker = NSPopUpButton()
    let explanation = NSTextField(wrappingLabelWithString: "Choose the shape to subtract from.")
    let applyButton = NSButton(title: "Subtract", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var selectedBaseID: UUID? { (basePicker.selectedItem?.representedObject as? NSUUID).map { $0 as UUID } }

    init(editor: EditorWindowController) {
        self.editor = editor; let owner = editor.lifecycleJobs; jobOwner = owner
        drawing = owner.isActive ? editor.diagramDocument : nil
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 540, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Subtract Shapes"; panel.isReleasedWhenClosed = false; panel.autorecalculatesKeyViewLoop = true
        super.init(window: panel); panel.delegate = self; panel.setAccessibilityIdentifier("MacVisioSubtractChooser")
        buildUI()
        if jobOwner.isActive, let parent = editor.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in self?.detachEditor() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { refreshTimer?.invalidate(); if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let label = NSTextField(labelWithString: "Subtract from:")
        label.frame = CGRect(x: 20, y: 164, width: 110, height: 24); content.addSubview(label)
        basePicker.frame = CGRect(x: 136, y: 160, width: 384, height: 30)
        let baseMenu = NSMenu(); baseMenu.autoenablesItems = false; basePicker.menu = baseMenu
        basePicker.target = self; basePicker.action = #selector(baseChanged(_:))
        basePicker.setAccessibilityLabel("Shape to subtract from"); content.addSubview(basePicker)
        explanation.frame = CGRect(x: 20, y: 68, width: 500, height: 76)
        explanation.setAccessibilityLabel("Subtract availability"); content.addSubview(explanation)
        applyButton.frame = CGRect(x: 400, y: 18, width: 120, height: 32); applyButton.bezelStyle = .rounded
        applyButton.target = self; applyButton.action = #selector(applyChoice(_:)); applyButton.keyEquivalent = "\r"; content.addSubview(applyButton)
        cancelButton.frame = CGRect(x: 270, y: 18, width: 120, height: 32); cancelButton.bezelStyle = .rounded
        cancelButton.target = self; cancelButton.action = #selector(cancelChoice(_:)); cancelButton.keyEquivalent = "\u{1b}"; content.addSubview(cancelButton)
    }

    @discardableResult func presentCurrentSelection() -> Bool {
        guard jobOwner.isActive, let editor, editor.lifecycleJobs.isActive, let drawing, let parent = editor.window, let panel = window else { return false }
        guard !hasMarkedText else { explanation.stringValue = "Finish text composition before Subtract."; return false }
        if let reason = editor.subtractUnavailableReason { editor.root.showMessage(reason); return false }
        let selected = editor.canvas.selectedNodes, nodes = drawing.diagram.page.nodes.filter { selected.contains($0.id) }
        guard nodes.count == 2 else { return false }
        snapshot = Snapshot(input: LifecycleJobInput(ownerID: drawing.lifecycleOwnerID, snapshotID: drawing.stateID, revision: drawing.revision),
                            windowOwnerID: editor.lifecycleJobs.id, pageID: drawing.diagram.activePageID,
                            selected: selected, selectedEdge: editor.canvas.selectedEdge)
        basePicker.removeAllItems()
        for node in nodes {
            let index = drawing.diagram.page.nodes.firstIndex { $0.id == node.id } ?? 0
            // NSPopUpButton.addItem(withTitle:) can replace an equal title.
            // Identity belongs to the UUID even when public labels collide.
            let item = NSMenuItem(title: "Shape \(node.formatting.sourceShapeID ?? String(index + 1)) · \(node.kind.title)", action: nil, keyEquivalent: "")
            item.representedObject = node.id as NSUUID; basePicker.menu?.addItem(item)
        }
        basePicker.selectItem(at: 0)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above); panel.center() }
        super.showWindow(nil); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(basePicker)
        refreshTimer?.invalidate(); refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshAvailability() }
        refreshAvailability(); return true
    }
    override func showWindow(_ sender: Any?) { _ = presentCurrentSelection() }

    var hasMarkedText: Bool {
        (window?.firstResponder as? NSTextView)?.hasMarkedText() == true || (editor?.window?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }
    var unavailableReason: String? {
        guard jobOwner.isActive, let editor, editor.lifecycleJobs.isActive, let drawing else { return "The drawing window is closed." }
        if hasMarkedText { return "Finish text composition before Subtract." }
        guard let snapshot else { return "Reopen Subtract Shapes to review the operands." }
        guard !drawing.isCalculating else { return "Wait for calculation to finish or cancel it." }
        guard snapshot.windowOwnerID == editor.lifecycleJobs.id, snapshot.input.ownerID == drawing.lifecycleOwnerID,
              snapshot.input.snapshotID == drawing.stateID, snapshot.input.revision == drawing.revision,
              snapshot.pageID == drawing.diagram.activePageID, snapshot.selected == editor.canvas.selectedNodes,
              snapshot.selectedEdge == editor.canvas.selectedEdge else {
            return "The drawing or selection changed. Reopen Subtract Shapes to review the current operands."
        }
        guard let baseID = selectedBaseID, snapshot.selected.contains(baseID) else { return "Choose one of the two selected shapes to subtract from." }
        return BooleanGeometry.unavailableReason(snapshot.selected, in: drawing.diagram, operation: .subtract(baseID: baseID))
    }
    func refreshAvailability() {
        let reason = unavailableReason
        applyButton.isEnabled = reason == nil; basePicker.isEnabled = reason == nil
        cancelButton.isEnabled = !hasMarkedText
        explanation.stringValue = reason ?? "The base keeps the filled area outside the other shape. The result uses the first operand’s fill, line and layer in drawing order."
    }
    @discardableResult func selectBase(_ id: UUID) -> Bool {
        guard !hasMarkedText, let item = basePicker.itemArray.first(where: { ($0.representedObject as? NSUUID) == (id as NSUUID) }) else { return false }
        basePicker.select(item); refreshAvailability(); return true
    }
    @discardableResult func applySelectedBase() -> Bool {
        if let reason = unavailableReason { explanation.stringValue = reason; return false }
        guard let snapshot, let baseID = selectedBaseID, let editor else { return false }
        close()
        return editor.submitSetOperation(.subtract(baseID: baseID), selected: snapshot.selected, expected: snapshot.input, pageID: snapshot.pageID)
    }
    @objc private func baseChanged(_ sender: Any?) { refreshAvailability() }
    @objc private func applyChoice(_ sender: Any?) { _ = applySelectedBase() }
    @objc private func cancelChoice(_ sender: Any?) { cancelOperation(sender) }
    override func cancelOperation(_ sender: Any?) { if !hasMarkedText { close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !hasMarkedText }
    func windowWillClose(_ notification: Notification) { resetPresentation() }
    private func resetPresentation() {
        refreshTimer?.invalidate(); refreshTimer = nil; snapshot = nil; basePicker.removeAllItems()
        if let window { window.parent?.removeChildWindow(window) }
    }
    override func close() { resetPresentation(); super.close() }
    func detachEditor() {
        close(); editor = nil; drawing = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver); self.closeObserver = nil }
    }
}
