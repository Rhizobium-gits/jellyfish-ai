import AppKit

/// エージェントを動かす AI（エンジン）。どれもユーザーの Mac に入っている公式の CLI を、その CLI のログインのまま動かす。
/// Jellyfish は API キーを持たず、受け取らず、保存しない（ログインは各 CLI の公式のログイン画面で本人が行う）
enum AgentEngine: String, Codable, CaseIterable {
    case claude, codex, gemini

    /// メニュー・チャットに出す名前
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "ChatGPT（Codex）"
        case .gemini: return "Gemini"
        }
    }

    var cliName: String { rawValue }

    /// CLI の名前つき（案内用）
    var cliTitle: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        }
    }

    /// 公式の案内（インストールのしかた）
    var setupURL: URL {
        switch self {
        case .claude: return URL(string: "https://code.claude.com/docs/en/setup")!
        case .codex: return URL(string: "https://github.com/openai/codex")!
        case .gemini: return URL(string: "https://github.com/google-gemini/gemini-cli")!
        }
    }

    /// インストールのコマンドの例（案内に出すだけ。Jellyfish は実行しない）
    var installCommand: String {
        switch self {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: return "npm install -g @openai/codex"
        case .gemini: return "npm install -g @google/gemini-cli"
        }
    }

    /// 使うアカウント（サブスクリプション）の名前
    var accountKind: String {
        switch self {
        case .claude: return L("Claude のアカウント（Pro / Max など）")
        case .codex: return L("ChatGPT のアカウント（Plus / Pro など）")
        case .gemini: return L("Google アカウント")
        }
    }

    /// Jellyfish の機能のうち、このエンジンで使えるもの（チーム・PC 操作・自律組織・外部 MCP は Claude Code の仕組みを使う）
    var supportsJellyfishTools: Bool { self == .claude }

    /// 実行ポリシーの説明（確認なしで何をするか）
    var policyLine: String {
        switch self {
        case .claude: return L("Claude Code の Auto モード（確認なしで実行し、危ない操作は Claude Code の安全判定が止める）")
        case .codex: return L("Codex のサンドボックス（作業フォルダの中だけ書き込める・ネットワークなし・権限の追加は求めない）")
        case .gemini: return L("Gemini の auto_edit（作業フォルダの中の編集だけ自動で承認し、コマンドは実行しない）")
        }
    }
}

/// 勝手に課金しないための決まり（Claude も同じ）
/// - 子プロセスに API キー・クラウドの課金先を指す環境変数を渡さない（シェルの設定に書いてあっても）
/// - CLI が API キー（従量課金）でログインしているときは使わない。ユーザーがメニューで許可したときだけ使う
enum BillingGuard {
    /// これがあると CLI が従量課金の API・クラウドで動く
    /// ユーザーがメニューで「API キー（従量課金）での利用を許可」したか（設定の allowAPIBilling。既定は許可しない）
    static var allowAPI: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _allowAPI }
        set { lock.lock(); _allowAPI = newValue; lock.unlock() }
    }
    private static var _allowAPI = false
    private static let lock = NSLock()

    static let apiEnvKeys: [String] = [
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN",
        "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
        "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_APPLICATION_CREDENTIALS",
    ]

    static func sanitized(_ env: [String: String], allowAPI: Bool) -> [String: String] {
        guard !allowAPI else { return env }
        var e = env
        for k in apiEnvKeys { e.removeValue(forKey: k) }
        return e
    }
}

/// ログインの状態（資格情報の中身は読まない。CLI の状態表示と、Gemini は設定ファイルの「どの方法でログインしたか」だけ）
struct EngineStatus: Equatable {
    enum Login: Equatable {
        case notInstalled
        /// 入っているが、Jellyfish が使うオプションが無い古い版
        case unsupported(String)
        case loggedOut
        /// サブスクリプション（アカウント）でログイン
        case subscription
        /// API キー・クラウドの課金でログイン（従量課金）
        case paidAPI(String)
        /// 確かめられなかった
        case unknown(String)
    }
    var login: Login
    var version: String?
    var path: String?
    /// メール・プランなど（分かるものだけ）
    var account: String?

