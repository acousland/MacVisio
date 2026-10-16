import AppKit
import Sparkle

/// Bundle configuration sets defaults; this policy also applies when Sparkle
/// has a persisted preference from another build with the same bundle ID.
struct AppUpdatePolicy {
    enum Channel: String { case stable, development }
    let channel: Channel?
    init(info: [String: Any]) {
        channel = (info["MacVisioReleaseChannel"] as? String).flatMap(Channel.init(rawValue:))
    }
    var permitsAutomaticChecks: Bool { channel == .stable }
    func permits(_ check: SPUUpdateCheck) -> Bool {
        guard channel != nil else { return false }
        switch check {
        case .updates: return true
        case .updatesInBackground, .updateInformation: return permitsAutomaticChecks
        @unknown default: return false
        }
    }
}

final class AppUpdates: NSObject, NSMenuItemValidation, SPUUpdaterDelegate {
    let policy: AppUpdatePolicy
    lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)

    init(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        policy = AppUpdatePolicy(info: info)
        super.init()
    }
    func start() { controller.startUpdater() }
    @objc func toggleAutomaticChecks(_ sender: Any?) {
        guard policy.permitsAutomaticChecks else { return }
        controller.updater.automaticallyChecksForUpdates.toggle()
    }
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard policy.permits(updateCheck) else {
            throw NSError(domain: "com.macvisio.update-policy", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "This build permits manual update checks only when its release channel is configured."])
        }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticChecks(_:)) {
            guard policy.permitsAutomaticChecks else {
                menuItem.state = .off
                menuItem.toolTip = "Scheduled checks are disabled for development and unconfigured builds."
                return false
            }
            menuItem.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
            menuItem.toolTip = nil
        }
        return true
    }
}
