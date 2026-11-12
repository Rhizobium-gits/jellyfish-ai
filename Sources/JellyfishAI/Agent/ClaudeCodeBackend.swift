import Foundation

/// Claude Code CLI を `-p --output-format stream-json` で起動するバックエンド。
///
/// 権限：`--permission-mode auto`（Claude Code 公式の Auto Mode。毎回の確認なしで自律実行し、
/// 認証情報の持ち出しや取り返しのつかない操作などは Claude Code 側の安全判定が止める）。
/// `--permission-prompts none` で、確認が必要になった操作は待たずに拒否される（無人で固まらない）。
/// いずれも `claude --help`（2.1.322）に存在するオプションだけを使っている。
final class ClaudeCodeBackend: AgentBackend {
    let install: ClaudeInstall
    let permissionMode: String
    let model: String?
    var executable: URL { install.url }

    /// 指定モードが auto でも、そのバージョンが auto を持たなければ acceptEdits に落とす（存在しないオプションは付けない）
    init(install: ClaudeInstall, permissionMode: String = "auto", model: String? = nil) {
        self.install = install
        self.permissionMode = Self.effectiveMode(permissionMode, install: install)
        self.model = model
    }

    /// 設定ファイル（settings.json）に書いてあっても使わないモード。Claude Code の安全判定がすべて外れるため。
    /// settings.json はエージェントからも書き換えられるので、ここで止める（すべてのクラゲの権限が一度に広がらないように）
    static let refusedModes: Set<String> = ["bypassPermissions"]

    /// 実際に付ける --permission-mode。使わないモードや、その版の --help に無いモードは auto にする
    static func effectiveMode(_ requested: String, install: ClaudeInstall) -> String {
        let known = install.permissionModes
        var m = requested
        let listed = known.isEmpty ? ["auto", "acceptEdits", "plan"].contains(m) : known.contains(m)
        if refusedModes.contains(m) || !listed { m = "auto" }
        if m == "auto" && !install.supportsAutoMode { m = "acceptEdits" }
        return m
    }

    /// 設定の permissionMode を使わずに置き換えたか（メニューの「実行ポリシー」に出す）
    static func refusedSetting(_ requested: String, install: ClaudeInstall) -> Bool {
        let m = effectiveMode(requested, install: install)
        return m != requested && !(requested == "auto" && m == "acceptEdits")
    }

    var engine: AgentEngine { .claude }
    var assignsSessionID: Bool { false }
    var displayName: String { "Claude Code" }
    var defaultModel: String? { model }

    var policyDescription: String {
        permissionMode == "auto" ? "Auto Mode" : "mode: \(permissionMode)"
    }

    func run(prompt: String, sessionID: String, resume: Bool, cwd: URL, logDir: URL,
             options: AgentRunOptions,
             onEvent: @escaping (AgentEvent) -> Void,
             onExit: @escaping (Int32, String) -> Void) throws -> AgentHandle {
        // --resume / --session-id に渡す ID は UUID の形だけ（オプションとして解釈される文字列を渡さない）
        guard UUID(uuidString: sessionID) != nil else { throw POSIXError(.EINVAL) }
        let p = Process()
        p.executableURL = executable
        var args = ["-p",
                    "--output-format", "stream-json", "--verbose",
                    "--permission-mode", permissionMode]
        if install.supportsPermissionPrompts { args += ["--permission-prompts", "none"] }
        args += resume ? ["--resume", sessionID] : ["--session-id", sessionID]
        // 「自動」は AgentRuntime が依頼ごとに選んだモデルに置き換えている。万一残っていても claude には渡さない
        if let m = options.model ?? model, m != ModelRouter.auto { args += ["--model", m] }
        if let e = options.effort, install.supportsEffort { args += ["--effort", e] }
        // 外部の MCP サーバーを読み込まない（Jellyfish の --mcp-config だけになる）
        if options.strictMCPConfig, install.supportsStrictMCPConfig { args += ["--strict-mcp-config"] }
        // チーム機能（--mcp-config と --allowedTools は値を複数取るので、後ろに別のオプションが続く並びにする）
        if let mcp = options.mcpConfig, install.supportsMCPConfig {
            args += ["--mcp-config", mcp.path]
            if install.supportsAllowedTools, !options.allowedTools.isEmpty {
                args += ["--allowedTools", options.allowedTools.joined(separator: ",")]
            }
        }
        if let sp = options.appendSystemPrompt, !sp.isEmpty, install.supportsAppendSystemPrompt {
            args += ["--append-system-prompt", sp]
        }
        // 指示は最後に「--」のあとで渡す。「- README を直して」のように - で始まる指示がオプションと
        // 間違われない（claude 2.1.322 で確認：-p の直後に置くと unknown option になる）
        args += ["--", prompt]
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = ShellEnvironment.shared.agentEnvironment().merging(options.env) { _, new in new }
        p.standardInput = FileHandle.nullDevice

        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let eventsURL = logDir.appendingPathComponent("events.jsonl")
        // 生イベント（調査用）は 4MB を超えたら 1 世代だけ残して入れ替える（ツールの結果を含むので際限なく溜めない）
        LogRotation.rotate(eventsURL, maxBytes: 4_000_000)
        if !FileManager.default.fileExists(atPath: eventsURL.path) {
            FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        }
        let eventsLog = try? FileHandle(forWritingTo: eventsURL)
        eventsLog?.seekToEndOfFile()

        let parser = StreamJSONParser(onEvent: onEvent)
        let stderrBox = StderrBuffer()

        out.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            guard !data.isEmpty else { return }
            eventsLog?.write(data)
            parser.feed(data)
        }
        err.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty { stderrBox.append(data) }
        }

        let handle = ClaudeHandle(process: p)
        p.terminationHandler = { proc in
            // 残りの出力を読み切ってから終了を通知（イベントの順序を保つ）
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
        return handle
    }
}

