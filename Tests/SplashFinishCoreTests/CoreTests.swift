import BobukCore
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
        let now = Date()
        var inbox = Inbox(); let first = event()
        try inbox.receive(first); inbox.snooze(now: now)
        XCTAssertEqual(inbox.snoozedUntil, now.addingTimeInterval(900))
        XCTAssertFalse(inbox.wakeIfDue(now: now.addingTimeInterval(899)))
        XCTAssertFalse(try inbox.receive(first)); XCTAssertNotNil(inbox.snoozedUntil)
        XCTAssertFalse(try inbox.receive(event())); XCTAssertNotNil(inbox.snoozedUntil, "Identical updates must not wake snooze")
        XCTAssertTrue(try inbox.receive(event("two")), "A new event ends short snooze")
        XCTAssertNil(inbox.snoozedUntil)
        inbox.snooze(now: now)
        XCTAssertTrue(inbox.wakeIfDue(now: now.addingTimeInterval(900)))
        XCTAssertNil(inbox.snoozedUntil)
        inbox.snooze(now: now)
        inbox.reveal()
        XCTAssertNil(inbox.snoozedUntil, "An explicit show ends short snooze")
    }
    func testSnoozeKeepsPanelHiddenWhenAnotherTaskArrives() throws {
        let now = Date()
        var inbox = Inbox(); try inbox.receive(event("one"))
        let deadline = now.addingTimeInterval(3600)
        inbox.snooze(until: deadline)
        XCTAssertFalse(try inbox.receive(event("two")))
        XCTAssertEqual(inbox.items.map(\.task), ["one", "two"])
        XCTAssertEqual(inbox.snoozedUntil, deadline)
        XCTAssertFalse(inbox.wakeIfDue(now: deadline.addingTimeInterval(-1)))
        XCTAssertTrue(inbox.wakeIfDue(now: deadline))
    }
    func testSnoozeKeepsPanelHiddenWhenSameTaskChanges() throws {
        let now = Date()
        var inbox = Inbox(); try inbox.receive(event("one"))
        let deadline = now.addingTimeInterval(3600)
        inbox.snooze(until: deadline)
        XCTAssertFalse(try inbox.receive(event("one", title: "New answer")))
        XCTAssertEqual(inbox.items.map(\.title), ["New answer"])
        XCTAssertEqual(inbox.snoozedUntil, deadline)
        XCTAssertFalse(inbox.wakeIfDue(now: deadline.addingTimeInterval(-1)))
        inbox.reveal()
        XCTAssertNil(inbox.snoozedUntil, "An explicit show ends timed snooze")
    }
    func testTimedSnoozeSurvivesEmptyInboxAndStateRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = StateFile(url: root.appendingPathComponent("state.json"))
        let deadline = Date().addingTimeInterval(3600)
        var inbox = Inbox()

        inbox.snooze(until: deadline)
        XCTAssertEqual(inbox.snoozedUntil, deadline, "Timed snooze can start with an empty inbox")
        XCTAssertFalse(try inbox.receive(event()))
        inbox.dismiss(key: "codex:one")
        XCTAssertTrue(inbox.items.isEmpty)
        XCTAssertEqual(inbox.snoozedUntil, deadline, "Dismissing the last card does not end timed snooze")

        try state.save(inbox)
        inbox = try state.load()
        XCTAssertTrue(inbox.items.isEmpty)
        XCTAssertEqual(inbox.snoozedUntil, deadline)
        XCTAssertFalse(try inbox.receive(event("two", status: .attention)))
        XCTAssertEqual(inbox.attention.map(\.task), ["two"])
        XCTAssertEqual(inbox.snoozedUntil, deadline)
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
    func testAsyncQuestionSurvivesProgressUntilUserResponds() throws {
        var inbox = Inbox()
        try inbox.receive(AgentEvent(task: "s", agent: "Codex", status: .attention, title: "Question?", phase: "question"))
        try inbox.receive(AgentEvent(task: "s", agent: "Codex", status: .running, title: "Working", phase: "progress"))
        XCTAssertEqual(inbox.items.first?.title, "Question?")
        try inbox.receive(AgentEvent(task: "s", agent: "Codex", status: .running, title: "Working"))
        XCTAssertTrue(inbox.items.isEmpty)
    }
    func testAgentKeysAreNormalized() throws {
        var inbox = Inbox()
        try inbox.receive(AgentEvent(task: "s", agent: "Claude Code", status: .done, title: "x"))
        XCTAssertEqual(inbox.lastEvents?.keys.sorted(), ["claudecode"])
        XCTAssertEqual(Inbox.agentKey(" Claude  Code "), "claudecode")
    }
    func testPerAgentTimestampsAreBounded() throws {
        var inbox = Inbox()
        for index in 0..<80 {
            try inbox.receive(AgentEvent(task: "s", agent: "agent-\(index)", status: .done, title: "x"))
        }
        XCTAssertEqual(inbox.lastEvents?.count, 64)
        XCTAssertNotNil(inbox.lastEvents?["agent-79"], "The newest agent survives pruning")
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
    func testSnoozeDurationAndMorningDeadline() {
        var inbox = Inbox()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        inbox.snooze(until: now.addingTimeInterval(3600))
        XCTAssertEqual(inbox.snoozedUntil, now.addingTimeInterval(3600))
        let morning = Snooze.untilTomorrowMorning(now: now)
        XCTAssertGreaterThanOrEqual(morning, 60)
        inbox.snooze(until: now.addingTimeInterval(morning))
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
    func testCodexEphemeralHooksAreIgnoredWithoutFilteringAnswerText() throws {
        for name in ["Stop", "PermissionRequest", "UserPromptSubmit", "PostToolUse", "Interrupt", "SessionEnd"] {
            var payload: [String: Any] = [
                "session_id": "background", "hook_event_name": name,
                "transcript_path": "", "last_assistant_message": "Объяснение Сообщений"
            ]
            func parse(_ agent: String = "codex") throws -> AgentEvent? {
                try HookEvent.parse(agent: agent, input: JSONSerialization.data(withJSONObject: payload))
            }
            XCTAssertNil(try parse(), name)
            payload["transcript_path"] = NSNull()
            XCTAssertNil(try parse(), name)
            payload["transcript_path"] = " \n\t"
            XCTAssertNil(try parse(), name)
            payload["transcript_path"] = "/tmp/rollout.jsonl"
            XCTAssertNotNil(try parse(), name)
            payload.removeValue(forKey: "transcript_path")
            XCTAssertNotNil(try parse(), name)
        }
        // JSON can be a valid user-requested result. Do not filter by content.
        let payload: [String: Any] = [
            "session_id": "real", "hook_event_name": "Stop",
            "transcript_path": "/tmp/rollout.jsonl", "last_assistant_message": "{\"suggestions\":[]}"
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertEqual(try HookEvent.parse(agent: "codex", input: data)?.title, "{\"suggestions\":[]}")
        var claude = payload
        claude["transcript_path"] = ""
        XCTAssertNotNil(try HookEvent.parse(agent: "claude", input: JSONSerialization.data(withJSONObject: claude)))
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
        let input: [String: Any] = ["questions": [["title": "Which season?"]]]
        let extra: [String: Any] = ["tool_name": "request_user_input_async", "tool_input": input, "tool_response": "{\"accepted\":true}"]
        let question = try parse("PostToolUse", extra: extra)
        XCTAssertEqual(question?.status, .attention)
        XCTAssertEqual(question?.title, "Which season?")
        XCTAssertEqual(question?.phase, "question")
        XCTAssertNil(try parse("PostToolUse", extra: ["tool_name": "request_user_input_async", "tool_response": "{\"accepted\":false}"]))
        XCTAssertEqual(try parse("Interrupt")?.status, .running)
        XCTAssertNil(try parse("Notification", extra: ["notification_type": "auth_success"], agent: "claude"))
        XCTAssertEqual(try parse("Notification", extra: ["notification_type": "permission_prompt"], agent: "claude")?.status, .attention)
        XCTAssertNil(try parse("Unrelated"))
    }
    func testCopilotHookMappingAndOrdering() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CopilotHooks")
        let source = EventSource(pid: 42)
        let stop = try XCTUnwrap(HookEvent.parse(agent: "copilot", input: Data(contentsOf: fixtures.appendingPathComponent("stop.json")), source: source, event: "Stop"))
        let notification = try XCTUnwrap(HookEvent.parse(agent: "copilot", input: Data(contentsOf: fixtures.appendingPathComponent("notification.json")), event: "notification"))
        XCTAssertEqual(stop.status, .done); XCTAssertEqual(stop.title, "Agent turn ended")
        XCTAssertEqual(stop.detail, "Background work may continue")
        XCTAssertEqual(stop.project, "project"); XCTAssertEqual(stop.source, source)
        XCTAssertEqual(notification.status, .attention); XCTAssertGreaterThan(notification.hookTimestamp!, stop.hookTimestamp!)
        func parse(_ event: String, _ fields: [String: Any]) throws -> AgentEvent? {
            try HookEvent.parse(agent: "copilot", input: JSONSerialization.data(withJSONObject: fields), event: event)
        }
        let base: [String: Any] = ["session_id": "s", "timestamp": 1000]
        for event in ["UserPromptSubmit", "PostToolUse", "SessionEnd"] {
            XCTAssertEqual(try parse(event, base)?.status, .running)
        }
        XCTAssertEqual(try parse("PostToolUse", base)?.phase, "copilot-progress")
        XCTAssertNil(try parse("Stop", ["session_id": "s", "agent_id": "child"]))
        XCTAssertNil(try parse("Stop", ["session_id": "s", "hook_event_name": "SubagentStop"]))
        XCTAssertNil(try parse("unknown", base))
        XCTAssertNil(try parse("Stop", [:]))
        for kind in ["shell_completed", "agent_idle", "other"] {
            XCTAssertNil(try parse("notification", ["sessionId": "s", "notification_type": kind]))
        }
        XCTAssertEqual(try parse("notification", ["sessionId": "s", "notification_type": "elicitation_dialog"])?.status, .attention)
        XCTAssertNil(try HookEvent.parse(agent: "copilot", input: Data(repeating: 32, count: 1_048_577), event: "Stop"))
        var inbox = Inbox()
        try inbox.receive(notification)
        let progress = try XCTUnwrap(parse("PostToolUse", ["session_id": "session-1", "timestamp": notification.hookTimestamp! + 1]))
        try inbox.receive(progress)
        try inbox.receive(notification)
        XCTAssertEqual(inbox.items.first?.status, .attention, "An unrelated tool cannot resolve an approval")
        try inbox.receive(stop)
        XCTAssertEqual(inbox.items.first?.status, .attention, "An older stop must not overwrite attention")
        let freshStop = try XCTUnwrap(parse("Stop", ["session_id": "session-1", "timestamp": notification.hookTimestamp! + 2]))
        try inbox.receive(freshStop)
        try inbox.receive(progress)
        XCTAssertEqual(inbox.items.first?.status, .done)
        try inbox.receive(AgentEvent(task: "session-1", agent: "GitHub Copilot CLI", status: .attention, title: "Manual request"))
        XCTAssertEqual(inbox.items.first?.title, "Manual request", "Explicit skill notifications remain usable after hooks")
        let roundTrip = try DeepLink.parse(DeepLink.eventURL(freshStop))
        XCTAssertEqual(roundTrip.hookTimestamp, freshStop.hookTimestamp)
        try inbox.receive(AgentEvent(task: "other", agent: "GitHub Copilot CLI", status: .done, title: "Other"))
        let end = try XCTUnwrap(HookEvent.parse(agent: "copilot", input: Data(contentsOf: fixtures.appendingPathComponent("session-end.json")), event: "SessionEnd"))
        try inbox.receive(end)
        XCTAssertEqual(inbox.items.map(\.task), ["other"])
        XCTAssertNotNil(inbox.lastEvents?["githubcopilotcli"])
    }
    func testCopilotProgressDoesNotSuppressDelayedAttentionAndTimestampTies() throws {
        func parse(_ event: String, _ fields: [String: Any]) throws -> AgentEvent {
            try XCTUnwrap(HookEvent.parse(agent: "copilot", input: JSONSerialization.data(withJSONObject: fields), event: event))
        }
        let progress = try parse("PostToolUse", ["session_id": "s", "timestamp": 2000, "tool_name": "Read"])
        let attention = try parse("notification", ["sessionId": "s", "timestamp": 1000, "notification_type": "permission_prompt"])
        let stop = try parse("Stop", ["session_id": "s", "timestamp": 2000])
        var inbox = Inbox()
        try inbox.receive(progress)
        try inbox.receive(attention)
        XCTAssertEqual(inbox.items.first?.status, .attention, "A parallel tool must not hide a delayed permission request")
        try inbox.receive(stop)
        XCTAssertEqual(inbox.items.first?.status, .done)
        try inbox.receive(progress)
        XCTAssertEqual(inbox.items.first?.status, .done, "Equal-time progress must not erase a completion")

        var tied = Inbox()
        let prompt = try parse("UserPromptSubmit", ["session_id": "s", "timestamp": 2000])
        try tied.receive(prompt)
        try tied.receive(stop)
        XCTAssertEqual(tied.items.first?.status, .done, "Distinct events at the same millisecond must not be discarded")
        try tied.receive(prompt)
        XCTAssertEqual(tied.items.first?.status, .done, "Replayed IDs remain ignored")
        let nextStop = try parse("Stop", ["session_id": "s", "timestamp": 2001])
        XCTAssertTrue(try tied.receive(nextStop), "A later turn must reveal the inbox even if the earlier stop is still visible")
    }
    func testAgyHookMappingTranscriptPreviewAndLifecycle() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("splash-agy-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let transcript = root.appendingPathComponent("transcript.jsonl")
        let transcriptLines = [
            #"{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"Old prompt"}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","content":"Old turn reply"}"#,
            #"{"step_index":3,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"Current prompt"}"#,
            #"{"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command"}]}"#,
            #"{"step_index":5,"source":"MODEL","type":"PLANNER_RESPONSE","content":"All **tests** passed."}"#
        ].joined(separator: "\n") + "\n"
        try SafeFile.write(Data(transcriptLines.utf8), to: transcript)

        func parse(_ event: String?, _ fields: [String: Any], agent: String = "agy") throws -> AgentEvent? {
            try HookEvent.parse(agent: agent, input: JSONSerialization.data(withJSONObject: fields), event: event)
        }

        let stop = try XCTUnwrap(parse("Stop", [
            "conversationId": "conv-1",
            "hookEventName": "Stop",
            "cwd": "/code/splash",
            "terminationReason": "NO_TOOL_CALL",
            "fullyIdle": true,
            "transcriptPath": transcript.path
        ]))
        XCTAssertEqual(stop.agent, "Antigravity")
        XCTAssertEqual(stop.task, "conv-1")
        XCTAssertEqual(stop.project, "splash")
        XCTAssertEqual(stop.status, .done)
        XCTAssertEqual(stop.title, "All **tests** passed.")
        XCTAssertEqual(stop.detail, "Ready for review")

        // A turn that produced no assistant text must not fall back to an earlier turn's reply.
        let silentTranscript = root.appendingPathComponent("silent.jsonl")
        let silentLines = [
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","content":"Stale reply"}"#,
            #"{"step_index":2,"source":"USER_EXPLICIT","type":"USER_INPUT","content":"New prompt"}"#,
            #"{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"read_file"}]}"#
        ].joined(separator: "\n") + "\n"
        try SafeFile.write(Data(silentLines.utf8), to: silentTranscript)
        let silentStop = try XCTUnwrap(parse("Stop", [
            "conversationId": "conv-1",
            "workspacePaths": ["/code/fallback-ws"],
            "terminationReason": "NO_TOOL_CALL",
            "fullyIdle": false,
            "transcriptPath": silentTranscript.path
        ], agent: "antigravity"))
        XCTAssertEqual(silentStop.project, "fallback-ws")
        XCTAssertEqual(silentStop.title, "Response completed")
        XCTAssertEqual(silentStop.detail, "Background work may continue")

        // Symlinked transcript paths must be ignored safely.
        let link = root.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: transcript)
        let linkedStop = try XCTUnwrap(parse("Stop", [
            "conversationId": "conv-1",
            "terminationReason": "NO_TOOL_CALL",
            "transcriptPath": link.path
        ]))
        XCTAssertEqual(linkedStop.title, "Response completed")

        // Errors and cancellations map cleanly.
        let errored = try XCTUnwrap(parse("Stop", [
            "conversationId": "conv-1",
            "terminationReason": "ERROR",
            "error": "Quota exceeded"
        ]))
        XCTAssertEqual(errored.status, .attention)
        XCTAssertEqual(errored.title, "Quota exceeded")
        let maxSteps = try XCTUnwrap(parse("Stop", [
            "conversationId": "conv-1",
            "terminationReason": "MAX_INVOCATIONS"
        ]))
        XCTAssertEqual(maxSteps.status, .attention)
        XCTAssertEqual(maxSteps.title, "Agent reached its step limit")
        let canceled = try XCTUnwrap(parse("Stop", [
            "conversationId": "conv-1",
            "terminationReason": "USER_CANCELED"
        ]))
        XCTAssertEqual(canceled.status, .running)
        XCTAssertEqual(canceled.title, "Interrupted")

        // ask_question raises attention with real question text; PostToolUse clears it; unrelated tools are ignored.
        let question = try XCTUnwrap(parse("PreToolUse", [
            "conversationId": "conv-1",
            "hookEventName": "PreToolUse",
            "cwd": "/code/splash",
            "toolCall": [
                "id": "call-1",
                "name": "ask_question",
                "args": [
                    "questions": [
                        ["question": "Deploy to production?"],
                        ["question": "Run migrations?"]
                    ]
                ]
            ]
        ]))
        XCTAssertEqual(question.status, .attention)
        XCTAssertEqual(question.title, "Deploy to production?")
        XCTAssertEqual(question.detail, "+1 more question — waiting for your answer")
        XCTAssertEqual(question.phase, "question")
        XCTAssertNil(try parse("PreToolUse", [
            "conversationId": "conv-1",
            "toolCall": ["name": "run_command", "args": ["CommandLine": "ls"]]
        ]))
        let answered = try XCTUnwrap(parse("PostToolUse", [
            "conversationId": "conv-1",
            "hookEventName": "PostToolUse",
            "toolCall": ["name": "ask_question"]
        ]))
        XCTAssertEqual(answered.status, .running)
        XCTAssertNil(answered.phase)
        XCTAssertNil(try parse("PostToolUse", [
            "conversationId": "conv-1",
            "toolCall": ["name": "run_command"]
        ]))

        // PreInvocation: invocation 1 clears prior completion; invocation > 1 is progress and preserves .done / question.
        let turnStart = try XCTUnwrap(parse("PreInvocation", ["conversationId": "conv-1", "invocationNum": 1]))
        let midTurn = try XCTUnwrap(parse("PreInvocation", ["conversationId": "conv-1", "invocationNum": 2]))
        XCTAssertEqual(turnStart.status, .running); XCTAssertNil(turnStart.phase)
        XCTAssertEqual(midTurn.status, .running); XCTAssertEqual(midTurn.phase, "progress")

        var inbox = Inbox()
        try inbox.receive(stop)
        try inbox.receive(midTurn)
        XCTAssertEqual(inbox.items.first?.status, .done, "Mid-turn progress must not erase completion")
        try inbox.receive(turnStart)
        XCTAssertTrue(inbox.items.isEmpty, "A new user turn clears the previous completion")
        try inbox.receive(question)
        try inbox.receive(midTurn)
        XCTAssertEqual(inbox.items.first?.title, "Deploy to production?", "Mid-turn progress must not clear an open question")
        try inbox.receive(answered)
        XCTAssertTrue(inbox.items.isEmpty, "PostToolUse on ask_question clears the question card")
        try inbox.receive(stop)
        try inbox.receive(canceled)
        XCTAssertTrue(inbox.items.isEmpty, "USER_CANCELED clears stale cards without raising attention")

        // Subagents suppress non-attention events, but still forward ask_question prompts.
        XCTAssertNil(try parse("Stop", ["conversationId": "sub-1", "parentConversationId": "conv-1", "terminationReason": "NO_TOOL_CALL"]))
        XCTAssertNil(try parse("PreInvocation", ["conversationId": "sub-1", "isSubagent": true, "invocationNum": 1]))
        XCTAssertEqual(try parse("PreToolUse", [
            "conversationId": "sub-1",
            "parentConversationId": "conv-1",
            "toolCall": ["name": "ask_question", "args": ["questions": [["question": "Subagent needs input"]]]]
        ])?.status, .attention)

        // Event mismatch and oversized payloads are rejected.
        XCTAssertNil(try parse("Stop", ["conversationId": "conv-1", "hookEventName": "PreInvocation"]))
        XCTAssertNil(try HookEvent.parse(agent: "agy", input: Data(repeating: 32, count: 1_048_577), event: "Stop"))
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
    var installer: IntegrationInstaller { makeInstaller(environment: [:]) }
    private func makeInstaller(environment: [String: String]) -> IntegrationInstaller {
        IntegrationInstaller(home: home, environment: environment, executable: "/Applications/Splash Finish.app/Contents/MacOS/SplashFinish", resources: resources)
    }
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
        try SafeFile.write(JSONSerialization.data(withJSONObject: original), to: url)
        _ = try installer.run(install: true, agents: AgentKind.allCases)
        let first = try Data(contentsOf: url)
        _ = try installer.run(install: true, agents: AgentKind.allCases)
        XCTAssertEqual(first, try Data(contentsOf: url))
        let extensionURL = home.appendingPathComponent(".pi/agent/extensions/splash-finish.ts")
        let ompExtension = home.appendingPathComponent(".omp/agent/extensions/splash-finish.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ompExtension.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extensionURL.path))
        XCTAssertFalse(try String(contentsOf: extensionURL).contains("__EXECUTABLE_JSON__"))
        let current = try JSONSerialization.jsonObject(with: first) as! [String: Any]
        XCTAssertEqual(current["model"] as? String, "keep-me")
        _ = try installer.run(install: false, agents: AgentKind.allCases)
        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! NSDictionary
        XCTAssertTrue(restored.isEqual(to: original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extensionURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ompExtension.path))
        _ = try installer.run(install: false, agents: AgentKind.allCases)
    }
    func testInstalledHooksHonorWorkerOptOut() throws {
        let executable = home.appendingPathComponent("worker's app")
        let log = home.appendingPathComponent("hook-calls.txt")
        try SafeFile.write(Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$HOOK_TEST_LOG\"\n".utf8), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let guarded = IntegrationInstaller(home: home, environment: [:], executable: executable.path, resources: resources)
        _ = try guarded.run(install: true, agents: [.claude, .codex])
        for path in [".claude/settings.json", ".codex/hooks.json"] {
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: home.appendingPathComponent(path))) as! [String: Any]
            let hooks = config["hooks"] as! [String: Any]
            let groups = hooks["Stop"] as! [[String: Any]]
            let command = (groups[0]["hooks"] as! [[String: Any]])[0]["command"] as! String
            for disabled in [nil, "0", "1"] as [String?] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                var environment = ["HOOK_TEST_LOG": log.path]
                environment["SPLASH_FINISH_DISABLED"] = disabled
                process.environment = environment
                try process.run(); process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
            }
        }
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(calls.count, 4, "Only unset and 0 invoke each agent hook; 1 must skip the executable")
        XCTAssertTrue(guarded.inspect(inbox: Inbox()).filter { [.claude, .codex].contains($0.agent) }.allSatisfy { $0.state == .installed })
    }
    func testPiAgentAskDetectionAndRecommendations() throws {
        XCTAssertFalse(installer.piAgentAskDetected())
        let settings = home.appendingPathComponent(".pi/agent/settings.json")
        let package = home.appendingPathComponent(".pi/agent/npm/node_modules/pi-agent-ask/package.json")
        try SafeFile.write(Data("{\"packages\":[\"npm:pi-agent-ask\"]}".utf8), to: settings)
        XCTAssertFalse(installer.piAgentAskDetected(), "A configured but missing package is not installed")
        try SafeFile.write(Data("{\"name\":\"pi-agent-ask\",\"version\":\"2.0.2\"}".utf8), to: package)
        XCTAssertTrue(installer.piAgentAskDetected())
        XCTAssertEqual(installer.inspect(inbox: Inbox()).first { $0.agent == .pi }?.piAskDetected, true)
        XCTAssertTrue(try installer.run(install: true, agents: [.pi]).joined().contains("rich questions enabled"))
        XCTAssertEqual(installer.inspect(inbox: Inbox()).first { $0.agent == .pi }?.richQuestionsEnabled, true)
        try SafeFile.write(Data("{\"packages\":[{\"source\":\"npm:pi-agent-ask\",\"extensions\":[]}]}".utf8), to: settings)
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
        XCTAssertEqual(installer.inspect(inbox: Inbox()).first { $0.agent == .pi }?.richQuestionsEnabled, true)
        _ = try installer.run(install: true, agents: [.pi])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "CLI reinstall preserves a project-local opt-in")
        _ = try installer.run(install: true, agents: [.pi], richQuestions: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(installer.inspect(inbox: Inbox()).first { $0.agent == .pi }?.richQuestionsEnabled, false)
        _ = try installer.run(install: true, agents: [.pi], richQuestions: true)
        _ = try installer.run(install: false, agents: [.pi])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
    func testRichPiFileOwnershipIsProtected() throws {
        let file = home.appendingPathComponent(".pi/agent/extensions/splash-finish-questions.ts")
        try SafeFile.write(Data("user-owned extension".utf8), to: file)
        XCTAssertThrowsError(try installer.run(install: true, agents: [.pi]))
        XCTAssertThrowsError(try installer.run(install: false, agents: [.pi]))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user-owned extension")
    }
    func testDoctorDetectsInstallOutdatedAndLastEvent() throws {
        var inbox = Inbox()
        let initial = installer.inspect(inbox: inbox)
        XCTAssertEqual(initial.map(\.agent), AgentKind.allCases)
        XCTAssertTrue(initial.allSatisfy { $0.state == .notInstalled })
        _ = try installer.run(install: true, agents: [.pi])
        try inbox.receive(AgentEvent(task: "s", agent: "pi", status: .done, title: "done"))
        let installed = try XCTUnwrap(installer.inspect(inbox: inbox).first { $0.agent == .pi })
        XCTAssertEqual(installed.state, .installed); XCTAssertNotNil(installed.lastEvent)
        // Display-name variants of an agent map to the same last-event record.
        try inbox.receive(AgentEvent(task: "c", agent: "Claude Code", status: .done, title: "done"))
        XCTAssertNotNil(installer.inspect(inbox: inbox).first { $0.agent == .claude }?.lastEvent)
        let skill = home.appendingPathComponent(".pi/agent/skills/splash-finish/SKILL.md")
        try Data("<!-- Managed by Splash Finish --> old".utf8).write(to: skill)
        XCTAssertEqual(installer.inspect(inbox: inbox).first { $0.agent == .pi }?.state, .updateAvailable)
    }
    func testOmpLifecycleAndLastEventWithoutHooksOrRichPi() throws {
        let root = home.appendingPathComponent(".omp/agent")
        let adapter = root.appendingPathComponent("extensions/splash-finish.ts")
        let skill = root.appendingPathComponent("skills/splash-finish/SKILL.md")
        let rich = root.appendingPathComponent("extensions/splash-finish-questions.ts")
        let unrelated = ["hooks.json", "settings.json", "config.yml", "extensions/user.ts"].map { root.appendingPathComponent($0) }
        let userContent = Data("User configuration\n".utf8)
        for path in unrelated { try SafeFile.write(userContent, to: path) }
        var inbox = Inbox()
        try inbox.receive(AgentEvent(task: "session", agent: "OMP", status: .done, title: "Done"))

        XCTAssertEqual(installer.inspect(inbox: inbox).first { $0.agent == .omp }?.state, .notInstalled)
        let messages = try installer.run(install: true, agents: [.omp], richQuestions: true)
        XCTAssertTrue(messages.contains("Installed omp skill and extension"))
        XCTAssertFalse(messages.joined().contains("pi-agent-ask"))
        let initialAdapter = try String(contentsOf: adapter, encoding: .utf8)
        let initialSkill = try String(contentsOf: skill, encoding: .utf8)
        let marker = "// Managed by Splash Finish (OMP). Reinstall to update; uninstall-skills removes this file."
        XCTAssertTrue(initialAdapter.hasPrefix(marker + "\n"))
        let encodedExecutable = String(decoding: try JSONEncoder().encode(installer.executable), as: UTF8.self)
        XCTAssertTrue(initialAdapter.contains(encodedExecutable))
        XCTAssertFalse(initialAdapter.contains("__EXECUTABLE_JSON__"))
        XCTAssertTrue(initialSkill.contains("'\(installer.executable)'"))
        XCTAssertFalse(initialSkill.contains("__COMMAND__"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rich.path))
        let status = try XCTUnwrap(installer.inspect(inbox: inbox).first { $0.agent == .omp })
        XCTAssertEqual(status.state, .installed)
        XCTAssertEqual(status.lastEvent, inbox.lastEvents?["omp"])
        XCTAssertNotNil(status.lastEvent)
        XCTAssertFalse(status.richQuestionsEnabled)
        XCTAssertFalse(status.piAskDetected)

        try FileManager.default.removeItem(at: skill)
        XCTAssertEqual(installer.inspect(inbox: inbox).first { $0.agent == .omp }?.state, .incomplete)
        _ = try installer.run(install: true, agents: [.omp])
        XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), initialSkill)
        XCTAssertEqual(try String(contentsOf: adapter, encoding: .utf8), initialAdapter)
        try SafeFile.write(Data((marker + "\n// Old adapter\n").utf8), to: adapter)
        XCTAssertEqual(installer.inspect(inbox: inbox).first { $0.agent == .omp }?.state, .updateAvailable)
        _ = try installer.run(install: true, agents: [.omp])
        XCTAssertEqual(try String(contentsOf: adapter, encoding: .utf8), initialAdapter)

        try SafeFile.write(userContent, to: rich)
        _ = try installer.run(install: false, agents: [.omp])
        XCTAssertFalse(FileManager.default.fileExists(atPath: adapter.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: skill.deletingLastPathComponent().path))
        XCTAssertEqual(installer.inspect(inbox: inbox).first { $0.agent == .omp }?.state, .notInstalled)
        for path in unrelated + [rich] { XCTAssertEqual(try Data(contentsOf: path), userContent) }
    }
    func testOmpResolvesConfigRootDefaultOverrideAndNamedProfiles() throws {
        let custom = home.appendingPathComponent(".custom-omp")
        let override = home.appendingPathComponent("custom agent dir").path
        let named = custom.appendingPathComponent("profiles/work.v2-3_team/agent").path
        let legacy = home.appendingPathComponent(".omp/profiles/legacy/agent").path
        let defaultRoot = home.appendingPathComponent(".omp/agent").path
        let maxLength = String(repeating: "a", count: 64)
        let scenarios: [([String: String], String)] = [
            (["PI_CONFIG_DIR": ".custom-omp"], custom.appendingPathComponent("agent").path),
            (["PI_CONFIG_DIR": "", "PI_CODING_AGENT_DIR": ""], defaultRoot),
            (["PI_CODING_AGENT_DIR": override], override),
            (["OMP_PROFILE": " \twork.v2-3_team\n", "PI_PROFILE": "..", "PI_CONFIG_DIR": ".custom-omp", "PI_CODING_AGENT_DIR": override], named),
            (["PI_PROFILE": "legacy", "PI_CODING_AGENT_DIR": override], legacy),
            (["OMP_PROFILE": maxLength], home.appendingPathComponent(".omp/profiles/\(maxLength)/agent").path),
            (["OMP_PROFILE": "", "PI_PROFILE": "legacy", "PI_CODING_AGENT_DIR": override], override),
            (["OMP_PROFILE": " default ", "PI_PROFILE": "legacy", "PI_CODING_AGENT_DIR": legacy], defaultRoot)
        ]
        let candidateRoots = Set(scenarios.map { $0.1 })
        for (environment, expected) in scenarios {
            let configured = makeInstaller(environment: environment)
            _ = try configured.run(install: true, agents: [.omp])
            for root in candidateRoots {
                let extensionPath = root + "/extensions/splash-finish.ts"
                XCTAssertEqual(FileManager.default.fileExists(atPath: extensionPath), root == expected, "\(environment)")
            }
            XCTAssertEqual(configured.inspect(inbox: Inbox()).first { $0.agent == .omp }?.state, .installed)
            _ = try configured.run(install: false, agents: [.omp])
            XCTAssertFalse(FileManager.default.fileExists(atPath: expected + "/extensions/splash-finish.ts"))
        }
    }
    func testInvalidOmpProfilesRefusePreflightForAllWithoutAffectingPi() throws {
        let claude = home.appendingPathComponent(".claude/settings.json")
        let invalidNames = ["../outside", "/absolute", "Uppercase", "work.", "-work", "com1.txt", "work🧪", String(repeating: "a", count: 65)]
        for name in invalidNames {
            let configured = makeInstaller(environment: ["OMP_PROFILE": name, "PI_PROFILE": "valid"])
            XCTAssertThrowsError(try configured.run(install: true, agents: AgentKind.allCases)) {
                XCTAssertTrue($0.localizedDescription.contains("Invalid OMP profile"))
            }
            let statuses = configured.inspect(inbox: Inbox())
            XCTAssertEqual(statuses.first { $0.agent == .omp }?.state, .error)
            XCTAssertEqual(statuses.first { $0.agent == .pi }?.state, .notInstalled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: claude.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".omp").path))
        }
        let legacy = makeInstaller(environment: ["PI_PROFILE": ".."])
        XCTAssertThrowsError(try legacy.run(install: true, agents: [.omp]))
        XCTAssertNoThrow(try legacy.run(install: true, agents: [.pi]))
    }
    func testSharedAgentRootRefusesAllAndProtectsEachAdaptersOwnership() throws {
        let sharedRoot = home.appendingPathComponent("shared")
        let adapter = sharedRoot.appendingPathComponent("extensions/splash-finish.ts")
        let skill = sharedRoot.appendingPathComponent("skills/splash-finish/SKILL.md")
        let claude = home.appendingPathComponent(".claude/settings.json")
        let shared = makeInstaller(environment: ["PI_CODING_AGENT_DIR": sharedRoot.path])
        XCTAssertThrowsError(try shared.run(install: true, agents: AgentKind.allCases)) {
            XCTAssertTrue($0.localizedDescription.contains("share an agent directory"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sharedRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claude.path))
        _ = try installer.run(install: true, agents: [.claude])
        let claudeConfig = try Data(contentsOf: claude)
        XCTAssertThrowsError(try shared.run(install: false, agents: AgentKind.allCases))
        XCTAssertEqual(try Data(contentsOf: claude), claudeConfig)

        let ownershipPairs: [(AgentKind, AgentKind)] = [(.pi, .omp), (.omp, .pi)]
        for (owner, other) in ownershipPairs {
            _ = try shared.run(install: true, agents: [owner])
            let originalAdapter = try Data(contentsOf: adapter)
            let originalSkill = try Data(contentsOf: skill)
            for install in [true, false] {
                XCTAssertThrowsError(try shared.run(install: install, agents: [other])) {
                    XCTAssertTrue($0.localizedDescription.contains("adapter managed for"))
                }
                XCTAssertEqual(try Data(contentsOf: adapter), originalAdapter)
                XCTAssertEqual(try Data(contentsOf: skill), originalSkill)
            }
            let states = shared.inspect(inbox: Inbox())
            XCTAssertEqual(states.first { $0.agent == owner }?.state, .installed)
            XCTAssertEqual(states.first { $0.agent == other }?.state, .error)
            _ = try shared.run(install: false, agents: [owner])
            XCTAssertFalse(FileManager.default.fileExists(atPath: adapter.path))
        }

        let named = makeInstaller(environment: [
            "OMP_PROFILE": "work",
            "PI_CODING_AGENT_DIR": home.appendingPathComponent(".omp/profiles/work/../work/agent").path
        ])
        XCTAssertThrowsError(try named.run(install: true, agents: AgentKind.allCases)) {
            XCTAssertTrue($0.localizedDescription.contains("share an agent directory"))
        }
        XCTAssertEqual(try Data(contentsOf: claude), claudeConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".omp").path))
    }
    func testOmpPreflightRefusesUnmanagedAdapterAndDanglingSymlink() throws {
        let adapter = home.appendingPathComponent(".omp/agent/extensions/splash-finish.ts")
        let claude = home.appendingPathComponent(".claude/settings.json")
        let userContent = Data("// User adapter\n// Managed by Splash Finish (OMP). Reinstall to update; uninstall-skills removes this file.\n".utf8)
        try SafeFile.write(userContent, to: adapter)
        for install in [true, false] {
            XCTAssertThrowsError(try installer.run(install: install, agents: AgentKind.allCases))
            XCTAssertEqual(try Data(contentsOf: adapter), userContent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: claude.path))
        }
        XCTAssertEqual(installer.inspect(inbox: Inbox()).first { $0.agent == .omp }?.state, .error)

        try FileManager.default.removeItem(at: adapter)
        let missing = home.appendingPathComponent("missing.ts")
        try FileManager.default.createSymbolicLink(at: adapter, withDestinationURL: missing)
        for install in [true, false] {
            XCTAssertThrowsError(try installer.run(install: install, agents: [.omp])) {
                XCTAssertTrue($0.localizedDescription.contains("Refusing symlink"))
            }
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: adapter.path), missing.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        try FileManager.default.removeItem(at: adapter)
        let skill = home.appendingPathComponent(".omp/agent/skills/splash-finish/SKILL.md")
        try SafeFile.write(Data("User skill\n".utf8), to: skill)
        for install in [true, false] {
            XCTAssertThrowsError(try installer.run(install: install, agents: [.omp]))
            XCTAssertEqual(try String(contentsOf: skill, encoding: .utf8), "User skill\n")
        }
    }
    func testBackupRotationKeepsNewestThree() throws {
        let url = home.appendingPathComponent(".codex/hooks.json")
        _ = try installer.run(install: true, agents: [.codex])
        for _ in 0..<5 {
            var config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            var hooks = config["hooks"] as! [String: Any]
            hooks.removeValue(forKey: "SessionEnd") // A required event; patch re-adds it and must back up first.
            config["hooks"] = hooks
            try SafeFile.write(JSONSerialization.data(withJSONObject: config), to: url)
            _ = try installer.run(install: true, agents: [.codex])
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".codex").path)
            .filter { $0.hasPrefix("hooks.json.splash-finish-backup-") }
        XCTAssertEqual(backups.count, 3)
    }
    func testFocusStatusReadsAssertionsDatabase() throws {
        let database = home.appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")
        try SafeFile.write(Data(#"{"data":[{}]}"#.utf8), to: database)
        XCTAssertFalse(FocusStatus.isDoNotDisturbActive(home: home))
        try SafeFile.write(Data(#"{"data":[{"storeAssertionRecords":[{"assertionDetails":{}}]}]}"#.utf8), to: database)
        XCTAssertTrue(FocusStatus.isDoNotDisturbActive(home: home))
        try FileManager.default.removeItem(at: database)
        XCTAssertFalse(FocusStatus.isDoNotDisturbActive(home: home))
    }
    func testInvalidConfigPreflightDoesNotWriteOtherFiles() throws {
        let url = home.appendingPathComponent(".codex/hooks.json")
        let bad = Data("{\"hooks\":{\"Stop\":\"invalid\"}}".utf8)
        try SafeFile.write(bad, to: url)
        XCTAssertThrowsError(try installer.run(install: true, agents: AgentKind.allCases))
        XCTAssertEqual(try Data(contentsOf: url), bad)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }
    func testUnmanagedFileAndSymlinkRefused() throws {
        let skill = home.appendingPathComponent(".pi/agent/skills/splash-finish/SKILL.md")
        try SafeFile.write(Data("My own skill".utf8), to: skill)
        XCTAssertThrowsError(try installer.run(install: true, agents: [.pi]))
        XCTAssertEqual(try String(contentsOf: skill), "My own skill")
        let link = home.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.appendingPathComponent("absent"))
        XCTAssertThrowsError(try SafeFile.write(Data(), to: link))
        XCTAssertThrowsError(try SafeFile.write(Data(), to: link.appendingPathComponent("child.json")))
    }
    func testMixedGroupsKeepUnrelatedHandlers() throws {
        let url = home.appendingPathComponent(".codex/hooks.json")
        let original: [String: Any] = ["description": "keep", "hooks": ["Stop": [["custom": "metadata", "hooks": [
            ["type": "command", "command": "'old' hook codex --managed-splash-finish"],
            ["type": "command", "command": "echo user-hook"]]]]]]
        try SafeFile.write(JSONSerialization.data(withJSONObject: original), to: url)
        _ = try installer.run(install: false, agents: [.codex])
        let result = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hooks = result["hooks"] as! [String: [[String: Any]]]
        XCTAssertEqual(hooks["Stop"]?.first?["custom"] as? String, "metadata")
        XCTAssertEqual((hooks["Stop"]?.first?["hooks"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(result["description"] as? String, "keep")
    }
    func testCopilotManagedFilesAndRepair() throws {
        let custom = home.appendingPathComponent("custom home")
        let executable = home.appendingPathComponent("worker's executable")
        let log = home.appendingPathComponent("calls")
        try SafeFile.write(Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$HOOK_TEST_LOG\"\n".utf8), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let copilot = IntegrationInstaller(home: home, environment: ["COPILOT_HOME": custom.path], executable: executable.path, resources: resources)
        let other = custom.appendingPathComponent("hooks/other.json")
        try SafeFile.write(Data("user content".utf8), to: other)
        _ = try copilot.run(install: true, agents: [.copilot])
        let path = custom.appendingPathComponent("hooks/splash-finish.json")
        let first = try Data(contentsOf: path)
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let hooks = try XCTUnwrap(config["hooks"] as? [String: [[String: Any]]])
        XCTAssertEqual(config["version"] as? Int, 1)
        XCTAssertEqual(Set(hooks.keys), Set(["Stop", "UserPromptSubmit", "PostToolUse", "SessionEnd", "notification"]))
        XCTAssertEqual(hooks["notification"]?.first?["matcher"] as? String, "permission_prompt|elicitation_dialog")
        let command = try XCTUnwrap(hooks["Stop"]?.first?["bash"] as? String)
        for disabled in ["0", "1"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = ["HOOK_TEST_LOG": log.path, "SPLASH_FINISH_DISABLED": disabled]
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        }
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "hook copilot Stop --managed-splash-finish\n")
        _ = try copilot.run(install: true, agents: [.copilot])
        XCTAssertEqual(try Data(contentsOf: path), first)
        XCTAssertEqual(copilot.inspect(inbox: Inbox()).first { $0.agent == .copilot }?.state, .installed)
        var edited = config
        edited["hooks"] = [:]
        try SafeFile.write(JSONSerialization.data(withJSONObject: edited), to: path)
        XCTAssertEqual(copilot.inspect(inbox: Inbox()).first { $0.agent == .copilot }?.state, .updateAvailable)
        _ = try copilot.run(install: true, agents: [.copilot])
        XCTAssertEqual(try Data(contentsOf: path), first)
        _ = try copilot.run(install: false, agents: [.copilot])
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "user content")
        try SafeFile.write(Data("{\"version\":1}".utf8), to: path)
        XCTAssertThrowsError(try copilot.run(install: true, agents: AgentKind.allCases))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }
    func testAgyManagedPluginAndRepair() throws {
        let custom = home.appendingPathComponent("custom agy config")
        let executable = home.appendingPathComponent("worker's agy binary")
        let log = home.appendingPathComponent("agy-calls")
        try SafeFile.write(Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$HOOK_TEST_LOG\"\n".utf8), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let agy = IntegrationInstaller(home: home, environment: ["ANTIGRAVITY_CONFIG_DIR": custom.path], executable: executable.path, resources: resources)

        let unrelated = custom.appendingPathComponent("hooks.json")
        try SafeFile.write(Data("{\"user-hook\":{}}\n".utf8), to: unrelated)

        _ = try agy.run(install: true, agents: [.agy])
        let pluginRoot = custom.appendingPathComponent("plugins/splash-finish")
        let manifestPath = pluginRoot.appendingPathComponent("plugin.json")
        let hooksPath = pluginRoot.appendingPathComponent("hooks.json")
        let skillPath = pluginRoot.appendingPathComponent("skills/splash-finish/SKILL.md")

        let manifestData = try Data(contentsOf: manifestPath)
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        XCTAssertEqual(manifest["name"] as? String, "splash-finish")
        XCTAssertTrue((manifest["description"] as? String)?.contains("Managed by Splash Finish") == true)

        let hooksData = try Data(contentsOf: hooksPath)
        let hooksRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: hooksData) as? [String: Any])
        let spec = try XCTUnwrap(hooksRoot["splash-finish"] as? [String: Any])
        XCTAssertEqual(Set(spec.keys), Set(["PreInvocation", "PreToolUse", "PostToolUse", "Stop"]))

        let stopHandlers = try XCTUnwrap(spec["Stop"] as? [[String: Any]])
        let stopCommand = try XCTUnwrap(stopHandlers.first?["command"] as? String)
        let preToolGroups = try XCTUnwrap(spec["PreToolUse"] as? [[String: Any]])
        XCTAssertEqual(preToolGroups.first?["matcher"] as? String, "ask_question")
        let preToolCommand = try XCTUnwrap((preToolGroups.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)

        for (command, expectedDisabledStdout) in [(stopCommand, "{}\n"), (preToolCommand, "{\"decision\":\"allow\"}\n")] {
            for disabled in ["0", "1"] {
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", command]
                process.environment = ["HOOK_TEST_LOG": log.path, "SPLASH_FINISH_DISABLED": disabled]
                let stdout = Pipe(); process.standardOutput = stdout
                try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
                let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if disabled == "1" {
                    XCTAssertEqual(output, expectedDisabledStdout)
                }
            }
        }
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8),
                       "hook agy Stop --managed-splash-finish\nhook agy PreToolUse --managed-splash-finish\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: skillPath.path))

        // Idempotent reinstall and doctor inspection (including lastEvent alias).
        _ = try agy.run(install: true, agents: [.agy])
        XCTAssertEqual(try Data(contentsOf: hooksPath), hooksData)
        var inbox = Inbox()
        try inbox.receive(AgentEvent(task: "conv-1", agent: "Antigravity", status: .done, title: "Done"))
        let status = try XCTUnwrap(agy.inspect(inbox: inbox).first { $0.agent == .agy })
        XCTAssertEqual(status.state, .installed)
        XCTAssertNotNil(status.lastEvent)

        // Modified managed file reports updateAvailable and repairs cleanly.
        try SafeFile.write(Data("{\"splash-finish\":{\"Stop\":[{\"command\":\"old --managed-splash-finish\"}]}}\n".utf8), to: hooksPath)
        XCTAssertEqual(agy.inspect(inbox: inbox).first { $0.agent == .agy }?.state, .updateAvailable)
        _ = try agy.run(install: true, agents: [.agy])
        XCTAssertEqual(try Data(contentsOf: hooksPath), hooksData)

        // Uninstall removes plugin files and empty folders without touching user's hooks.json.
        _ = try agy.run(install: false, agents: [.agy])
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginRoot.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "{\"user-hook\":{}}\n")

        // Unmanaged plugin manifest is refused in preflight without touching other agents.
        try SafeFile.write(Data("{\"name\":\"splash-finish\",\"description\":\"user owned\"}\n".utf8), to: manifestPath)
        XCTAssertThrowsError(try agy.run(install: true, agents: AgentKind.allCases))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/settings.json").path))
    }
}

/// `SPLASH_FINISH_HOME` names a folder that holds every file; hooks and the Python tests rely on it.
final class SplashPathsTests: XCTestCase {
    func testPathsMatchEarlierVersions() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let installed = AppPaths.splashFinish(environment: [:], home: home)
        XCTAssertEqual(installed.support.path, "/Users/someone/Library/Application Support/Splash Finish")
        XCTAssertEqual(installed.state.path, "/Users/someone/Library/Application Support/Splash Finish/state.json")
        XCTAssertEqual(installed.file("app.lock").path, "/Users/someone/Library/Application Support/Splash Finish/app.lock")
        for value in ["/tmp/splash-home", "/tmp/splash-home/"] {
            let isolated = AppPaths.splashFinish(environment: ["SPLASH_FINISH_HOME": value], home: home)
            XCTAssertEqual(isolated.support.path, "/tmp/splash-home")
            XCTAssertEqual(isolated.state.path, "/tmp/splash-home/state.json")
            XCTAssertEqual(isolated.file("skills.lock").path, "/tmp/splash-home/skills.lock")
        }
    }
}
