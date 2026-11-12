import Foundation
import Testing
@testable import JellyfishAI

// 自律組織モードの「考える部分」（選び方・学習・進化）と、表示の言語のテスト

@Suite struct OrgGenomeTests {
    @Test func keysRoundTripAndClamp() {
        for g in OrgGenome.seeds { #expect(OrgGenome(key: g.key) == g, "\(g.key)") }
        #expect(OrgGenome(key: "parallel9")?.size == 5)
        #expect(OrgGenome(key: "pipeline3+r") == OrgGenome(.pipeline, 3, reviewer: true))
        #expect(OrgGenome(key: "solo") == OrgGenome(.solo))
        #expect(OrgGenome(key: "committee3") == nil)
    }

    @Test func mutationsAreValidNeighbours() {
        for g in OrgGenome.seeds {
            let ms = g.mutations()
            #expect(!ms.contains(g))
            #expect(Set(ms).count == ms.count)
            for m in ms { #expect(m == m.normalized(), "\(m.key)") }
        }
        #expect(OrgGenome(.parallel, 3).mutations().contains(OrgGenome(.parallel, 4)))
        #expect(OrgGenome(.parallel, 3).mutations().contains(OrgGenome(.parallel, 3, reviewer: true)))
    }

    @Test func infersFormationFromMembers() {
        typealias M = (name: String, role: String?, task: String, after: [String])
        let chain: [M] = [("調査係", "調査", "調べる", []), ("実装係", "実装", "作る", ["調査係"]), ("レビュー係", "レビュー", "見直す", ["実装係"])]
        #expect(TeamCoordinator.inferGenome(formation: nil, members: chain) == OrgGenome(.pipeline, 2, reviewer: true))
        let fan: [M] = [("A", nil, "東京を調べる", []), ("B", nil, "大阪を調べる", []), ("C", nil, "福岡を調べる", [])]
        #expect(TeamCoordinator.inferGenome(formation: nil, members: fan) == OrgGenome(.parallel, 3))
        #expect(TeamCoordinator.inferGenome(formation: "hierarchy3", members: fan) == OrgGenome(.hierarchy, 3))
        // 順番があるのに parallel と書いてあっても、実際の形（pipeline）を使う
        #expect(TeamCoordinator.inferGenome(formation: "parallel2", members: Array(chain.prefix(2))).shape == .pipeline)
        let same: [M] = [("案1", nil, "キャッチコピーを考える", []), ("案2", nil, "キャッチコピーを考える", []), ("Reviewer", "review", "pick", ["案1", "案2"])]
        #expect(TeamCoordinator.inferGenome(formation: nil, members: same) == OrgGenome(.ensemble, 2, reviewer: true))
        #expect(TeamCoordinator.inferGenome(formation: nil, members: [("レビュー係", nil, "見て", [])]) == OrgGenome(.solo, reviewer: true))
    }
}

@Suite struct TaskFeatureTests {
    @Test func tagsInThreeLanguages() {
        #expect(TaskFeatures.extract("競合3社の料金をそれぞれ調べて比較して").tags.isSuperset(of: ["research", "multi", "compare"]))
        #expect(TaskFeatures.extract("Research each of the three competitors and compare their pricing").tags.isSuperset(of: ["research", "multi", "compare"]))
        #expect(TaskFeatures.extract("分别调查三家竞争对手的价格并比较").tags.isSuperset(of: ["research", "multi", "compare"]))
        #expect(TaskFeatures.extract("ちょっと時刻を教えて").tags.contains("quick"))
        #expect(TaskFeatures.extract("hi").tags.contains("len:short"))
    }

    @Test func similarTasksAreCloserThanUnrelatedOnes() {
        let a = TaskFeatures.extract("このリポジトリのバグを修正してテストを追加して")
        let b = TaskFeatures.extract("別のリポジトリのバグを直してテストも書いて")
        let c = TaskFeatures.extract("京都の紅葉の名所を調べて旅行の計画を立てて")
        #expect(a.similarity(b) > a.similarity(c))
        #expect(a.similarity(a) > 0.99)
        let e1 = TaskFeatures.extract("Write unit tests for the parser and fix the failing bug")
        let e2 = TaskFeatures.extract("Fix the bug in the parser and write tests")
        let e3 = TaskFeatures.extract("Plan a weekend trip to Kyoto")
        #expect(e1.similarity(e2) > e1.similarity(e3))
    }
}

@Suite struct OrgPolicyTests {
    func greedy(_ text: String, _ eps: [OrgEpisode] = [], candidates: [OrgGenome] = OrgGenome.seeds) -> OrgRecommendation {
        var rng = SeededRNG(1)
        return OrgPolicy.recommend(TaskFeatures.extract(text), candidates: candidates, episodes: eps, sample: false, rng: &rng)
    }

    func episode(_ text: String, used: OrgGenome, reward good: Bool, agent: UUID = UUID()) -> OrgEpisode {
        OrgEpisode(id: UUID().uuidString, agent: agent, at: Date(), preview: text, features: TaskFeatures.extract(text),
                   recommended: used.key, used: used.key, exploration: false,
                   outcome: OrgOutcome(state: good ? "completed" : "error", seconds: 60, costUSD: nil, tasks: used.agentCount, tasksOK: good ? used.agentCount : 0),
                   reactions: [good ? .thumbsUp : .thumbsDown])
    }

    @Test func smallTasksGoSoloAndBroadOnesGetATeam() {
        #expect(greedy("今日の日付を教えて").genome.shape == .solo)
        #expect(greedy("hi, what time is it?").genome.shape == .solo)
        let broad = greedy("競合5社の料金・機能・サポートをそれぞれ調べて、比較表にまとめて")
        #expect(broad.genome.shape == .parallel)
        #expect(broad.novel)
    }

    @Test func learnsFromOutcomesAndTransfersToSimilarTasks() {
        let pipe = OrgGenome(.pipeline, 3, reviewer: true)
        // 「調べて記事を書く」系の依頼で、順番＋レビューがよく、分担はよくなかった
        var eps: [OrgEpisode] = []
        for t in ["新しい論文を調べてブログ記事を書いて", "最新の研究を調査して解説記事を書いて", "業界の動向を調べてレポートを書いて"] {
            eps.append(episode(t, used: pipe, reward: true))
            eps.append(episode(t, used: OrgGenome(.parallel, 3), reward: false))
        }
        // 一度も見ていない文でも、似た依頼なら学んだ形を選ぶ
        let rec = greedy("話題の技術を調べて紹介記事を書いて", eps)
        #expect(rec.genome == pipe)
        #expect(!rec.novel)
        #expect(rec.evidence > 0.5)
        // 似ていない依頼にはあまり効かない（依頼の種類からの見込みが残る）
        #expect(greedy("今日の日付を教えて", eps).genome.shape == .solo)
    }

    @Test func badExperienceMovesAwayFromAFormation() {
        let text = "このアプリのバグを直して"
        let before = greedy(text).genome
        let eps = (0..<4).map { _ in episode(text, used: before, reward: false) }
        #expect(greedy(text, eps).genome != before)
    }

    @Test func thompsonSamplingExploresButMostlyExploits() {
        let f = TaskFeatures.extract("競合5社の料金をそれぞれ調べて比較して")
        var rng = SeededRNG(42)
        var counts: [String: Int] = [:]
        for _ in 0..<300 {
            let r = OrgPolicy.recommend(f, candidates: OrgGenome.seeds, episodes: [], sample: true, rng: &rng)
            counts[r.genome.key, default: 0] += 1
        }
        #expect(counts.count >= 3)
        let best = OrgPolicy.recommend(f, candidates: OrgGenome.seeds, episodes: [], sample: false, rng: &rng).genome.key
        let top2 = counts.sorted { $0.value > $1.value }.prefix(2).map(\.key)
        #expect(top2.contains(best), "\(counts)")
    }

    @Test func betaSamplesHaveTheRightMean() {
        var rng = SeededRNG(7)
        let xs = (0..<4000).map { _ in Beta.sample(3, 7, &rng) }
        let mean = xs.reduce(0, +) / Double(xs.count)
        #expect(abs(mean - 0.3) < 0.02)
        #expect(xs.allSatisfy { $0 >= 0 && $0 <= 1 })
    }
}

@Suite struct OrgRewardTests {
    let done = OrgOutcome(state: "completed", seconds: 120, costUSD: 0.1, tasks: 3, tasksOK: 3)

    @Test func reactionsOrderScores() {
        let up = OrgReward.score(done, [.thumbsUp])!, praise = OrgReward.score(done, [.praise])!
        let moved = OrgReward.score(done, [.movedOn])!, plain = OrgReward.score(done, [])!
        let fix = OrgReward.score(done, [.correction])!, down = OrgReward.score(done, [.thumbsDown])!
        #expect(up > praise && praise > moved && moved > plain && plain > fix && fix > down)
        #expect(OrgReward.score(nil, [.thumbsUp]) == nil)
        let failed = OrgOutcome(state: "error", seconds: 30, costUSD: nil, tasks: 2, tasksOK: 0)
        #expect(OrgReward.score(failed, [])! < 0.2)
        #expect(OrgReward.score(OrgOutcome(state: "completed", seconds: 60, costUSD: nil, tasks: 4, tasksOK: 2), [])! < plain)
    }

    @Test func followUpsInThreeLanguages() {
        #expect(OrgReaction.fromFollowUp("違う、そうじゃなくて表にして") == .correction)
        #expect(OrgReaction.fromFollowUp("That's not what I asked, try again") == .correction)
        #expect(OrgReaction.fromFollowUp("不对，重做一下") == .correction)
        #expect(OrgReaction.fromFollowUp("ありがとう、完璧です") == .praise)
        #expect(OrgReaction.fromFollowUp("Perfect, thanks!") == .praise)
        #expect(OrgReaction.fromFollowUp("谢谢，很好") == .praise)
        #expect(OrgReaction.fromFollowUp("次は README を英語にして") == .movedOn)
    }
}

@Suite struct OrgEvolutionTests {
    @Test func elitesHaveChildrenAndLosersRetire() {
        let pop = OrgGenome.seeds.map { OrgGenomeState(genome: $0, generation: 0, parent: nil, born: Date()) }
        func ep(_ g: OrgGenome, _ r: Bool) -> OrgEpisode {
            OrgEpisode(id: UUID().uuidString, agent: UUID(), at: Date(), preview: "x", features: TaskFeatures.extract("x"),
                       recommended: g.key, used: g.key, exploration: false,
                       outcome: OrgOutcome(state: r ? "completed" : "error", seconds: 10, costUSD: nil, tasks: 0, tasksOK: 0),
                       reactions: [r ? .thumbsUp : .thumbsDown])
        }
        let good = OrgGenome(.parallel, 3), bad = OrgGenome(.hierarchy, 2)
        let eps = (0..<3).map { _ in ep(good, true) } + (0..<5).map { _ in ep(bad, false) } + (0..<5).map { _ in ep(OrgGenome(.solo), false) }
        let (next, events) = OrgEvolution.evolve(pop, episodes: eps)
        let children = next.filter { $0.parent == good.key }
        #expect(!children.isEmpty)
        #expect(children.allSatisfy { $0.generation == 1 })
        #expect(next.first { $0.genome == bad }?.retired == true)
        // 「一人で」は成績が悪くても引退させない（いつでも戻れる形）
        #expect(next.first { $0.genome == OrgGenome(.solo) }?.retired == false)
        #expect(!events.isEmpty)
        // リーダーが自分で選んだ、一覧にない形も取り込む
        let (adopted, _) = OrgEvolution.evolve(pop, episodes: [ep(OrgGenome(.ensemble, 3), true)])
        #expect(adopted.contains { $0.genome == OrgGenome(.ensemble, 3) })
    }
}

@Suite struct OrgLearnerTests {
    @Test func episodesPersistAndFollowUpsBecomeReactions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jf-org-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = UUID()
        let l = OrgLearner(dir: dir)
        let (e1, _) = l.begin(agent: agent, text: "競合をそれぞれ調べて比較して")
        l.setUsed(e1.id, OrgGenome(.parallel, 3))
        l.finish(e1.id, outcome: OrgOutcome(state: "completed", seconds: 100, costUSD: 0.2, tasks: 3, tasksOK: 3))
        #expect(l.awaitingFeedback(agent: agent)?.id == e1.id)
        // 続けて「違う」と言われた → 前の依頼は correction
        let (e2, _) = l.begin(agent: agent, text: "違う、料金だけでいい")
        #expect(l.episode(e1.id)?.reactions == [.correction])
        l.finish(e2.id, outcome: OrgOutcome(state: "completed", seconds: 20, costUSD: nil, tasks: 0, tasksOK: 0))
        l.react(e2.id, .thumbsUp)
        l.react(e2.id, .thumbsDown)   // 押し直したら最後のものだけ
        #expect(l.episode(e2.id)?.reactions == [.thumbsDown])
        #expect(l.awaitingFeedback(agent: agent) == nil)
        // 同じ文をもう一度 → retry
        let (e3, _) = l.begin(agent: agent, text: "違う、料金だけでいい")
        _ = e3
        #expect(l.episode(e2.id)?.reactions == [.thumbsDown])   // 👍👎 を押したものには付けない
        l.flush()
        let again = OrgLearner(dir: dir)
        #expect(again.episodes.count == 3)
        #expect(again.episode(e1.id)?.used == "parallel3")
        #expect(again.episode(e1.id)?.reward != nil)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("episodes.json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func learningOffDoesNotRecord() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jf-org-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let l = OrgLearner(dir: dir)
        l.learning = false
        let (e, rec) = l.begin(agent: UUID(), text: "調べて")
        l.finish(e.id, outcome: OrgOutcome(state: "completed", seconds: 1, costUSD: nil, tasks: 0, tasksOK: 0))
        #expect(l.episodes.isEmpty)
        #expect(OrgGenome.seeds.contains(rec.genome))
    }

    @Test func promptMentionsTheRecommendation() {
        var rng = SeededRNG(3)
        let rec = OrgPolicy.recommend(TaskFeatures.extract("競合5社をそれぞれ調べて比較して"), candidates: OrgGenome.seeds, episodes: [], sample: false, rng: &rng)
        let p = TeamCoordinator.orgPrompt(rec, canCreate: 5)
        #expect(p.contains(rec.genome.key))
        #expect(p.contains("form_team"))
        #expect(!p.contains("%@") && !p.contains("%ld"))
    }
}

@Suite struct LocalizationTests {
    @Test func resolvesSystemLanguage() {
        #expect(AppLanguage.system.resolved(preferred: ["ja-JP", "en-US"]) == .ja)
        #expect(AppLanguage.system.resolved(preferred: ["zh-Hans-CN"]) == .zh)
        #expect(AppLanguage.system.resolved(preferred: ["en-GB"]) == .en)
        #expect(AppLanguage.system.resolved(preferred: ["fr-FR", "de-DE"]) == .en)
        #expect(AppLanguage.en.resolved(preferred: ["ja-JP"]) == .en)
    }

    @Test func fallsBackToJapanese() {
        #expect(L10n.translate("これは表にない文", to: .en) == "これは表にない文")
        #expect(L10n.translate("自動（システムに合わせる）", to: .en) == "Automatic (follow the system)")
        #expect(L10n.translate("自動（システムに合わせる）", to: .ja) == "自動（システムに合わせる）")
    }

    /// 訳でも %@ / %ld の数と種類が同じ（違うと String(format:) で落ちる）
    @Test func placeholdersMatch() {
        let spec = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(?:ld|lld|d|@|f|\.\d+f)"#)
        func specs(_ s: String) -> [String] {
            let t = s.replacingOccurrences(of: "%%", with: "")
            return spec.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { Range($0.range, in: t).map { String(t[$0]) } }
                .map { $0.replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression) }.sorted()
        }
        for lang in [AppLanguage.en, .zh] {
            for (k, v) in L10n.table(lang) { #expect(specs(k) == specs(v), "\(lang.rawValue): \(k.prefix(40))") }
        }
    }
}
