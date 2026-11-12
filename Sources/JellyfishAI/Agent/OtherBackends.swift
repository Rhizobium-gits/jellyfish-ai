import Foundation

/// Codex CLI・Gemini CLI を 1 ターンずつ起動して、出てくる JSONL を AgentEvent にする。
/// - どちらも安全側の公式オプションだけを使う（危ない「全部許可」系は付けない）
///   Codex：サンドボックス workspace-write（作業フォルダの中だけ書ける・ネットワークなし）、承認は求めない（never）
///   Gemini：approval-mode auto_edit（作業フォルダの中の編集だけ自動承認。シェルのコマンドは実行されない）。フォルダの信頼の確認は飛ばさない
/// - Jellyfish のチーム・PC 操作・自律組織（MCP）は Claude Code だけ。ここでは渡さない
/// - 子プロセスには API キーの環境変数を渡さない（BillingGuard）

/// 子プロセスを起動して、標準出力を行ごとにパーサへ渡す（Claude Code と同じ流れ）
enum CLIProcess {
    static func start(executable: URL, args: [String], cwd: URL, env: [String: String], logDir: URL,
                      parser: JSONLParser, onExit: @escaping (Int32, String) -> Void) throws -> AgentHandle {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let eventsURL = logDir.appendingPathComponent("events.jsonl")
        LogRotation.rotate(eventsURL, maxBytes: 4_000_000)
        if !FileManager.default.fileExists(atPath: eventsURL.path) { FileManager.default.createFile(atPath: eventsURL.path, contents: nil) }
        let eventsLog = try? FileHandle(forWritingTo: eventsURL)
        eventsLog?.seekToEndOfFile()
        let stderrBox = StderrBuffer()
        out.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            guard !d.isEmpty else { return }
            eventsLog?.write(d)
            parser.feed(d)
        }
        err.fileHandleForReading.readabilityHandler = { fh in
            let d = fh.availableData
            if !d.isEmpty { stderrBox.append(d) }
        }
        p.terminationHandler = { proc in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            if !rest.isEmpty { eventsLog?.write(rest); parser.feed(rest) }
            parser.flush()
            stderrBox.append(err.fileHandleForReading.readDataToEndOfFile())
            try? eventsLog?.close()
            let status = proc.terminationStatus
            let tail = stderrBox.tail()
            DispatchQueue.main.async { onExit(status, tail) }
        }
        try p.run()
        return ClaudeHandle(process: p)
    }
}

/// 1 行 1 JSON を受けて handle(_:) に渡す。イベントはメインスレッドで onEvent へ
class JSONLParser {
    private var buffer = Data()
    private let lock = NSLock()
    let onEvent: (AgentEvent) -> Void
    private var finishedSent = false

    init(onEvent: @escaping (AgentEvent) -> Void) { self.onEvent = onEvent }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for l in lines { line(l) }
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { line(rest) }
        if !finishedSent, let e = endedWithoutResult() { emit(e) }
    }

    private func line(_ d: Data) {
        guard !d.isEmpty, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        for e in handle(o) { emit(e) }
    }

    func emit(_ e: AgentEvent) {
        if case .finished = e { finishedSent = true }
        DispatchQueue.main.async { self.onEvent(e) }
    }

    /// サブクラス：1 行ぶんのイベント
    func handle(_ o: [String: Any]) -> [AgentEvent] { [] }
    /// 終わりの合図が来ないまま出力が終わったとき（エラーの内容があればそれで終える）
    func endedWithoutResult() -> AgentEvent? { nil }

    /// ツールの 1 行の説明（Claude Code のときと同じ形）
    static func summary(_ name: String, _ detail: String?) -> String {
        guard let d = detail?.replacingOccurrences(of: "\n", with: " "), !d.isEmpty else { return name }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let one = d.replacingOccurrences(of: home, with: "~")
        return "\(name): " + (one.count > 80 ? String(one.prefix(80)) + "…" : one)
    }
}

// MARK: - Codex

/// `codex exec --json` のイベント：thread.started / turn.started / item.started・item.completed / turn.completed / turn.failed / error
final class CodexEventParser: JSONLParser {
    private var lastMessage = ""
    private var lastError: String?
    private var openTools = Set<String>()

