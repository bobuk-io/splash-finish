// Runs the one Homebrew command that updates the app and reports its live output and true result.
// From Ting and Splash Finish; the names of the app are parameters (`AppUpdateIdentity`).
import BobukCore
import Foundation

/// Design: brew replaces <App>.app while it runs, and the running app may be stopped or crash on
/// its replaced files. So the app does not own the brew process through a pipe. A small detached
/// helper script runs brew with its output in a log file and its exit code in a status file of a
/// run folder; any copy only reads those files. The helper ignores SIGHUP and outlives the app.
///
/// The window must stay visible while brew works, also in the moments when no installed <App>.app
/// exists (brew removed the old one and has not placed the new one, or placing it failed). So
/// before brew starts, the app copies its own bundle into the run folder (an APFS clone, cheap). The
/// helper watches the process whose pid is in the run folder; when that copy is gone while brew
/// still runs, it starts that copy with `--homebrew-update-viewer <run folder>`: a process that
/// shows only the progress window (`HomebrewUpdateViewer`), with the rest of the live output and
/// the result, independent of what brew does to the installed bundle.
///
/// After brew the helper waits for whoever shows the window to see the result. When it asks for a
/// restart, or nobody is there to show it, the helper starts the installed copy with
/// `--homebrew-update-log <run folder>`, which shows the result once more (role `.final`, which
/// never asks for another restart). "Installed copy" is looked up after brew: the newest
/// `Caskroom/<cask>/<version>/<App>.app`, resolved, because an upgrade removes the old version folder;
/// the old place only when no record is left. With no installed copy at all, the viewer shows the
/// result unless someone has already seen it.
/// Who shows a run, given explicitly by how the process was started.
public enum HomebrewUpdateRole: Equatable, Sendable {
    /// The copy that started the update from its menu.
    case owner
    /// The copy in the run folder that the helper started while the installed app was gone.
    case viewer
    /// The installed app that the helper started after brew to show the result.
    case final

    /// Whether this process should quit so that the helper starts the installed app. The owner
    /// and the viewer may run old or removed code after a success; the final copy is the new one.
    /// After a failure the viewer also hands over, so that the app is back once its window is closed.
    public func restarts(after outcome: HomebrewUpdateOutcome) -> Bool {
        switch self {
        case .owner, .viewer: outcome == .upgraded
        case .final: false
        }
    }

    public func relaunchWhenDone(after outcome: HomebrewUpdateOutcome) -> Bool {
        self == .viewer || restarts(after: outcome)
    }
}

@MainActor
public final class HomebrewUpdateRunner {
    /// Nil for a copy that only watches a run that another copy started.
    public let install: HomebrewInstall?
    public let app: AppUpdateIdentity
    private let appPID: pid_t
    private let base: URL
    private let opener: URL
    private let shell: URL
    private let viewerSource: URL?
    private let pollInterval: TimeInterval

    private var helper: Process?
    private var timer: Timer?
    private var onOutput: ((String) -> Void)?
    private var onFinish: ((HomebrewUpdateOutcome) -> Void)?
    private var lastOutput = ""
    /// The run folder of the current or last run.
    public private(set) var directory: URL?

    public init(app: AppUpdateIdentity, install: HomebrewInstall?,
                appPID: pid_t = ProcessInfo.processInfo.processIdentifier,
                base: URL? = nil,
                opener: URL = URL(fileURLWithPath: "/usr/bin/open"),
                shell: URL = URL(fileURLWithPath: "/bin/sh"),
                viewerSource: URL? = AppBundle.applicationURL,
                pollInterval: TimeInterval = 0.25) {
        self.app = app
        self.install = install
        self.appPID = appPID
        self.base = base ?? app.runBase
        self.opener = opener
        self.shell = shell
        self.viewerSource = viewerSource
        self.pollInterval = pollInterval
    }

    public var isRunning: Bool { timer != nil }

