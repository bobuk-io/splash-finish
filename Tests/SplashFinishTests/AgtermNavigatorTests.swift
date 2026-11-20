import XCTest
import Darwin
import SplashFinishCore
@testable import SplashFinish

@MainActor final class AgtermNavigatorTests: XCTestCase {
    private let session = "11111111-1111-4111-8111-111111111111"
    private let window = "22222222-2222-4222-8222-222222222222"
    private let otherWindow = "33333333-3333-4333-8333-333333333333"
    private let pane = "44444444-4444-4444-8444-aabbccddeeff"
    private let otherPane = "55555555-5555-4555-8555-555555555555"
    private let otherSession = "66666666-6666-4666-8666-666666666666"
    private let socketPath = "/tmp/splash-finish-agterm-test.sock"
    private let cli = URL(fileURLWithPath: "/not-installed/agterm.app/Contents/MacOS/agtermctl")

    private struct Step {
        let command: [String]
        let data: Data?
        let error: String?
        init(_ command: [String], _ data: Data?, error: String? = nil) {
            self.command = command; self.data = data; self.error = error
        }
    }
    private struct Outcome {
        let success: Bool?
        let error: String?
        let commands: [[String]]
        let activations: Int
        let completions: Int
    }

    private func reply(_ result: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["ok": true, "result": result], options: [.sortedKeys])
    }
    private var ack: Data { reply([:]) }
    private var source: AgtermSource { AgtermSource(session: session, window: window, pane: pane, socket: socketPath) }
    private func windows(_ ids: [String]? = nil, active: String? = nil,
                         closed: Set<String> = [], remote: Set<String> = []) -> Data {
        reply(["windows": (ids ?? [window]).map { id -> [String: Any] in
            var entry: [String: Any] = ["id": id, "open": !closed.contains(id), "active": id == active]
            if remote.contains(id) { entry["remote"] = ["host": "test.invalid"] }
            return entry
        }])
    }
    private func surface(_ kind: String = "left", token: String? = nil,
                         active: Bool = true, visible: Bool = true, remote: Bool = false) -> [String: Any] {
        ["id": "surface:\(session):\(kind)", "kind": kind, "paneID": token ?? pane,
         "active": active, "visible": visible, "remote": remote]
    }
    private func tree(_ surfaces: [[String: Any]]? = nil, id: String? = nil, active: Bool = true,
                      split: Bool = false, scratch: Bool = false, overlay: Bool = false,
                      flags: [String: Any] = [:], extraSessions: [[String: Any]] = []) -> Data {
        var value = flags
        value["workspaces"] = [["sessions": [["id": id ?? session, "active": active,
            "split": split, "scratch": scratch, "overlay": overlay,
            "surfaces": surfaces ?? [surface()]]] + extraSessions]]
        return reply(["tree": value])
    }
    private func sessionCommand(_ words: [String], window destination: String? = nil) -> [String] {
        words + ["--target", session, "--window", destination ?? window]
    }
    private func readTree(_ destination: String? = nil) -> [String] { ["tree", "--window", destination ?? window] }

    private func steps(initial: Data? = nil, selected: Data? = nil, confirmed: Data? = nil,
                       paneCommands: [Step] = [], paneLess: Bool = false,
                       destination: String? = nil, listedWindows: [String]? = nil) -> [Step] {
        let target = destination ?? window
        let listing = windows(listedWindows ?? [target])
        var result = [Step(["window", "list"], listing), Step(readTree(target), initial ?? tree()),
            Step(["window", "list"], listing), Step(sessionCommand(["session", "select"], window: target), ack)]
        if !paneLess { result.append(Step(readTree(target), selected ?? initial ?? tree())) }
        result += paneCommands
        result += [Step(["window", "list"], listing), Step(["window", "select", target], ack),
            Step(["window", "list"], windows(listedWindows ?? [target], active: target)),
            Step(readTree(target), confirmed ?? tree())]
        return result
    }

    private func navigate(_ plan: [Step], source suppliedSource: AgtermSource? = nil,
                          activation: Bool = true, trusted: @escaping (String) -> Bool = { _ in true },
                          expectAll: Bool = true, file: StaticString = #filePath, line: UInt = #line) -> Outcome {
        var commands = [[String]](), success: Bool?, error: String?, activations = 0, completions = 0
        AgtermNavigator.navigate(suppliedSource ?? source, executable: cli,
            activate: { activations += 1; return activation }, run: { executable, arguments, done in
                XCTAssertEqual(executable, self.cli, file: file, line: line)
                let index = commands.count
                commands.append(arguments)
                guard index < plan.count else {
                    XCTFail("Unexpected extra CLI command: \(arguments)", file: file, line: line)
                    done(nil, "Unexpected command"); return
                }
                XCTAssertEqual(arguments, plan[index].command + ["--socket", self.socketPath, "--json"], file: file, line: line)
                done(plan[index].data, plan[index].error)
            }, socketIsTrusted: trusted, completion: { ok, detail in
                completions += 1; success = ok; error = detail
            })
        XCTAssertEqual(completions, 1, "Every navigation must complete exactly once", file: file, line: line)
        XCTAssertEqual(error == nil, success == true, file: file, line: line)
        if expectAll { XCTAssertEqual(commands.count, plan.count, file: file, line: line) }
        return Outcome(success: success, error: error, commands: commands, activations: activations, completions: completions)
    }

    func testExactSessionPaneWindowAndCapturedSocketAreConfirmed() {
        let result = navigate(steps())
        XCTAssertEqual(result.success, true)
        XCTAssertEqual(result.activations, 1)
        XCTAssertFalse(result.commands.flatMap { $0 }.contains("active"))
        XCTAssertFalse(result.commands.flatMap { $0 }.contains("--command"))
    }

    func testStableTokenResolvesSwappedRightPaneAndRevealsHiddenSplit() {
        let hidden = tree([surface(token: otherPane), surface("right", active: false, visible: false)])
        let visible = tree([surface(token: otherPane, active: false), surface("right")], split: true)
        let plan = steps(initial: hidden, confirmed: visible,
                         paneCommands: [Step(sessionCommand(["session", "focus", "right"]), ack)])
        XCTAssertEqual(navigate(plan).success, true)
    }

    func testStablePaneUUIDMatchingIsCaseInsensitive() {
        let uppercase = AgtermSource(session: session, window: window, pane: pane.uppercased(), socket: socketPath)
        XCTAssertEqual(navigate(steps(), source: uppercase).success, true)
    }

    func testTokenPromotedToPrimaryDoesNotRequireAnExistingSplit() {
        let promoted = tree([surface()])
        let result = navigate(steps(initial: promoted, confirmed: promoted))
        XCTAssertEqual(result.success, true)
        XCTAssertFalse(result.commands.contains { $0.starts(with: ["session", "focus"]) })
    }

    func testTokenRoleIsResolvedAgainAfterSelection() {
        let original = tree([surface("right", active: false), surface(token: otherPane)], split: true)
        let swapped = tree([surface(), surface("right", token: otherPane, active: false)], split: true)
        let plan = steps(initial: original, selected: swapped, confirmed: swapped,
                         paneCommands: [Step(sessionCommand(["session", "focus", "left"]), ack)])
        XCTAssertEqual(navigate(plan).success, true)
    }

    func testMovedSessionIsFoundOnlyByExactUUIDInAnotherOpenLocalWindow() {
        var plan = steps(destination: otherWindow, listedWindows: [otherWindow, window])
        plan[0] = Step(["window", "list"], windows([otherWindow, window]))
        plan.insert(Step(readTree(), tree(id: otherSession)), at: 1)
        let result = navigate(plan)
        XCTAssertEqual(result.success, true)
        XCTAssertEqual(Array(result.commands[1].prefix(3)), readTree(), "The original window is searched first")
        XCTAssertTrue(result.commands.contains { $0.starts(with: ["window", "select", otherWindow]) })
    }

    func testClosedOriginalWindowDoesNotGetReopenedWhenSessionMoved() {
        var plan = steps(destination: otherWindow)
        plan[0] = Step(["window", "list"], windows([window, otherWindow], closed: [window]))
        XCTAssertEqual(navigate(plan).success, true)
    }

    func testMissingPaneFailsBeforeAnyMutationEvenIfAnotherSessionHasToken() {
        let wrong = tree([surface(token: otherPane)], extraSessions: [
            ["id": otherSession, "active": false, "split": false, "scratch": false, "overlay": false,
             "surfaces": [surface()]]])
        let result = navigate([Step(["window", "list"], windows()), Step(readTree(), wrong)])
        XCTAssertEqual(result.success, false)
        XCTAssertEqual(result.activations, 0)
    }

    func testMissingClosedAndRemoteWindowsFailBeforeMutation() {
        for listing in [windows([]), windows(closed: [window]), windows(remote: [window])] {
            let result = navigate([Step(["window", "list"], listing)])
            XCTAssertEqual(result.success, false)
            XCTAssertEqual(result.activations, 0)
        }
        let missing = navigate([Step(["window", "list"], windows()), Step(readTree(), tree(id: otherSession))])
        XCTAssertEqual(missing.success, false)
    }

    func testRemoteWindowIsNeverSearchedForMovedSession() {
        let plan = [Step(["window", "list"], windows([otherWindow, window], remote: [otherWindow])),
                    Step(readTree(), tree(id: otherSession))]
        XCTAssertEqual(navigate(plan).success, false)
    }

    func testRemotePaneAndAmbiguousExactSessionAreRejectedBeforeMutation() {
        let remote = tree([surface(remote: true)])
        let duplicate = tree(extraSessions: [["id": session, "active": false, "split": false,
            "scratch": false, "overlay": false, "surfaces": [surface()]]])
        for invalid in [remote, duplicate] {
            let result = navigate([Step(["window", "list"], windows()), Step(readTree(), invalid)])
            XCTAssertEqual(result.success, false)
        }
    }

    func testExistingScratchIsHiddenBeforeFocusingOriginalSplitPane() {
        let covered = tree([surface(token: otherPane, active: false, visible: false),
            surface("right", active: false, visible: false), surface("scratch", token: otherPane)],
            split: true, scratch: true)
        let uncovered = tree([surface(token: otherPane), surface("right", active: false)], split: true)
        let confirmed = tree([surface(token: otherPane, active: false), surface("right")], split: true)
        let commands = [Step(sessionCommand(["session", "scratch", "off"]), ack),
            Step(readTree(), uncovered), Step(sessionCommand(["session", "focus", "right"]), ack)]
        XCTAssertEqual(navigate(steps(initial: covered, confirmed: confirmed, paneCommands: commands)).success, true)
    }

    func testHiddenScratchIsShownOnlyWithTheSameLiveToken() {
        let hidden = tree([surface(token: otherPane), surface("scratch", active: false, visible: false)])
        let shown = tree([surface(token: otherPane, active: false, visible: false), surface("scratch")], scratch: true)
        let command = Step(sessionCommand(["session", "scratch", "on"]), ack)
        XCTAssertEqual(navigate(steps(initial: hidden, confirmed: shown, paneCommands: [command])).success, true)
    }

    func testScratchTokenDisappearingAfterSelectionNeverCreatesAReplacement() {
        let hidden = tree([surface(token: otherPane), surface("scratch", active: false, visible: false)])
        let disappeared = tree([surface(token: otherPane)])
        let full = steps(initial: hidden, selected: disappeared)
        let result = navigate(Array(full.prefix(5)))
        XCTAssertEqual(result.success, false)
        XCTAssertFalse(result.commands.contains { $0.starts(with: ["session", "scratch"]) })
    }

    func testPaneLessSourceReturnsOnlyToExactSessionWithoutPaneMutations() {
        let noPane = AgtermSource(session: session, window: window, socket: socketPath)
        let arbitrary = tree([surface(token: otherPane)])
        let result = navigate(steps(initial: arbitrary, confirmed: arbitrary, paneLess: true), source: noPane)
        XCTAssertEqual(result.success, true)
        XCTAssertFalse(result.commands.contains { $0.starts(with: ["session", "focus"]) || $0.starts(with: ["session", "scratch"]) })
    }

    func testPaneLessSourceDoesNotClaimAHiddenSessionIsVisible() {
        let noPane = AgtermSource(session: session, window: window, socket: socketPath)
        let hidden = tree([surface(token: otherPane, active: false, visible: false)])
        XCTAssertEqual(navigate(steps(confirmed: hidden, paneLess: true), source: noPane).success, false)
    }

    func testEveryCLIStageRejectsTransportErrorsMalformedJSONAndNegativeAcknowledgements() {
        let covered = tree([surface(active: false, visible: false), surface("right", token: otherPane, active: false),
                           surface("scratch", token: otherPane)], split: true, scratch: true)
        let uncovered = tree([surface(), surface("right", token: otherPane, active: false)], split: true)
        let plan = steps(initial: covered, confirmed: uncovered, paneCommands: [
            Step(sessionCommand(["session", "scratch", "off"]), ack), Step(readTree(), uncovered),
            Step(sessionCommand(["session", "focus", "left"]), ack)])
        for index in plan.indices {
            for failure in [Step(plan[index].command, nil, error: "Connection refused"),
                            Step(plan[index].command, Data("not JSON".utf8)),
                            Step(plan[index].command, Data("{\"ok\":false,\"error\":\"refused\"}".utf8)),
                            Step(plan[index].command, Data("{\"ok\":true}".utf8))] {
                var failed = Array(plan.prefix(index + 1)); failed[index] = failure
                let result = navigate(failed)
                XCTAssertEqual(result.success, false, "Stage \(index) must not turn an acknowledgement into success")
                XCTAssertFalse(result.error?.isEmpty ?? true)
            }
        }
    }

    func testReadbackMustConfirmExactActiveVisiblePaneAndSession() {
        let mismatches = [tree([surface(active: false)]), tree([surface(visible: false)], overlay: true),
            tree([surface(token: otherPane)]), tree(active: false), tree(id: otherSession),
            tree(flags: ["zoomedSurface": "surface:\(otherSession):left"]),
            tree(flags: ["pickPending": "picker"]), tree(flags: ["askPending": "question"]),
            tree(flags: ["quickVisible": true]), tree(flags: ["dashboardMembers": ["\(session):left"]])]
        for mismatch in mismatches {
            XCTAssertEqual(navigate(steps(confirmed: mismatch)).success, false)
        }
        XCTAssertEqual(navigate(steps(confirmed: tree(flags: ["zoomedSurface": "surface:\(session):left"]))).success, true)
    }

    func testReadbackRejectsWrongInactiveClosedOrRemoteWindow() {
        let plan = steps()
        for listing in [windows(active: otherWindow), windows([window, otherWindow], active: otherWindow),
                        windows(active: window, closed: [window]), windows(active: window, remote: [window])] {
            var failed = Array(plan.dropLast()); failed[failed.count - 1] = Step(["window", "list"], listing)
            XCTAssertEqual(navigate(failed).success, false)
        }
    }

    func testWindowIsRecheckedBeforeRaisingSoClosedWindowIsNotReopened() {
        let plan = steps()
        var failed = Array(plan.prefix(6)); failed[5] = Step(["window", "list"], windows(closed: [window]))
        let result = navigate(failed)
        XCTAssertEqual(result.success, false)
        XCTAssertEqual(result.activations, 0)
        XCTAssertFalse(result.commands.contains { $0.starts(with: ["window", "select"]) })
    }

    func testActivationFailureNeverReportsSuccessAndDoesNotReadBack() {
        let result = navigate(Array(steps().dropLast(2)), activation: false)
        XCTAssertEqual(result.success, false)
        XCTAssertEqual(result.activations, 1)
    }

    func testSourceAndSocketTrustAreCheckedBeforeEveryProcessInvocation() {
        let invalid = AgtermSource(session: "not-a-uuid", window: window, pane: pane, socket: socketPath)
        XCTAssertEqual(navigate([], source: invalid).success, false)
        XCTAssertEqual(navigate([], trusted: { _ in false }).success, false)
        var calls = 0
        let plan = Array(steps().prefix(1))
        let result = navigate(plan, trusted: { path in
            XCTAssertEqual(path, self.socketPath)
            calls += 1
            return calls == 1
        })
        XCTAssertEqual(result.success, false)
        XCTAssertEqual(calls, 2)
    }

    func testSocketTrustAcceptsOnlyCurrentUserUnixSocketAndRejectsSymlink() throws {
        let directory = URL(fileURLWithPath: "/tmp/sf-agterm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("socket").path
        XCTAssertFalse(AgtermNavigator.trustedSocket(path))
        let regular = directory.appendingPathComponent("regular")
        try Data().write(to: regular)
        XCTAssertFalse(AgtermNavigator.trustedSocket(regular.path))
        XCTAssertFalse(AgtermNavigator.trustedSocket(directory.path))
        XCTAssertFalse(AgtermNavigator.trustedSocket("relative.sock"))
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        XCTAssertLessThanOrEqual(bytes.count, MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertTrue(AgtermNavigator.trustedSocket(path))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: path)
        XCTAssertFalse(AgtermNavigator.trustedSocket(link.path))
    }

    func testExecutableDiscoveryUsesOnlyBundledFixedCLIPathAndCorrectBundleIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sf-agterm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, bundleID) in [("agterm", AgtermSource.bundleID), ("other", "invalid.example.terminal")] {
            let app = root.appendingPathComponent(name + ".app")
            let executable = app.appendingPathComponent("Contents/MacOS/agtermctl")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID,
                "CFBundleExecutable": "agtermctl", "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try plist.write(to: app.appendingPathComponent("Contents/Info.plist"))
            try Data("not executable".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
            XCTAssertNil(AgtermNavigator.executable(app: app))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            XCTAssertEqual(AgtermNavigator.executable(app: app), bundleID == AgtermSource.bundleID ? executable : nil)
        }
    }
}
