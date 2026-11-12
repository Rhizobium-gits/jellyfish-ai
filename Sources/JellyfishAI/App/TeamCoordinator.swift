import AppKit

/// 仲間への依頼 1 件
final class TeamTask {
    enum Status: String { case queued, running, completed, error, cancelled }
    let id: String
    let from: UUID
    let to: UUID
    let text: String
    var status: Status = .queued
    var result: String?
    var delivered = false
    let createdAt = Date()
    var startedAt: Date?
    var endedAt: Date?

    init(id: String, from: UUID, to: UUID, text: String) {
        self.id = id; self.from = from; self.to = to; self.text = text
    }
    var isDone: Bool { status == .completed || status == .error || status == .cancelled }
}

/// エージェント同士の分業。
/// - つながり（線）の管理：隣に置くとつながる、✂︎ やメニューで切る、つながりの塊が 1 チーム
/// - Claude Code から見える MCP ツール（list_team / assign_task / create_teammate / wait_for_tasks）
/// - 依頼と結果の受け渡しを線の上の光で見せる（LinkOverlay）
final class TeamCoordinator {
    static let maxTeamSize = 8
    /// ユーザーが作ったクラゲ = 0。エージェントが作った仲間は 1、その仲間が作ると 2 まで
    static let maxDepth = 2
    static let maxAgents = 20
    static let requestMarker = "[Jellyfish チーム依頼 from: "
    static let requestFooter = "\n\n---\n（チーム依頼）"

    weak var manager: JellyManager?
    private let store: Store
    private(set) var links: Set<JellyLink>
    let bus: TeamBus
    let overlay = LinkOverlay()
    private var tasks: [String: TeamTask] = [:]
    private var queues: [UUID: [String]] = [:]
    private var running: [UUID: String] = [:]
    private var waiters: [Waiter] = []
    private var hovered: UUID?

    private struct Waiter {
        let id = UUID()
        let caller: UUID
        let taskIDs: [String]
        let reply: (String, Bool) -> Void
    }

    init(manager: JellyManager, store: Store) {
        self.manager = manager
        self.store = store
        self.links = Set(store.loadLinks())
        self.bus = TeamBus(dataDir: store.dir)
        overlay.onCut = { [weak self] l in self?.unlink(l.a, l.b) }
        // Esc で PC 操作が止められたら：そのエージェントの作業を止め、PC 操作もオフに戻す
        DesktopControl.shared.onUserStop = { [weak self] id in
            guard let self, let c = self.controller(id), let rt = self.manager?.runtime(for: c) else { return }
            rt.pcControl = false
            rt.cancel()
            self.manager?.onChange?()
        }
    }

    func start() {
        // 存在しないクラゲへのつながりは捨てる
        let ids = Set(manager?.controllers.map(\.record.id) ?? [])
        links = links.filter { ids.contains($0.a) && ids.contains($0.b) }
        do {
            try bus.start()
            bus.onMessage = { [weak self] conn, msg in self?.handle(conn, msg) }
        } catch {
            AppLog.write("team bus failed: \(error)")
        }
        refresh()
    }

    func shutdown() { bus.stop() }

    // MARK: - つながり

    func neighbors(_ id: UUID) -> [UUID] { links.filter { $0.contains(id) }.map { $0.other(id) } }

    /// つながりの塊（自分を含む）
    func team(of id: UUID) -> [UUID] {
        var seen: Set<UUID> = [id], order = [id], queue = [id]
        while let x = queue.first {
            queue.removeFirst()
            for n in neighbors(x) where seen.insert(n).inserted { order.append(n); queue.append(n) }
        }
        return order
    }

    /// 線をたどる最短の道（光を流す経路）
    func path(from a: UUID, to b: UUID) -> [UUID]? {
        var prev: [UUID: UUID] = [:]
        var seen: Set<UUID> = [a]
        var queue = [a]
        while let x = queue.first {
            queue.removeFirst()
            if x == b { break }
            for n in neighbors(x) where seen.insert(n).inserted { prev[n] = x; queue.append(n) }
        }
        guard seen.contains(b) else { return nil }
        var p = [b]
        while let q = prev[p[0]] { p.insert(q, at: 0) }
        return p
    }

    func isLinked(_ a: UUID, _ b: UUID) -> Bool { links.contains(JellyLink(a, b)) }

    @discardableResult
    func link(_ a: UUID, _ b: UUID, animated: Bool = true) -> Bool {
        guard a != b, !isLinked(a, b) else { return false }
        // チームの大きさの上限
        guard canLink(a, b) else {
            AppLog.write("link refused: team would exceed \(TeamCoordinator.maxTeamSize)")
            return false
        }
        links.insert(JellyLink(a, b))
        save()
        refresh()
        if animated, let p1 = anchor(a), let p2 = anchor(b) { overlay.linkCreated(JellyLink(a, b), from: p1, to: p2) }
        AppLog.write("link \(name(a)) — \(name(b))")
        return true
    }

