// The progress window of a Homebrew update: the command, the live output of brew and the result.
// A `ChromeWindow` in the app's palette, from Ting and Splash Finish.
import AppKit
import BobukCore
import BobukUI
import Observation
import SwiftUI

@MainActor
@Observable
public final class HomebrewUpdateModel {
    public enum Phase: Equatable {
        case running
        case finished(HomebrewUpdateOutcome)
    }

    /// Homebrew refused the cask because it is not trusted yet: the window asks the person.
    public enum Trust: Equatable {
        case none
        /// The update failed for this reason; the window offers to trust `cask` and update.
        case needed(cask: String)
        /// `brew trust` runs.
        case running(cask: String)
        /// `brew trust` failed; the output says why.
        case failed(cask: String, exitCode: Int32)
    }

    public let appName: String
    public var command = ""
    public var output = ""
    public var phase: Phase = .running
    /// True after a success, while the app quits so that the helper starts the new copy.
    public var restarting = false
    public var trust: Trust = .none

    public init(appName: String) { self.appName = appName }

    public var title: String {
        switch trust {
        case .needed(let cask): return "Homebrew does not trust \(cask) yet."
        case .running(let cask): return "Trusting \(cask)…"
        case .failed(let cask, let code): return "Homebrew could not trust \(cask) (brew exit code \(code))."
        case .none: break
        }
        return switch phase {
        case .running: "Updating \(appName) via Homebrew…"
        case .finished(.upgraded): restarting ? "\(appName) was updated. Restarting…" : "\(appName) was updated."
        case .finished(.upToDate): "\(appName) is already up to date."
        case .finished(.failed(let code, _)): "The update failed (brew exit code \(code))."
        case .finished(.cancelled): "The update was cancelled."
        }
    }

    public var succeeded: Bool { phase == .finished(.upgraded) || phase == .finished(.upToDate) }

    /// True while something runs: brew's update or `brew trust`.
    public var isBusy: Bool {
        if case .running = trust { return true }
        return phase == .running
    }

    /// Shows the result. A failure or cancel shows the text it carries: the whole brew output, or
    /// the reason why the run could not start when there is no log at all. With `cask`, a refusal
    /// of that cask as untrusted asks to trust it (`trust` becomes `.needed`).
    public func finish(_ outcome: HomebrewUpdateOutcome, log: String?, cask: HomebrewCask? = nil) {
        switch outcome {
        case .failed(_, let text), .cancelled(let text):
            output = text.isEmpty ? (log ?? output) : text
        case .upgraded, .upToDate:
            output = log ?? output
        }
        phase = .finished(outcome)
        if case .failed = outcome, let cask, HomebrewUpdate.refusesUntrusted(output, cask: cask) {
            trust = .needed(cask: cask.tap)
        } else {
            trust = .none
        }
    }
}

@MainActor
public final class HomebrewUpdateWindowController: NSObject, NSWindowDelegate {
    private static var controllers: [String: HomebrewUpdateWindowController] = [:]

    /// One controller per app in a process.
    public static func shared(for app: AppUpdateIdentity, palette: PickerPalette = .system,
                              theme: ThemeStore? = nil) -> HomebrewUpdateWindowController {
        if let existing = controllers[app.bundleIdentifier] { return existing }
        let controller = HomebrewUpdateWindowController(app: app, palette: palette, theme: theme)
        controllers[app.bundleIdentifier] = controller
        return controller
    }

    public let app: AppUpdateIdentity
    public let model: HomebrewUpdateModel
    private let palette: PickerPalette
    private let theme: ThemeStore?
    private var window: ChromeWindow?
    private var runner: HomebrewUpdateRunner?
    private var role: HomebrewUpdateRole = .owner
    /// Replaced by tests; quits the app so the helper can start the installed copy.
    public var terminate: @MainActor () -> Void = { NSApp.terminate(nil) }
    /// Runs `brew trust` after the person asked for it. Replaced by tests.
    public var runTrust: @MainActor (HomebrewInstall) async -> HomebrewTrust.Result = { await HomebrewTrust.run($0) }
    /// Starts the update again once the cask is trusted. Replaced by tests.
    public var restart: (@MainActor (HomebrewInstall) -> Void)?
    /// The install of the update this process started: the one to trust. Internal for tests.
    var install: HomebrewInstall?

    public init(app: AppUpdateIdentity, palette: PickerPalette = .system, theme: ThemeStore? = nil) {
        self.app = app
        self.palette = palette
        self.theme = theme
        model = HomebrewUpdateModel(appName: app.displayName)
    }

    public var isRunning: Bool { runner?.isRunning == true }

    /// Starts the update, or brings the running one to the front: a second start is refused.
    public func start(_ install: HomebrewInstall) {
        // A run in progress, or a success while the app quits to restart: show it, start nothing.
        if model.restarting || runner?.isRunning == true { show(); return }
        let runner = HomebrewUpdateRunner(app: app, install: install)
        self.runner = runner
        self.install = install
        role = .owner
        model.command = HomebrewUpdate.commandLine(for: install)
        model.output = ""
        model.phase = .running
        model.restarting = false
        model.trust = .none
        show()
        runner.start(onOutput: { [weak self] in self?.model.output = $0 },
                     onFinish: { [weak self] in self?.finish($0) })
    }

