import Foundation

/// 自律組織モードの学習（バックグラウンド）。
/// - 依頼ごとのエピソード（特徴・選んだ型・成果・反応）をデータフォルダの org/ に保存する（端末内だけ。どこにも送らない）
/// - 成果や反応が増えると、少し待ってから裏のキューで型を進化させ、学習のレポート（org/report.md）を書き直す
/// - 状態はメインスレッドで持ち、重い処理（進化・保存・レポート）はコピーを渡して裏で行う
final class OrgLearner {
    static let maxEpisodes = 600

    let dir: URL
    private(set) var episodes: [OrgEpisode] = []
    private(set) var population: [OrgGenomeState] = []
    private(set) var lastEvents: [String] = []
    /// 学習するか（設定の orgLearning）。オフでも選び方には今までの学習を使う
    var learning = true
    /// 進化・保存が終わったとき（メインスレッド）
    var onChange: (() -> Void)?

    private let queue = DispatchQueue(label: "jellyfish.org", qos: .utility)
    private var pending: DispatchWorkItem?
    /// 進化の待ち。あとから保存だけの予約が来ても、進化は取り消さない
    private var evolvePending = false
    private var rng = SystemRandomNumberGenerator()

    init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        load()
        if population.isEmpty { population = OrgGenome.seeds.map { OrgGenomeState(genome: $0, generation: 0, parent: nil, born: Date()) } }
    }

    var generation: Int { population.map(\.generation).max() ?? 0 }
    var activeGenomes: [OrgGenome] { population.filter { !$0.retired }.map(\.genome) }
    var learnedCount: Int { episodes.filter { $0.reward != nil }.count }

    // MARK: - 依頼の始まりと終わり

    /// ユーザーの依頼を受けたとき：前の依頼への反応を読み、おすすめの型を選んでエピソードを始める
    func begin(agent: UUID, text: String, now: Date = Date()) -> (OrgEpisode, OrgRecommendation) {
        // 同じクラゲへの直前の依頼（3 時間以内）への反応
        if let i = episodes.lastIndex(where: { $0.agent == agent }), now.timeIntervalSince(episodes[i].at) < 3 * 3600,
           episodes[i].outcome != nil, !episodes[i].reactions.contains(.thumbsUp), !episodes[i].reactions.contains(.thumbsDown) {
            let same = episodes[i].preview == OrgLearner.preview(text)
            add(same ? .retry : OrgReaction.fromFollowUp(text), at: i)
        }
        let f = TaskFeatures.extract(text)
        let rec = OrgPolicy.recommend(f, candidates: activeGenomes, episodes: episodes, sample: learning, rng: &rng)
        let ep = OrgEpisode(id: "e" + String(UUID().uuidString.prefix(8)).lowercased(), agent: agent, at: now,
                            preview: OrgLearner.preview(text), features: f, recommended: rec.genome.key,
                            used: nil, exploration: rec.exploration, outcome: nil)
        if learning {
            episodes.append(ep)
            if episodes.count > OrgLearner.maxEpisodes { episodes.removeFirst(episodes.count - OrgLearner.maxEpisodes) }
            scheduleSave(evolve: false)
        }
        return (ep, rec)
    }

    /// 実際に組んだ型
    func setUsed(_ id: String, _ g: OrgGenome) {
        guard let i = episodes.firstIndex(where: { $0.id == id }) else { return }
        episodes[i].used = g.key
        scheduleSave(evolve: false)
    }

    func used(_ id: String) -> String? { episodes.first { $0.id == id }?.used }

    func finish(_ id: String, outcome: OrgOutcome) {
        guard let i = episodes.firstIndex(where: { $0.id == id }) else { return }
        episodes[i].outcome = outcome
        if outcome.state == "cancelled" { episodes[i].reactions.append(.cancel) }
        scheduleSave(evolve: true)
    }

    /// 👍 / 👎（同じエピソードには最後のものだけ残す）
    func react(_ id: String, _ r: OrgReaction) {
        guard let i = episodes.firstIndex(where: { $0.id == id }) else { return }
        episodes[i].reactions.removeAll { $0 == .thumbsUp || $0 == .thumbsDown }
        add(r, at: i)
    }

    private func add(_ r: OrgReaction, at i: Int) {
        guard learning else { return }
        episodes[i].reactions.append(r)
        scheduleSave(evolve: true)
    }

    func episode(_ id: String) -> OrgEpisode? { episodes.first { $0.id == id } }

    /// チャットに 👍👎 を出すエピソード：そのクラゲの最後の依頼で、終わっていて、まだ 👍👎 がないもの
    func awaitingFeedback(agent: UUID) -> OrgEpisode? {
        guard let e = episodes.last(where: { $0.agent == agent }), e.outcome != nil,
              !e.reactions.contains(.thumbsUp), !e.reactions.contains(.thumbsDown) else { return nil }
        return e
    }

    func reset() {
        episodes = []
        population = OrgGenome.seeds.map { OrgGenomeState(genome: $0, generation: 0, parent: nil, born: Date()) }
        lastEvents = []
        scheduleSave(evolve: false, delay: 0)
    }

    // MARK: - 表示用

    struct Summary {
        var learned: Int
        var generation: Int
        var active: Int
        var retired: Int
        /// 依頼の種類ごとに、いちばん成績のよい型
        var bestByTag: [(tag: String, genome: OrgGenome, mean: Double, n: Int)]
    }

    func summary() -> Summary {
        var byTag: [String: [String: (n: Int, sum: Double)]] = [:]
        for e in episodes {
            guard let r = e.reward else { continue }
            for t in e.features.tags where !t.hasPrefix("len:") {
                var m = byTag[t] ?? [:]
                let v = m[e.usedKey] ?? (0, 0)
                m[e.usedKey] = (v.n + 1, v.sum + r)
                byTag[t] = m
            }
        }
        var best: [(String, OrgGenome, Double, Int)] = []
        for (t, m) in byTag {
            if let top = m.max(by: { $0.value.sum / Double($0.value.n) < $1.value.sum / Double($1.value.n) }),
               let g = OrgGenome(key: top.key) {
                best.append((t, g, top.value.sum / Double(top.value.n), top.value.n))
            }
        }
        best.sort { $0.3 > $1.3 }
        return Summary(learned: learnedCount, generation: generation,
                       active: population.filter { !$0.retired }.count, retired: population.filter(\.retired).count,
                       bestByTag: best.map { (tag: $0.0, genome: $0.1, mean: $0.2, n: $0.3) })
    }

    static func tagLabel(_ t: String) -> String {
        switch t {
        case "research": return L("調査")
        case "code": return L("コード")
        case "review": return L("レビュー")
        case "writing": return L("文章")
        case "compare": return L("比較")
        case "multi": return L("複数の対象")
        case "translate": return L("翻訳")
        case "data": return L("データ")
        case "design": return L("設計")
        case "test": return L("テスト")
        case "plan": return L("計画")
        case "creative": return L("アイデア")
        case "quick": return L("ちょっとした用事")
        case "pc": return L("PC 操作")
        default: return t
        }
    }

    // MARK: - 保存・進化（裏で）

    private var episodesURL: URL { dir.appendingPathComponent("episodes.json") }
    private var populationURL: URL { dir.appendingPathComponent("population.json") }
    var reportURL: URL { dir.appendingPathComponent("report.md") }

    private func load() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: episodesURL), let e = try? dec.decode([OrgEpisode].self, from: d) { episodes = e }
        if let d = try? Data(contentsOf: populationURL), let p = try? dec.decode([OrgGenomeState].self, from: d) { population = p }
    }

    /// 少し待ってからまとめて（成果と反応が続けて届いても 1 回で済む）
    private func scheduleSave(evolve: Bool, delay: Double = 3) {
        pending?.cancel()
        if evolve { evolvePending = true }
        let eps = episodes, pop = population
        let doEvolve = evolvePending && learning
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            var newPop = pop
            var events: [String] = []
            if doEvolve { (newPop, events) = OrgEvolution.evolve(pop, episodes: eps) }
            self.write(eps, newPop)
            let report = OrgLearner.report(eps, newPop, events: events)
            try? report.write(to: self.reportURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                if doEvolve {
                    self.evolvePending = false
                    self.population = newPop
                    if !events.isEmpty { self.lastEvents = events; AppLog.write("org: gen \(self.generation) " + events.joined(separator: ", ")) }
                }
                self.onChange?()
            }
        }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func write(_ eps: [OrgEpisode], _ pop: [OrgGenomeState]) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if let d = try? enc.encode(eps) { try? d.write(to: episodesURL, options: .atomic); try? FileManager.default.setAttributes(attrs, ofItemAtPath: episodesURL.path) }
        if let d = try? enc.encode(pop) { try? d.write(to: populationURL, options: .atomic) }
    }

    /// 終わるときに、待っている保存をすぐ済ませる
    func flush() {
        pending?.cancel()
        let e = episodes, p = population
        // 裏で書いている途中なら、それが終わってから最新のものを書く
        queue.sync { write(e, p) }
    }

    static func preview(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 60 ? String(one.prefix(60)) + "…" : one
    }

    /// 学習のレポート（人が読む用）
    static func report(_ eps: [OrgEpisode], _ pop: [OrgGenomeState], events: [String]) -> String {
        let st = OrgEvolution.stats(eps)
        var s = "# " + L("Jellyfish 自律組織：学習のレポート") + "\n\n"
        s += L("学んだ依頼: %ld 件 · 世代: %ld · 使っている型: %ld（引退 %ld）", eps.filter { $0.reward != nil }.count,
               pop.map(\.generation).max() ?? 0, pop.filter { !$0.retired }.count, pop.filter(\.retired).count) + "\n\n"
        s += L("記録はこの Mac の中だけにあり、どこにも送りません。メニューの「学習をリセット」で消せます。") + "\n\n"
        s += "## " + L("組織の型ごとの成績") + "\n\n| " + L("型") + " | " + L("件数") + " | " + L("平均点") + " | " + L("世代") + " | " + L("状態") + " |\n|---|---|---|---|---|\n"
        for p in pop.sorted(by: { (st[$0.genome.key]?.mean ?? -1) > (st[$1.genome.key]?.mean ?? -1) }) {
            let v = st[p.genome.key]
            s += "| \(p.genome.label) (`\(p.genome.key)`) | \(v?.n ?? 0) | \(v.map { String(format: "%.2f", $0.mean) } ?? "-") | \(p.generation) | \(p.retired ? L("引退") : L("使用中")) |\n"
        }
        if !events.isEmpty { s += "\n## " + L("今回の進化") + "\n\n" + events.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        s += "\n## " + L("最近の依頼") + "\n\n| " + L("日時") + " | " + L("依頼") + " | " + L("おすすめ") + " | " + L("実際") + " | " + L("点") + " | " + L("反応") + " |\n|---|---|---|---|---|---|\n"
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        for e in eps.suffix(30).reversed() {
            let text = e.preview.replacingOccurrences(of: "|", with: "/")
            s += "| \(f.string(from: e.at)) | \(text) | \(e.recommended)\(e.exploration ? " 🧪" : "") | \(e.usedKey) | \(e.reward.map { String(format: "%.2f", $0) } ?? "-") | \(e.reactions.map(\.rawValue).joined(separator: ", ")) |\n"
        }
        s += "\n🧪 = " + L("見込みがいちばんの型ではなく、試しに選んだもの（探索）") + "\n"
        return s
    }
}
