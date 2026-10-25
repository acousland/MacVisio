import AppKit
import UniformTypeIdentifiers

/// One ribbon command, named and placed as Microsoft Visio 2019 names and places it (see
/// Fixtures/Reference/visio-2019-ribbon.json). A command MacVisio does not yet support keeps its place,
/// shown unavailable, so the ribbon reads like Visio's and never pretends to act.
struct RibbonCommand {
    enum Kind { case button, split, menu, check, gallery, fontCombo, sizeCombo, color, tool }
    enum Size { case large, small, icon }
    enum Target { case editor, ribbon }
    var name: String
    var kind: Kind = .button
    var size: Size = .small
    var symbol: String = "square"
    var action: Selector? = nil
    var target: Target = .editor
    var identifier: String? = nil
    /// Dropdown items for menus and split buttons (nil action: unavailable).
    var menu: [(String, Selector?)] = []
    /// Visio's names for the command's primary action when it has one (New Page's Blank Page).
    var aliases: [String] = []
    var tool: CanvasTool? = nil
    var available: Bool { action != nil || tool != nil || [.fontCombo, .sizeCombo, .color].contains(kind) || menu.contains { $0.1 != nil } }
}

/// A ribbon group's columns: a large command, a stack of up to three small commands, or rows of compact
/// controls (Font, Paragraph).
enum RibbonColumn { case large(RibbonCommand), stack([RibbonCommand]), rows([[RibbonCommand]]) }

struct RibbonGroupDefinition {
    var name: String
    var columns: [RibbonColumn]
    /// The dialog launcher in the group's corner; Visio names it after the dialog it opens.
    var launcher: RibbonCommand? = nil
    var commands: [RibbonCommand] {
        columns.flatMap { column -> [RibbonCommand] in
            switch column { case .large(let c): return [c]; case .stack(let cs): return cs; case .rows(let rows): return rows.flatMap { $0 } }
        } + (launcher.map { [$0] } ?? [])
    }
}

struct RibbonTabDefinition { var name: String; var groups: [RibbonGroupDefinition] }

enum RibbonDefinition {
    typealias E = EditorWindowController
    private static func large(_ name: String, _ symbol: String, _ action: Selector? = nil, kind: RibbonCommand.Kind = .button, id: String? = nil, menu: [(String, Selector?)] = [], aliases: [String] = [], target: RibbonCommand.Target = .editor) -> RibbonCommand {
        RibbonCommand(name: name, kind: kind, size: .large, symbol: symbol, action: action, target: target, identifier: id, menu: menu, aliases: aliases)
    }
    private static func small(_ name: String, _ symbol: String, _ action: Selector? = nil, kind: RibbonCommand.Kind = .button, id: String? = nil, menu: [(String, Selector?)] = [], target: RibbonCommand.Target = .editor) -> RibbonCommand {
        RibbonCommand(name: name, kind: kind, size: .small, symbol: symbol, action: action, target: target, identifier: id, menu: menu)
    }
    private static func icon(_ name: String, _ symbol: String, _ action: Selector? = nil, kind: RibbonCommand.Kind = .button, id: String? = nil, menu: [(String, Selector?)] = [], target: RibbonCommand.Target = .editor) -> RibbonCommand {
        RibbonCommand(name: name, kind: kind, size: .icon, symbol: symbol, action: action, target: target, identifier: id, menu: menu)
    }
    private static func check(_ name: String, _ action: Selector? = nil, id: String? = nil) -> RibbonCommand {
        RibbonCommand(name: name, kind: .check, size: .small, action: action, identifier: id)
    }
    private static func gallery(_ name: String) -> RibbonCommand { RibbonCommand(name: name, kind: .gallery, size: .large) }
    private static func tool(_ name: String, _ symbol: String, _ tool: CanvasTool) -> RibbonCommand {
        RibbonCommand(name: name, kind: .tool, size: .small, symbol: symbol, target: .ribbon, identifier: "tool_\(tool.rawValue)", tool: tool)
    }
    private static func launcher(_ name: String, _ action: Selector? = nil) -> RibbonCommand {
        RibbonCommand(name: name, kind: .button, size: .icon, symbol: "arrow.down.right.square", action: action)
    }

    static let tabs: [String] = ["File", "Home", "Insert", "Draw", "Design", "Data", "Process", "Review", "View", "Help"]

