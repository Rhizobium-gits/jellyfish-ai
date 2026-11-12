import AppKit
import ApplicationServices

/// macOS の許可（プライバシーとセキュリティ）。何に使うか・いまの状態・システム設定の場所。
/// 許可そのものは macOS の公式の画面で本人が付ける（Jellyfish は付けられないし、OS の仕組みを外さない）。
/// アプリにできるのは、前の版に付いた効かない許可を tccutil で消すこと、許可を求めること、取り消すこと
enum AppPermission: String, CaseIterable {
    case accessibility, screenRecording, fullDiskAccess, automation

    var title: String {
        switch self {
        case .accessibility: return L("アクセシビリティ")
        case .screenRecording: return L("画面収録")
        case .fullDiskAccess: return L("フルディスクアクセス")
        case .automation: return L("オートメーション（ほかのアプリの操作）")
        }
    }

    /// 付けると何ができるようになるか（Full Access の範囲）
    var scope: String {
        switch self {
        case .accessibility: return L("PC 操作でクリック・キー入力をする（PC 操作をオンにしたクラゲだけ。スクリプトからの入力の合成も、この許可の範囲で動けます）")
        case .screenRecording: return L("画面の撮影（「この画面」の添付・PC 操作）と、🎧 システムの音の文字起こし")
        case .fullDiskAccess: return L("エージェントが、デスクトップ・書類・ダウンロード・ほかのアプリのデータなどを、そのたびに聞かれずに読み書きする")
        case .automation: return L("エージェントが AppleScript などでほかのアプリ（Finder・ブラウザなど）を操作する。アプリごとに macOS が確認します")
        }
    }

    /// tccutil のサービス名（取り消し・古い許可の削除に使う）
    var services: [String] {
        switch self {
        case .accessibility: return ["Accessibility"]
        case .screenRecording: return ["ScreenCapture"]
        case .fullDiskAccess: return ["SystemPolicyAllFiles", "SystemPolicyDesktopFolder", "SystemPolicyDocumentsFolder", "SystemPolicyDownloadsFolder"]
        case .automation: return ["AppleEvents"]
        }
    }

    /// システム設定のその場所
    var settingsURL: URL {
        let anchor: String
        switch self {
        case .accessibility: anchor = "Privacy_Accessibility"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        case .automation: anchor = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// いま効いているか（nil = アプリごとに決まるので一言では言えない）。確かめるときに確認のダイアログは出さない
    var granted: Bool? {
        switch self {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .fullDiskAccess: return AppPermission.hasFullDiskAccess()
        case .automation: return nil
        }
    }

    /// フルディスクアクセスがあるか：守られたファイル（このユーザーのプライバシーの記録）を開けるかだけ見る。中身は読まない。
    /// フルディスクアクセスは確認のダイアログを出さないので、確かめても何も出ない
    static func hasFullDiskAccess(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let f = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let h = try? FileHandle(forReadingFrom: f) else { return false }
        try? h.close()
        return true
    }

    /// まとめて許可するときに古い許可を消すサービス（いま効いていないものだけ。オートメーションは効いているかを確かめられないので消さない）
    static func servicesToReset(_ statuses: [AppPermission: Bool?]) -> [String] {
        AppPermission.allCases.filter { p in
            guard let g = statuses[p] ?? nil else { return false }
            return !g
        }.flatMap(\.services)
    }

    /// アプリの中の permissions.sh（無ければ nil）
    static func script(bundle: URL = Bundle.main.bundleURL) -> URL? {
        let s = bundle.appendingPathComponent("Contents/Resources/permissions.sh")
        return FileManager.default.isExecutableFile(atPath: s.path) ? s : nil
    }

    /// ターミナルで実行するコマンド（確認の画面にそのまま出す）
    static func command(_ sub: String, services: [String] = [], bundle: URL = Bundle.main.bundleURL) -> String? {
        guard let s = script(bundle: bundle) else { return nil }
        let allowed = Set(AppPermission.allCases.flatMap(\.services))
        let args = services.filter { allowed.contains($0) }
        return ([EngineLogin.shellQuote(s.path), sub] + args).joined(separator: " ")
    }
}

/// 「🔐 権限」の画面：何を許しているか（Full Access の範囲と、実際に付いている許可）を見て、まとめて許可・取り消しをする
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    private weak var manager: JellyManager?
    private let window: NSWindow
    private var rows: [AppPermission: NSTextField] = [:]
    private let signing = NSTextField(wrappingLabelWithString: "")
    private let signButton = NSButton(title: "", target: nil, action: nil)
    private var timer: Timer?
    /// 「まとめて許可する」を押して、ターミナルで古い許可を消しているところ（終わったら permissions.sh が jellyfish://permissions?done=grant を開く）
    private(set) var waitingForGrant = false

    init(manager: JellyManager) {
        self.manager = manager
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520), styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = L("🔐 権限（Full Access）")
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
    }

