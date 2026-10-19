import AppKit
import MacVisioInfrastructure
import ObjectiveC

private var membershipEditorKey: UInt8 = 0

private func membershipHasMarkedText(_ drawing: MacVisioDocument) -> Bool {
    var pending = drawing.windowControllers.compactMap(\.window), visited = Set<ObjectIdentifier>()
    while let window = pending.popLast() {
        guard visited.insert(ObjectIdentifier(window)).inserted else { continue }
        if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return true }
        pending += window.childWindows ?? []
        if let sheet = window.attachedSheet { pending.append(sheet) }
    }
    return false
}

extension EditorWindowController {
    var membershipController: MembershipEditorController {
        if let current = objc_getAssociatedObject(self, &membershipEditorKey) as? MembershipEditorController, !current.isClosed { return current }
        let controller = MembershipEditorController(editor: self)
        objc_setAssociatedObject(self, &membershipEditorKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }
    var membershipUnavailableReason: String? {
        guard lifecycleJobs.isActive else { return "The drawing window is closed." }
        guard !diagramDocument.isCalculating else { return "Wait for calculation to finish or cancel it." }
        if membershipHasMarkedText(diagramDocument) {
            return "Finish text composition before opening Memberships."
        }
        return nil
    }
    @objc func showMemberships(_ sender: Any?) {
        if let reason = membershipUnavailableReason { root.showMessage(reason); return }
        let controller = membershipController
        guard !controller.hasMarkedText, window?.makeFirstResponder(canvas) != false else {
            root.showMessage("Finish text composition before opening Memberships."); return
        }
        diagramDocument.commitTextEditing(); canvas.finishPageInteraction()
        if let reason = membershipUnavailableReason { root.showMessage(reason); return }
        guard !canvas.isEditingText else { root.showMessage("Finish text editing before opening Memberships."); return }
        controller.showWindow(sender)
    }
}

/// One explicit reciprocal edge per Apply. The immutable document snapshot is
/// processed on an owned worker; UI choices never mutate committed page arrays.
final class MembershipEditorController: NSWindowController, NSWindowDelegate {
    static let maximumMenuEntries = 2_000
    private struct Snapshot: Equatable {
        let documentOwnerID: UUID
        let input: LifecycleJobInput
        let pageID: UUID
        let selectedNodes: Set<UUID>
        let selectedEdge: UUID?
        let sourceID: UUID?
        let lineageID: UUID?
    }
    private weak var editor: EditorWindowController?
    private weak var drawing: MacVisioDocument?
    private let jobOwner = LifecycleJobOwner()
    private var parentObserver: NSObjectProtocol?
    private var timer: Timer?
    private var snapshot: Snapshot?
    private var index: DiagramMemberships.Index?
    private var pendingLoad: LifecycleJobHandle?
    private var submittedCalculationID: UUID?
    var beforePreparation: ((LifecycleJobCancellation) throws -> Void)?
    private(set) var isClosed = false
    private(set) var entries: [DiagramMemberships.Entry] = []
    private(set) var containers: [DiagramMemberships.Entry] = []
    let memberPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let containerPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let operationPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let summaryLabel = NSTextField(wrappingLabelWithString: "")
    let reasonLabel = NSTextField(wrappingLabelWithString: "Choose an explicit container and member.")
    let applyButton = NSButton(title: "Apply Membership", target: nil, action: nil)
    let reloadButton = NSButton(title: "Reload", target: nil, action: nil)
    let cancelJobButton = NSButton(title: "Cancel Pending Edit", target: nil, action: nil)
    var isBusy: Bool { pendingLoad != nil || submittedCalculationID != nil }
    var hasMarkedText: Bool {
        (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
            || drawing.map(membershipHasMarkedText) == true
    }
    var selectedMemberID: UUID? { (memberPicker.selectedItem?.representedObject as? NSUUID).map { $0 as UUID } }
    var selectedContainerID: UUID? { (containerPicker.selectedItem?.representedObject as? NSUUID).map { $0 as UUID } }
    var includesMember: Bool { operationPicker.indexOfSelectedItem == 0 }

    init(editor: EditorWindowController) {
        self.editor = editor; drawing = editor.diagramDocument
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 680, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Memberships"; panel.isReleasedWhenClosed = false
        super.init(window: panel); panel.delegate = self
        panel.setAccessibilityIdentifier("MacVisioMemberships")
        buildUI()
        if let parent = editor.window {
            parentObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in self?.detach() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); if let parentObserver { NotificationCenter.default.removeObserver(parentObserver) } }
    override func showWindow(_ sender: Any?) {
        guard !isClosed, jobOwner.isActive, let parent = editor?.window, let window else { return }
        if window.parent == nil { parent.addChildWindow(window, ordered: .above); window.center() }
        super.showWindow(sender); window.makeKeyAndOrderFront(sender)
        timer?.invalidate(); timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.refreshAvailability() }
        _ = reloadSnapshot()
    }
    override func close() {
        guard !hasMarkedText else { reasonLabel.stringValue = "Finish text composition before closing Memberships."; return }
        super.close()
    }
    override func cancelOperation(_ sender: Any?) { close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if hasMarkedText { reasonLabel.stringValue = "Finish text composition before closing Memberships."; return false }; return true
    }
    func windowWillClose(_ notification: Notification) { detach() }
    private func detach() {
        guard !isClosed else { return }
        isClosed = true; cancelPendingWork(); jobOwner.close()
        timer?.invalidate(); timer = nil; snapshot = nil; index = nil; entries = []; containers = []
        memberPicker.removeAllItems(); containerPicker.removeAllItems(); applyButton.isEnabled = false
        if let window { window.orderOut(nil); window.parent?.removeChildWindow(window) }
        beforePreparation = nil; editor = nil; drawing = nil
    }
    private func capture() -> Snapshot? {
        guard let editor, let drawing, editor.lifecycleJobs.isActive, jobOwner.isActive, !isClosed else { return nil }
        return Snapshot(documentOwnerID: drawing.lifecycleOwnerID,
            input: LifecycleJobInput(ownerID: jobOwner.id, snapshotID: drawing.stateID, revision: drawing.revision),
            pageID: drawing.diagram.activePageID, selectedNodes: editor.canvas.selectedNodes, selectedEdge: editor.canvas.selectedEdge,
            sourceID: drawing.diagram.visioArchive?.sourceResourceID, lineageID: drawing.diagram.visioArchive?.sourceLineageID)
    }
    private func accepts(_ candidate: Snapshot) -> Bool {
        !isClosed && jobOwner.isActive && window?.isVisible == true && !hasMarkedText && capture() == candidate
    }

