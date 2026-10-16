import AppKit
import MacVisioInfrastructure

/// Nonmodal progress keeps other drawings usable. Closing this panel requests
/// cancellation; only the job's completion disposes its controller.
final class LifecycleProgressController: NSWindowController, NSWindowDelegate {
    private let message = NSTextField(labelWithString: "Preparing…")
    private let indicator = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var finished = false
    var onCancel: (() -> Void)?

    init(title: String, detail: String) {
        let panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 380, height: 116),
            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = title
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        message.stringValue = detail
        message.lineBreakMode = .byTruncatingMiddle
        message.frame = CGRect(x: 20, y: 75, width: 340, height: 20)
        indicator.frame = CGRect(x: 20, y: 48, width: 340, height: 16)
        indicator.style = .bar
        indicator.isIndeterminate = true
        cancelButton.frame = CGRect(x: 270, y: 9, width: 90, height: 30)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        panel.contentView?.addSubview(message)
        panel.contentView?.addSubview(indicator)
        panel.contentView?.addSubview(cancelButton)
        panel.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(attachedTo parent: NSWindow? = nil) {
        indicator.startAnimation(nil)
        if let parent, let window { parent.beginSheet(window) } else { showWindow(nil) }
    }

    func update(_ progress: LifecycleJobProgress) {
        guard !finished else { return }
        message.stringValue = progress.stage
        indicator.isIndeterminate = progress.fraction == nil
        if let fraction = progress.fraction {
            indicator.minValue = 0
            indicator.maxValue = 1
            indicator.doubleValue = fraction
        } else {
            indicator.startAnimation(nil)
        }
    }

    func finish() {
        finished = true
        onCancel = nil
        indicator.stopAnimation(nil)
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        close()
    }

    @objc private func cancel(_ sender: Any?) {
        guard !finished else { return }
        cancelButton.isEnabled = false
        message.stringValue = "Cancelling…"
        onCancel?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if finished { return true }
        cancel(nil)
        return false
    }
}
