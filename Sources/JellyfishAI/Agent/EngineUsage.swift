import Foundation

/// ChatGPT（Codex）の使用量の枠（5 時間・今週の ％）とプラン。
/// Codex CLI が自分の記録（`$CODEX_HOME/sessions/年/月/日/rollout-*.jsonl`、既定は ~/.codex）に書いている
/// `token_count` の `rate_limits` を、いちばん新しいものだけ読む。モデルは呼ばず、どこにも送らない。
/// 読むのは記録の終わりの方の token_count の行だけで、会話の中身は使わない
struct CodexLimits: Equatable {
    var plan: String?
    var limits: [ClaudeAccount.Limit]
    /// その値を Codex が記録した時刻（最後に Codex を使ったとき）
    var observedAt: Date?
}

enum CodexUsage {
    static func home(_ env: [String: String] = ShellEnvironment.shared.environment()) -> URL {
        if let h = env["CODEX_HOME"], h.hasPrefix("/") { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    private static var cache: (CodexLimits?, Date)?
    private static let lock = NSLock()

    /// いちばん新しい値（1 分は覚えておく）
    static func latest(now: Date = Date()) -> CodexLimits? {
        lock.lock()
        if let c = cache, now.timeIntervalSince(c.1) < 60 { lock.unlock(); return c.0 }
        lock.unlock()
        let v = read(home: home(), now: now)
        lock.lock(); cache = (v, now); lock.unlock()
        return v
    }

    /// 直近 8 日の記録のうち新しいものから、rate_limits のある token_count を探す
    static func read(home: URL, now: Date = Date(), days: Int = 8, calendar: Calendar = .current) -> CodexLimits? {
        let fm = FileManager.default
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        var files: [(URL, Date)] = []
        for back in 0..<days {
            guard let d = calendar.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            guard let y = c.year, let m = c.month, let dd = c.day else { continue }
            let dir = root.appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, dd), isDirectory: true)
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where f.lastPathComponent.hasPrefix("rollout-") && f.pathExtension == "jsonl" {
                let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((f, mod))
            }
            // 新しい日に見つかれば、それより前の日は見ない
            if !files.isEmpty { break }
        }
        // メニューを開くときに読むので、新しい 2 つのファイルの終わりだけ
        for (f, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(2) {
            if let v = lastLimits(in: f, now: now) { return v }
        }
        return nil
    }

    /// ファイルの終わり（最大 512KB）から、いちばん後の rate_limits を読む
    static func lastLimits(in file: URL, now: Date = Date()) -> CodexLimits? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let chunk: UInt64 = 512_000
        try? h.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? h.readToEnd() else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") && line.contains("\"token_count\"") {
            if let v = parse(line: String(line), now: now) { return v }
        }
        return nil
    }

    /// token_count の 1 行から（Codex の記録の形：payload.rate_limits.primary / secondary の used_percent・window_minutes・resets_at）
    static func parse(line: String, now: Date = Date()) -> CodexLimits? {
        guard let d = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let p = d["payload"] as? [String: Any], p["type"] as? String == "token_count",
              let rl = p["rate_limits"] as? [String: Any] else { return nil }
        var limits: [ClaudeAccount.Limit] = []
        for key in ["primary", "secondary"] {
            guard let w = rl[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { continue }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue
            let resets = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            var l = ClaudeAccount.Limit(label: label(minutes), percent: Int(used.rounded()), resetsAt: resets, resetsText: nil)
            // 記録したあとに枠がリセットされていれば、いまは 0%
            if let r = resets, r <= now {
                l.percent = 0
                l.resetsAt = nil
                l.resetsText = L("済み（次に使うと更新）")
            }
            limits.append(l)
        }
        guard !limits.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let at = (d["timestamp"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        let plan = (rl["plan_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return CodexLimits(plan: plan, limits: limits, observedAt: at)
    }

    static func label(_ minutes: Int?) -> String {
        guard let m = minutes, m > 0 else { return L("枠") }
        if m == 10080 { return L("今週の枠") }
        if m % 1440 == 0 { return L("%ld 日の枠", m / 1440) }
        if m % 60 == 0 { return L("%ld 時間の枠", m / 60) }
        return L("%ld 分の枠", m)
    }

    /// 「ChatGPT Plus」のように
    static func planName(_ plan: String?) -> String? {
        guard let p = plan, let first = p.first else { return nil }
        return "ChatGPT " + first.uppercased() + p.dropFirst()
    }
}
