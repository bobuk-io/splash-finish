// Updates through BobukUpdates. A copy that Homebrew manages updates with brew only, from the kit's
// progress window; Sparkle is not created for it at all. Every other release copy updates with
// Sparkle from the public feed (`SUFeedURL` in Info.plist), verified with the EdDSA public key in
// `SUPublicEDKey` and by Apple's code signature checks. Sparkle stays an app dependency: this file
// only adapts it to the kit's `SparkleUpdating`.
import BobukCore
import BobukUI
import BobukUpdates
import Sparkle

@MainActor
private final class SparkleUpdater: SparkleUpdating {
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                          userDriverDelegate: nil)
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var canCheck: Bool { controller.updater.canCheckForUpdates }
    func check() { controller.checkForUpdates(nil) }
}

extension AppUpdateIdentity {
    /// The bundle identifier also names the run folder, `io.bobuk.splash-finish.homebrew-update`,
    /// which the restarted copy of earlier versions reads.
    static let splashFinish = AppUpdateIdentity(
        displayName: "Splash Finish", executableName: "SplashFinish",
        cask: HomebrewCask(name: "splash-finish", appBundleName: "Splash Finish.app"),
        bundleIdentifier: "io.bobuk.splash-finish", keptNotice: "Your inbox and agent integrations are kept.")
}

extension UpdateService {
    /// The one update action of the menu-bar menu.
    static let shared = UpdateService.detect(app: .splashFinish, theme: .splash, makeSparkle: { SparkleUpdater() })
}
