import AppKit

enum WelcomeSection: Hashable {
    case home
    case new
    case open
}

struct RecentDrawing {
    let url: URL
    let title: String
    let location: String
    let isPinned: Bool
}

enum WelcomeWindowLayout {
    static let preferredContentSize = NSSize(width: 780, height: 640)
    static let minimumContentSize = NSSize(width: 480, height: 440)

    static func frame(_ frame: NSRect, fitting visibleFrame: NSRect) -> NSRect {
        let available = visibleFrame.insetBy(dx: 16, dy: 16)
        let size = NSSize(width: min(frame.width, available.width), height: min(frame.height, available.height))
        return NSRect(x: min(max(frame.minX, available.minX), available.maxX - size.width),
                      y: min(max(frame.minY, available.minY), available.maxY - size.height),
                      width: size.width, height: size.height)
    }

    static func templateColumns(for width: CGFloat) -> Int {
        max(1, min(3, Int((width + 12) / 212)))
    }
}

/// The reusable start window shown before a drawing is open.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private let onNew: (DiagramTemplate) -> Void
    private let onOpen: () -> Void
    private let onRecent: (URL) -> Void
    private let onPin: (URL) -> Void
    private let onLocate: ((URL) -> Void)?
    private let onRemove: ((URL) -> Void)?
    private let onBack: () -> Void
    private let onSave: (() -> Void)?
    private let onSaveAs: (() -> Void)?
    private let onClose: (() -> Void)?

    private var recents: [RecentDrawing] = []
    private var section: WelcomeSection = .home
    private var canGoBack = false
    private var searchText = ""

    private var sectionButtons: [WelcomeSection: NSButton] = [:]
    private var backButton: NSButton?
    private var documentActionSection: NSStackView?
    private let titleLabel = NSTextField(labelWithString: "Home")
    private let subtitleLabel = NSTextField(labelWithString: "Create a drawing or open a recent file.")
    private let searchField = NSSearchField()
    private let bodyStack = WelcomeBodyStack(frame: .zero)
    private weak var bodyScrollView: NSScrollView?
    private let progressIndicator = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private var progressView: NSStackView?
    private var openingName: String?
    private var templateColumns = 3
    private var isUpdatingLayout = false

    init(onNew: @escaping (DiagramTemplate) -> Void,
         onOpen: @escaping () -> Void,
         onRecent: @escaping (URL) -> Void,
         onPin: @escaping (URL) -> Void,
         onBack: @escaping () -> Void,
         onSave: (() -> Void)? = nil,
         onSaveAs: (() -> Void)? = nil,
         onClose: (() -> Void)? = nil,
         onLocate: ((URL) -> Void)? = nil,
         onRemove: ((URL) -> Void)? = nil) {
        self.onNew = onNew
        self.onOpen = onOpen
        self.onRecent = onRecent
        self.onPin = onPin
        self.onBack = onBack
        self.onSave = onSave
        self.onSaveAs = onSaveAs
        self.onClose = onClose
        self.onLocate = onLocate
        self.onRemove = onRemove

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: WelcomeWindowLayout.preferredContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacVisio"
        window.contentMinSize = WelcomeWindowLayout.minimumContentSize
        window.autorecalculatesKeyViewLoop = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.center()
        super.init(window: window)

        configureWindow()
        buildInterface()
        refresh(recents: [], section: .home, canGoBack: false)
        fitWindowToScreen()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func refresh(recents: [RecentDrawing], section: WelcomeSection, canGoBack: Bool) {
        let enteringTemplates = section == .new && self.section != .new
        self.recents = recents
        self.section = section
        self.canGoBack = canGoBack
        updateNavigation()
        renderSection()
        if enteringTemplates, let first = templateKeyboardButtons(in: bodyStack).first {
            window?.initialFirstResponder = first
            window?.makeFirstResponder(first)
        }
    }

    private func templateKeyboardButtons(in view: NSView) -> [WelcomeKeyboardButton] {
        view.subviews.flatMap { child in
            if let button = child as? WelcomeKeyboardButton { return [button] }
            return templateKeyboardButtons(in: child)
        }
    }

    func refresh(recents: [RecentDrawing], canGoBack: Bool) {
        refresh(recents: recents, section: section, canGoBack: canGoBack)
    }

    override func showWindow(_ sender: Any?) {
        fitWindowToScreen()
        super.showWindow(sender)
        updateTemplateColumns()
        scrollBodyToTop()
    }

    private func fitWindowToScreen() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: WelcomeWindowLayout.minimumContentSize))
        window.minSize = NSSize(width: min(minimumFrame.width, available.width),
                                height: min(minimumFrame.height, available.height))
        window.setFrame(WelcomeWindowLayout.frame(window.frame, fitting: screen.visibleFrame), display: false)
    }

    /// Displays a lightweight progress banner while a selected drawing is being opened.
    func showOpening(_ name: String?) {
        openingName = name
        progressIndicator.isHidden = name == nil
        progressLabel.isHidden = name == nil
        progressView?.isHidden = name == nil
        if let name {
            progressLabel.stringValue = "Opening \(name)…"
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    private func configureWindow() {
        window?.backgroundColor = EditorPalette.panel
        window?.appearance = nil
        window?.delegate = self
        window?.contentView?.setAccessibilityIdentifier("welcomeWindow")
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.distribution = .fill
        root.translatesAutoresizingMaskIntoConstraints = false

        let background = AdaptiveSurfaceView(fill: EditorPalette.panel)
        background.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            background.topAnchor.constraint(equalTo: content.topAnchor),
            background.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        content.addSubview(root)

        let header = makeHeader()
        let main = makeMainPane()
        let footer = makeDocumentActions()
        root.addArrangedSubview(header)
        root.addArrangedSubview(main)
        root.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            main.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor)
        ])

    }

    private func makeHeader() -> NSView {
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false

        let brandMark = NSImageView()
        brandMark.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "MacVisio")
        brandMark.contentTintColor = EditorPalette.accent
        brandMark.translatesAutoresizingMaskIntoConstraints = false
        brandMark.widthAnchor.constraint(equalToConstant: 26).isActive = true
        brandMark.heightAnchor.constraint(equalToConstant: 26).isActive = true

        let brandName = NSTextField(labelWithString: "MacVisio")
        brandName.font = .systemFont(ofSize: 17, weight: .semibold)
        brandName.textColor = .labelColor
        let brand = NSStackView(views: [brandMark, brandName])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 10

        let browse = NSButton(title: "Open File…", target: self, action: #selector(openAction(_:)))
        browse.bezelStyle = .rounded
        browse.keyEquivalent = "o"
        browse.setAccessibilityLabel("Browse for a drawing")
        let brandRow = NSStackView(views: [brand, NSView(), browse])
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY

        let home = navigationButton("Home", symbol: "house", section: .home)
        let new = navigationButton("New", symbol: "plus.rectangle.on.rectangle", section: .new)
        let open = navigationButton("Open", symbol: "folder", section: .open)
        sectionButtons = [.home: home, .new: new, .open: open]

        let nav = NSStackView(views: [home, new, open])
        nav.orientation = .horizontal
        nav.alignment = .centerY
        nav.spacing = 6

        let stack = NSStackView(views: [brandRow, nav])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -14),
            brandRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            separator.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])
        header.setContentHuggingPriority(.required, for: .vertical)
        return header
    }

    private func makeDocumentActions() -> NSView {
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        let back = NSButton(frame: .zero)
        back.title = "Back to drawing"
        back.target = self
        back.action = #selector(backAction(_:))
        back.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)
        back.imagePosition = .imageLeading
        back.bezelStyle = .regularSquare
        back.isBordered = false
        back.contentTintColor = .secondaryLabelColor
        back.font = .systemFont(ofSize: 13)
        back.alignment = .left
        back.setAccessibilityLabel("Back to drawing")
        back.identifier = NSUserInterfaceItemIdentifier("welcomeBackButton")
        back.tag = 900
        back.keyEquivalent = "\u{1b}"
        backButton = back

        var views: [NSView] = [back, NSView()]
        if onSave != nil { views.append(documentActionButton("Save", action: #selector(saveAction(_:)))) }
        if onSaveAs != nil { views.append(documentActionButton("Save As…", action: #selector(saveAsAction(_:)))) }
        if onClose != nil { views.append(documentActionButton("Close Drawing", action: #selector(closeAction(_:)))) }
        let stack = NSStackView(views: views)
        documentActionSection = stack
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: footer.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -14)
        ])
        footer.isHidden = true
        footer.setContentHuggingPriority(.required, for: .vertical)
        return footer
    }

    private func documentActionButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.identifier = NSUserInterfaceItemIdentifier("welcomeDocumentAction.\(title)")
        return button
    }

    private func navigationButton(_ title: String, symbol: String, section: WelcomeSection) -> NSButton {
        let button = AdaptiveNavigationButton(frame: .zero)
        button.title = title
        button.target = self
        button.action = #selector(sectionAction(_:))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.alignment = .center
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = .systemFont(ofSize: 14, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityLabel(title)
        button.tag = section.tagValue
        button.identifier = NSUserInterfaceItemIdentifier("welcomeSection.\(title.lowercased())")
        button.widthAnchor.constraint(equalToConstant: 88).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func makeMainPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let heading = NSStackView(views: [titleLabel, subtitleLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 7
        heading.setContentHuggingPriority(.required, for: .vertical)

        searchField.placeholderString = "Search recent drawings"
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityLabel("Search recent drawings")
        searchField.drawsBackground = true
        searchField.backgroundColor = EditorPalette.panel
        searchField.textColor = .labelColor

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 16
        bodyStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        scroll.documentView = bodyStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bodyScrollView = scroll

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isHidden = true
        progressLabel.font = .systemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.lineBreakMode = .byTruncatingMiddle
        progressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progressLabel.isHidden = true
        let progress = NSStackView(views: [progressIndicator, progressLabel])
        progress.orientation = .horizontal
        progress.alignment = .centerY
        progress.spacing = 8
        progress.isHidden = true
        progressView = progress

        let column = NSStackView(views: [heading, searchField, scroll, progress])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 16
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -24),
            column.topAnchor.constraint(equalTo: pane.topAnchor, constant: 20),
            column.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -16),
            heading.widthAnchor.constraint(equalTo: column.widthAnchor),
            subtitleLabel.widthAnchor.constraint(equalTo: heading.widthAnchor),
            heading.heightAnchor.constraint(equalToConstant: titleLabel.fittingSize.height + subtitleLabel.fittingSize.height + 7),
            searchField.widthAnchor.constraint(equalTo: column.widthAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 24),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),
            progress.widthAnchor.constraint(equalTo: column.widthAnchor),
            progress.heightAnchor.constraint(equalToConstant: 16),
            bodyStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return pane
    }

    private func updateNavigation() {
        for (value, button) in sectionButtons {
            let selected = value == section
            button.contentTintColor = selected ? EditorPalette.accent : .secondaryLabelColor
            button.font = .systemFont(ofSize: 14, weight: selected ? .semibold : .medium)
            (button as? AdaptiveNavigationButton)?.isCurrent = selected
        }
        backButton?.isHidden = !canGoBack
        documentActionSection?.isHidden = !canGoBack
        documentActionSection?.superview?.isHidden = !canGoBack
    }

    private func renderSection() {
        switch section {
        case .home:
            titleLabel.stringValue = "Home"
            subtitleLabel.stringValue = "Create a drawing or open a recent file."
            searchField.isHidden = false
            searchField.placeholderString = "Search recent drawings"
            renderHome()
        case .new:
            titleLabel.stringValue = "New diagram"
            subtitleLabel.stringValue = "Select a template to create a drawing."
            searchField.isHidden = true
            renderTemplates()
        case .open:
            titleLabel.stringValue = "Open"
            subtitleLabel.stringValue = "Browse for a drawing or open one from your recent files."
            searchField.isHidden = false
            searchField.placeholderString = "Search recent drawings"
            renderOpen()
        }
        scrollBodyToTop()
    }

    private func renderHome() {
        clearBody()
        appendBody(templateGrid(limit: 3))
        appendBody(sectionHeading("Recent", detail: ""))
        addRecentContent(to: bodyStack)
    }

    private func renderTemplates() {
        clearBody()
        appendBody(templateGrid())
    }

    private func renderOpen() {
        clearBody()
        let browse = makeBrowseCard()
        appendBody(browse)
        appendBody(sectionHeading("Recent", detail: "Open a drawing you have worked on recently."))
        addRecentContent(to: bodyStack)
    }

    private func appendBody(_ view: NSView) {
        bodyStack.addView(view, in: .top)
        view.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
    }

    private func scrollBodyToTop() {
        guard let scroll = bodyScrollView else { return }
        window?.contentView?.layoutSubtreeIfNeeded()
        bodyStack.layoutSubtreeIfNeeded()
        let clipView = scroll.contentView
        let documentHeight = bodyStack.bounds.height
        let visibleHeight = clipView.bounds.height
        let topY = bodyStack.isFlipped ? CGFloat.zero : max(documentHeight - visibleHeight, 0)
        clipView.scroll(to: NSPoint(x: 0, y: topY))
        scroll.reflectScrolledClipView(clipView)
    }

    func windowDidResize(_ notification: Notification) {
        updateTemplateColumns()
        scrollBodyToTop()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        fitWindowToScreen()
        updateTemplateColumns()
    }

    private func updateTemplateColumns() {
        guard !isUpdatingLayout, let content = window?.contentView else { return }
        isUpdatingLayout = true
        defer { isUpdatingLayout = false }
        content.layoutSubtreeIfNeeded()
        let columns = WelcomeWindowLayout.templateColumns(for: bodyScrollView?.contentView.bounds.width ?? 0)
        guard columns != templateColumns else { return }
        templateColumns = columns
        renderSection()
    }

    private func clearBody() {
        for view in bodyStack.arrangedSubviews {
            bodyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func templateGrid(limit: Int? = nil) -> NSView {
        let templates = Array(DiagramTemplate.allCases.prefix(limit ?? DiagramTemplate.allCases.count))
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 12
        grid.identifier = NSUserInterfaceItemIdentifier("welcomeTemplateGrid")
        for start in stride(from: 0, to: templates.count, by: templateColumns) {
            let end = min(start + templateColumns, templates.count)
            var cards: [NSView] = templates[start..<end].map { TemplateCard(template: $0, compact: limit != nil, target: self, action: #selector(templateAction(_:))) }
            while cards.count < templateColumns {
                let spacer = NSView()
                spacer.translatesAutoresizingMaskIntoConstraints = false
                cards.append(spacer)
            }
            let row = NSStackView(views: cards)
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 12
            grid.addView(row, in: .top)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            for card in cards.dropFirst() {
                card.widthAnchor.constraint(equalTo: cards[0].widthAnchor).isActive = true
            }
        }
        return grid
    }

    private func sectionHeading(_ title: String, detail: String) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.textColor = .labelColor
        if detail.isEmpty { return name }
        let note = NSTextField(labelWithString: detail)
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [name, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeBrowseCard() -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        icon.contentTintColor = EditorPalette.accent
        icon.imageScaling = .scaleProportionallyDown

        let title = NSTextField(labelWithString: "Browse files")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let note = NSTextField(labelWithString: "Open a MacVisio drawing or supported Visio file.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, note])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        note.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true

        let browse = NSButton(title: "Browse…", target: self, action: #selector(openAction(_:)))
        browse.bezelStyle = .rounded
        browse.controlSize = .large
        browse.keyEquivalent = "o"
        browse.setAccessibilityLabel("Browse for a drawing")

        let row = NSStackView(views: [icon, text, browse])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let card = borderedCard()
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18)
        ])
        return card
    }

    private func addRecentContent(to stack: NSStackView) {
        let visible = filteredRecents
        if visible.isEmpty {
            let empty = makeEmptyRecentState(hasSearch: !searchText.isEmpty)
            stack.addView(empty, in: .top)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return
        }
        let rows = AdaptiveStackView(fill: EditorPalette.ribbon, border: EditorPalette.border, radius: 9)
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 2
        for recent in visible {
            let row = RecentDrawingRow(drawing: recent, target: self,
                                       openAction: #selector(recentAction(_:)),
                                       pinAction: #selector(pinAction(_:)),
                                       locateAction: #selector(locateRecentAction(_:)),
                                       removeAction: #selector(removeRecentAction(_:)))
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        stack.addView(rows, in: .top)
        rows.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeEmptyRecentState(hasSearch: Bool) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: hasSearch ? "magnifyingglass" : "doc.text", accessibilityDescription: nil)
        icon.contentTintColor = .tertiaryLabelColor
        let title = NSTextField(labelWithString: hasSearch ? "No matching drawings" : "Your recent drawings will appear here")
        title.font = .systemFont(ofSize: 14, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let message = NSTextField(wrappingLabelWithString: hasSearch ? "Try another name or folder." : "Choose a template to create your first diagram, or open an existing file.")
        message.font = .systemFont(ofSize: 12)
        message.textColor = .tertiaryLabelColor
        message.maximumNumberOfLines = 2
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, message])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5
        title.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        message.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 26).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 26).isActive = true
        let card = borderedCard()
        card.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 19),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -19)
        ])
        return card
    }

    private func borderedCard() -> NSView {
        let card = AdaptiveSurfaceView(fill: EditorPalette.ribbon, border: EditorPalette.border, radius: 10)
        card.translatesAutoresizingMaskIntoConstraints = false
        return card
    }

    private var filteredRecents: [RecentDrawing] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recents }
        return recents.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.location.localizedCaseInsensitiveContains(query) ||
            $0.url.lastPathComponent.localizedCaseInsensitiveContains(query)
        }
    }

    @objc private func sectionAction(_ sender: NSButton) {
        section = sectionButtons.first(where: { $0.value.tag == sender.tag })?.key ?? .home
        searchText = ""
        searchField.stringValue = ""
        updateNavigation()
        renderSection()
    }

    @objc private func templateAction(_ sender: NSButton) {
        guard let raw = payload(from: sender, prefix: "welcomeTemplate."),
              let template = DiagramTemplate(rawValue: raw) else { return }
        onNew(template)
    }

    @objc private func openAction(_ sender: NSButton) { onOpen() }

    @objc private func locateRecentAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }; onLocate?(url)
    }
    @objc private func removeRecentAction(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }; onRemove?(url)
    }
    @objc private func recentAction(_ sender: NSButton) {
        guard let path = payload(from: sender, prefix: "welcomeRecent."),
              let recent = recents.first(where: { $0.url.path == path }) else { return }
        onRecent(recent.url)
    }

    @objc private func pinAction(_ sender: NSButton) {
        guard let path = payload(from: sender, prefix: "welcomePin."),
              let recent = recents.first(where: { $0.url.path == path }) else { return }
        onPin(recent.url)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchText = sender.stringValue
        switch section {
        case .home: renderHome()
        case .open: renderOpen()
        case .new: break
        }
    }

    @objc private func backAction(_ sender: Any?) {
        guard canGoBack else { return }
        onBack()
    }

    @objc private func saveAction(_ sender: Any?) {
        guard canGoBack else { return }
        onSave?()
    }

    @objc private func saveAsAction(_ sender: Any?) {
        guard canGoBack else { return }
        onSaveAs?()
    }

    @objc private func closeAction(_ sender: Any?) {
        guard canGoBack else { return }
        onClose?()
    }

    private func payload(from button: NSButton, prefix: String) -> String? {
        guard let value = button.identifier?.rawValue, value.hasPrefix(prefix) else { return nil }
        return String(value.dropFirst(prefix.count))
    }
}

