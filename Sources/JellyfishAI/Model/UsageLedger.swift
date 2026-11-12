import Foundation

/// AI ごと・モデルごと・アカウントごとの使用量（呼び出しの回数と、CLI が報告したトークン）を、日ごとに数える。
/// - Claude の「今週の使用量（％）」は Claude Code の /usage から（ClaudeAccount）。ここはそれに加えて、Jellyfish が動かした分の内訳
/// - Codex・Gemini は CLI から残りの枠が分からないので、Jellyfish が動かした分だけを出す
/// - データフォルダの usage.json にだけ保存する（端末内。どこにも送らない）。60 日より古い日は捨てる
final class UsageLedger {
    struct Key: Hashable, Codable {
        var day: String      // yyyy-MM-dd（この Mac の時刻）
        var engine: String
        var model: String
        var account: String
    }
    struct Count: Codable, Equatable {
        var calls = 0
        var input = 0
        var output = 0
        var cached = 0
    }
    struct Row: Equatable {
        var engine: AgentEngine
        var model: String
        var account: String
        var count: Count
    }

    static let keepDays = 60
    let url: URL
    private(set) var counts: [Key: Count] = [:]
    private let queue = DispatchQueue(label: "jellyfish.usage", qos: .utility)
    private var pending: DispatchWorkItem?

    init(url: URL) {
        self.url = url
        if let d = try? Data(contentsOf: url), let rows = try? JSONDecoder().decode([Stored].self, from: d) {
            for r in rows { counts[r.key] = r.count }
        }
    }

    private struct Stored: Codable { var key: Key; var count: Count }

    static func day(_ d: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 1 回ぶんを足す（メインスレッドから）
    func add(engine: AgentEngine, model: String?, account: String?, input: Int, output: Int, cached: Int, now: Date = Date()) {
        let k = Key(day: UsageLedger.day(now), engine: engine.rawValue,
                    model: (model?.isEmpty == false ? model! : "-"), account: account ?? "-")
        var c = counts[k] ?? Count()
        c.calls += 1
        c.input += max(0, input)
        c.output += max(0, output)
        c.cached += max(0, cached)
        counts[k] = c
        scheduleSave(now: now)
    }

    /// 直近 days 日（今日を含む）の、AI・モデル・アカウントごとの合計。多い順
    func recent(days: Int = 7, now: Date = Date(), calendar: Calendar = .current) -> [Row] {
        let start = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
        let first = UsageLedger.day(start, calendar: calendar)
        var sum: [String: Row] = [:]
        for (k, c) in counts where k.day >= first {
            guard let e = AgentEngine(rawValue: k.engine) else { continue }
            let id = "\(k.engine)|\(k.model)|\(k.account)"
            var r = sum[id] ?? Row(engine: e, model: k.model, account: k.account, count: Count())
            r.count.calls += c.calls
            r.count.input += c.input
            r.count.output += c.output
            r.count.cached += c.cached
            sum[id] = r
        }
        return sum.values.sorted {
            ($0.engine.sortIndex, -$0.count.calls, $0.model) < ($1.engine.sortIndex, -$1.count.calls, $1.model)
        }
    }

    /// 「1.2M」「45k」のような短い数
    static func short(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000 { return "\(n / 1000)k" }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    private func scheduleSave(now: Date) {
        pending?.cancel()
        let cutoff = UsageLedger.day(Calendar.current.date(byAdding: .day, value: -UsageLedger.keepDays, to: now) ?? now)
        counts = counts.filter { $0.key.day >= cutoff }
        let rows = counts.map { Stored(key: $0.key, count: $0.value) }.sorted { ($0.key.day, $0.key.engine, $0.key.model) < ($1.key.day, $1.key.engine, $1.key.model) }
        let url = self.url
        let item = DispatchWorkItem {
            guard let d = try? JSONEncoder().encode(rows) else { return }
            try? d.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        pending = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    func flush() {
        pending?.cancel()
        let rows = counts.map { Stored(key: $0.key, count: $0.value) }
        let url = self.url
        queue.sync {
            if let d = try? JSONEncoder().encode(rows) { try? d.write(to: url, options: .atomic) }
        }
    }
}

extension AgentEngine {
    var sortIndex: Int { AgentEngine.allCases.firstIndex(of: self) ?? 0 }
}
