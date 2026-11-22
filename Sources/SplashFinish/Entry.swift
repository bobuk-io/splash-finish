import AppKit
import BobukCore
import BobukUI
import BobukUpdates

@main struct SplashFinishMain {
    @MainActor static func main() {
        // The Homebrew recovery viewer shows only the progress window and never returns.
        HomebrewLaunch.runViewerIfRequested(CommandLine.arguments, app: .splashFinish, theme: .splash)
        let args = Array(CommandLine.arguments.dropFirst())
        // The restart after an update and Finder's -psn_ argument start the app, not the CLI.
        if let first = args.first, !HomebrewLaunch.isUpdateLaunch(args), !AppBundle.isProcessSerialNumber(first) {
            exit(CLI.run(args))
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
