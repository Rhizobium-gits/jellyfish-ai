import Foundation

/// チャットのモデルの「自動」：依頼ごとに、その依頼に合うモデルを選ぶ（端末内の判定だけ。モデルは呼ばない）。
/// - 短い・簡単な依頼 → Haiku、ふつうの依頼 → Sonnet、コード・設計・計画などが重なる依頼や長くて重い依頼 → Opus
/// - いちばん重い依頼は Fable。ただし Fable の今週の使用量が 75% 以上（または分からない）なら Opus にする
/// - 渡す名前は claude --help の --model に載っている別名（fable / opus / sonnet）と、Haiku は正式名
enum ModelRouter {
    /// AgentRuntime.model・設定の model に入れる「自動」の値（claude には渡さない）
    static let auto = "auto"
    static let fableLimit = 75

    struct Choice: Equatable {
        let model: String
        let reason: String
    }

    /// チャット・メニューに出すモデルの一覧（value = claude の --model に渡す値。nil = Claude Code の既定）
    static let models: [(label: String, value: String)] = [
        ("Fable 5.2", "fable"),
        ("Opus 5.5", "opus"),
        ("Sonnet 5.5", "sonnet"),
        ("Haiku 5.5", "claude-haiku-5-5"),
    ]

    static func displayName(_ model: String) -> String {
        if let m = models.first(where: { $0.value == model }) { return m.label }
        let id = model.lowercased()
        for (label, value) in models where id.contains(value.replacingOccurrences(of: "claude-", with: "").prefix(5)) { return label }
        return model
    }

    static func choose(_ text: String, attachments: Bool = false, fableUsedPercent: Int?) -> Choice {
        let t = TaskFeatures.extract(text).tags
        let short = t.contains("len:short") || t.contains("quick")
        let long = t.contains("len:long")
        let heavy = t.intersection(["code", "design", "plan", "data", "test"])
        let hard = (long && (!heavy.isEmpty || t.contains("research") || t.contains("multi"))) || heavy.count >= 2
        if hard {
            if let p = fableUsedPercent, p < fableLimit {
                return Choice(model: "fable", reason: L("重い依頼（Fable の今週の使用量 %ld%%）", p))
            }
            let why = fableUsedPercent.map { L("重い依頼（Fable は今週 %ld%% 使っているので Opus）", $0) } ?? L("重い依頼")
            return Choice(model: "opus", reason: why)
        }
        if short && heavy.isEmpty && !attachments && !t.contains("pc") && !t.contains("research") {
            return Choice(model: "claude-haiku-5-5", reason: L("短い・簡単な依頼"))
        }
        return Choice(model: "sonnet", reason: attachments ? L("添付や画面のある依頼") : L("ふつうの依頼"))
    }
}
