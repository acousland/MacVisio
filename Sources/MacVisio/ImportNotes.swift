import AppKit

extension EditorWindowController {
    @objc func showImportNotes(_ sender:Any?) {
        guard let window,window.attachedSheet == nil,!diagramDocument.importWarnings.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Import compatibility notes"
        alert.informativeText = "The drawing opened successfully. Some content may look or behave differently; the details below describe the current import limitations."
        alert.addButton(withTitle:"Close")
        let scroll = NSScrollView(frame:CGRect(x:0,y:0,width:480,height:260))
        scroll.hasVerticalScroller = true;scroll.borderType = .bezelBorder
        let text = NSTextView(frame:CGRect(x:0,y:0,width:460,height:260))
        text.isEditable = false;text.isSelectable = true
        text.font = .systemFont(ofSize:13);text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = CGSize(width:10,height:10)
        text.isVerticallyResizable = true;text.isHorizontallyResizable = false
        text.autoresizingMask = [.width];text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = CGSize(width:460,height:CGFloat.greatestFiniteMagnitude)
        text.string = diagramDocument.importWarnings.joined(separator:"\n\n")
        if let container = text.textContainer,let layout = text.layoutManager {
            layout.ensureLayout(for:container)
            text.setFrameSize(CGSize(width:460,height:max(260,ceil(layout.usedRect(for:container).height)+20)))
        }
        text.setAccessibilityLabel("Import compatibility details")
        scroll.documentView = text;alert.accessoryView = scroll
        alert.beginSheetModal(for:window)
    }
}