    @discardableResult func reloadSnapshot() -> Bool {
        guard !isClosed, !isBusy, !hasMarkedText, let editor, let drawing, !drawing.isCalculating else {
            reasonLabel.stringValue = hasMarkedText ? "Finish text composition before reloading Memberships." : "Wait for the pending edit, or cancel it before reloading."
            return false
        }
        drawing.commitTextEditing(); editor.canvas.finishPageInteraction()
        guard !drawing.isCalculating, !editor.canvas.isEditingText, let captured = capture() else { return false }
        let frozen = drawing.diagram, preferredMember = selectedMemberID, preferredContainer = selectedContainerID
        snapshot = nil; index = nil; entries = []; containers = []; applyButton.isEnabled = false
        reasonLabel.stringValue = "Reading retained public relationships…"
        let request = UUID()
        do {
            pendingLoad = try LifecycleJobService.shared.submit(id: request, kind: .calculation, input: captured.input,
                accepts: { [weak self] candidate in self?.pendingLoad?.id == request && candidate == captured.input && self?.accepts(captured) == true },
                work: { context in try DiagramMemberships.index(in: frozen, pageID: captured.pageID, cancellation: context.cancellation) },
                completion: { [weak self] result in
                    guard let self else { return }
                    self.jobOwner.finish(request)
                    guard self.pendingLoad?.id == request else { return }
                    self.pendingLoad = nil
                    guard !self.isClosed else { return }
                    switch result {
                    case .success(let index):
                        guard index.order.count <= Self.maximumMenuEntries else {
                            self.reasonLabel.stringValue = "Memberships currently supports at most \(Self.maximumMenuEntries) objects per page. Use a smaller page for this editor."
                            self.refreshAvailability(); return
                        }
                        self.snapshot = captured; self.index = index
                        self.entries = index.order.compactMap { index.entries[$0] }; self.containers = index.containers
                        self.populate(self.memberPicker, values: self.entries)
                        self.populate(self.containerPicker, values: self.containers)
                        let rawMember = captured.selectedNodes.count == 1 ? captured.selectedNodes.first : captured.selectedEdge
                        self.select(self.memberPicker, id: preferredMember ?? rawMember)
                        self.select(self.containerPicker, id: preferredContainer)
                        self.reasonLabel.stringValue = index.issues.first ?? "List, lane, callout and boundary relationships are read-only. Apply changes one explicit container edge."
                    case .failure(let error):
                        self.reasonLabel.stringValue = (error as? LifecycleJobError) == .staleInput ? "The drawing, page, selection or source changed. Reload Memberships." : error.localizedDescription
                    }
                    self.refreshAvailability()
                })
            if let pendingLoad { jobOwner.track(pendingLoad) }
            refreshAvailability(); return true
        } catch { reasonLabel.stringValue = error.localizedDescription; return false }
    }

