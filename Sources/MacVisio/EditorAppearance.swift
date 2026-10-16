import AppKit

/// Application chrome only: drawing and export colors remain document content.
enum EditorAppearance {
    static let preferenceKey = "MacVisioAppearance"
    static var selection: String { UserDefaults.standard.string(forKey: preferenceKey) ?? "dark" }
    static func apply(_ selection: String? = nil) {
        if let selection, ["dark", "light", "system"].contains(selection) {
            UserDefaults.standard.set(selection, forKey: preferenceKey)
        }
        let appearance: NSAppearance?
        switch self.selection {
        case "light": appearance = NSAppearance(named: .aqua)
        case "system": appearance = nil
        default: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = appearance
        // AppKit can retain closed windows/controllers beyond document close.
        // Their model references are no longer valid; hidden windows inherit
        // NSApp.appearance when shown and need no selection refresh now.
        for window in NSApp.windows where window.isVisible {
            window.appearance = nil
            window.contentView?.needsDisplay = true
            if let editor = window.windowController as? EditorWindowController, editor.lifecycleJobs.isActive
            {
                editor.root?.ribbon.refreshSelection()
            }
        }
    }
}

enum EditorPalette {
    private static func adaptive(_ name: String, light: String, dark: String) -> NSColor {
        NSColor(
            name: NSColor.Name("MacVisio.\(name)"),
            dynamicProvider: { appearance in
                NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            })
    }
    static let ribbon = adaptive("ribbon", light: "#FAFAFA", dark: "#292929")
    static let panel = adaptive("panel", light: "#F5F5F5", dark: "#252526")
    static let workspace = adaptive("workspace", light: "#DADADA", dark: "#171719")
    static let border = adaptive("border", light: "#D0D0D0", dark: "#414144")
    static let hover = adaptive("hover", light: "#E5EAF3", dark: "#3A3D46")
    static let accent = adaptive("accent", light: "#3955A3", dark: "#A7BBFF")
    static let ruler = adaptive("ruler", light: "#777777", dark: "#85858B")
    static let footer = adaptive("footer", light: "#F2F2F2", dark: "#202022")
}

final class PageTabButton: NSButton {
    var isCurrent = false
    override func draw(_ dirtyRect: NSRect) {
        if isCurrent || isHighlighted {
            (isCurrent ? EditorPalette.ribbon : EditorPalette.hover).setFill()
            bounds.fill()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(
            in: bounds.insetBy(dx: 10, dy: 8),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: isCurrent ? .semibold : .regular),
                .foregroundColor: isCurrent ? EditorPalette.accent : NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ])
        if isCurrent {
            EditorPalette.accent.setFill()
            CGRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }
    }
}
