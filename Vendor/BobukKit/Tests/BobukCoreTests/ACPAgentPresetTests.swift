import BobukCore
import BobukTestSupport
import Foundation
import Testing

@Suite struct ACPAgentPresetTests {
    private func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @Test func catalogContainsPopularAgentsWithUniqueIDs() {
        let ids = ACPAgentPreset.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ["antigravity", "codex", "claude", "pi", "kimi", "gemini", "opencode"] {
            let preset = ACPAgentPreset.named(id)
            #expect(preset != nil)
            #expect(preset?.executables.isEmpty == false)
            #expect(preset?.installHint.isEmpty == false)
        }
    }

    @Test func autoDetectsInstalledAgentsInOrder() throws {
        let dir = try TemporaryDirectory(prefix: "acp-presets-detect")
        defer { dir.remove() }
        let home = dir.url
        try makeExecutable(at: home.appendingPathComponent(".kimi-code/bin/kimi"))
        try makeExecutable(at: home.appendingPathComponent(".pi/agent/bin/pi-acp"))
        try makeExecutable(at: home.appendingPathComponent(".local/bin/claude-code-acp"))

        let emptyEnv: [String: String] = ["PATH": ""]
        let detected = ACPAgentPreset.detectInstalled(in: ACPAgentPreset.all, home: home, environment: emptyEnv)
        #expect(detected.map(\.id) == ["claude", "pi", "kimi"])
        #expect(ACPAgentPreset.preferredAvailable(in: ACPAgentPreset.all, home: home, environment: emptyEnv) == .claude)
    }