    override func handle(_ o: [String: Any]) -> [AgentEvent] {
        switch o["type"] as? String ?? "" {
        case "thread.started":
            return [.started(session: o["thread_id"] as? String, model: nil, permissionMode: "workspace-write")]
        case "turn.started":
            return [.thinking]
        case "item.started", "item.updated":
            guard let item = o["item"] as? [String: Any] else { return [] }
            let type = item["type"] as? String ?? ""
            if type == "reasoning" { return [.thinking] }
            guard let tool = CodexEventParser.toolInfo(item), let id = item["id"] as? String, !openTools.contains(id) else { return [] }
            openTools.insert(id)
            return [.toolStarted(name: tool.name, summary: JSONLParser.summary(tool.name, tool.detail))]
        case "item.completed":
            guard let item = o["item"] as? [String: Any] else { return [] }
            let type = item["type"] as? String ?? ""
            if type == "agent_message", let t = item["text"] as? String, !t.isEmpty {
                lastMessage = t
                return [.text(t)]
            }
            if type == "reasoning" { return [.thinking] }
            if type == "error", let m = item["message"] as? String { lastError = m; return [] }
            guard let tool = CodexEventParser.toolInfo(item) else { return [] }
            let id = item["id"] as? String ?? UUID().uuidString
            let failed = (item["status"] as? String) == "failed" || ((item["exit_code"] as? Int).map { $0 != 0 } ?? false)
            var out: [AgentEvent] = []
            if !openTools.contains(id) { out.append(.toolStarted(name: tool.name, summary: JSONLParser.summary(tool.name, tool.detail))) }
            openTools.remove(id)
            out.append(.toolFinished(isError: failed))
            return out
        case "turn.completed":
            return [.finished(success: true, result: lastMessage, costUSD: nil, durationMs: nil)]
        case "turn.failed":
            let m = ((o["error"] as? [String: Any])?["message"] as? String) ?? lastError ?? "turn.failed"
            return [.finished(success: false, result: m, costUSD: nil, durationMs: nil)]
        case "error":
            lastError = o["message"] as? String ?? lastError
            return []
        default:
            return []
        }
    }

    override func endedWithoutResult() -> AgentEvent? {
        lastError.map { .finished(success: false, result: $0, costUSD: nil, durationMs: nil) }
    }

    /// ツールにあたる項目と、その 1 行の説明
    static func toolInfo(_ item: [String: Any]) -> (name: String, detail: String?)? {
        switch item["type"] as? String ?? "" {
        case "command_execution": return ("Bash", item["command"] as? String)
        case "file_change":
            let paths = (item["changes"] as? [[String: Any]])?.compactMap { $0["path"] as? String }
            return ("Edit", paths?.joined(separator: ", "))
        case "mcp_tool_call":
            let name = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: ".")
            return ("MCP", name.isEmpty ? nil : name)
        case "web_search": return ("WebSearch", item["query"] as? String)
        default: return nil
        }
    }
}

final class CodexBackend: AgentBackend {
    let install: CLIInstall
    let model: String?

    init(install: CLIInstall, model: String?) {
        self.install = install
        self.model = model
    }

    var engine: AgentEngine { .codex }
    var displayName: String { "Codex CLI" }
    var defaultModel: String? { model }
    var policyDescription: String { "Codex · workspace-write" }
    /// Codex は会話の ID を自分で決める（thread.started で受け取る）
    var assignsSessionID: Bool { true }

