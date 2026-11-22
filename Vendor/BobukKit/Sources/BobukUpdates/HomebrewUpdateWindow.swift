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

    public let appName: String
    public var command = ""
    public var output = ""
    public var phase: Phase = .running
    /// True after a success, while the app quits so that the helper starts the new copy.
    public var restarting = false

    public init(appName: String) { self.appName = appName }

    public var title: String {
        switch phase {
        case .running: "Updating \(appName) via Homebrew…"
        case .finished(.upgraded): restarting ? "\(appName) was updated. Restarting…" : "\(appName) was updated."
        case .finished(.upToDate): "\(appName) is already up to date."
        case .finished(.failed(let code, _)): "The update failed (brew exit code \(code))."
        case .finished(.cancelled): "The update was cancelled."
        }
    }

    public var succeeded: Bool { phase == .finished(.upgraded) || phase == .finished(.upToDate) }

    /// Shows the result. A failure or cancel shows the text it carries: the whole brew output, or
    /// the reason why the run could not start when there is no log at all.
    public func finish(_ outcome: HomebrewUpdateOutcome, log: String?) {
        switch outcome {
        case .failed(_, let text), .cancelled(let text):
            output = text.isEmpty ? (log ?? output) : text
        case .upgraded, .upToDate:
            output = log ?? output
        }
        phase = .finished(outcome)
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
        role = .owner
        model.command = HomebrewUpdate.commandLine(for: install)
        model.output = ""
        model.phase = .running
        model.restarting = false
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
        let runner = HomebrewUpdateRunner(app: app, install: nil)
        self.runner = runner
        show()
        runner.watch(directory, onOutput: { [weak self] in self?.model.output = $0 },
                     onFinish: { [weak self] in self?.finish($0) })
    }

    private func finish(_ outcome: HomebrewUpdateOutcome) {
        model.finish(outcome, log: (runner?.directory).map(HomebrewUpdateRunner.output(in:)))
        // The viewer exists only to show this result: bring its window back if it was closed.
        if role == .viewer { show() }
        guard runner?.conclude(outcome, role: role) == true else { return }
        // Quit so that the helper starts the installed app, which shows this result again.
        model.restarting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.terminate() }
    }

    private func cancel() { runner?.cancel() }

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
                                             close: { [weak window] in window?.performClose(nil) }))
        self.window = window
        return window
    }
}

private struct HomebrewUpdateView: View {
    let model: HomebrewUpdateModel
    let notice: String
    let palette: PickerPalette
    let theme: ThemeStore?
    let cancel: () -> Void
    let close: () -> Void

    private var activePalette: PickerPalette { theme?.pickerPalette ?? palette }

    var body: some View {
        let current = activePalette
        let logBackground = theme.map { $0.tokens.fieldColor } ?? Color(nsColor: .textBackgroundColor)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if model.phase == .running || model.restarting { ProgressView().controlSize(.small) }
                Text(model.title).font(.headline)
                    .foregroundStyle(Color(nsColor: model.phase == .running || model.succeeded ? current.text : current.accent))
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
