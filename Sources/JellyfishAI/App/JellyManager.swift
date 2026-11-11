import AppKit

/// すべてのクラゲの生成・配置・表示・永続化を管理する。
/// Phase 2 ではここに AgentRuntime（エージェントごとのプロセス管理）がぶら下がる。
final class JellyManager {
    let store: Store
    private(set) var settings: AppSettings
    private(set) var controllers: [JellyController] = []
    /// メニューバー表示の更新など
    var onChange: (() -> Void)?

    private var pointerTimer: Timer?
    /// クラゲごとのエージェント（セッション・プロセス・履歴）
    private var runtimes: [UUID: AgentRuntime] = [:]
    /// クラゲを消しても実行中なら最後まで動かすためのもの
    private var detached: [AgentRuntime] = []
    /// クラゲごとのチャットウィンドウ
    private var chats: [UUID: AgentChatController] = [:]

    private var lastPointer = NSPoint(x: -1, y: -1)
    private var pointerIdleTicks = 0
    private var saveScheduled = false

    var layout: AvatarLayout { AvatarFactory.layout(settings.avatarStyle, scale: settings.jellyScale) }
    var windowSize: CGSize { layout.size }

    init(store: Store) {
        self.store = store
        self.settings = store.loadSettings()
    }

    // MARK: 起動