    /// 引数（テストあり）。新しい会話は `exec`、続きは `exec resume <id>`。プロンプトは「--」のあと
    static func arguments(prompt: String, sessionID: String?, model: String?) -> [String] {
        var a = ["exec"]
        if sessionID != nil { a.append("resume") }
        a += ["--json", "--skip-git-repo-check",
              "--config", #"sandbox_mode="workspace-write""#,
              "--config", #"approval_policy="never""#]
        if let m = model, !m.isEmpty { a += ["--model", m] }
        a.append("--")
        if let s = sessionID { a.append(s) }
        a.append(prompt)
        return a
    }

    func run(prompt: String, sessionID: String, resume: Bool, cwd: URL, logDir: URL, options: AgentRunOptions,
             onEvent: @escaping (AgentEvent) -> Void, onExit: @escaping (Int32, String) -> Void) throws -> AgentHandle {
        guard !resume || UUID(uuidString: sessionID) != nil else { throw POSIXError(.EINVAL) }
        let m = options.model ?? model
        let args = CodexBackend.arguments(prompt: prompt, sessionID: resume ? sessionID : nil, model: m == ModelRouter.auto ? nil : m)
        return try CLIProcess.start(executable: install.url, args: args, cwd: cwd, env: ShellEnvironment.shared.agentEnvironment(),
                                    logDir: logDir, parser: CodexEventParser(onEvent: onEvent), onExit: onExit)
    }
}

// MARK: - Gemini

/// `gemini -o stream-json` のイベント：init / message（assistant は delta）/ tool_use / tool_result / error / result
final class GeminiEventParser: JSONLParser {
    private var text = ""
    private var lastError: String?

    override func handle(_ o: [String: Any]) -> [AgentEvent] {
        switch o["type"] as? String ?? "" {
        case "init":
            return [.started(session: o["session_id"] as? String, model: o["model"] as? String, permissionMode: "auto_edit")]
        case "message":
            guard o["role"] as? String == "assistant", let c = o["content"] as? String, !c.isEmpty else { return [] }
            if o["delta"] as? Bool == true { text += c } else { text = c }
            return [.text(text)]
        case "tool_use":
            let name = o["tool_name"] as? String ?? "tool"
            let p = o["parameters"] as? [String: Any]
            let detail = ["command", "file_path", "absolute_path", "path", "pattern", "query", "url"].lazy.compactMap { p?[$0] as? String }.first
            return [.toolStarted(name: name, summary: JSONLParser.summary(name, detail))]
        case "tool_result":
            return [.toolFinished(isError: (o["status"] as? String) == "error")]
        case "error":
            lastError = o["message"] as? String ?? lastError
            return []
        case "result":
            let ok = (o["status"] as? String) == "success"
            let err = ((o["error"] as? [String: Any])?["message"] as? String) ?? lastError
            return [.finished(success: ok, result: ok ? text : (err ?? text), costUSD: nil, durationMs: nil)]
        default:
            return []
        }
    }

    override func endedWithoutResult() -> AgentEvent? {
        lastError.map { .finished(success: false, result: $0, costUSD: nil, durationMs: nil) }
    }
}

final class GeminiBackend: AgentBackend {
    let install: CLIInstall
    let model: String?

    init(install: CLIInstall, model: String?) {
        self.install = install
        self.model = model
    }

    var engine: AgentEngine { .gemini }
    var displayName: String { "Gemini CLI" }
    var defaultModel: String? { model }
    var policyDescription: String { "Gemini · auto_edit" }
    var assignsSessionID: Bool { false }

    /// 引数（テストあり）。会話の ID は Jellyfish が決めて --session-id で渡し、続きは --resume <id>。
    /// プロンプトは --prompt=… の形で渡す（「-」で始まる指示がオプションと間違われない）
    static func arguments(prompt: String, sessionID: String, resume: Bool, model: String?) -> [String] {
        var a = ["--output-format", "stream-json", "--approval-mode", "auto_edit"]
        a += resume ? ["--resume", sessionID] : ["--session-id", sessionID]
        if let m = model, !m.isEmpty { a += ["--model", m] }
        a.append("--prompt=" + prompt)
        return a
    }

    func run(prompt: String, sessionID: String, resume: Bool, cwd: URL, logDir: URL, options: AgentRunOptions,
             onEvent: @escaping (AgentEvent) -> Void, onExit: @escaping (Int32, String) -> Void) throws -> AgentHandle {
        guard UUID(uuidString: sessionID) != nil else { throw POSIXError(.EINVAL) }
        let m = options.model ?? model
        let args = GeminiBackend.arguments(prompt: prompt, sessionID: sessionID, resume: resume, model: m == ModelRouter.auto ? nil : m)
        return try CLIProcess.start(executable: install.url, args: args, cwd: cwd, env: ShellEnvironment.shared.agentEnvironment(),
                                    logDir: logDir, parser: GeminiEventParser(onEvent: onEvent), onExit: onExit)
    }
}
