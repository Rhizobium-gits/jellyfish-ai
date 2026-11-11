import Foundation

/// 1 回の指示とその結果
struct AgentTurn: Codable {
    var prompt: String
    var startedAt: Date
    var endedAt: Date?
    var state: AgentState
    var result: String?
    var error: String?
    var costUSD: Double?
    var tools: [String] = []
}

/// クラゲ1体ぶんのエージェント。セッション・プロセス・履歴・ログ・作業フォルダを他と共有しない。
/// 各ターンは独立した OS プロセスなので、1体が落ちても他のクラゲには影響しない。
final class AgentRuntime {
    let agentID: UUID
    let dir: URL
    private(set) var turns: [AgentTurn] = []
    private(set) var sessionID: String
    private(set) var sessionStarted: Bool
    private(set) var cwd: URL
    /// クラゲごとのモデル・強さ（nil = 既定）
    var model: String? { didSet { saveMeta() } }
    var effort: String? { didSet { saveMeta() } }

    /// 現在の動作の 1 行説明（「Bash: npm test」など）
    private(set) var activity: String?
    /// 実際に使われたモデル（Claude Code の init イベントから）
    private(set) var activeModel: String?
    private(set) var permissionMode: String?
    private var cachedSessionFile: URL?
    private var cachedTitle: (date: Date, title: String)?
    private(set) var lastError: String?

    var onState: ((AgentState) -> Void)?
    var onUpdate: (() -> Void)?
    /// ターンが終わったとき（チームの依頼の結果を返すのに使う）
    var onTurnEnded: ((AgentTurn) -> Void)?
    /// 実行ごとのチーム設定（MCP・system prompt）。nil を返せばチーム機能なしで動く
    var teamConfig: (() -> TeamCoordinator.RunConfig?)?

    private var handle: AgentHandle?
    private var pendingTools = 0
    private var cancelRequested = false
    private var gotResult = false
    private let backendProvider: () -> AgentBackend?

    var isRunning: Bool { handle != nil }

    init(agentID: UUID, baseDir: URL, backendProvider: @escaping () -> AgentBackend?) {
        self.agentID = agentID
        self.backendProvider = backendProvider
        dir = baseDir.appendingPathComponent("agents/\(agentID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let meta = AgentRuntime.loadMeta(dir)
        sessionID = meta?.sessionID ?? UUID().uuidString.lowercased()
        sessionStarted = meta?.sessionStarted ?? false
        cwd = URL(fileURLWithPath: meta?.cwd ?? FileManager.default.homeDirectoryForCurrentUser.path, isDirectory: true)
        model = meta?.model
        effort = meta?.effort
        turns = AgentRuntime.loadTurns(dir)
        // 前回アプリ終了時に実行中だったターンは中断扱い
        if let last = turns.last, !last.state.isTerminal && last.state != .error {
            turns[turns.count - 1].state = .error
            turns[turns.count - 1].error = "アプリの終了により中断されました"
            turns[turns.count - 1].endedAt = Date()
            saveTurns()
        }
        saveMeta()
    }

    var lastTurn: AgentTurn? { turns.last }

    /// 指示を送る（実行中なら何もしない）
    @discardableResult
    func submit(_ prompt: String) -> Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return false }
        guard let backend = backendProvider() else {
            lastError = "claude コマンドが見つかりません（設定で claudePath を指定してください）"
            turns.append(AgentTurn(prompt: text, startedAt: Date(), endedAt: Date(), state: .error, error: lastError))
            saveTurns()
            onState?(.error)
            onUpdate?()
            return false
        }
        turns.append(AgentTurn(prompt: text, startedAt: Date(), state: .thinking))
        saveTurns()
        pendingTools = 0
        cancelRequested = false
        gotResult = false
        activity = "考えています…"
        lastError = nil
        onState?(.thinking)
        onUpdate?()