    @Test func detectsReadyNeedsAdapterAndNotInstalledSeparately() throws {
        let dir = try TemporaryDirectory(prefix: "acp-presets-status")
        defer { dir.remove() }
        let home = dir.url
        let extraBin = dir.url.appendingPathComponent("custom-bin")
        try makeExecutable(at: home.appendingPathComponent(".gemini/antigravity-cli/bin/agy"))
        try makeExecutable(at: home.appendingPathComponent(".local/bin/claude"))
        try makeExecutable(at: extraBin.appendingPathComponent("codex"))
        try makeExecutable(at: home.appendingPathComponent(".nvm/versions/node/v22.5.0/bin/pi"))
        try makeExecutable(at: home.appendingPathComponent(".local/share/mise/installs/gemini-cli/latest/bin/gemini"))

        let env: [String: String] = ["PATH": extraBin.path]
        let statuses = ACPAgentPreset.detectAll(in: ACPAgentPreset.all, home: home, environment: env)
        let byID = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })

        #expect(byID["antigravity"]?.isReady == true)
        #expect(byID["gemini"]?.isReady == true)
        #expect(byID["codex"]?.needsACPAdapter == true)
        #expect(byID["codex"]?.cliURL?.lastPathComponent == "codex")
        #expect(byID["claude"]?.needsACPAdapter == true)
        #expect(byID["claude"]?.cliURL?.lastPathComponent == "claude")
        #expect(byID["pi"]?.needsACPAdapter == true)
        #expect(byID["kimi"]?.availability == .notInstalled)
        #expect(byID["opencode"]?.availability == .notInstalled)

        // Launching an agent whose CLI is present without its ACP adapter throws acpAdapterMissing.
        let workspace = dir.url.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        #expect(throws: ACPAgentLaunchError.acpAdapterMissing(agent: "Claude", installHint: ACPAgentPreset.claude.installHint)) {
            _ = try ACPAgentPreset.claude.launch(in: workspace, clientName: "test", home: home, environment: env)
        }
    }

    @Test func detectsAgentsFromNpmrcPrefixAndPreservesShimName() throws {
        let dir = try TemporaryDirectory(prefix: "acp-presets-npmrc")
        defer { dir.remove() }
        let home = dir.url
        let npmPrefix = home.appendingPathComponent("my-npm-global")
        try "prefix=~/my-npm-global\n".write(to: home.appendingPathComponent(".npmrc"), atomically: true, encoding: .utf8)
        try makeExecutable(at: npmPrefix.appendingPathComponent("bin/codex-acp"))

        // Also test a shim symlink pointing to a multi-call 'mise' binary.
        let miseBin = dir.url.appendingPathComponent("mise")
        try makeExecutable(at: miseBin)
        let shimsDir = home.appendingPathComponent(".local/share/mise/shims")
        try FileManager.default.createDirectory(at: shimsDir, withIntermediateDirectories: true)
        let geminiShim = shimsDir.appendingPathComponent("gemini")
        try FileManager.default.createSymbolicLink(at: geminiShim, withDestinationURL: miseBin)

        let env: [String: String] = ["PATH": ""]
        let codexURL = ACPAgentPreset.codex.resolveExecutable(home: home, environment: env)
        #expect(codexURL?.lastPathComponent == "codex-acp")

        let geminiURL = ACPAgentPreset.gemini.resolveExecutable(home: home, environment: env)
        #expect(geminiURL?.lastPathComponent == "gemini")
    }

    @Test func installsACPAdapterUsingNPMAndDetectsResult() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-adapter-install")
        defer { dir.remove() }
        let home = dir.url
        let binDir = home.appendingPathComponent(".local/bin")
        let fakeNPM = binDir.appendingPathComponent("npm")
        let script = """
        #!/bin/sh
        set -eu
        echo "installing $*"
        if [ "$1" = "install" ] && [ "$2" = "-g" ] && [ "$3" = "@agentclientprotocol/codex-acp" ]; then
            printf '#!/bin/sh\\nexit 0\\n' > "\(binDir.path)/codex-acp"
            chmod 755 "\(binDir.path)/codex-acp"
            exit 0
        fi
        echo "unexpected args: $*" >&2
        exit 2
        """
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: fakeNPM)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeNPM.path)

        let env: [String: String] = ["PATH": "", "BOBUK_ACP_NPM_PATH": fakeNPM.path]
        actor OutputLog {
            var chunks: [String] = []
            func add(_ s: String) { chunks.append(s) }
            func joined() -> String { chunks.joined() }
        }
        let log = OutputLog()
        let installedURL = try await ACPAgentPreset.codex.installACPAdapter(
            home: home,
            environment: env,
            onOutput: { await log.add($0) }
        )
        #expect(installedURL.lastPathComponent == "codex-acp")
        #expect(await log.joined().contains("@agentclientprotocol/codex-acp"))
        #expect(ACPAgentPreset.codex.detectAvailability(home: home, environment: ["PATH": ""]) == .ready(executableURL: installedURL))

        // Agents with built-in ACP do not use npm adapter installation.
        do {
            _ = try await ACPAgentPreset.kimi.installACPAdapter(home: home, environment: env)
            Issue.record("Expected notApplicable for kimi")
        } catch let error as ACPAdapterInstallError {
            #expect(error == .notApplicable(agent: "Kimi"))
        }
    }

    @Test func overrideAndMissingErrors() throws {
        let dir = try TemporaryDirectory(prefix: "acp-presets-override")
        defer { dir.remove() }
        let workspace = dir.url.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let nonexistentPreset = ACPAgentPreset(
            id: "nonexistent-test",
            name: "Nonexistent",
            executables: ["bobuk-nonexistent-acp-binary"],
            cliExecutables: ["bobuk-nonexistent-cli-binary"],
            arguments: [],
            overrideVariable: "BOBUK_ACP_NONEXISTENT_PATH",
            installHint: "Install Nonexistent."
        )
        #expect(throws: ACPAgentLaunchError.notInstalled(agent: "Nonexistent", installHint: "Install Nonexistent.")) {
            _ = try nonexistentPreset.launch(in: workspace, clientName: "test", home: dir.url, environment: ["PATH": ""])
        }

        #expect(throws: ACPAgentLaunchError.invalidOverride(variable: "BOBUK_ACP_CODEX_PATH")) {
            _ = try ACPAgentPreset.codex.launch(
                in: workspace,
                clientName: "test",
                home: dir.url,
                environment: ["BOBUK_ACP_CODEX_PATH": "/nonexistent/codex-acp"]
            )
        }

        let custom = dir.url.appendingPathComponent("custom-codex")
        try makeExecutable(at: custom)
        let direct = try ACPAgentPreset.codex.launch(
            in: workspace,
            sandboxed: false,
            clientName: "test",
            home: dir.url,
            environment: ["BOBUK_ACP_CODEX_PATH": custom.path]
        )
        if case .unrestricted = direct.isolation {} else { Issue.record("Expected unrestricted launch") }
        #expect(direct.executable.lastPathComponent == "custom-codex")
    }

    @Test func sandboxAllowsOpenedDirectoryAndBlocksUnrelatedUserFolders() throws {
        let dir = try TemporaryDirectory(prefix: "acp-presets-sandbox")
        defer { dir.remove() }
        let home = dir.url
        let openedFolder = home.appendingPathComponent("Documents/MyProject")
        let downloads = home.appendingPathComponent("Downloads")
        let state = home.appendingPathComponent(".kimi")
        let projectFile = openedFolder.appendingPathComponent("note.txt")
        let secretFile = downloads.appendingPathComponent("secret.txt")
        try FileManager.default.createDirectory(at: openedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("project\n".utf8).write(to: projectFile)
        try Data("private\n".utf8).write(to: secretFile)

        let profile = ACPAgentPreset.kimi.sandboxProfile(home: home, directory: openedFolder, access: .workspace())
        let worker = Process()
        worker.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        worker.arguments = ["-p", profile, "/bin/bash", "-c", #"""
            if cat "$1" >/dev/null 2>&1; then exit 11; fi
            if printf x > "$1" 2>/dev/null; then exit 12; fi
            [[ "$(cat "$2")" == "project" ]] || exit 13
            printf ok > "$3/out.txt" || exit 14
            printf ok > "$4/state.txt" || exit 15
            /usr/bin/python3 -c 'import os, pty; m, s = pty.openpty(); os.close(m); os.close(s)' || exit 16
            """#, "fixture", secretFile.path, projectFile.path, openedFolder.path, state.path]
        worker.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        worker.currentDirectoryURL = openedFolder
        worker.standardOutput = FileHandle.nullDevice
        worker.standardError = FileHandle.nullDevice
        try worker.run()
        worker.waitUntilExit()
        #expect(worker.terminationStatus == 0)
        #expect(try String(contentsOf: openedFolder.appendingPathComponent("out.txt"), encoding: .utf8) == "ok")
        #expect(try String(contentsOf: state.appendingPathComponent("state.txt"), encoding: .utf8) == "ok")
    }

    @Test func workspaceAccessHandlesScopedReadWriteAndToolApproval() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-workspace-mode")
        defer { dir.remove() }
        let workspace = dir.url.appendingPathComponent("project")
        let outside = dir.url.appendingPathComponent("outside.txt")
        let inside = workspace.appendingPathComponent("readme.md")
        let written = workspace.appendingPathComponent("created.txt")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("line1\nline2\nline3\n".utf8).write(to: inside)
        try Data("nope\n".utf8).write(to: outside)

        let script = #"""
        set -eu
        IFS= read -r line
        [[ "$line" == *'"readTextFile":true'* && "$line" == *'"writeTextFile":true'* ]] || exit 10
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"ws"}}'
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ws","update":{"sessionUpdate":"tool_call","title":"Reading file","status":"in_progress"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":"p1","method":"session/request_permission","params":{"sessionId":"ws","options":[{"optionId":"opt-allow","kind":"allow_once","name":"Allow"}]}}'
        IFS= read -r line
        [[ "$line" == *'"p1"'* && "$line" == *'"opt-allow"'* ]] || exit 11
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":\"r1\",\"method\":\"fs/read_text_file\",\"params\":{\"sessionId\":\"ws\",\"path\":\"$1\",\"line\":2,\"limit\":1}}"
        IFS= read -r line
        [[ "$line" == *'"r1"'* && "$line" == *'"line2"'* ]] || exit 12
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":\"r2\",\"method\":\"fs/read_text_file\",\"params\":{\"sessionId\":\"ws\",\"path\":\"$2\"}}"
        IFS= read -r line
        [[ "$line" == *'"r2"'* && "$line" == *'"error"'* ]] || exit 13
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":\"w1\",\"method\":\"fs/write_text_file\",\"params\":{\"sessionId\":\"ws\",\"path\":\"$3\",\"content\":\"hello\"}}"
        IFS= read -r line
        [[ "$line" == *'"w1"'* && "$line" == *'"result"'* ]] || exit 14
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ws","update":{"sessionUpdate":"tool_call_update","status":"completed"}}}'
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"ws","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Done"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        IFS= read -r line || true
        """#

        let client = ACPClient(
            launch: ACPLaunchConfiguration(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: ["-c", script, "fixture", inside.path, outside.path, written.path],
                directory: workspace,
                environment: ["PATH": "/usr/bin:/bin"],
                clientName: "test",
                isolation: .unrestricted,
                access: .workspace(allowWrite: true, autoApproveTools: true)
            ),
            requestTimeout: .seconds(3),
            turnTimeout: .seconds(3)
        )
        _ = try await client.connect()
        actor Collector {
            var tools: [String?] = []
            var text = ""
            func addTool(_ t: String?) { tools.append(t) }
            func addText(_ s: String) { text += s }
        }
        let collector = Collector()
        let reason = try await client.prompt("Inspect workspace", onTool: { await collector.addTool($0) }, onChunk: { await collector.addText($0) })
        #expect(reason == "end_turn")
        #expect(await collector.text == "Done")
        #expect(await collector.tools == ["Reading file", nil])
        #expect(try String(contentsOf: written, encoding: .utf8) == "hello")
        await client.close()
    }

    @Test func headlessAskSelectsModelAndEffortAndReturnsResponse() async throws {
        let dir = try TemporaryDirectory(prefix: "acp-headless-ask")
        defer { dir.remove() }
        let fakeAgent = dir.url.appendingPathComponent("fake-acp")
        let script = #"""
        #!/bin/bash
        set -eu
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1}}'
        IFS= read -r line
        cfg='[{"type":"select","category":"model","id":"model","currentValue":"m-fast","options":[{"value":"m-fast","name":"Fast"},{"value":"m-smart","name":"Smart Model"}]},{"type":"select","category":"thought_level","id":"thought_level","currentValue":"medium","options":[{"value":"low","name":"Low"},{"value":"medium","name":"Medium"},{"value":"high","name":"High"}]}]'
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"s1\",\"configOptions\":$cfg}}"
        IFS= read -r line
        [[ "$line" == *'"configId":"model"'* && "$line" == *'"value":"m-smart"'* ]] || exit 21
        cfg=${cfg/\"currentValue\":\"m-fast\"/\"currentValue\":\"m-smart\"}
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"configOptions\":$cfg}}"
        IFS= read -r line
        [[ "$line" == *'"configId":"thought_level"'* && "$line" == *'"value":"high"'* ]] || exit 22
        cfg=${cfg/\"currentValue\":\"medium\"/\"currentValue\":\"high\"}
        printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":4,\"result\":{\"configOptions\":$cfg}}"
        IFS= read -r line
        [[ "$line" == *'"session\/prompt"'* ]] || exit 23
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"**Answer:** 42"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":5,"result":{"stopReason":"end_turn"}}'
        IFS= read -r line || true
        """#
        try Data(script.utf8).write(to: fakeAgent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeAgent.path)

        let response = try await ACPAgentPreset.codex.ask(
            "What is the answer?",
            in: dir.url,
            options: ACPPromptOptions(model: "smart", effort: "high", sandboxed: false, access: .textOnly),
            clientName: "test",
            home: dir.url,
            environment: ["BOBUK_ACP_CODEX_PATH": fakeAgent.path, "PATH": "/usr/bin:/bin"]
        )
        #expect(response.text == "**Answer:** 42")
        #expect(response.stopReason == "end_turn")
        #expect(response.model == "m-smart")
        #expect(response.effort == "high")

        // Also verify probeCapabilities reads models & efforts cleanly and closes the subprocess.
        let probed = try await ACPAgentPreset.codex.probeCapabilities(
            sandboxed: false,
            clientName: "test-probe",
            home: dir.url,
            environment: ["BOBUK_ACP_CODEX_PATH": fakeAgent.path, "PATH": "/usr/bin:/bin"]
        )
        #expect(probed.models?.current == "m-fast")
        #expect(probed.models?.choices.count == 2)
        #expect(probed.efforts?.current == "medium")
        #expect(probed.efforts?.choices.map(\.id) == ["low", "medium", "high"])
    }
}
