import AppKit
import Foundation
import SwiftUI
import Testing
import BobukCore
@testable import BobukUpdates

/// The runner and the updater choice of the app. `brew` and `open` are fake scripts in a temporary
/// folder: no test runs the real Homebrew, touches /Applications or opens an app.
@MainActor
@Suite(.serialized) struct HomebrewUpdateTests {
    private let root: URL
    private let fm = FileManager.default
    /// Spaces in the names exercise the quoting of the helper script, as "Splash Finish.app" does.
    private let demo = AppUpdateIdentity(displayName: "Demo App", executableName: "DemoApp",
                                         cask: HomebrewCask(name: "demo-app", appBundleName: "Demo App.app"),
                                         bundleIdentifier: "io.bobuk.demo-app", keptNotice: "Settings are kept.")

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("bobukkit-brew-run-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func script(_ path: String, _ body: String) throws -> URL {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n\(body)\n".write(to: file, atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    /// A Homebrew prefix whose fake `brew` records its arguments and then runs `body`.
    private func install(brew body: String) throws -> HomebrewInstall {
        let prefix = root.appendingPathComponent("prefix")
        let calls = root.appendingPathComponent("brew-calls").path
        _ = try script("prefix/bin/brew", "printf '%s\\n' \"$*\" >> '\(calls)'\n\(body)")
        let app = root.appendingPathComponent("Applications/Demo App.app")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        let folder = prefix.appendingPathComponent("Caskroom/demo-app/0.7.3")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: folder.appendingPathComponent("Demo App.app"), withDestinationURL: app)
        return try #require(HomebrewDetection.install(of: app, cask: demo.cask, prefixes: [prefix]))
    }

    private func runner(_ install: HomebrewInstall, pid: pid_t = ProcessInfo.processInfo.processIdentifier) throws -> HomebrewUpdateRunner {
        let opener = try script("bin/open", "printf '%s\\n' \"$*\" >> '\(root.appendingPathComponent("open-calls").path)'")
        // A fake Demo App.app whose executable records how the helper started the progress viewer.
        _ = try script("ViewerSource/Demo App.app/Contents/MacOS/DemoApp",
                       "printf '%s\\n' \"$*\" >> '\(root.appendingPathComponent("viewer-calls").path)'")
        return HomebrewUpdateRunner(app: demo, install: install, appPID: pid, base: root.appendingPathComponent("runs"),
                                    opener: opener, viewerSource: root.appendingPathComponent("ViewerSource/Demo App.app"),
                                    pollInterval: 0.05)
    }

    /// A stand-in for the viewer process: alive until the test ends it, like a window the person closes.
    private func viewerProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        return process
    }

    private func attach(_ directory: URL, pid: pid_t) async throws -> (HomebrewUpdateRunner, HomebrewUpdateOutcome, [String]) {
        let watcher = HomebrewUpdateRunner(app: demo, install: nil, appPID: pid, base: root.appendingPathComponent("runs"),
                                           viewerSource: nil, pollInterval: 0.05)
        var seen: [String] = []
        let outcome = try await withCheckedThrowingContinuation { continuation in
            watcher.watch(directory, onOutput: { seen.append($0) }, onFinish: { continuation.resume(returning: $0) })
        }
        return (watcher, outcome, seen)
    }

    private func finish(_ runner: HomebrewUpdateRunner, output: ((String) -> Void)? = nil) async throws -> HomebrewUpdateOutcome {
        try await withCheckedThrowingContinuation { continuation in
            let started = runner.start(onOutput: { output?($0) }, onFinish: { continuation.resume(returning: $0) })
            if !started { continuation.resume(throwing: CancellationError()) }
        }
    }