    /// Shows a run that the helper started this process for. The role comes from the argument the
    /// helper used, never from the timing of the status file: `.viewer` is the recovery window
    /// (a copy of the app in the run folder) while the installed app is gone, `.final` the
    /// installed app started after brew.
    public func showRun(_ directory: URL, role: HomebrewUpdateRole) {
        if runner?.isRunning == true { show(); return }
        self.role = role
        model.command = (try? String(contentsOf: directory.appendingPathComponent("command"), encoding: .utf8))
            ?? HomebrewUpdate.arguments(for: app.cask).joined(separator: " ")
        model.output = HomebrewUpdateRunner.output(in: directory)
        model.phase = .running
        model.restarting = false
        model.trust = .none
        install = nil
        let runner = HomebrewUpdateRunner(app: app, install: nil)
        self.runner = runner
        show()
        runner.watch(directory, onOutput: { [weak self] in self?.model.output = $0 },
                     onFinish: { [weak self] in self?.finish($0) })
    }

    /// Internal for tests.
    func finish(_ outcome: HomebrewUpdateOutcome) {
        // Only the copy that started brew knows its install, so only it can offer to trust the cask.
        model.finish(outcome, log: (runner?.directory).map(HomebrewUpdateRunner.output(in:)),
                     cask: role == .owner ? install?.cask : nil)
        // The viewer exists only to show this result: bring its window back if it was closed.
        if role == .viewer { show() }
        guard runner?.conclude(outcome, role: role) == true else { return }
        // Quit so that the helper starts the installed app, which shows this result again.
        model.restarting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.terminate() }
    }

    private func cancel() { runner?.cancel() }

    /// The person chose to trust the cask: `brew trust --cask <tap>`, then the same update again.
    /// A failure stays in the window with brew's output.
    public func trustAndUpdate() {
        guard case .needed(let cask) = model.trust, let install else { return }
        model.trust = .running(cask: cask)
        model.command = HomebrewUpdate.trustCommandLine(for: install)
        model.output = ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.runTrust(install)
            guard case .running = self.model.trust else { return }
            if result.succeeded {
                self.model.trust = .none
                if let restart = self.restart { restart(install) } else { self.start(install) }
            } else {
                self.model.output = result.output
                self.model.trust = .failed(cask: cask, exitCode: result.exitCode)
            }
        }
    }

    private func show() {
        let window = self.window ?? makeWindow()
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    public func windowWillClose(_ notification: Notification) {
        // Closing the window does not stop brew; the menu action shows it again. The recovery
        // viewer is nothing but this window: closing it after the result quits it, and the helper
        // then starts the installed app again.
        window = nil
        if role == .viewer, runner?.isRunning != true { terminate() }
    }

    private func makeWindow() -> ChromeWindow {
        let initialStyle = theme?.chromeStyle ?? palette.chromeStyle
        let window = ChromeWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                                  style: initialStyle, showsTitle: true)
        if let theme { window.bindTheme(theme) }
        window.title = "Update \(app.displayName) via Homebrew"
        window.minSize = NSSize(width: 520, height: 340)
        window.delegate = self
        window.setContent(HomebrewUpdateView(model: model, notice: app.keptNotice, palette: palette, theme: theme,
                                             cancel: { [weak self] in self?.cancel() },
                                             trust: { [weak self] in self?.trustAndUpdate() },
                                             close: { [weak window] in window?.performClose(nil) }))
        self.window = window
        return window
    }
}

struct HomebrewUpdateView: View {
    let model: HomebrewUpdateModel
    let notice: String
    let palette: PickerPalette
    let theme: ThemeStore?
    let cancel: () -> Void
    let trust: () -> Void
    let close: () -> Void

    private var activePalette: PickerPalette { theme?.pickerPalette ?? palette }

    var body: some View {
        let current = activePalette
        let logBackground = theme.map { $0.tokens.fieldColor } ?? Color(nsColor: .textBackgroundColor)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.isBusy || model.restarting { ProgressView().controlSize(.small) }
                Text(model.title).font(.headline)
                    .foregroundStyle(Color(nsColor: model.isBusy || model.succeeded ? current.text : current.accent))
            }
            if case .needed(let cask) = model.trust {
                Text("Homebrew loads apps from taps other than its own only after you trust them, and \(cask) is not trusted on this Mac yet. Trusting it lets Homebrew load only this cask, now and for later updates. \(model.appName) then runs brew trust --cask \(cask) and updates.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.command)
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: current.text).opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.output.isEmpty ? "Waiting for brew…" : model.output)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .foregroundStyle(Color(nsColor: model.output.isEmpty ? current.secondary : current.text))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    Color.clear.frame(height: 1).id("end")
                }
                .background(logBackground, in: RoundedRectangle(cornerRadius: 4))
                .onChange(of: model.output) { proxy.scrollTo("end", anchor: .bottom) }
            }
            HStack {
                Text("Only \(model.appName) is updated. \(notice)")
                    .font(.caption).foregroundStyle(Color(nsColor: current.secondary))
                Spacer()
                if model.phase == .running {
                    Button("Cancel", action: cancel)
                } else if case .needed = model.trust {
                    Button("Close", action: close)
                    Button("Trust and Update", action: trust).keyboardShortcut(.defaultAction)
                } else if case .running = model.trust {
                    EmptyView()
                } else if !model.restarting {
                    Button("Close", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 300)
        .foregroundStyle(Color(nsColor: current.text))
        .tint(Color(nsColor: current.accent))
        .background(Color(nsColor: current.surface))
    }
}

/// The recovery viewer: the copy of the app in the run folder, started by the helper with
/// `--homebrew-update-viewer <run folder>` while the installed app is gone. It runs only this
/// window: no menu-bar icon, no hotkey, no configuration, no Sparkle.
@MainActor
public enum HomebrewUpdateViewer {
    public static func run(_ directory: URL, app: AppUpdateIdentity, palette: PickerPalette = .system,
                           theme: ThemeStore? = nil) -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        theme?.apply()
        HomebrewUpdateWindowController.shared(for: app, palette: palette, theme: theme).showRun(directory, role: .viewer)
        application.run()
        exit(0)
    }
}