    private func build() {
        var views: [NSView] = []
        let intro = NSTextField(wrappingLabelWithString: L("Jellyfish AI に付いている macOS の許可です。許可そのものは、システム設定で本人がオンにします（Jellyfish は付けられません）。ここでは、効いていない古い許可を消して許可を求め直したり、まとめて取り消したりできます。実行するコマンドは、押す前に確認の画面に出ます。"))
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        views.append(intro)
        for p in AppPermission.allCases {
            let name = NSTextField(labelWithString: p.title)
            name.font = .systemFont(ofSize: 13, weight: .semibold)
            let scope = NSTextField(wrappingLabelWithString: p.scope)
            scope.font = .systemFont(ofSize: 11)
            scope.textColor = .secondaryLabelColor
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 12, weight: .medium)
            let left = NSStackView(views: [name, scope])
            left.orientation = .vertical
            left.alignment = .leading
            left.spacing = 2
            let open = NSButton(title: L("システム設定で開く"), target: self, action: #selector(openSettings(_:)))
            open.identifier = NSUserInterfaceItemIdentifier(p.rawValue)
            open.bezelStyle = .rounded
            let row = NSStackView(views: [left, NSView(), status, open])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            left.setContentHuggingPriority(.defaultLow, for: .horizontal)
            scope.preferredMaxLayoutWidth = 360
            rows[p] = status
            views.append(row)
        }
        signing.font = .systemFont(ofSize: 11.5)
        signing.preferredMaxLayoutWidth = 600
        views.append(signing)
        let grant = NSButton(title: L("まとめて許可する…"), target: self, action: #selector(grantAll))
        grant.bezelStyle = .rounded
        grant.keyEquivalent = "\r"
        let revoke = NSButton(title: L("まとめて取り消す…"), target: self, action: #selector(revokeAll))
        revoke.bezelStyle = .rounded
        signButton.target = self
        signButton.action = #selector(fixSignature)
        signButton.bezelStyle = .rounded
        signButton.title = L("固定の署名にする…")
        let close = NSButton(title: L("閉じる"), target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [grant, revoke, signButton, NSView(), close])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        views.append(buttons)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        for v in views { v.translatesAutoresizingMaskIntoConstraints = false; v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true }
        window.contentView = stack
        stack.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 640, height: max(360, stack.fittingSize.height)))
    }

