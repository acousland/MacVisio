import MacVisioInfrastructure
import AppKit
import ObjectiveC

/// An owner can accept resource jobs across ordinary document edits, but never
/// after its window closes. Replaceable jobs additionally use a request key.
final class LifecycleJobOwner {
    let id = UUID()
    private(set) var isActive = true
    private var handles: [UUID: LifecycleJobHandle] = [:]
    private var latest: [String: UUID] = [:]
    private var observer: NSObjectProtocol?

    init(window: NSWindow? = nil) {
        if let window {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                self?.close()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        handles.values.forEach { $0.cancel() }
    }

    func track(_ handle: LifecycleJobHandle, replacing key: String? = nil) {
        guard isActive else { handle.cancel(); return }
        if let key {
            if let prior = latest[key] { handles[prior]?.cancel() }
            latest[key] = handle.id
        }
        handles[handle.id] = handle
    }

    func finish(_ id: UUID) {
        handles.removeValue(forKey: id)
        latest = latest.filter { $0.value != id }
    }

    func close() {
        isActive = false
        cancelAll()
    }

    func cancelAll() {
        handles.values.forEach { $0.cancel() }
    }
}

private var editorLifecycleOwnerKey: UInt8 = 0

extension EditorWindowController {
    var lifecycleJobs: LifecycleJobOwner {
        if let owner = objc_getAssociatedObject(self, &editorLifecycleOwnerKey) as? LifecycleJobOwner { return owner }
        let owner = LifecycleJobOwner(window: window)
        objc_setAssociatedObject(self, &editorLifecycleOwnerKey, owner, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return owner
    }
}
