import Foundation

/// Claude Code にログインしているアカウントと使用量の上限（メニューバーに出す。VS Code の Claude Code 拡張と同じ情報）。
/// どちらも Claude Code 自身のコマンドの出力を読むだけで、Jellyfish が Anthropic と直接通信することはない。
///   claude auth status --json                       メール・プラン
///   claude -p --output-format json -- /usage         今週の使用量。Claude Code のローカルコマンドなのでモデルは呼ばず、
///                                                    トークンも使わない（使用量そのものは Claude Code が Anthropic から取ってくる）
/// メニューを開いたときだけ、前に読んでから 60 秒以上たっていれば読み直す（裏で定期的に取りに行くことはしない）。
/// メールはメニューに出すだけで、ログには書かない。
final class ClaudeAccount {
    static let shared = ClaudeAccount()

    struct Account: Equatable {
        var loggedIn: Bool
        var email: String?
        /// 「Max 20x」「Pro」など
        var plan: String?
    }

    struct Limit: Equatable {
        /// 「今週（全モデル）」「今週（Fable）」など
        var label: String
        var percent: Int
        var resetsAt: Date?
        /// 日時として読めなかったときの元の文字列
        var resetsText: String?
    }

    struct Snapshot: Equatable {
        var account: Account?
        var limits: [Limit] = []
        /// 読めなかった理由など
        var note: String?
        var updatedAt: Date
    }

    private(set) var snapshot: Snapshot?
    private(set) var loading = false
    /// /usage がローカルコマンドとして扱われなかった claude の版。モデルが呼ばれてしまうので、その版では二度と呼ばない
    private var usageUnsupportedVersion: String?
    /// 読み終わったとき（メインスレッド）
    var onChange: (() -> Void)?

    static let maxAge: TimeInterval = 60

    /// メインスレッドから呼ぶ
    func refreshIfStale(claudeOverride: String?) {
        if loading { return }
        if let s = snapshot, Date().timeIntervalSince(s.updatedAt) < Self.maxAge { return }
        loading = true
        let skip = usageUnsupportedVersion
        DispatchQueue.global(qos: .userInitiated).async {
            let (snap, unsupported) = Self.fetch(override: claudeOverride, skipUsageFor: skip)
            DispatchQueue.main.async {
                self.loading = false
                self.snapshot = snap
                if let unsupported { self.usageUnsupportedVersion = unsupported }
                self.onChange?()
            }
        }
    }

    // MARK: - 取得

    /// 待って読む（メニューからは refreshIfStale で裏で。SnapshotTool の --account-menu からも使う）
    static func fetch(override: String?, skipUsageFor skip: String?) -> (Snapshot, String?) {
        var snap = Snapshot(updatedAt: Date())
        guard let claude = ClaudeLocator.best(override: override) else {
            snap.note = L("Claude Code が見つかりません")
            return (snap, nil)
        }
        if claude.supportsAuthCommand, let out = run(claude.url, ["auth", "status", "--json"], timeout: 10) {
            snap.account = parseAccount(Data(out.utf8))
        }
        if snap.account?.loggedIn == false {
            snap.note = L("Claude Code にログインしていません（ターミナルで claude auth login）")
            return (snap, nil)
        }
        if skip == claude.versionString {
            snap.note = L("この版の Claude Code では使用量を読めません")
            return (snap, nil)
        }
        var args = ["-p", "--output-format", "json"]
        // 万一ローカルコマンドとして扱われなかったときに備えて、いちばん軽いモデルを指定しておく
        args += ["--model", "haiku"]
        if claude.supportsNoSessionPersistence { args.append("--no-session-persistence") }
        if claude.supportsStrictMCPConfig && claude.supportsMCPConfig {
            args += ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#]
        }
        // 読むだけなので、ツールは渡さず、データフォルダに置かれたプロジェクトの設定（フックなど）も読み込まない
        if claude.supportsSettingSources { args += ["--setting-sources", "user"] }
        if claude.supportsToolsFlag { args += ["--tools", ""] }
        args += ["--", "/usage"]
        guard let out = run(claude.url, args, timeout: 20),
              let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else {
            snap.note = L("使用量を読めませんでした")
            return (snap, nil)
        }
        guard obj["local_command"] as? String == "usage", let text = obj["result"] as? String else {
            snap.note = L("この版の Claude Code では使用量を読めません")
            return (snap, claude.versionString)
        }
        snap.limits = parseUsage(text)
        if snap.limits.isEmpty {
            // API キーで使っているときなど、上限の行が無い
            snap.note = text.split(separator: "\n").first.map(String.init) ?? L("使用量の上限はありません")
        }
        return (snap, nil)
    }