private extension WelcomeSection {
    var tagValue: Int {
        switch self {
        case .home: return 1
        case .new: return 2
        case .open: return 3
        }
    }
}

private class AdaptiveSurfaceView: NSView {
    private let fillColor: NSColor
    private let borderColor: NSColor?
    private let cornerRadius: CGFloat

    init(fill: NSColor, border: NSColor? = nil, radius: CGFloat = 0) {
        fillColor = fill
        borderColor = border
        cornerRadius = radius
        super.init(frame: .zero)
        wantsLayer = true
        updateSurface()
    }

    override var wantsUpdateLayer: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() { updateSurface() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    private func updateSurface() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fillColor.cgColor
            layer.borderColor = borderColor?.cgColor
        }
        layer.cornerRadius = cornerRadius
        layer.borderWidth = borderColor == nil ? 0 : 1
    }
}

private final class AdaptiveStackView: NSStackView {
    private let fillColor: NSColor
    private let borderColor: NSColor?
    private let cornerRadius: CGFloat

    init(fill: NSColor, border: NSColor? = nil, radius: CGFloat = 0) {
        fillColor = fill
        borderColor = border
        cornerRadius = radius
        super.init(frame: .zero)
        wantsLayer = true
        updateSurface()
    }

    override var wantsUpdateLayer: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() { updateSurface() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    private func updateSurface() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = fillColor.cgColor
            layer.borderColor = borderColor?.cgColor
        }
        layer.cornerRadius = cornerRadius
        layer.borderWidth = borderColor == nil ? 0 : 1
    }
}