    static let ribbon: [RibbonTabDefinition] = [
        RibbonTabDefinition(name: "Home", groups: [
            RibbonGroupDefinition(name: "Clipboard", columns: [
                .large(large("Paste", "doc.on.clipboard", #selector(VisioRibbonView.paste(_:)), kind: .split, id: "paste", menu: [("Paste", #selector(VisioRibbonView.paste(_:))), ("Paste Special…", nil)], target: .ribbon)),
                .stack([small("Cut", "scissors", #selector(VisioRibbonView.cut(_:)), id: "cut", target: .ribbon), small("Copy", "doc.on.doc", #selector(VisioRibbonView.copy(_:)), id: "copy", target: .ribbon),
                        small("Format Painter", "paintbrush")])]),
            RibbonGroupDefinition(name: "Font", columns: [
                .rows([[RibbonCommand(name: "Font", kind: .fontCombo), RibbonCommand(name: "Font Size", kind: .sizeCombo),
                        icon("Increase Font Size", "textformat.size.larger", #selector(VisioRibbonView.increaseFontSize(_:)), id: "fontGrow", target: .ribbon),
                        icon("Decrease Font Size", "textformat.size.smaller", #selector(VisioRibbonView.decreaseFontSize(_:)), id: "fontShrink", target: .ribbon)],
                       [icon("Bold", "bold", #selector(E.boldText(_:)), id: "fontBold"), icon("Italic", "italic", #selector(E.italicText(_:)), id: "fontItalic"),
                        icon("Underline", "underline", #selector(E.underlineText(_:)), id: "fontUnderline"), icon("Strikethrough", "strikethrough"),
                        icon("Change Case...", "textformat", kind: .menu, menu: [("Sentence case.", nil), ("lowercase", nil), ("UPPERCASE", nil)]),
                        RibbonCommand(name: "Font Color", kind: .color, size: .icon, symbol: "character", identifier: "textColor")]])],
                launcher: launcher("Font")),
            RibbonGroupDefinition(name: "Paragraph", columns: [
                .rows([[icon("Align Top", "align.vertical.top", #selector(VisioRibbonView.alignTextTop(_:)), id: "textTop", target: .ribbon),
                        icon("Align Middle", "align.vertical.center", #selector(VisioRibbonView.alignTextMiddle(_:)), id: "textMiddle", target: .ribbon),
                        icon("Align Bottom", "align.vertical.bottom", #selector(VisioRibbonView.alignTextBottom(_:)), id: "textBottom", target: .ribbon),
                        icon("Bullets", "list.bullet"), icon("Rotate Text", "rotate.left")],
                       [icon("Align Left", "text.alignleft", #selector(VisioRibbonView.alignTextLeft(_:)), id: "textLeft", target: .ribbon),
                        icon("Center", "text.aligncenter", #selector(VisioRibbonView.alignTextCenter(_:)), id: "textCenter", target: .ribbon),
                        icon("Align Right", "text.alignright", #selector(VisioRibbonView.alignTextRight(_:)), id: "textRight", target: .ribbon),
                        icon("Justify", "text.justify"), icon("Decrease Indent", "decrease.indent"), icon("Increase Indent", "increase.indent")]])],
                launcher: launcher("Paragraph")),
            RibbonGroupDefinition(name: "Tools", columns: [
                .stack([tool("Pointer Tool", "cursorarrow", .pointer), tool("Connector", "arrow.turn.down.right", .connector), tool("Text", "character.textbox", .text)]),
                .stack([RibbonCommand(name: "Rectangle", kind: .split, size: .icon, symbol: "rectangle", action: #selector(VisioRibbonView.insertRectangle(_:)), target: .ribbon,
                                      menu: [("Rectangle", #selector(VisioRibbonView.insertRectangle(_:))), ("Ellipse", #selector(VisioRibbonView.insertEllipse(_:))),
                                             ("Line", #selector(E.lineTool(_:))), ("Freeform", nil), ("Arc", nil), ("Pencil", nil)]),
                        icon("Connection Point", "smallcircle.filled.circle", #selector(E.editConnectionPoints(_:)), id: "connectionPoints"),
                        icon("Text Block", "character.textbox")])]),
            RibbonGroupDefinition(name: "Shape Styles", columns: [
                .large(large("Quick Styles", "square.on.square", kind: .menu)),
                .stack([RibbonCommand(name: "Fill", kind: .color, size: .small, symbol: "drop", identifier: "fillColor"),
                        RibbonCommand(name: "Line", kind: .color, size: .small, symbol: "pencil.line", identifier: "lineColor"),
                        small("Effects", "sparkles", kind: .menu)])],
                launcher: launcher("Format Object...", #selector(E.showFormatPane(_:)))),
            RibbonGroupDefinition(name: "Arrange", columns: [
                .large(large("Align", "align.horizontal.left", kind: .menu, menu: [("Align Left", #selector(E.alignLeft(_:))), ("Align Center", #selector(E.alignCenter(_:))),
                                                                                 ("Align Top", #selector(E.alignTop(_:)))])),
                .large(large("Position", "rectangle.3.group", kind: .menu, menu: [("Distribute Horizontally", #selector(E.distributeHorizontal(_:))),
                                                                                  ("Distribute Vertically", #selector(E.distributeVertical(_:)))])),
                .stack([small("Bring to Front", "square.2.layers.3d.top.filled", #selector(E.bringToFront(_:)), kind: .split, id: "front",
                              menu: [("Bring to Front", #selector(E.bringToFront(_:))), ("Bring Forward", nil)]),
                        small("Send to Back", "square.2.layers.3d.bottom.filled", #selector(E.sendToBack(_:)), kind: .split, id: "back",
                              menu: [("Send to Back", #selector(E.sendToBack(_:))), ("Send Backward", nil)]),
                        small("Group", "square.on.square.dashed", kind: .menu, id: "group", menu: [("Group", #selector(E.groupSelection(_:))), ("Ungroup", #selector(E.ungroupSelection(_:)))])])]),
            RibbonGroupDefinition(name: "Editing", columns: [
                .large(large("Change Shape", "arrow.triangle.2.circlepath", kind: .menu)),
                .stack([small("Find", "magnifyingglass", kind: .menu, menu: [("Find…", #selector(E.showDocumentFind(_:))), ("Replace…", nil)]),
                        small("Layers", "square.3.layers.3d", kind: .menu, menu: [("Layer Properties…", #selector(E.editLayers(_:)))]),
                        small("Select", "cursorarrow.rays", kind: .menu, menu: [("Select All", #selector(VisioRibbonView.selectAllShapes(_:)))])])]),
        ]),
        RibbonTabDefinition(name: "Insert", groups: [
            RibbonGroupDefinition(name: "Pages", columns: [
                .large(large("New Page", "doc.badge.plus", #selector(E.addPage(_:)), kind: .split,
                             menu: [("Blank Page", #selector(E.addPage(_:))), ("Background Page", #selector(E.addBackgroundPage(_:))), ("Duplicate Page", #selector(E.duplicatePage(_:)))],
                             aliases: ["Blank Page"]))]),
            RibbonGroupDefinition(name: "Illustrations", columns: [
                .large(large("Pictures...", "photo", #selector(E.insertImage(_:)))), .large(large("Online Pictures...", "globe")),
                .large(large("Chart...", "chart.bar")), .large(large("CAD Drawing...", "ruler"))]),
            RibbonGroupDefinition(name: "Diagram Parts", columns: [
                .large(large("Container", "rectangle.dashed", kind: .menu)), .large(large("Callout", "text.bubble", kind: .menu)),
                .large(large("Connector", "arrow.turn.down.right", #selector(E.connectorTool(_:))))]),
            RibbonGroupDefinition(name: "Links", columns: [.large(large("Link", "link", #selector(E.editHyperlinks(_:)), id: "hyperlinks"))]),
            RibbonGroupDefinition(name: "Text", columns: [
                .large(large("Text Box", "character.textbox", #selector(E.textTool(_:)), kind: .split,
                             menu: [("Draw Horizontal Text Box", #selector(E.textTool(_:))), ("Vertical Text Box", nil)], aliases: ["Draw Horizontal Text Box"])),
                .large(large("ScreenTip...", "text.bubble")), .large(large("Object...", "cube")),
                .large(large("Field...", "curlybraces", #selector(E.insertField(_:)), id: "field")), .large(large("Symbol", "omega", kind: .menu))]),
        ]),
        RibbonTabDefinition(name: "Draw", groups: [
            RibbonGroupDefinition(name: "Tools", columns: [
                .large(large("Select", "cursorarrow", #selector(E.pointerTool(_:)))), .large(large("Draw with Touch", "hand.draw")),
                .large(large("Stroke Eraser", "eraser")), .large(large("Lasso Select", "lasso"))]),
            RibbonGroupDefinition(name: "Pens", columns: [.large(gallery("Pens")), .stack([small("Color", "paintpalette", kind: .menu), small("Thickness", "lineweight", kind: .menu)])]),
            RibbonGroupDefinition(name: "Convert", columns: [.large(large("Ink to Text", "pencil.and.scribble"))]),
        ]),
        RibbonTabDefinition(name: "Design", groups: [
            RibbonGroupDefinition(name: "Page Setup", columns: [
                .large(large("Orientation", "rectangle.portrait.rotate", kind: .menu, menu: [("Portrait", #selector(VisioRibbonView.portrait(_:))), ("Landscape", #selector(VisioRibbonView.landscape(_:)))], target: .ribbon)),
                .large(large("Size", "doc", kind: .menu, menu: [("More Page Sizes…", #selector(E.showPageSetup(_:)))])),
                .large(large("Auto Size", "arrow.up.left.and.arrow.down.right"))],
                launcher: launcher("Page Setup...", #selector(E.showPageSetup(_:)))),
            RibbonGroupDefinition(name: "Themes", columns: [.large(gallery("Themes"))]),
            RibbonGroupDefinition(name: "Variants", columns: [.large(gallery("Variants"))]),
            RibbonGroupDefinition(name: "Backgrounds", columns: [
                .large(large("Backgrounds", "rectangle.on.rectangle", kind: .menu,
                             menu: [("Add Background Page", #selector(E.addBackgroundPage(_:))), ("Edit Background Page", #selector(E.editBackgroundPage(_:))), ("Match Background Size", #selector(E.matchBackgroundSize(_:)))])),
                .large(large("Borders & Titles", "rectangle.inset.topleft.filled", kind: .menu))],
                launcher: launcher("Page Setup", #selector(E.showPageSetup(_:)))),
            RibbonGroupDefinition(name: "Layout", columns: [
                .large(large("Re-Layout Page", "rectangle.3.group", kind: .menu)), .large(large("Connectors", "arrow.triangle.branch", kind: .menu))],
                launcher: launcher("Layout & Routing...")),
        ]),
        RibbonTabDefinition(name: "Data", groups: [
            RibbonGroupDefinition(name: "External Data", columns: [
                .large(large("Quick Import", "square.and.arrow.down")), .large(large("Custom Import", "tablecells.badge.ellipsis")),
                .large(large("Refresh All", "arrow.clockwise", kind: .split))]),
            RibbonGroupDefinition(name: "Data Graphics", columns: [.large(gallery("Data Graphics")), .large(large("Position", "rectangle.center.inset.filled", kind: .menu)),
                                                                   .stack([small("Configure", "slider.horizontal.3"), small("Auto Space", "arrow.left.and.right")])]),
            RibbonGroupDefinition(name: "Display Data", columns: [.large(large("Insert Legend", "list.bullet.rectangle", kind: .menu))]),
            RibbonGroupDefinition(name: "Show/Hide", columns: [.stack([check("Shape Data Window", #selector(E.editShapeData(_:)), id: "shapeData"),
                                                                       check("External Data Window"), check("Data Graphic Fields")])]),
            RibbonGroupDefinition(name: "Advanced Data Linking", columns: [.large(large("Link Data", "link.badge.plus")), .large(large("Advanced Data Graphics", "chart.bar.doc.horizontal", kind: .menu))]),
        ]),
        RibbonTabDefinition(name: "Process", groups: [
            RibbonGroupDefinition(name: "Subprocess", columns: [
                .large(large("Create New", "rectangle.split.3x1")), .large(large("Link to Existing", "link", kind: .menu)), .large(large("Create from Selection", "rectangle.dashed.and.paperclip"))]),
            RibbonGroupDefinition(name: "Diagram Validation", columns: [
                .large(large("Check Diagram", "checkmark.seal", #selector(E.checkDrawingContent(_:)), kind: .split, menu: [("Check Diagram", #selector(E.checkDrawingContent(_:)))])),
                .large(large("Ignore This Issue", "eye.slash", kind: .split)),
                .stack([check("Issues Window", #selector(E.showDocumentIssues(_:)), id: "issuesWindow")])]),
            RibbonGroupDefinition(name: "SharePoint Workflow", columns: [
                .large(large("Import", "square.and.arrow.down")), .large(large("Export", "square.and.arrow.up")),
                .large(large("Stage Outline", "list.number")), .large(large("Create Workflow", "flowchart"))]),
        ]),
        RibbonTabDefinition(name: "Review", groups: [
            RibbonGroupDefinition(name: "Proofing", columns: [.large(large("Spelling...", "textformat.abc.dottedunderline")), .stack([small("Research...", "books.vertical"), small("Thesaurus...", "character.book.closed")])]),
            RibbonGroupDefinition(name: "Accessibility", columns: [.large(large("Check Accessibility", "accessibility"))]),
            RibbonGroupDefinition(name: "Language", columns: [.large(large("Translate", "character.bubble")), .large(large("Language", "globe", kind: .menu))]),
            RibbonGroupDefinition(name: "Comments", columns: [.large(large("New Comment", "text.bubble")), .large(large("Comments Pane", "bubble.left.and.bubble.right", kind: .split))]),
            RibbonGroupDefinition(name: "Reports", columns: [.large(large("Shape Reports", "doc.text.below.ecg"))]),
        ]),
        RibbonTabDefinition(name: "View", groups: [
            RibbonGroupDefinition(name: "Views", columns: [.large(large("Presentation Mode", "play.rectangle"))]),
            RibbonGroupDefinition(name: "Show", columns: [
                .stack([check("Ruler", #selector(VisioRibbonView.toggleRulers(_:)), id: "showRuler"), check("Grid", #selector(E.toggleGrid(_:)), id: "showGrid"), check("Page Breaks")]),
                .stack([check("Guides")]),
                .large(large("Task Panes", "sidebar.right", kind: .menu,
                             menu: [("Shapes", #selector(E.toggleShapeLibrary(_:))), ("Format Shape", #selector(E.toggleFormatPane(_:))), ("Shape Data", #selector(E.editShapeData(_:))), ("Issues", #selector(E.showDocumentIssues(_:)))]))],
                launcher: launcher("Ruler & Grid...")),
            RibbonGroupDefinition(name: "Zoom", columns: [
                .large(large("Zoom...", "magnifyingglass", kind: .button, menu: [], target: .editor)),
                .stack([small("Fit to Window", "arrow.up.left.and.arrow.down.right", #selector(E.fitPage(_:))), small("Page Width", "arrow.left.and.right")])]),
            RibbonGroupDefinition(name: "Visual Aids", columns: [.stack([check("Dynamic Grid"), check("AutoConnect"), check("Connection Points")])],
                                  launcher: launcher("Snap & Glue...")),
            RibbonGroupDefinition(name: "Window", columns: [
                .large(large("New Window", "macwindow.badge.plus")), .stack([small("Arrange All", "rectangle.split.2x1"), small("Cascade", "square.stack")]),
                .large(large("Switch Windows", "macwindow.on.rectangle", kind: .menu, id: "switchWindows", target: .ribbon))]),
            RibbonGroupDefinition(name: "Macros", columns: [.large(large("Macros", "list.bullet.rectangle.portrait")), .large(large("Add-Ons", "puzzlepiece.extension", kind: .menu))]),
        ]),
        RibbonTabDefinition(name: "Help", groups: [
            RibbonGroupDefinition(name: "Help", columns: [
                .large(large("Help", "questionmark.circle", #selector(NSApplication.showHelp(_:)))), .large(large("Contact Support...", "person.crop.circle.badge.questionmark")),
                .large(large("Feedback", "face.smiling")), .large(large("Show Training", "graduationcap"))]),
        ]),
    ]
}

private final class RibbonCommandButton: NSButton {
    var size: RibbonCommand.Size = .small
    var dropdown = false
    var unavailable = false

    override var isFlipped: Bool { true }

    /// Greedy word wrapping, as the label is drawn.
    static func lines(_ text: String, font: NSFont, width: CGFloat) -> [String] {
        var lines: [String] = [], current = ""
        for word in text.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if !current.isEmpty, (candidate as NSString).size(withAttributes: [.font: font]).width > width { lines.append(current); current = word } else { current = candidate }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    override func draw(_ dirtyRect: NSRect) {
        if (state == .on || isHighlighted) && isEnabled {
            (state == .on ? EditorPalette.ribbonSelected : EditorPalette.ribbonHover).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).fill()
        }
        let ink = (state == .on ? EditorPalette.accent : NSColor.labelColor).withAlphaComponent(isEnabled && !unavailable ? 1 : 0.38)
        let icon = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [ink])) ?? image
        let font = NSFont.systemFont(ofSize: 11)
        func chevron(at point: CGPoint) {
            let path = NSBezierPath(); path.move(to: point); path.line(to: CGPoint(x: point.x + 3, y: point.y + 3)); path.line(to: CGPoint(x: point.x + 6, y: point.y))
            ink.setStroke(); path.lineWidth = 1; path.stroke()
        }
        switch size {
        case .large:
            let iconSize: CGFloat = 28
            icon?.draw(in: CGRect(x: (bounds.width - iconSize) / 2, y: 4, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
            let text = title as NSString
            text.draw(in: CGRect(x: 1, y: 36, width: bounds.width - 2, height: 30), withAttributes: [.font: font, .foregroundColor: ink, .paragraphStyle: paragraph])
            if dropdown {
                // As in Visio: below a one-line label, or after the last word of a two-line label.
                let lines = Self.lines(title, font: font, width: bounds.width - 2)
                if lines.count < 2 { chevron(at: CGPoint(x: bounds.midX - 3, y: 56)) }
                else {
                    let last = (lines.last! as NSString).size(withAttributes: [.font: font]).width
                    chevron(at: CGPoint(x: min(bounds.width - 7, bounds.midX + last / 2 + 3), y: 56))
                }
            }
        case .small, .icon:
            let iconSize: CGFloat = 16
            icon?.draw(in: CGRect(x: 3, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            if size == .small {
                (title as NSString).draw(at: CGPoint(x: 23, y: (bounds.height - 14) / 2), withAttributes: [.font: font, .foregroundColor: ink])
            }
            if dropdown { chevron(at: CGPoint(x: bounds.width - 9, y: bounds.midY - 1)) }
        }
    }
}

/// The diagram editor's ribbon, laid out like Microsoft Visio 2019's: a tab strip with "Tell me what you want
/// to do", and command groups of large buttons, three-row stacks and formatting rows with dialog launchers.
/// Commands route to the editor's existing actions, so the ribbon and menu bar operate the same features.
final class VisioRibbonView: FlippedView, NSTextFieldDelegate, NSComboBoxDelegate {
    private weak var editor: EditorWindowController?
    private let tabBar = FlippedView()
    private let commandScroll = NSScrollView()
    private let commandContent = FlippedView()
    private let tellMe = NSSearchField()
    private let tabNames = RibbonDefinition.tabs
    private var tabButtons: [String: NSButton] = [:]
    private var selectedTab = "Home"
    private var toolButtons: [CanvasTool: NSButton] = [:]
    private var fontFamily = NSComboBox()
    private var fontSize = NSComboBox()
    private var fillWell = NSColorWell()
    private var lineWell = NSColorWell()
    private var textWell = NSColorWell()
    private var fontFamilyEditing = false
    private var fontSizeEditing = false
    private var builtTab: String?
    private var menusByButton: [ObjectIdentifier: [(String, Selector?, RibbonCommand.Target)]] = [:]

    /// The caller owns appearance persistence and application-wide appearance.
    var onAppearanceChanged: ((String) -> Void)?

    static let tabHeight: CGFloat = 30
    static let commandHeight: CGFloat = 94

    init(editor: EditorWindowController) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 1000, height: Self.tabHeight + Self.commandHeight))
        wantsLayer = true
        tabBar.wantsLayer = true
        commandScroll.drawsBackground = true
        commandScroll.borderType = .noBorder
        commandScroll.hasHorizontalScroller = true
        commandScroll.hasVerticalScroller = false
        commandScroll.autohidesScrollers = true
        commandScroll.horizontalScroller?.controlSize = .mini
        commandScroll.documentView = commandContent
        addSubview(tabBar)
        addSubview(commandScroll)
        buildTabs()
        applyColors()
        selectTab("Home")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        tabBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.tabHeight)
        commandScroll.frame = CGRect(x: 0, y: Self.tabHeight, width: bounds.width, height: max(0, bounds.height - Self.tabHeight))
        layoutTabs()
        buildCommandArea(force: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = EditorPalette.ribbon.cgColor
            self.tabBar.layer?.backgroundColor = EditorPalette.tabStrip.cgColor
            self.commandScroll.backgroundColor = EditorPalette.ribbon
            self.applyTabStyles()
        }
    }

    func selectTab(_ name: String) {
        guard tabNames.contains(name), name != "File" else { return }
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
            let color: NSColor = selected ? EditorPalette.accent : EditorPalette.tabText
            button.attributedTitle = NSAttributedString(string: tab, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: color])
            button.wantsLayer = true
            button.layer?.backgroundColor = selected ? EditorPalette.ribbon.cgColor : NSColor.clear.cgColor
        }
    }

    func detachEditor() {
        editor = nil
        onAppearanceChanged = nil
        fontFamily.delegate = nil; fontSize.delegate = nil; tellMe.delegate = nil
    }

    /// Refreshes selection-sensitive controls without replacing the ribbon or stealing focus from a font
    /// field the user is currently editing.
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
            case "fontBold", "fontItalic", "fontUnderline", "fontGrow", "fontShrink", "textLeft", "textCenter", "textRight", "textTop", "textMiddle", "textBottom":
                button.isEnabled = canFormatText
            case "group": button.isEnabled = !selection.isEmpty
            case "front", "back": button.isEnabled = !selection.isEmpty
            case "connectionPoints", "hyperlinks", "field": button.isEnabled = selection.count == 1
            case "showGrid": button.state = editor.canvas.showsGrid ? .on : .off
            case "showRuler": button.state = editor.showsRulers ? .on : .off
            default: break
            }
        }
        for well in [fillWell, lineWell] { well.isEnabled = editable }
        textWell.isEnabled = canFormatText
        fontFamily.isEnabled = canFormatText; fontSize.isEnabled = canFormatText
        if !fontFamilyEditing { fontFamily.stringValue = selection.first.map { $0.formatting.fontName == "System" ? "System" : $0.formatting.fontName } ?? "System" }
        if !fontSizeEditing { fontSize.stringValue = selection.first.map { "\(Int($0.fontSize.rounded()))pt" } ?? "12pt" }
        if let node = selection.first {
            fillWell.color = NSColor(hex: node.fill); lineWell.color = NSColor(hex: node.stroke); textWell.color = NSColor(hex: node.textColor)
            button(identifier: "fontBold")?.state = node.bold ? .on : .off
            button(identifier: "fontItalic")?.state = node.formatting.italic ? .on : .off
            button(identifier: "fontUnderline")?.state = node.formatting.underline ? .on : .off
        }
        needsDisplay = true
    }

    private func button(identifier: String) -> NSButton? {
        descendants(of: commandContent).compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == identifier }
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants(of: $0) } }

    private func buildTabs() {
        for tab in tabNames {
            let button = NSButton(title: tab, target: self, action: #selector(tabPressed(_:)))
            button.identifier = NSUserInterfaceItemIdentifier("tab_" + tab)
            button.setButtonType(.toggle)
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.alignment = .center
            button.setAccessibilityLabel(tab == "File" ? "File" : "\(tab) ribbon tab")
            button.toolTip = tab == "File" ? "Open the File view" : "Show \(tab) commands"
            tabBar.addSubview(button)
            tabButtons[tab] = button
        }
        tellMe.placeholderString = "Tell me what you want to do"
        tellMe.identifier = NSUserInterfaceItemIdentifier("tellMe")
        tellMe.font = .systemFont(ofSize: 12)
        tellMe.sendsWholeSearchString = true
        tellMe.target = self
        tellMe.action = #selector(tellMeSearched(_:))
        tellMe.setAccessibilityLabel("Tell me what you want to do")
        tabBar.addSubview(tellMe)
    }

    private func layoutTabs() {
        var x: CGFloat = 4
        for tab in tabNames {
            let width = (tab as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width + 26
            tabButtons[tab]?.frame = CGRect(x: x, y: 3, width: width, height: Self.tabHeight - 3)
            x += width
        }
        tellMe.frame = CGRect(x: x + 10, y: 4, width: 240, height: 22)
    }

    @objc private func tabPressed(_ sender: NSButton) {
        guard let tab = sender.identifier?.rawValue.replacingOccurrences(of: "tab_", with: "") else { return }
        if tab == "File" { sender.state = .off; editor?.showBackstage(nil); return }
        selectTab(tab)
    }

    @objc private func tellMeSearched(_ sender: NSSearchField) {
        guard !sender.stringValue.isEmpty else { return }
        editor?.showCommandSearch(query: sender.stringValue)
        sender.stringValue = ""
    }

    // MARK: Building

    private func buildCommandArea(force: Bool) {
        guard let editor, force || builtTab != selectedTab else { return }
        builtTab = selectedTab
        commandContent.subviews.forEach { $0.removeFromSuperview() }
        toolButtons.removeAll(); menusByButton.removeAll()
        var x: CGFloat = 4
        for group in RibbonDefinition.ribbon.first(where: { $0.name == selectedTab })?.groups ?? [] {
            x += build(group, at: x, editor: editor)
        }
        commandContent.frame = CGRect(x: 0, y: 0, width: x + 4, height: Self.commandHeight)
        commandScroll.contentView.scroll(to: .zero)
        commandScroll.reflectScrolledClipView(commandScroll.contentView)
        refreshSelection()
    }

    private static let rowHeight: CGFloat = 22
    private static let top: CGFloat = 4

    private func build(_ group: RibbonGroupDefinition, at originX: CGFloat, editor: EditorWindowController) -> CGFloat {
        let view = FlippedView(frame: CGRect(x: originX, y: 0, width: 10, height: Self.commandHeight))
        view.identifier = NSUserInterfaceItemIdentifier("group_" + group.name)
        commandContent.addSubview(view)
        var x: CGFloat = 4
        for column in group.columns {
            switch column {
            case .large(let command):
                x += place(command, in: view, x: x, y: Self.top, editor: editor) + 2
            case .stack(let commands):
                var width: CGFloat = 0
                for (row, command) in commands.enumerated() {
                    width = max(width, place(command, in: view, x: x, y: Self.top + CGFloat(row) * (Self.rowHeight + 1), editor: editor))
                }
                x += width + 4
            case .rows(let rows):
                var width: CGFloat = 0
                for (row, commands) in rows.enumerated() {
                    var rowX = x
                    for command in commands { rowX += place(command, in: view, x: rowX, y: Self.top + 2 + CGFloat(row) * (Self.rowHeight + 10), editor: editor) + 2 }
                    width = max(width, rowX - x)
                }
                x += width + 2
            }
        }
        let caption = NSTextField(labelWithString: group.name)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        let captionWidth = (group.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 30
        let width = max(x + 2, captionWidth)
        caption.frame = CGRect(x: 0, y: Self.commandHeight - 20, width: width - (group.launcher == nil ? 0 : 16), height: 15)
        view.addSubview(caption)
        if let launcher = group.launcher {
            let button = makeButton(launcher, editor: editor)
            button.frame = CGRect(x: width - 17, y: Self.commandHeight - 20, width: 14, height: 14)
            button.size = .icon
            button.image = NSImage(systemSymbolName: "arrow.down.right.square", accessibilityDescription: launcher.name)
            button.imageScaling = .scaleProportionallyDown
            view.addSubview(button)
        }
        let separator = NSBox(frame: CGRect(x: width, y: 6, width: 1, height: Self.commandHeight - 12))
        separator.boxType = .separator
        view.addSubview(separator)
        view.frame.size.width = width + 1
        return width + 1
    }

    private func makeButton(_ command: RibbonCommand, editor: EditorWindowController) -> RibbonCommandButton {
        let button = RibbonCommandButton(title: command.name, target: nil, action: nil)
        button.size = command.size
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.setButtonType(command.kind == .tool ? .toggle : .momentaryPushIn)
        button.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.name)
            ?? NSImage(systemSymbolName: "square", accessibilityDescription: command.name)
        button.unavailable = !command.available
        button.dropdown = command.kind == .menu || command.kind == .split
        button.toolTip = command.available ? command.name : "\(command.name) — not yet available in MacVisio"
        button.setAccessibilityLabel(command.name)
        if let identifier = command.identifier { button.identifier = NSUserInterfaceItemIdentifier(identifier) }
        if let tool = command.tool {
            button.target = self; button.action = #selector(toolPressed(_:)); button.tag = tool.rawValue; toolButtons[tool] = button
        } else if command.kind == .menu || (command.kind == .split && !command.menu.isEmpty && command.action == nil) {
            button.target = self; button.action = #selector(showCommandMenu(_:))
            menusByButton[ObjectIdentifier(button)] = command.menu.map { ($0.0, $0.1, command.target) }
            button.isEnabled = command.available
        } else if let action = command.action {
            button.target = command.target == .ribbon ? self : editor
            button.action = action
            if command.kind == .split, !command.menu.isEmpty { menusByButton[ObjectIdentifier(button)] = command.menu.map { ($0.0, $0.1, command.target) } }
        } else {
            button.isEnabled = false
        }
        return button
    }

    /// Places a command and returns the width it takes.
    private func place(_ command: RibbonCommand, in group: NSView, x: CGFloat, y: CGFloat, editor: EditorWindowController) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11)
        switch command.kind {
        case .fontCombo, .sizeCombo:
            let combo = command.kind == .fontCombo ? fontFamily : fontSize
            let width: CGFloat = command.kind == .fontCombo ? 120 : 58
            configure(combo, fontList: command.kind == .fontCombo)
            combo.frame = CGRect(x: x, y: y, width: width, height: Self.rowHeight + 2)
            group.addSubview(combo)
            return width
        case .color:
            let well = command.identifier == "fillColor" ? fillWell : command.identifier == "lineColor" ? lineWell : textWell
            well.colorWellStyle = .minimal
            well.target = self
            well.action = command.identifier == "fillColor" ? #selector(fillChanged(_:)) : command.identifier == "lineColor" ? #selector(lineChanged(_:)) : #selector(textChanged(_:))
            well.identifier = NSUserInterfaceItemIdentifier(command.identifier ?? command.name)
            well.toolTip = command.name
            well.setAccessibilityLabel(command.name)
            if command.size == .small {
                let label = NSTextField(labelWithString: command.name)
                label.font = font
                let icon = NSImageView(image: NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) ?? NSImage())
                icon.frame = CGRect(x: x + 3, y: y + 3, width: 16, height: 16)
                label.frame = CGRect(x: x + 23, y: y + 3, width: 34, height: 16)
                well.frame = CGRect(x: x + 56, y: y + 1, width: 30, height: 20)
                group.addSubview(icon); group.addSubview(label); group.addSubview(well)
                return 88
            }
            well.frame = CGRect(x: x, y: y, width: 34, height: Self.rowHeight)
            group.addSubview(well)
            return 34
        case .check:
            let box = NSButton(checkboxWithTitle: command.name, target: nil, action: nil)
            box.font = font
            box.identifier = command.identifier.map { NSUserInterfaceItemIdentifier($0) }
            if let action = command.action { box.target = editor; box.action = action } else { box.isEnabled = false; box.toolTip = "\(command.name) — not yet available in MacVisio" }
            if command.identifier == "showRuler" { box.target = self }
            box.sizeToFit()
            box.frame = CGRect(x: x, y: y + 2, width: box.frame.width, height: 18)
            group.addSubview(box)
            return box.frame.width
        case .gallery:
            let gallery = NSBox(frame: CGRect(x: x, y: y, width: 150, height: 66))
            gallery.boxType = .custom; gallery.borderWidth = 1; gallery.cornerRadius = 2
            gallery.borderColor = EditorPalette.border; gallery.fillColor = .clear
            gallery.toolTip = "\(command.name) — not yet available in MacVisio"
            gallery.setAccessibilityLabel(command.name)
            let label = NSTextField(labelWithString: command.name)
            label.font = font; label.textColor = .tertiaryLabelColor; label.alignment = .center
            label.frame = CGRect(x: 0, y: 24, width: 150, height: 16)
            gallery.contentView?.addSubview(label)
            group.addSubview(gallery)
            return 150
        default:
            let button = makeButton(command, editor: editor)
            let textWidth = (command.name as NSString).size(withAttributes: [.font: font]).width
            let width: CGFloat
            switch command.size {
            case .large:
                let words = command.name.split(separator: " ")
                let longest = words.map { (String($0) as NSString).size(withAttributes: [.font: font]).width }.max() ?? textWidth
                width = max(42, min(textWidth, max(longest, textWidth / 2 + 8)) + 10)
                button.frame = CGRect(x: x, y: y, width: width, height: 68)
            case .small:
                width = textWidth + 28 + (button.dropdown ? 10 : 0)
                button.frame = CGRect(x: x, y: y, width: width, height: Self.rowHeight)
            case .icon:
                width = button.dropdown ? 32 : 24
                button.frame = CGRect(x: x, y: y, width: width, height: Self.rowHeight)
            }
            group.addSubview(button)
            return width
        }
    }

    private func configure(_ combo: NSComboBox, fontList: Bool) {
        guard combo.numberOfItems == 0 else { return }
        if fontList { combo.addItems(withObjectValues: ["System"] + NSFontManager.shared.availableFontFamilies.sorted()) }
        else { combo.addItems(withObjectValues: ["6pt", "8pt", "9pt", "10pt", "11pt", "12pt", "14pt", "16pt", "18pt", "24pt", "30pt", "36pt", "48pt", "60pt", "72pt", "96pt"]) }
        combo.isEditable = true
        combo.completes = fontList
        combo.usesDataSource = false
        combo.delegate = self
        combo.target = self
        combo.action = fontList ? #selector(fontFamilySelected(_:)) : #selector(fontSizeSelected(_:))
        combo.font = .systemFont(ofSize: 11)
        combo.setAccessibilityLabel(fontList ? "Font" : "Font Size")
        combo.toolTip = fontList ? "Font" : "Font Size"
    }

    @objc private func showCommandMenu(_ sender: NSButton) {
        guard let items = menusByButton[ObjectIdentifier(sender)] else { return }
        if sender.identifier?.rawValue == "switchWindows" { switchDrawing(sender); return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, action, target) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target == .ribbon ? self : editor
            item.isEnabled = action != nil
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func switchDrawing(_ sender: NSButton) {
        guard let workflow = editor?.diagramDocument.documentWorkflow ?? (NSApp.delegate as? AppDelegate)?.workflow else { return }
        workflow.makeSwitchMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    // MARK: Commands

    @objc private func toolPressed(_ sender: NSButton) {
        guard let editor, let tool = CanvasTool(rawValue: sender.tag) else { return }
        editor.setTool(tool)
        refreshSelection()
    }

    @objc func paste(_ sender: Any?) { editor?.pasteSelection() }
    @objc func copy(_ sender: Any?) { editor?.copySelection() }
    @objc func cut(_ sender: Any?) { editor?.cutSelection(sender) }
    @objc func insertRectangle(_ sender: Any?) { editor?.insertShape(.rectangle) }
    @objc func insertEllipse(_ sender: Any?) { editor?.insertShape(.ellipse) }
    @objc func selectAllShapes(_ sender: Any?) { editor?.canvas.selectAll(sender) }
    @objc func increaseFontSize(_ sender: Any?) { editor?.modifySelection("Increase Font Size") { $0.fontSize = Self.fontStep($0.fontSize, up: true) } }
    @objc func decreaseFontSize(_ sender: Any?) { editor?.modifySelection("Decrease Font Size") { $0.fontSize = Self.fontStep($0.fontSize, up: false) } }
    @objc func alignTextLeft(_ sender: Any?) { editor?.modifySelection("Align Left") { $0.formatting.alignment = .left } }
    @objc func alignTextCenter(_ sender: Any?) { editor?.modifySelection("Center") { $0.formatting.alignment = .center } }
    @objc func alignTextRight(_ sender: Any?) { editor?.modifySelection("Align Right") { $0.formatting.alignment = .right } }
    @objc func alignTextTop(_ sender: Any?) { setVerticalAlignment(0, "Align Top") }
    @objc func alignTextMiddle(_ sender: Any?) { setVerticalAlignment(1, "Align Middle") }
    @objc func alignTextBottom(_ sender: Any?) { setVerticalAlignment(2, "Align Bottom") }
    @objc func portrait(_ sender: Any?) { editor?.setPageOrientation(landscape: false) }
    @objc func landscape(_ sender: Any?) { editor?.setPageOrientation(landscape: true) }
    @objc func toggleRulers(_ sender: Any?) { editor?.toggleRulers(sender) }

    private func setVerticalAlignment(_ value: Int, _ action: String) {
        editor?.modifySelection(action) { node in
            var box = node.formatting.textBox ?? ShapeTextBox(); box.verticalAlignment = value; node.formatting.textBox = box
        }
    }

    /// Visio's Increase/Decrease Font Size steps through its font-size list.
    static let fontSizes: [Double] = [6, 8, 9, 10, 11, 12, 14, 16, 18, 24, 30, 36, 48, 60, 72, 96]
    static func fontStep(_ size: Double, up: Bool) -> Double {
        up ? (fontSizes.first { $0 > size + 0.01 } ?? min(500, size + 12)) : (fontSizes.last { $0 < size - 0.01 } ?? max(1, size - 1))
    }

    @objc private func fillChanged(_ sender: NSColorWell) { editor?.modifySelection("Shape Fill") { $0.fill = sender.color.hexString } }
    @objc private func lineChanged(_ sender: NSColorWell) { editor?.modifySelection("Shape Line Color") { $0.stroke = sender.color.hexString } }
    @objc private func textChanged(_ sender: NSColorWell) { editor?.modifySelection("Text Color") { $0.textColor = sender.color.hexString } }

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
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "pt", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(text), value.isFinite, (1...500).contains(value) else { return }
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
}
