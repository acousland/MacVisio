import AppKit
import MacVisioInfrastructure
import ObjectiveC

private var editorDocumentFindKey: UInt8 = 0

extension EditorWindowController {
    var documentFindController: EditorFindController {
        if let controller = objc_getAssociatedObject(self, &editorDocumentFindKey) as? EditorFindController { return controller }
        let controller = EditorFindController(editor: self)
        objc_setAssociatedObject(self, &editorDocumentFindKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    @objc func showDocumentFind(_ sender: Any?) {
        guard lifecycleJobs.isActive else { return }
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true {
            root.showMessage("Finish text composition before opening Find."); return
        }
        window?.makeFirstResponder(canvas)
        canvas.finishPageInteraction()
        documentFindController.showWindow(sender)
    }
}

/// Native UI owns only query/presentation state. Search runs on immutable
/// committed values; replacement enters the accepted document transaction API.
final class EditorFindController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate {
    private struct EligibilityKey: Equatable {
        var active: Bool
        var stateID: UUID?
        var revision: UInt64?
        var input: LifecycleJobInput?
        var selected: DocumentSearch.Match.ID?
        var searching: Bool
        var calculating: Bool
        var composition: Bool
    }
    weak var editor: EditorWindowController?
    private weak var drawing: MacVisioDocument?
    private let jobOwner: LifecycleJobOwner
    private var parentCloseObserver: NSObjectProtocol?
    private var eligibilityTimer: Timer?
    private var requestID: UUID?
    private var searchHandle: LifecycleJobHandle?
    private var resultInput: LifecycleJobInput?
    private var searchedPages: [UUID: String] = [:]
    private var selectingInitialResult = false
    private var eligibilityKey: EligibilityKey?
    /// Counts actual UI validation passes, not cheap timer-key comparisons.
    private(set) var eligibilityEvaluations = 0
    private(set) var isSearching = false
    private(set) var results = DocumentSearch.Results(matches: [], completion: .complete)
    let queryField = NSSearchField()
    let domainPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    let caseButton = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    let table = NSTableView()
    let preview = NSTextView()
    let summary = NSTextField(wrappingLabelWithString: "Find text, shapes and shape data across all pages.")
    let reasonLabel = NSTextField(wrappingLabelWithString: "Select a result to see replacement availability.")
    let replacementField = NSTextField(string: "")
    let replaceButton = NSButton(title: "Replace Selected", target: nil, action: nil)
    let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    let nextButton = NSButton(title: "Next", target: nil, action: nil)
    /// Testable policy, surfaced through Results.completion when invalid.
    var resultBudget = 10_000

    init(editor: EditorWindowController) {
        self.editor = editor; drawing = editor.diagramDocument; jobOwner = editor.lifecycleJobs
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 780, height: 620),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Find and Replace"; panel.minSize = CGSize(width: 620, height: 580)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self; panel.setAccessibilityIdentifier("MacVisioDocumentFind")
        buildUI()
        if let parent = editor.window {
            parentCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                object: parent, queue: .main) { [weak self] _ in self?.detach() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
        eligibilityTimer?.invalidate(); searchHandle?.cancel()
    }
    override func showWindow(_ sender: Any?) {
        guard jobOwner.isActive, drawing != nil, let parent = editor?.window, let panel = window else { return }
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above); panel.center() }
        super.showWindow(sender); panel.makeKeyAndOrderFront(sender); panel.makeFirstResponder(queryField)
        eligibilityTimer?.invalidate()
        eligibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshEligibility() }
        refreshEligibility()
    }
    override func cancelOperation(_ sender: Any?) {
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return }
        close()
    }
    func windowWillClose(_ notification: Notification) {
        cancelSearch(); eligibilityTimer?.invalidate(); eligibilityTimer = nil
        if let window { window.parent?.removeChildWindow(window) }
    }
    private func detach() {
        cancelSearch(); close(); editor = nil; drawing = nil
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)])
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views); row.orientation = .horizontal; row.spacing = 8; row.alignment = .centerY
            stack.addArrangedSubview(row); row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true; return row
        }
        queryField.placeholderString = "Text, shape kind, ID or shape data"; queryField.delegate = self
        queryField.target = self; queryField.action = #selector(find(_:)); queryField.sendsWholeSearchString = true
        queryField.setAccessibilityLabel("Find in drawing")
        queryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let find = NSButton(title: "Find", target: self, action: #selector(find(_:))); find.bezelStyle = .rounded
        _ = row([queryField, find])
        domainPicker.addItems(withTitles: ["All content", "Text", "Shapes", "Shape data"])
        domainPicker.target = self; domainPicker.action = #selector(queryOptionsChanged(_:)); domainPicker.setAccessibilityLabel("Search scope")
        caseButton.target = self; caseButton.action = #selector(queryOptionsChanged(_:))
        _ = row([domainPicker, caseButton])
        stack.addArrangedSubview(summary); summary.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        summary.font = .systemFont(ofSize: 12); summary.setAccessibilityLabel("Search result summary")
        for (id, title, width) in [("page", "Page", 130.0), ("surface", "Result", 145.0), ("text", "Matched content", 400.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        table.dataSource = self; table.delegate = self; table.rowHeight = 28
        table.target = self; table.action = #selector(revealSelectedResult(_:))
        table.usesAlternatingRowBackgroundColors = true; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("Find results across pages")
        let resultScroll = NSScrollView(); resultScroll.hasVerticalScroller = true; resultScroll.hasHorizontalScroller = true
        resultScroll.borderType = .bezelBorder; resultScroll.documentView = table
        stack.addArrangedSubview(resultScroll)
        preview.isEditable = false; preview.isSelectable = true; preview.isRichText = false
        preview.font = .systemFont(ofSize: 13); preview.textContainerInset = CGSize(width: 8, height: 8)
        preview.setAccessibilityLabel("Source text snapshot with selected match")
        preview.autoresizingMask = [.width]; preview.textContainer?.widthTracksTextView = true
        let previewScroll = NSScrollView(); previewScroll.hasVerticalScroller = true; previewScroll.borderType = .bezelBorder
        previewScroll.documentView = preview; stack.addArrangedSubview(previewScroll)
        NSLayoutConstraint.activate([resultScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            previewScroll.widthAnchor.constraint(equalTo: stack.widthAnchor), resultScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130),
            previewScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100), resultScroll.heightAnchor.constraint(equalTo: previewScroll.heightAnchor, multiplier: 1.3)])
        stack.addArrangedSubview(reasonLabel); reasonLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        reasonLabel.font = .systemFont(ofSize: 12); reasonLabel.setAccessibilityLabel("Replacement availability")
        replacementField.placeholderString = "Replacement text"; replacementField.setAccessibilityLabel("Replace with")
        replacementField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replaceButton.target = self; replaceButton.action = #selector(replaceSelected(_:)); replaceButton.bezelStyle = .rounded
        _ = row([NSTextField(labelWithString: "Replace with"), replacementField, replaceButton])
        previousButton.target = self; previousButton.action = #selector(previousResult(_:)); previousButton.bezelStyle = .rounded
        nextButton.target = self; nextButton.action = #selector(nextResult(_:)); nextButton.bezelStyle = .rounded
        let close = NSButton(title: "Close", target: self, action: #selector(closePanel(_:))); close.bezelStyle = .rounded
        _ = row([previousButton, nextButton, close])
        window?.initialFirstResponder = queryField
        refreshEligibility()
    }

    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSControl === queryField { invalidateQuery() }
    }
    @objc private func queryOptionsChanged(_ sender: Any?) { invalidateQuery() }
    private func invalidateQuery() {
        cancelSearch(); results = .init(matches: [], completion: .complete); resultInput = nil
        table.reloadData(); preview.string = ""; summary.stringValue = "Press Return or Find to search all pages."
        refreshEligibility()
    }
    private func cancelSearch() {
        searchHandle?.cancel(); searchHandle = nil; requestID = nil; isSearching = false
    }
    @objc func find(_ sender: Any?) { performSearch() }
    func performSearch() {
        guard jobOwner.isActive, let drawing else { return }
        if (queryField.currentEditor() as? NSTextView)?.hasMarkedText() == true { return }
        cancelSearch(); resultInput = nil; results = .init(matches: [], completion: .complete); table.reloadData(); preview.string = ""
        let domains: Set<DocumentSearch.Domain> = domainPicker.indexOfSelectedItem == 1 ? [.text] : domainPicker.indexOfSelectedItem == 2 ? [.shape] : domainPicker.indexOfSelectedItem == 3 ? [.data] : Set(DocumentSearch.Domain.allCases)
        let query = DocumentSearch.Query(text: queryField.stringValue, caseSensitive: caseButton.state == .on, domains: domains, maxResults: resultBudget)
        let snapshot = drawing.diagram
        let input = LifecycleJobInput(ownerID: jobOwner.id, snapshotID: drawing.stateID, revision: drawing.revision)
        let id = UUID(); requestID = id; isSearching = true; summary.stringValue = "Searching all pages…"; refreshEligibility()
        do {
            let handle = try LifecycleJobService.shared.submit(id: id, kind: .library, input: input,
                accepts: { [weak self, weak drawing] candidate in
                    guard let self, let drawing else { return false }
                    return self.jobOwner.isActive && self.requestID == id && candidate.ownerID == self.jobOwner.id
                        && drawing.stateID == candidate.snapshotID && drawing.revision == candidate.revision
                }, work: { context in
                    try Self.search(query, snapshot: snapshot, cancellation: context.cancellation)
                }, completion: { [weak self] outcome in
                    self?.jobOwner.finish(id)
                    guard let self, self.jobOwner.isActive, self.requestID == id else { return }
                    self.searchHandle = nil; self.requestID = nil; self.isSearching = false
                    switch outcome {
                    case .success(let results):
                        self.results = results; self.resultInput = input
                        self.searchedPages = snapshot.pages.reduce(into: [:]) { if $0[$1.id] == nil { $0[$1.id] = $1.name } }
                        self.summary.stringValue = Self.summary(for: results)
                        self.table.reloadData()
                        if !results.isEmpty {
                            // A background completion may update its preview,
                            // never finalize input or steal document focus.
                            self.selectingInitialResult = true
                            self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                            self.selectingInitialResult = false
                        }
                    case .failure(let error):
                        self.summary.stringValue = (error as? LifecycleJobError) == .staleInput
                            ? "The drawing changed while searching. Find again for current results." : error.localizedDescription
                    }
                    self.refreshEligibility()
                })
            searchHandle = handle; jobOwner.track(handle, replacing: "document-find")
        } catch {
            isSearching = false; requestID = nil; summary.stringValue = error.localizedDescription; refreshEligibility()
        }
    }

    /// Page checkpoints participate in accepted owner cancellation. Each local
    /// search remains bounded by the remaining result budget.
    static func search(_ query: DocumentSearch.Query, snapshot: Diagram,
                       cancellation: LifecycleJobCancellation) throws -> DocumentSearch.Results {
        guard (1...100_000).contains(query.maxResults) else { return .init(matches: [], completion: .invalidBudget) }
        var matches: [DocumentSearch.Match] = []
        for page in snapshot.pages {
            try cancellation.check()
            var subset = snapshot; subset.pages = [page]; subset.activePageID = page.id
            var remaining = query; remaining.maxResults = max(1, query.maxResults - matches.count)
            let found = DocumentSearch.find(remaining, in: subset)
            if matches.count == query.maxResults, !found.isEmpty { return .init(matches: matches, completion: .truncated) }
            matches.append(contentsOf: found)
            if found.isTruncated { return .init(matches: matches, completion: .truncated) }
        }
        try cancellation.check()
        return .init(matches: matches, completion: .complete)
    }
    static func summary(for results: DocumentSearch.Results) -> String {
        switch results.completion {
        case .complete: return "\(results.count) \(results.count == 1 ? "match" : "matches") across all pages."
        case .truncated: return "Showing the first \(results.count) matches. More results exist; narrow the search."
        case .invalidBudget: return "Search result limit must be between 1 and 100,000."
        }
    }
    var selectedMatch: DocumentSearch.Match? {
        results.indices.contains(table.selectedRow) ? results[table.selectedRow] : nil
    }
    var replacementReason: String? {
        guard jobOwner.isActive, drawing != nil else { return "The drawing window is closed." }
        guard let drawing else { return "The drawing is closed." }
        if isSearching { return "Wait for the search to finish." }
        if drawing.isCalculating { return "Wait for calculation to finish or cancel it." }
        if (editor?.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return "Finish text composition before replacing text." }
        guard let match = selectedMatch else { return "Select a text result to replace it." }
        guard resultInput?.snapshotID == drawing.stateID, resultInput?.revision == drawing.revision else { return "The drawing changed. Find again before replacing text." }
        return DocumentSearch.replacementBlock(for: match, in: drawing.diagram)?.localizedDescription
    }
    func refreshEligibility() {
        let key = EligibilityKey(active: jobOwner.isActive, stateID: drawing?.stateID, revision: drawing?.revision,
                                 input: resultInput, selected: selectedMatch?.id, searching: isSearching,
                                 calculating: drawing?.isCalculating ?? false,
                                 composition: (editor?.window?.firstResponder as? NSTextView)?.hasMarkedText() == true)
        guard key != eligibilityKey else { return }
        eligibilityKey = key; eligibilityEvaluations += 1
        let reason = replacementReason
        replaceButton.isEnabled = reason == nil
        reasonLabel.stringValue = reason ?? "Replace this selected text match. Other runs and fields stay unchanged."
        previousButton.isEnabled = !results.isEmpty; nextButton.isEnabled = !results.isEmpty
    }
    @objc func replaceSelected(_ sender: Any?) { _ = applyReplacement() }
    @discardableResult func applyReplacement() -> Bool {
        guard jobOwner.isActive, let editor, let drawing else { return false }
        guard finishParentEditing(editor) else { return false }
        if let reason = replacementReason { reasonLabel.stringValue = reason; replaceButton.isEnabled = false; return false }
        guard let match = selectedMatch else { return false }
        do {
            let candidate = try DocumentSearch.replacing(match, with: replacementField.stringValue, in: drawing.diagram).validated()
            guard candidate != drawing.diagram else { summary.stringValue = "Replacement makes no change."; return false }
            drawing.replaceInEditor(with: candidate, action: "Replace Text")
            resultInput = nil; refreshEligibility()
            if drawing.isCalculating { summary.stringValue = "Replacement is calculating. Find again after it finishes." }
            else if let error = drawing.lastCalculationJobError { summary.stringValue = error.localizedDescription; return false }
            else { performSearch() }
            return true
        } catch { reasonLabel.stringValue = error.localizedDescription; return false }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let match = results[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "page": value = searchedPages[match.pageID] ?? "Missing page"
        case "surface": value = Self.surfaceName(match.surface)
        default:
            let source = match.source as NSString
            let start = max(0, match.range.location - 50), end = min(source.length, NSMaxRange(match.range) + 100)
            let context = source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
            value = (context.location > 0 ? "…" : "") + source.substring(with: context).replacingOccurrences(of: "\n", with: " ↵ ")
                + (NSMaxRange(context) < source.length ? "…" : "")
        }
        let field = NSTextField(labelWithString: value); field.lineBreakMode = .byTruncatingTail
        field.toolTip = "\(Self.surfaceName(match.surface)) · UTF-16 \(match.range.location):\(match.range.length)"
        return field
    }
    static func surfaceName(_ surface: DocumentSearch.Surface) -> String {
        switch surface {
        case .nodeText: return "Shape text"
        case .edgeLabel: return "Connector label"
        case .shapeKind: return "Shape kind"
        case .objectID: return "Shape ID"
        case .sourceShapeID: return "Source shape ID"
        case .dataKey: return "Data key"
        case .dataLabel: return "Data label"
        case .dataValue: return "Data value"
        }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let match = selectedMatch else { preview.string = ""; refreshEligibility(); return }
        preview.string = match.source; preview.setSelectedRange(match.range); preview.scrollRangeToVisible(match.range)
        if !selectingInitialResult { _ = navigate(to: match) }
        refreshEligibility()
    }
    @objc func revealSelectedResult(_ sender: Any?) { if let match = selectedMatch { _ = navigate(to: match) } }
    @discardableResult func navigate(to match: DocumentSearch.Match) -> Bool {
        guard jobOwner.isActive, let editor, let drawing else { return false }
        guard finishParentEditing(editor) else { return false }
        guard
              resultInput?.snapshotID == drawing.stateID, resultInput?.revision == drawing.revision,
              drawing.diagram.pages.contains(where: { $0.id == match.pageID }) else {
            reasonLabel.stringValue = "The drawing changed. Find again before navigating."; return false
        }
        if drawing.diagram.activePageID != match.pageID { editor.switchPage(match.pageID) }
        guard resultInput?.snapshotID == drawing.stateID, resultInput?.revision == drawing.revision else { return false }
        let layer = editor.retainedScene?.layers.first { $0.page.id == match.pageID }
        let runtime = layer?.runtime ?? drawing.runtime(for: match.pageID)
        let bounds: CGRect?
        let visible: Bool
        if runtime.nodesByID[match.objectID] != nil {
            editor.canvas.select([match.objectID]); bounds = runtime.nodeBoundsByID[match.objectID]; visible = runtime.isVisible(nodeID: match.objectID)
        } else if runtime.edgesByID[match.objectID] != nil {
            editor.canvas.select([], edge: match.objectID); bounds = layer?.routeBounds[match.objectID] ?? runtime.edgeBoundsByID[match.objectID]; visible = runtime.isVisible(edgeID: match.objectID)
        } else { reasonLabel.stringValue = "This result no longer exists. Find again."; return false }
        if let bounds {
            let zoom = editor.canvas.coordinateZoom, origin = editor.canvas.pageOrigin
            editor.canvas.scrollToVisible(CGRect(x: origin.x + bounds.minX * zoom, y: origin.y + bounds.minY * zoom,
                                                width: max(24, bounds.width * zoom), height: max(24, bounds.height * zoom)).insetBy(dx: -20, dy: -20))
        }
        if !visible { summary.stringValue = "This result is on a hidden layer. Its layer visibility is unchanged." }
        return true
    }
    private func finishParentEditing(_ editor: EditorWindowController) -> Bool {
        if (editor.window?.firstResponder as? NSTextView)?.hasMarkedText() == true {
            summary.stringValue = "Finish text composition before navigating or replacing text."; return false
        }
        editor.window?.makeFirstResponder(editor.canvas)
        editor.canvas.finishEditing(commit: true)
        return true
    }
    @objc func nextResult(_ sender: Any?) { moveSelection(1) }
    @objc func previousResult(_ sender: Any?) { moveSelection(-1) }
    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        let previous = table.selectedRow
        let row = (max(0, table.selectedRow) + delta + results.count) % results.count
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); table.scrollRowToVisible(row)
        if row == previous { _ = navigate(to: results[row]) }
    }
    @objc private func closePanel(_ sender: Any?) { close() }
}
