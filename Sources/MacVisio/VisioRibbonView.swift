import AppKit
import UniformTypeIdentifiers

private final class RibbonCommandButton: NSButton {
    var verticalContent = true

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if state == .on || isHighlighted {
            (state == .on ? EditorPalette.hover : EditorPalette.panel).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let ink = (state == .on ? EditorPalette.accent : NSColor.labelColor).withAlphaComponent(isEnabled ? 1 : 0.42)
        let icon = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[ink])) ?? image
        if verticalContent {
            let iconSize: CGFloat = 21
            icon?.draw(in: CGRect(x: (bounds.width - iconSize) / 2, y: 7, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            (title as NSString).draw(in: CGRect(x: 3, y: 32, width: bounds.width - 6, height: 25), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: state == .on ? .medium : .regular),
                .foregroundColor: ink,
                .paragraphStyle: paragraph
            ])
        } else {
            let iconSize: CGFloat = 13
            icon?.draw(in: CGRect(x: 5, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in: CGRect(x: 21, y: (bounds.height-13)/2, width: bounds.width - 24, height: 13), withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: state == .on ? .medium : .regular),
                .foregroundColor: ink,
                .paragraphStyle: paragraph
            ])
        }
    }
}

/// A compact, native AppKit ribbon for the diagram editor.
/// Commands are routed to the editor's existing actions so the ribbon and menu
/// remain two ways to operate the same document features.
final class VisioRibbonView: FlippedView, NSTextFieldDelegate, NSComboBoxDelegate {
    private weak var editor: EditorWindowController?
    private let tabBar = FlippedView()
    private let commandScroll = NSScrollView()
    private let commandContent = FlippedView()
    private let tabNames = ["File", "Home", "Insert", "Design", "Data", "Review", "View"]
    private var tabButtons: [String:NSButton] = [:]
    private var tabUnderlines: [String:NSView] = [:]
    private var selectedTab = "Home"
    private var toolButtons: [CanvasTool:NSButton] = [:]
    private var fontFamily = NSComboBox()
    private var fontSize = NSComboBox()
    private var fillWell = NSColorWell()
    private var lineWell = NSColorWell()
    private var textWell = NSColorWell()
    private var appearancePopup = NSPopUpButton()
    private var fontFamilyEditing = false
    private var fontSizeEditing = false
    private var builtTab: String?

