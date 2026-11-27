// Homebrew-aware updates: which copy Homebrew manages, the one command an app runs and what its
// result means. Pure logic over paths and text; the process run and the window are BobukUpdates.
// From Ting and Splash Finish, which had identical copies apart from the names.
import Foundation

/// One app's cask in the bobuk-io tap.
public struct HomebrewCask: Equatable, Sendable {
    /// Cask name, such as `ting` or `splash-finish`.
    public var name: String
    /// Fully qualified token, such as `bobuk-io/tap/ting`.
    public var tap: String
    /// The bundle the cask installs, such as `Ting.app` or `Splash Finish.app`.
    public var appBundleName: String

    public init(name: String, tap: String? = nil, appBundleName: String) {
        self.name = name
        self.tap = tap ?? "bobuk-io/tap/\(name)"
        self.appBundleName = appBundleName
    }
}

/// An app that a Caskroom record of its cask points to.
public struct HomebrewInstall: Equatable, Sendable {
    /// The Homebrew prefix that owns the record, such as `/opt/homebrew`.
    public let prefix: URL
    /// `<prefix>/Caskroom/<cask>/<version>/<App>.app`, a symlink or a copy.
    public let record: URL
    /// The installed app the record resolves to: the place to start the app again after an update.
    public let app: URL
    public let cask: HomebrewCask

    public init(prefix: URL, record: URL, app: URL, cask: HomebrewCask) {
        self.prefix = prefix
        self.record = record
        self.app = app
        self.cask = cask
    }

    /// The `brew` of the owning prefix, never one found elsewhere.
    public var brew: URL { prefix.appendingPathComponent("bin/brew") }
    /// `<prefix>/Caskroom/<cask>`.
    public var caskroom: URL { prefix.appendingPathComponent("Caskroom/\(cask.name)") }
}

public enum HomebrewDetection {
    public static let defaultPrefixes = ["/opt/homebrew", "/usr/local"]

    /// Prefixes to look at, in order: `HOMEBREW_PREFIX`, the prefix of each `brew` found in `PATH`,
    /// then the default Apple silicon and Intel prefixes. No duplicates.
    public static func prefixes(environment: [String: String],
                                fileManager: FileManager = .default) -> [URL] {
        var paths: [String] = []
        if let custom = environment["HOMEBREW_PREFIX"], custom.hasPrefix("/") { paths.append(custom) }
        for folder in (environment["PATH"] ?? "").split(separator: ":") where folder.hasPrefix("/") {
            let brew = URL(fileURLWithPath: String(folder)).appendingPathComponent("brew")
            if fileManager.isExecutableFile(atPath: brew.path) {
                // `<prefix>/bin/brew`: the prefix is the parent of `bin`.
                paths.append(brew.deletingLastPathComponent().deletingLastPathComponent().path)
            }
        }
        paths += defaultPrefixes
        var seen = Set<String>()
        return paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
    }

    /// The Homebrew record of this bundle, or nil when Homebrew does not clearly manage it.
    /// Nil keeps the Sparkle updates of a directly downloaded copy: no record, a record of another
    /// path, an unreadable Caskroom, a prefix without a runnable `brew`, or two prefixes that both
    /// claim the copy.
    public static func install(of bundle: URL, cask: HomebrewCask, prefixes: [URL],
                               fileManager: FileManager = .default) -> HomebrewInstall? {
        let target = resolved(bundle)
        var found: [HomebrewInstall] = []
        for prefix in prefixes {
            let caskroom = prefix.appendingPathComponent("Caskroom/\(cask.name)")
            guard let versions = try? fileManager.contentsOfDirectory(atPath: caskroom.path) else { continue }
            let match = versions.filter { !$0.hasPrefix(".") }.sorted().compactMap { version -> URL? in
                let record = caskroom.appendingPathComponent(version).appendingPathComponent(cask.appBundleName)
                var isFolder: ObjCBool = false
                guard fileManager.fileExists(atPath: record.path, isDirectory: &isFolder), isFolder.boolValue,
                      resolved(record) == target else { return nil }
                return record
            }.last
            guard let match else { continue }
            guard fileManager.isExecutableFile(atPath: prefix.appendingPathComponent("bin/brew").path) else { return nil }
            found.append(HomebrewInstall(prefix: prefix, record: match, app: bundle.standardizedFileURL, cask: cask))
        }
        return found.count == 1 ? found[0] : nil
    }

