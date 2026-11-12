import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: JellyManager!
    private var shortcuts: Shortcuts!
    private var statusBar: StatusBarController!
    private var pendingURLs: [URL] = []
    private var termSource: DispatchSourceSignal?
    private var urlThrottle = URLRoutes.Throttle()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 二重起動の防止（2つ目は即終了。URL は LaunchServices が既存側へ渡す）
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !others.isEmpty {
                NSApp.terminate(nil)
                return
            }
        }

        // 同じデータフォルダを 2 つのプロセスで使わない（.app の外から起動した開発用ビルドでも効くようにロックファイルで）
        if !AppPaths.acquireInstanceLock() {
            AppLog.write("another instance is using \(AppPaths.dataDir.path); exiting")
            NSApp.terminate(nil)
            return
        }

        // kill（SIGTERM）で終えられたときも、普通の終了と同じく保存してエージェントを止める（scripts/install.sh の入れ替えなど）
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { NSApp.terminate(nil) }
        term.resume()
        termSource = term

        // 自動化（デモ録画）用の合言葉を、URL を受け付ける前に用意する（普段は前回の残りを消すだけ）
        if URLRoutes.automationToken != nil { AppLog.write("automation mode: jellyfish:// with token accepted") }

        ShellEnvironment.shared.prefetch()
        DispatchQueue.global(qos: .utility).async { DataJanitor.cleanUp(dataDir: AppPaths.dataDir) }
        let store = Store()
        // 表示の言語は、メニューやウィンドウを作る前に決める
        L10n.setting = store.loadSettings().language
        installMainMenu()
        // 表示の言語を変えたら、メインメニュー（編集・ウインドウ）も作り直す
        NotificationCenter.default.addObserver(forName: JellyManager.languageChanged, object: nil, queue: .main) { [weak self] _ in
            self?.installMainMenu()
        }
        // 初めての起動（データフォルダにまだクラゲの記録がない）なら、使い方と権限の案内を出す
        let firstLaunch = !store.hasSavedJellies
        manager = JellyManager(store: store)
        shortcuts = Shortcuts(manager: manager)
        statusBar = StatusBarController(manager: manager, shortcuts: shortcuts)
        manager.start()
        let live = Set(manager.controllers.map(\.record.id))
        DispatchQueue.global(qos: .utility).async { DataJanitor.cleanUpRemovedAgents(dataDir: AppPaths.dataDir, live: live) }
        manager.prefetchBackend()
        shortcuts.registerAll()

        // 設定ファイルと実際の登録状態を合わせる（システム設定側で変更された場合も追従）
        if LoginItem.isAvailable {
            manager.updateSettings { $0.launchAtLogin = LoginItem.isEnabled }
        }

        pendingURLs.forEach(handle)
        pendingURLs.removeAll()

        AppLog.write("launch v\(AppInfo.version) (\(AppInfo.build)) macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if firstLaunch {
            let key = (shortcuts.activeNewJelly ?? manager.settings.newJellyHotKey).display
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                AppInfo.showWelcome(manager: self.manager, newJellyKey: key)
            }
        }
    }

    /// チャット欄で ⌘C / ⌘V / ⌘A / ⌘Z、ウィンドウの ⌘M / ⌘W / フルスクリーンが効くようにメインメニューを用意する
    private func installMainMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.submenu = m
            main.addItem(it)
        }
        func item(_ t: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        let about = NSMenuItem(title: L("Jellyfish AI について"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        sub("Jellyfish AI", [
            about,
            .separator(),
            item(L("Jellyfish AI を隠す"), #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item(L("Jellyfish AI を終了"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub(L("編集"), [
            item(L("取り消す"), Selector(("undo:")), "z"),
            item(L("やり直す"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item(L("カット"), #selector(NSText.cut(_:)), "x"),
            item(L("コピー"), #selector(NSText.copy(_:)), "c"),
            item(L("ペースト"), #selector(NSText.paste(_:)), "v"),
            item(L("すべてを選択"), #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            // Mac の音声入力（入力欄で話すと文字になる）
            item(L("音声入力を開始"), Selector(("startDictation:")), ""),
        ])
        sub(L("ウインドウ"), [
            item(L("しまう"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(L("拡大／縮小"), #selector(NSWindow.performZoom(_:)), ""),
            item(L("フルスクリーンにする"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            .separator(),
            item(L("閉じる"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = main
    }

    @objc private func showAbout() { AppInfo.showAbout() }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.shutdown()
    }

    /// 動いている最中に、アプリのアイコン（アプリケーションフォルダ・Spotlight・Dock・Launchpad）からもう一度開いたとき。
    /// 隠していたクラゲを出す。1 体もいなければ新しいクラゲを出して入力欄を開く
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard let manager else { return false }
        if manager.settings.allHidden {
            manager.setAllHidden(false)
        } else if manager.controllers.isEmpty {
            _ = manager.spawn()
        }
        return false
    }

    /// jellyfish:// URL スキーム（ショートカット.app・Raycast 等からの操作と、自動テスト・デモ録画用）
    /// 外から誰でも呼べる（Web ページのリンクからも開ける）ので、普段は URLRoutes.publicRoutes だけ受け付ける
    /// （続けざまの呼び出しは間引き、新しいクラゲは上限まで）。
    /// 指示の送信・PC 操作の許可・作業フォルダの変更・削除などは、環境変数 JELLYFISH_AUTOMATION=1 を付けて
    /// 起動し（scripts/demo/record.sh）、データフォルダの automation.token の合言葉を token=… で付けたときだけ動く
    ///   jellyfish://new[?chat=0&cwd=~/dir]    新しいクラゲ（chat=0 で入力欄を開かない、cwd で作業フォルダ）
    ///   jellyfish://type?agent=2&text=...     入力欄に 1 文字ずつ打ち込んで送信（デモ録画用、cps=打鍵/秒）
    ///   jellyfish://press?agent=2             長押しと同じ動作（デモ録画用）
    ///   jellyfish://rename?agent=2&name=調査係  名前を変える（空で Agent N に戻す）
    ///   jellyfish://link?a=2&b=3 | unlink     2 体をつなぐ / 切る
    ///   jellyfish://move?agent=2&dx=-120&dy=40[&mods=shift|option&t=0.8]  ドラッグして置く（デモ録画用）
    ///   jellyfish://toggle | show | hide      全体の表示切替
    ///   jellyfish://arrange                   右端に並べ直す
    ///   jellyfish://renumber                  番号を 1 から振り直す
    ///   jellyfish://state?agent=2&s=working   状態を設定（Phase 1 ではプレビュー用）
    ///   jellyfish://remove?agent=2            削除
    ///   jellyfish://scale?v=1.25              大きさ
    ///   jellyfish://style?v=pixel|realistic   見た目
    ///   jellyfish://login?on=1|0              ログイン時の自動起動
    ///   jellyfish://debug                     各エージェントの状態を app.log へ
    func application(_ application: NSApplication, open urls: [URL]) {
        if manager == nil { pendingURLs.append(contentsOf: urls); return }
        urls.forEach(handle)
    }

    private func handle(_ url: URL) {
        let host = String((url.host ?? "").prefix(32))
        guard URLRoutes.allowed(url, automationToken: URLRoutes.automationToken) else {
            if url.scheme == "jellyfish" { AppLog.write("url refused: \(host)（公開以外の操作は JELLYFISH_AUTOMATION=1 と合言葉が必要）") }
            return
        }
        let automation = URLRoutes.isAutomation(url, token: URLRoutes.automationToken)
        if !automation {
            guard urlThrottle.allow(host.lowercased()) else { AppLog.write("url throttled: \(host)"); return }
            if host.lowercased() == "new", manager.controllers.count >= TeamCoordinator.maxAgents {
                AppLog.write("url refused: new（クラゲが上限の \(TeamCoordinator.maxAgents) 体）")
                return
            }
        }
        if url.host != "debug" { AppLog.write("url: \(host)") }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ k: String) -> String? { q.first { $0.name == k }?.value }
        let agent = param("agent").flatMap(Int.init).flatMap { manager.controller(number: $0) }
        switch url.host ?? "" {
        case "new":
            // new?chat=0 で入力欄を開かない、new?cwd=~/foo で作業フォルダを指定（デモ・テスト用）
            // 外のアプリ・Web ページからのときは、チャットを出してもキーボードの入力先は奪わない
            let c = manager.spawn(openChat: param("chat") != "0", activate: automation)
            if let p = param("cwd"), let rt = manager.runtime(for: c) {
                rt.changeFolder(URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true))
            }
        case "type":
            // テスト用：jellyfish://type?agent=2&text=...&cps=14 で入力欄に打ち込んでから送信
            if let c = agent, let text = param("text") {
                manager.typePrompt(text, into: c, cps: param("cps").flatMap(Double.init) ?? 14, quick: param("quick") == "1")
            }
        case "press":
            if let c = agent { c.simulateLongPress() }
        case "rename":
            if let c = agent { let err = manager.rename(c, to: param("name") ?? ""); AppLog.write("rename -> \(err ?? "ok")") }
        case "link", "unlink":
            // jellyfish://link?a=2&b=3 でつなぐ / unlink で切る
            if let a = param("a").flatMap(Int.init).flatMap({ manager.controller(number: $0) }),
               let b = param("b").flatMap(Int.init).flatMap({ manager.controller(number: $0) }) {
                if url.host == "link" { manager.team?.link(a.record.id, b.record.id) }
                else if param("scissors") == "1" { manager.team?.cutWithScissors(a.record.id, b.record.id) }
                else { manager.team?.unlink(a.record.id, b.record.id) }
            }
        case "pc":
            // テスト用：jellyfish://pc?agent=2&on=1 で PC 操作を許可 / 0 で取り消す
            if let c = agent, let rt = manager.runtime(for: c) { rt.pcControl = param("on") == "1" }
        case "folder":
            if let c = agent, let p = param("path"), let rt = manager.runtime(for: c) {
                rt.changeFolder(URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true))
            }
        case "move":
            // デモ録画用：jellyfish://move?agent=2&dx=-120&dy=40 でドラッグしたように動かして置く
            // mods=shift でチームごと、mods=option で切り離し
            if let c = agent {
                var mods: NSEvent.ModifierFlags = []
                let m = param("mods") ?? ""
                if m.contains("shift") { mods.insert(.shift) }
                if m.contains("option") { mods.insert(.option) }
                manager.demoDrag(c, by: CGVector(dx: param("dx").flatMap(Double.init) ?? 0, dy: param("dy").flatMap(Double.init) ?? 0),
                                 duration: param("t").flatMap(Double.init) ?? 0.8, mods: mods)
            }
        case "toggle": manager.toggleAllHidden()
        case "show": manager.setAllHidden(false)
        case "hide": manager.setAllHidden(true)
        case "arrange": manager.arrangeAll()
        case "renumber": manager.renumber()
        case "state":
            if let c = agent, let s = param("s").flatMap(AgentState.init(rawValue:)) { c.setState(s) }
        case "remove":
            if let c = agent { manager.remove(c) }
        case "prompt":
            // テスト用：jellyfish://prompt?agent=2&text=... で指示を送る
            if let c = agent, let text = param("text"), let rt = manager.runtime(for: c) {
                let ok = rt.submit(text)
                AppLog.write("prompt submit agent=\(c.record.number) ok=\(ok) running=\(rt.isRunning)")
            } else {
                AppLog.write("prompt: agent/text/runtime missing agent=\(agent?.record.number ?? -1)")
            }
        case "open":
            if let c = agent { manager.openChat(for: c, activate: automation) }
        case "permissions":
            // 「🔐 権限」の画面を出す（表示だけ。許可を求めるのは、本人がその画面で「まとめて許可する」を押したあとの続きだけ）
            manager.showPermissions(done: param("done"))
        case "watchtest":
            // テスト用（合言葉つきの自動化のときだけ）：見守りの吹き出しを見本の画像で出す
            manager.debugWatchFinding()
        case "accounts":
            // 自動化（合言葉つき）のときだけ：アカウントと AI の画面
            manager.showAccounts()
        case "debug":
            for c in manager.controllers {
                let r = c.record
                AppLog.write("agent \(r.number) \(r.color.key) state=\(r.state.rawValue) visible=\(c.isVisible) animating=\(c.isAnimating) frame=\(NSStringFromRect(c.panel.frame))")
            }
        case "style":
            if let st = param("v").flatMap(AvatarStyle.init(rawValue:)) { manager.setStyle(st) }
        case "login":
            let want = param("on") == "1"
            let err = LoginItem.set(want)
            AppLog.write("login item set(\(want)) -> \(err ?? "ok"), status=\(LoginItem.statusText)")
            manager.updateSettings { $0.launchAtLogin = LoginItem.isEnabled }
        case "scale":
            if let v = param("v").flatMap(Double.init) { manager.setScale(min(max(v, 0.5), 2.0)) }
        default: break
        }
    }
}

/// jellyfish:// のどの操作を受け付けるか
enum URLRoutes {
    /// 外から呼ばれても困らない操作（表示の切り替え・新しいクラゲ・チャットを開く・見た目）
    static let publicRoutes: Set<String> = ["new", "toggle", "show", "hide", "arrange", "open", "style", "scale", "permissions"]

    static var automationEnabled: Bool { ProcessInfo.processInfo.environment["JELLYFISH_AUTOMATION"] == "1" }

    /// 自動化（JELLYFISH_AUTOMATION=1）で起動したときだけ作る合言葉。データフォルダの automation.token（本人だけが読める）に書き、
    /// URL に token=… が付いているときだけ公開以外の操作を受け付ける。環境変数が何かの拍子に付いたままになっても、
    /// 合言葉を読めない Web ページからは公開の操作しかできない
    static let automationToken: String? = {
        let url = AppPaths.dataDir.appendingPathComponent("automation.token")
        guard automationEnabled else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // SystemRandomNumberGenerator は macOS では暗号用の乱数（arc4random_buf）
        var rng = SystemRandomNumberGenerator()
        let token = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else { return nil }
        return token
    }()

    static func allowed(_ url: URL, automationToken: String?) -> Bool {
        guard url.scheme?.lowercased() == "jellyfish" else { return false }
        if isAutomation(url, token: automationToken) { return true }
        let host = (url.host ?? "").lowercased()
        guard publicRoutes.contains(host) else { return false }
        // 作業フォルダの指定は自動化のときだけ
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if host == "new", q.contains(where: { $0.name == "cwd" }) { return false }
        return true
    }

    /// 合言葉つきの（scripts/demo の録画からの）呼び出しか
    static func isAutomation(_ url: URL, token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let given = q.first(where: { $0.name == "token" })?.value else { return false }
        // 長さと中身を、途中で抜けずに比べる
        let a = Array(given.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// 外から続けざまに呼ばれても困らないように（Web ページが jellyfish://new を繰り返し開くなど）。
    /// 新しいクラゲは 3 秒に 1 回、それ以外の操作は 0.3 秒に 1 回まで
    struct Throttle {
        private var last: [String: Date] = [:]
        mutating func allow(_ host: String, now: Date = Date()) -> Bool {
            let gap: TimeInterval = host == "new" ? 3 : 0.3
            if let t = last[host], now.timeIntervalSince(t) < gap { return false }
            last[host] = now
            return true
        }
    }
}