private class WelcomeKeyboardButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 7, yRadius: 7).fill() }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") { performClick(nil) }
        else { super.keyDown(with: event) }
    }
}

private final class AdaptiveNavigationButton: WelcomeKeyboardButton {
    var isCurrent = false { didSet { updateSurface() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateLayer() { updateSurface() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    private func updateSurface() {
        guard let layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = (isCurrent ? EditorPalette.hover : NSColor.clear).cgColor
        }
        layer.cornerRadius = 7
    }
}

private final class TemplateCard: AdaptiveSurfaceView {
    private let template: DiagramTemplate

    init(template: DiagramTemplate, compact: Bool, target: AnyObject?, action: Selector) {
        self.template = template
        super.init(fill: EditorPalette.ribbon, border: EditorPalette.border, radius: 10)
        translatesAutoresizingMaskIntoConstraints = false

        let iconTile = AdaptiveSurfaceView(fill: EditorPalette.hover, radius: 8)
        iconTile.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: template.symbol, accessibilityDescription: nil)
        icon.contentTintColor = EditorPalette.accent
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconTile.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22)
        ])

        let title = NSTextField(wrappingLabelWithString: template.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.maximumNumberOfLines = 2
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let subtitle = NSTextField(wrappingLabelWithString: template.subtitle)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 5

        let contents = NSStackView(views: [iconTile, text])
        contents.orientation = .vertical
        contents.alignment = .leading
        contents.spacing = 10
        contents.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contents)
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contents.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contents.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            contents.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
            iconTile.widthAnchor.constraint(equalToConstant: 36),
            iconTile.heightAnchor.constraint(equalToConstant: 36),
            text.widthAnchor.constraint(equalTo: contents.widthAnchor),
            title.widthAnchor.constraint(equalTo: contents.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: contents.widthAnchor)
        ])

        let button = WelcomeKeyboardButton(title: "", target: target, action: action)
        button.focusRingType = .exterior
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.identifier = NSUserInterfaceItemIdentifier("welcomeTemplate.\(template.rawValue)")
        button.setAccessibilityLabel("\(template.title). \(template.subtitle)")
        button.setAccessibilityRole(.button)
        button.toolTip = "\(template.title) — \(template.subtitle)"
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: compact ? 126 : 146)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private final class RecentDrawingRow: NSView {
    private weak var openButton: NSButton?

    init(drawing: RecentDrawing, target: AnyObject?, openAction: Selector, pinAction: Selector, locateAction: Selector, removeAction: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor

        let name = NSTextField(labelWithString: drawing.title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let location = NSTextField(labelWithString: drawing.location)
        location.font = .systemFont(ofSize: 11)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        location.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = NSStackView(views: [name, location])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolTip = drawing.url.path

        let path = drawing.url.path
        let pin = NSButton(title: "", target: target, action: pinAction)
        pin.image = NSImage(systemSymbolName: drawing.isPinned ? "pin.fill" : "pin", accessibilityDescription: nil)
        pin.contentTintColor = drawing.isPinned ? EditorPalette.accent : .tertiaryLabelColor
        pin.isBordered = false
        pin.identifier = NSUserInterfaceItemIdentifier("welcomePin.\(path)")
        pin.setAccessibilityLabel(drawing.isPinned ? "Unpin \(drawing.title)" : "Pin \(drawing.title)")
        pin.toolTip = drawing.isPinned ? "Unpin drawing" : "Pin drawing"

        let open = NSButton(title: "Open", target: target, action: openAction)
        open.bezelStyle = .rounded
        open.controlSize = .small
        open.identifier = NSUserInterfaceItemIdentifier("welcomeRecent.\(path)")
        open.setAccessibilityLabel("Open \(drawing.title)")
        openButton = open

        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.addItem(withTitle: "More")
        more.menu?.autoenablesItems = false
        for (title, action) in [("Locate…", locateAction), ("Remove from Recents", removeAction)] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target; item.representedObject = drawing.url; more.menu?.addItem(item)
        }
        more.identifier = NSUserInterfaceItemIdentifier("welcomeRecentActions.\(path)")
        more.setAccessibilityLabel("Actions for \(drawing.title)")
        more.toolTip = "Locate a moved drawing or remove its history entry. Files are never deleted."
        // Keep the actions menu compact so the drawing name and location take the row's spare width.
        more.setContentHuggingPriority(.required, for: .horizontal)
        more.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = NSStackView(views: [icon, labels, pin, open, more])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 22),
            name.widthAnchor.constraint(equalTo: labels.widthAnchor),
            location.widthAnchor.constraint(equalTo: labels.widthAnchor),
            pin.widthAnchor.constraint(equalToConstant: 28),
            pin.heightAnchor.constraint(equalToConstant: 28),
            open.widthAnchor.constraint(equalToConstant: 58),
            more.widthAnchor.constraint(equalToConstant: 76),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 58)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(drawing.title), \(drawing.location)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Clicking anywhere on the row other than its pin, Open or More controls opens the drawing.
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        openButton?.performClick(nil)
    }
}

/// A short scroll document starts at the top of its viewport.
private final class WelcomeBodyStack: NSStackView {
    override var isFlipped: Bool { true }
}