    private static func resolved(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// The result of one Homebrew update.
public enum HomebrewUpdateOutcome: Equatable, Sendable {
    case upgraded
    case upToDate
    case failed(exitCode: Int32, output: String)
    case cancelled(output: String)
}

public enum HomebrewUpdate {
    /// The argument with which the helper starts the installed copy again to show the result.
    public static let resultArgument = "--homebrew-update-log"
    /// The argument with which the helper starts the progress viewer, the copy of the app in the
    /// run folder, while the installed app is gone.
    public static let viewerArgument = "--homebrew-update-viewer"

    /// Only this app: the cask is always named, so Homebrew never upgrades anything else.
    /// `--greedy` because the casks say `auto_updates true`, which plain upgrades skip.
    public static func arguments(for cask: HomebrewCask) -> [String] {
        ["upgrade", "--cask", "--greedy", cask.tap]
    }

    /// The environment of the brew run, from the app's own.
    /// - `PATH` starts with the prefix: an app started by Finder or at login has a minimal PATH.
    /// - `brew upgrade` refreshes the taps first, every time. By default brew refreshes them at most
    ///   once a day, so a release published since then is invisible: brew reports "the latest
    ///   version is already installed" while the app has just announced the new one.
    public static func environment(_ base: [String: String], prefix: URL) -> [String: String] {
        var environment = base
        environment["PATH"] = "\(prefix.path)/bin:\(prefix.path)/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOMEBREW_AUTO_UPDATE_SECS"] = "0"
        environment["HOMEBREW_NO_AUTO_UPDATE"] = nil
        return environment
    }

    /// The command as the window shows it.
    public static func commandLine(for install: HomebrewInstall) -> String {
        ([install.brew.path] + arguments(for: install.cask)).joined(separator: " ")
    }

    /// Success only on exit code 0 without a cancel. Exit 0 without an upgrade report means that
    /// nothing was upgraded ("Not upgrading ting, the latest version is already installed").
    /// Every other exit code is a failure with the real output: a network error, a Homebrew lock,
    /// a refused password prompt.
    public static func outcome(exitCode: Int32, output: String, cancelled: Bool) -> HomebrewUpdateOutcome {
        if cancelled { return .cancelled(output: output) }
        guard exitCode == 0 else { return .failed(exitCode: exitCode, output: output) }
        let upgraded = output.contains("was successfully upgraded") || output.contains("Upgrading 1 outdated")
        return upgraded ? .upgraded : .upToDate
    }

    /// The run folder named by `--homebrew-update-log <folder>` (or another `argument`), accepted
    /// only directly inside `base`.
    public static func resultDirectory(in arguments: [String], base: URL,
                                       argument: String = resultArgument) -> URL? {
        guard let index = arguments.firstIndex(of: argument), index + 1 < arguments.count else { return nil }
        let folder = URL(fileURLWithPath: arguments[index + 1]).standardizedFileURL
        guard folder.deletingLastPathComponent().path == base.standardizedFileURL.path else { return nil }
        return folder
    }

    /// True when the process was started by the update helper (viewer or result), so the app must
    /// not treat its arguments as a command line.
    public static func isUpdateLaunch(_ arguments: [String]) -> Bool {
        arguments.contains(resultArgument) || arguments.contains(viewerArgument)
    }
}

/// Who updates this copy of the app.
public enum UpdaterChoice: Equatable, Sendable {
    case homebrew(HomebrewInstall)
    case sparkle
    /// A development build without a feed: no updates.
    case none

    public static func choose(homebrew: HomebrewInstall?, hasFeed: Bool, hasKey: Bool) -> UpdaterChoice {
        if let homebrew { return .homebrew(homebrew) }
        return hasFeed && hasKey ? .sparkle : .none
    }

    /// The choice for a running copy. Only a release copy (Sparkle feed and key in Info.plist) can be
    /// one that Homebrew installed, so a development build never looks. The bundle is the real app
    /// behind the executable, also when it was started through a command-line symlink.
    public static func detect(cask: HomebrewCask?, bundle: URL?, info: [String: Any],
                              environment: [String: String]) -> UpdaterChoice {
        let hasFeed = (info["SUFeedURL"] as? String)?.isEmpty == false
        let hasKey = (info["SUPublicEDKey"] as? String)?.isEmpty == false
        var homebrew: HomebrewInstall?
        if hasFeed && hasKey, let cask, let bundle {
            homebrew = HomebrewDetection.install(of: bundle, cask: cask,
                                                 prefixes: HomebrewDetection.prefixes(environment: environment))
        }
        return choose(homebrew: homebrew, hasFeed: hasFeed, hasKey: hasKey)
    }
}