    var usable: Bool { if case .subscription = login { return true }; return false }

    var summary: String {
        switch login {
        case .notInstalled: return L("入っていません")
        case .unsupported(let why): return L("この版では使えません（%@）", why)
        case .loggedOut: return L("ログインしていません")
        case .subscription: return account.map { L("ログイン済み（%@）", $0) } ?? L("ログイン済み")
        case .paidAPI(let how): return L("⚠️ %@（従量課金）でログイン中", how)
        case .unknown(let why): return L("確かめられませんでした（%@）", why)
        }
    }
}

/// Codex CLI・Gemini CLI を探す（PATH・よくある置き場所。--version と --help で使えるか確かめる）
struct CLIInstall: Equatable {
    let engine: AgentEngine
    let url: URL
    let version: String
    /// Jellyfish が使うオプションがそろっているか（足りなければその理由）
    let missing: String?
}

enum CLILocator {
    private static var cache: [AgentEngine: (CLIInstall?, Date)] = [:]
    private static let lock = NSLock()

    static func find(_ e: AgentEngine, override: String? = nil, maxAge: TimeInterval = 60) -> CLIInstall? {
        precondition(e != .claude, "Claude は ClaudeLocator")
        lock.lock()
        if let c = cache[e], Date().timeIntervalSince(c.1) < maxAge { lock.unlock(); return c.0 }
        lock.unlock()
        let found = locate(e, override: override)
        lock.lock(); cache[e] = (found, Date()); lock.unlock()
        return found
    }

    static func invalidate() { lock.lock(); cache.removeAll(); lock.unlock() }

