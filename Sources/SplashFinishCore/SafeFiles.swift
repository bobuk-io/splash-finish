import Foundation
import Darwin

public enum SafeFiles {
    /// Refuse symlinks at every existing component, including dangling links.
    public static func check(_ url: URL) throws {
        var path = url.standardizedFileURL
        while path.path != "/" {
            var info = stat()
            if lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                // macOS exposes these protected system directories through root aliases.
                let alias = path.path
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: alias)
                let systemAlias = ["/var", "/tmp", "/etc"].contains(alias)
                    && ["private" + alias, "/private" + alias].contains(destination)
                if !systemAlias { throw EventError.invalid("Refusing symlink: \(alias)") }
            }
            path.deleteLastPathComponent()
        }
    }
    public static func prepareDirectory(_ url: URL) throws {
        try check(url)
        let exists = FileManager.default.fileExists(atPath: url.path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        if !exists { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) }
    }
    public static func write(_ data: Data, to url: URL) throws {
        try check(url)
        try prepareDirectory(url.deletingLastPathComponent())
        let previousPermissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".splash-finish-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                            attributes: [.posixPermissions: previousPermissions ?? NSNumber(value: 0o600)]) else {
            throw EventError.invalid("Cannot write \(url.path)")
        }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

public final class FileLock {
    private let descriptor: Int32
    public init(url: URL, nonblocking: Bool = false) throws {
        try SafeFiles.prepareDirectory(url.deletingLastPathComponent())
        try SafeFiles.check(url)
        descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw EventError.invalid("Cannot open lock \(url.path)") }
        guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            close(descriptor); throw EventError.invalid("Splash Finish is already running or another installation is in progress")
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
