import Foundation
import Testing
@testable import JellyfishAI

// Claude 以外の AI（Codex CLI・Gemini CLI）と、勝手に課金しないための決まりのテスト

func describe(_ e: AgentEvent) -> String {
    switch e {
    case .started(let s, let m, let p): return "started \(s ?? "-") \(m ?? "-") \(p ?? "-")"
    case .text(let t): return "text \(t)"
    case .thinking: return "thinking"
    case .toolStarted(let n, let s): return "tool \(n) | \(s)"
    case .toolFinished(let err): return "done \(err ? "error" : "ok")"
    case .finished(let ok, let r, _, _): return "finished \(ok) \(r)"
    case .usage(let m, let i, let o, let c): return "usage \(m ?? "-") \(i)/\(o)/\(c)"
    }
}

func obj(_ s: String) -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(s.utf8)) as! [String: Any] }

@Suite struct CodexTests {
    @Test func readsExecJSONEvents() {
        // 公式の例（codex exec --json）に沿った行
        let p = CodexEventParser(onEvent: { _ in })
        let lines = [
            #"{"type":"thread.started","thread_id":"0199a213-81c0-7800-8aa1-bbab2a035a53"}"#,
            #"{"type":"turn.started"}"#,
            #"{"type":"item.started","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","status":"in_progress"}}"#,
            #"{"type":"item.completed","item":{"id":"item_1","type":"command_execution","command":"bash -lc ls","status":"completed","exit_code":0}}"#,
            #"{"type":"item.completed","item":{"id":"item_2","type":"file_change","changes":[{"path":"a.md","kind":"add"}],"status":"completed"}}"#,
            #"{"type":"item.completed","item":{"id":"item_3","type":"agent_message","text":"できました"}}"#,
            #"{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122}}"#,
        ]
        let got = lines.flatMap { p.handle(obj($0)) }.map(describe)
        #expect(got == [
            "started 0199a213-81c0-7800-8aa1-bbab2a035a53 - workspace-write",
            "thinking",
            "tool Bash | Bash: bash -lc ls",
            "done ok",
            "tool Edit | Edit: a.md", "done ok",
            "text できました",
            "usage - 24763/122/24448",
            "finished true できました",
        ])
    }

    @Test func failedTurnsAndCommands() {
        let p = CodexEventParser(onEvent: { _ in })
        #expect(p.handle(obj(#"{"type":"item.completed","item":{"id":"x","type":"command_execution","command":"false","status":"failed","exit_code":1}}"#)).map(describe)
                == ["tool Bash | Bash: false", "done error"])
        #expect(p.handle(obj(#"{"type":"turn.failed","error":{"message":"usage limit"}}"#)).map(describe) == ["finished false usage limit"])
        let q = CodexEventParser(onEvent: { _ in })
        _ = q.handle(obj(#"{"type":"error","message":"stream disconnected"}"#))
        #expect(q.endedWithoutResult().map(describe) == "finished false stream disconnected")
    }

    @Test func argumentsUseTheSandboxAndNeverBypass() {
        let new = CodexBackend.arguments(prompt: "- README を直して", sessionID: nil, model: nil)
        #expect(new == ["exec", "--json", "--skip-git-repo-check", "--config", #"sandbox_mode="workspace-write""#,
                        "--config", #"approval_policy="never""#, "--", "- README を直して"])
        let id = "0199a213-81c0-7800-8aa1-bbab2a035a53"
        let resume = CodexBackend.arguments(prompt: "続き", sessionID: id, model: "gpt-5")
        #expect(Array(resume.prefix(2)) == ["exec", "resume"])
        #expect(Array(resume.suffix(3)) == ["--", id, "続き"])
        #expect(resume.contains("--model"))
        for a in [new, resume] {
            #expect(!a.contains { $0.contains("dangerously") || $0.contains("danger-full-access") || $0.contains("approve-for-me") })
        }
    }

    @Test func loginStatus() {
        #expect(EngineAuth.codexStatus("Logged in using ChatGPT\n").usable)
        #expect(EngineAuth.codexStatus("Not logged in\n").login == .loggedOut)
        if case .paidAPI = EngineAuth.codexStatus("Logged in using an API key - sk-proj-***\n").login {} else { Issue.record("API key should be paid") }
        if case .paidAPI = EngineAuth.codexStatus("Logged in using Amazon Bedrock API key").login {} else { Issue.record("Bedrock should be paid") }
        if case .unknown = EngineAuth.codexStatus("").login {} else { Issue.record("empty should be unknown") }
    }
}

