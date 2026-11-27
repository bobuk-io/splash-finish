// Trusting the app's cask after Homebrew refused to load it from an untrusted tap. Run only when the
// person asks for it in the update window: trust is their decision, never the app's.
import BobukCore
import Foundation

public enum HomebrewTrust {
    public struct Result: Equatable, Sendable {
        public var exitCode: Int32
        public var output: String
        public var succeeded: Bool { exitCode == 0 }

        public init(exitCode: Int32, output: String) {
            self.exitCode = exitCode
            self.output = output
        }
    }

    /// Runs `brew trust --cask <tap>` with the `brew` of the prefix that installed the app, without
    /// a terminal (a prompt fails instead of waiting), and returns its exit code and output.
    public static func run(_ install: HomebrewInstall,
                           environment: [String: String] = ProcessInfo.processInfo.environment) async -> Result {
        let brew = install.brew
        let arguments = HomebrewUpdate.trustArguments(for: install.cask)
        let environment = HomebrewUpdate.environment(environment, prefix: install.prefix)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = brew
                process.arguments = arguments
                process.environment = environment
                let pipe = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(exitCode: -1, output: "Could not run \(brew.path): \(error.localizedDescription)"))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Result(exitCode: process.terminationStatus,
                                                      output: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
