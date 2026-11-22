import BobukCore
import BobukTestSupport
import Foundation
import Testing

@Suite struct ACPClientTests {
    private actor Transcript {
        var text = ""
        func append(_ delta: String) { text += delta }
    }

    private static let script = #"""
    set -eu
    mode="$1"
    IFS= read -r line
    [[ "$line" == *'"initialize"'* ]] || exit 1
    case "$mode" in
        quiet) IFS= read -r line || true; exit 0 ;;
        version) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":9}}'; exit 0 ;;
    esac
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
    IFS= read -r line
    [[ "$line" == *'"session\/new"'* ]] || exit 1
    if [[ "$mode" == auth ]]; then
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Authentication required"}}'
        exit 0
    fi
    options='"configOptions":[{"type":"select","category":"model","id":"model","currentValue":"fast","options":[{"group":"Gemini","options":[{"value":"fast","name":"Fast"},{"value":"slow","name":"Slow"}]}]}]'
    printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"demo\",$options}}"
    IFS= read -r line
    if [[ "$mode" == normal ]]; then
        [[ "$line" == *'"session\/set_config_option"'* && "$line" == *'"slow"'* ]] || exit 1
        options=${options/\"currentValue\":\"fast\"/\"currentValue\":\"slow\"}
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{$options}}"
        IFS= read -r line
    fi
    [[ "$line" == *'"session\/prompt"'* ]] || exit 1
    if [[ "$mode" == tool ]]; then
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"demo","update":{"sessionUpdate":"tool_call","status":"in_progress"}}}'
        IFS= read -r line || true
        exit 0
    fi
    if [[ "$mode" == normal ]]; then
        printf '%s\n' '{"jsonrpc":"2.0","id":"server-1","method":"session/request_permission","params":{}}'
        IFS= read -r line
        [[ "$line" == *'"server-1"'* && "$line" == *'"cancelled"'* ]] || exit 1
        printf '%s\n' '{"jsonrpc":"2.0","id":"server-2","method":"fs/read_text_file","params":{}}'
        IFS= read -r line
        [[ "$line" == *'"server-2"'* && "$line" == *'-32601'* ]] || exit 1
    fi
    printf '%s' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"demo","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Вена'
    printf '%s\n' '"}}}}'
    if [[ "$mode" == cancel ]]; then
        IFS= read -r line
        [[ "$line" == *'"session\/cancel"'* ]] || exit 1
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"cancelled"}}'
    else
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"demo","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":".pdf"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":4,"result":{"stopReason":"end_turn"}}'
    fi
    IFS= read -r line || true
    """#

    private func fixture(_ mode: String, directory: TemporaryDirectory, timeout: Duration = .seconds(2),
                         isolation: ACPProcessIsolation = .unrestricted) -> ACPClient {
        ACPClient(launch: ACPLaunchConfiguration(executable: URL(fileURLWithPath: "/bin/bash"),
                  arguments: ["-c", Self.script, "fixture", mode], directory: directory.url,
                  environment: ["PATH": "/usr/bin:/bin"], clientName: "fixture", isolation: isolation),
                  requestTimeout: timeout, turnTimeout: .seconds(2))
    }

    @Test func launchesThroughSandboxAndDoesNotFallBack() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-launch-mode")
        defer { dir.remove() }
        let sandbox = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let wrapped = fixture("normal", directory: dir,
                              isolation: .sandboxed(launcher: sandbox, arguments: ["-p", "(version 1)(allow default)"]))
        #expect(try await wrapped.connect()?.current == "fast")
        await wrapped.close()
        let denied = fixture("normal", directory: dir,
                              isolation: .sandboxed(launcher: URL(fileURLWithPath: "/usr/bin/false"), arguments: []))
        await #expect(throws: ACPError.disconnected) { _ = try await denied.connect() }
    }

    @Test func modelSelectionAndStreamRejectingCallbacks() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-test")
        defer { dir.remove() }
        let agent = fixture("normal", directory: dir)
        let models = try #require(await agent.connect())
        #expect(models.current == "fast")
        #expect(models.choices.map(\.name) == ["Fast", "Slow"])
        #expect(try await agent.selectModel("slow")?.current == "slow")
        let transcript = Transcript()
        #expect(try await agent.prompt("Suggest a rule") { await transcript.append($0) } == "end_turn")
        #expect(await transcript.text == "Вена.pdf")
        await agent.close()
    }

    @Test func cancelTurn() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-test")
        defer { dir.remove() }
        let agent = fixture("cancel", directory: dir)
        _ = try await agent.connect()
        // The first chunk proves that the test server has begun processing the prompt.
        #expect(try await agent.prompt("A prompt") { _ in await agent.cancel() } == "cancelled")
        await agent.close()
    }

    @Test func authenticationTimeoutAndVersion() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-test")
        defer { dir.remove() }
        let auth = fixture("auth", directory: dir)
        await #expect(throws: ACPError.authenticationRequired) { _ = try await auth.connect() }
        let quiet = fixture("quiet", directory: dir, timeout: .milliseconds(200))
        await #expect(throws: ACPError.timedOut) { _ = try await quiet.connect() }
        let newer = fixture("version", directory: dir)
        await #expect(throws: ACPError.unsupportedVersion) { _ = try await newer.connect() }
    }

    @Test func abortsOnToolExecution() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-test")
        defer { dir.remove() }
        let agent = fixture("tool", directory: dir)
        _ = try await agent.connect()
        await #expect(throws: ACPError.unexpectedTool) { _ = try await agent.prompt("A prompt") { _ in } }
    }

    @Test func sendsLargePromptBeyondPipeBufferWithoutEAGAINFailure() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-large-prompt")
        defer { dir.remove() }
        let script = #"""
        set -eu
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"big"}}'
        IFS= read -r line
        bytes=${#line}
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"big\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"$bytes\"}}}}"
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        IFS= read -r line || true
        """#
        let agent = ACPClient(launch: ACPLaunchConfiguration(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: ["-c", script],
            directory: dir.url,
            environment: ["PATH": "/usr/bin:/bin"],
            clientName: "fixture",
            isolation: .unrestricted
        ), requestTimeout: .seconds(3), turnTimeout: .seconds(3))
        _ = try await agent.connect()
        let largePrompt = String(repeating: "a", count: 28_000)
        let transcript = Transcript()
        let reason = try await agent.prompt(largePrompt) { await transcript.append($0) }
        #expect(reason == "end_turn")
        let receivedBytes = Int(await transcript.text) ?? 0
        #expect(receivedBytes > 28_000)
        await agent.close()
    }

    @Test func allowsToolsWithoutFilesystemAccess() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-tools-only")
        defer { dir.remove() }
        let script = #"""
        set -eu
        IFS= read -r line
        [[ "$line" == *'"clientCapabilities":{}'* ]] || exit 10
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"tools-demo"}}'
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"tools-demo","update":{"sessionUpdate":"tool_call","title":"web_search","status":"in_progress"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":"perm-1","method":"session/request_permission","params":{"sessionId":"tools-demo","options":[{"optionId":"opt-allow","kind":"allow_once","name":"Allow"}]}}'
        IFS= read -r line
        [[ "$line" == *'"perm-1"'* && "$line" == *'"opt-allow"'* ]] || exit 11
        printf '%s\n' '{"jsonrpc":"2.0","id":"fs-1","method":"fs/read_text_file","params":{"sessionId":"tools-demo","path":"/etc/hosts"}}'
        IFS= read -r line
        [[ "$line" == *'"fs-1"'* && "$line" == *'-32601'* ]] || exit 12
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"tools-demo","update":{"sessionUpdate":"tool_call_update","status":"completed"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"tools-demo","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Found via web_search"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        IFS= read -r line || true
        """#
        let client = ACPClient(
            launch: ACPLaunchConfiguration(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", script],
                directory: dir.url,
                environment: ["PATH": "/usr/bin:/bin"],
                clientName: "fixture",
                isolation: .unrestricted,
                access: .tools(autoApproveTools: true)
            ),
            requestTimeout: .seconds(2),
            turnTimeout: .seconds(2)
        )
        _ = try await client.connect()
        actor Collector {
            var tools: [String?] = []
            var text = ""
            func addTool(_ t: String?) { tools.append(t) }
            func addText(_ s: String) { text += s }
        }
        let collector = Collector()
        let reason = try await client.prompt("Search news", onTool: { await collector.addTool($0) }, onChunk: { await collector.addText($0) })
        #expect(reason == "end_turn")
        #expect(await collector.tools == ["web_search", nil])
        #expect(await collector.text == "Found via web_search")
        await client.close()
    }
}
