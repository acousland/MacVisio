// Run with the embedded Sparkle framework; probes the live feed without installing.
import AppKit
import Sparkle

final class Probe:NSObject,SPUUpdaterDelegate {
    func updater(_ updater:SPUUpdater,didFindValidUpdate item:SUAppcastItem) {
        print("Sparkle verified the feed; available build: \(item.versionString)")
        exit(0)
    }
    func updaterDidNotFindUpdate(_ updater:SPUUpdater,error:Error) {
        let error = error as NSError
        guard let latest = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem,
              latest.versionString == updater.hostBundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String else {
            fputs("Unexpected no-update result: \(error)\n",stderr)
            exit(1)
        }
        print("Sparkle verified the live signed feed; current build \(latest.versionString) is up to date.")
        exit(0)
    }
    func updater(_ updater:SPUUpdater,didAbortWithError error:Error) {
        fputs("Sparkle probe failed: \(error)\n",stderr)
        exit(1)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/MacVisio.app"
guard let host = Bundle(path:URL(fileURLWithPath:path).path) else { fatalError("App bundle missing") }
let probe = Probe()
let driver = SPUStandardUserDriver(hostBundle:host,delegate:nil)
let updater = SPUUpdater(hostBundle:host,applicationBundle:host,userDriver:driver,delegate:probe)
do { try updater.start() } catch { fatalError("Updater initialization: \(error)") }
DispatchQueue.main.async { updater.checkForUpdateInformation() }
DispatchQueue.main.asyncAfter(deadline:.now()+45) { fputs("Sparkle probe timed out\n",stderr); exit(1) }
app.run()
