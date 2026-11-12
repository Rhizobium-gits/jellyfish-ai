import AppKit

/// 「アカウントと AI」：Claude・ChatGPT（Codex）・Gemini のログインの状態、ログイン、入れ方、使う AI の選択。
/// 初めての起動のときと、メニューバーのクラゲ › 🔑 アカウントと AI から開く。
/// ログインは各 CLI の公式の画面（ターミナルとブラウザ）で本人が行い、Jellyfish はパスワード・トークン・API キーを受け取らない
final class AccountsWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    weak var manager: JellyManager?
    private struct Row { let use: NSButton; let status: NSTextField; let login: NSButton; let setup: NSButton }
    private var rows: [AgentEngine: Row] = [:]
    private let billing = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?

    init(manager: JellyManager) {
        self.manager = manager
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = L("アカウントと AI")
        window.isReleasedWhenClosed = false
        window.delegate = self

        let title = NSTextField(labelWithString: L("使う AI にログインする"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let intro = NSTextField(wrappingLabelWithString: L("エージェントは、この Mac に入っている各 AI の公式の CLI を、あなたのアカウントのログインのまま動かします。ログインはそれぞれの公式の画面（ターミナルとブラウザ）で行い、Jellyfish はパスワード・トークン・API キーを受け取りません。使う AI はクラゲごとにチャットでも変えられます。"))
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 12)

        var views: [NSView] = [title, intro]
        for e in AgentEngine.allCases {
            let use = NSButton(radioButtonWithTitle: "", target: self, action: #selector(useEngine(_:)))
            use.identifier = NSUserInterfaceItemIdentifier(e.rawValue)
            use.toolTip = L("クラゲごとに選んでいないときに使う AI にする")
            let name = NSTextField(labelWithString: e.displayName)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            let sub = NSTextField(labelWithString: "\(e.cliTitle) · \(e.accountKind)")
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            let status = NSTextField(labelWithString: L("確認中…"))
            status.font = .systemFont(ofSize: 11.5)
            status.lineBreakMode = .byTruncatingTail
            let left = NSStackView(views: [name, sub, status])
            left.orientation = .vertical
            left.alignment = .leading
            left.spacing = 2
            let login = NSButton(title: L("ログイン…"), target: self, action: #selector(login(_:)))
            login.identifier = NSUserInterfaceItemIdentifier(e.rawValue)
            let setup = NSButton(title: L("入れてログイン…"), target: self, action: #selector(setup(_:)))
            setup.identifier = NSUserInterfaceItemIdentifier(e.rawValue)
            for b in [login, setup] { b.bezelStyle = .rounded; b.controlSize = .regular }
            let row = NSStackView(views: [use, left, NSView(), setup, login])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
            left.setContentHuggingPriority(.defaultLow, for: .horizontal)
            status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rows[e] = Row(use: use, status: status, login: login, setup: setup)
            views.append(row)
        }
        billing.font = .systemFont(ofSize: 11.5)
        billing.textColor = .secondaryLabelColor
        views.append(billing)
        let close = NSButton(title: L("閉じる"), target: self, action: #selector(closeWindow))
        close.keyEquivalent = "\r"
        let footer = NSStackView(views: [NSView(), close])
        footer.orientation = .horizontal
        views.append(footer)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        var cs = [stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                  stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                  content.widthAnchor.constraint(equalToConstant: 640)]
        for v in views { cs.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44)) }
        NSLayoutConstraint.activate(cs)
        window.contentView = content
    }

    func show() {
        refresh()
        manager?.refreshEngineStatus()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 開いている間は、ターミナルでログインしたらすぐ分かるよう、ときどき確かめ直す
        timer?.invalidate()
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in self?.manager?.refreshEngineStatus() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        guard let m = manager else { return }
        for (e, r) in rows {
            r.use.state = m.settings.engine == e ? .on : .off
            let s = EngineAuth.shared.cached(e)
            r.status.stringValue = s?.summary ?? L("確認中…")
            r.status.textColor = s?.usable == true ? .systemGreen : (s.map { if case .paidAPI = $0.login { return NSColor.systemOrange }; return .secondaryLabelColor } ?? .secondaryLabelColor)
            if let v = s?.version { r.status.stringValue += "  ·  v\(v)" }
            let installed = s.map { if case .notInstalled = $0.login { return false }; return true } ?? true
            r.login.isHidden = !installed
            r.login.title = s?.usable == true ? L("別のアカウントで…") : L("ログイン…")
            r.setup.isHidden = installed
        }
        billing.stringValue = m.settings.allowAPIBilling
            ? L("⚠️ API キー（従量課金）での利用を許可しています。メニューバーのクラゲ › 🔑 アカウントと AI でオフにできます。")
            : L("💳 勝手に課金しません：API キー（従量課金）でログインしている AI は使わず、シェルの設定にある API キーも CLI に渡しません。サブスクリプション（Claude・ChatGPT・Google のアカウント）でログインしてください。")
    }

    private func engine(_ sender: NSButton) -> AgentEngine? { sender.identifier.flatMap { AgentEngine(rawValue: $0.rawValue) } }

    @objc private func useEngine(_ sender: NSButton) {
        guard let e = engine(sender) else { return }
        manager?.setDefaultEngine(e)
        refresh()
    }

    @objc private func login(_ sender: NSButton) {
        guard let e = engine(sender) else { return }
        manager?.openLogin(e)
    }

    @objc private func setup(_ sender: NSButton) {
        guard let e = engine(sender) else { return }
        manager?.offerInstall(e)
    }

    @objc private func closeWindow() { window.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