    func unlink(_ a: UUID, _ b: UUID) {
        guard links.remove(JellyLink(a, b)) != nil else { return }
        if let p1 = anchor(a), let p2 = anchor(b) { overlay.linkCut(from: p1, to: p2) }
        save()
        refresh()
        AppLog.write("unlink \(name(a)) — \(name(b))")
    }

    func unlinkAll(_ a: UUID) { for n in neighbors(a) { unlink(a, n) } }

    /// デモ録画用：線の真ん中に ✂︎ を出してから切る
    func cutWithScissors(_ a: UUID, _ b: UUID) {
        guard isLinked(a, b), let p1 = anchor(a), let p2 = anchor(b) else { return }
        overlay.showScissors(JellyLink(a, b), at: CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            self?.overlay.hideScissors()
            self?.unlink(a, b)
        }
    }

    /// クラゲが消えたとき：つながりを外し、その子への依頼は失敗として返す
    func removeAgent(_ id: UUID) {
        let had = !neighbors(id).isEmpty
        links = links.filter { !$0.contains(id) }
        for t in tasks.values where t.to == id && !t.isDone {
            resolve(t.id, .error, result: "\(name(id)) が削除されました")
        }
        queues[id] = nil
        running[id] = nil
        if had { save() }
        refresh()
    }

    private func save() {
        store.save(links: Array(links))
        manager?.teamChanged()
    }

    // MARK: - ドラッグ（近づけてつなぐ・⇧ でチームごと移動・⌥ で切り離す）

    /// 中心どうしが体の幅の何倍まで近づいたらつながるか
    static let linkReach: CGFloat = 1.5
    /// つないだあと、線が見えるように落ち着かせる距離（体の幅の倍数）
    static let settleDistance: CGFloat = 1.6

    /// ドラッグ 1 回ぶんの状態
    private struct DragSession {
        let id: UUID
        let start: NSPoint
        /// 同じチームの仲間の、ドラッグ開始時の位置（⇧ で一緒に動かす）
        let mates: [UUID: NSPoint]
        var group = false
        var cutting = false
        var candidate: UUID?
    }
    private var drag: DragSession?
    /// 置いたあと滑らせている間も「つながる先」の表示を残す
    private var pendingLink: (UUID, UUID)?
    private var glideTimer: Timer?
    private var glideFinish: (() -> Void)?

    func canLink(_ a: UUID, _ b: UUID) -> Bool {
        a != b && !isLinked(a, b) && Set(team(of: a)).union(team(of: b)).count <= TeamCoordinator.maxTeamSize
    }

    func teammateNames(for id: UUID) -> [String] { team(of: id).dropFirst().map(name) }

    func jellyDragBegan(_ c: JellyController, origin: NSPoint) {
        finishGlide()
        let id = c.record.id
        var mates: [UUID: NSPoint] = [:]
        for m in team(of: id) where m != id {
            if let mc = controller(m), mc.isVisible { mates[m] = mc.panel.frame.origin }
        }
        drag = DragSession(id: id, start: origin, mates: mates)
    }

    /// ドラッグ中（動くたび・修飾キーが変わるたび）
    func jellyDragged(_ c: JellyController, mods: NSEvent.ModifierFlags) {
        let id = c.record.id
        if drag?.id != id { jellyDragBegan(c, origin: c.panel.frame.origin) }
        guard var s = drag else { return }
        let o = c.panel.frame.origin
        let dx = o.x - s.start.x, dy = o.y - s.start.y
        // ⇧：線でつながった仲間も一緒に動く（離すと元の位置へ戻る）
        let group = mods.contains(.shift) && !s.mates.isEmpty
        if group || s.group {
            for (m, p) in s.mates {
                guard let mc = controller(m) else { continue }
                mc.panel.setFrameOrigin(group ? NSPoint(x: p.x + dx, y: p.y + dy) : p)
                (mc.avatar as? RealisticAvatar)?.windowMoved()
            }
        }
        s.group = group
        // ⌥：離すとこのクラゲのつながりを全部切る
        s.cutting = mods.contains(.option) && !neighbors(id).isEmpty
        let cand = s.cutting ? nil : adjacentCandidate(for: c, excluding: group ? Set(s.mates.keys) : [])
        if let cand, cand.record.id != s.candidate { cand.avatar.poke() }
        s.candidate = cand?.record.id
        drag = s
        refresh()
    }

