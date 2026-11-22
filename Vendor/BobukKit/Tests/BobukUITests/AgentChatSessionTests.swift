import BobukCore
import BobukTestSupport
import BobukUI
import Foundation
import Testing

@MainActor struct AgentChatSessionTests {
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
}
