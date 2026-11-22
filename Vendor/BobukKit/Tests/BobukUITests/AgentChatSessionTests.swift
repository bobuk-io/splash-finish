import BobukCore
import BobukTestSupport
@testable import BobukUI
import Foundation
import Testing

@MainActor struct AgentChatSessionTests {
    @Test func markdownParserSeparatesBlocksWhilePreservingCode() {
        let raw = """
        # Title

        Hello **world**.

        - First item
        - Second item

        1. Step one

        > Quoted note

        ```swift
        let x = 1
        ```
        """
        let blocks = ChatMarkdownBlock.parse(raw)
        #expect(blocks == [
            .heading(level: 1, text: "Title"),
            .paragraph("Hello **world**."),
            .bullet("First item"),
            .bullet("Second item"),
            .ordered(number: "1", text: "Step one"),
            .quote("Quoted note"),
            .code(language: "swift", code: "let x = 1"),
        ])
    }
    @Test(arguments: [true, false]) func modelCatalogRequirement(_ required: Bool) async throws {
        let dir = try TemporaryDirectory(prefix: "acp-no-models")
        defer { dir.remove() }
        let agent = #"""
            IFS= read -r line
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
            IFS= read -r line
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"demo","configOptions":[]}}'
            IFS= read -r line || true
            """#
        let chat = AgentChatSession(makeClient: {
            ACPClient(launch: .init(executable: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", agent],
                                   directory: dir.url, environment: ["PATH": "/usr/bin:/bin"], clientName: "test",
                                   isolation: .unrestricted),
                      requestTimeout: .seconds(2))
        }, missingModelsMessage: required ? "No models" : nil)
        chat.draft = "Keep my draft"
        chat.connect()
        for _ in 0..<200 where chat.phase == .connecting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chat.phase == .ready)
        #expect(chat.canSend == !required)
        if required {
            chat.send()
            #expect(chat.messages.isEmpty)
            #expect(chat.draft == "Keep my draft")
        }
        await chat.shutdown()
    }

    @Test func idleTimeoutDisconnectsSubprocessAndKeepsTranscript() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-idle")
        defer { dir.remove() }
        let marker = dir.url.appendingPathComponent("alive")
        let agent = """
            trap 'rm -f "\(marker.path)"' EXIT
            touch "\(marker.path)"
            while IFS= read -r line; do
                case "$line" in
                    *initialize*)
                        printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
                        ;;
                    *session*new*)
                        printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"demo","configOptions":[]}}'
                        ;;
                    *session*prompt*)
                        printf '%s\\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"demo","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hi"}}}}'
                        printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
                        ;;
                esac
            done
            """
        var idleCallbacks = 0
        let chat = AgentChatSession(
            makeClient: {
                ACPClient(
                    launch: .init(
                        executable: URL(fileURLWithPath: "/bin/bash"),
                        arguments: ["-c", agent],
                        directory: dir.url,
                        environment: ["PATH": "/usr/bin:/bin"],
                        clientName: "test",
                        isolation: .unrestricted
                    ),
                    requestTimeout: .seconds(2)
                )
            },
            idleTimeout: .milliseconds(250)
        )
        chat.onIdleDisconnect = { idleCallbacks += 1 }
        chat.connect()
        for _ in 0..<200 where chat.phase == .connecting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chat.phase == .ready)
        #expect(!chat.disconnectedForInactivity)

        // Activity resets the countdown; sending a message keeps it alive during the turn.
        chat.draft = "Hello"
        chat.send()
        for _ in 0..<200 where chat.phase == .replying { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chat.phase == .ready)
        #expect(chat.messages.count == 2)

        chat.draft = "Next thought"
        // Let the idle timer fire.
        for _ in 0..<200 where chat.phase == .ready { try await Task.sleep(for: .milliseconds(15)) }
        #expect(chat.phase == .disconnected)
        #expect(chat.disconnectedForInactivity)
        #expect(chat.error == nil)
        #expect(idleCallbacks == 1)
        // Transcript and draft stay visible for when the user comes back.
        #expect(chat.messages.count == 2)
        #expect(chat.draft == "Next thought")

        // Reconnecting clears the idle flag and can disable timeout dynamically.
        chat.idleTimeout = nil
        chat.connect()
        for _ in 0..<200 where chat.phase == .connecting { try await Task.sleep(for: .milliseconds(10)) }
        #expect(chat.phase == .ready)
        #expect(!chat.disconnectedForInactivity)
        try await Task.sleep(for: .milliseconds(200))
        #expect(chat.phase == .ready)
        await chat.shutdown()
    }
}