    /// 置いたとき
    func jellyDropped(_ c: JellyController, mods: NSEvent.ModifierFlags) {
        jellyDragged(c, mods: mods)
        guard let s = drag, s.id == c.record.id else { refresh(); return }
        drag = nil
        let id = c.record.id
        var movers = [c]
        if s.group {
            for m in s.mates.keys {
                guard let mc = controller(m) else { continue }
                mc.moveTo(mc.panel.frame.origin, persist: true)
                movers.append(mc)
            }
        }
        if s.cutting {
            unlinkAll(id)
            refresh()
            return
        }
        guard let tid = s.candidate, let t = controller(tid), canLink(id, tid) else {
            if let tid = s.candidate { AppLog.write("link refused: \(name(id)) — \(name(tid))") }
            refresh()
            return
        }
        // 近すぎると線が体に隠れて ✂︎ も出せないので、線が見える距離まで滑らせてからつなぐ
        pendingLink = (id, tid)
        if let d = settleOffset(for: c, from: t, movers: movers) {
            glide(movers, by: d) { [weak self] in self?.completeLink(id, tid) }
        } else {
            completeLink(id, tid)
        }
    }

    private func completeLink(_ a: UUID, _ b: UUID) {
        pendingLink = nil
        // 滑らせている間に片方が消えていたら何もしない
        if controller(a) != nil, controller(b) != nil, link(a, b) {
            controller(a)?.avatar.poke()
            controller(b)?.avatar.poke()
        } else {
            refresh()
        }
    }

    private func adjacentCandidate(for c: JellyController, excluding: Set<UUID>) -> JellyController? {
        guard let m = manager, m.settings.teamEnabled else { return nil }
        let p = c.anchorPoint
        let reach = c.panel.frame.width * TeamCoordinator.linkReach
        return m.controllers
            .filter { $0 !== c && $0.isVisible && !isLinked($0.record.id, c.record.id) && !excluding.contains($0.record.id) }
            .map { ($0, hypot($0.anchorPoint.x - p.x, $0.anchorPoint.y - p.y)) }
            .filter { $0.1 <= reach }
            .min { $0.1 < $1.1 }?.0
    }

