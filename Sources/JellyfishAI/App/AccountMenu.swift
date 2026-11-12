import AppKit

/// メニューバーのメニューのいちばん上：Claude Code のアカウント（メール・プラン）と今週の使用量のバー
enum AccountMenu {
    /// この範囲のタグの項目を、読み終わったときに差し替える
    static let tags = 7100..<7120

    static func items(_ snap: ClaudeAccount.Snapshot?, loading: Bool) -> [NSMenuItem] {
        var views: [NSView] = []
        let status: String
        if loading && snap == nil {
            status = L("読み込み中…")
        } else if let s = snap {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: L("ja_JP"))
            rel.unitsStyle = .short
            let age = Date().timeIntervalSince(s.updatedAt)
            status = (loading ? L("更新中…") + " " : "") + (age < 5 ? L("たった今更新") : L("%@に更新", rel.localizedString(for: s.updatedAt, relativeTo: Date())))
        } else {
            status = ""
        }
        let acct = snap?.account
        views.append(AccountHeaderView(email: acct?.email ?? (snap == nil ? L("Claude Code のアカウント") : L("アカウント不明")),
                                       detail: acct?.plan.map { "Claude \($0)" } ?? "Claude Code",
                                       status: status))
        for l in snap?.limits ?? [] { views.append(UsageRowView(l)) }
        if let note = snap?.note { views.append(NoteView(note)) }
        var out: [NSMenuItem] = views.enumerated().map { i, v in
            let it = NSMenuItem()
            it.view = v
            it.isEnabled = false
            it.tag = tags.lowerBound + i
            return it
        }
        let sep = NSMenuItem.separator()
        sep.tag = tags.lowerBound + out.count
        out.append(sep)
        return out
    }

    static let width: CGFloat = 300
    static let left: CGFloat = 21
    static let right: CGFloat = 14
}

private class MenuInfoView: NSView {
    override var isFlipped: Bool { true }
    init(height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: AccountMenu.width, height: height))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    func drawText(_ s: String, font: NSFont, color: NSColor, x: CGFloat, y: CGFloat, alignRight: Bool = false, maxWidth: CGFloat? = nil) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let w = min(attr.size().width, maxWidth ?? .greatestFiniteMagnitude)
        let h = attr.size().height
        attr.draw(with: NSRect(x: alignRight ? x - w : x, y: y, width: w, height: h), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// メールとプラン、右上に更新時刻
private final class AccountHeaderView: MenuInfoView {
    let email: String, detail: String, status: String
    init(email: String, detail: String, status: String) {
        self.email = email; self.detail = detail; self.status = status
        super.init(height: 42)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.width - AccountMenu.right
        let small = NSFont.systemFont(ofSize: 10.5)
        let statusW = (status as NSString).size(withAttributes: [.font: small]).width
        drawText(email, font: .systemFont(ofSize: 13, weight: .semibold), color: .labelColor, x: AccountMenu.left, y: 5,
                 maxWidth: r - AccountMenu.left)
        drawText(detail, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, x: AccountMenu.left, y: 23,
                 maxWidth: r - AccountMenu.left - statusW - 8)
        drawText(status, font: small, color: .tertiaryLabelColor, x: r, y: 24, alignRight: true)
    }
}

/// 「今週（全モデル）  57%」とバー、その下にリセットの日時
private final class UsageRowView: MenuInfoView {
    let limit: ClaudeAccount.Limit
    init(_ l: ClaudeAccount.Limit) {
        limit = l
        super.init(height: 46)
    }
    required init?(coder: NSCoder) { fatalError() }

    static func resetText(_ l: ClaudeAccount.Limit, now: Date = Date()) -> String {
        guard let d = l.resetsAt else { return l.resetsText.map { L("リセット: %@", $0) } ?? "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: L("ja_JP"))
        f.dateFormat = L("M月d日(E) H:mm")
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: L("ja_JP"))
        rel.unitsStyle = .short
        return L("%@ にリセット（%@）", f.string(from: d), rel.localizedString(for: d, relativeTo: now))
    }

    override func draw(_ dirtyRect: NSRect) {
        let l = AccountMenu.left, r = bounds.width - AccountMenu.right
        let pct = max(0, min(100, limit.percent))
        let color: NSColor = pct >= 90 ? .systemRed : pct >= 75 ? .systemOrange : .controlAccentColor
        drawText(limit.label, font: .systemFont(ofSize: 12.5), color: .labelColor, x: l, y: 3, maxWidth: r - l - 50)
        drawText("\(pct)%", font: .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold), color: pct >= 75 ? color : .labelColor,
                 x: r, y: 3, alignRight: true)
        let bar = NSRect(x: l, y: 21, width: r - l, height: 5)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2.5, yRadius: 2.5).fill()
        if pct > 0 {
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(5, bar.width * CGFloat(pct) / 100), height: bar.height),
                         xRadius: 2.5, yRadius: 2.5).fill()
        }
        drawText(Self.resetText(limit), font: .systemFont(ofSize: 10.5), color: .secondaryLabelColor, x: l, y: 29, maxWidth: r - l)
    }
}

/// 読めなかった理由など
private final class NoteView: MenuInfoView {
    let text: String
    init(_ t: String) {
        text = t
        super.init(height: 20)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        drawText(text, font: .systemFont(ofSize: 11), color: .secondaryLabelColor, x: AccountMenu.left, y: 2,
                 maxWidth: bounds.width - AccountMenu.left - AccountMenu.right)
    }
}