        let resume = sessionStarted
        var opts = AgentRunOptions(model: model, effort: effort)
        if let t = teamConfig?() {
            opts.mcpConfig = t.mcpConfig
            opts.appendSystemPrompt = t.systemPrompt
            opts.allowedTools = t.allowedTools
            opts.env = t.env
        }
        do {
            handle = try backend.run(prompt: text, sessionID: sessionID, resume: resume, cwd: cwd, logDir: dir,
                                     options: opts,
                                     onEvent: { [weak self] e in self?.handle(e) },
                                     onExit: { [weak self] status, err in self?.exited(status: status, stderr: err) })
            AppLog.write("agent \(agentID.uuidString.prefix(8)) run resume=\(resume) model=\(model ?? "-") effort=\(effort ?? "-") cwd=\(cwd.path)")
        } catch {
            finish(.error, error: "起動に失敗しました: \(error.localizedDescription)")
        }
        return true
    }

    func cancel() {
        guard let h = handle else { return }
        cancelRequested = true
        activity = "キャンセルしています…"
        onUpdate?()
        h.cancel()
    }

    /// 直前の指示をもう一度
    func retry() {
        guard !isRunning, let last = turns.last else { return }
        submit(last.prompt)
    }

    // MARK: - イベント → 状態（実イベントだけで判定）

    private func handle(_ e: AgentEvent) {
        guard !turns.isEmpty else { return }
        let i = turns.count - 1
        switch e {
        case .started(let session, let model, let mode):
            if let s = session, s == sessionID { sessionStarted = true; saveMeta() }
            self.activeModel = model
            self.permissionMode = mode
        case .thinking:
            if pendingTools == 0 { setTurnState(.thinking); activity = "考えています…" }
        case .text(let t):
            if pendingTools == 0 { setTurnState(.thinking) }
            activity = String(t.replacingOccurrences(of: "\n", with: " ").prefix(90))
        case .toolStarted(let name, let summary):
            pendingTools += 1
            turns[i].tools.append(name)
            activity = summary
            setTurnState(.working)
        case .toolFinished:
            pendingTools = max(0, pendingTools - 1)
            if pendingTools == 0 { setTurnState(.thinking) }
        case .finished(let success, let result, let cost, _):
            gotResult = true
            turns[i].result = result
            turns[i].costUSD = cost
            if cancelRequested {
                turns[i].state = .cancelled
            } else {
                turns[i].state = success ? .completed : .error
                if !success { turns[i].error = result }
            }
        }
        onUpdate?()
    }

    private func setTurnState(_ s: AgentState) {
        guard let last = turns.last, last.state != s else { return }
        turns[turns.count - 1].state = s
        onState?(s)
    }

    private func exited(status: Int32, stderr: String) {
        handle = nil
        guard let last = turns.last else { return }
        if cancelRequested {
            finish(.cancelled, error: nil)
        } else if gotResult {
            finish(last.state == .completed ? .completed : .error, error: last.error)
        } else {
            let msg = stderr.isEmpty ? "プロセスが終了しました（コード \(status)）" : stderr
            finish(.error, error: msg)
        }
    }

    private func finish(_ s: AgentState, error: String?) {
        handle = nil
        if !turns.isEmpty {
            let i = turns.count - 1
            turns[i].state = s
            turns[i].endedAt = Date()
            if let error { turns[i].error = error }
        }
        activity = nil
        lastError = error
        saveTurns()
        onState?(s)
        onUpdate?()
        if let t = turns.last { onTurnEnded?(t) }
    }

    // MARK: - Claude Code のセッション記録

    /// このクラゲの会話が残っている Claude Code のセッションファイル
    var sessionFile: URL? {
        guard sessionStarted else { return nil }
        if let f = cachedSessionFile, FileManager.default.fileExists(atPath: f.path) { return f }
        cachedSessionFile = ClaudeSessions.file(for: sessionID)
        return cachedSessionFile
    }

    /// Claude Code が付けたセッションのタイトル（更新時刻で キャッシュ）
    var sessionTitle: String? {
        guard let f = sessionFile else { return nil }
        let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let c = cachedTitle, c.date == m { return c.title }
        guard let info = ClaudeSessions.info(file: f, modified: m), info.title != "（無題のセッション）" else { return nil }
        cachedTitle = (m, info.title)
        return info.title
    }

    /// 作業フォルダを変える。Claude Code のセッションはフォルダ（プロジェクト）ごとに保存されるので新しいセッションになる
    func changeFolder(_ url: URL) {
        guard !isRunning, url.standardizedFileURL != cwd.standardizedFileURL else { return }
        cwd = url
        sessionID = UUID().uuidString.lowercased()
        sessionStarted = false
        cachedSessionFile = nil
        cachedTitle = nil
        saveMeta()
        onUpdate?()
    }

    /// 既存の Claude Code セッション（過去のプロジェクト）をこのクラゲで続ける
    func bind(to info: ClaudeSessionInfo) {
        guard !isRunning else { return }
        sessionID = info.id
        sessionStarted = true
        cachedSessionFile = info.file
        cachedTitle = nil
        if let c = info.cwd { cwd = URL(fileURLWithPath: c, isDirectory: true) }
        saveMeta()
        onUpdate?()
    }

    // MARK: - 永続化

    private struct Meta: Codable {
        var sessionID: String; var sessionStarted: Bool; var cwd: String
        var model: String?; var effort: String?
    }

    private static func loadMeta(_ dir: URL) -> Meta? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: d)
    }

    private func saveMeta() {
        let m = Meta(sessionID: sessionID, sessionStarted: sessionStarted, cwd: cwd.path, model: model, effort: effort)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: dir.appendingPathComponent("meta.json"), options: .atomic) }
    }

    private static func loadTurns(_ dir: URL) -> [AgentTurn] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("history.json")) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([AgentTurn].self, from: d)) ?? []
    }

    private func saveTurns() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(turns) { try? d.write(to: dir.appendingPathComponent("history.json"), options: .atomic) }
    }

    /// クラゲ削除時、実行中でなければ記録ごと消す
    func deleteFiles() {
        try? FileManager.default.removeItem(at: dir)
    }
}