final class ClaudeHandle: AgentHandle {
    private let process: Process
    init(process: Process) { self.process = process }

    var isRunning: Bool { process.isRunning }
    var processID: Int32? { process.isRunning ? process.processIdentifier : nil }

    /// まず SIGINT（Claude Code が後始末できる）、3 秒で終わらなければ SIGTERM
    func cancel() {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { process.terminate() }
        }
    }
}

final class StderrBuffer {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); if data.count > 64_000 { data = data.suffix(32_000) }; lock.unlock() }
    func tail() -> String {
        lock.lock(); defer { lock.unlock() }
        let s = String(decoding: data.suffix(4000), as: UTF8.self)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// stream-json（1 行 1 JSON）を AgentEvent に変換する
final class StreamJSONParser {
    private var buffer = Data()
    private let lock = NSLock()
    private let onEvent: (AgentEvent) -> Void

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
        lines.forEach(handleLine)
    }

    func flush() {
        lock.lock()
        let rest = buffer
        buffer.removeAll()
        lock.unlock()
        if !rest.isEmpty { handleLine(rest) }
    }

    private func emit(_ e: AgentEvent) { DispatchQueue.main.async { self.onEvent(e) } }

    private func handleLine(_ line: Data) {
        guard !line.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "system":
            if (obj["subtype"] as? String) == "init" {
                emit(.started(session: obj["session_id"] as? String, model: obj["model"] as? String,
                              permissionMode: obj["permissionMode"] as? String))
            }
        case "assistant":
            let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for c in content {
                switch c["type"] as? String {
                case "text":
                    if let t = c["text"] as? String, !t.isEmpty { emit(.text(t)) }
                case "thinking", "redacted_thinking":
                    emit(.thinking)
                case "tool_use":
                    let name = c["name"] as? String ?? "tool"
                    emit(.toolStarted(name: name, summary: StreamJSONParser.summarize(name, c["input"] as? [String: Any])))
                default: break
                }
            }
        case "user":
            let content = ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            for c in content where (c["type"] as? String) == "tool_result" {
                emit(.toolFinished(isError: (c["is_error"] as? Bool) ?? false))
            }
        case "result":
            let subtype = obj["subtype"] as? String ?? ""
            let isError = (obj["is_error"] as? Bool) ?? false
            var result = obj["result"] as? String ?? ""
            if result.isEmpty, let errs = obj["errors"] as? [Any] { result = errs.map { "\($0)" }.joined(separator: "\n") }
            if result.isEmpty && subtype != "success" { result = subtype }
            emit(.finished(success: subtype == "success" && !isError, result: result,
                           costUSD: obj["total_cost_usd"] as? Double, durationMs: obj["duration_ms"] as? Int))
        default:
            break
        }
    }

    /// ツール呼び出しを 1 行の説明にする（パネルの「いま何をしているか」表示用）
    static func summarize(_ name: String, _ input: [String: Any]?) -> String {
        // チーム機能のツールは日本語の 1 行に
        if name.hasPrefix("mcp__jellyfish__") {
            let short = { (s: String?) -> String in
                let one = (s ?? "").replacingOccurrences(of: "\n", with: " ")
                return one.count > 60 ? String(one.prefix(60)) + "…" : one
            }
            switch name.dropFirst("mcp__jellyfish__".count) {
            case "assign_task": return L("🤝 %@ に依頼: %@", input?["to"] as? String ?? L("仲間"), short(input?["task"] as? String))
            case "create_teammate":
                let who = input?["name"] as? String ?? ""
                return (input?["task"] as? String).map { L("✨ 仲間「%@」を作る: %@", who, short($0)) } ?? L("✨ 仲間「%@」を作る", who)
            case "wait_for_tasks": return L("⏳ 仲間の結果を待っています")
            case "list_team": return L("👥 チームを確認")
            default: break
            }
        }
        guard let input else { return name }
        let keys = ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt"]
        for k in keys {
            if let v = input[k] as? String, !v.isEmpty {
                let one = v.replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
                let short = one.count > 80 ? String(one.prefix(80)) + "…" : one
                return "\(name): \(short)"
            }
        }
        return name
    }
}