    func start() {
        var records = store.loadJellies()
        if records.isEmpty { records = [makeRecord()] }
        for r in records { _ = addController(r) }
        ensureOnScreen()
        if !settings.allHidden {
            for c in controllers where !c.record.hidden { c.show(animated: true) }
        }
        startPointerTracking()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.ensureOnScreen()
        }
        save()
    }

    private func makeRecord() -> JellyRecord {
        let used = Set(controllers.map { $0.record.colorIndex })
        var ci = 0
        while used.contains(ci) { ci += 1 }
        let n = settings.nextAgentNumber
        settings.nextAgentNumber += 1
        store.save(settings)
        return JellyRecord(id: UUID(), number: n, colorIndex: ci, origin: nil,
                           hidden: false, state: .idle, createdAt: Date())
    }

    private func addController(_ r: JellyRecord) -> JellyController {
        let avatar = AvatarFactory.make(settings.avatarStyle, record: r, scale: settings.jellyScale,
                                        maxFPS: settings.maxFPS, calmFPS: settings.calmFPS)
        let c = JellyController(record: r, avatar: avatar, manager: self)
        controllers.append(c)
        attachRuntime(to: c)
        if r.origin == nil {
            c.moveTo(freeSlotOrigin(excluding: c), persist: true)
        } else {
            c.panel.setFrameOrigin(r.origin!)
        }
        return c
    }

    // MARK: 生成・削除

    /// 新しいクラゲ（エージェント）を生成する。既存のクラゲには一切触れない。
    @discardableResult
    func spawn(openChat open: Bool = true) -> JellyController {
        if settings.allHidden { setAllHidden(false) }
        let c = addController(makeRecord())
        c.show(animated: true)
        save()
        onChange?()
        // 生成したらすぐ指示を打ち込めるように
        if open { DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak c] in
            guard let self, let c, self.controllers.contains(where: { $0 === c }) else { return }
            self.openChat(for: c, quickCapture: true)
        } }
        return c
    }

    // MARK: エージェント

    func backend() -> AgentBackend? {
        guard let install = ClaudeLocator.best(override: settings.claudePath) else { return nil }
        return ClaudeCodeBackend(install: install, permissionMode: settings.permissionMode,
                                 model: settings.model.isEmpty ? nil : settings.model)
    }

    var policyDescription: String { backend()?.policyDescription ?? "claude が見つかりません" }

    var claudePathDescription: String {
        guard let i = ClaudeLocator.best(override: settings.claudePath) else { return "未検出" }
        return "\(i.versionString)  \(i.url.path)"
    }

    /// 起動直後に claude の検出（バージョン・オプション確認）を済ませておく
    func prefetchBackend() {
        let override = settings.claudePath
        DispatchQueue.global(qos: .utility).async { _ = ClaudeLocator.best(override: override) }
    }

    func runtime(for c: JellyController) -> AgentRuntime? { runtimes[c.record.id] }

    private func attachRuntime(to c: JellyController) {
        let rt = runtimes[c.record.id] ?? AgentRuntime(agentID: c.record.id, baseDir: store.dir,
                                                       backendProvider: { [weak self] in self?.backend() })
        runtimes[c.record.id] = rt
        rt.onState = { [weak self, weak c] s in
            c?.setState(s)
            self?.onChange?()
        }
        rt.onUpdate = { [weak self, weak c] in
            guard let self, let c else { return }
            self.chats[c.record.id]?.refresh()
        }
        // 前回の終了時に動いていた場合など、記録と状態がずれていたら記録側に合わせる
        if !rt.isRunning, let last = rt.lastTurn, c.record.state != last.state,
           !(c.record.state == .idle && last.state == .completed) {
            c.setState(last.state)
        } else if !rt.isRunning && (c.record.state == .thinking || c.record.state == .working) {
            c.setState(.idle)
        }
    }

    /// チャットウィンドウを開く。quickCapture（⌘L で作った直後）は、最初の指示を送ったら閉じて元の作業に戻す
    func openChat(for c: JellyController, quickCapture: Bool = false) {
        guard let rt = runtimes[c.record.id] else { return }
        let chat: AgentChatController
        if let existing = chats[c.record.id] {
            chat = existing
            // ⌘L の小さな入力欄のまま開き直したときは、会話が読める普段の大きさに広げる
            if !existing.isVisible, !rt.turns.isEmpty || rt.sessionStarted,
               existing.window.frame.height < settings.chatHeight - 1 {
                existing.resizeKeepingTop(NSSize(width: settings.chatWidth, height: settings.chatHeight))
            }
        } else {
            let fresh = rt.turns.isEmpty && !rt.sessionStarted
            let size = fresh ? NSSize(width: settings.chatWidth, height: max(300, settings.chatHeight * 0.6))
                             : NSSize(width: settings.chatWidth, height: settings.chatHeight)
            chat = AgentChatController(jelly: c, runtime: rt, size: size)
            chat.manager = self
            chats[c.record.id] = chat
        }
        chat.closeAfterFirstSubmit = quickCapture
        chat.show(near: c)
    }

    /// デモ録画・自動テスト用：チャットの入力欄に 1 文字ずつ打ち込んで送信する（jellyfish://type）
    func typePrompt(_ text: String, into c: JellyController, cps: Double) {
        if chats[c.record.id]?.isVisible != true { openChat(for: c) }
        chats[c.record.id]?.typeAndSubmit(text, cps: cps)
    }

    var claudeExecutable: URL? { ClaudeLocator.best(override: settings.claudePath)?.url }
    var supportsEffort: Bool { ClaudeLocator.best(override: settings.claudePath)?.supportsEffort ?? false }

    func rememberChatSize(_ size: NSSize) {
        guard size.width >= 380, size.height >= 240 else { return }
        settings.chatWidth = Double(size.width)
        settings.chatHeight = Double(size.height)
        scheduleSave()
    }

    /// チャットウィンドウが 1 つでも出て（またはしまわれて）いる間は普通のアプリとして Dock・⌘Tab に出す
    func chatWindowVisibilityChanged() {
        let any = chats.values.contains { $0.isVisible }
        let want: NSApplication.ActivationPolicy = any ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    /// 過去の Claude Code セッション（プロジェクト）をクラゲで呼び出す
    func resumeSession(_ info: ClaudeSessionInfo) {
        if let c = controllers.first(where: { runtimes[$0.record.id]?.sessionID == info.id }) {
            if c.record.hidden || settings.allHidden { setHidden(c, false); if settings.allHidden { setAllHidden(false) } }
            openChat(for: c)
            return
        }
        if settings.allHidden { setAllHidden(false) }
        let c = addController(makeRecord())
        runtimes[c.record.id]?.bind(to: info)
        c.setState(.completed)
        c.show(animated: true)
        save()
        onChange?()
        openChat(for: c)
    }

    /// そのセッションを使っているクラゲの番号（メニュー表示用）
    func agentNumber(forSession id: String) -> Int? {
        controllers.first { runtimes[$0.record.id]?.sessionID == id }?.record.number
    }

    /// 長押しで消す。実行中なら、勝手にキャンセルせず確認する。
    func requestRemove(_ c: JellyController) {
        guard let rt = runtimes[c.record.id], rt.isRunning else {
            remove(c)
            return
        }
        let a = NSAlert()
        a.messageText = "\(c.record.title) はまだ作業中です"
        a.informativeText = "クラゲを消しても、作業はバックグラウンドで最後まで続けられます。結果は履歴（ログ）に残ります。"
        a.addButton(withTitle: "作業は続けて、クラゲだけ消す")
        a.addButton(withTitle: "作業をキャンセルして消す")
        a.addButton(withTitle: "やめる")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            rt.onState = nil
            rt.onUpdate = nil
            detached.append(rt)
            rt.onState = { [weak self, weak rt] s in
                if s.isTerminal || s == .error { self?.detached.removeAll { $0 === rt } }
            }
            remove(c)
        case .alertSecondButtonReturn:
            rt.cancel()
            remove(c)
        default:
            c.avatar.pressCancelled()
        }
    }

    /// クラゲを削除する。
    /// Phase 2: 実行中タスクがある場合はキャンセルするか継続するかを確認し、勝手にキャンセルしない。
    func remove(_ c: JellyController) {
        if let chat = chats.removeValue(forKey: c.record.id) {
            chat.window.orderOut(nil)
            chat.window.close()
            chatWindowVisibilityChanged()
        }
        if let rt = runtimes.removeValue(forKey: c.record.id), !rt.isRunning {
            rt.onState = nil
            rt.onUpdate = nil
        }
        controllers.removeAll { $0 === c }
        c.despawn {}
        save()
        onChange?()
    }

    func controller(number: Int) -> JellyController? { controllers.first { $0.record.number == number } }

    // MARK: 表示・非表示（非表示でもバックグラウンド処理は止めない）

    func setAllHidden(_ hidden: Bool) {
        settings.allHidden = hidden
        store.save(settings)
        for c in controllers where !c.record.hidden {
            hidden ? c.hide() : c.show(animated: true)
        }
        onChange?()
    }

    func toggleAllHidden() { setAllHidden(!settings.allHidden) }

    func setHidden(_ c: JellyController, _ hidden: Bool) {
        c.update { $0.hidden = hidden }
        if hidden { c.hide() } else if !settings.allHidden { c.show(animated: true) }
        onChange?()
    }

    func resetPosition(_ c: JellyController) {
        c.moveTo(freeSlotOrigin(excluding: c), persist: true)
    }

    func arrangeAll() {
        var placed: [JellyController] = []
        for c in controllers {
            let o = freeSlotOrigin(excluding: c, among: placed)
            c.moveTo(o, persist: true)
            placed.append(c)
        }
    }

    // MARK: 設定

    func setScale(_ s: Double) {
        guard abs(s - settings.jellyScale) > 0.001 else { return }
        settings.jellyScale = s
        store.save(settings)
        rebuildControllers()
    }

    func setFrameRates(max: Int, calm: Int) {
        settings.maxFPS = max
        settings.calmFPS = calm
        store.save(settings)
        controllers.forEach { $0.avatar.setFrameRates(max: max, calm: calm) }
        onChange?()
    }

    func setStyle(_ style: AvatarStyle) {
        guard style != settings.avatarStyle else { return }
        settings.avatarStyle = style
        store.save(settings)
        rebuildControllers()
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        store.save(settings)
        onChange?()
    }

    /// サイズ変更時：クラゲの上端中央を基準に作り直す
    private func rebuildControllers() {
        let old = controllers
        controllers = []
        for c in old {
            var r = c.record
            let f = c.panel.frame
            let size = windowSize
            r.origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height)
            c.close()
            let n = addController(r)
            chats[r.id]?.attach(jelly: n)
            if !settings.allHidden && !r.hidden { n.show(animated: true) }
        }
        save()
        onChange?()
    }

    // MARK: 配置

    /// 画面右端から縦に並べ、互い違いにずらした「群れ」の配置スロット
    private func slotOrigins(on screen: NSScreen) -> [NSPoint] {
        let vf = screen.visibleFrame
        let L = layout
        let size = L.size
        let stepY = L.stepY
        let stepX = L.stepX
        let rows = max(1, Int((vf.height * 0.90 - size.height) / stepY) + 1)
        var out: [NSPoint] = []
        for col in 0..<8 {
            for row in 0..<rows {
                let stagger: CGFloat = row % 2 == 1 ? L.stagger : 0
                let x = vf.maxX - size.width + L.edgeOverhang - CGFloat(col) * stepX + stagger
                // 最上段はアプリのツールバーと重なりやすいので、少し下から並べる
                let y = vf.maxY - size.height - vf.height * 0.10 - CGFloat(row) * stepY
                out.append(NSPoint(x: x, y: y))
            }
        }
        return out
    }

    private func freeSlotOrigin(excluding me: JellyController?, among: [JellyController]? = nil) -> NSPoint {
        guard let screen = NSScreen.screens.first else { return .zero }
        let others = (among ?? controllers).filter { $0 !== me && !$0.record.hidden }.map { $0.panel.frame.origin }
        let minDist = windowSize.width * 0.45
        let slots = slotOrigins(on: screen)
        for s in slots where !others.contains(where: { hypot($0.x - s.x, $0.y - s.y) < minDist }) {
            return s
        }
        return slots[0]
    }

    /// ディスプレイ構成が変わってクラゲが画面外に出たら、空きスロットへ戻す
    func ensureOnScreen() {
        for c in controllers {
            let f = c.panel.frame
            let core = f.insetBy(dx: f.width * 0.3, dy: f.height * 0.3)
            if !NSScreen.screens.contains(where: { $0.frame.intersects(core) }) {
                c.moveTo(freeSlotOrigin(excluding: c), persist: true)
            }
        }
    }

    // MARK: ポインタ追跡（透明部分はクリックを素通しさせる）

    private func startPointerTracking() {
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.pollPointer() }
        RunLoop.main.add(t, forMode: .common)
        pointerTimer = t
    }

    private func pollPointer() {
        let p = NSEvent.mouseLocation
        if p == lastPointer {
            // ポインタが止まっていても、クラゲ側が漂って位置が変わるので時々は再判定する
            pointerIdleTicks += 1
            if pointerIdleTicks < 10 { return }
        }
        pointerIdleTicks = 0
        lastPointer = p
        var claimed = false
        for c in controllers.reversed() {
            if c.updatePointer(p, allowed: !claimed) { claimed = true }
        }
    }

    // MARK: イベント

    func jellyClicked(_ c: JellyController) {
        openChat(for: c)
        onChange?()
    }

    /// アプリ終了時：実行中のエージェントを中断して記録を残す
    func shutdown() {
        for rt in runtimes.values where rt.isRunning { rt.cancel() }
        for rt in detached where rt.isRunning { rt.cancel() }
        save()
    }

    func recordChanged() {
        scheduleSave()
        onChange?()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        store.save(controllers.map { $0.record })
        store.save(settings)
    }

    // MARK: メニュー

    func agentMenuItems(for c: JellyController, includeHeader: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let r = c.record
        if includeHeader {
            let h = NSMenuItem.header("\(r.title) · \(r.color.name) · \(r.state.label)")
            h.image = MenuImages.dot(r.color, state: r.state)
            items.append(h)
            items.append(.separator())
        }
        items.append(ClosureMenuItem("チャットを開く…") { [weak self, weak c] in if let c { self?.openChat(for: c) } })
        if let rt = runtimes[c.record.id], rt.isRunning {
            items.append(ClosureMenuItem("作業をキャンセル") { [weak rt] in rt?.cancel() })
        }
        let preview = NSMenuItem(title: "状態プレビュー", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in AgentState.allCases {
            sub.addItem(ClosureMenuItem("\(s.label)（\(s.englishLabel)）", checked: r.state == s) { [weak c] in
                c?.setState(s)
            })
        }
        preview.submenu = sub
        items.append(preview)
        if r.hidden {
            items.append(ClosureMenuItem("表示する") { [weak self, weak c] in if let c { self?.setHidden(c, false) } })
        } else {
            items.append(ClosureMenuItem("このクラゲを隠す") { [weak self, weak c] in if let c { self?.setHidden(c, true) } })
        }
        items.append(ClosureMenuItem("定位置に戻す") { [weak self, weak c] in if let c { self?.resetPosition(c) } })
        items.append(.separator())
        items.append(ClosureMenuItem("このクラゲを削除") { [weak self, weak c] in if let c { self?.remove(c) } })
        return items
    }

    func contextMenu(for c: JellyController) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        agentMenuItems(for: c, includeHeader: true).forEach { m.addItem($0) }
        return m
    }
}