    private static func locate(_ e: AgentEngine, override: String?) -> CLIInstall? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let o = override, !o.isEmpty { candidates.append((o as NSString).expandingTildeInPath) }
        if let path = ShellEnvironment.shared.environment()["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/\(e.cliName)" }
        }
        candidates += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
            .map { "\($0)/\(e.cliName)" }
        var seen = Set<String>()
        for c in candidates where fm.isExecutableFile(atPath: c) && seen.insert(c).inserted {
            guard let v = run(URL(fileURLWithPath: c), ["--version"], timeout: 15) else { continue }
            let version = v.split(whereSeparator: { $0 == " " || $0 == "\n" }).last { $0.first?.isNumber == true }.map(String.init) ?? "?"
            return CLIInstall(engine: e, url: URL(fileURLWithPath: c), version: version, missing: missingOptions(e, URL(fileURLWithPath: c)))
        }
        return nil
    }

    /// 使うオプションが --help にあるか（推測でオプションを付けない）
    static func missingOptions(_ e: AgentEngine, _ url: URL) -> String? {
        switch e {
        case .codex:
            let exec = run(url, ["exec", "--help"], timeout: 15) ?? ""
            let resume = run(url, ["exec", "resume", "--help"], timeout: 15) ?? ""
            return missing(in: exec, ["--json", "--skip-git-repo-check", "--config"]) ?? missing(in: resume, ["--json", "--config"])
        case .gemini:
            let help = run(url, ["--help"], timeout: 20) ?? ""
            return missing(in: help, ["stream-json", "--approval-mode", "auto_edit", "--session-id", "--resume", "--prompt"])
        case .claude:
            return nil
        }
    }

    static func missing(in help: String, _ options: [String]) -> String? {
        let m = options.filter { !help.contains($0) }
        return m.isEmpty ? nil : m.joined(separator: ", ")
    }

    static func run(_ url: URL, _ args: [String], timeout: Double) -> String? {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.environment = ShellEnvironment.shared.agentEnvironment()
        p.currentDirectoryURL = AppPaths.dataDir
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// エンジンごとのログイン状態（読むたびに CLI を起動するので、少しの間は覚えておく）
final class EngineAuth {
    static let shared = EngineAuth()
    private var cache: [AgentEngine: (EngineStatus, Date)] = [:]
    private let lock = NSLock()
    var onChange: (() -> Void)?

    /// 覚えている状態（無ければ nil）
    func cached(_ e: AgentEngine) -> EngineStatus? { lock.lock(); defer { lock.unlock() }; return cache[e]?.0 }

    /// maxAge より古ければ確かめ直す（待つ。メインスレッドからは短い間だけ）
    func status(_ e: AgentEngine, claudePath: String?, cliPath: String?, maxAge: TimeInterval = 600) -> EngineStatus {
        lock.lock()
        if let c = cache[e], Date().timeIntervalSince(c.1) < maxAge { lock.unlock(); return c.0 }
        lock.unlock()
        let s = EngineAuth.check(e, claudePath: claudePath, cliPath: cliPath)
        lock.lock(); cache[e] = (s, Date()); lock.unlock()
        return s
    }

    /// 裏で確かめ直す（メニュー・アカウントの画面を開いたとき、ログインのあと）
    func refresh(_ engines: [AgentEngine] = AgentEngine.allCases, claudePath: String?, cliPaths: [AgentEngine: String], relocate: Bool = false) {
        lock.lock()
        if refreshing { lock.unlock(); return }
        refreshing = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            // あとから入れた CLI を見つけ直す（ふだんは 60 秒ごと）
            if relocate { ClaudeLocator.invalidate(); CLILocator.invalidate() }
            for e in engines {
                let s = EngineAuth.check(e, claudePath: claudePath, cliPath: cliPaths[e])
                self.lock.lock(); self.cache[e] = (s, Date()); self.lock.unlock()
            }
            self.lock.lock(); self.refreshing = false; self.lock.unlock()
            DispatchQueue.main.async { self.onChange?() }
        }
    }
    private var refreshing = false

    static func check(_ e: AgentEngine, claudePath: String?, cliPath: String?) -> EngineStatus {
        switch e {
        case .claude:
            guard let c = ClaudeLocator.best(override: claudePath) else { return EngineStatus(login: .notInstalled) }
            guard c.supportsAuthCommand, let out = CLILocator.run(c.url, ["auth", "status", "--json"], timeout: 10) else {
                return EngineStatus(login: .unknown(L("claude auth status が使えません")), version: c.versionString, path: c.url.path)
            }
            var s = claudeStatus(Data(out.utf8))
            s.version = c.versionString
            s.path = c.url.path
            return s
        case .codex:
            guard let c = CLILocator.find(.codex, override: cliPath) else { return EngineStatus(login: .notInstalled) }
            if let m = c.missing { return EngineStatus(login: .unsupported(m), version: c.version, path: c.url.path) }
            let out = CLILocator.run(c.url, ["login", "status"], timeout: 15) ?? ""
            var s = codexStatus(out)
            s.version = c.version
            s.path = c.url.path
            return s
        case .gemini:
            guard let c = CLILocator.find(.gemini, override: cliPath) else { return EngineStatus(login: .notInstalled) }
            if let m = c.missing { return EngineStatus(login: .unsupported(m), version: c.version, path: c.url.path) }
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
            var s = geminiStatus(settings: try? Data(contentsOf: dir.appendingPathComponent("settings.json")),
                                 hasOAuthCredentials: FileManager.default.fileExists(atPath: dir.appendingPathComponent("oauth_creds.json").path))
            s.version = c.version
            s.path = c.url.path
            return s
        }
    }

    // MARK: 読み取り（テストあり）

    /// claude auth status --json：authMethod が claude.ai（サブスクリプション）で、apiProvider が firstParty のときだけ使う
    static func claudeStatus(_ data: Data) -> EngineStatus {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return EngineStatus(login: .unknown("auth status")) }
        guard o["loggedIn"] as? Bool == true else { return EngineStatus(login: .loggedOut) }
        let method = o["authMethod"] as? String ?? ""
        let provider = o["apiProvider"] as? String ?? "firstParty"
        let plan = ClaudeAccount.planLabel(subscription: o["subscriptionType"] as? String, tier: o["planTier"] as? String)
        let email = (o["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let account = [email, plan.map { "Claude \($0)" }].compactMap { $0 }.joined(separator: " · ")
        if method == "claude.ai" && provider == "firstParty" {
            return EngineStatus(login: .subscription, account: account.isEmpty ? nil : account)
        }
        let how = provider != "firstParty" ? provider : (method.isEmpty ? "API" : method)
        return EngineStatus(login: .paidAPI(how), account: email)
    }

    /// codex login status：「Logged in using ChatGPT」だけがサブスクリプション。ほか（API キー・アクセストークン・Bedrock）は従量課金とみなす
    static func codexStatus(_ out: String) -> EngineStatus {
        let line = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("Logged in") || $0.hasPrefix("Not logged in") } ?? ""
        if line.hasPrefix("Logged in using ChatGPT") { return EngineStatus(login: .subscription, account: "ChatGPT") }
        if line.hasPrefix("Logged in using") {
            let how = String(line.dropFirst("Logged in using".count)).trimmingCharacters(in: .whitespaces)
            return EngineStatus(login: .paidAPI(how.isEmpty ? "API" : String(how.prefix(40))))
        }
        if line.hasPrefix("Not logged in") { return EngineStatus(login: .loggedOut) }
        return EngineStatus(login: .unknown("codex login status"))
    }

    /// ~/.gemini/settings.json の「どの方法でログインしたか」：oauth-personal（Google アカウント）だけがサブスクリプション
    static func geminiStatus(settings: Data?, hasOAuthCredentials: Bool) -> EngineStatus {
        var type: String?
        if let d = settings, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            type = ((o["security"] as? [String: Any])?["auth"] as? [String: Any])?["selectedType"] as? String
                ?? o["selectedAuthType"] as? String
        }
        switch type {
        case "oauth-personal", nil:
            return hasOAuthCredentials ? EngineStatus(login: .subscription, account: L("Google アカウント")) : EngineStatus(login: .loggedOut)
        default:
            return EngineStatus(login: .paidAPI(type ?? "API"))
        }
    }
}