    /// 作業フォルダはデータフォルダ（プロジェクトの設定や CLAUDE.md を読み込まない）
    private static func run(_ url: URL, _ args: [String], timeout: Double) -> String? {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.currentDirectoryURL = AppPaths.dataDir
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

    // MARK: - 読み取り（テストあり）

    static func parseAccount(_ data: Data) -> Account? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let loggedIn = o["loggedIn"] as? Bool ?? false
        let email = (o["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Account(loggedIn: loggedIn, email: email,
                       plan: planLabel(subscription: o["subscriptionType"] as? String, tier: o["planTier"] as? String))
    }

    /// subscriptionType「max」と planTier「max_20x」→「Max 20x」
    static func planLabel(subscription: String?, tier: String?) -> String? {
        guard let sub = subscription, !sub.isEmpty else { return nil }
        var label = sub.prefix(1).uppercased() + sub.dropFirst()
        if let tier, let r = tier.range(of: #"(\d+)x$"#, options: .regularExpression) { label += " " + tier[r] }
        return label
    }

    /// 「Current week (all models): 57% used · resets Nov 13 at 2:59am (Asia/Tokyo)」の行を読む
    static func parseUsage(_ text: String, now: Date = Date()) -> [Limit] {
        let re = try! NSRegularExpression(pattern: #"^\s*(Current [^:]+):\s*(\d+)%\s*used(?:\s*·\s*resets\s+(.+?))?\s*$"#)
        var out: [Limit] = []
        for line in text.split(separator: "\n").map(String.init) {
            let ns = line as NSString
            guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let label = ns.substring(with: m.range(at: 1))
            let pct = Int(ns.substring(with: m.range(at: 2))) ?? 0
            let resets = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3))
            let date = resets.flatMap { parseReset($0, now: now) }
            out.append(Limit(label: japaneseLabel(label), percent: pct, resetsAt: date, resetsText: date == nil ? resets : nil))
        }
        return out
    }

    /// 「Current week (all models)」→「今週（全モデル）」、「Current session」→「今のセッション」
    /// （名前は日本語だが、いまの言語に訳す）
    static func japaneseLabel(_ s: String) -> String {
        var head = s
        var inner: String?
        if let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close {
            inner = String(s[s.index(after: open)..<close])
            head = String(s[..<open]).trimmingCharacters(in: .whitespaces)
        }
        switch (head, inner) {
        case ("Current week", "all models"?): return L("今週（全モデル）")
        case ("Current week", let i?): return L("今週（%@）", i)
        case ("Current week", nil): return L("今週")
        case ("Current session", let i?): return L("今のセッション（%@）", i)
        case ("Current session", nil): return L("今のセッション")
        default:
            var t = head
            if let i = inner { t = L("%@（%@）", head, i == "all models" ? L("全モデル") : i) }
            return t.replacingOccurrences(of: "Current week", with: L("今週"))
                .replacingOccurrences(of: "Current session", with: L("今のセッション"))
        }
    }

    /// 「Nov 13 at 2:59am (Asia/Tokyo)」「3pm (Asia/Tokyo)」→ 日時。読めなければ nil
    static func parseReset(_ s: String, now: Date = Date()) -> Date? {
        let re = try! NSRegularExpression(pattern: #"^(?:([A-Z][a-z]{2})\s+(\d{1,2})(?:,\s*(\d{4}))?\s+at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?$"#,
                                          options: [.caseInsensitive])
        let ns = s.trimmingCharacters(in: .whitespaces) as NSString
        guard let m = re.firstMatch(in: ns as String, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
        var cal = Calendar(identifier: .gregorian)
        if let tz = group(7) {
            guard let zone = TimeZone(identifier: tz) else { return nil }
            cal.timeZone = zone
        }
        guard var hour = group(4).flatMap(Int.init), hour >= 1, hour <= 12 else { return nil }
        let minute = group(5).flatMap(Int.init) ?? 0
        let pm = group(6)?.lowercased() == "pm"
        if hour == 12 { hour = 0 }
        if pm { hour += 12 }
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        var c = cal.dateComponents([.year, .month, .day], from: now)
        c.hour = hour
        c.minute = minute
        if let mon = group(1), let day = group(2).flatMap(Int.init) {
            guard let i = months.firstIndex(of: mon.lowercased()) else { return nil }
            c.month = i + 1
            c.day = day
            if let y = group(3).flatMap(Int.init) { c.year = y }
            guard var d = cal.date(from: c) else { return nil }
            // 年が書いていないとき、年末に「Jan 2」と出たら来年
            if group(3) == nil, d < now.addingTimeInterval(-180 * 86400), let next = cal.date(byAdding: .year, value: 1, to: d) { d = next }
            return d
        }
        guard var d = cal.date(from: c) else { return nil }
        if d < now, let next = cal.date(byAdding: .day, value: 1, to: d) { d = next }
        return d
    }
}
