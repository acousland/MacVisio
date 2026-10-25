import AppKit

/// The File tab's backstage view, organised as Microsoft Visio 2019's: a command column (Info, New, Open,
/// Save, Save As, Print, Share, Export, Close, then Account and Options) beside the selected page.
/// Every command calls the editor's existing action.
final class BackstageView: FlippedView {
    private weak var editor: EditorWindowController?
    private let column = FlippedView()
    private let content = FlippedView()
    private var buttons: [String: NSButton] = [:]
    private(set) var selected = "Info"
    static let pages = ["Info", "New", "Open", "Save", "Save As", "Print", "Share", "Export", "Close", "Account", "Options"]
    /// Pages that act immediately in Visio rather than showing a page.
    private static let immediate: Set<String> = ["Save", "Close"]

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("backstage")
        wantsLayer = true; column.wantsLayer = true; content.wantsLayer = true
        addSubview(column); addSubview(content)
        let back = symbolButton("arrow.left.circle", label: "Back", target: self, action: #selector(close(_:)))
        back.identifier = NSUserInterfaceItemIdentifier("backstageBack")
        back.contentTintColor = .white
        back.frame = CGRect(x: 16, y: 16, width: 32, height: 32)
        column.addSubview(back)
        var y: CGFloat = 70
        for page in Self.pages {
            if page == "Account" { y += 40 }
            let button = NSButton(title: page, target: self, action: #selector(pagePressed(_:)))
            button.isBordered = false
            button.alignment = .left
            button.identifier = NSUserInterfaceItemIdentifier("backstage_" + page)
            button.setAccessibilityLabel(page)
            button.frame = CGRect(x: 0, y: y, width: 160, height: 36)
            button.wantsLayer = true
            column.addSubview(button)
            buttons[page] = button
            y += 38
        }
        refreshColors()
        show("Info")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        column.frame = CGRect(x: 0, y: 0, width: 160, height: bounds.height)
        content.frame = CGRect(x: 160, y: 0, width: max(0, bounds.width - 160), height: bounds.height)
    }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }

    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.column.layer?.backgroundColor = EditorPalette.backstage.cgColor
            self.content.layer?.backgroundColor = EditorPalette.ribbon.cgColor
            for (page, button) in self.buttons {
                let current = page == self.selected
                button.attributedTitle = NSAttributedString(string: "      " + page, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white])
                button.layer?.backgroundColor = current ? NSColor.white.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
            }
        }
    }

    @objc private func pagePressed(_ sender: NSButton) {
        guard let page = sender.identifier?.rawValue.replacingOccurrences(of: "backstage_", with: "") else { return }
        if Self.immediate.contains(page) {
            close(nil)
            if page == "Save" { editor?.diagramDocument.save(nil) } else { editor?.window?.performClose(nil) }
            return
        }
        show(page)
    }

    func show(_ page: String) {
        selected = page
        refreshColors()
        content.subviews.forEach { $0.removeFromSuperview() }
        let title = uiLabel(page, size: 28)
        title.frame = CGRect(x: 40, y: 32, width: 600, height: 40)
        content.addSubview(title)
        var y: CGFloat = 96
        func action(_ label: String, _ detail: String, _ symbol: String, _ selector: Selector?, target: AnyObject? = nil, id: String? = nil) {
            let button = NSButton(title: label, image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: target ?? editor, action: selector)
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded
            button.isEnabled = selector != nil
            button.toolTip = selector == nil ? "\(label) — not yet available in MacVisio" : detail
            if let id { button.identifier = NSUserInterfaceItemIdentifier(id) }
            button.frame = CGRect(x: 40, y: y, width: 260, height: 32)
            content.addSubview(button)
            let note = uiLabel(detail, size: 12)
            note.textColor = .secondaryLabelColor
            note.frame = CGRect(x: 312, y: y + 7, width: 520, height: 18)
            content.addSubview(note)
            y += 44
        }
        typealias E = EditorWindowController
        switch page {
        case "Info":
            let name = editor?.diagramDocument.fileURL?.path ?? editor?.diagramDocument.displayName ?? ""
            let path = uiLabel(name, size: 12); path.textColor = .secondaryLabelColor
            path.frame = CGRect(x: 40, y: 72, width: 800, height: 18); content.addSubview(path)
            action("Check Drawing", "Look for content that may not survive saving.", "checkmark.seal", #selector(E.checkDrawingContent(_:)))
            action("Drawing Issues", "Review import, calculation and font issues.", "exclamationmark.triangle", #selector(E.showDocumentIssues(_:)))
            action("Properties", "Title, subject and other document properties.", "info.circle", nil)
        case "New":
            action("Blank Drawing", "Start a new drawing.", "doc.badge.plus", #selector(BackstageView.newDrawing(_:)), target: self)
            action("Templates", "Choose a template from the start screen.", "square.grid.2x2", #selector(BackstageView.showTemplates(_:)), target: self)
        case "Open":
            action("Browse…", "Open a drawing, stencil or template.", "folder", #selector(BackstageView.openDrawing(_:)), target: self)
            for url in NSDocumentController.shared.recentDocumentURLs.prefix(8) {
                let recent = NSButton(title: url.lastPathComponent, target: self, action: #selector(openRecent(_:)))
                recent.bezelStyle = .recessed; recent.toolTip = url.path
                recent.identifier = NSUserInterfaceItemIdentifier(url.path)
                recent.frame = CGRect(x: 40, y: y, width: 420, height: 26); content.addSubview(recent); y += 30
            }
        case "Save As":
            action("Save As…", "Save a copy under another name or format.", "square.and.arrow.down.on.square", #selector(NSDocument.saveAs(_:)), target: editor?.diagramDocument)
        case "Print":
            action("Print…", "Print the drawing at its physical page size.", "printer", #selector(E.printDiagram(_:)))
        case "Share":
            action("Share", "Share with people.", "person.2", nil)
        case "Export":
            action("Create PDF", "Export the current page as PDF.", "doc.richtext", #selector(E.exportPDF(_:)))
            action("Create PDF of All Pages", "Export every foreground page.", "doc.on.doc", #selector(E.exportAllPagesPDF(_:)))
            action("PNG Image", "Export as a PNG picture.", "photo", #selector(E.exportPNG(_:)))
            action("JPEG Image", "Export as a JPEG picture.", "photo", #selector(E.exportJPEG(_:)))
            action("TIFF Image", "Export as a TIFF picture.", "photo", #selector(E.exportTIFF(_:)))
            action("SVG Drawing", "Export as Scalable Vector Graphics.", "scribble.variable", #selector(E.exportSVG(_:)))
            action("Visio Drawing (.vsdx)", "Save a copy as a Visio drawing.", "square.and.arrow.up", #selector(E.exportVSDX(_:)))
            action("Visio 2003-2010 Drawing (.vsd)", "Save a copy in the binary format.", "archivebox", #selector(E.exportVSD(_:)))
            action("Visio Template (.vstx)", "Save a copy as a template.", "doc.badge.gearshape", #selector(E.exportTemplate(_:)))
        case "Account":
            let label = uiLabel("Office Theme", size: 13); label.frame = CGRect(x: 40, y: y + 4, width: 120, height: 20); content.addSubview(label)
            let popup = NSPopUpButton(frame: CGRect(x: 170, y: y, width: 200, height: 26), pullsDown: false)
            popup.addItems(withTitles: ["Dark", "Light", "System"])
            popup.selectItem(withTitle: EditorAppearance.selection.capitalized)
            popup.identifier = NSUserInterfaceItemIdentifier("appearance")
            popup.setAccessibilityLabel("App appearance")
            popup.target = self; popup.action = #selector(appearanceChanged(_:))
            content.addSubview(popup)
        case "Options":
            let snap = NSButton(checkboxWithTitle: "Snap to grid", target: editor, action: #selector(E.toggleSnap(_:)))
            snap.state = editor?.canvas.snapsToGrid == true ? .on : .off
            snap.frame = CGRect(x: 40, y: y, width: 300, height: 22); content.addSubview(snap)
            let grid = NSButton(checkboxWithTitle: "Show grid", target: editor, action: #selector(E.toggleGrid(_:)))
            grid.state = editor?.canvas.showsGrid == true ? .on : .off
            grid.frame = CGRect(x: 40, y: y + 30, width: 300, height: 22); content.addSubview(grid)
        default: break
        }
    }

    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.title.lowercased(), ["dark", "light", "system"].contains(raw) else { return }
        editor?.root.ribbon.onAppearanceChanged?(raw)
    }
    @objc func newDrawing(_ sender: Any?) { close(nil); (NSApp.delegate as? AppDelegate)?.newDocument(sender) }
    @objc func showTemplates(_ sender: Any?) {
        close(nil)
        (editor?.diagramDocument.documentWorkflow ?? (NSApp.delegate as? AppDelegate)?.workflow)?.showWelcome()
    }
    @objc func openDrawing(_ sender: Any?) { close(nil); (NSApp.delegate as? AppDelegate)?.openDocument(sender) }
    @objc private func openRecent(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        close(nil)
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { _, _, _ in }
    }
    @objc func close(_ sender: Any?) { removeFromSuperview() }
}

extension EditorWindowController {
    /// File: Visio's backstage view over the editor.
    @objc func showBackstage(_ sender: Any?) {
        canvas.finishPageInteraction()
        if let existing = root.subviews.first(where: { $0 is BackstageView }) { existing.removeFromSuperview() }
        let backstage = BackstageView(editor: self)
        backstage.frame = root.bounds
        backstage.autoresizingMask = [.width, .height]
        root.addSubview(backstage)
    }
    var showsRulers: Bool { canvas.showsRulers }
    @objc func toggleRulers(_ sender: Any?) { canvas.showsRulers.toggle(); root.ribbon.refreshSelection() }
    /// Design > Orientation: swaps the page's paper width and height when they disagree with the request.
    func setPageOrientation(landscape: Bool) {
        let page = diagramDocument.diagram.page
        guard (page.width > page.height) != landscape, page.width != page.height else { return }
        configurePage(width: page.height, height: page.width)
    }
    /// "Tell me what you want to do": opens command search with the typed text.
    func showCommandSearch(query: String) {
        showCommandSearch(nil)
        commandSearchController.searchField.stringValue = query
        commandSearchController.filterCommands()
    }
}