    func show() {
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh() {
        for p in AppPermission.allCases {
            guard let f = rows[p] else { continue }
            switch p.granted {
            case true?: f.stringValue = L("✓ 許可"); f.textColor = .systemGreen
            case false?: f.stringValue = L("✗ 未許可"); f.textColor = .systemOrange
            case nil: f.stringValue = L("アプリごと"); f.textColor = .secondaryLabelColor
            }
        }
        let adhoc = AppUpdater.isAdhoc(Bundle.main.bundleURL)
        let source = PermissionsWindowController.sourceCheckout()
        signing.stringValue = adhoc
            ? L("⚠️ この版は仮の署名（ad-hoc）です。macOS は更新のたびに別のアプリとみなすので、システム設定のスイッチがオンのままでも前の版の許可は効かず、何度も許可を求められます。「まとめて許可する」で古い許可を消して許可し直してください。") + " "
                + (source != nil ? L("ソースから入れているので「固定の署名にする」で、次からの更新でも許可が続くようにできます。") : "")
            : L("✓ 証明書で署名した版です。同じ証明書で署名した版に更新しても、許可は続きます。")
        signButton.isHidden = !(adhoc && source != nil)
    }

    /// scripts/install.sh が覚えたソースのフォルダ（git の checkout で、署名と入れるスクリプトがあるときだけ）
    static func sourceCheckout(dataDir: URL = AppPaths.dataDir) -> String? {
        SourceCheckout.validated(dataDir: dataDir, needs: ["signing.sh", "install.sh"])
    }

    // MARK: 操作

    @objc private func openSettings(_ sender: NSButton) {
        guard let p = sender.identifier.flatMap({ AppPermission(rawValue: $0.rawValue) }) else { return }
        NSWorkspace.shared.open(p.settingsURL)
    }

    @objc private func grantAll() {
        var statuses: [AppPermission: Bool?] = [:]
        for p in AppPermission.allCases { statuses[p] = p.granted }
        let reset = AppPermission.servicesToReset(statuses)
        let a = NSAlert()
        a.messageText = L("まとめて許可しますか？")
        var text = L("次のことをします:") + "\n"
        if !reset.isEmpty, let cmd = AppPermission.command("grant", services: reset) {
            text += L("1. いま効いていない許可（前の版に付いたもの）を、ターミナルで消します（Jellyfish AI の分だけ）:") + "\n" + cmd + "\n"
            text += L("2. Jellyfish AI が許可を求めます。出てきた macOS の確認と、システム設定の画面で Jellyfish AI をオンにしてください") + "\n"
        } else {
            text += L("1. Jellyfish AI が許可を求めます。出てきた macOS の確認と、システム設定の画面で Jellyfish AI をオンにしてください") + "\n"
        }
        text += "\n" + L("フルディスクアクセスは確認が出ないので、システム設定の画面で Jellyfish AI をオンにします（要らなければオンにしなくて構いません）。付けた許可は、ここの「まとめて取り消す」でいつでも外せます。")
        a.informativeText = text
        a.addButton(withTitle: L("許可する"))
        a.addButton(withTitle: L("キャンセル"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if !reset.isEmpty, let cmd = AppPermission.command("grant", services: reset) {
            waitingForGrant = true
            if !runInTerminal(cmd, name: "permissions") { waitingForGrant = false; NSSound.beep() }
            AppLog.write("permissions: reset stale \(reset.joined(separator: ","))")
        } else {
            requestNow()
        }
    }

    /// 古い許可を消し終わった（permissions.sh grant から）か、すぐに求めるとき
    func grantFinished() {
        guard waitingForGrant else { show(); return }
        waitingForGrant = false
        requestNow()
    }

    private func requestNow() {
        // アクセシビリティ：macOS の確認（システム設定を開くボタンつき）。画面収録：macOS の確認
        DesktopControl.requestPermissions()
        // フルディスクアクセスは確認が出ないので、場所を開く
        if !AppPermission.hasFullDiskAccess() { NSWorkspace.shared.open(AppPermission.fullDiskAccess.settingsURL) }
        AppLog.write("permissions: requested")
        show()
    }

    @objc private func revokeAll() {
        guard let cmd = AppPermission.command("revoke") else { NSSound.beep(); return }
        let a = NSAlert()
        a.messageText = L("まとめて取り消しますか？")
        a.informativeText = L("すべてのクラゲの PC 操作をオフにし、🎧 の聞き取りを止めてから、Jellyfish AI に付いている macOS の許可をすべて取り消します（アクセシビリティ・画面収録・フルディスクアクセス・デスクトップなどのフォルダ・オートメーション。ほかのアプリの許可には触りません）。ターミナルで次のコマンドを実行します:") + "\n\n" + cmd
        a.alertStyle = .warning
        a.addButton(withTitle: L("取り消す"))
        a.addButton(withTitle: L("キャンセル"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        manager?.disableAllPrivileges()
        if !runInTerminal(cmd, name: "permissions") { NSSound.beep() }
        AppLog.write("permissions: revoke all")
    }

    @objc private func fixSignature() {
        guard let src = PermissionsWindowController.sourceCheckout() else { return }
        let q = EngineLogin.shellQuote
        let cmd = "cd \(q(src)) && scripts/signing.sh create && scripts/install.sh"
        let a = NSAlert()
        a.messageText = L("固定の署名にしますか？")
        a.informativeText = L("ログインキーチェーンに Jellyfish 専用の署名用の証明書（自己署名）を作り、それで署名し直して入れ替えます。macOS は「同じ証明書で署名した Jellyfish AI」を同じアプリとみなすので、次からの更新でも許可が続きます。ターミナルで次のコマンドを実行します:") + "\n\n" + cmd + "\n\n"
            + L("署名のときに macOS が「codesign がキーを使おうとしています」と聞くので、「許可」を選んでください（「常に許可」にすると、ほかのプログラムも確認なしでこの証明書を使えるようになります）。入れ替えたあと、もう一度だけ「まとめて許可する」をしてください。")
        a.addButton(withTitle: L("署名して入れ替える"))
        a.addButton(withTitle: L("キャンセル"))
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if manager?.anyAgentBusy == true {
            UpdateChecker.fallback(L("作業中のクラゲがいます。終わってからもう一度試してください。"), offerPage: false)
            return
        }
        if !runInTerminal(cmd, name: "signing") { NSSound.beep() }
        AppLog.write("permissions: fix signature")
    }

    private func runInTerminal(_ command: String, name: String) -> Bool {
        let q = EngineLogin.shellQuote
        let text = ["#!/bin/zsh -l", "clear",
                    "printf '%s\\n\\n  %s\\n\\n' \(q("🪼 Jellyfish AI: " + L("あなたが許可したコマンドを実行します:"))) \(q(command))",
                    command].joined(separator: "\n") + "\n"
        return EngineLogin.openScript(text, name: name)
    }

    @objc private func closeWindow() { window.performClose(nil) }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