    @discardableResult func select(memberID: UUID, containerID: UUID, included: Bool) -> Bool {
        guard !isClosed, !isBusy, !hasMarkedText, entries.contains(where: { $0.id == memberID }), containers.contains(where: { $0.id == containerID }) else { return false }
        select(memberPicker, id: memberID); select(containerPicker, id: containerID)
        operationPicker.selectItem(at: included ? 0 : 1); refreshAvailability(); return true
    }
    func refreshAvailability() {
        guard !isClosed else { applyButton.isEnabled = false; return }
        if let request = submittedCalculationID, drawing?.pendingCalculationID != request {
            submittedCalculationID = nil
            if let error = drawing?.lastCalculationJobError { reasonLabel.stringValue = error.localizedDescription }
            else { _ = reloadSnapshot(); return }
        }
        memberPicker.isEnabled = !isBusy; containerPicker.isEnabled = !isBusy; operationPicker.isEnabled = !isBusy
        reloadButton.isEnabled = !isBusy && !hasMarkedText
        cancelJobButton.isEnabled = isBusy
        guard !isBusy, let snapshot, accepts(snapshot), let index, index.issues.isEmpty,
              let memberID = selectedMemberID, let containerID = selectedContainerID,
              let member = index.entries[memberID], let container = index.entries[containerID],
              memberID != containerID, member.sourceRefusal == nil, container.sourceRefusal == nil else {
            applyButton.isEnabled = false
            if let snapshot, !accepts(snapshot), !isBusy { reasonLabel.stringValue = "The drawing, page, selection or source changed. Reload Memberships." }
            return
        }
        applyButton.isEnabled = drawing?.isCalculating == false && index.contains(member: memberID, container: containerID) != includesMember
        let memberships = index.outgoing[memberID, default: []].map { relation in
            "\(relation.kind.rawValue): \(index.entries[relation.target]?.title ?? "Unavailable")"
        }
        summaryLabel.stringValue = "Group parentage is separate. Retained relationships: " + (memberships.isEmpty ? "none" : memberships.joined(separator: "; "))
    }
    @discardableResult func applyMembership() -> Bool {
        guard !isClosed, !isBusy, !hasMarkedText, let editor, let drawing, !drawing.isCalculating else { return false }
        guard window?.makeFirstResponder(memberPicker) != false else { return false }
        drawing.commitTextEditing(); editor.canvas.finishPageInteraction()
        guard let snapshot, accepts(snapshot) else { reasonLabel.stringValue = "The drawing, page, selection or source changed. Reload Memberships before applying."; applyButton.isEnabled = false; return false }
        guard let index, index.issues.isEmpty, let memberID = selectedMemberID, let containerID = selectedContainerID,
              memberID != containerID, index.contains(member: memberID, container: containerID) != includesMember else { return false }
        let included = includesMember, frozen = drawing.diagram, beforePreparation = self.beforePreparation
        drawing.replaceInEditor(with: frozen, action: included ? "Add Container Member" : "Remove Container Member", forceAsync: true, presentFailureAlert: false,
            acceptsEditorInput: { [weak self] in self?.accepts(snapshot) == true },
            preparation: { cancellation in
                try beforePreparation?(cancellation)
                let next = try DiagramMemberships.settingMembership(in: frozen, pageID: snapshot.pageID, memberID: memberID, containerID: containerID, included: included, cancellation: cancellation)
                return (next, CalculationWork())
            })
        guard let request = drawing.pendingCalculationID else {
            reasonLabel.stringValue = drawing.lastCalculationJobError?.localizedDescription ?? "The membership edit was not submitted."; return false
        }
        submittedCalculationID = request; reasonLabel.stringValue = "Preparing one reciprocal container membership…"; refreshAvailability(); return true
    }
    func cancelPendingWork() {
        pendingLoad?.cancel()
        if let request = submittedCalculationID { drawing?.cancelPendingCalculation(ifID: request) }
        if !isClosed { reasonLabel.stringValue = "Cancelling the pending membership operation…" }
    }
    static func populatePicker(_ picker: NSPopUpButton, choices: [(UUID, String)]) {
        picker.removeAllItems()
        for (id, title) in choices {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = id as NSUUID
            picker.menu?.addItem(item)
        }
    }
    static func selectPicker(_ picker: NSPopUpButton, id: UUID?) {
        guard let id, let item = picker.itemArray.first(where: { ($0.representedObject as? NSUUID) == id as NSUUID }) else { return }
        picker.select(item)
    }
    private func populate(_ picker: NSPopUpButton, values: [DiagramMemberships.Entry]) { Self.populatePicker(picker, choices: values.map { ($0.id, $0.title) }) }
    private func select(_ picker: NSPopUpButton, id: UUID?) { Self.selectPicker(picker, id: id) }
    private func buildUI() {
        operationPicker.addItems(withTitles: ["Add to Container", "Remove from Container"])
        for picker in [memberPicker, containerPicker, operationPicker] { picker.target = self; picker.action = #selector(choiceChanged(_:)) }
        applyButton.target = self; applyButton.action = #selector(apply(_:))
        reloadButton.target = self; reloadButton.action = #selector(reload(_:))
        cancelJobButton.target = self; cancelJobButton.action = #selector(cancelJob(_:))
        let close = NSButton(title: "Close", target: self, action: #selector(closePanel(_:)))
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        for (name, picker) in [("Member", memberPicker), ("Container", containerPicker), ("Operation", operationPicker)] {
            let row = NSStackView(views: [NSTextField(labelWithString: name), picker]); row.spacing = 12; content.addArrangedSubview(row)
            picker.widthAnchor.constraint(equalToConstant: 460).isActive = true
        }
        content.addArrangedSubview(summaryLabel); content.addArrangedSubview(reasonLabel)
        let buttons = NSStackView(views: [applyButton, reloadButton, cancelJobButton, close]); buttons.spacing = 10; content.addArrangedSubview(buttons)
        guard let host = window?.contentView else { return }
        host.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 18), content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -18), content.topAnchor.constraint(equalTo: host.topAnchor, constant: 18), content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -18)])
        memberPicker.setAccessibilityIdentifier("MembershipMember"); containerPicker.setAccessibilityIdentifier("MembershipContainer")
        operationPicker.setAccessibilityIdentifier("MembershipOperation"); applyButton.setAccessibilityIdentifier("ApplyMembership")
    }
    @objc private func choiceChanged(_ sender: Any?) { refreshAvailability() }
    @objc private func apply(_ sender: Any?) { _ = applyMembership() }
    @objc private func reload(_ sender: Any?) { _ = reloadSnapshot() }
    @objc private func cancelJob(_ sender: Any?) { cancelPendingWork() }
    @objc private func closePanel(_ sender: Any?) { close() }
}

