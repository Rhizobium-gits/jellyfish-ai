import AppKit

/// メニューバーのクラゲアイコン。クラゲを全部隠しても、ここから操作・再表示できる。
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let manager: JellyManager
    private let shortcuts: Shortcuts
    private let menu = NSMenu()

    init(manager: JellyManager, shortcuts: Shortcuts) {
        self.manager = manager
        self.shortcuts = shortcuts
        super.init()
        item.button?.image = MenuImages.statusIcon()
        item.button?.toolTip = "Jellyfish AI"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = manager.settings

        let newTitle = "新しいクラゲ"
        let newItem = ClosureMenuItem(newTitle) { [weak self] in self?.manager.spawn() }
        if let hk = shortcuts.activeNewJelly { applyShortcut(hk, to: newItem) }
        menu.addItem(newItem)

        let toggle = ClosureMenuItem(s.allHidden ? "クラゲを表示" : "クラゲを隠す") { [weak self] in
            self?.manager.toggleAllHidden()
        }
        if let hk = shortcuts.activeToggle { applyShortcut(hk, to: toggle) }
        menu.addItem(toggle)
        menu.addItem(ClosureMenuItem("右端に並べ直す") { [weak self] in self?.manager.arrangeAll() })

        // 過去の Claude Code セッション（VS Code やターミナルで作ったものも含む）を呼び出す
        let past = NSMenuItem(title: "過去のセッションを開く", action: nil, keyEquivalent: "")
        let pastMenu = NSMenu()
        pastMenu.autoenablesItems = false
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: "ja_JP")
        rel.unitsStyle = .short
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let sessions = ClaudeSessions.recent(limit: 20)
        if sessions.isEmpty { pastMenu.addItem(.header("（まだありません）")) }
        for info in sessions {
            let folder = (info.cwd ?? "").replacingOccurrences(of: home, with: "~")
            var title = info.title
            if title.count > 34 { title = String(title.prefix(34)) + "…" }
            let when = rel.localizedString(for: info.modified, relativeTo: Date())
            let mine = manager.agentNumber(forSession: info.id).map { "  🪼Agent \($0)" } ?? ""
            let it = ClosureMenuItem("\(title)\(mine)") { [weak self] in self?.manager.resumeSession(info) }
            it.toolTip = "\(folder)  ·  \(when)"
            // 2 行目にフォルダと日時
            let attr = NSMutableAttributedString(string: "\(title)\(mine)\n", attributes: [.font: NSFont.menuFont(ofSize: 13)])
            attr.append(NSAttributedString(string: "\(folder)  ·  \(when)", attributes: [.font: NSFont.menuFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]))
            it.attributedTitle = attr
            pastMenu.addItem(it)
        }
        past.submenu = pastMenu
        menu.addItem(past)

        if let note = shortcuts.conflictNote { menu.addItem(.header("⚠︎ \(note)")) }
        if let app = shortcuts.suspendedForApp { menu.addItem(.header("⌘L を一時解放中（\(app)）")) }

        menu.addItem(.separator())
        menu.addItem(.header("エージェント（\(manager.controllers.count)）"))
        for c in manager.controllers {
            let r = c.record
            let title = "\(r.title)　\(r.color.name) · \(r.state.label)" + (r.hidden ? "（非表示）" : "")
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.image = MenuImages.dot(r.color, state: r.state)
            let sub = NSMenu()
            sub.autoenablesItems = false
            manager.agentMenuItems(for: c, includeHeader: false).forEach { sub.addItem($0) }
            mi.submenu = sub
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        let style = NSMenuItem(title: "見た目", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for st in AvatarStyle.allCases {
            styleMenu.addItem(ClosureMenuItem(st.label, checked: s.avatarStyle == st) { [weak self] in
                self?.manager.setStyle(st)
            })
        }
        style.submenu = styleMenu
        menu.addItem(style)

        let scr = NSMenuItem(title: "画面認識", action: nil, keyEquivalent: "")
        let scrMenu = NSMenu()
        for m in ScreenMode.allCases {
            scrMenu.addItem(ClosureMenuItem(m.label, checked: s.screenMode == m) { [weak self] in self?.manager.updateSettings { $0.screenMode = m } })
        }
        scrMenu.addItem(.separator())
        scrMenu.addItem(ClosureMenuItem("使っていたアプリのある画面だけ撮る", checked: s.screenTarget == .activeDisplay) { [weak self] in
            self?.manager.updateSettings { $0.screenTarget = .activeDisplay }
        })
        scrMenu.addItem(ClosureMenuItem("すべてのディスプレイを撮る", checked: s.screenTarget == .allDisplays) { [weak self] in
            self?.manager.updateSettings { $0.screenTarget = .allDisplays }
        })
        scrMenu.addItem(.separator())
        scrMenu.addItem(.header(ScreenContext.hasPermission() ? "画面収録の権限: 許可済み" : "画面収録の権限: 未許可（初回の撮影時に確認が出ます）"))
        scr.submenu = scrMenu
        menu.addItem(scr)

        let size = NSMenuItem(title: "大きさ", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (label, v) in [("小", 0.8), ("標準", 1.0), ("大", 1.25), ("特大", 1.5)] {
            sizeMenu.addItem(ClosureMenuItem(label, checked: abs(s.jellyScale - v) < 0.01) { [weak self] in
                self?.manager.setScale(v)
            })
        }
        size.submenu = sizeMenu
        menu.addItem(size)

        let fps = NSMenuItem(title: "なめらかさ（リアル）", action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        for (label, mx, calm) in [("標準（待機中は 30fps）", 60, 30), ("常に 60fps", 60, 60), ("省電力（常に 30fps）", 30, 30)] {
            fpsMenu.addItem(ClosureMenuItem(label, checked: s.maxFPS == mx && s.calmFPS == calm) { [weak self] in
                self?.manager.setFrameRates(max: mx, calm: calm)
            })
        }
        fps.submenu = fpsMenu
        menu.addItem(fps)

        // 実際に付与している権限を確認できるように
        let policy = NSMenuItem(title: "実行ポリシー", action: nil, keyEquivalent: "")
        let pm = NSMenu()
        pm.autoenablesItems = false
        pm.addItem(.header("すべてのクラゲ共通：\(manager.policyDescription)"))
        pm.addItem(.header("claude -p --permission-mode \(manager.backend().map { ($0 as? ClaudeCodeBackend)?.permissionMode ?? "" } ?? s.permissionMode)"))
        pm.addItem(.header("・確認なしでファイル作成/編集/削除・コマンド実行"))
        pm.addItem(.header("・認証情報の持ち出し、意図しない外部送信、取り返しのつかない操作は"))
        pm.addItem(.header("　Claude Code の安全判定で止まる（OS の権限設定は変更しない）"))
        pm.addItem(.header("・作業フォルダはクラゲごと（既定はホーム）"))
        pm.addItem(.separator())
        pm.addItem(.header("claude: \(manager.claudePathDescription)"))
        policy.submenu = pm
        menu.addItem(policy)

        // エージェント同士の分業
        let teamItem = NSMenuItem(title: "チーム（分業）", action: nil, keyEquivalent: "")
        let tm = NSMenu()
        tm.autoenablesItems = false
        tm.addItem(ClosureMenuItem("エージェント同士の分業を使う", checked: s.teamEnabled) { [weak self] in
            self?.manager.updateSettings { $0.teamEnabled.toggle() }
            self?.manager.team?.refresh()
        })
        tm.addItem(.separator())
        tm.addItem(.header("・クラゲを別のクラゲの隣に置くと線でつながり、同じチームになる"))
        tm.addItem(.header("・チームの仲間に作業を頼む / 新しい仲間を作って分担する（Claude Code の MCP ツール）"))
        tm.addItem(.header("・線の上の光：依頼（依頼元の色）と結果（依頼先の色）の受け渡し"))
        tm.addItem(.header("・線にポインタを置くと ✂︎ で切れる（右クリック > つながり でも可）"))
        tm.addItem(.header("・1 チーム最大 \(TeamCoordinator.maxTeamSize) 体、エージェントが作れるのは 2 段まで"))
        teamItem.submenu = tm
        menu.addItem(teamItem)

        let login = ClosureMenuItem("ログイン時に自動起動", checked: LoginItem.isEnabled) { [weak self] in
            let want = !LoginItem.isEnabled
            if let err = LoginItem.set(want) {
                let a = NSAlert()
                a.messageText = "自動起動を設定できませんでした"
                a.informativeText = err
                a.runModal()
            }
            self?.manager.updateSettings { $0.launchAtLogin = LoginItem.isEnabled }
        }
        login.isEnabled = LoginItem.isAvailable
        menu.addItem(login)
        menu.addItem(ClosureMenuItem("設定フォルダを開く") { [weak self] in
            guard let dir = self?.manager.store.dir else { return }
            NSWorkspace.shared.open(dir)
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Jellyfish AI を終了", key: "q") { NSApp.terminate(nil) })
    }

    private func applyShortcut(_ hk: HotKeySpec, to item: NSMenuItem) {
        item.keyEquivalent = HotKeySpec.keyName(hk.keyCode).lowercased()
        var m: NSEvent.ModifierFlags = []
        if hk.modifiers & UInt32(1 << 8) != 0 { m.insert(.command) }
        if hk.modifiers & UInt32(1 << 9) != 0 { m.insert(.shift) }
        if hk.modifiers & UInt32(1 << 11) != 0 { m.insert(.option) }
        if hk.modifiers & UInt32(1 << 12) != 0 { m.insert(.control) }
        item.keyEquivalentModifierMask = m
    }
}