    /// Starts the update. Returns false, and starts nothing, while another run is in progress.
    /// A run that cannot start finishes at once with `.failed` and the reason as its output.
    @discardableResult
    public func start(onOutput: @escaping (String) -> Void, onFinish: @escaping (HomebrewUpdateOutcome) -> Void) -> Bool {
        guard !isRunning else { return false }
        guard let install else {
            onFinish(.failed(exitCode: -1, output: "Homebrew does not manage this copy of \(app.displayName)."))
            return true
        }
        let fm = FileManager.default
        let folder = base.appendingPathComponent(UUID().uuidString)
        let script = folder.appendingPathComponent("update.sh")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try Self.helperScript.write(to: script, atomically: false, encoding: .utf8)
            try Data().write(to: folder.appendingPathComponent("output.log"))
            try HomebrewUpdate.commandLine(for: install)
                .write(to: folder.appendingPathComponent("command"), atomically: false, encoding: .utf8)
            try String(appPID).write(to: folder.appendingPathComponent("pid"), atomically: false, encoding: .utf8)
        } catch {
            onFinish(.failed(exitCode: -1, output: "Could not prepare the update in \(folder.path): \(error.localizedDescription)"))
            return true
        }
        // The progress viewer for the time without an installed app. It is required: without a
        // complete copy nothing could show the progress while brew replaces the app, so brew never starts.
        do {
            try Self.prepareViewer(from: viewerSource, in: folder, app: app)
        } catch {
            onFinish(.failed(exitCode: -1, output: "Could not prepare the progress window in \(folder.path): \(error.localizedDescription)"))
            return true
        }
        Self.removeOldRuns(in: base, keeping: folder)
        let process = Process()
        process.executableURL = shell
        process.arguments = [script.path, folder.path, install.app.path, install.caskroom.path,
                             opener.path, app.cask.appBundleName, app.executableName,
                             install.brew.path] + HomebrewUpdate.arguments(for: install.cask)
        process.environment = HomebrewUpdate.environment(ProcessInfo.processInfo.environment, prefix: install.prefix)
        // No terminal: a password prompt (sudo) fails instead of waiting forever, and brew reports it.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            onFinish(.failed(exitCode: -1, output: "Could not start the update helper \(shell.path): \(error.localizedDescription)"))
            return true
        }
        helper = process
        begin(folder, onOutput: onOutput, onFinish: onFinish)
        return true
    }

    /// Shows a run that another copy of the app started (`--homebrew-update-log`): this process takes
    /// over as the one the helper waits for. Returns false while a run is in progress here.
    @discardableResult
    public func watch(_ folder: URL, onOutput: @escaping (String) -> Void,
               onFinish: @escaping (HomebrewUpdateOutcome) -> Void) -> Bool {
        guard !isRunning else { return false }
        try? String(appPID).write(to: folder.appendingPathComponent("pid"), atomically: false, encoding: .utf8)
        begin(folder, onOutput: onOutput, onFinish: onFinish)
        return true
    }

    private func begin(_ folder: URL, onOutput: @escaping (String) -> Void,
                       onFinish: @escaping (HomebrewUpdateOutcome) -> Void) {
        directory = folder
        lastOutput = ""
        self.onOutput = onOutput
        self.onFinish = onFinish
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    /// Stops brew. The result is a cancel, never a success. A watching copy has no helper of its
    /// own; it asks the helper through the run folder.
    public func cancel() {
        guard isRunning, let directory else { return }
        if let helper, helper.isRunning {
            helper.terminate()
        } else {
            try? Data().write(to: directory.appendingPathComponent("cancel"))
        }
    }

    /// Acknowledges the result for `role`. Returns true when this process should quit now so
    /// that the helper starts the installed app.
    @discardableResult
    public func conclude(_ outcome: HomebrewUpdateOutcome, role: HomebrewUpdateRole) -> Bool {
        acknowledge(relaunch: role.relaunchWhenDone(after: outcome))
        return role.restarts(after: outcome)
    }

    public enum ViewerError: LocalizedError {
        case noBundle
        case incomplete(String)
        public var errorDescription: String? {
            switch self {
            case .noBundle: "this copy is not running from an app bundle that can be copied."
            case .incomplete(let path): "the copy has no executable at \(path)."
            }
        }
    }

    /// Copies `source` (<App>.app) to `<run folder>/viewer/<App>.app` and checks that its executable
    /// is there, the one the helper starts.
    public static func prepareViewer(from source: URL?, in folder: URL, app: AppUpdateIdentity) throws {
        guard let source else { throw ViewerError.noBundle }
        let fm = FileManager.default
        let viewer = folder.appendingPathComponent("viewer")
        try fm.createDirectory(at: viewer, withIntermediateDirectories: true)
        let copy = viewer.appendingPathComponent(app.cask.appBundleName)
        try fm.copyItem(at: source, to: copy)
        let executable = copy.appendingPathComponent("Contents/MacOS").appendingPathComponent(app.executableName)
        guard fm.isExecutableFile(atPath: executable.path) else { throw ViewerError.incomplete(executable.path) }
    }

    /// Run folders of earlier updates, older than a day, with their viewer copies.
    public static func removeOldRuns(in base: URL, keeping current: URL) {
        let fm = FileManager.default
        let limit = Date().addingTimeInterval(-86_400)
        for folder in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where folder.lastPathComponent != current.lastPathComponent {
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let date, date < limit { try? fm.removeItem(at: folder) }
        }
    }

    /// Tells the helper that the app has seen the result; with `relaunch` the helper starts the
    /// installed copy again as soon as this process has quit.
    public func acknowledge(relaunch: Bool) {
        guard let directory else { return }
        // Plain writes: the helper only checks that the markers exist.
        if relaunch { try? Data().write(to: directory.appendingPathComponent("relaunch")) }
        try? Data().write(to: directory.appendingPathComponent("handled"))
    }

    private func poll() {
        guard let directory, isRunning else { return }
        let output = Self.output(in: directory)
        if output != lastOutput {
            lastOutput = output
            onOutput?(output)
        }
        guard let outcome = Self.outcome(in: directory) else { return }
        timer?.invalidate()
        timer = nil
        helper = nil
        let finish = onFinish
        onOutput = nil
        onFinish = nil
        finish?(outcome)
    }

    public static func output(in directory: URL) -> String {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("output.log")) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The result once the helper wrote the exit code of brew; nil while brew runs.
    public static func outcome(in directory: URL) -> HomebrewUpdateOutcome? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("status"), encoding: .utf8),
              let code = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let cancelled = FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled").path)
        return HomebrewUpdate.outcome(exitCode: code, output: output(in: directory), cancelled: cancelled)
    }

    /// Arguments: run folder, installed app, Caskroom folder of the cask, opener, bundle name,
    /// executable name, then brew and its arguments. The command itself comes from
    /// `HomebrewUpdate.arguments(for:)`, never from this text. The pid of the copy that shows the
    /// window is in `<run folder>/pid`. Names are arguments, so spaces ("Splash Finish.app") are safe.
    public static let helperScript = #"""
    #!/bin/sh
    dir=$1; app=$2; caskroom=$3; opener=$4; bundle=$5; executable=$6; shift 6
    viewer="$dir/viewer/$bundle/Contents/MacOS/$executable"
    trap '' HUP
    alive() { p=$(cat "$dir/pid" 2>/dev/null); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
    target() {
      found=""
      for v in $(ls "$caskroom" 2>/dev/null | sort -V); do
        r="$caskroom/$v/$bundle"
        [ -d "$r" ] && found=$(cd -P "$r" 2>/dev/null && pwd -P)
      done
      [ -z "$found" ] && [ -d "$app" ] && found=$app
      [ -n "$found" ] && printf '%s\n' "$found"
    }
    show() {
      [ -x "$viewer" ] || return 1
      rm -f "$dir/pid"
      "$viewer" --homebrew-update-viewer "$dir" >/dev/null 2>&1 </dev/null &
    }
    final() {
      t=$(target)
      if [ -n "$t" ]; then
        rm -f "$dir/pid"
        "$opener" "$t" --args --homebrew-update-log "$dir"
      elif [ ! -e "$dir/handled" ]; then
        show
      fi
    }
    "$@" >"$dir/output.log" 2>&1 </dev/null &
    child=$!
    trap ': >"$dir/cancelled"; kill -TERM "$child" 2>/dev/null' TERM INT
    last=0
    while kill -0 "$child" 2>/dev/null; do
      if [ -e "$dir/cancel" ] && [ ! -e "$dir/cancelled" ]; then : >"$dir/cancelled"; kill -TERM "$child" 2>/dev/null; fi
      if ! alive; then
        now=$(date +%s)
        if [ $((now - last)) -ge 10 ]; then
          if show; then last=$now; fi
        fi
      fi
      sleep 0.2
    done
    wait "$child"; code=$?
    printf '%s\n' "$code" >"$dir/status.tmp" && mv "$dir/status.tmp" "$dir/status"
    trap '' TERM INT
    gone=0
    while [ ! -e "$dir/handled" ] && [ "$gone" -lt 50 ]; do
      if alive; then gone=0; else gone=$((gone + 1)); fi
      sleep 0.2
    done
    if [ -e "$dir/handled" ] && [ ! -e "$dir/relaunch" ]; then exit 0; fi
    while alive; do sleep 0.2; done
    final
    """#
}
