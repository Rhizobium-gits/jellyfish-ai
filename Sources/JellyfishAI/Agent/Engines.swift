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

    /// 使うアカウント（サブスクリプション）の名前
    var accountKind: String {
        switch self {
        case .claude: return L("Claude のアカウント（Pro / Max など）")
        case .codex: return L("ChatGPT のアカウント（Plus / Pro など）")
        case .gemini: return L("Google アカウント")
        }
    }

    /// PC 操作・外部 MCP・モデルの「自動」を使えるか（Claude だけ）。チームのツール（仲間を作る・頼む）・自律組織はどの AI でも使える
    var supportsJellyfishTools: Bool { self == .claude }

    /// チームで分担するときの得意なこと・できないこと（Jellyfish での動かし方から決まるもの。リーダーへの案内とメニューに出す）
    var teamStrengths: String {
        switch self {
        case .claude:
            return L("リーダー・まとめ・レビュー、長い多段の作業、コマンドの実行、Web 検索、PC 操作（許可したとき）、外部ツール（MCP）")
        case .codex:
            return L("コードの実装・修正、テストやビルドの実行（作業フォルダの中だけ。ネットワークなしなので、Web 検索・パッケージのダウンロードはできない）")
        case .gemini:
            return L("Google 検索・Web ページを読んでの調査、たくさんの資料やコードを読んでの要約・比較、文章を書く・ファイルを直す（シェルのコマンドは実行しない）")
        }
    }

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
        // ChatGPT のデスクトップアプリに入っている Codex CLI（アプリで ChatGPT にログインしていれば、そのまま使える）
        if e == .codex {
            for root in ["/Applications", "\(home)/Applications"] {
                for app in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where app.hasSuffix(".app") && (app.hasPrefix("ChatGPT") || app.hasPrefix("Codex")) {
                    candidates.append("\(root)/\(app)/Contents/Resources/codex-cli/bin/codex")
                }
            }
        }
        // 見つかったものから、使える（オプションがそろっている）いちばん新しい版を選ぶ
        var seen = Set<String>()
        var found: [CLIInstall] = []
        for c in candidates where fm.isExecutableFile(atPath: c) && seen.insert(c).inserted {
            guard let v = run(URL(fileURLWithPath: c), ["--version"], timeout: 15) else { continue }
            let version = v.split(whereSeparator: { $0 == " " || $0 == "\n" }).last { $0.first?.isNumber == true }.map(String.init) ?? "?"
            found.append(CLIInstall(engine: e, url: URL(fileURLWithPath: c), version: version, missing: missingOptions(e, URL(fileURLWithPath: c))))
        }
        return found.max { a, b in
            if (a.missing == nil) != (b.missing == nil) { return a.missing != nil }
            return CLILocator.versionParts(a.version).lexicographicallyPrecedes(CLILocator.versionParts(b.version))
        }
    }

    /// 「0.162.0-alpha.2」→ [0, 162, 0]
    static func versionParts(_ v: String) -> [Int] {
        (v.split(separator: "-").first ?? "").split(separator: ".").map { Int($0) ?? 0 }
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

    static func run(_ url: URL, _ args: [String], timeout: Double, mergeStderr: Bool = true) -> String? {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.environment = ShellEnvironment.shared.agentEnvironment()
        p.currentDirectoryURL = AppPaths.dataDir
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = mergeStderr ? out : FileHandle.nullDevice
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
        var lines = header(allowAPI: allowAPI)
        if let f = folder { lines.append("cd \(shellQuote(f.path)) || exit 1") }
        lines.append("clear")
        lines += loginLines(e, cli: shellQuote(cli.path), folder: folder)
        return lines.joined(separator: "\n") + "\n"
    }

    /// スクリプトの頭（課金の環境変数を外す）
    static func header(allowAPI: Bool) -> [String] {
        var lines = ["#!/bin/zsh -l"]
        if !allowAPI { lines.append("unset " + BillingGuard.apiEnvKeys.joined(separator: " ")) }
        return lines
    }

    /// ログインを始める行（cli はシェルの式：クォート済みのパスか "$cli"）
    static func loginLines(_ e: AgentEngine, cli: String, folder: URL?) -> [String] {
        let note: String
        let command: String
        switch e {
        case .claude:
            note = L("Claude のアカウント（Pro / Max）でログインします。ブラウザが開いたら、ログインして許可してください。")
            command = "exec \(cli) auth login --claudeai"
        case .codex:
            note = L("ChatGPT のアカウントでログインします（「Sign in with ChatGPT」）。ブラウザが開いたら、ログインして許可してください。API キーは使わないでください（従量課金になります）。")
            command = "exec \(cli) login"
        case .gemini:
            note = folder == nil
                ? L("Gemini CLI が開きます。ログインの方法を聞かれたら「Sign in with Google」（Google アカウント）を選んでください。API キー・Vertex AI は選ばないでください（従量課金になります）。終わったら /quit で閉じてください。")
                : L("このフォルダで Gemini CLI を開きます。「このフォルダを信頼するか」を聞かれたら、信頼してよいフォルダのときだけ信頼してください。終わったら /quit で閉じてください。")
            command = "exec \(cli)"
        }
        return ["printf '%s\\n\\n' \(shellQuote("🪼 Jellyfish AI: " + note))", command]
    }

    /// スクリプトをデータフォルダに書いてターミナルで開く
    static func open(_ e: AgentEngine, cli: URL, folder: URL? = nil, allowAPI: Bool) -> Bool {
        openScript(script(e, cli: cli, folder: folder, allowAPI: allowAPI), name: "login-\(e.rawValue)")
    }

    static func openScript(_ text: String, name: String) -> Bool {
        let url = AppPaths.dataDir.appendingPathComponent("\(name).command")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return false }
        return NSWorkspace.shared.open(url)
    }
}

