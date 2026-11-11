import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var manager: JellyManager!
    private var shortcuts: Shortcuts!
    private var statusBar: StatusBarController!
    private var pendingURLs: [URL] = []

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

        ShellEnvironment.shared.prefetch()
        installMainMenu()
        let store = Store()
        manager = JellyManager(store: store)
        shortcuts = Shortcuts(manager: manager)
        statusBar = StatusBarController(manager: manager, shortcuts: shortcuts)
        manager.start()
        manager.prefetchBackend()
        shortcuts.registerAll()

        // 設定ファイルと実際の登録状態を合わせる（システム設定側で変更された場合も追従）
        if LoginItem.isAvailable {
            manager.updateSettings { $0.launchAtLogin = LoginItem.isEnabled }
        }

        pendingURLs.forEach(handle)
        pendingURLs.removeAll()
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
        sub("Jellyfish AI", [
            item("Jellyfish AI を隠す", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Jellyfish AI を終了", #selector(NSApplication.terminate(_:)), "q"),
        ])
        sub("編集", [
            item("取り消す", Selector(("undo:")), "z"),
            item("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("カット", #selector(NSText.cut(_:)), "x"),
            item("コピー", #selector(NSText.copy(_:)), "c"),
            item("ペースト", #selector(NSText.paste(_:)), "v"),
            item("すべてを選択", #selector(NSText.selectAll(_:)), "a"),
        ])
        sub("ウインドウ", [
            item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("拡大／縮小", #selector(NSWindow.performZoom(_:)), ""),
            item("フルスクリーンにする", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            .separator(),
            item("閉じる", #selector(NSWindow.performClose(_:)), "w"),
        ])
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager?.shutdown()
    }

    /// jellyfish:// URL スキーム（自動テスト・ショートカット.app・Raycast 等からの操作用）
    ///   jellyfish://new[?chat=0&cwd=~/dir]    新しいクラゲ（chat=0 で入力欄を開かない、cwd で作業フォルダ）
    ///   jellyfish://type?agent=2&text=...     入力欄に 1 文字ずつ打ち込んで送信（デモ録画用、cps=打鍵/秒）
    ///   jellyfish://press?agent=2             長押しと同じ動作（デモ録画用）
    ///   jellyfish://rename?agent=2&name=調査係  名前を変える（空で Agent N に戻す）
    ///   jellyfish://link?a=2&b=3 | unlink     2 体をつなぐ / 切る
    ///   jellyfish://move?agent=2&dx=-120&dy=40[&mods=shift|option&t=0.8]  ドラッグして置く（デモ録画用）
    ///   jellyfish://toggle | show | hide      全体の表示切替
    ///   jellyfish://arrange                   右端に並べ直す
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
        guard url.scheme == "jellyfish" else { return }
        if url.host != "debug" { AppLog.write("url: \(url.host ?? "") \(url.query?.prefix(60) ?? "")") }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ k: String) -> String? { q.first { $0.name == k }?.value }
        let agent = param("agent").flatMap(Int.init).flatMap { manager.controller(number: $0) }
        switch url.host ?? "" {
        case "new":
            // new?chat=0 で入力欄を開かない、new?cwd=~/foo で作業フォルダを指定（デモ・テスト用）
            let c = manager.spawn(openChat: param("chat") != "0")
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
            if let c = agent { manager.openChat(for: c) }
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
