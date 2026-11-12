import Foundation

/// GUI アプリは launchd の最小限の環境（PATH が /usr/bin:/bin 程度）で起動するため、
/// エージェントがターミナルと同じツール（brew、node、git、conda など）を使えるよう、
/// ログインシェルの環境変数を一度だけ取り込む。
final class ShellEnvironment {
    static let shared = ShellEnvironment()

    private var cached: [String: String]?
    private let lock = NSLock()

    /// エージェント・CLI に渡す環境変数：課金につながる API キーなどを外したもの（BillingGuard。ユーザーがメニューで許可したときだけ残す）
    func agentEnvironment() -> [String: String] {
        BillingGuard.sanitized(environment(), allowAPI: BillingGuard.allowAPI)
    }

    /// 起動直後にバックグラウンドで取得を始めておく
    func prefetch() {
        DispatchQueue.global(qos: .utility).async { _ = self.environment() }
    }

    func environment() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        var env = ProcessInfo.processInfo.environment
        if let login = Self.loginShellEnvironment() {
            env.merge(login) { _, new in new }
        }
        // 入れ子の Claude Code 判定に使われる変数は渡さない
        for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE_") { env.removeValue(forKey: k) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var parts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        for e in extra where !parts.contains(e) { parts.append(e) }
        env["PATH"] = parts.joined(separator: ":")
        cached = env
        return env
    }

    private static func loginShellEnvironment() -> [String: String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "env -0"]
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // 5 秒で打ち切り（重い .zprofile でも固まらない）
        let deadline = Date().addingTimeInterval(5)
        var data = Data()
        let reader = out.fileHandleForReading
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
        data = reader.readDataToEndOfFile()
        p.waitUntilExit()
        guard Date() <= deadline.addingTimeInterval(1), p.terminationStatus == 0 else { return nil }
        var env: [String: String] = [:]
        for entry in data.split(separator: 0) {
            guard let s = String(data: Data(entry), encoding: .utf8), let eq = s.firstIndex(of: "=") else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }
}

/// 見つかった claude と、そのバージョンで実際に使えるオプション
struct ClaudeInstall {
    let url: URL
    let version: [Int]
    let versionString: String
    /// `--permission-mode` に auto があるか（--help の choices で判定）
    let supportsAutoMode: Bool
    /// `--permission-prompts` があるか
    let supportsPermissionPrompts: Bool
    /// `--effort` があるか
    let supportsEffort: Bool
    /// チーム機能に使う `--mcp-config` / `--append-system-prompt` / `--allowedTools` があるか
    var supportsMCPConfig = false
    var supportsAppendSystemPrompt = false
    var supportsAllowedTools = false
    /// `--strict-mcp-config`（--mcp-config 以外の MCP サーバーを読み込まない）があるか
    var supportsStrictMCPConfig = false
    /// アカウントと使用量の表示に使う `auth` コマンド（`claude auth status --json`）と
    /// `--no-session-persistence`（/usage を読むだけの呼び出しをセッションに残さない）があるか
    var supportsAuthCommand = false
    var supportsNoSessionPersistence = false
    /// `--permission-mode` の choices（--help に書いてあるもの。読めなければ空）
    var permissionModes: [String] = []
    /// /usage を読むだけの呼び出しで、ツールとプロジェクトの設定（フック）を読み込まないための
    /// `--tools` と `--setting-sources` があるか
    var supportsToolsFlag = false
    var supportsSettingSources = false
}

/// claude 実行ファイルを探す。候補（PATH・標準インストール先・VS Code / Cursor 拡張に同梱）すべての
/// `--version` を調べて一番新しいものを選び、`--help` でオプションの有無を確かめる（推測でオプションを付けない）。
enum ClaudeLocator {
    private static var cached: ClaudeInstall?
    /// 見つからなかった時刻。30 秒たったらもう一度探す（あとから Claude Code を入れても再起動しなくてよい）
    private static var missedAt: Date?
    private static var probing = false
    /// cached / missedAt / probing を守る（短時間だけ持つ）
    private static let lock = NSLock()
    /// 探すのは同時に 1 回だけ（シェルの起動や --help で数秒かかることがある）
    private static let probeLock = NSLock()
    static let retryInterval: TimeInterval = 30

    enum Status { case detecting, found(ClaudeInstall), notFound }

    /// 画面表示用：待たずに今わかっていることを返す。まだ調べていなければ裏で調べ始める
    static func status(override: String?) -> Status {
        lock.lock()
        let c = cached, missed = missedAt, busy = probing
        lock.unlock()
        if let c { return .found(c) }
        if busy { return .detecting }
        let stale = missed.map { Date().timeIntervalSince($0) >= retryInterval } ?? true
        if stale { DispatchQueue.global(qos: .utility).async { _ = best(override: override) } }
        return missed == nil ? .detecting : .notFound
    }