/// Copy leaves the source archive behind. Prove its ownership and complete
/// endpoint closure on an owned worker before publishing native clipboard data
/// or passing a duplicate fragment to the ordinary paste transaction.
extension EditorWindowController {
    func prepareMembershipFragment(_ nodeIDs: Set<UUID>, edges: Set<UUID> = [], completion: @escaping (DiagramPage) -> Void) {
        guard membershipUnavailableReason == nil, window?.makeFirstResponder(canvas) != false else { return }
        diagramDocument.commitTextEditing(); canvas.finishPageInteraction()
        guard membershipUnavailableReason == nil, !canvas.isEditingText else { return }
        let owner = lifecycleJobs, frozen = diagramDocument.diagram
        if !DiagramMemberships.needsSourceProof(in: frozen, pageID: frozen.page.id) {
            completion(DiagramOperations.fragment(nodeIDs, edges: edges, from: frozen.page))
            return
        }
        let state = diagramDocument.stateID, revision = diagramDocument.revision, documentOwner = diagramDocument.lifecycleOwnerID
        let selectedNodes = canvas.selectedNodes, selectedEdge = canvas.selectedEdge
        let resourceID = frozen.visioArchive?.sourceResourceID, lineageID = frozen.visioArchive?.sourceLineageID
        let input = LifecycleJobInput(ownerID: owner.id, snapshotID: state, revision: revision)
        let request = UUID(), progress = LifecycleProgressController(title: "Preparing selection", detail: "Checking public membership identities")
        do {
            let handle = try LifecycleJobService.shared.submit(id: request, kind: .conversion, input: input,
                accepts: { [weak self] candidate in
                    guard owner.isActive, let self, candidate == input, self.membershipUnavailableReason == nil else { return false }
                    let document = self.diagramDocument
                    return document.lifecycleOwnerID == documentOwner && document.stateID == state && document.revision == revision
                        && document.diagram.activePageID == frozen.activePageID
                        && document.diagram.visioArchive?.sourceResourceID == resourceID && document.diagram.visioArchive?.sourceLineageID == lineageID
                        && self.canvas.selectedNodes == selectedNodes && self.canvas.selectedEdge == selectedEdge
                }, progress: { progress.update($0) }, work: { context in
                    let binding = frozen.visioArchive?.pages.first { $0.pageID == frozen.page.id }
                    let fragment = DiagramOperations.fragment(nodeIDs, edges: edges, from: frozen.page, binding: binding)
                    let all = Set(fragment.nodes.map(\.id) + fragment.edges.map(\.id))
                    try DiagramMemberships.validateCopy(all, in: frozen, pageID: frozen.page.id, cancellation: context.cancellation)
                    try DiagramMemberships.validatePaste(fragment, cancellation: context.cancellation)
                    return fragment
                }, completion: { [weak self] result in
                    owner.finish(request); progress.finish()
                    guard owner.isActive, let self else { return }
                    switch result {
                    case .success(let fragment): completion(fragment)
                    case .failure(let error): self.root.showMessage(error.localizedDescription)
                    }
                })
            owner.track(handle); progress.onCancel = { handle.cancel() }; progress.show(attachedTo: window)
        } catch { progress.finish(); root.showMessage(error.localizedDescription) }
    }
}