/// CLI が入っていないとき：ユーザーが許可したら、公式のパッケージをターミナルで入れて、続けてログインを始める。
/// 入れ方は決まったものだけ（Claude は公式のインストーラ、Codex・Gemini は npm か Homebrew の公式パッケージ）。
/// 管理者のパスワード（sudo）は使わない。コマンドは許可を求める画面にそのまま出し、そのとおりに実行する
enum EngineInstall {
    enum Tool: Equatable { case official, npm(String), brew(String) }

    struct Plan: Equatable {
        let engine: AgentEngine
        let tool: Tool
        /// 許可を求める画面に出し、そのまま実行するコマンド
        let command: String
    }

    /// npm のパッケージ名・Homebrew の入れ方（公式の案内にあるもの）
    static func npmPackage(_ e: AgentEngine) -> String? {
        switch e {
        case .claude: return nil
        case .codex: return "@openai/codex"
        case .gemini: return "@google/gemini-cli"
        }
    }
    static func brewArgs(_ e: AgentEngine) -> String? {
        switch e {
        case .claude: return nil
        case .codex: return "install --cask codex"
        case .gemini: return "install gemini-cli"
        }
    }

    /// 入れ方を決める。npm が使えればnpm（グローバルの入れ先に書けるときだけ）、だめなら Homebrew、どちらも無ければ nil
    static func plan(_ e: AgentEngine, npm: String?, npmWritable: Bool, brew: String?) -> Plan? {
        if e == .claude { return Plan(engine: e, tool: .official, command: "curl -fsSL https://claude.ai/install.sh | bash") }
        if let npm, npmWritable, let pkg = npmPackage(e) {
            return Plan(engine: e, tool: .npm(npm), command: "\(word(npm)) install -g \(pkg)")
        }
        if let brew, let args = brewArgs(e) {
            return Plan(engine: e, tool: .brew(brew), command: "\(word(brew)) \(args)")
        }
        return nil
    }