    /// 実行用：見つかるまで（または見つからないとわかるまで）待つ
    static func best(override: String?) -> ClaudeInstall? {
        probeLock.lock(); defer { probeLock.unlock() }
        lock.lock()
        if let c = cached { lock.unlock(); return c }
        if let m = missedAt, Date().timeIntervalSince(m) < retryInterval { lock.unlock(); return nil }
        probing = true
        lock.unlock()
        let found = locate(override: override)
        lock.lock()
        cached = found
        missedAt = found == nil ? Date() : nil
        probing = false
        lock.unlock()
        if let f = found {
            AppLog.write("claude: \(f.url.path) v\(f.versionString) auto=\(f.supportsAutoMode) prompts=\(f.supportsPermissionPrompts)")
        } else {
            AppLog.write("claude: not found")
        }
        return found
    }

    static func invalidate() { lock.lock(); cached = nil; missedAt = nil; lock.unlock() }

    private static func locate(override: String?) -> ClaudeInstall? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let o = override, !o.isEmpty {
            let path = (o as NSString).expandingTildeInPath
            if fm.isExecutableFile(atPath: path), let i = inspect(URL(fileURLWithPath: path)) { return i }
        }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                       "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        if let path = ShellEnvironment.shared.environment()["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/claude" }
        }
        for extRoot in ["\(home)/.vscode/extensions", "\(home)/.cursor/extensions"] {
            guard let items = try? fm.contentsOfDirectory(atPath: extRoot) else { continue }
            // 拡張は版ごとにフォルダが残るので、フォルダ名の版が新しい順に数個だけ調べる
            let dirs = items.filter { $0.hasPrefix("anthropic.claude-code-") }
                .map { name -> ([Int], String) in
                    let v = name.dropFirst("anthropic.claude-code-".count).split(separator: "-").first ?? ""
                    return (v.split(separator: ".").compactMap { Int($0) }, name)
                }
                .sorted { $0.0.lexicographicallyPrecedes($1.0) }
                .suffix(2)
            candidates += dirs.map { "\(extRoot)/\($0.1)/resources/native-binary/claude" }
        }
        var seen = Set<String>()
        var installs: [ClaudeInstall] = []
        for c in candidates where fm.isExecutableFile(atPath: c) {
            let real = (try? fm.destinationOfSymbolicLink(atPath: c)).map { ($0 as NSString).isAbsolutePath ? $0 : ((c as NSString).deletingLastPathComponent as NSString).appendingPathComponent($0) } ?? c
            guard seen.insert(real).inserted else { continue }
            if let i = inspect(URL(fileURLWithPath: c)) { installs.append(i) }
        }
        return installs.max { $0.version.lexicographicallyPrecedes($1.version) }
    }

    private static func inspect(_ url: URL) -> ClaudeInstall? {
        guard let v = run(url, ["--version"], timeout: 8) else { return nil }
        let token = v.split(whereSeparator: { $0 == " " || $0 == "\n" }).first.map(String.init) ?? ""
        let parts = token.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        let help = run(url, ["--help"], timeout: 8) ?? ""
        let autoMode = help.range(of: #"--permission-mode[\s\S]{0,400}?"auto""#, options: .regularExpression) != nil
        return ClaudeInstall(url: url, version: parts, versionString: token,
                             supportsAutoMode: autoMode,
                             supportsPermissionPrompts: help.contains("--permission-prompts"),
                             supportsEffort: help.contains("--effort"),
                             supportsMCPConfig: help.contains("--mcp-config"),
                             supportsAppendSystemPrompt: help.contains("--append-system-prompt"),
                             supportsAllowedTools: help.contains("--allowedTools"),
                             supportsStrictMCPConfig: help.contains("--strict-mcp-config"),
                             supportsAuthCommand: help.range(of: #"(?m)^\s+auth\s"#, options: .regularExpression) != nil,
                             supportsNoSessionPersistence: help.contains("--no-session-persistence"),
                             permissionModes: permissionModes(fromHelp: help),
                             supportsToolsFlag: help.range(of: #"(?m)^\s+--tools\s"#, options: .regularExpression) != nil,
                             supportsSettingSources: help.contains("--setting-sources"))
    }

    /// 「--permission-mode <mode> ... (choices: "acceptEdits", "auto", ...)」から choices を読む
    static func permissionModes(fromHelp help: String) -> [String] {
        guard let r = help.range(of: #"--permission-mode[\s\S]{0,400}?\(choices:[^)]*\)"#, options: .regularExpression) else { return [] }
        let re = try! NSRegularExpression(pattern: #""([A-Za-z]+)""#)
        let s = String(help[r])
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
    }

    private static func run(_ url: URL, _ args: [String], timeout: Double) -> String? {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.environment = ShellEnvironment.shared.agentEnvironment()
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
