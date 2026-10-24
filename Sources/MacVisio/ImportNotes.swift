import AppKit

extension Notification.Name {
    static let macVisioDiagnosticsDidChange = Notification.Name("MacVisio.documentDiagnosticsDidChange")
}

extension EditorWindowController {
    @objc func showImportNotes(_ sender: Any?) { showDocumentIssues(sender) }

    @objc func showDocumentIssues(_ sender: Any?) {
        if diagramDocument.issuesController == nil {
            diagramDocument.issuesController = DocumentIssuesController(document: diagramDocument)
        }
        diagramDocument.issuesController?.navigator = { [weak self] issue in
            self?.navigateDocumentDiagnostic(issue) ?? false
        }
        diagramDocument.issuesController?.reload()
        diagramDocument.issuesController?.showWindow(sender)
    }

    /// Rechecks membership in this document's current records and retained model.
    /// Merely possessing an object UUID from another document cannot navigate it.
    @discardableResult func navigateDocumentDiagnostic(_ diagnostic: DocumentDiagnostic) -> Bool {
        guard diagramDocument.currentDiagnostics.contains(diagnostic) else { return false }
        if let sheetID = diagnostic.target.definitionSheetID {
            guard let registry = diagramDocument.diagram.definitions else { return false }
            let sheets = [registry.documentSheet].compactMap { $0 }
                + (registry.masters + registry.styles).flatMap(\.sheets)
            guard let sheet = sheets.first(where: { $0.id == sheetID }),
                  diagnostic.source.definitionCell.map({ sheet.cell($0) != nil }) ?? true,
                  definitionSheetUnavailableReason == nil
            else { return false }
            showDefinitionSheet(sheetID: sheetID, address: diagnostic.source.definitionCell)
            let controller = definitionSheetController
            return controller.window?.isVisible == true && controller.selectedSheetID == sheetID
                && (diagnostic.source.definitionCell.map { controller.selectedAddress == $0 } ?? true)
        }
        guard let pageID = diagnostic.target.pageID,
            let page = diagramDocument.diagram.pages.first(where: { $0.id == pageID })
        else { return false }
        if let object = diagnostic.target.objectID,
            !page.nodes.contains(where: { $0.id == object })
                && !page.edges.contains(where: { $0.id == object })
        {
            return false
        }
        switchPage(pageID)
        var bounds: CGRect?
        let layer = retainedScene?.layers.first { $0.page.id == pageID }
        let runtime = layer?.runtime ?? diagramDocument.runtime(for: pageID)
        switch diagnostic.target {
        case .shape(_, let id):
            canvas.select([id])
            bounds = runtime.nodeBoundsByID[id]
        case .connector(_, let id):
            canvas.select([], edge: id)
            bounds = layer?.routeBounds[id] ?? runtime.edgeBoundsByID[id]
        case .page:
            canvas.select([])
            bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        case .document, .definition: return false
        }
        if let bounds {
            let zoom = canvas.coordinateZoom
            canvas.scrollToVisible(
                CGRect(
                    x: canvas.pageOrigin.x + bounds.minX * zoom,
                    y: canvas.pageOrigin.y + bounds.minY * zoom,
                    width: max(1, bounds.width * zoom), height: max(1, bounds.height * zoom)
                ).insetBy(dx: -20, dy: -20))
        }
        root?.status.toolTip = diagnostic.source.cell.map { "Authored cell: \($0)" }
        window?.makeFirstResponder(canvas)
        return true
    }
}

/// One pane belongs to one document. Its observer filters by document instance;
/// rows retain actual source provenance and never infer identities from prose.
final class DocumentIssuesController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private weak var diagramDocument: MacVisioDocument?
    private var observer: NSObjectProtocol?
    private(set) var records: [DocumentDiagnostic] = []
    var navigator: ((DocumentDiagnostic) -> Bool)?
    private let table = NSTableView()
    private let details = NSTextView()
    private let coverage = NSTextField(labelWithString: "")
    private let reveal = NSButton(title: "Reveal Target", target: nil, action: nil)

    init(document: MacVisioDocument) {
        diagramDocument = document
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Document Issues"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("issue"))
        column.title = "Origin · State · Issue"
        column.width = 720
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 26
        table.target = self
        table.doubleAction = #selector(revealSelected)
        let list = NSScrollView()
        list.hasVerticalScroller = true
        list.documentView = table
        details.isEditable = false
        details.isSelectable = true
        details.font = .systemFont(ofSize: 12)
        details.frame = CGRect(x: 0, y: 0, width: 720, height: 160)
        details.minSize = CGSize(width: 0, height: 160)
        details.maxSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        details.isVerticallyResizable = true
        details.isHorizontallyResizable = false
        details.autoresizingMask = [.width]
        details.textContainer?.widthTracksTextView = true
        details.textContainer?.containerSize = CGSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        details.textContainerInset = CGSize(width: 8, height: 8)
        details.setAccessibilityLabel("Selected issue details and authored cell")
        let detailScroll = NSScrollView()
        detailScroll.hasVerticalScroller = true
        detailScroll.documentView = details
        reveal.target = self
        reveal.action = #selector(revealSelected)
        reveal.isEnabled = false
        let stack = NSStackView(views: [coverage, list, detailScroll, reveal])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let content = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
                list.widthAnchor.constraint(equalTo: stack.widthAnchor),
                list.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
                detailScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                detailScroll.heightAnchor.constraint(equalToConstant: 160),
            ])
        }
        observer = NotificationCenter.default.addObserver(
            forName: .macVisioDiagnosticsDidChange, object: document, queue: .main
        ) { [weak self] _ in self?.reload() }
        reload()
    }
    required init?(coder: NSCoder) { nil }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func reload() {
        let selected =
            table.selectedRow >= 0 && table.selectedRow < records.count ? records[table.selectedRow].id : nil
        records = diagramDocument?.currentDiagnostics ?? []
        coverage.stringValue =
            "\(records.filter(\.isMaterial).count) material issues · Supplied producer records; coverage is incomplete"
        table.reloadData()
        if let selected, let row = records.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateDetails()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let issue = records[row]
        let text = NSTextField(
            labelWithString:
                "\(issue.severity.rawValue) · \(issue.origin.rawValue) · \(issue.displayState.rawValue) · \(issue.message)"
        )
        text.lineBreakMode = .byTruncatingTail
        return text
    }
    func tableViewSelectionDidChange(_ notification: Notification) { updateDetails() }
    private func updateDetails() {
        guard records.indices.contains(table.selectedRow) else {
            details.string = "Select an issue to inspect its source and cell."
            reveal.isEnabled = false
            return
        }
        let issue = records[table.selectedRow]
        details.string = [
            issue.message, "Code: \(issue.code)",
            "Dimension: \(issue.dimension.rawValue) · Display: \(issue.displayState.rawValue)",
            issue.source.cell.map { "Authored cell: \($0)" }, issue.source.part.map { "Source part: \($0)" },
            issue.source.visioID.map { "Source Visio ID: \($0)" },
            issue.target.definitionSheetID.map { "Definition sheet: \($0.uuidString)" },
            issue.target == .document ? "Document-wide record; no object target was supplied." : nil,
        ].compactMap { $0 }.joined(separator: "\n")
        reveal.isEnabled = issue.actions.contains(.revealTarget)
    }
    @objc private func revealSelected() {
        guard records.indices.contains(table.selectedRow) else { return }
        _ = navigator?(records[table.selectedRow])
    }
}