/// The worker prepares immutable bytes. The main publication seam reads them
/// only after acceptance; no pasteboard/AppKit objects cross the worker boundary.
private final class MembershipCutPayload {
    private let lock = NSLock()
    private var value: (Data, String)?
    func store(_ data: Data, text: String) { lock.lock(); defer { lock.unlock() }; value = (data, text) }
    func read() throws -> (Data, String) {
        lock.lock(); defer { lock.unlock() }
        guard let value else { throw DiagramError.invalid("The prepared Cut clipboard is unavailable.") }
        return value
    }
}

extension EditorWindowController {
    /// Cut has one owned calculation. Clipboard publication happens after all
    /// proof/calculation checks and immediately before the nonthrowing document
    /// commit. Other clipboard clients are outside this app's transaction.
    func cutSelection(_ sender: Any?, pasteboard: NSPasteboard = .general,
                      beforePreparation: ((LifecycleJobCancellation) throws -> Void)? = nil) {
        precondition(Thread.isMainThread)
        if let reason = membershipUnavailableReason { root.showMessage(reason); return }
        guard window?.makeFirstResponder(canvas) != false else { return }
        diagramDocument.commitTextEditing(); canvas.finishPageInteraction()
        guard membershipUnavailableReason == nil, !canvas.isEditingText else { return }
        let document = diagramDocument, owner = lifecycleJobs, frozen = document.diagram
        let rawNodes = canvas.selectedNodes, rawEdge = canvas.selectedEdge
        let nodes = DiagramOperations.expandedSelection(rawNodes, in: frozen.page)
        let edges = Set([rawEdge].compactMap { $0 })
        guard !nodes.isEmpty || !edges.isEmpty else { return }
        let state = document.stateID, revision = document.revision, documentOwner = document.lifecycleOwnerID
        let sourceID = frozen.visioArchive?.sourceResourceID, lineageID = frozen.visioArchive?.sourceLineageID
        let clipboardVersion = pasteboard.changeCount, payload = MembershipCutPayload()
        document.replaceInEditor(with: frozen, action: "Cut", forceAsync: true, presentFailureAlert: false,
            acceptsEditorInput: { [weak self] in
                guard owner.isActive, let self, !membershipHasMarkedText(self.diagramDocument) else { return false }
                let current = self.diagramDocument
                return current.lifecycleOwnerID == documentOwner && current.stateID == state && current.revision == revision
                    && current.diagram.activePageID == frozen.activePageID
                    && current.diagram.visioArchive?.sourceResourceID == sourceID && current.diagram.visioArchive?.sourceLineageID == lineageID
                    && self.canvas.selectedNodes == rawNodes && self.canvas.selectedEdge == rawEdge
                    && pasteboard.changeCount == clipboardVersion
            }, beforeEditorPublication: {
                precondition(Thread.isMainThread)
                guard pasteboard.changeCount == clipboardVersion else { throw LifecycleJobError.staleInput }
                let (data, text) = try payload.read(), item = NSPasteboardItem()
                guard item.setData(data, forType: CanvasView.fragmentPasteboardType), item.setString(text, forType: .string) else {
                    throw DiagramError.invalid("The Cut clipboard item could not be prepared. The drawing was retained.")
                }
                pasteboard.clearContents()
                guard pasteboard.writeObjects([item]) else {
                    // NSPasteboard offers no rollback/compare-and-swap API.
                    // Failure after clear can affect clipboard, never drawing.
                    throw DiagramError.invalid("The system refused the Cut clipboard write. The drawing was retained; the clipboard may be empty.")
                }
            }, preparation: { cancellation in
                try beforePreparation?(cancellation)
                try cancellation.check()
                guard nodes.isSubset(of: Set(frozen.page.nodes.map(\.id))), edges.isSubset(of: Set(frozen.page.edges.map(\.id))) else {
                    throw LifecycleJobError.staleInput
                }
                let removedEdges = frozen.page.edges.filter {
                    nodes.contains($0.source) || nodes.contains($0.target) || $0.parentID.map(nodes.contains) == true || edges.contains($0.id)
                }
                for node in frozen.page.nodes where nodes.contains(node.id) {
                    try cancellation.check()
                    if let reason = NativeEditProtection.blockReason(for: "Delete", node: node, in: frozen.page) { throw DiagramError.invalid(reason) }
                }
                for edge in removedEdges {
                    try cancellation.check()
                    if frozen.page.isLocked(edge) { throw DiagramError.invalid("A connector, its group or layer is locked. Cut was refused.") }
                    if let reason = NativeEditProtection.blockReason(for: "Delete", node: edge.textNode, in: frozen.page) { throw DiagramError.invalid(reason) }
                }
                let binding = frozen.visioArchive?.pages.first { $0.pageID == frozen.page.id }
                let fragment = DiagramOperations.fragment(nodes, edges: edges, from: frozen.page, binding: binding)
                let copied = Set(fragment.nodes.map(\.id) + fragment.edges.map(\.id))
                let removed = nodes.union(removedEdges.map(\.id))
                // Do not discard an attached/group connector missing from the
                // encoded selection. Require an explicit complete Cut closure.
                guard copied == removed else { throw DiagramError.invalid("Select the complete connector closure before Cut. The drawing and clipboard were retained.") }
                if DiagramMemberships.needsSourceProof(in: frozen, pageID: frozen.page.id) {
                    try DiagramMemberships.validateCopy(copied, in: frozen, pageID: frozen.page.id, cancellation: cancellation)
                    try DiagramMemberships.validatePaste(fragment, cancellation: cancellation)
                    try DiagramMemberships.validateRemoval(removed, in: frozen, pageID: frozen.page.id, cancellation: cancellation)
                }
                let encoded = try JSONEncoder().encode(fragment)
                guard encoded.count <= 64 * 1_024 * 1_024 else { throw DiagramError.invalid("The Cut clipboard exceeds the 64 MiB limit.") }
                try cancellation.check()
                payload.store(encoded, text: fragment.nodes.map(\.text).joined(separator: "\n"))
                var next = frozen
                next.page.nodes.removeAll { nodes.contains($0.id) }
                next.page.edges.removeAll { removed.contains($0.id) }
                return (try next.validated(), CalculationWork())
            })
    }
}
