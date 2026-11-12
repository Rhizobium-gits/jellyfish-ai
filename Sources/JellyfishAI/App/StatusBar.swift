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
        startAnimation()
        ClaudeAccount.shared.onChange = { [weak self] in self?.accountChanged() }
    }

    // MARK: アカウントと使用量（メニューを開いたときに読み、読み終わったら開いたままのメニューを差し替える）

    private var menuOpen = false

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func accountChanged() {
        guard menuOpen else { return }
        for it in menu.items.reversed() where AccountMenu.tags.contains(it.tag) { menu.removeItem(it) }
        for (i, it) in AccountMenu.items(ClaudeAccount.shared.snapshot, loading: ClaudeAccount.shared.loading).enumerated() {
            menu.insertItem(it, at: i)
        }
    }

    // MARK: アイコンのアニメーション（待機 = ゆっくり上下とまばたき、考え中 = 「…」、作業中 = 歩く）

    private var animTimer: Timer?
    private var tick = 0

    private func startAnimation() {
        let t = Timer(timeInterval: 1.0 / 6.0, repeats: true) { [weak self] _ in self?.animate() }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        animTimer = t
    }

    private func animate() {
        tick += 1
        let states = manager.controllers.map(\.record.state)
        var p = MenuImages.StatusPose()
        if states.contains(.working) {
            p.legs = tick % 2 == 0 ? 1 : 2
            p.lift = tick % 4 < 2 ? 1 : 0
            p.arms = tick % 4 < 2
        } else if states.contains(.thinking) {
            p.dots = (tick / 2) % 4
            p.lift = (tick / 6) % 2
        } else {
            // 6fps のうち 3 コマごとに判定（実質 2fps）。2 秒ごとに上下、たまにまばたき
            if tick % 3 != 0 { return }
            let slow = tick / 3
            p.lift = (slow / 4) % 2
            p.blink = slow % 11 == 0
        }
        let img = MenuImages.statusFrame(p)
        if item.button?.image !== img { item.button?.image = img }
    }

    /// 自律組織：タスクに合わせてエージェントが自分でチームを組み、成果と反応から組織の選び方を学ぶ
    private func orgMenuItem(_ s: AppSettings) -> NSMenuItem {
        let item = NSMenuItem(title: L("🧬 自律組織"), action: nil, keyEquivalent: "")
        let om = NSMenu()
        om.autoenablesItems = false
        om.addItem(ClosureMenuItem(L("自律組織モード（依頼に合わせてチームを自分で組む）"), checked: s.orgMode) { [weak self] in
            // チームの仕組みを使うので、オンにするときはチーム（分業）もオンにする
            self?.manager.updateSettings { $0.orgMode.toggle(); if $0.orgMode { $0.teamEnabled = true } }
            self?.manager.team?.refresh()
        })
        om.addItem(ClosureMenuItem(L("成果と反応から学ぶ（この Mac の中だけ）"), checked: s.orgLearning) { [weak self] in
            self?.manager.updateSettings { $0.orgLearning.toggle() }
        })
        om.addItem(.separator())
        if let org = manager.team?.org {
            let sum = org.summary()
            om.addItem(.header(L("学んだ依頼 %ld 件 · 世代 %ld · 組織の型 %ld（引退 %ld）", sum.learned, sum.generation, sum.active, sum.retired)))
            for b in sum.bestByTag.prefix(5) {
                om.addItem(.header(L("・%@ → %@（%ld 件・平均 %@）", OrgLearner.tagLabel(b.tag), b.genome.label, b.n, String(format: "%.2f", b.mean))))
            }
            if sum.bestByTag.isEmpty { om.addItem(.header(L("・まだ学んだ依頼はありません。はじめは依頼の種類から組織を選びます"))) }
            om.addItem(ClosureMenuItem(L("学習のレポートを開く")) {
                if !FileManager.default.fileExists(atPath: org.reportURL.path) {
                    try? OrgLearner.report(org.episodes, org.population, events: []).write(to: org.reportURL, atomically: true, encoding: .utf8)
                }
                NSWorkspace.shared.open(org.reportURL)
            })
            om.addItem(ClosureMenuItem(L("今の組織を解散（自律組織で作った、空いている仲間を片付ける）")) { [weak self] in
                _ = self?.manager.team?.dissolveAllIdleOrgMembers()
            })
            om.addItem(ClosureMenuItem(L("学習をリセット…")) {
                let a = NSAlert()
                a.messageText = L("自律組織の学習をリセットしますか？")
                a.informativeText = L("これまでの依頼の記録（%ld 件）と、進化した組織の型を消して、はじめの状態に戻します。", org.episodes.count)
                a.addButton(withTitle: L("リセット"))
                a.addButton(withTitle: L("キャンセル"))
                NSApp.activate(ignoringOtherApps: true)
                if a.runModal() == .alertFirstButtonReturn { org.reset() }
            })
        }
        om.addItem(.separator())
        om.addItem(.header(L("・依頼のたびに、学習からおすすめの組織（一人で・分担・順番・別案・階層 ＋ レビュー係）を選んでリーダーに伝える")))
        om.addItem(.header(L("・リーダー（頼んだクラゲ）が form_team で仲間を作り、役割と順番を決めて任せる")))
        om.addItem(.header(L("・結果（完了・失敗・時間）と 👍👎・やり直し・続けて送った言葉から点数を付けて学ぶ")))
        om.addItem(.header(L("・成績のよい組織を少し変えた型が生まれ、悪い型は引退する（未知の依頼にも似た依頼から当てはめる）")))
        om.addItem(.header(L("・仲間の分だけ Claude Code の使用量が増える。PC 操作は仲間には渡らない")))
        item.submenu = om
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = manager.settings

        ClaudeAccount.shared.refreshIfStale(claudeOverride: s.claudePath)
        AccountMenu.items(ClaudeAccount.shared.snapshot, loading: ClaudeAccount.shared.loading).forEach { menu.addItem($0) }
        if URLRoutes.automationToken != nil {
            menu.addItem(.header(L("⚠️ 自動化モード（JELLYFISH_AUTOMATION=1）：合言葉つきの jellyfish:// で指示の送信なども受け付けています")))
            menu.addItem(.separator())
        }

        let newTitle = L("新しいクラゲ")
        let newItem = ClosureMenuItem(newTitle) { [weak self] in self?.manager.spawn() }
        if let hk = shortcuts.activeNewJelly { applyShortcut(hk, to: newItem) }
        menu.addItem(newItem)

        let toggle = ClosureMenuItem(s.allHidden ? L("クラゲを表示") : L("クラゲを隠す")) { [weak self] in
            self?.manager.toggleAllHidden()
        }
        if let hk = shortcuts.activeToggle { applyShortcut(hk, to: toggle) }
        menu.addItem(toggle)
        menu.addItem(ClosureMenuItem(L("右端に並べ直す")) { [weak self] in self?.manager.arrangeAll() })

        // 過去の Claude Code セッション（VS Code やターミナルで作ったものも含む）を呼び出す
        let past = NSMenuItem(title: L("過去のセッションを開く"), action: nil, keyEquivalent: "")
        let pastMenu = NSMenu()
        pastMenu.autoenablesItems = false
        let rel = RelativeDateTimeFormatter()
        rel.locale = Locale(identifier: L("ja_JP"))
        rel.unitsStyle = .short
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let archived = Set(s.archivedSessions)
        let all = ClaudeSessions.recent(limit: 20 + archived.count)
        let sessions = Array(all.filter { !archived.contains($0.id) }.prefix(20))
        if sessions.isEmpty { pastMenu.addItem(.header(L("（まだありません）"))) }
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
            // ⌥ を押している間は「アーカイブ」に変わる（Claude Code の記録そのものは消さない）
            let alt = ClosureMenuItem("") { [weak self] in self?.manager.setArchived(info.id, true) }
            let altAttr = NSMutableAttributedString(string: L("🗄 アーカイブ: %@", title) + "\n", attributes: [.font: NSFont.menuFont(ofSize: 13)])
            altAttr.append(NSAttributedString(string: L("一覧から外す（記録は残る）"), attributes: [.font: NSFont.menuFont(ofSize: 10.5), .foregroundColor: NSColor.secondaryLabelColor]))
            alt.attributedTitle = altAttr
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = [.option]
            pastMenu.addItem(alt)
        }
        pastMenu.addItem(.separator())
        pastMenu.addItem(.header(L("⌥ を押しながら選ぶとアーカイブ")))
        let archivedInfos = all.filter { archived.contains($0.id) }
        if !s.archivedSessions.isEmpty {
            let arch = NSMenuItem(title: L("アーカイブ済み（%ld）", s.archivedSessions.count), action: nil, keyEquivalent: "")
            let am = NSMenu()
            am.autoenablesItems = false
            am.addItem(.header(L("選ぶと一覧に戻す（⌥ で開く）")))
            for info in archivedInfos {
                var t = info.title
                if t.count > 34 { t = String(t.prefix(34)) + "…" }
                am.addItem(ClosureMenuItem("↩︎ \(t)") { [weak self] in self?.manager.setArchived(info.id, false) })
                let open = ClosureMenuItem(L("開く: %@", t)) { [weak self] in self?.manager.resumeSession(info) }
                open.isAlternate = true
                open.keyEquivalentModifierMask = [.option]
                am.addItem(open)
            }
            if archivedInfos.count < s.archivedSessions.count {
                am.addItem(.header(L("ほか %ld 件（古いもの）", s.archivedSessions.count - archivedInfos.count)))
            }
            am.addItem(.separator())
            am.addItem(ClosureMenuItem(L("すべて一覧に戻す")) { [weak self] in self?.manager.updateSettings { $0.archivedSessions = [] } })
            arch.submenu = am
            pastMenu.addItem(arch)
        }
        past.submenu = pastMenu
        menu.addItem(past)

        if let note = shortcuts.conflictNote { menu.addItem(.header("⚠︎ \(note)")) }
        if let app = shortcuts.suspendedForApp { menu.addItem(.header(L("⌘L を一時解放中（%@）", app))) }

        menu.addItem(.separator())
        menu.addItem(.header(L("エージェント（%ld）", manager.controllers.count)))
        for c in manager.controllers {
            let r = c.record
            let title = "\(r.title)　\(r.color.name) · \(r.state.label)" + (r.hidden ? L("（非表示）") : "")
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.image = MenuImages.dot(r.color, state: r.state)
            let sub = NSMenu()
            sub.autoenablesItems = false
            manager.agentMenuItems(for: c, includeHeader: false).forEach { sub.addItem($0) }
            mi.submenu = sub
            menu.addItem(mi)
        }
        // 番号が飛んでいるときだけ（新しいクラゲは空いている一番小さい番号になるので、ふつうは詰まっている）
        if !manager.numbersAreCompact {
            menu.addItem(ClosureMenuItem(L("番号を 1 から振り直す")) { [weak self] in self?.manager.renumber() })
        }

        menu.addItem(.separator())
        let style = NSMenuItem(title: L("見た目"), action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for st in AvatarStyle.allCases {
            styleMenu.addItem(ClosureMenuItem(st.label, checked: s.avatarStyle == st) { [weak self] in
                self?.manager.setStyle(st)
            })
        }
        style.submenu = styleMenu
        menu.addItem(style)

        let scr = NSMenuItem(title: L("画面認識"), action: nil, keyEquivalent: "")
        let scrMenu = NSMenu()
        for m in ScreenMode.allCases {
            scrMenu.addItem(ClosureMenuItem(m.label, checked: s.screenMode == m) { [weak self] in self?.manager.updateSettings { $0.screenMode = m } })
        }
        scrMenu.addItem(.separator())
        scrMenu.addItem(ClosureMenuItem(L("使っていたアプリのある画面だけ撮る"), checked: s.screenTarget == .activeDisplay) { [weak self] in
            self?.manager.updateSettings { $0.screenTarget = .activeDisplay }
        })
        scrMenu.addItem(ClosureMenuItem(L("すべてのディスプレイを撮る"), checked: s.screenTarget == .allDisplays) { [weak self] in
            self?.manager.updateSettings { $0.screenTarget = .allDisplays }
        })
        scrMenu.addItem(.separator())
        scrMenu.addItem(.header(ScreenContext.hasPermission() ? L("画面収録の権限: 許可済み") : L("画面収録の権限: 未許可（初回の撮影時に確認が出ます）")))
        scr.submenu = scrMenu
        menu.addItem(scr)

        let size = NSMenuItem(title: L("大きさ"), action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (label, v) in [(L("小"), 0.8), (L("標準"), 1.0), (L("大"), 1.25), (L("特大"), 1.5)] {
            sizeMenu.addItem(ClosureMenuItem(label, checked: abs(s.jellyScale - v) < 0.01) { [weak self] in
                self?.manager.setScale(v)
            })
        }
        size.submenu = sizeMenu
        menu.addItem(size)

        let fps = NSMenuItem(title: L("なめらかさ（リアル）"), action: nil, keyEquivalent: "")
        let fpsMenu = NSMenu()
        for (label, mx, calm) in [(L("標準（待機中は 30fps）"), 60, 30), (L("常に 60fps"), 60, 60), (L("省電力（常に 30fps）"), 30, 30)] {
            fpsMenu.addItem(ClosureMenuItem(label, checked: s.maxFPS == mx && s.calmFPS == calm) { [weak self] in
                self?.manager.setFrameRates(max: mx, calm: calm)
            })
        }
        fps.submenu = fpsMenu
        menu.addItem(fps)

        // 実際に付与している権限を確認できるように
        let policy = NSMenuItem(title: L("実行ポリシー"), action: nil, keyEquivalent: "")
        let pm = NSMenu()
        pm.autoenablesItems = false
        pm.addItem(.header(L("すべてのクラゲ共通：%@", manager.policyDescription)))
        pm.addItem(.header("claude -p --permission-mode \(manager.effectivePermissionMode)"))
        if let refused = manager.refusedPermissionMode {
            pm.addItem(.header(L("⚠️ settings.json の permissionMode「%@」は使いません（安全判定が外れるか、この版にないため）", String(refused.prefix(40)))))
        }
        pm.addItem(.header(L("・確認なしでファイル作成/編集/削除・コマンド実行")))
        pm.addItem(.header(L("・認証情報の持ち出し、意図しない外部送信、取り返しのつかない操作は")))
        pm.addItem(.header(L("　Claude Code の安全判定で止まる（OS の権限設定は変更しない）")))
        pm.addItem(.header(L("・作業フォルダはクラゲごと（既定はホーム）")))
        pm.addItem(.separator())
        pm.addItem(.header("claude: \(manager.claudePathDescription)"))
        policy.submenu = pm
        menu.addItem(policy)

        // PC 操作
        let pcItem = NSMenuItem(title: L("PC 操作"), action: nil, keyEquivalent: "")
        let pcm = NSMenu()
        pcm.autoenablesItems = false
        if let d = DesktopControl.shared.driver, let c = manager.controllers.first(where: { $0.record.id == d }) {
            pcm.addItem(ClosureMenuItem(L("■ %@ の操作を今すぐ止める", c.record.title)) { [weak self] in
                DesktopControl.shared.release(d)
                if let rt = self?.manager.runtime(for: c) { rt.pcControl = false; rt.cancel() }
            })
            pcm.addItem(.separator())
        }
        pcm.addItem(.header(DesktopControl.permissionSummary))
        let allowed = manager.controllers.filter { manager.runtime(for: $0)?.pcControl == true }.map(\.record.title)
        pcm.addItem(.header(L("許可しているエージェント: %@", allowed.isEmpty ? L("なし") : allowed.joined(separator: L("、")))))
        pcm.addItem(.header(L("・チャットの「🖱 PC 操作」でエージェントごとにオン（既定オフ）")))
        pcm.addItem(.header(L("・同時に操作できるのは 1 体。操作中は画面の縁が光り、Esc で止まる")))
        pcm.addItem(.header(L("・チャットで直接頼んだときだけ使う（仲間からの依頼では使わない）")))
        pcm.addItem(.header(L("・クリックや入力は毎回 Claude Code の安全判定を通る")))
        pcm.addItem(.header(L("・macOS の許可はアプリ全体に付く（オフのエージェントのコマンドも、")))
        pcm.addItem(.header(L("　許可の範囲で画面の撮影やキー入力の合成ができる。止めるのは Claude Code の安全判定）")))
        pcm.addItem(ClosureMenuItem(L("許可の画面を開く…")) { DesktopControl.requestPermissions() })
        pcItem.submenu = pcm
        menu.addItem(pcItem)

        // エージェント同士の分業
        let teamItem = NSMenuItem(title: L("チーム（分業）"), action: nil, keyEquivalent: "")
        let tm = NSMenu()
        tm.autoenablesItems = false
        tm.addItem(ClosureMenuItem(L("エージェント同士の分業を使う"), checked: s.teamEnabled) { [weak self] in
            self?.manager.updateSettings { $0.teamEnabled.toggle() }
            self?.manager.team?.refresh()
        })
        tm.addItem(.separator())
        tm.addItem(.header(L("・クラゲを別のクラゲに近づけて離すと線でつながり、同じチームになる")))
        tm.addItem(.header(L("・⇧ を押しながらドラッグでチームごと移動、⌥ を押しながら離すと切り離し")))
        tm.addItem(.header(L("・チームの仲間に作業を頼む / 新しい仲間を作って分担する（Claude Code の MCP ツール）")))
        tm.addItem(.header(L("・線の上の光：依頼（依頼元の色）と結果（依頼先の色）の受け渡し")))
        tm.addItem(.header(L("・線にポインタを置くと ✂︎ で切れる（右クリック > つながり でも可）")))
        tm.addItem(.header(L("・1 チーム最大 %ld 体、エージェントが作れるのは 2 段まで", TeamCoordinator.maxTeamSize)))
        teamItem.submenu = tm
        menu.addItem(teamItem)
        menu.addItem(orgMenuItem(s))

        // ユーザーが Claude Code に設定している MCP サーバー（Figma・Blender など）を読み込むか
        let extItem = NSMenuItem(title: L("外部ツール（MCP）"), action: nil, keyEquivalent: "")
        let em = NSMenu()
        em.autoenablesItems = false
        for mode in ExternalMCPMode.allCases {
            em.addItem(ClosureMenuItem(mode.label, checked: s.externalMCP == mode) { [weak self] in
                self?.manager.updateSettings { $0.externalMCP = mode }
            })
        }
        em.addItem(.separator())
        let names = ExternalMCP.serverNames(cwd: FileManager.default.homeDirectoryForCurrentUser)
        em.addItem(.header(L("設定済み: %@（＋ claude.ai のコネクタ）", names.isEmpty ? L("なし") : names.joined(separator: ", "))))
        em.addItem(.header(L("・読み込まないと 1 回あたり約 4,800 トークン減り、起動も速くなる")))
        em.addItem(.header(L("・「呼んだときだけ」：指示に「Blender」「フィグマ」などの名前があると読み込み、同じ会話の続きでは読み込んだまま")))
        extItem.submenu = em
        menu.addItem(extItem)

        let login = ClosureMenuItem(L("ログイン時に自動起動"), checked: LoginItem.isEnabled) { [weak self] in
            let want = !LoginItem.isEnabled
            if let err = LoginItem.set(want) {
                let a = NSAlert()
                a.messageText = L("自動起動を設定できませんでした")
                a.informativeText = err
                a.runModal()
            }
            self?.manager.updateSettings { $0.launchAtLogin = LoginItem.isEnabled }
        }
        login.isEnabled = LoginItem.isAvailable
        menu.addItem(login)
        // どの言語で表示していても見つけられるよう、3 つの言語で書く
        let langItem = NSMenuItem(title: "🌐 言語 · Language · 语言", action: nil, keyEquivalent: "")
        let lm = NSMenu()
        lm.autoenablesItems = false
        for lang in AppLanguage.allCases {
            lm.addItem(ClosureMenuItem(lang.nativeName, checked: s.language == lang) { [weak self] in self?.manager.setLanguage(lang) })
        }
        langItem.submenu = lm
        menu.addItem(langItem)
        menu.addItem(ClosureMenuItem(L("設定フォルダを開く")) { [weak self] in
            guard let dir = self?.manager.store.dir else { return }
            NSWorkspace.shared.open(dir)
        })

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Jellyfish AI について")) { AppInfo.showAbout() })
        menu.addItem(ClosureMenuItem(L("アップデートを確認…")) { UpdateChecker.check() })
        menu.addItem(ClosureMenuItem(L("使い方（GitHub）")) { NSWorkspace.shared.open(AppInfo.repoURL) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Jellyfish AI を終了"), key: "q") { NSApp.terminate(nil) })
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
