import AppKit
import ObjectiveC

private var editorCommandSearchKey: UInt8 = 0

extension EditorWindowController {
    var commandSearchController: EditorCommandSearchController {
        if let controller = objc_getAssociatedObject(self, &editorCommandSearchKey) as? EditorCommandSearchController { return controller }
        let controller = EditorCommandSearchController(editor: self)
        objc_setAssociatedObject(self, &editorCommandSearchKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }
    @objc func showCommandSearch(_ sender: Any?) {
        guard lifecycleJobs.isActive else { return }
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true {
            root.showMessage("Finish text composition before opening command search."); return
        }
        window?.makeFirstResponder(canvas); canvas.finishPageInteraction()
        commandSearchController.showWindow(sender)
    }
}

struct EditorSearchCommand {
    enum Requirement {
        case none, idle, selectedShapes(Int), editableShapes(Int), oneEditableShape
        case editableObject, group, ungroup, multiplePages, definitionSheets
    }
    let title: String
    let keywords: String
    let action: Selector
    var requirement: Requirement = .none

    /// One catalog feeds presentation and dispatch. It only calls existing
    /// editor commands; search owns no alternate model-edit implementation.
    static let all: [EditorSearchCommand] = [
        .init(title: "Find and Replace…", keywords: "search text shapes data pages", action: #selector(EditorWindowController.showDocumentFind(_:))),
        .init(title: "Pointer Tool", keywords: "select arrow", action: #selector(EditorWindowController.pointerTool(_:)), requirement: .idle),
        .init(title: "Connector Tool", keywords: "connect line edge", action: #selector(EditorWindowController.connectorTool(_:)), requirement: .idle),
        .init(title: "Text Tool", keywords: "add text label", action: #selector(EditorWindowController.textTool(_:)), requirement: .idle),
        .init(title: "Insert Process", keywords: "flowchart rectangle shape add", action: #selector(EditorWindowController.insertProcess(_:)), requirement: .idle),
        .init(title: "Insert Decision", keywords: "flowchart branch diamond shape add", action: #selector(EditorWindowController.insertDecision(_:)), requirement: .idle),
        .init(title: "Insert Start / End", keywords: "flowchart terminator shape add", action: #selector(EditorWindowController.insertTerminator(_:)), requirement: .idle),
        .init(title: "Insert Data", keywords: "flowchart input output shape add", action: #selector(EditorWindowController.insertData(_:)), requirement: .idle),
        .init(title: "Insert Subprocess", keywords: "flowchart process predefined", action: #selector(EditorWindowController.insertSubprocess(_:)), requirement: .idle),
        .init(title: "Insert Off-page Link…", keywords: "flowchart destination page navigation", action: #selector(EditorWindowController.chooseOffPageTarget(_:)), requirement: .multiplePages),
        .init(title: "Edit Text…", keywords: "rename label", action: #selector(EditorWindowController.editText(_:)), requirement: .editableObject),
        .init(title: "Duplicate Shapes", keywords: "copy clone", action: #selector(EditorWindowController.duplicateSelection(_:)), requirement: .editableShapes(1)),
        .init(title: "Delete Selection", keywords: "remove shape connector", action: #selector(EditorWindowController.deleteSelection(_:)), requirement: .editableObject),
        .init(title: "Group Shapes", keywords: "combine selection", action: #selector(EditorWindowController.groupSelection(_:)), requirement: .group),
        .init(title: "Ungroup Shapes", keywords: "separate group", action: #selector(EditorWindowController.ungroupSelection(_:)), requirement: .ungroup),
        .init(title: "Union Shapes", keywords: "boolean geometry combine outline", action: #selector(EditorWindowController.unionSelection(_:)), requirement: .editableShapes(2)),
        .init(title: "Intersect Shapes", keywords: "boolean common overlap geometry", action: #selector(EditorWindowController.intersectSelection(_:)), requirement: .editableShapes(2)),
        .init(title: "Subtract Shapes…", keywords: "boolean cut difference base geometry", action: #selector(EditorWindowController.subtractSelection(_:)), requirement: .editableShapes(2)),
        .init(title: "Rotate Left", keywords: "turn anticlockwise", action: #selector(EditorWindowController.rotateLeft(_:)), requirement: .editableShapes(1)),
        .init(title: "Rotate Right", keywords: "turn clockwise", action: #selector(EditorWindowController.rotateRight(_:)), requirement: .editableShapes(1)),
        .init(title: "Flip Horizontal", keywords: "mirror", action: #selector(EditorWindowController.flipHorizontal(_:)), requirement: .editableShapes(1)),
        .init(title: "Flip Vertical", keywords: "mirror", action: #selector(EditorWindowController.flipVertical(_:)), requirement: .editableShapes(1)),
        .init(title: "Align Left", keywords: "arrange selection", action: #selector(EditorWindowController.alignLeft(_:)), requirement: .editableShapes(2)),
        .init(title: "Align Center", keywords: "arrange centre selection", action: #selector(EditorWindowController.alignCenter(_:)), requirement: .editableShapes(2)),
        .init(title: "Align Top", keywords: "arrange selection", action: #selector(EditorWindowController.alignTop(_:)), requirement: .editableShapes(2)),
        .init(title: "Distribute Horizontally", keywords: "space arrange selection", action: #selector(EditorWindowController.distributeHorizontal(_:)), requirement: .editableShapes(3)),
        .init(title: "Distribute Vertically", keywords: "space arrange selection", action: #selector(EditorWindowController.distributeVertical(_:)), requirement: .editableShapes(3)),
        .init(title: "Bring to Front", keywords: "arrange order", action: #selector(EditorWindowController.bringToFront(_:)), requirement: .editableShapes(1)),
        .init(title: "Send to Back", keywords: "arrange order", action: #selector(EditorWindowController.sendToBack(_:)), requirement: .editableShapes(1)),
        .init(title: "Lock / Unlock Shapes", keywords: "protect selection", action: #selector(EditorWindowController.toggleLock(_:)), requirement: .selectedShapes(1)),
        .init(title: "Shape Data…", keywords: "properties values fields", action: #selector(EditorWindowController.editShapeData(_:)), requirement: .oneEditableShape),
        .init(title: "Definition Sheets…", keywords: "document master style sheets cells formula cached value unit", action: #selector(EditorWindowController.showDefinitionSheets(_:)), requirement: .definitionSheets),
        .init(title: "Connection Points…", keywords: "ports glue", action: #selector(EditorWindowController.editConnectionPoints(_:)), requirement: .oneEditableShape),
        .init(title: "Insert Text Field…", keywords: "formula label", action: #selector(EditorWindowController.insertField(_:)), requirement: .oneEditableShape),
        .init(title: "Add Page", keywords: "new drawing sheet", action: #selector(EditorWindowController.addPage(_:)), requirement: .idle),
        .init(title: "Duplicate Page", keywords: "copy drawing sheet", action: #selector(EditorWindowController.duplicatePage(_:)), requirement: .idle),
        .init(title: "Delete Page…", keywords: "remove drawing sheet", action: #selector(EditorWindowController.deletePage(_:)), requirement: .multiplePages),
        .init(title: "Fit Page", keywords: "zoom view", action: #selector(EditorWindowController.fitPage(_:))),
        .init(title: "Actual Size", keywords: "zoom 100 percent view", action: #selector(EditorWindowController.actualSize(_:))),
        .init(title: "Zoom In", keywords: "magnify view", action: #selector(EditorWindowController.zoomIn(_:))),
        .init(title: "Zoom Out", keywords: "view", action: #selector(EditorWindowController.zoomOut(_:))),
        .init(title: "Show / Hide Grid", keywords: "view guides", action: #selector(EditorWindowController.toggleGrid(_:))),
        .init(title: "Snap to Grid", keywords: "view guides", action: #selector(EditorWindowController.toggleSnap(_:))),
        .init(title: "Preview Drawing Grid…", keywords: "document wide operation reversible", action: #selector(EditorWindowController.previewDrawingGrid(_:)), requirement: .idle),
        .init(title: "Show / Hide Shape Library", keywords: "stencils panel", action: #selector(EditorWindowController.toggleShapeLibrary(_:))),
        .init(title: "Check Drawing Content…", keywords: "proofing missing font descriptions issues", action: #selector(EditorWindowController.checkDrawingContent(_:)), requirement: .idle),
        .init(title: "Export Redacted Support Report…", keywords: "diagnostics troubleshooting privacy", action: #selector(EditorWindowController.exportRedactedSupportReport(_:))),
        .init(title: "Export PDF…", keywords: "publish save document", action: #selector(EditorWindowController.exportPDF(_:))),
        .init(title: "Export SVG…", keywords: "publish save vector", action: #selector(EditorWindowController.exportSVG(_:))),
        .init(title: "Export PNG…", keywords: "publish save image", action: #selector(EditorWindowController.exportPNG(_:))),
        .init(title: "Print…", keywords: "printer document pages range paper scale", action: #selector(EditorWindowController.printDiagram(_:)), requirement: .idle)
    ]

    static func matching(_ text: String) -> [EditorSearchCommand] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        return all.filter { command in words.allSatisfy {
            (command.title + " " + command.keywords).range(of: $0, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
        } }
    }
    func disabledReason(in editor: EditorWindowController) -> String? {
        guard editor.lifecycleJobs.isActive else { return "The drawing window is closed." }
        let document = editor.diagramDocument
        if case .none = requirement {} else if document.isCalculating { return "Wait for calculation to finish or cancel it." }
        if (editor.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return "Finish text composition before running this command." }
        let selection = editor.selection, page = document.diagram.page
        let anyLocked = selection.contains { page.isLocked($0) }
        func shapes(_ count: Int, editable: Bool) -> String? {
            guard selection.count >= count else { return count == 1 ? "Select at least one shape." : "Select at least \(count) shapes." }
            if editable && anyLocked { return "Unlock the selected shapes, groups or layers first." }
            return nil
        }
        switch requirement {
        case .none, .idle: break
        case .definitionSheets:
            if let reason = editor.definitionSheetUnavailableReason { return reason }
        case .selectedShapes(let count): if let reason = shapes(count, editable: false) { return reason }
        case .editableShapes(let count): if let reason = shapes(count, editable: true) { return reason }
        case .oneEditableShape:
            guard selection.count == 1 else { return "Select exactly one shape." }
            if anyLocked { return "Unlock the selected shape, its group or its layer first." }
        case .editableObject:
            guard !selection.isEmpty || editor.canvas.selectedEdge != nil else { return "Select a shape or connector." }
            if anyLocked { return "Unlock the selected shapes, groups or layers first." }
            if let id = editor.canvas.selectedEdge, let edge = document.runtime().edgesByID[id], page.isLocked(edge) { return "Unlock the connector's group or layer first." }
            if action == #selector(EditorWindowController.editText(_:)), selection.count > 1 { return "Select exactly one shape or connector." }
        case .group:
            if let reason = shapes(2, editable: true) { return reason }
            guard Set(selection.map(\.parentID)).count == 1 else { return "Select shapes in the same group." }
        case .ungroup:
            if let reason = shapes(1, editable: true) { return reason }
            guard selection.contains(where: { $0.formatting.isGroup }) else { return "Select a group to ungroup." }
        case .multiplePages:
            guard document.diagram.pages.count > 1 else {
                return action == #selector(EditorWindowController.chooseOffPageTarget(_:))
                    ? "Add another page before inserting an off-page link." : "Keep at least one drawing page."
            }
        }
        if [#selector(EditorWindowController.editText(_:)), #selector(EditorWindowController.insertField(_:))].contains(action) {
            let match: DocumentSearch.Match?
            if let node = selection.first {
                match = .init(pageID: page.id, objectID: node.id, surface: .nodeText,
                              range: NSRange(location: 0, length: node.text.utf16.count), source: node.text)
            } else if let id = editor.canvas.selectedEdge, let edge = document.runtime().edgesByID[id] {
                match = .init(pageID: page.id, objectID: id, surface: .edgeLabel,
                              range: NSRange(location: 0, length: edge.label.utf16.count), source: edge.label)
            } else { match = nil }
            if let match, let block = DocumentSearch.replacementBlock(for: match, in: document.diagram) {
                switch block {
                // Explicit text/field editors own field editing. Empty strings
                // have no replaceable range, but still check protection first.
                case .fieldContent, .invalidRange: break
                default: return block.localizedDescription
                }
            }
        }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        if action == #selector(EditorWindowController.unionSelection(_:)),let reason = editor.unionUnavailableReason { return reason }
        if action == #selector(EditorWindowController.intersectSelection(_:)), let reason = editor.intersectUnavailableReason { return reason }
        if action == #selector(EditorWindowController.subtractSelection(_:)), let reason = editor.subtractUnavailableReason { return reason }
        if !editor.validateMenuItem(item) { return "This command is unavailable for the current selection." }
        return nil
    }
}

final class EditorCommandSearchController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate {
    private struct AvailabilityKey: Equatable {
        var stateID: UUID
        var revision: UInt64
        var pageID: UUID
        var nodes: Set<UUID>
        var edge: UUID?
        var calculating: Bool
        var printing: Bool
        var parentComposition: Bool
        var inlineEditing: Bool
        var filterGeneration: UInt64
    }
    private weak var editor: EditorWindowController?
    private weak var drawing: MacVisioDocument?
    private let jobOwner: LifecycleJobOwner
    private var closeObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
    private var filteredText = ""
    private var filterGeneration: UInt64 = 0
    private var availabilityKey: AvailabilityKey?
    private var disabledReasons: [Selector: String] = [:]
    private(set) var availabilityEvaluations = 0
    let searchField = NSSearchField()
    let table = NSTableView()
    let explanation = NSTextField(wrappingLabelWithString: "Type a command name, then choose Run.")
    let runButton = NSButton(title: "Run Command", target: nil, action: nil)
    private(set) var commands = EditorSearchCommand.all

    init(editor: EditorWindowController) {
        self.editor = editor; drawing = editor.diagramDocument; jobOwner = editor.lifecycleJobs
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 700, height: 500),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Search Commands"; panel.minSize = CGSize(width: 540, height: 360); panel.isReleasedWhenClosed = false
        panel.autorecalculatesKeyViewLoop = true
        super.init(window: panel)
        panel.delegate = self; panel.setAccessibilityIdentifier("MacVisioCommandSearch"); buildUI()
        if let window = editor.window {
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.close(); self?.editor = nil; self?.drawing = nil
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }; refreshTimer?.invalidate() }
    override func showWindow(_ sender: Any?) {
        guard jobOwner.isActive, drawing != nil, let parent = editor?.window, let panel = window else { return }
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above); panel.center() }
        super.showWindow(sender); panel.makeKeyAndOrderFront(sender); panel.makeFirstResponder(searchField)
        filterCommands(); refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshEnabledState() }
    }
    override func cancelOperation(_ sender: Any?) {
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return }
        close()
    }
    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate(); refreshTimer = nil
        if let window { window.parent?.removeChildWindow(window) }
    }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        searchField.placeholderString = "Search commands, tools and actions"; searchField.delegate = self
        searchField.target = self; searchField.action = #selector(runSelected(_:)); searchField.sendsWholeSearchString = true
        searchField.cell?.sendsActionOnEndEditing = false
        searchField.setAccessibilityLabel("Search editor commands"); stack.addArrangedSubview(searchField)
        searchField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for (id, title, width) in [("command", "Command", 270.0), ("state", "Availability", 370.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 30; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.setAccessibilityLabel("Editor command results")
        table.target = self; table.doubleAction = #selector(runSelected(_:))
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.borderType = .bezelBorder; scroll.documentView = table
        stack.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        stack.addArrangedSubview(explanation); explanation.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        explanation.font = .systemFont(ofSize: 12); explanation.setAccessibilityLabel("Command availability explanation")
        runButton.target = self; runButton.action = #selector(runSelected(_:)); runButton.bezelStyle = .rounded; runButton.keyEquivalent = "\r"
        let close = NSButton(title: "Close", target: self, action: #selector(closePanel(_:))); close.bezelStyle = .rounded
        let footer = NSStackView(views: [runButton, close]); footer.spacing = 8; stack.addArrangedSubview(footer)
        window?.initialFirstResponder = searchField
    }
    func controlTextDidChange(_ notification: Notification) {
        if (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true { filterCommands() }
        else { refreshEnabledState() }
    }
    func filterCommands() {
        let old = selectedCommand?.action
        filteredText = searchField.stringValue
        commands = EditorSearchCommand.matching(searchField.stringValue); filterGeneration &+= 1
        _ = updateAvailabilityCache(); table.reloadData()
        if !commands.isEmpty {
            let row = commands.firstIndex { $0.action == old } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        refreshEnabledState()
    }
    var selectedCommand: EditorSearchCommand? { commands.indices.contains(table.selectedRow) ? commands[table.selectedRow] : nil }
    private func updateAvailabilityCache() -> Bool {
        guard jobOwner.isActive, let drawing, let editor else { return false }
        let key = AvailabilityKey(stateID: drawing.stateID, revision: drawing.revision, pageID: drawing.diagram.activePageID,
                                  nodes: editor.canvas.selectedNodes, edge: editor.canvas.selectedEdge,
                                  calculating: drawing.isCalculating,
                                  printing: editor.isPrinting,
                                  parentComposition: (editor.window?.firstResponder as? NSTextView)?.hasMarkedText() == true,
                                  inlineEditing: editor.canvas.isEditingText, filterGeneration: filterGeneration)
        guard key != availabilityKey else { return false }
        availabilityKey = key; availabilityEvaluations += 1
        disabledReasons = commands.reduce(into: [:]) { reasons, command in
            if let reason = command.disabledReason(in: editor) { reasons[command.action] = reason }
        }
        return true
    }
    func refreshEnabledState() {
        guard jobOwner.isActive, drawing != nil, editor != nil else { runButton.isEnabled = false; explanation.stringValue = "The drawing window is closed."; return }
        if (searchField.currentEditor() as? NSTextView)?.hasMarkedText() == true {
            runButton.isEnabled = false; explanation.stringValue = "Finish text composition before running a command."; return
        }
        let changed = updateAvailabilityCache()
        let reason = selectedCommand.flatMap { disabledReasons[$0.action] }
        runButton.isEnabled = selectedCommand != nil && reason == nil
        explanation.stringValue = selectedCommand == nil ? "No matching commands." : reason ?? "Ready. Run the selected editor command."
        // Updating cells does not replace the search field or its field editor.
        if changed { table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<commands.count), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard commands.indices.contains(row), jobOwner.isActive, drawing != nil, editor != nil else { return nil }
        let command = commands[row], reason = disabledReasons[command.action]
        let text = tableColumn?.identifier.rawValue == "command" ? command.title : reason ?? "Available"
        let field = NSTextField(labelWithString: text); field.lineBreakMode = .byTruncatingTail
        field.textColor = reason == nil ? .labelColor : .secondaryLabelColor; field.toolTip = reason
        return field
    }
    func tableViewSelectionDidChange(_ notification: Notification) { refreshEnabledState() }
    @objc func runSelected(_ sender: Any?) { _ = executeSelected() }
    @discardableResult func executeSelected() -> Bool {
        guard jobOwner.isActive, drawing != nil, let editor else { return false }
        if (searchField.currentEditor() as? NSTextView)?.hasMarkedText() == true ||
            (editor.window?.firstResponder as? NSTextView)?.hasMarkedText() == true {
            explanation.stringValue = "Finish text composition before running a command."; return false
        }
        guard filteredText.utf8.elementsEqual(searchField.stringValue.utf8) else {
            filterCommands(); explanation.stringValue = "The search changed. Review the matching command before running it."; return false
        }
        guard let command = selectedCommand else { return false }
        // Ending native input can itself commit text or inspector changes.
        // Validate the resulting current state, immediately before dispatch.
        editor.window?.makeFirstResponder(editor.canvas)
        editor.canvas.finishEditing(commit: true)
        if let reason = command.disabledReason(in: editor) { explanation.stringValue = reason; runButton.isEnabled = false; return false }
        close(); editor.window?.makeKeyAndOrderFront(nil); editor.window?.makeFirstResponder(editor.canvas)
        // Existing native commands own their transaction, dialogs and focus.
        return NSApp.sendAction(command.action, to: editor, from: self)
    }
    @objc private func closePanel(_ sender: Any?) { close() }
}