@Suite struct GeminiTests {
    @Test func readsStreamJSONEvents() {
        // gemini -o stream-json の形（init / message delta / tool_use / tool_result / result）
        let p = GeminiEventParser(onEvent: { _ in })
        let lines = [
            #"{"type":"init","timestamp":"2026-11-12T00:00:00Z","session_id":"6c1d3f1e-2b8a-4c55-9d7e-1a2b3c4d5e6f","model":"gemini-pro"}"#,
            #"{"type":"message","role":"user","content":"hi"}"#,
            #"{"type":"tool_use","tool_name":"write_file","tool_id":"t1","parameters":{"file_path":"/tmp/a.md","content":"x"}}"#,
            #"{"type":"tool_result","tool_id":"t1","status":"success","output":"ok"}"#,
            #"{"type":"message","role":"assistant","content":"でき","delta":true}"#,
            #"{"type":"message","role":"assistant","content":"ました","delta":true}"#,
            #"{"type":"result","status":"success","stats":{}}"#,
        ]
        let got = lines.flatMap { p.handle(obj($0)) }.map(describe)
        #expect(got == [
            "started 6c1d3f1e-2b8a-4c55-9d7e-1a2b3c4d5e6f gemini-pro auto_edit",
            "tool write_file | write_file: /tmp/a.md", "done ok",
            "text でき", "text できました",
            "finished true できました",
        ])
        let q = GeminiEventParser(onEvent: { _ in })
        #expect(q.handle(obj(#"{"type":"result","status":"error","error":{"type":"x","message":"quota"}}"#)).map(describe) == ["finished false quota"])
    }

    @Test func argumentsKeepTrustAndApprovals() {
        let id = "6c1d3f1e-2b8a-4c55-9d7e-1a2b3c4d5e6f"
        let new = GeminiBackend.arguments(prompt: "-v を説明して", sessionID: id, resume: false, model: nil)
        #expect(new == ["--output-format", "stream-json", "--approval-mode", "auto_edit", "--session-id", id, "--prompt=-v を説明して"])
        let resume = GeminiBackend.arguments(prompt: "続き", sessionID: id, resume: true, model: nil)
        #expect(resume.contains("--resume") && !resume.contains("--session-id"))
        for a in [new, resume] {
            #expect(!a.contains { $0 == "--yolo" || $0 == "-y" || $0 == "yolo" || $0 == "--skip-trust" })
        }
    }

    @Test func loginFromSettingsFile() {
        let oauth = Data(#"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#.utf8)
        #expect(EngineAuth.geminiStatus(settings: oauth, hasOAuthCredentials: true).usable)
        #expect(EngineAuth.geminiStatus(settings: oauth, hasOAuthCredentials: false).login == .loggedOut)
        #expect(EngineAuth.geminiStatus(settings: nil, hasOAuthCredentials: false).login == .loggedOut)
        for t in ["gemini-api-key", "vertex-ai", "compute-default-credentials"] {
            let d = Data(#"{"security":{"auth":{"selectedType":"\#(t)"}}}"#.utf8)
            if case .paidAPI = EngineAuth.geminiStatus(settings: d, hasOAuthCredentials: true).login {} else { Issue.record("\(t) should be paid") }
        }
        // 古い書き方
        let legacy = Data(#"{"selectedAuthType":"gemini-api-key"}"#.utf8)
        if case .paidAPI = EngineAuth.geminiStatus(settings: legacy, hasOAuthCredentials: false).login {} else { Issue.record("legacy api key") }
    }
}

@Suite struct BillingTests {
    @Test func claudeSubscriptionOnly() {
        let sub = Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"a@b.c","subscriptionType":"max","planTier":"max_20x"}"#.utf8)
        let s = EngineAuth.claudeStatus(sub)
        #expect(s.usable)
        #expect(s.account == "a@b.c · Claude Max 20x")
        let console = Data(#"{"loggedIn":true,"authMethod":"console","apiProvider":"firstParty"}"#.utf8)
        if case .paidAPI = EngineAuth.claudeStatus(console).login {} else { Issue.record("console should be paid") }
        let bedrock = Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}"#.utf8)
        if case .paidAPI = EngineAuth.claudeStatus(bedrock).login {} else { Issue.record("bedrock should be paid") }
        #expect(EngineAuth.claudeStatus(Data(#"{"loggedIn":false}"#.utf8)).login == .loggedOut)
    }

    @Test func apiKeysAreNotPassedUnlessAllowed() {
        let env = ["PATH": "/bin", "ANTHROPIC_API_KEY": "x", "OPENAI_API_KEY": "y", "CODEX_API_KEY": "z", "GEMINI_API_KEY": "w",
                   "GOOGLE_API_KEY": "v", "GOOGLE_GENAI_USE_VERTEXAI": "true", "HOME": "/Users/x"]
        let clean = BillingGuard.sanitized(env, allowAPI: false)
        #expect(clean == ["PATH": "/bin", "HOME": "/Users/x"])
        #expect(BillingGuard.sanitized(env, allowAPI: true) == env)
    }

    @Test func preflightRefusesPaidLoginsUnlessAllowed() {
        let paid = EngineStatus(login: .paidAPI("API key"))
        for e in AgentEngine.allCases {
            #expect(JellyManager.preflightMessage(e, paid, allowAPI: false) != nil)
            #expect(JellyManager.preflightMessage(e, paid, allowAPI: true) == nil)
            #expect(JellyManager.preflightMessage(e, EngineStatus(login: .subscription), allowAPI: false) == nil)
            #expect(JellyManager.preflightMessage(e, EngineStatus(login: .loggedOut), allowAPI: true) != nil)
            #expect(JellyManager.preflightMessage(e, EngineStatus(login: .notInstalled), allowAPI: false) != nil)
        }
    }

    @Test func loginScriptsUseSubscriptionLogins() {
        let cli = URL(fileURLWithPath: "/opt/homebrew/bin/x y")
        let claude = EngineLogin.script(.claude, cli: cli, folder: nil, allowAPI: false)
        #expect(claude.contains("auth login --claudeai"))
        #expect(!claude.contains("--console"))
        #expect(claude.contains("unset ANTHROPIC_API_KEY"))
        #expect(claude.contains("'/opt/homebrew/bin/x y'"))
        let codex = EngineLogin.script(.codex, cli: cli, folder: nil, allowAPI: false)
        #expect(codex.contains("' login") && !codex.contains("--with-api-key"))
        let gemini = EngineLogin.script(.gemini, cli: cli, folder: URL(fileURLWithPath: "/tmp/it's"), allowAPI: false)
        #expect(gemini.contains(#"cd '/tmp/it'\''s'"#))
        #expect(!gemini.contains("--skip-trust") && !gemini.contains("yolo"))
        #expect(!EngineLogin.script(.claude, cli: cli, folder: nil, allowAPI: true).contains("unset"))
    }
}


@Suite struct HandoffAndUsageTests {
    let dir = URL(fileURLWithPath: "/Users/x/Library/Application Support/JellyfishAI/handoff/20261112-agent1-ab12")

    @Test func handoffFoldersReachEveryEngine() {
        // Codex：exec resume には --add-dir が無いので、サンドボックスの書けるフォルダとして設定で渡す
        let c = CodexBackend.arguments(prompt: "p", sessionID: nil, model: nil, addDirs: [dir])
        #expect(c.contains(#"sandbox_workspace_write.writable_roots=["/Users/x/Library/Application Support/JellyfishAI/handoff/20261112-agent1-ab12"]"#))
        let r = CodexBackend.arguments(prompt: "p", sessionID: "0199a213-81c0-7800-8aa1-bbab2a035a53", model: nil, addDirs: [dir])
        #expect(r.contains { $0.hasPrefix("sandbox_workspace_write.writable_roots=") })
        #expect(Array(r.suffix(3)) == ["--", "0199a213-81c0-7800-8aa1-bbab2a035a53", "p"])
        // 引用符・バックスラッシュは TOML の文字列としてエスケープする
        let odd = CodexBackend.arguments(prompt: "p", sessionID: nil, model: nil, addDirs: [URL(fileURLWithPath: #"/tmp/a"b\c"#)])
        #expect(odd.contains(#"sandbox_workspace_write.writable_roots=["/tmp/a\"b\\c"]"#))
        // Gemini：ワークスペースに入れる
        let g = GeminiBackend.arguments(prompt: "p", sessionID: "6c1d3f1e-2b8a-4c55-9d7e-1a2b3c4d5e6f", resume: false, model: nil, addDirs: [dir])
        #expect(g.contains("--include-directories") && g.contains(dir.path))
        #expect(g.last == "--prompt=p")
        #expect(CodexBackend.arguments(prompt: "p", sessionID: nil, model: nil).allSatisfy { !$0.contains("writable_roots") })
    }

    @Test func tokenUsageFromEachCLI() {
        let claude = StreamJSONParser(onEvent: { _ in })
        _ = claude
        let g = GeminiEventParser(onEvent: { _ in })
        let line = #"{"type":"result","status":"success","stats":{"total_tokens":150,"input_tokens":120,"output_tokens":30,"cached":20,"models":{"gemini-pro":{"total_tokens":150,"input_tokens":120,"output_tokens":30,"cached":20,"input":100}}}}"#
        #expect(g.handle(obj(line)).map(describe) == ["usage gemini-pro 120/30/20", "finished true "])
    }

    @Test func ledgerSumsByEngineModelAndAccount() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("jf-usage-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: f) }
        let l = UsageLedger(url: f)
        let now = Date()
        let old = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        l.add(engine: .claude, model: "claude-opus-5-5", account: "claude#abc", input: 1000, output: 50, cached: 900, now: now)
        l.add(engine: .claude, model: "claude-opus-5-5", account: "claude#abc", input: 2000, output: 70, cached: 0, now: now)
        l.add(engine: .codex, model: nil, account: "ChatGPT", input: 300, output: 30, cached: 0, now: now)
        l.add(engine: .gemini, model: "gemini-pro", account: "Google", input: 10, output: 1, cached: 0, now: old)
        let rows = l.recent(days: 7, now: now)
        #expect(rows.map(\.engine) == [.claude, .codex])
        #expect(rows[0].count == UsageLedger.Count(calls: 2, input: 3000, output: 120, cached: 900))
        #expect(rows[1].model == "-")
        #expect(l.recent(days: 30, now: now).count == 3)
        l.flush()
        #expect(UsageLedger(url: f).recent(days: 30, now: now).count == 3)
        #expect(UsageLedger.short(1_234_567) == "1.2M" && UsageLedger.short(45_000) == "45k" && UsageLedger.short(1234) == "1.2k" && UsageLedger.short(12) == "12")
    }

    @Test func strengthsDescribeWhatEachEngineCanDoHere() {
        // 動かし方から決まること（Codex はネットワークなし、Gemini はコマンドを実行しない）を案内に書いている
        #expect(AgentEngine.codex.teamStrengths.contains("ネットワーク"))
        #expect(AgentEngine.gemini.teamStrengths.contains("コマンド"))
        #expect(AgentEngine.claude.teamStrengths.contains("リーダー"))
    }
}

@Suite struct ClaudeUsageTests {
    final class Box: @unchecked Sendable { var events: [String] = [] }

    @Test func modelUsageFromResult() async throws {
        let box = Box()
        let p = StreamJSONParser(onEvent: { box.events.append(describe($0)) })
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"OK","modelUsage":{"claude-haiku-5-5":{"inputTokens":2,"outputTokens":4,"cacheReadInputTokens":11391,"cacheCreationInputTokens":11203}}}"#
        p.feed(Data((line + "\n").utf8))
        try await Task.sleep(for: .milliseconds(150))
        await MainActor.run {}
        #expect(box.events == ["usage claude-haiku-5-5 22596/4/22594", "finished true OK"])
    }
}

@Suite struct EngineModelTests {
    @Test func codexCatalogListsVisibleModelsInOrder() {
        // codex debug models の形（実際の出力から必要なところだけ）
        let json = #"""
        {"models":[
          {"slug":"gpt-6-astra","display_name":"GPT-6-Astra","visibility":"list","priority":2,"description":"Frontier intelligence.","supported_reasoning_levels":[{"effort":"low"},{"effort":"high"},{"effort":"ultra"}]},
          {"slug":"codex-auto-review","display_name":"Codex Auto Review","visibility":"hide","priority":10,"supported_reasoning_levels":[]},
          {"slug":"gpt-6.1-sol","display_name":"GPT-6.1-Sol","visibility":"list","priority":1,"description":"Latest workhorse.","supported_reasoning_levels":[{"effort":"low"},{"effort":"medium"}]}
        ]}
        """#
        let m = EngineModels.parseCodex(Data(json.utf8))
        #expect(m.map(\.id) == ["gpt-6.1-sol", "gpt-6-astra"])
        #expect(m[0].name == "GPT-6.1-Sol" && m[0].detail == "Latest workhorse.")
        #expect(m[1].efforts == ["low", "high", "ultra"])
        #expect(EngineModels.parseCodex(Data("{}".utf8)).isEmpty)
    }

    @Test func geminiModelsFromCLI() {
        // gemini models -o json の出力
        let json = #"""
        [{"modelId":"auto","id":"auto","name":"Auto","displayName":"Auto","description":"Let Gemini CLI decide the best model for the task"},
         {"modelId":"gemini-2.5-pro","id":"gemini-2.5-pro","name":"gemini-2.5-pro","displayName":"gemini-2.5-pro","description":""}]
        """#
        let m = EngineModels.parseGemini(Data(json.utf8))
        #expect(m.map(\.id) == ["auto", "gemini-2.5-pro"])
        #expect(m[0].name == "Auto" && m[1].detail == nil && m[1].efforts.isEmpty)
    }

    @Test func modelAndEffortArguments() {
        let c = CodexBackend.arguments(prompt: "p", sessionID: nil, model: "gpt-6.1-sol", effort: "high")
        #expect(c.contains("--model") && c.contains("gpt-6.1-sol"))
        #expect(c.contains(#"model_reasoning_effort="high""#))
        // 英小文字以外の強さは渡さない
        let bad = CodexBackend.arguments(prompt: "p", sessionID: nil, model: nil, effort: #"high" sandbox_mode="danger-full-access"#)
        #expect(!bad.contains { $0.contains("model_reasoning_effort") || $0.contains("danger") })
        // Gemini の「auto」は Gemini のモデルの id なので、そのまま渡す
        let g = GeminiBackend.arguments(prompt: "p", sessionID: "6c1d3f1e-2b8a-4c55-9d7e-1a2b3c4d5e6f", resume: false, model: "auto")
        #expect(g.contains("--model") && g.contains("auto"))
    }

    @Test func picksTheNewestVersion() {
        #expect(CLILocator.versionParts("0.162.0-alpha.2") == [0, 162, 0])
        #expect(CLILocator.versionParts("0.167.2").lexicographicallyPrecedes([0, 168]))
        #expect(CLILocator.versionParts("0.162.0-alpha.2").lexicographicallyPrecedes(CLILocator.versionParts("0.167.2")))
    }
}

@Suite struct TeamToolsOnOtherEnginesTests {
    let bridge = (command: "/Applications/JellyfishAI.app/Contents/MacOS/JellyfishAI",
                  args: ["--mcp-bridge", "/Users/x/Library/Application Support/JellyfishAI/bus.sock", "0B1E0000-0000-4000-8000-000000000001"])
    let tools = ["list_team", "assign_task", "create_teammate", "wait_for_tasks"]

    @Test func codexGetsJellyfishMCPForThisRunOnly() {
        let a = CodexBackend.arguments(prompt: "p", sessionID: nil, model: nil, mcp: bridge, tools: tools,
                                       instructions: "# Jellyfish チーム\n\"仲間\" に頼む\\")
        #expect(a.contains(#"mcp_servers.jellyfish.command="/Applications/JellyfishAI.app/Contents/MacOS/JellyfishAI""#))
        #expect(a.contains(#"mcp_servers.jellyfish.args=["--mcp-bridge","/Users/x/Library/Application Support/JellyfishAI/bus.sock","0B1E0000-0000-4000-8000-000000000001"]"#))
        #expect(a.contains(#"mcp_servers.jellyfish.enabled_tools=["list_team","assign_task","create_teammate","wait_for_tasks"]"#))
        // 確認なしにするのは jellyfish のサーバーのツールだけ
        #expect(a.contains(#"mcp_servers.jellyfish.default_tools_approval_mode="approve""#))
        #expect(!a.contains { $0.hasPrefix("approval_policy=") && !$0.contains("never") })
        #expect(!a.contains { $0.contains("dangerously") || $0.contains("danger-full-access") })
        // 改行・引用符・バックスラッシュは TOML の文字列としてエスケープ
        #expect(a.contains(##"developer_instructions="# Jellyfish チーム\n\"仲間\" に頼む\\""##))
        #expect(a.suffix(2) == ["--", "p"])
        // チームのツールが無ければ足さない
        #expect(!CodexBackend.arguments(prompt: "p", sessionID: nil, model: nil, mcp: bridge, tools: []).contains { $0.contains("mcp_servers") })
    }

    @Test func tomlEscapesControlCharacters() {
        #expect(CodexBackend.toml("a\tb\u{1}") == #""a\tb\u0001""#)
        #expect(CodexBackend.tomlArray([]) == "[]")
    }

    @Test func geminiDefaultsKeepExistingServersAndSettings() throws {
        let existing = Data(#"{"mcpServers":{"figma":{"command":"figma-mcp"}},"ui":{"theme":"dark"}}"#.utf8)
        let d = try #require(GeminiBackend.systemDefaults(existing: existing, command: bridge.command, args: bridge.args, tools: tools))
        let o = try #require(try JSONSerialization.jsonObject(with: d) as? [String: Any])
        let servers = try #require(o["mcpServers"] as? [String: Any])
        #expect(servers["figma"] != nil)
        let j = try #require(servers["jellyfish"] as? [String: Any])
        #expect(j["command"] as? String == bridge.command)
        #expect(j["includeTools"] as? [String] == tools)
        #expect((o["ui"] as? [String: Any])?["theme"] as? String == "dark")
        #expect(GeminiBackend.systemDefaults(existing: nil, command: "x", args: [], tools: tools) != nil)
    }

    @Test func geminiPolicyAllowsOnlyJellyfishTools() {
        #expect(GeminiBackend.policyTOML.contains(#"mcpName = "jellyfish""#))
        #expect(GeminiBackend.policyTOML.contains(#"decision = "allow""#))
        #expect(!GeminiBackend.policyTOML.contains("run_shell_command"))
        let p = URL(fileURLWithPath: "/tmp/agent/gemini-jellyfish-policy.toml")
        let a = GeminiBackend.arguments(prompt: "p", sessionID: "6c1d3f1e-2b8a-4c55-9d7e-1a2b3c4d5e6f", resume: false, model: nil, policy: p)
        #expect(a.contains("--policy") && a.contains(p.path))
        #expect(!a.contains { $0 == "--yolo" || $0 == "yolo" || $0 == "--skip-trust" })
    }
}
