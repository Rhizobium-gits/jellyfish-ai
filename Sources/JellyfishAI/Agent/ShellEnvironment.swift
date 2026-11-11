import Foundation

/// GUI アプリは launchd の最小限の環境（PATH が /usr/bin:/bin 程度）で起動するため、
/// エージェントがターミナルと同じツール（brew、node、git、conda など）を使えるよう、
/// ログインシェルの環境変数を一度だけ取り込む。
final class ShellEnvironment {
    static let shared = ShellEnvironment()

    private var cached: [String: String]?
    private let lock = NSLock()

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
}

/// claude 実行ファイルを探す。候補（PATH・標準インストール先・VS Code / Cursor 拡張に同梱）すべての
/// `--version` を調べて一番新しいものを選び、`--help` でオプションの有無を確かめる（推測でオプションを付けない）。
enum ClaudeLocator {
    private static var cached: ClaudeInstall?
    private static let lock = NSLock()

    static func best(override: String?) -> ClaudeInstall? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let found = locate(override: override)
        cached = found
        if let f = found {
            AppLog.write("claude: \(f.url.path) v\(f.versionString) auto=\(f.supportsAutoMode) prompts=\(f.supportsPermissionPrompts)")
        } else {
            AppLog.write("claude: not found")
        }
        return found
    }

    static func invalidate() { lock.lock(); cached = nil; lock.unlock() }

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
                             supportsEffort: help.contains("--effort"))
    }

    private static func run(_ url: URL, _ args: [String], timeout: Double) -> String? {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.environment = ShellEnvironment.shared.environment()
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