    /// パスを 1 語に（ふつうの文字だけならそのまま、ほかはクォート）
    static func word(_ s: String) -> String {
        s.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "/._-+").contains($0) || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) })
            ? s : EngineLogin.shellQuote(s)
    }

    /// 入れてからログインするスクリプト
    static func script(_ p: Plan, allowAPI: Bool) -> String {
        let e = p.engine
        let q = EngineLogin.shellQuote
        var lines = EngineLogin.header(allowAPI: allowAPI)
        lines.append("set -o pipefail")
        lines.append("clear")
        lines.append("printf '%s\\n\\n  %s\\n\\n' \(q("🪼 Jellyfish AI: " + L("%@ を入れます（あなたが許可したコマンド）:", e.cliTitle))) \(q(p.command))")
        switch p.tool {
        case .official: break
        case .npm(let path), .brew(let path):
            // npm は node を、brew は自分の仲間を PATH から探すので、見つけた場所を前に足す
            lines.append("export PATH=\(q((path as NSString).deletingLastPathComponent)):\"$PATH\"")
        }
        lines.append(p.command)
        lines.append("if [ $? -ne 0 ]; then")
        lines.append("  printf '\\n%s\\n%s\\n' \(q("⚠️ " + L("入れられませんでした。上のメッセージを確かめてください。"))) \(q(L("公式の案内: %@", e.setupURL.absoluteString)))")
        lines.append("  exit 1")
        lines.append("fi")
        // 入ったものを見つける
        switch p.tool {
        case .official: lines.append("export PATH=\"$HOME/.local/bin:$PATH\"")
        case .npm(let npm): lines.append("export PATH=\"$(\(q(npm)) prefix -g)/bin:$PATH\"")
        case .brew(let brew): lines.append("export PATH=\"$(\(q(brew)) --prefix)/bin:$PATH\"")
        }
        lines.append("hash -r")
        lines.append("cli=\"$(command -v \(e.cliName))\"")
        lines.append("if [ -z \"$cli\" ]; then")
        lines.append("  printf '\\n%s\\n' \(q("⚠️ " + L("入りましたが %@ が見つかりません。ターミナルを開き直してから、メニューバーのクラゲ › 🔑 アカウントと AI でログインしてください。", e.cliName)))")
        lines.append("  exit 1")
        lines.append("fi")
        lines.append("printf '\\n%s\\n\\n' \(q("✅ " + L("入りました。続けてログインします。"))) ")
        lines += EngineLogin.loginLines(e, cli: "\"$cli\"", folder: nil)
        return lines.joined(separator: "\n") + "\n"
    }

    /// npm・brew を探す（シェルの PATH と、よくある場所）
    static func findTool(_ name: String) -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var dirs = (ShellEnvironment.shared.environment()["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.volta/bin", "\(home)/.local/bin"]
        for d in dirs where !d.isEmpty {
            let p = "\(d)/\(name)"
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// npm のグローバルの入れ先（そこに書けるか。書けなければ sudo が要るので npm は使わない）
    static func npmPrefix(_ npm: String) -> (path: String, writable: Bool)? {
        guard let out = CLILocator.run(URL(fileURLWithPath: npm), ["prefix", "-g"], timeout: 15, mergeStderr: false) else { return nil }
        let prefix = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.hasPrefix("/") else { return nil }
        let fm = FileManager.default
        let target = ["\(prefix)/lib/node_modules", "\(prefix)/lib", prefix].first { fm.fileExists(atPath: $0) } ?? prefix
        // パッケージの置き場所と、コマンドの置き場所（無ければ作れるか）の両方に書けること
        let bin = "\(prefix)/bin"
        let binOK = fm.fileExists(atPath: bin) ? fm.isWritableFile(atPath: bin) : fm.isWritableFile(atPath: prefix)
        return (prefix, fm.isWritableFile(atPath: target) && binOK)
    }

    static func open(_ p: Plan, allowAPI: Bool) -> Bool {
        EngineLogin.openScript(script(p, allowAPI: allowAPI), name: "install-\(p.engine.rawValue)")
    }
}
