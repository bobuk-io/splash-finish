import XCTest
@testable import SplashFinishCore

final class InboxTests: XCTestCase {
    func event(_ task: String = "one", status: EventStatus = .done, title: String = "Done") -> AgentEvent {
        AgentEvent(task: task, agent: "Codex", status: status, title: title)
    }
    func testReceiveAndDismissOne() throws {
        var inbox = Inbox()
        try inbox.receive(event("one")); try inbox.receive(event("two")); try inbox.receive(event("three", status: .attention))
        inbox.dismiss(key: "codex:two")
        XCTAssertEqual(inbox.items.map(\.task), ["one", "three"])
        XCTAssertEqual(inbox.attention.count, 1); XCTAssertEqual(inbox.completed.count, 1)
        inbox.dismiss(key: "absent"); XCTAssertEqual(inbox.items.count, 2)
        inbox.clear(); XCTAssertTrue(inbox.items.isEmpty)
    }
    func testSameTaskUpdatesInsteadOfDuplicating() throws {
        var inbox = Inbox()
        try inbox.receive(event(status: .attention))
        try inbox.receive(event(title: "Finished"))
        XCTAssertEqual(inbox.items.count, 1); XCTAssertEqual(inbox.completed.count, 1)
        XCTAssertEqual(inbox.items.first?.title, "Finished")
        try inbox.receive(event(status: .running)); XCTAssertTrue(inbox.items.isEmpty)
    }
    func testSnoozeDeadlineAndEarlyWake() throws {
        let now = Date(timeIntervalSince1970: 1000)
        var inbox = Inbox(); let first = event()
        try inbox.receive(first); inbox.snooze(now: now)
        XCTAssertEqual(inbox.snoozedUntil, now.addingTimeInterval(900))
        XCTAssertFalse(inbox.wakeIfDue(now: now.addingTimeInterval(899)))
        XCTAssertFalse(try inbox.receive(first)); XCTAssertNotNil(inbox.snoozedUntil)
        XCTAssertFalse(try inbox.receive(event())); XCTAssertNotNil(inbox.snoozedUntil, "Identical updates must not wake snooze")
        XCTAssertTrue(try inbox.receive(event("two"))); XCTAssertNil(inbox.snoozedUntil)
        inbox.snooze(now: now); XCTAssertTrue(inbox.wakeIfDue(now: now.addingTimeInterval(900)))
        XCTAssertNil(inbox.snoozedUntil)
    }
    func testResumeDoesNotWakeAndFinalDismissCancelsSnooze() throws {
        var inbox = Inbox(); try inbox.receive(event()); try inbox.receive(event("two"))
        inbox.snooze()
        XCTAssertFalse(try inbox.receive(event(status: .running)))
        XCTAssertNotNil(inbox.snoozedUntil)
        inbox.dismiss(key: "codex:two"); XCTAssertNil(inbox.snoozedUntil)
        XCTAssertFalse(inbox.wakeIfDue(now: .distantFuture))
    }
    func testOrderedRunsRejectLateEventsEvenAfterDismissOrRestart() throws {
        var inbox = Inbox()
        func ordered(_ run: Int64, _ sequence: Int64, _ status: EventStatus) -> AgentEvent {
            AgentEvent(task: "session", agent: "pi", status: status, title: "update", run: run, sequence: sequence)
        }
        XCTAssertTrue(try inbox.receive(ordered(10, 2, .done)))
        XCTAssertFalse(try inbox.receive(ordered(10, 1, .running)))
        XCTAssertEqual(inbox.items.first?.status, .done)
        XCTAssertFalse(try inbox.receive(AgentEvent(task: "session", agent: "pi", status: .running, title: "late legacy")))
        inbox.dismiss(key: "pi:session")
        inbox = try JSONDecoder().decode(Inbox.self, from: JSONEncoder().encode(inbox))
        XCTAssertFalse(try inbox.receive(ordered(10, 1, .attention)))
        XCTAssertTrue(inbox.items.isEmpty)
        XCTAssertTrue(try inbox.receive(ordered(11, 1, .attention)))
        XCTAssertFalse(try inbox.receive(ordered(10, 100, .done)))
        XCTAssertEqual(inbox.items.first?.status, .attention)
        inbox.clear()
        XCTAssertFalse(try inbox.receive(ordered(11, 1, .attention)))
        XCTAssertTrue(try inbox.receive(ordered(12, 1, .done)))
    }
    func testLateToolProgressCannotEraseCompletedHook() throws {
        var inbox = Inbox()
        try inbox.receive(AgentEvent(task: "s", agent: "Codex", status: .done, title: "Done"))
        try inbox.receive(AgentEvent(task: "s", agent: "Codex", status: .running, title: "Working", phase: "progress"))
        XCTAssertEqual(inbox.items.first?.status, .done)
        try inbox.receive(AgentEvent(task: "s", agent: "Codex", status: .running, title: "Working"))
        XCTAssertTrue(inbox.items.isEmpty)
    }
    func testAgentKeysAreNormalized() throws {
        var inbox = Inbox()
        try inbox.receive(AgentEvent(task: "s", agent: "Claude Code", status: .done, title: "x"))
        XCTAssertEqual(inbox.lastEvents?.keys.sorted(), ["claudecode"])
        XCTAssertEqual(Inbox.agentKey(" Claude  Code "), "claudecode")
    }
    func testQuestionPlaceholdersAndSelectiveClear() throws {
        var inbox = Inbox()
        let question = AgentEvent(task: QuestionTask.prefix + "abc", agent: "pi", status: .attention, title: "Question")
        try inbox.receive(question)
        try inbox.receive(AgentEvent(task: "keep", agent: "pi", status: .attention, title: "Ordinary"))
        inbox.dismissAll(except: [question.key])
        XCTAssertEqual(inbox.items.map(\.task), [question.task])
        inbox.discardQuestionPlaceholders()
        XCTAssertTrue(inbox.items.isEmpty)
        XCTAssertNil(inbox.snoozedUntil)
        XCTAssertEqual(QuestionTask.id(fromTask: "question-abc"), "abc")
        XCTAssertNil(QuestionTask.id(fromTask: "other"))
    }
    func testSnoozeDurationAndMorningDeadline() throws {
        var inbox = Inbox()
        try inbox.receive(event())
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        inbox.snooze(now: now, duration: 3600)
        XCTAssertEqual(inbox.snoozedUntil, now.addingTimeInterval(3600))
        let morning = Snooze.untilTomorrowMorning(now: now)
        XCTAssertGreaterThanOrEqual(morning, 60)
        inbox.snooze(now: now, duration: morning)
        XCTAssertEqual(inbox.snoozedUntil, now.addingTimeInterval(morning))
    }
    func testLegacyInboxDecodesWithoutOrderingMetadata() throws {
        let old = Data(#"{"items":[],"seenEventIDs":[]}"#.utf8)
        let inbox = try JSONDecoder().decode(Inbox.self, from: old)
        XCTAssertNil(inbox.latestOrders); XCTAssertNil(inbox.lastEvents)
    }
    func testQueueAndReplayHistoryAreBounded() throws {
        var inbox = Inbox()
        for i in 0..<600 { try inbox.receive(event(String(i))) }
        XCTAssertEqual(inbox.items.count, 200); XCTAssertEqual(inbox.seenEventIDs.count, 512)
    }
}

final class EventTests: XCTestCase {
    func testDeepLinkRoundTripAndEscaping() throws {
        let event = AgentEvent(task: "session & ? café", agent: "Claude Code", status: .attention,
                               title: "Apply 'migration' & test?", detail: "100% ready + review",
                               project: "日本語", source: EventSource(pid: 123, bundleID: "com.apple.Terminal", url: "vscode://file/tmp/work", weztermPane: 34), run: 1234, sequence: 9)
        let result = try DeepLink.parse(DeepLink.eventURL(event))
        XCTAssertEqual(result.id, event.id); XCTAssertEqual(result.key, event.key)
        XCTAssertEqual(result.title, event.title); XCTAssertEqual(result.detail, event.detail)
        XCTAssertEqual(result.project, event.project); XCTAssertEqual(result.source, event.source)
        XCTAssertEqual(result.run, 1234); XCTAssertEqual(result.sequence, 9)
    }
    func testRejectBadURLs() {
        for raw in ["https://event?agent=a&task=t&status=done", "splash-finish://event?agent=a&task=t&status=nope",
                    "splash-finish://event?agent=a&agent=b&task=t&status=done", "splash-finish://event?agent=a&status=done",
                    "splash-finish://event?agent=a&task=t&status=done&source-url=file:///tmp/script.sh"] {
            XCTAssertThrowsError(try DeepLink.parse(URL(string: raw)!))
        }
    }
    func testTruncationAndControlCharacters() throws {
        let event = try AgentEvent(task: "task", agent: "Codex", status: .done,
                                   title: "hello\u{1B}\nworld\t" + String(repeating: "x", count: 5000)).validated()
        XCTAssertEqual(event.title.utf8.count, MessageText.maximumBytes)
        XCTAssertTrue(event.title.hasPrefix("hello world "))
        XCTAssertEqual(MessageText.plain(event.title, limit: 160).count, 161)
    }
    func testHookMapping() throws {
        func parse(_ event: String, extra: [String: Any] = [:], agent: String = "codex") throws -> AgentEvent? {
            var object: [String: Any] = ["session_id": "abc", "hook_event_name": event, "cwd": "/code/backend"]
            object.merge(extra) { _, new in new }
            return try HookEvent.parse(agent: agent, input: JSONSerialization.data(withJSONObject: object))
        }
        XCTAssertEqual(try parse("Stop", extra: ["last_assistant_message": "Fixed authentication"])?.title, "Fixed authentication")
        XCTAssertEqual(try parse("Stop")?.status, .done)
        XCTAssertEqual(try parse("PermissionRequest", extra: ["tool_name": "Bash"])?.status, .attention)
        XCTAssertEqual(try parse("PermissionRequest")?.project, "backend")
        XCTAssertEqual(try parse("UserPromptSubmit")?.status, .running)
        XCTAssertEqual(try parse("PostToolUse")?.status, .running)
        XCTAssertEqual(try parse("Interrupt")?.status, .running)
        XCTAssertNil(try parse("Notification", extra: ["notification_type": "auth_success"], agent: "claude"))
        XCTAssertEqual(try parse("Notification", extra: ["notification_type": "permission_prompt"], agent: "claude")?.status, .attention)
        XCTAssertNil(try parse("Unrelated"))
    }
}

final class FilesAndInstallerTests: XCTestCase {
    var home: URL!
    var resources: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("splash-finish-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        resources = project.appendingPathComponent("Sources/SplashFinish/Resources/Integrations")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }
    var installer: IntegrationInstaller { IntegrationInstaller(home: home, environment: [:], executable: "/Applications/Splash Finish.app/Contents/MacOS/SplashFinish", resources: resources) }
    func testStatePersistenceAndPermissions() throws {
        var inbox = Inbox(); try inbox.receive(AgentEvent(task: "one", agent: "pi", status: .done, title: "Done")); inbox.snooze()
        let file = StateFile(url: home.appendingPathComponent("state.json"))
        try file.save(inbox); XCTAssertEqual(try file.load(), inbox)
        let mode = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }
    func testInstallIsIdempotentAndUninstallPreservesOtherSettings() throws {
        let url = home.appendingPathComponent(".claude/settings.json")
        let original: [String: Any] = ["model": "keep-me", "hooks": ["Stop": [["matcher": "", "hooks": [["type": "command", "command": "echo existing"]]]]]]
        try SafeFiles.write(JSONSerialization.data(withJSONObject: original), to: url)
        _ = try installer.run(install: true, agents: AgentKind.allCases)
        let first = try Data(contentsOf: url)
        _ = try installer.run(install: true, agents: AgentKind.allCases)
        XCTAssertEqual(first, try Data(contentsOf: url))
        let extensionURL = home.appendingPathComponent(".pi/agent/extensions/splash-finish.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extensionURL.path))
        XCTAssertFalse(try String(contentsOf: extensionURL).contains("__EXECUTABLE_JSON__"))
        let current = try JSONSerialization.jsonObject(with: first) as! [String: Any]
        XCTAssertEqual(current["model"] as? String, "keep-me")
        _ = try installer.run(install: false, agents: AgentKind.allCases)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! NSDictionary
        XCTAssertTrue(restored.isEqual(to: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extensionURL.path))
        _ = try installer.run(install: false, agents: AgentKind.allCases)
    }
    func testPiAgentAskDetectionAndRecommendations() throws {
        XCTAssertFalse(installer.piAgentAskDetected())
        let settings = home.appendingPathComponent(".pi/agent/settings.json")
        let package = home.appendingPathComponent(".pi/agent/npm/node_modules/pi-agent-ask/package.json")
        try SafeFiles.write(Data("{\"packages\":[\"npm:pi-agent-ask\"]}".utf8), to: settings)
        XCTAssertFalse(installer.piAgentAskDetected(), "A configured but missing package is not installed")
        try SafeFiles.write(Data("{\"name\":\"pi-agent-ask\",\"version\":\"2.0.2\"}".utf8), to: package)
        XCTAssertTrue(installer.piAgentAskDetected())
        XCTAssertTrue(installer.inspect(inbox: Inbox()).last!.piAskDetected)
        XCTAssertTrue(try installer.run(install: true, agents: [.pi]).joined().contains("rich questions enabled"))
        XCTAssertTrue(installer.inspect(inbox: Inbox()).last!.richQuestionsEnabled)
        try SafeFiles.write(Data("{\"packages\":[{\"source\":\"npm:pi-agent-ask\",\"extensions\":[]}]}".utf8), to: settings)
        XCTAssertFalse(installer.piAgentAskDetected(), "A disabled extension must not be offered as available")
        XCTAssertTrue(try installer.run(install: true, agents: [.pi]).joined().contains("pi install npm:pi-agent-ask"))
    }
    func testRichPiCanBeEnabledPreservedAndDisabled() throws {
        let file = home.appendingPathComponent(".pi/agent/extensions/splash-finish-questions.ts")
        _ = try installer.run(install: true, agents: [.pi])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        _ = try installer.run(install: true, agents: [.pi], richQuestions: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("__EXECUTABLE_JSON__"))
        XCTAssertEqual(installer.inspect(inbox: Inbox()).last?.richQuestionsEnabled, true)
        _ = try installer.run(install: true, agents: [.pi])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "CLI reinstall preserves a project-local opt-in")
        _ = try installer.run(install: true, agents: [.pi], richQuestions: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(installer.inspect(inbox: Inbox()).last?.richQuestionsEnabled, false)
        _ = try installer.run(install: true, agents: [.pi], richQuestions: true)
        _ = try installer.run(install: false, agents: [.pi])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testRichPiFileOwnershipIsProtected() throws {
        let file = home.appendingPathComponent(".pi/agent/extensions/splash-finish-questions.ts")
        try SafeFiles.write(Data("user-owned extension".utf8), to: file)
        XCTAssertThrowsError(try installer.run(install: true, agents: [.pi]))
        XCTAssertThrowsError(try installer.run(install: false, agents: [.pi]))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user-owned extension")
    }
    func testDoctorDetectsInstallOutdatedAndLastEvent() throws {
        var inbox = Inbox()
        XCTAssertEqual(installer.inspect(inbox: inbox).map(\.state), [.notInstalled, .notInstalled, .notInstalled])
        _ = try installer.run(install: true, agents: [.pi])
        try inbox.receive(AgentEvent(task: "s", agent: "pi", status: .done, title: "done"))
        let installed = installer.inspect(inbox: inbox).last!
        XCTAssertEqual(installed.state, .installed); XCTAssertNotNil(installed.lastEvent)
        // Display-name variants of an agent map to the same last-event record.
        try inbox.receive(AgentEvent(task: "c", agent: "Claude Code", status: .done, title: "done"))
        XCTAssertNotNil(installer.inspect(inbox: inbox).first { $0.agent == .claude }?.lastEvent)
        let skill = home.appendingPathComponent(".pi/agent/skills/splash-finish/SKILL.md")
        try Data("<!-- Managed by Splash Finish --> old".utf8).write(to: skill)
        XCTAssertEqual(installer.inspect(inbox: inbox).last?.state, .updateAvailable)
    }
    func testBackupRotationKeepsNewestThree() throws {
        let url = home.appendingPathComponent(".codex/hooks.json")
        _ = try installer.run(install: true, agents: [.codex])
        for _ in 0..<5 {
            var config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var hooks = config["hooks"] as! [String: Any]
            hooks.removeValue(forKey: "SessionEnd") // A required event; patch re-adds it and must back up first.
            config["hooks"] = hooks
            try SafeFiles.write(JSONSerialization.data(withJSONObject: config), to: url)
            _ = try installer.run(install: true, agents: [.codex])
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".codex").path)
            .filter { $0.hasPrefix("hooks.json.splash-finish-backup-") }
        XCTAssertEqual(backups.count, 3)
    }
    func testFocusStatusReadsAssertionsDatabase() throws {
        let database = home.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        try SafeFiles.write(Data(#"{"data":[{}]}"#.utf8), to: database)
        XCTAssertFalse(FocusStatus.isDoNotDisturbActive(home: home))
        try SafeFiles.write(Data(#"{"data":[{"storeAssertionRecords":[{"assertionDetails":{}}]}]}"#.utf8), to: database)
        XCTAssertTrue(FocusStatus.isDoNotDisturbActive(home: home))
        try FileManager.default.removeItem(at: database)
        XCTAssertFalse(FocusStatus.isDoNotDisturbActive(home: home))
    }
    func testInvalidConfigPreflightDoesNotWriteOtherFiles() throws {
        let url = home.appendingPathComponent(".codex/hooks.json")
        let bad = Data("{\"hooks\":{\"Stop\":\"invalid\"}}".utf8)
        try SafeFiles.write(bad, to: url)
        XCTAssertThrowsError(try installer.run(install: true, agents: AgentKind.allCases))
        XCTAssertEqual(try Data(contentsOf: url), bad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }
    func testUnmanagedFileAndSymlinkRefused() throws {
        let skill = home.appendingPathComponent(".pi/agent/skills/splash-finish/SKILL.md")
        try SafeFiles.write(Data("My own skill".utf8), to: skill)
        XCTAssertThrowsError(try installer.run(install: true, agents: [.pi]))
        XCTAssertEqual(try String(contentsOf: skill), "My own skill")
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("absent"))
        XCTAssertThrowsError(try SafeFiles.write(Data(), to: link))
        XCTAssertThrowsError(try SafeFiles.write(Data(), to: link.appendingPathComponent("child.json")))
    }
    func testMixedGroupsKeepUnrelatedHandlers() throws {
        let url = home.appendingPathComponent(".codex/hooks.json")
        let original: [String: Any] = ["description": "keep", "hooks": ["Stop": [["custom": "metadata", "hooks": [
            ["type": "command", "command": "'old' hook codex --managed-splash-finish"],
            ["type": "command", "command": "echo user-hook"]]]]]]
        try SafeFiles.write(JSONSerialization.data(withJSONObject: original), to: url)
        _ = try installer.run(install: false, agents: [.codex])
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hooks = result["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(hooks["Stop"]?.first?["custom"] as? String, "metadata")
        XCTAssertEqual((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(result["description"] as? String, "keep")
    }
}