    /// 相手から settleDistance 離れた、画面内で他のクラゲと重ならない位置までのずれ（すでに十分離れていれば nil）
    private func settleOffset(for c: JellyController, from t: JellyController, movers: [JellyController]) -> CGVector? {
        let w = c.panel.frame.width
        let want = w * TeamCoordinator.settleDistance
        let pa = c.anchorPoint, pt = t.anchorPoint
        let dist = hypot(pa.x - pt.x, pa.y - pt.y)
        guard dist < want - 2 else { return nil }
        let base = dist < 1 ? CGFloat.pi : atan2(pa.y - pt.y, pa.x - pt.x)
        let moving = Set(movers.map { ObjectIdentifier($0) })
        let others = (manager?.controllers ?? [])
            .filter { $0.isVisible && $0 !== t && !moving.contains(ObjectIdentifier($0)) }
            .map(\.anchorPoint)
        let vf = (t.panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 来た向きを優先し、ふさがっていれば 30° ずつ回して探す
        for k in [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6] {
            let ang = base + CGFloat(k) * .pi / 6
            let d = CGVector(dx: pt.x + cos(ang) * want - pa.x, dy: pt.y + sin(ang) * want - pa.y)
            let f = c.panel.frame.offsetBy(dx: d.dx, dy: d.dy)
            guard vf.contains(f.insetBy(dx: f.width * 0.2, dy: f.height * 0.2)) else { continue }
            let np = CGPoint(x: pa.x + d.dx, y: pa.y + d.dy)
            if others.contains(where: { hypot($0.x - np.x, $0.y - np.y) < w * 0.9 }) { continue }
            return d
        }
        return nil
    }

    /// 少しだけ滑らせて置き直す（0.22 秒・ease-out）
    private func glide(_ movers: [JellyController], by d: CGVector, done: @escaping () -> Void) {
        finishGlide()
        let starts = movers.map { ($0, $0.panel.frame.origin) }
        let t0 = CACurrentMediaTime(), dur = 0.22
        glideFinish = {
            for (m, o) in starts { m.moveTo(NSPoint(x: o.x + d.dx, y: o.y + d.dy), persist: true) }
            done()
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            let k = min(1, (CACurrentMediaTime() - t0) / dur)
            let e = CGFloat(1 - pow(1 - k, 3))
            for (m, o) in starts {
                m.panel.setFrameOrigin(NSPoint(x: o.x + d.dx * e, y: o.y + d.dy * e))
                (m.avatar as? RealisticAvatar)?.windowMoved()
            }
            self?.refresh()
            if k >= 1 { self?.finishGlide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        glideTimer = timer
    }

    private func finishGlide() {
        glideTimer?.invalidate()
        glideTimer = nil
        let f = glideFinish
        glideFinish = nil
        f?()
    }

    // MARK: - 描画

    private func controller(_ id: UUID) -> JellyController? { manager?.controllers.first { $0.record.id == id } }
    private func anchor(_ id: UUID) -> CGPoint? {
        guard let c = controller(id), c.isVisible else { return nil }
        return c.anchorPoint
    }
    func name(_ id: UUID) -> String { controller(id)?.record.title ?? "（削除済み）" }

    /// 線・名前ラベル・点線プレビューを今の位置で描き直す（静止中は CPU を使わない）
    func refresh() {
        guard let m = manager else { return }
        var segs: [(JellyLink, CGPoint, CGPoint)] = []
        if !m.settings.allHidden {
            for l in links {
                if let p1 = anchor(l.a), let p2 = anchor(l.b) { segs.append((l, p1, p2)) }
            }
        }
        var labels: [LinkOverlay.Label] = []
        if !m.settings.allHidden {
            for c in m.controllers where c.isVisible {
                let id = c.record.id
                guard hovered == id || !neighbors(id).isEmpty || running[id] != nil else { continue }
                labels.append(.init(id: id, text: c.record.title, at: c.labelPoint, color: c.record.color.nsColor))
            }
        }
        var preview: LinkOverlay.Preview?
        var pills: [LinkOverlay.Pill] = []
        var warn: Set<JellyLink> = []
        let pair = drag.flatMap { s in s.candidate.map { (s.id, $0) } } ?? pendingLink
        if let (a, b) = pair, let ca = controller(a), let cb = controller(b), ca.isVisible, cb.isVisible {
            let ok = pendingLink != nil || canLink(a, b)
            let color = ca.record.color.nsColor
            preview = .init(from: ca.anchorPoint, to: cb.anchorPoint, color: color, ok: ok, radius: cb.panel.frame.width * 0.62)
            if drag != nil {
                // 吹き出しは 2 体の頭より上（線の重ね窓はクラゲより下に描くので、体に隠れない位置に置く）
                let top = max(ca.panel.frame.maxY, cb.panel.frame.maxY) + 16
                let text = ok ? "🔗 離すと \(cb.record.title) とつながる" : "チームは \(TeamCoordinator.maxTeamSize) 体まで"
                pills.append(.init(id: "candidate", text: text, at: CGPoint(x: (ca.anchorPoint.x + cb.anchorPoint.x) / 2, y: top),
                                   color: ok ? color : LinkOverlay.warnColor))
            }
        }
        if let s = drag, let c = controller(s.id), c.isVisible {
            // 名前ラベル（足元）のさらに下
            let at = CGPoint(x: c.anchorPoint.x, y: c.labelPoint.y - 19)
            let color = c.record.color.nsColor
            if s.cutting {
                warn = Set(links.filter { $0.contains(s.id) })
                pills.append(.init(id: "hint", text: "✂ 離すと つながりを切る", at: at, color: LinkOverlay.warnColor))
            } else if s.group {
                pills.append(.init(id: "hint", text: "👥 チームごと移動中", at: at, color: color))
            } else if !neighbors(s.id).isEmpty {
                pills.append(.init(id: "hint", text: "⇧ チームごと移動 · ⌥ 切り離す", at: at, color: color))
            } else if s.candidate == nil, links.isEmpty, m.settings.teamEnabled,
                      m.controllers.contains(where: { $0 !== c && $0.isVisible }) {
                // まだ一度もつないでいない人向けの案内
                pills.append(.init(id: "hint", text: "ほかのクラゲの近くで離すと つながる", at: at, color: color))
            }
        }
        overlay.update(segments: segs, labels: labels, preview: preview, pills: pills, warn: warn)
    }

    /// ポインタ追跡（30Hz）から：クラゲの上なら名前を出し、線の近くなら ✂︎ を出す
    func pointerMoved(_ p: CGPoint, over c: JellyController?) {
        let id = c?.record.id
        if id != hovered { hovered = id; refresh() }
        if c != nil { overlay.hideScissors(); return }
        overlay.pointerMoved(p)
    }

    // MARK: - エージェントの実行に渡す設定

    struct RunConfig {
        let mcpConfig: URL
        let systemPrompt: String
        let allowedTools: [String]
        let env: [String: String]
    }

    func runConfig(for c: JellyController, runtime rt: AgentRuntime) -> RunConfig? {
        guard let m = manager, m.settings.teamEnabled || rt.pcControl, let exe = Bundle.main.executableURL else { return nil }
        let id = c.record.id
        let cfg: [String: Any] = ["mcpServers": ["jellyfish": [
            "type": "stdio", "command": exe.path, "args": ["--mcp-bridge", bus.path, id.uuidString],
        ]]]
        let url = rt.dir.appendingPathComponent("mcp.json")
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]),
              (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        var prompt = m.settings.teamEnabled ? systemPrompt(for: c, runtime: rt) : ""
        if rt.pcControl { prompt += "\n\n" + DesktopControl.systemPrompt }
        // 事前に許可するのはチームのツールだけ。PC 操作のツールは毎回 Claude Code の安全判定を通す
        let allowed = m.settings.teamEnabled
            ? TeamCoordinator.toolDefinitions.compactMap { $0["name"] as? String }.map { "mcp__jellyfish__\($0)" } : []
        return RunConfig(mcpConfig: url, systemPrompt: prompt,
                         allowedTools: allowed,
                         // wait_for_tasks は仲間の作業が終わるまで待つので、MCP の既定のタイムアウトより長くする
                         env: ["MCP_TOOL_TIMEOUT": "2400000"])
    }

    private func systemPrompt(for c: JellyController, runtime rt: AgentRuntime) -> String {
        let id = c.record.id
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let mates = team(of: id).dropFirst().compactMap { controller($0) }
        var roster = mates.map { m -> String in
            let st = manager?.runtime(for: m).map { $0.isRunning ? "作業中" : "空き" } ?? "?"
            let direct = isLinked(id, m.record.id) ? "隣" : "チーム内"
            return "- \(m.record.title)（\(m.record.color.name)、\(st)、\(direct)）"
        }.joined(separator: "\n")
        if roster.isEmpty { roster = "- まだ仲間はいません（create_teammate で作れます）" }
        let pcNote = rt.pcControl ? "" : "\nPC 操作（画面を見てクリック・入力する）は、ユーザーがこのエージェントのチャットで「🖱 PC 操作」をオンにすると使えます。頼まれたらそう伝えてください。"
        let depth = c.record.depth ?? 0
        let room = max(0, min(TeamCoordinator.maxTeamSize - team(of: id).count,
                              TeamCoordinator.maxAgents - (manager?.controllers.count ?? 0)))
        let canCreate = depth < TeamCoordinator.maxDepth && room > 0
        return """
        # Jellyfish チーム
        あなたは Jellyfish AI のデスクトップにいるエージェント「\(c.record.title)」（\(c.record.color.name)）です。jellyfish MCP サーバーのツールで、線でつながった仲間（同じチーム）と分業できます。
        - list_team: 仲間と状態を見る
        - assign_task: 仲間に作業を頼む（すぐ戻り、task_id が返る。相手が作業中なら順番待ち）
        - create_teammate: 新しい仲間を自分の隣に出して作業を任せる
        - wait_for_tasks: 頼んだ作業の結果を待って受け取る
        独立した部分に分けられる大きな作業や、ユーザーが分担・並列・チーム・仲間・添削・レビューを求めたときは、作業を分けて assign_task / create_teammate で同時に任せ、wait_for_tasks で結果を集めて統合してください。小さな作業は自分でやってください。仲間は自分の会話を見られないので、依頼文に必要な前提（目的・対象ファイル・出力形式）を書いてください。同じファイルを同時に編集しないよう担当を分けてください。
        作業フォルダ: \(rt.cwd.path.replacingOccurrences(of: home, with: "~"))
        今のチーム:
        \(roster)
        \(canCreate ? "新しく作れる仲間: あと \(room) 体" : "このエージェントはこれ以上仲間を作れません（上限）。今いる仲間には頼めます。")\(pcNote)
        """
    }

    // MARK: - ターンの終了

    func turnEnded(agent: UUID, turn: AgentTurn) {
        DesktopControl.shared.release(agent)
        if let tid = running[agent] {
            running[agent] = nil
            let st: TeamTask.Status = turn.state == .completed ? .completed : (turn.state == .cancelled ? .cancelled : .error)
            resolve(tid, st, result: turn.result ?? turn.error)
        }
        // 次の依頼（ユーザーの指示の後に来ていたものも）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.startNext(agent) }
    }

    private func startNext(_ agent: UUID) {
        guard running[agent] == nil, var q = queues[agent], !q.isEmpty,
              let c = controller(agent), let rt = manager?.runtime(for: c), !rt.isRunning else { return }
        let tid = q.removeFirst()
        queues[agent] = q
        guard let t = tasks[tid], !t.isDone else { startNext(agent); return }
        let prompt = TeamCoordinator.requestMarker + name(t.from) + "]\n" + t.text + TeamCoordinator.requestFooter
            + "同じチームの「\(name(t.from))」からの依頼です。終わったら、依頼元がそのまま使えるように結果を最終回答としてまとめてください（作ったファイルのパスや要点を含める）。"
        running[agent] = tid
        t.status = .running
        t.startedAt = Date()
        if !rt.submit(prompt) {
            running[agent] = nil
            resolve(tid, .error, result: rt.lastError ?? "開始できませんでした")
            return
        }
        setFlow(t, active: true)
        refresh()
    }

    private func resolve(_ tid: String, _ status: TeamTask.Status, result: String?) {
        guard let t = tasks[tid], !t.isDone else { return }
        t.status = status
        t.result = result
        t.endedAt = Date()
        setFlow(t, active: false)
        // 結果を依頼元へ（依頼先の色の光が戻っていく）
        if let ids = path(from: t.to, to: t.from) {
            let pts = ids.compactMap { anchor($0) }
            if pts.count == ids.count, let c = controller(t.to) { overlay.sendPackets(along: pts, color: c.record.color.nsColor) }
        }
        AppLog.write("team task \(tid) \(name(t.from)) ← \(name(t.to)) \(status.rawValue)")
        checkWaiters()
        refresh()
    }

    private func setFlow(_ t: TeamTask, active: Bool) {
        guard let ids = path(from: t.from, to: t.to), ids.count > 1 else { return }
        for i in 0..<(ids.count - 1) {
            let l = JellyLink(ids[i], ids[i + 1])
            if active {
                overlay.setFlow(l, toward: ids[i + 1], color: controller(t.from)?.record.color.nsColor ?? .white)
            } else {
                // 同じ線を別の依頼がまだ使っていれば流し続ける
                let still = tasks.values.contains { o in
                    o !== t && o.status == .running && (path(from: o.from, to: o.to).map { p in
                        zip(p, p.dropFirst()).contains { JellyLink($0, $1) == l }
                    } ?? false)
                }
                if !still { overlay.setFlow(l, toward: nil, color: .white) }
            }
        }
    }

    // MARK: - MCP（JSON-RPC 2.0 over stdio、ブリッジ経由）

    private func handle(_ conn: BusConnection, _ msg: [String: Any]) {
        if msg["jellyfish"] as? String == "hello" {
            // 名乗ったエージェントの claude（このアプリが起動したプロセス）の子からの接続だけを受け付ける。
            // 同じユーザーの別のプロセスがエージェントになりすまして PC 操作ツールを使えないように
            let id = (msg["agent"] as? String).flatMap(UUID.init(uuidString:))
            if let id, let c = controller(id), let pid = manager?.runtime(for: c)?.processID,
               ProcessTree.isDescendant(conn.peerPID, of: pid) {
                conn.agentID = id
            } else {
                AppLog.write("team bus: refused hello agent=\(id.map { String($0.uuidString.prefix(8)) } ?? "-") peer=\(conn.peerPID)")
            }
            return
        }
        guard let method = msg["method"] as? String else { return }
        let id = msg["id"]
        func reply(_ result: [String: Any]) {
            guard let id else { return }
            conn.send(["jsonrpc": "2.0", "id": id, "result": result])
        }
        switch method {
        case "initialize":
            let pv = (msg["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18"
            reply(["protocolVersion": pv, "capabilities": ["tools": [:]],
                   "serverInfo": ["name": "jellyfish", "version": AppInfo.version],
                   "instructions": "Jellyfish AI のチーム機能。線でつながった仲間のエージェントに作業を頼み、結果を受け取る。"])
        case "ping":
            reply([:])
        case "tools/list":
            var tools = manager?.settings.teamEnabled == true ? TeamCoordinator.toolDefinitions : []
            if let id = conn.agentID, let c = controller(id), manager?.runtime(for: c)?.pcControl == true {
                tools += DesktopControl.toolDefinitions
            }
            reply(["tools": tools])
        case "tools/call":
            let p = msg["params"] as? [String: Any] ?? [:]
            let tool = p["name"] as? String ?? ""
            let args = p["arguments"] as? [String: Any] ?? [:]
            guard let caller = conn.agentID, controller(caller) != nil else {
                reply(["content": [["type": "text", "text": "このエージェントは Jellyfish のクラゲとして見つかりません"]], "isError": true])
                return
            }
            call(tool, args, from: caller) { text, isError in
                if conn.isClosed { return }
                reply(["content": [["type": "text", "text": text]], "isError": isError])
            }
        default:
            if id != nil {
                conn.send(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
    }

    static let toolDefinitions: [[String: Any]] = [
        ["name": "list_team",
         "description": "線でつながったチームの仲間（名前・色・状態）と、新しく作れる仲間の数を返す。",
         "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
        ["name": "assign_task",
         "description": "チームの仲間に作業を頼む。すぐに task_id を返し、仲間は並行して作業する（作業中なら順番待ち）。結果は wait_for_tasks で受け取る。仲間はあなたの会話を見られないので、目的・前提・対象ファイル・出力形式を依頼文に書くこと。",
         "inputSchema": ["type": "object", "required": ["to", "task"], "properties": [
            "to": ["type": "string", "description": "仲間の名前（list_team の name）"],
            "task": ["type": "string", "description": "依頼する作業の内容"],
         ]]],
        ["name": "create_teammate",
         "description": "新しい仲間のエージェントを自分の隣に作り（線でつながる）、task があればすぐ任せる。作業フォルダ・モデルは自分と同じ。task_id が返るので wait_for_tasks で結果を受け取る。",
         "inputSchema": ["type": "object", "required": ["name"], "properties": [
            "name": ["type": "string", "description": "仲間の名前（役割がわかる短い名前。例: 調査係、レビュー係）"],
            "task": ["type": "string", "description": "最初に任せる作業（省略可）"],
         ]]],
        ["name": "read_transcript",
         "description": "ユーザーが「🎧 聞き取り」で拾ったシステムの音（会議・動画など）の文字起こしを読む。聞き取り中なら途中まで。since_line を渡すとその行より後だけ返す（リアルタイムの翻訳・要約に使う）。from に仲間の名前を渡すとその仲間の文字起こしを読む。",
         "inputSchema": ["type": "object", "properties": [
            "since_line": ["type": "number"], "from": ["type": "string"],
         ]]],
        ["name": "wait_for_tasks",
         "description": "頼んだ作業が終わるまで待ち、結果を返す。task_ids を省略すると、まだ受け取っていない自分の依頼すべてを待つ。timeout_seconds を過ぎたら、その時点の状況を返す（もう一度呼べば続きを待てる）。",
         "inputSchema": ["type": "object", "properties": [
            "task_ids": ["type": "array", "items": ["type": "string"]],
            "timeout_seconds": ["type": "number", "description": "待つ最大秒数（既定 600、最大 1800）"],
         ]]],
    ]

    private func call(_ tool: String, _ args: [String: Any], from caller: UUID, reply: @escaping (String, Bool) -> Void) {
        func ok(_ obj: Any) { reply(TeamCoordinator.json(obj), false) }
        func fail(_ s: String) { reply(s, true) }
        guard let me = controller(caller), let m = manager else { fail("呼び出し元が見つかりません"); return }
        if DesktopControl.toolDefinitions.contains(where: { $0["name"] as? String == tool }) {
            guard let rt = m.runtime(for: me), rt.pcControl else {
                fail("このエージェントには PC 操作が許可されていません（チャットの「🖱 PC 操作」でオンにできます）")
                return
            }
            DesktopControl.shared.call(tool, args, agent: caller, name: me.record.title, color: me.record.color.nsColor,
                                       dir: rt.dir, reply: reply)
            return
        }
        switch tool {
        case "list_team":
            let mates = team(of: caller).dropFirst().compactMap { controller($0) }
            ok([
                "you": ["name": me.record.title, "color": me.record.color.name],
                "teammates": mates.map { c -> [String: Any] in
                    let rt = m.runtime(for: c)
                    return ["name": c.record.title, "color": c.record.color.name,
                            "state": c.record.state.rawValue, "busy": rt?.isRunning ?? false,
                            "linked_directly": isLinked(caller, c.record.id),
                            "queued_tasks": queues[c.record.id]?.count ?? 0]
                },
                "can_create": canCreateCount(from: me),
            ])
        case "assign_task":
            guard let toName = args["to"] as? String, let text = (args["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                fail("to と task が必要です"); return
            }
            guard let target = resolve(name: toName, in: caller) else {
                let names = team(of: caller).dropFirst().map(name).joined(separator: ", ")
                fail("「\(toName)」はチームにいません。仲間: \(names.isEmpty ? "なし（create_teammate で作れます）" : names)")
                return
            }
            let t = enqueue(from: caller, to: target.record.id, text: text)
            ok(["task_id": t.id, "to": target.record.title, "status": t.status.rawValue])
        case "create_teammate":
            let n = canCreateCount(from: me)
            guard n > 0 else {
                fail((me.record.depth ?? 0) >= TeamCoordinator.maxDepth
                     ? "このエージェントは仲間を作れません（作成の深さの上限 \(TeamCoordinator.maxDepth)）。今いる仲間に assign_task で頼んでください。"
                     : "チームの上限（\(TeamCoordinator.maxTeamSize) 体）に達しています")
                return
            }
            let raw = (args["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let nm = m.uniqueName(String((raw.isEmpty ? "仲間" : raw).prefix(24)))
            guard let c = m.spawnTeammate(near: me, name: nm) else { fail("仲間を作れませんでした"); return }
            link(caller, c.record.id)
            var out: [String: Any] = ["name": c.record.title, "color": c.record.color.name]
            if let text = (args["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                // 出現アニメーションが落ち着いてから光を送る
                let t = enqueue(from: caller, to: c.record.id, text: text, delay: 0.5)
                out["task_id"] = t.id
                out["status"] = t.status.rawValue
            }
            ok(out)
        case "read_transcript":
            var target = caller
            if let n = args["from"] as? String, !n.isEmpty {
                guard let c = resolve(name: n, in: caller) else { fail("「\(n)」はチームにいません"); return }
                target = c.record.id
            }
            let since = (args["since_line"] as? NSNumber)?.intValue ?? 0
            guard let t = m.transcriptText(for: target, sinceLine: since) else {
                fail("文字起こしがありません。ユーザーにチャットの「🎧」で聞き取りを始めてもらってください。")
                return
            }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            ok(["file": t.path.replacingOccurrences(of: home, with: "~"), "listening": t.live,
                "from_line": since, "next_line": since + t.lines.count, "lines": t.lines])
        case "wait_for_tasks":
            var ids = (args["task_ids"] as? [String]) ?? []
            if ids.isEmpty {
                ids = tasks.values.filter { $0.from == caller && !$0.delivered }.sorted { $0.createdAt < $1.createdAt }.map(\.id)
            }
            ids = ids.filter { tasks[$0] != nil }
            guard !ids.isEmpty else { ok(["tasks": [], "note": "待つ依頼がありません"]); return }
            let timeout = min(max((args["timeout_seconds"] as? Double) ?? 600, 5), 1800)
            let w = Waiter(caller: caller, taskIDs: ids, reply: reply)
            if ids.allSatisfy({ tasks[$0]?.isDone == true }) {
                deliver(w, timedOut: false)
                return
            }
            waiters.append(w)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let i = self.waiters.firstIndex(where: { $0.id == w.id }) else { return }
                self.waiters.remove(at: i)
                self.deliver(w, timedOut: true)
            }
        default:
            fail("未知のツール: \(tool)")
        }
    }

    private func canCreateCount(from c: JellyController) -> Int {
        guard (c.record.depth ?? 0) < TeamCoordinator.maxDepth else { return 0 }
        return max(0, min(TeamCoordinator.maxTeamSize - team(of: c.record.id).count,
                          TeamCoordinator.maxAgents - (manager?.controllers.count ?? 0)))
    }

    /// 名前（大文字小文字・前後の空白は無視）、色の名前、「Agent N」で仲間を探す
    private func resolve(name raw: String, in caller: UUID) -> JellyController? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mates = team(of: caller).dropFirst().compactMap { controller($0) }
        if let c = mates.first(where: { $0.record.title.lowercased() == key }) { return c }
        let alias = ["青": "blue", "あお": "blue", "橙": "orange", "だいだい": "orange", "紫": "purple", "むらさき": "purple",
                     "緑": "green", "みどり": "green", "桃": "pink", "もも": "pink", "黄": "yellow", "黄色": "yellow", "きいろ": "yellow",
                     "水色": "cyan", "黄緑": "lime", "藍": "indigo"]
        let colorKey = alias[key.replacingOccurrences(of: "の", with: "").replacingOccurrences(of: "色", with: "")] ?? alias[key] ?? key
        let byColor = mates.filter { $0.record.color.name.lowercased() == key || $0.record.color.key == colorKey }
        if byColor.count == 1 { return byColor[0] }
        return mates.first { "agent \($0.record.number)" == key }
    }

    @discardableResult
    private func enqueue(from: UUID, to: UUID, text: String, delay: Double = 0) -> TeamTask {
        let tid = "t" + String(UUID().uuidString.prefix(6)).lowercased()
        let t = TeamTask(id: tid, from: from, to: to, text: text)
        tasks[tid] = t
        queues[to, default: []].append(tid)
        AppLog.write("team task \(tid) \(name(from)) → \(name(to))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // 依頼元の色の光が線をたどって相手へ
            if let ids = self.path(from: from, to: to) {
                let pts = ids.compactMap { self.anchor($0) }
                if pts.count == ids.count, let c = self.controller(from) {
                    self.overlay.sendPackets(along: pts, color: c.record.color.nsColor)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.startNext(to) }
        }
        return t
    }

    private func checkWaiters() {
        let ready = waiters.filter { w in w.taskIDs.allSatisfy { tasks[$0]?.isDone == true } }
        waiters.removeAll { w in ready.contains { $0.id == w.id } }
        ready.forEach { deliver($0, timedOut: false) }
    }

    private func deliver(_ w: Waiter, timedOut: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var out: [[String: Any]] = []
        var pending: [String] = []
        for id in w.taskIDs {
            guard let t = tasks[id] else { continue }
            var e: [String: Any] = ["task_id": t.id, "from_teammate": name(t.to), "status": t.status.rawValue]
            if t.isDone {
                t.delivered = true
                var r = (t.result ?? "").replacingOccurrences(of: home, with: "~")
                if r.count > 30000 { r = String(r.prefix(30000)) + "\n…（長いので省略。続きは相手のセッションを参照）" }
                e["result"] = r
                if let s = t.startedAt, let en = t.endedAt { e["seconds"] = Int(en.timeIntervalSince(s)) }
            } else {
                pending.append(t.id)
            }
            out.append(e)
        }
        var obj: [String: Any] = ["tasks": out]
        if timedOut { obj["timed_out"] = true; obj["pending"] = pending; obj["note"] = "まだ終わっていない依頼があります。もう一度 wait_for_tasks を呼ぶと続きを待てます。" }
        w.reply(TeamCoordinator.json(obj), false)
    }

    static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "{}" }
        return String(decoding: d, as: UTF8.self)
    }

    /// チャット・メニュー表示用：そのクラゲの進行中・順番待ちの依頼
    func pendingDescription(for id: UUID) -> String? {
        if let t = running[id].flatMap({ tasks[$0] }) { return "📨 \(name(t.from)) からの依頼を作業中" }
        if let n = queues[id]?.count, n > 0 { return "📨 依頼 \(n) 件が順番待ち" }
        return nil
    }
}