/// 各 CLI の公式のログインを、ターミナルで開く（Jellyfish はパスワード・トークン・API キーを扱わない）
enum EngineLogin {
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// ターミナルで実行するスクリプト。課金の環境変数を外してから、その CLI のログインを始める
    static func script(_ e: AgentEngine, cli: URL, folder: URL?, allowAPI: Bool) -> String {
        var lines = ["#!/bin/zsh -l"]
        if !allowAPI { lines.append("unset " + BillingGuard.apiEnvKeys.joined(separator: " ")) }
        if let f = folder { lines.append("cd \(shellQuote(f.path)) || exit 1") }
        lines.append("clear")
        let note: String
        let command: String
        switch e {
        case .claude:
            note = L("Claude のアカウント（Pro / Max）でログインします。ブラウザが開いたら、ログインして許可してください。")
            command = "exec \(shellQuote(cli.path)) auth login --claudeai"
        case .codex:
            note = L("ChatGPT のアカウントでログインします（「Sign in with ChatGPT」）。ブラウザが開いたら、ログインして許可してください。API キーは使わないでください（従量課金になります）。")
            command = "exec \(shellQuote(cli.path)) login"
        case .gemini:
            note = folder == nil
                ? L("Gemini CLI が開きます。ログインの方法を聞かれたら「Sign in with Google」（Google アカウント）を選んでください。API キー・Vertex AI は選ばないでください（従量課金になります）。終わったら /quit で閉じてください。")
                : L("このフォルダで Gemini CLI を開きます。「このフォルダを信頼するか」を聞かれたら、信頼してよいフォルダのときだけ信頼してください。終わったら /quit で閉じてください。")
            command = "exec \(shellQuote(cli.path))"
        }
        lines.append("printf '%s\\n\\n' \(shellQuote("🪼 Jellyfish AI: " + note))")
        lines.append(command)
        return lines.joined(separator: "\n") + "\n"
    }

    /// スクリプトをデータフォルダに書いてターミナルで開く
    static func open(_ e: AgentEngine, cli: URL, folder: URL? = nil, allowAPI: Bool) -> Bool {
        let url = AppPaths.dataDir.appendingPathComponent("login-\(e.rawValue).command")
        do {
            try script(e, cli: cli, folder: folder, allowAPI: allowAPI).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return false }
        return NSWorkspace.shared.open(url)
    }
}
