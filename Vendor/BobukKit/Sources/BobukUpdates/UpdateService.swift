// Updates of a bobuk-io app. A copy that Homebrew manages updates with brew only, from a progress
// window; Sparkle is not created for it at all, so it neither checks nor shows its window. Every
// other release copy updates with Sparkle from the public feed (`SUFeedURL`), verified with the
// EdDSA key in `SUPublicEDKey`. Development builds have no updates.
//
// Sparkle is not a dependency of BobukKit (lowkey and HAScS must not resolve it). An app that ships
// Sparkle passes a 10-line `SparkleUpdating` adapter around `SPUStandardUpdaterController`.
import AppKit
import BobukCore
import BobukUI
import Observation

/// The names an update needs: window texts, the cask, the bundle and the run folder.
public struct AppUpdateIdentity: Equatable, Sendable {
    /// "Ting", "Splash Finish".
    public var displayName: String
    /// `Contents/MacOS` executable: "Ting", "SplashFinish".
    public var executableName: String
    public var cask: HomebrewCask
    /// Reverse-DNS prefix of the run folder: "io.bobuk.ting".
    public var bundleIdentifier: String
    /// What an update keeps, shown under the output: "Settings, bindings and micro-apps are kept."
    public var keptNotice: String

    public init(displayName: String, executableName: String, cask: HomebrewCask, bundleIdentifier: String,
                keptNotice: String) {
        self.displayName = displayName
        self.executableName = executableName
        self.cask = cask
        self.bundleIdentifier = bundleIdentifier
        self.keptNotice = keptNotice
    }

    /// Per-user temporary folder of update runs; it survives the restart but holds no configuration.
    public var runBase: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(bundleIdentifier).homebrew-update")
    }
}

/// What the app needs from Sparkle; a protocol so tests can check that Sparkle is never created.
@MainActor
public protocol SparkleUpdating: AnyObject {
    var automaticallyChecks: Bool { get set }
    var canCheck: Bool { get }
    func check()
}

@MainActor
@Observable
public final class UpdateService {
    public let app: AppUpdateIdentity
    public let choice: UpdaterChoice
    @ObservationIgnored private let sparkle: SparkleUpdating?
    @ObservationIgnored public let homebrewWindow: HomebrewUpdateWindowController

    /// - Parameter makeSparkle: called only when Sparkle updates this copy.
    public init(app: AppUpdateIdentity, choice: UpdaterChoice, palette: PickerPalette = .system,
                theme: ThemeStore? = nil, makeSparkle: () -> SparkleUpdating) {
        self.app = app
        self.choice = choice
        homebrewWindow = HomebrewUpdateWindowController.shared(for: app, palette: palette, theme: theme)
        sparkle = choice == .sparkle ? makeSparkle() : nil
        automaticallyChecks = sparkle?.automaticallyChecks ?? false
    }

    /// The service of the running copy: Homebrew, Sparkle or nothing, from the real app bundle
    /// behind the executable and its Info.plist.
    public static func detect(app: AppUpdateIdentity, palette: PickerPalette = .system,
                              theme: ThemeStore? = nil, makeSparkle: () -> SparkleUpdating) -> UpdateService {
        let choice = UpdaterChoice.detect(cask: app.cask, bundle: AppBundle.applicationURL, info: AppBundle.info,
                                          environment: ProcessInfo.processInfo.environment)
        return UpdateService(app: app, choice: choice, palette: palette, theme: theme, makeSparkle: makeSparkle)
    }

    /// True when Sparkle updates this copy; its controls are shown then.
    public var isAvailable: Bool { sparkle != nil }

    /// The Homebrew record when Homebrew manages this copy.
    public var homebrew: HomebrewInstall? {
        if case .homebrew(let install) = choice { return install }
        return nil
    }

    /// The one update action of the app's menu and Settings; nil hides it.
    public var menuTitle: String? {
        switch choice {
        case .homebrew: "Update \(app.displayName) via Homebrew…"
        case .sparkle: "Check for Updates…"
        case .none: nil
        }
    }

    /// Mirrors Sparkle's own preference, which Sparkle stores in the app's user defaults.
    public var automaticallyChecks: Bool {
        didSet {
            guard let sparkle, sparkle.automaticallyChecks != automaticallyChecks else { return }
            sparkle.automaticallyChecks = automaticallyChecks
        }
    }

    public var canCheck: Bool { sparkle?.canCheck ?? false }

    public func checkForUpdates() {
        NSApp.activate()
        if let homebrew {
            homebrewWindow.start(homebrew)
        } else {
            sparkle?.check()
        }
    }
}

/// The launch side of Homebrew updates: the helper restarts the app with one of two arguments.
@MainActor
public enum HomebrewLaunch {
    /// Call first in `main`, before the app's own command-line handling: in the recovery viewer
    /// (`--homebrew-update-viewer <run>`) this shows only the progress window and never returns.
    public static func runViewerIfRequested(_ arguments: [String] = CommandLine.arguments, app: AppUpdateIdentity,
                                            palette: PickerPalette = .system, theme: ThemeStore? = nil) {
        guard let run = HomebrewUpdate.resultDirectory(in: arguments, base: app.runBase,
                                                       argument: HomebrewUpdate.viewerArgument) else { return }
        HomebrewUpdateViewer.run(run, app: app, palette: palette, theme: theme)
    }

    /// Call after launch: an installed copy started with `--homebrew-update-log <run>` shows the result.
    public static func showResultIfRequested(_ arguments: [String] = CommandLine.arguments, app: AppUpdateIdentity,
                                             palette: PickerPalette = .system, theme: ThemeStore? = nil) {
        guard let run = HomebrewUpdate.resultDirectory(in: arguments, base: app.runBase) else { return }
        HomebrewUpdateWindowController.shared(for: app, palette: palette, theme: theme).showRun(run, role: .final)
    }

    /// True when the helper started this process, so its arguments are not a command line.
    public static func isUpdateLaunch(_ arguments: [String] = CommandLine.arguments) -> Bool {
        HomebrewUpdate.isUpdateLaunch(arguments)
    }
}