    /// The caller owns appearance persistence and application-wide appearance.
    var onAppearanceChanged: ((String) -> Void)?

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 144))
        wantsLayer = true
        layer?.backgroundColor = EditorPalette.ribbon.cgColor
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = EditorPalette.ribbon.cgColor
        commandScroll.drawsBackground = true
        commandScroll.backgroundColor = EditorPalette.ribbon
        commandScroll.borderType = .noBorder
        commandScroll.hasHorizontalScroller = true
        commandScroll.hasVerticalScroller = false
        commandScroll.autohidesScrollers = false
        commandScroll.horizontalScroller?.controlSize = .mini
        commandScroll.documentView = commandContent
        addSubview(tabBar)
        addSubview(commandScroll)
        buildTabs()
        selectTab("Home")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        tabBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 32)
        commandScroll.frame = CGRect(x: 0, y: 32, width: bounds.width, height: max(0, bounds.height - 32))
        layoutTabs()
        buildCommandArea(force: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = EditorPalette.ribbon.cgColor
            self.tabBar.layer?.backgroundColor = EditorPalette.ribbon.cgColor
            self.commandScroll.backgroundColor = EditorPalette.ribbon
            self.applyTabStyles()
        }
    }

    func selectTab(_ name: String) {
        guard tabNames.contains(name) else { return }
        if fontFamilyEditing || fontSizeEditing { editor?.window?.makeFirstResponder(editor?.canvas) }
        selectedTab = name
        effectiveAppearance.performAsCurrentDrawingAppearance { self.applyTabStyles() }
        buildCommandArea(force: true)
        refreshSelection()
    }

    private func applyTabStyles() {
        for (tab, button) in tabButtons {
            let selected = tab == selectedTab
            button.state = selected ? .on : .off
            button.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
            button.contentTintColor = tab == "File" && selected ? NSColor.white : NSColor.labelColor
            button.wantsLayer = true
            button.layer?.backgroundColor = tab == "File" && selected ? NSColor(hex:"#3955A3").cgColor : (selected ? EditorPalette.panel.cgColor : NSColor.clear.cgColor)
            tabUnderlines[tab]?.layer?.backgroundColor = selected ? EditorPalette.accent.cgColor : NSColor.clear.cgColor
        }
    }

    /// Refreshes selection-sensitive controls without replacing the ribbon or
    /// stealing focus from a font field the user is currently editing.
    func refreshSelection() {
        guard let editor else { return }
        let selection = editor.selection
        let editable = !editor.editableSelectionIDs.isEmpty
        let canFormatText = editor.canvas.isEditingText || !selection.isEmpty
        for (tool, button) in toolButtons { button.state = editor.canvas.tool == tool ? .on : .off }
        for button in descendants(of: commandContent).compactMap({ $0 as? NSButton }) {
            switch button.identifier?.rawValue {
            case "cut", "copy": button.isEnabled = !selection.isEmpty || editor.canvas.selectedEdge != nil
            case "paste": button.isEnabled = NSPasteboard.general.data(forType: CanvasView.fragmentPasteboardType) != nil
            case "fontBold", "fontItalic", "fontUnderline": button.isEnabled = canFormatText
            case "fillColor", "lineColor", "textColor": button.isEnabled = editable
            case "group": button.isEnabled = selection.count >= 2
            case "ungroup": button.isEnabled = selection.contains(where: { $0.formatting.isGroup })
            case "distributeHorizontal": button.isEnabled = selection.count >= 3
            case "front", "back", "lock", "alignLeft", "alignCenter", "alignTop": button.isEnabled = !selection.isEmpty
            case "shapeData", "shapeSheet", "geometry", "controls", "connectionPoints", "hyperlinks", "followLink": button.isEnabled = selection.count == 1
            case "exportStencil": button.isEnabled = !selection.isEmpty || editor.canvas.selectedEdge != nil
            default: break
            }
        }
        for well in descendants(of: commandContent).compactMap({ $0 as? NSColorWell }) { well.isEnabled = editable }
        for combo in descendants(of: commandContent).compactMap({ $0 as? NSComboBox }) {
            if combo === fontFamily || combo === fontSize { combo.isEnabled = canFormatText }
        }
        if !fontFamilyEditing { fontFamily.stringValue = selection.first.map { $0.formatting.fontName == "System" ? "System" : $0.formatting.fontName } ?? "System" }
        if !fontSizeEditing { fontSize.stringValue = selection.first.map { String(Int($0.fontSize.rounded())) } ?? "12" }
        if selectedTab == "View" { appearancePopup.selectItem(withTitle: EditorAppearance.selection.capitalized) }
        if !selection.isEmpty {
            fillWell.color = NSColor(hex: selection[0].fill)
            lineWell.color = NSColor(hex: selection[0].stroke)
            textWell.color = NSColor(hex: selection[0].textColor)
            if let node = selection.first {
                if let b = button(identifier: "fontBold") { b.state = node.bold ? .on : .off }
                if let b = button(identifier: "fontItalic") { b.state = node.formatting.italic ? .on : .off }
                if let b = button(identifier: "fontUnderline") { b.state = node.formatting.underline ? .on : .off }
            }
        }
        needsDisplay = true
    }

    private func button(identifier: String) -> NSButton? {
        descendants(of: commandContent).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func buildTabs() {
        for tab in tabNames {
            let button = NSButton(title: tab, target: self, action: #selector(tabPressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("tab_" + tab)
            button.setButtonType(.toggle)
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.alignment = .center
            button.setAccessibilityLabel("\(tab) ribbon tab")
            button.toolTip = "Show \(tab) commands"
            tabBar.addSubview(button)
            tabButtons[tab] = button
            let underline = NSView()
            underline.wantsLayer = true
            tabBar.addSubview(underline)
            tabUnderlines[tab] = underline
        }
        let bottomRule = NSBox()
        bottomRule.boxType = .separator
        bottomRule.identifier = NSUserInterfaceItemIdentifier("tabSeparator")
        tabBar.addSubview(bottomRule)
    }

    private func layoutTabs() {
        let widths: [CGFloat] = [58, 69, 70, 75, 63, 76, 65]
        var x: CGFloat = 8
        for (i, tab) in tabNames.enumerated() {
            let width = widths[i]
            tabButtons[tab]?.frame = CGRect(x: x, y: 1, width: width, height: 30)
            tabUnderlines[tab]?.frame = CGRect(x: x + 7, y: 29, width: width - 14, height: 2)
            x += width
        }
        if let separator = tabBar.subviews.first(where: { $0.identifier?.rawValue == "tabSeparator" }) as? NSBox {
            separator.frame = CGRect(x: 0, y: 31, width: bounds.width, height: 1)
        }
    }

    @objc private func tabPressed(_ sender: NSButton) {
        guard let tab = sender.identifier?.rawValue.replacingOccurrences(of: "tab_", with: "") else { return }
        selectTab(tab)
    }

    private func buildCommandArea(force: Bool) {
        guard let editor, force || builtTab != selectedTab else { return }
        builtTab = selectedTab
        commandContent.subviews.forEach { $0.removeFromSuperview() }
        toolButtons.removeAll()
        let width: CGFloat
        switch selectedTab {
        case "File": width = buildFile(editor)
        case "Home": width = buildHome(editor)
        case "Insert": width = buildInsert(editor)
        case "Design": width = buildDesign(editor)
        case "Data": width = buildData(editor)
        case "Review": width = buildReview(editor)
        default: width = buildView(editor)
        }
        commandContent.frame = CGRect(x: 0, y: 0, width: width, height: 96)
        commandScroll.contentView.scroll(to: .zero)
        commandScroll.reflectScrolledClipView(commandScroll.contentView)
        refreshSelection()
    }

    @discardableResult private func addGroup(_ title: String, width: CGFloat, x: inout CGFloat) -> FlippedView {
        let group = FlippedView(frame: CGRect(x: x, y: 0, width: width, height: 96))
        group.wantsLayer = true
        let caption = NSTextField(labelWithString: title)
        caption.font = .systemFont(ofSize: 9, weight: .medium)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.frame = CGRect(x: 3, y: 78, width: width - 6, height: 13)
        group.addSubview(caption)
        let separator = NSBox(frame: CGRect(x: width - 1, y: 8, width: 1, height: 67))
        separator.boxType = .separator
        group.addSubview(separator)
        commandContent.addSubview(group)
        x += width
        return group
    }

    @discardableResult private func addButton(_ group: NSView, title: String, symbol: String, x: CGFloat, y: CGFloat, width: CGFloat = 52, height: CGFloat = 58, action: Selector, target: AnyObject? = nil, identifier: String? = nil, vertical: Bool = true) -> NSButton {
        let button = RibbonCommandButton(title: title, target: target ?? editor, action: action)
        button.verticalContent = vertical
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.setButtonType(.momentaryPushIn)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = vertical ? .imageAbove : .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.font = .systemFont(ofSize: vertical ? 9 : 10, weight: .regular)
        button.alignment = .center
        button.toolTip = title
        button.setAccessibilityLabel(title)
        if let identifier { button.identifier = NSUserInterfaceItemIdentifier(identifier) }
        button.frame = CGRect(x: x, y: y, width: width, height: height)
        group.addSubview(button)
        return button
    }

    @discardableResult private func addCompactButton(_ group: NSView, title: String, symbol: String, x: CGFloat, y: CGFloat, width: CGFloat = 65, action: Selector, target: AnyObject? = nil, identifier: String? = nil) -> NSButton {
        addButton(group, title: title, symbol: symbol, x: x, y: y, width: width, height: 27, action: action, target: target, identifier: identifier, vertical: false)
    }

    private func addToolButton(_ group: NSView, tool: CanvasTool, title: String, symbol: String, x: CGFloat, y: CGFloat, editor: EditorWindowController) {
        let button = addButton(group, title: title, symbol: symbol, x: x, y: y, width: 76, height: 31, action: #selector(toolPressed(_:)), target: self, identifier: "tool_\(tool.rawValue)", vertical: false)
        button.setButtonType(.toggle)
        button.tag = tool.rawValue
        toolButtons[tool] = button
        button.target = self
    }

    private func addPopup(_ group: NSView, label: String, titles: [String], x: CGFloat, y: CGFloat, width: CGFloat, action: Selector, target: AnyObject? = nil, identifier: String? = nil) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: CGRect(x: x, y: y, width: width, height: 25), pullsDown: false)
        popup.addItems(withTitles: titles)
        popup.target = target ?? self
        popup.action = action
        popup.font = .systemFont(ofSize: 11)
        popup.setAccessibilityLabel(label)
        popup.toolTip = label
        if let identifier { popup.identifier = NSUserInterfaceItemIdentifier(identifier) }
        group.addSubview(popup)
        return popup
    }

    private func buildHome(_ editor: EditorWindowController) -> CGFloat {
        var x: CGFloat = 0
        let clipboard = addGroup("Clipboard", width: 132, x: &x)
        addButton(clipboard, title: "Paste", symbol: "doc.on.clipboard", x: 6, y: 10, width: 52, height: 60, action: #selector(paste(_:)), target: self, identifier: "paste")
        addCompactButton(clipboard, title: "Copy", symbol: "doc.on.doc", x: 62, y: 12, width: 62, action: #selector(copy(_:)), target: self, identifier: "copy")
        addCompactButton(clipboard, title: "Cut", symbol: "scissors", x: 62, y: 42, width: 62, action: #selector(cut(_:)), target: self, identifier: "cut")

        let font = addGroup("Font", width: 247, x: &x)
        fontFamily = NSComboBox(frame: CGRect(x: 7, y: 10, width: 145, height: 25))
        fontFamily.addItems(withObjectValues: ["System"] + NSFontManager.shared.availableFontFamilies.sorted())
        fontFamily.isEditable = true
        fontFamily.completes = true
        fontFamily.usesDataSource = false
        fontFamily.delegate = self
        fontFamily.target = self
        fontFamily.action = #selector(fontFamilySelected(_:))
        fontFamily.font = .systemFont(ofSize: 11)
        fontFamily.setAccessibilityLabel("Font family")
        fontFamily.toolTip = "Choose or enter a font family"
        font.addSubview(fontFamily)
        fontSize = NSComboBox(frame: CGRect(x: 160, y: 10, width: 72, height: 25))
        fontSize.addItems(withObjectValues: ["8", "9", "10", "11", "12", "14", "16", "18", "20", "24", "28", "32", "36", "48", "72"])
        fontSize.isEditable = true
        fontSize.delegate = self
        fontSize.target = self
        fontSize.action = #selector(fontSizeSelected(_:))
        fontSize.font = .systemFont(ofSize: 11)
        fontSize.setAccessibilityLabel("Font size in points")
        fontSize.toolTip = "Choose a font size from 1 to 500 points"
        font.addSubview(fontSize)
        let bold = addCompactButton(font, title: "Bold", symbol: "bold", x: 7, y: 42, width: 69, action: #selector(EditorWindowController.boldText(_:)), target: editor, identifier: "fontBold")
        bold.setButtonType(.toggle)
        let italic = addCompactButton(font, title: "Italic", symbol: "italic", x: 80, y: 42, width: 69, action: #selector(EditorWindowController.italicText(_:)), target: editor, identifier: "fontItalic")
        italic.setButtonType(.toggle)
        let underline = addCompactButton(font, title: "Underline", symbol: "underline", x: 153, y: 42, width: 80, action: #selector(EditorWindowController.underlineText(_:)), target: editor, identifier: "fontUnderline")
        underline.setButtonType(.toggle)

        let tools = addGroup("Tools", width: 174, x: &x)
        addToolButton(tools, tool: .pointer, title: "Pointer", symbol: "arrow.up.left", x: 5, y: 10, editor: editor)
        addToolButton(tools, tool: .connector, title: "Connector", symbol: "point.3.connected.trianglepath.dotted", x: 88, y: 10, editor: editor)
        addToolButton(tools, tool: .text, title: "Text", symbol: "textformat", x: 5, y: 43, editor: editor)
        addToolButton(tools, tool: .line, title: "Line", symbol: "line.diagonal", x: 88, y: 43, editor: editor)

        let styles = addGroup("Shape Styles", width: 164, x: &x)
        addColorControl(styles, title: "Fill", identifier: "fillColor", x: 8, well: fillWell, action: #selector(fillChanged(_:)))
        addColorControl(styles, title: "Line", identifier: "lineColor", x: 61, well: lineWell, action: #selector(lineChanged(_:)))
        addColorControl(styles, title: "Text", identifier: "textColor", x: 114, well: textWell, action: #selector(textChanged(_:)))

        let arrange = addGroup("Arrange", width: 268, x: &x)
        let columnX: [CGFloat] = [3, 69, 135, 201]
        addCompactButton(arrange, title: "Left", symbol: "align.horizontal.left", x: columnX[0], y: 9, width: 64, action: #selector(EditorWindowController.alignLeft(_:)), target: editor, identifier: "alignLeft")
        addCompactButton(arrange, title: "Center", symbol: "align.horizontal.center", x: columnX[1], y: 9, width: 64, action: #selector(EditorWindowController.alignCenter(_:)), target: editor, identifier: "alignCenter")
        addCompactButton(arrange, title: "Top", symbol: "align.vertical.top", x: columnX[2], y: 9, width: 64, action: #selector(EditorWindowController.alignTop(_:)), target: editor, identifier: "alignTop")
        addCompactButton(arrange, title: "Spread", symbol: "distribute.horizontal.center", x: columnX[3], y: 9, width: 64, action: #selector(EditorWindowController.distributeHorizontal(_:)), target: editor, identifier: "distributeHorizontal")
        addCompactButton(arrange, title: "Group", symbol: "square.3.layers.3d", x: columnX[0], y: 42, width: 64, action: #selector(EditorWindowController.groupSelection(_:)), target: editor, identifier: "group")
        addCompactButton(arrange, title: "Ungroup", symbol: "square.3.layers.3d.down.right", x: columnX[1], y: 42, width: 64, action: #selector(EditorWindowController.ungroupSelection(_:)), target: editor, identifier: "ungroup")
        addCompactButton(arrange, title: "Front", symbol: "square.3.layers.3d.down.right", x: columnX[2], y: 42, width: 64, action: #selector(EditorWindowController.bringToFront(_:)), target: editor, identifier: "front")
        addCompactButton(arrange, title: "Back", symbol: "square.3.layers.3d", x: columnX[3], y: 42, width: 64, action: #selector(EditorWindowController.sendToBack(_:)), target: editor, identifier: "back")
        return x
    }

    private func addColorControl(_ group: NSView, title: String, identifier: String, x: CGFloat, well: NSColorWell, action: Selector) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 9)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.frame = CGRect(x: x, y: 8, width: 44, height: 14)
        group.addSubview(label)
        well.frame = CGRect(x: x + 8, y: 26, width: 28, height: 26)
        well.color = EditorPalette.accent
        well.target = self
        well.action = action
        well.toolTip = "Set shape \(title.lowercased()) color"
        well.setAccessibilityLabel("\(title) color")
        well.identifier = NSUserInterfaceItemIdentifier(identifier)
        group.addSubview(well)
    }

    private func buildFile(_ editor: EditorWindowController) -> CGFloat {
        var x: CGFloat = 0
        let document = addGroup("Document", width: 236, x: &x)
        addButton(document, title: "New", symbol: "doc.badge.plus", x: 7, y: 10, action: #selector(newDocument(_:)), target: self)
        addButton(document, title: "Open", symbol: "folder", x: 64, y: 10, action: #selector(openDocument(_:)), target: self)
        addButton(document, title: "Save", symbol: "square.and.arrow.down", x: 121, y: 10, action: #selector(saveDocument(_:)), target: self)
        addButton(document, title: "Print", symbol: "printer", x: 178, y: 10, action: #selector(EditorWindowController.printDiagram(_:)), target: editor)
        let export = addGroup("Export", width: 310, x: &x)
        addButton(export, title: "PDF", symbol: "doc.richtext", x: 5, y: 10, width: 54, action: #selector(EditorWindowController.exportPDF(_:)), target: editor)
        addButton(export, title: "All Pages", symbol: "doc.on.doc", x: 65, y: 10, width: 57, action: #selector(EditorWindowController.exportAllPagesPDF(_:)), target: editor)
        addButton(export, title: "PNG", symbol: "photo", x: 128, y: 10, width: 54, action: #selector(EditorWindowController.exportPNG(_:)), target: editor)
        addButton(export, title: "SVG", symbol: "scribble.variable", x: 188, y: 10, width: 54, action: #selector(EditorWindowController.exportSVG(_:)), target: editor)
        addButton(export, title: "VSDX", symbol: "square.and.arrow.up", x: 248, y: 10, width: 54, action: #selector(EditorWindowController.exportVSDX(_:)), target: editor)
        let legacy = addGroup("Legacy", width: 130, x: &x)
        addButton(legacy, title: "VSD", symbol: "archivebox", x: 8, y: 10, width: 52, action: #selector(EditorWindowController.exportVSD(_:)), target: editor)
        addButton(legacy, title: "Template", symbol: "doc.badge.gearshape", x: 66, y: 10, width: 58, action: #selector(EditorWindowController.exportTemplate(_:)), target: editor)
        return x
    }

    private func buildInsert(_ editor: EditorWindowController) -> CGFloat {
        var x: CGFloat = 0
        let shapes = addGroup("Shapes", width: 286, x: &x)
        let kinds: [(String, String, ShapeKind)] = [("Rectangle", "rectangle", .rectangle), ("Ellipse", "circle", .ellipse), ("Decision", "diamond", .diamond), ("Document", "doc", .document)]
        for (index, item) in kinds.enumerated() {
            let button = addButton(shapes, title: item.0, symbol: item.1, x: 5 + CGFloat(index) * 68, y: 10, width: 65, action: #selector(insertShape(_:)), target: self, identifier: "shape_\(index)")
            button.tag = index
        }
        let media = addGroup("Media", width: 130, x: &x)
        addButton(media, title: "Image", symbol: "photo.badge.plus", x: 8, y: 10, action: #selector(EditorWindowController.insertImage(_:)), target: editor)
        addButton(media, title: "Stencil", symbol: "square.grid.3x3", x: 66, y: 10, action: #selector(EditorWindowController.openStencil(_:)), target: editor)
        let pages = addGroup("Pages", width: 194, x: &x)
        addButton(pages, title: "New Page", symbol: "plus.square", x: 5, y: 10, width: 59, action: #selector(EditorWindowController.addPage(_:)), target: editor)
        addButton(pages, title: "Duplicate", symbol: "plus.square.on.square", x: 67, y: 10, width: 59, action: #selector(EditorWindowController.duplicatePage(_:)), target: editor)
        addButton(pages, title: "Background", symbol: "rectangle.on.rectangle", x: 129, y: 10, width: 59, action: #selector(EditorWindowController.addBackgroundPage(_:)), target: editor)
        let text = addGroup("Text", width: 130, x: &x)
        addButton(text, title: "Text Box", symbol: "textformat", x: 8, y: 10, action: #selector(EditorWindowController.textTool(_:)), target: editor)
        addButton(text, title: "Line", symbol: "line.diagonal", x: 66, y: 10, action: #selector(EditorWindowController.lineTool(_:)), target: editor)
        return x
    }

    private func buildDesign(_ editor: EditorWindowController) -> CGFloat {
        var x: CGFloat = 0
        let page = addGroup("Page", width: 258, x: &x)
        addButton(page, title: "Page Setup", symbol: "doc.text.magnifyingglass", x: 7, y: 10, width: 62, action: #selector(EditorWindowController.showPageSetup(_:)), target: editor)
        addButton(page, title: "Add Page", symbol: "plus.square", x: 73, y: 10, width: 62, action: #selector(EditorWindowController.addPage(_:)), target: editor)
        addButton(page, title: "Duplicate", symbol: "plus.square.on.square", x: 139, y: 10, width: 62, action: #selector(EditorWindowController.duplicatePage(_:)), target: editor)
        addButton(page, title: "Delete", symbol: "trash", x: 205, y: 10, width: 48, action: #selector(EditorWindowController.deletePage(_:)), target: editor)
        let background = addGroup("Background", width: 254, x: &x)
        addButton(background, title: "Add Background", symbol: "rectangle.on.rectangle", x: 5, y: 10, width: 75, action: #selector(EditorWindowController.addBackgroundPage(_:)), target: editor)
        addButton(background, title: "Edit Background", symbol: "square.and.pencil", x: 84, y: 10, width: 78, action: #selector(EditorWindowController.editBackgroundPage(_:)), target: editor)
        addButton(background, title: "Match Size", symbol: "arrow.left.and.right", x: 166, y: 10, width: 78, action: #selector(EditorWindowController.matchBackgroundSize(_:)), target: editor)
        let layer = addGroup("Layers", width: 126, x: &x)
        addButton(layer, title: "Layer Properties", symbol: "square.3.layers.3d", x: 8, y: 10, width: 108, action: #selector(EditorWindowController.editLayers(_:)), target: editor)
        return x
    }

    private func buildData(_ editor: EditorWindowController) -> CGFloat {
        var x: CGFloat = 0
        let inspect = addGroup("Shape Data", width: 290, x: &x)
        addButton(inspect, title: "Shape Data", symbol: "list.bullet.rectangle", x: 5, y: 10, width: 66, action: #selector(EditorWindowController.editShapeData(_:)), target: editor, identifier: "shapeData")
        addButton(inspect, title: "ShapeSheet", symbol: "tablecells", x: 74, y: 10, width: 66, action: #selector(EditorWindowController.showShapeSheet(_:)), target: editor, identifier: "shapeSheet")
        addButton(inspect, title: "Geometry", symbol: "point.topleft.down.to.point.bottomright.curvepath", x: 143, y: 10, width: 66, action: #selector(EditorWindowController.editGeometry(_:)), target: editor, identifier: "geometry")
        addButton(inspect, title: "Controls", symbol: "slider.horizontal.3", x: 212, y: 10, width: 70, action: #selector(EditorWindowController.editControls(_:)), target: editor, identifier: "controls")
        let connections = addGroup("Connections", width: 168, x: &x)
        addButton(connections, title: "Connection Points", symbol: "point.3.connected.trianglepath.dotted", x: 5, y: 10, width: 76, action: #selector(EditorWindowController.editConnectionPoints(_:)), target: editor, identifier: "connectionPoints")
        addButton(connections, title: "Control Cells", symbol: "tablecells", x: 85, y: 10, width: 76, action: #selector(EditorWindowController.editControlCells(_:)), target: editor)
        let links = addGroup("Links", width: 126, x: &x)
        addButton(links, title: "Hyperlinks", symbol: "link", x: 7, y: 10, width: 54, action: #selector(EditorWindowController.editHyperlinks(_:)), target: editor, identifier: "hyperlinks")
        addButton(links, title: "Follow", symbol: "arrow.up.right.square", x: 65, y: 10, width: 54, action: #selector(EditorWindowController.followHyperlink(_:)), target: editor, identifier: "followLink")
        let stencil = addGroup("Stencil", width: 132, x: &x)
        addButton(stencil, title: "Export Selection", symbol: "square.and.arrow.up", x: 8, y: 10, width: 114, action: #selector(EditorWindowController.exportSelectionStencil(_:)), target: editor, identifier: "exportStencil")
        return x
    }

    private func buildReview(_ editor: EditorWindowController) -> CGFloat {
        var x: CGFloat = 0
        let find = addGroup("Find", width: 142, x: &x)
        addButton(find, title: "Find Shapes", symbol: "magnifyingglass", x: 8, y: 10, width: 122, action: #selector(EditorWindowController.findShapes(_:)), target: editor)
        let links = addGroup("Links", width: 190, x: &x)
        addButton(links, title: "Edit Hyperlinks", symbol: "link.badge.plus", x: 5, y: 10, width: 86, action: #selector(EditorWindowController.editHyperlinks(_:)), target: editor, identifier: "hyperlinks")
        addButton(links, title: "Follow Link", symbol: "arrow.up.right.square", x: 96, y: 10, width: 86, action: #selector(EditorWindowController.followHyperlink(_:)), target: editor, identifier: "followLink")
        let data = addGroup("Shape Details", width: 225, x: &x)
        addButton(data, title: "Shape Data", symbol: "list.bullet.rectangle", x: 5, y: 10, width: 68, action: #selector(EditorWindowController.editShapeData(_:)), target: editor, identifier: "shapeData")
        addButton(data, title: "ShapeSheet", symbol: "tablecells", x: 78, y: 10, width: 68, action: #selector(EditorWindowController.showShapeSheet(_:)), target: editor, identifier: "shapeSheet")
        addButton(data, title: "Layers", symbol: "square.3.layers.3d", x: 151, y: 10, width: 68, action: #selector(EditorWindowController.editLayers(_:)), target: editor)
        return x
    }

    private func buildView(_ editor: EditorWindowController) -> CGFloat {
        var x: CGFloat = 0
        let zoom = addGroup("Zoom", width: 300, x: &x)
        addButton(zoom, title: "Zoom Out", symbol: "minus.magnifyingglass", x: 5, y: 10, width: 62, action: #selector(EditorWindowController.zoomOut(_:)), target: editor)
        addButton(zoom, title: "Zoom In", symbol: "plus.magnifyingglass", x: 71, y: 10, width: 62, action: #selector(EditorWindowController.zoomIn(_:)), target: editor)
        addButton(zoom, title: "Fit Page", symbol: "arrow.up.left.and.arrow.down.right", x: 137, y: 10, width: 68, action: #selector(EditorWindowController.fitPage(_:)), target: editor)
        addButton(zoom, title: "100%", symbol: "1.magnifyingglass", x: 209, y: 10, width: 62, action: #selector(EditorWindowController.actualSize(_:)), target: editor)
        let display = addGroup("Display", width: 155, x: &x)
        addButton(display, title: "Grid", symbol: "circle.grid.3x3", x: 8, y: 10, width: 60, action: #selector(EditorWindowController.toggleGrid(_:)), target: editor)
        addButton(display, title: "Snap", symbol: "dot.scope", x: 78, y: 10, width: 60, action: #selector(EditorWindowController.toggleSnap(_:)), target: editor)
        let appearance = addGroup("Appearance", width: 220, x: &x)
        appearancePopup = addPopup(appearance, label: "App appearance", titles: ["Dark", "Light", "System"], x: 10, y: 20, width: 190, action: #selector(appearanceChanged(_:)), target: self, identifier: "appearance")
        let current = UserDefaults.standard.string(forKey: "MacVisioAppearance") ?? "dark"
        appearancePopup.selectItem(withTitle: current.capitalized)
        return x
    }

    @objc private func toolPressed(_ sender: NSButton) {
        guard let editor, let tool = CanvasTool(rawValue: sender.tag) else { return }
        editor.setTool(tool)
        refreshSelection()
    }

    @objc private func paste(_ sender: Any?) { editor?.pasteSelection() }
    @objc private func copy(_ sender: Any?) { editor?.copySelection() }
    @objc private func cut(_ sender: Any?) { editor?.copySelection(); editor?.deleteSelection(sender) }

    @objc private func fillChanged(_ sender: NSColorWell) {
        editor?.modifySelection("Shape Fill") { $0.fill = sender.color.hexString }
    }
    @objc private func lineChanged(_ sender: NSColorWell) {
        editor?.modifySelection("Shape Line Color") { $0.stroke = sender.color.hexString }
    }
    @objc private func textChanged(_ sender: NSColorWell) {
        editor?.modifySelection("Text Color") { $0.textColor = sender.color.hexString }
    }

    @objc private func fontFamilySelected(_ sender: NSComboBox) {
        guard !fontFamilyEditing else { return }
        applyFontFamily(sender.stringValue)
    }
    @objc private func fontSizeSelected(_ sender: NSComboBox) {
        guard !fontSizeEditing else { return }
        applyFontSize(sender.stringValue)
    }
    private func applyFontFamily(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        editor?.modifySelection("Font Family") { $0.formatting.fontName = name }
    }
    private func applyFontSize(_ raw: String) {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, (1...500).contains(value) else { return }
        editor?.modifySelection("Font Size") { $0.fontSize = value }
    }
    func controlTextDidBeginEditing(_ obj: Notification) {
        guard let field = obj.object as? NSComboBox else { return }
        if field === fontFamily { fontFamilyEditing = true }
        if field === fontSize { fontSizeEditing = true }
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSComboBox else { return }
        if field === fontFamily { fontFamilyEditing = false; applyFontFamily(field.stringValue) }
        if field === fontSize { fontSizeEditing = false; applyFontSize(field.stringValue) }
    }

    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.title.lowercased(), ["dark", "light", "system"].contains(raw) else { return }
        onAppearanceChanged?(raw)
    }

    @objc private func newDocument(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.newDocument(sender)
    }
    @objc private func openDocument(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.openDocument(sender)
    }
    @objc private func saveDocument(_ sender: Any?) {
        editor?.diagramDocument.save(sender)
    }
    @objc private func insertShape(_ sender: NSButton) {
        let kinds: [ShapeKind] = [.rectangle, .ellipse, .diamond, .document]
        guard kinds.indices.contains(sender.tag) else { return }
        editor?.insertShape(kinds[sender.tag])
    }
}
