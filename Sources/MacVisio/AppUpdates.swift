import AppKit
import Sparkle

final class AppUpdates:NSObject,NSMenuItemValidation {
    let controller = SPUStandardUpdaterController(startingUpdater:false,updaterDelegate:nil,userDriverDelegate:nil)
    func start() { controller.startUpdater() }
    @objc func toggleAutomaticChecks(_ sender:Any?) { controller.updater.automaticallyChecksForUpdates.toggle() }
    func validateMenuItem(_ menuItem:NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticChecks(_:)) { menuItem.state = controller.updater.automaticallyChecksForUpdates ? .on : .off }
        return true
    }
}
