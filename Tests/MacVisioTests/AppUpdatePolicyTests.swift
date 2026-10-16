import AppKit
import Sparkle
import XCTest
@testable import MacVisio

final class AppUpdatePolicyTests: XCTestCase {
    func testDevelopmentAllowsManualOnlyAndUnconfiguredBuildsFailClosed() {
        let development = AppUpdatePolicy(info: ["MacVisioReleaseChannel": "development", "SUEnableAutomaticChecks": true])
        XCTAssertTrue(development.permits(.updates))
        XCTAssertFalse(development.permits(.updatesInBackground))
        XCTAssertFalse(development.permits(.updateInformation))
        XCTAssertFalse(development.permitsAutomaticChecks)
        for info: [String: Any] in [[:], ["MacVisioReleaseChannel": "STABLE"], ["MacVisioReleaseChannel": "unexpected"]] {
            let unconfigured = AppUpdatePolicy(info: info)
            XCTAssertFalse(unconfigured.permits(.updates))
            XCTAssertFalse(unconfigured.permits(.updatesInBackground))
        }
    }

    func testStablePermitsKnownChecksAndKeepsUserPreferenceOwnership() {
        let stable = AppUpdatePolicy(info: ["MacVisioReleaseChannel": "stable", "SUEnableAutomaticChecks": false])
        XCTAssertTrue(stable.permitsAutomaticChecks)
        XCTAssertTrue(stable.permits(.updates))
        XCTAssertTrue(stable.permits(.updatesInBackground))
        XCTAssertTrue(stable.permits(.updateInformation))
    }

    func testDevelopmentAutomaticMenuCannotOverrideChannelPolicyOrChangeStoredPreference() {
        let previousPreference = UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool
        let updates = AppUpdates(info: ["MacVisioReleaseChannel": "development"])
        let item = NSMenuItem(title: "Automatic checks", action: #selector(AppUpdates.toggleAutomaticChecks(_:)), keyEquivalent: "")
        item.state = .on
        XCTAssertFalse(updates.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
        XCTAssertNotNil(item.toolTip)
        updates.toggleAutomaticChecks(nil)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "SUEnableAutomaticChecks") as? Bool, previousPreference)
        let updater = updates.controller.updater
        XCTAssertThrowsError(try updates.updater(updater, mayPerform: .updatesInBackground))
        XCTAssertThrowsError(try updates.updater(updater, mayPerform: .updateInformation))
        XCTAssertNoThrow(try updates.updater(updater, mayPerform: .updates))
        // Verify the imported Sparkle delegate selector, rather than a similarly
        // named Swift helper that Sparkle would never invoke.
        XCTAssertTrue(updates.responds(to: #selector(SPUUpdaterDelegate.updater(_:mayPerform:))))
    }
}