    private func read(_ name: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    private func waitFor(_ name: String) async throws -> String {
        for _ in 0..<200 {
            let text = read(name)
            if !text.isEmpty { return text }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return ""
    }

    @Test func homebrewSuccessRunsOnlyTheTingCask() async throws {
        let install = try install(brew: "echo '==> Upgrading 1 outdated package:'\necho '🍺  ting was successfully upgraded!'")
        let runner = try runner(install)
        var lines = ""
        let outcome = try await finish(runner) { lines = $0 }
        #expect(outcome == .upgraded)
        #expect(read("brew-calls") == "upgrade --cask --greedy bobuk-io/tap/demo-app\n")
        #expect(lines.contains("successfully upgraded"))
        let directory = try #require(runner.directory)
        runner.acknowledge(relaunch: true)
        // The helper starts the installed copy again once this process is gone; here it is
        // still alive, so the opener has not run yet.
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(read("open-calls").isEmpty)
        #expect(fm.fileExists(atPath: directory.appendingPathComponent("relaunch").path))
    }

    @Test func homebrewUpToDate() async throws {
        let install = try install(brew: "echo 'Warning: Not upgrading ting, the latest version is already installed' >&2")
        let runner = try runner(install)
        #expect(try await finish(runner) == .upToDate)
        runner.acknowledge(relaunch: false)
    }

    @Test func homebrewFailureKeepsTheOutput() async throws {
        let install = try install(brew: "echo 'Error: Download failed: Could not resolve host' >&2\nexit 1")
        let runner = try runner(install)
        let outcome = try await finish(runner)
        #expect(outcome == .failed(exitCode: 1, output: "Error: Download failed: Could not resolve host\n"))
        runner.acknowledge(relaunch: false)
    }

    @Test func homebrewSecondStartIsRefused() async throws {
        let install = try install(brew: "sleep 1\necho done")
        let runner = try runner(install)
        let first = Task { try await finish(runner) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(runner.isRunning)
        #expect(!runner.start(onOutput: { _ in }, onFinish: { _ in }))
        #expect(try await first.value == .upToDate)
        #expect(read("brew-calls") == "upgrade --cask --greedy bobuk-io/tap/demo-app\n")
        runner.acknowledge(relaunch: false)
    }

    @Test func homebrewCancelIsNotSuccess() async throws {
        let install = try install(brew: "echo started\nsleep 5\necho '🍺  ting was successfully upgraded!'")
        let runner = try runner(install)
        let pending = Task { try await finish(runner) }
        try await Task.sleep(nanoseconds: 300_000_000)
        runner.cancel()
        let outcome = try await pending.value
        guard case .cancelled = outcome else { Issue.record("Expected a cancel, got \(outcome)"); return }
        runner.acknowledge(relaunch: false)
    }

    /// The path with every symlink resolved, as `cd -P` in the helper gives it.
    private func real(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else { return url.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A process that has already exited: a Ting that brew stopped or that crashed.
    private func deadPID() throws -> pid_t {
        let dead = Process()
        dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try dead.run()
        dead.waitUntilExit()
        return dead.processIdentifier
    }

    /// brew may stop or replace Ting while it runs. The helper sees that Ting is gone while brew
    /// still works and starts the progress viewer from the copy in the run folder at once, not the
    /// installed app; the viewer gets the output that brew writes after Ting's exit and the result,
    /// and after the success hands over to the installed copy.
    @Test func homebrewProgressStaysVisibleAfterTingQuits() async throws {
        // brew goes on only after the test has looked, not after a fixed sleep: under load the
        // viewer may start later than any sleep, and the test would then see the finished run.
        let go = root.appendingPathComponent("go")
        let install = try install(brew: """
            echo first
            i=0; while [ ! -f '\(go.path)' ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
            echo second
            echo '🍺  ting was successfully upgraded!'
            """)
        let runner = try runner(install, pid: try deadPID())
        _ = runner.start(onOutput: { _ in }, onFinish: { _ in })
        let directory = try #require(runner.directory)
        let viewed = try await waitFor("viewer-calls")
        #expect(viewed == "--homebrew-update-viewer \(directory.path)\n")
        // Started while brew still runs: no result yet, and the rest of the output is still to come.
        #expect(HomebrewUpdateRunner.outcome(in: directory) == nil)
        #expect(!HomebrewUpdateRunner.output(in: directory).contains("second"))
        #expect(read("open-calls").isEmpty)
        try Data().write(to: go)

        let viewer = try viewerProcess()
        let (watcher, outcome, seen) = try await attach(directory, pid: viewer.processIdentifier)
        #expect(outcome == .upgraded)
        #expect(seen.contains { $0.contains("second") })
        #expect(try String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8)
            == String(viewer.processIdentifier))
        #expect(watcher.conclude(outcome, role: .viewer))
        viewer.terminate()
        viewer.waitUntilExit()
        #expect(try await waitFor("open-calls") == "\(real(install.app)) --args --homebrew-update-log \(directory.path)\n")
    }

    /// brew removes the installed app and then fails to place the new one: no Demo App.app exists, yet
    /// the viewer (a copy outside the installed bundle) shows the progress and the failure.
    @Test func homebrewFailedReplacementStaysVisible() async throws {
        let install = try install(brew: "")
        _ = try script("prefix/bin/brew", """
            rm -rf '\(install.app.path)'
            echo 'Removing old Demo App.app'
            sleep 1
            echo 'Error: could not move the new Demo App.app into place' >&2
            exit 1
            """)
        let runner = try runner(install, pid: try deadPID())
        _ = runner.start(onOutput: { _ in }, onFinish: { _ in })
        let directory = try #require(runner.directory)
        #expect(try await waitFor("viewer-calls") == "--homebrew-update-viewer \(directory.path)\n")

        let viewer = try viewerProcess()
        let (watcher, outcome, _) = try await attach(directory, pid: viewer.processIdentifier)
        guard case .failed(1, let output) = outcome else { Issue.record("Expected a failure, got \(outcome)"); return }
        #expect(output.contains("could not move the new Demo App.app"))
        #expect(!fm.fileExists(atPath: install.app.path))
        // The viewer keeps the failure on screen until the person closes it.
        #expect(!watcher.conclude(outcome, role: .viewer))
        viewer.terminate()
        viewer.waitUntilExit()
        try await Task.sleep(nanoseconds: 800_000_000)
        // Nothing to start: no installed copy, and the result was already seen.
        #expect(read("open-calls").isEmpty)
        #expect(read("viewer-calls") == "--homebrew-update-viewer \(directory.path)\n")
    }

    /// The helper starts the viewer while brew runs, but the viewer attaches only after brew is
    /// done. It is still a recovery launch: after the success it hands over to the installed copy.
    /// Only the copy started after brew (`.final`) never restarts.
    @Test func homebrewLateRecoveryStillRestarts() async throws {
        let allowBrewToFinish = root.appendingPathComponent("allow-brew-to-finish")
        let install = try install(brew: "while [ ! -f '\(allowBrewToFinish.path)' ]; do sleep 0.01; done\necho '🍺  ting was successfully upgraded!'")
        let runner = try runner(install, pid: try deadPID())
        _ = runner.start(onOutput: { _ in }, onFinish: { _ in })
        let directory = try #require(runner.directory)
        _ = try await waitFor("viewer-calls")
        #expect(HomebrewUpdateRunner.outcome(in: directory) == nil)
        try Data().write(to: allowBrewToFinish)
        while HomebrewUpdateRunner.outcome(in: directory) == nil { try await Task.sleep(nanoseconds: 50_000_000) }

        let viewer = try viewerProcess()
        let (watcher, outcome, _) = try await attach(directory, pid: viewer.processIdentifier)
        #expect(outcome == .upgraded)
        #expect(watcher.conclude(outcome, role: .viewer))
        #expect(fm.fileExists(atPath: directory.appendingPathComponent("relaunch").path))
        viewer.terminate()
        viewer.waitUntilExit()
        #expect(try await waitFor("open-calls") == "\(real(install.app)) --args --homebrew-update-log \(directory.path)\n")

        #expect(!HomebrewUpdateRole.final.restarts(after: .upgraded))
        #expect(!HomebrewUpdateRole.final.relaunchWhenDone(after: .upgraded))
        #expect(HomebrewUpdateRole.owner.restarts(after: .upgraded))
        #expect(!HomebrewUpdateRole.owner.restarts(after: .upToDate))
    }

    /// The reopened copy has no helper of its own; its Cancel still stops brew, and is no success.
    @Test func homebrewWatcherCancelIsNotSuccess() async throws {
        let install = try install(brew: "echo started\nsleep 5\necho '🍺  ting was successfully upgraded!'")
        let runner = try runner(install)
        _ = runner.start(onOutput: { _ in }, onFinish: { _ in })
        let directory = try #require(runner.directory)
        let watcher = HomebrewUpdateRunner(app: demo, install: nil, base: root.appendingPathComponent("runs"), pollInterval: 0.05)
        let outcome = try await withCheckedThrowingContinuation { continuation in
            watcher.watch(directory, onOutput: { _ in }, onFinish: { continuation.resume(returning: $0) })
            watcher.cancel()
        }
        guard case .cancelled = outcome else { Issue.record("Expected a cancel, got \(outcome)"); return }
        watcher.acknowledge(relaunch: false)
    }

    /// A copy that runs from the Caskroom: the upgrade removes its version folder. The restart
    /// opens the new record, not the old path.
    @Test func homebrewRestartOpensTheReplacement() async throws {
        let prefix = root.appendingPathComponent("prefix")
        let caskroom = prefix.appendingPathComponent("Caskroom/demo-app")
        let old = caskroom.appendingPathComponent("0.7.3/Demo App.app")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        _ = try script("prefix/bin/brew", """
            rm -rf '\(caskroom.appendingPathComponent("0.7.3").path)'
            mkdir -p '\(caskroom.appendingPathComponent("0.7.4/Demo App.app").path)'
            echo '🍺  ting was successfully upgraded!'
            """)
        let install = try #require(HomebrewDetection.install(of: old, cask: demo.cask, prefixes: [prefix]))
        let ting = Process()
        ting.executableURL = URL(fileURLWithPath: "/bin/sleep")
        ting.arguments = ["30"]
        try ting.run()
        let runner = try runner(install, pid: ting.processIdentifier)
        #expect(try await finish(runner) == .upgraded)
        let directory = try #require(runner.directory)
        runner.acknowledge(relaunch: true)
        ting.terminate()
        ting.waitUntilExit()
        let opened = try await waitFor("open-calls")
        #expect(!fm.fileExists(atPath: old.path))
        #expect(opened == "\(real(caskroom.appendingPathComponent("0.7.4/Demo App.app"))) --args --homebrew-update-log \(directory.path)\n")
    }

    /// Without a complete copy of Demo App.app for the progress viewer, nothing could show the
    /// progress while brew replaces Ting: brew is never started, and the window shows why.
    @Test func homebrewViewerCopyFailureStartsNoBrew() async throws {
        let install = try install(brew: "echo '🍺  ting was successfully upgraded!'")
        let broken = root.appendingPathComponent("Broken/Demo App.app")
        try fm.createDirectory(at: broken.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let cases: [(URL?, String)] = [
            (nil, "not running from an app bundle"),
            (root.appendingPathComponent("Missing/Demo App.app"), "Could not prepare the progress window"),
            (broken, "has no executable"),
        ]
        for (source, reason) in cases {
            let runner = HomebrewUpdateRunner(app: demo, install: install, base: root.appendingPathComponent("runs"),
                                              viewerSource: source, pollInterval: 0.05)
            let outcome = try await finish(runner)
            guard case .failed(-1, let text) = outcome else { Issue.record("Expected a failure, got \(outcome)"); continue }
            #expect(text.contains("Could not prepare the progress window"))
            #expect(text.contains(reason))
            let model = HomebrewUpdateModel(appName: "Demo App")
            model.finish(outcome, log: runner.directory.map(HomebrewUpdateRunner.output(in:)))
            #expect(model.output == text)
            #expect(!runner.isRunning)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(read("brew-calls").isEmpty)
    }

    /// A run that cannot start shows its reason, not an empty log.
    @Test func homebrewStartupFailuresShowTheReason() async throws {
        let install = try install(brew: "exit 0")
        _ = try script("ViewerSource/Demo App.app/Contents/MacOS/DemoApp", "exit 0")
        let blocker = root.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)
        let unpreparable = HomebrewUpdateRunner(app: demo, install: install, base: blocker, viewerSource: nil, pollInterval: 0.05)
        let unstartable = HomebrewUpdateRunner(app: demo, install: install, base: root.appendingPathComponent("runs"),
                                               shell: root.appendingPathComponent("missing/sh"),
                                               viewerSource: root.appendingPathComponent("ViewerSource/Demo App.app"),
                                               pollInterval: 0.05)
        for (runner, reason) in [(unpreparable, "Could not prepare the update"), (unstartable, "Could not start the update helper")] {
            let outcome = try await finish(runner)
            guard case .failed(let code, let text) = outcome else { Issue.record("Expected a failure, got \(outcome)"); continue }
            #expect(code == -1)
            #expect(text.contains(reason))
            let model = HomebrewUpdateModel(appName: "Demo App")
            model.finish(outcome, log: runner.directory.map(HomebrewUpdateRunner.output(in:)))
            #expect(model.output == text)
            #expect(model.phase == .finished(outcome))
            #expect(!model.succeeded)
        }
        #expect(read("brew-calls").isEmpty)
    }

    private static let refusal = """
        Error: Refusing to load cask bobuk-io/tap/demo-app from untrusted tap bobuk-io/tap.
        Run `brew trust --cask bobuk-io/tap/demo-app` or `brew trust bobuk-io/tap` to trust it.
        """

    @Test func homebrewTrustRunsOnlyThisCask() async throws {
        let trusting = try install(brew: "echo \"==> Trusted cask $3\"")
        let result = await HomebrewTrust.run(trusting, environment: ["PATH": "/usr/bin"])
        #expect(result == HomebrewTrust.Result(exitCode: 0, output: "==> Trusted cask bobuk-io/tap/demo-app\n"))
        #expect(read("brew-calls") == "trust --cask bobuk-io/tap/demo-app\n")
        #expect(HomebrewUpdate.trustCommandLine(for: trusting) == "\(trusting.brew.path) trust --cask bobuk-io/tap/demo-app")
        try FileManager.default.removeItem(at: root.appendingPathComponent("prefix"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Applications"))
        let failing = try install(brew: "echo nope >&2; exit 3")
        let failed = await HomebrewTrust.run(failing)
        #expect(failed.exitCode == 3)
        #expect(failed.output == "nope\n")
        #expect(!failed.succeeded)
    }

    /// A refusal of this cask as untrusted asks to trust it; nothing else does.
    @Test func homebrewRefusalAsksForTrust() {
        let model = HomebrewUpdateModel(appName: "Demo App")
        model.finish(.failed(exitCode: 1, output: Self.refusal), log: nil, cask: demo.cask)
        #expect(model.trust == .needed(cask: "bobuk-io/tap/demo-app"))
        #expect(model.title == "Homebrew does not trust bobuk-io/tap/demo-app yet.")
        #expect(!model.isBusy)
        let other = Self.refusal.replacingOccurrences(of: "demo-app", with: "other")
        for (outcome, cask) in [(HomebrewUpdateOutcome.failed(exitCode: 1, output: other), demo.cask),
                                (.failed(exitCode: 1, output: "Error: Download failed"), demo.cask),
                                (.cancelled(output: Self.refusal), demo.cask),
                                (.failed(exitCode: 1, output: Self.refusal), nil)] as [(HomebrewUpdateOutcome, HomebrewCask?)] {
            model.finish(outcome, log: nil, cask: cask)
            #expect(model.trust == .none)
        }
        // The text may be only in the log.
        model.finish(.failed(exitCode: 1, output: ""), log: Self.refusal, cask: demo.cask)
        #expect(model.trust == .needed(cask: "bobuk-io/tap/demo-app"))
    }

    @Test func homebrewTrustThenUpdateAgain() async throws {
        let install = try install(brew: "exit 0")
        let controller = HomebrewUpdateWindowController(app: demo)
        var trusted: [HomebrewInstall] = []
        var restarted: [HomebrewInstall] = []
        var result = HomebrewTrust.Result(exitCode: 0, output: "")
        controller.runTrust = { trusted.append($0); return result }
        controller.restart = { restarted.append($0) }
        // Nothing to trust before the refusal.
        controller.trustAndUpdate()
        controller.install = install
        controller.finish(.failed(exitCode: 1, output: Self.refusal))
        #expect(controller.model.trust == .needed(cask: "bobuk-io/tap/demo-app"))
        controller.trustAndUpdate()
        #expect(controller.model.trust == .running(cask: "bobuk-io/tap/demo-app"))
        #expect(controller.model.isBusy)
        #expect(controller.model.command.hasSuffix("brew trust --cask bobuk-io/tap/demo-app"))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(trusted == [install])
        #expect(restarted == [install])
        #expect(controller.model.trust == .none)

        result = HomebrewTrust.Result(exitCode: 1, output: "Error: no such cask")
        controller.finish(.failed(exitCode: 1, output: Self.refusal))
        controller.trustAndUpdate()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(controller.model.trust == .failed(cask: "bobuk-io/tap/demo-app", exitCode: 1))
        #expect(controller.model.output == "Error: no such cask")
        #expect(controller.model.title == "Homebrew could not trust bobuk-io/tap/demo-app (brew exit code 1).")
        #expect(restarted.count == 1)
    }

    /// With BOBUKKIT_PREVIEW_DIR set, renders the trust question offscreen for a look.
    @Test func homebrewTrustPreview() async throws {
        guard let dir = ProcessInfo.processInfo.environment["BOBUKKIT_PREVIEW_DIR"] else { return }
        let model = HomebrewUpdateModel(appName: "Ting")
        model.command = "/opt/homebrew/bin/brew upgrade --cask --greedy bobuk-io/tap/ting"
        let cask = HomebrewCask(name: "ting", appBundleName: "Ting.app")
        model.finish(.failed(exitCode: 1, output: Self.refusal.replacingOccurrences(of: "demo-app", with: "ting")), log: nil, cask: cask)
        let view = HomebrewUpdateView(model: model, notice: "Settings and bindings are kept.", palette: .system, theme: nil,
                                      cancel: {}, trust: {}, close: {})
        let hosting = NSHostingView(rootView: view.frame(width: 620, height: 420))
        hosting.frame = NSRect(x: 0, y: 0, width: 620, height: 420)
        try await Task.sleep(for: .milliseconds(80))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("homebrew-trust.png"))
    }

    @Test func homebrewChoiceStartsNoSparkle() throws {
        let install = try install(brew: "exit 0")
        var made = 0
        let service = UpdateService(app: demo, choice: .homebrew(install), makeSparkle: { made += 1; return FakeSparkle() })
        #expect(made == 0)
        #expect(service.homebrew == install)
        #expect(!service.isAvailable)
        #expect(service.menuTitle == "Update Demo App via Homebrew…")
    }

    @Test func homebrewChoiceSparkleAndNone() {
        var made = 0
        let sparkle = UpdateService(app: demo, choice: .sparkle, makeSparkle: { made += 1; return FakeSparkle() })
        #expect(made == 1)
        #expect(sparkle.isAvailable)
        #expect(sparkle.homebrew == nil)
        #expect(sparkle.menuTitle == "Check for Updates…")

        let none = UpdateService(app: demo, choice: .none, makeSparkle: { made += 1; return FakeSparkle() })
        #expect(made == 1)
        #expect(!none.isAvailable)
        #expect(none.menuTitle == nil)
    }
}

@MainActor
private final class FakeSparkle: SparkleUpdating {
    var automaticallyChecks = true
    var canCheck = true
    func check() {}
}
