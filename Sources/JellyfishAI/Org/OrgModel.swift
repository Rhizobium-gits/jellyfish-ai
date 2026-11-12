import Foundation

// 自律組織モードの「考える部分」（画面・ファイル・claude を使わない。テストあり）
//
//   依頼の文 ─▶ TaskFeatures（語・種類・長さ）
//                 │ 過去の依頼との似ている度合い
//   過去の結果 ─▶ OrgPolicy：組織の型（OrgGenome）ごとに成功の見込みを Beta 分布で持ち、
//                 Thompson サンプリングで 1 つ選ぶ（よく効く型を使いつつ、ときどき別の型も試す）
//                 似た依頼がない（未知の）依頼は、依頼の種類からの見込みと全体の傾向で決める
//   成果と反応 ─▶ OrgReward：完了・失敗・仲間の成否・👍👎・やり直し・「違う」「ありがとう」などから 0〜1 の点数
//   ときどき   ─▶ OrgEvolution：成績のよい型を少し変えた型（人数・レビュー係の有無・形）を足し、悪い型は引退させる

/// 組織の型（遺伝子）
struct OrgGenome: Codable, Hashable {
    enum Shape: String, Codable, CaseIterable {
        /// リーダー（ユーザーが頼んだクラゲ）が一人で
        case solo
        /// 独立した部分に分け、size 人が同時に → リーダーがまとめる
        case parallel
        /// size 段の順番（調べる → 作る → 確かめる など）。前の段の結果が次の段に渡る
        case pipeline
        /// 同じ課題を size 人が別々に → リーダーがよいものを選ぶ・合わせる
        case ensemble
        /// size 人のサブリーダーが、それぞれさらに仲間を作って分担する（大きな仕事）
        case hierarchy
    }

    var shape: Shape
    /// 担当の人数（solo は 0）
    var size: Int
    /// 最後にレビュー係を置く
    var reviewer: Bool

    init(_ shape: Shape, _ size: Int = 0, reviewer: Bool = false) {
        self.shape = shape
        self.size = size
        self.reviewer = reviewer
        self = normalized()
    }

    static let sizeRange: [Shape: ClosedRange<Int>] = [
        .solo: 0...0, .parallel: 2...5, .pipeline: 2...4, .ensemble: 2...3, .hierarchy: 2...3,
    ]

    func normalized() -> OrgGenome {
        var g = self
        let r = OrgGenome.sizeRange[shape] ?? 0...0
        g.size = min(max(size, r.lowerBound), r.upperBound)
        return g
    }

    /// 「parallel3+r」のような短い名前（学習の記録・form_team の formation に使う）
    var key: String { shape == .solo ? "solo" + (reviewer ? "+r" : "") : "\(shape.rawValue)\(size)" + (reviewer ? "+r" : "") }

    init?(key raw: String) {
        var k = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var rev = false
        if k.hasSuffix("+r") { rev = true; k.removeLast(2) }
        let letters = k.prefix { $0.isLetter }
        guard let shape = Shape(rawValue: String(letters)) else { return nil }
        let n = Int(k.dropFirst(letters.count)) ?? OrgGenome.sizeRange[shape]?.lowerBound ?? 0
        self.init(shape, n, reviewer: rev)
    }

    /// 仲間の数（サブリーダーの下の担当は、1 人あたり 2 人と見積もる）
    var agentCount: Int {
        let base: Int
        switch shape {
        case .solo: base = 0
        case .hierarchy: base = size * 3
        default: base = size
        }
        return base + (reviewer ? 1 : 0)
    }

    /// 少しだけ変えた型（進化の候補）
    func mutations() -> [OrgGenome] {
        var out: [OrgGenome] = []
        if let r = OrgGenome.sizeRange[shape], r.count > 1 {
            if size + 1 <= r.upperBound { out.append(OrgGenome(shape, size + 1, reviewer: reviewer)) }
            if size - 1 >= r.lowerBound { out.append(OrgGenome(shape, size - 1, reviewer: reviewer)) }
        }
        out.append(OrgGenome(shape, size, reviewer: !reviewer))
        // 形を変える（人数は近いものに）
        for s in Shape.allCases where s != shape {
            out.append(OrgGenome(s, size == 0 ? 2 : size, reviewer: reviewer))
        }
        return out.filter { $0 != self }
    }

    /// 最初の世代
    static let seeds: [OrgGenome] = [
        OrgGenome(.solo), OrgGenome(.solo, reviewer: true),
        OrgGenome(.parallel, 2), OrgGenome(.parallel, 3), OrgGenome(.parallel, 3, reviewer: true),
        OrgGenome(.pipeline, 2), OrgGenome(.pipeline, 3, reviewer: true),
        OrgGenome(.ensemble, 2, reviewer: true), OrgGenome(.hierarchy, 2),
    ]

    /// 画面・指示に出す名前
    var label: String {
        let base: String
        switch shape {
        case .solo: base = L("一人で")
        case .parallel: base = L("分担して同時に（%ld 人）", size)
        case .pipeline: base = L("順番に（%ld 段）", size)
        case .ensemble: base = L("別々に試して選ぶ（%ld 案）", size)
        case .hierarchy: base = L("サブリーダー %ld 人がさらに分担", size)
        }
        return reviewer ? base + L(" ＋ レビュー係") : base
    }

    /// リーダーへの編成のしかた
    var howTo: String {
        var s: String
        switch shape {
        case .solo:
            s = L("仲間は作らず、自分で進める。")
        case .parallel:
            s = L("依頼を重ならない %ld つの部分に分け、form_team で %ld 人に同時に任せる（after は付けない）。結果を wait_for_tasks で集めて、自分が 1 つの答えにまとめる。", size, size)
        case .pipeline:
            s = L("%ld 段の工程（例: 調べる → 作る → 確かめる）に分け、form_team で各段の担当を作り、2 段目からは after に前の段の担当の名前を入れる（前の結果が自動で渡る）。最後の段の結果を wait_for_tasks で受け取ってまとめる。", size)
        case .ensemble:
            s = L("同じ課題を form_team で %ld 人に別々に任せる（それぞれ違う方針で）。結果を比べて、いちばんよいものを選ぶか、よいところを合わせる。", size)
        case .hierarchy:
            s = L("大きな仕事を %ld つの領域に分け、form_team で各領域のサブリーダーを作る。サブリーダーには「必要なら自分でも form_team で仲間を作って分担してよい」と書く。結果を集めてまとめる。", size)
        }
        if reviewer {
            s += L(" 最後に、ほかの全員を after に入れたレビュー係（名前に「レビュー」を含める）を置き、まとめる前に指摘を受ける。")
        }
        return s
    }
}

/// 依頼の特徴（似ている依頼を探す・依頼の種類からの見込みに使う）
struct TaskFeatures: Codable, Equatable {
    /// 語（日本語・中国語は漢字・カタカナの 2 文字、英語などは単語）と重み（長さ 1 に正規化）
    var terms: [String: Double]
    /// 依頼の種類（research・code・multi など）と長さ（len:short / len:medium / len:long）
    var tags: Set<String>
    var length: Int

    static let tagWords: [(String, [String])] = [
        ("research", ["調べ", "調査", "リサーチ", "探して", "情報を", "最新", "research", "investigate", "look up", "find out", "survey", "调查", "研究", "查找", "搜索", "了解一下"]),
        ("code", ["実装", "コード", "プログラム", "バグ", "修正", "関数", "ビルド", "リファクタ", "スクリプト", "implement", "code", "bug", "fix", "function", "build", "refactor", "script", "代码", "实现", "修复", "程序", "函数", "脚本"]),
        ("review", ["レビュー", "添削", "チェック", "校正", "見直", "review", "proofread", "critique", "check", "审查", "检查", "校对", "评审"]),
        ("writing", ["書いて", "文章", "記事", "原稿", "要約", "まとめて", "ドラフト", "メール文", "write", "draft", "essay", "article", "summarize", "summary", "撰写", "写一", "文章", "总结", "摘要"]),
        ("compare", ["比較", "比べ", "違い", "どちら", "compare", "versus", " vs", "difference", "pros and cons", "比较", "对比", "区别", "哪个"]),
        ("multi", ["それぞれ", "全部", "すべて", "一覧", "複数", "並列", "分担", "各", "each", "every", "all of", "multiple", "several", "in parallel", "list of", "每个", "所有", "多个", "分别", "并行", "列出"]),
        ("translate", ["翻訳", "英訳", "和訳", "translate", "translation", "翻译"]),
        ("data", ["データ", "解析", "分析", "統計", "グラフ", "csv", "data", "analy", "statistic", "plot", "chart", "数据", "统计", "图表"]),
        ("design", ["デザイン", "設計", "構成", "アーキテクチャ", "design", "architecture", "layout", "设计", "架构"]),
        ("test", ["テスト", "検証", "test", "verify", "validate", "测试", "验证"]),
        ("plan", ["計画", "企画", "戦略", "ロードマップ", "手順", "plan", "strategy", "roadmap", "steps", "计划", "策略", "规划"]),
        ("creative", ["アイデア", "案を", "ブレスト", "考えて", "名前", "idea", "brainstorm", "name for", "slogan", "创意", "点子", "头脑风暴", "想法"]),
        ("quick", ["ちょっと", "簡単に", "一言", "すぐ", "だけ", "quick", "simple", "briefly", "just ", "简单", "快速", "一句"]),
        ("pc", ["画面", "クリック", "アプリを開", "screen", "click", "open the app", "屏幕", "点击"]),
    ]

    static let stopwords: Set<String> = ["the", "a", "an", "and", "or", "to", "of", "in", "for", "on", "with", "is", "are", "be",
                                         "this", "that", "it", "please", "me", "my", "you", "can", "could", "would", "will", "i"]

    static func extract(_ text: String) -> TaskFeatures {
        let lower = text.lowercased()
        var counts: [String: Double] = [:]
        // 文字の種類で区切る：漢字・カタカナの続き → 2 文字ずつ、英数字の続き → 単語
        var word = "", cjk: [Character] = []
        func flushWord() {
            if word.count >= 2, !stopwords.contains(word) { counts[word, default: 0] += 1 }
            word = ""
        }
        func flushCJK() {
            if cjk.count == 1 { counts[String(cjk), default: 0] += 0.5 }
            if cjk.count >= 2 { for i in 0..<(cjk.count - 1) { counts[String(cjk[i...i + 1]), default: 0] += 1 } }
            cjk = []
        }
        for ch in lower {
            if ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII {
                flushCJK(); word.append(ch)
            } else if TaskFeatures.isHanOrKatakana(ch) {
                flushWord(); cjk.append(ch)
            } else {
                flushWord(); flushCJK()
            }
        }
        flushWord(); flushCJK()
        // 多すぎる語は上位だけ
        let top = counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(80)
        let norm = sqrt(top.reduce(0) { $0 + $1.value * $1.value })
        var terms: [String: Double] = [:]
        if norm > 0 { for (k, v) in top { terms[k] = v / norm } }

        var tags = Set<String>()
        for (tag, words) in tagWords where words.contains(where: { lower.contains($0) }) { tags.insert(tag) }
        // 長さ：日本語・中国語の 1 文字は英語の約 2.5 文字ぶんの中身があるとみなす
        let n = text.trimmingCharacters(in: .whitespacesAndNewlines).reduce(0.0) { $0 + (TaskFeatures.isCJK($1) ? 2.5 : 1) }
        tags.insert(n < 40 ? "len:short" : (n > 400 ? "len:long" : "len:medium"))
        return TaskFeatures(terms: terms, tags: tags, length: Int(n))
    }

    static func isCJK(_ ch: Character) -> Bool {
        guard let u = ch.unicodeScalars.first?.value else { return false }
        return isHanOrKatakana(ch) || (0x3040...0x309F).contains(u)
    }

    static func isHanOrKatakana(_ ch: Character) -> Bool {
        guard let u = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(u) || (0x3400...0x4DBF).contains(u) || (0x30A0...0x30FF).contains(u) || (0xF900...0xFAFF).contains(u)
    }

    /// 0〜1。語の重なり（コサイン）7 割・種類の重なり（Jaccard）3 割
    func similarity(_ o: TaskFeatures) -> Double {
        var dot = 0.0
        let (small, big) = terms.count <= o.terms.count ? (terms, o.terms) : (o.terms, terms)
        for (k, v) in small { if let w = big[k] { dot += v * w } }
        let kinds = tags.filter { !$0.hasPrefix("len:") }, okinds = o.tags.filter { !$0.hasPrefix("len:") }
        let union = kinds.union(okinds).count
        let jac = union == 0 ? (tags == o.tags ? 1 : 0) : Double(kinds.intersection(okinds).count) / Double(union)
        return max(0, min(1, 0.7 * dot + 0.3 * jac))
    }
}

/// ユーザーの反応
enum OrgReaction: String, Codable {
    case thumbsUp, thumbsDown
    /// 同じ指示をもう一度送った（再実行）
    case retry
    /// 実行中にキャンセルした
    case cancel
    /// 次の指示が「違う」「やり直して」など
    case correction
    /// 次の指示が「ありがとう」「完璧」など
    case praise
    /// 何も言わずに次の話へ進んだ（大きな不満はなかった）
    case movedOn

    /// 次の指示の文から反応を読む（日本語・英語・中国語）
    static func fromFollowUp(_ text: String) -> OrgReaction {
        let t = text.lowercased()
        let correction = ["違う", "ちがう", "間違", "やり直", "そうじゃな", "ダメ", "だめ", "微妙", "足りない", "不十分", "おかしい", "直して",
                          "wrong", "not what", "redo", "try again", "incorrect", "doesn't work", "didn't work", "not right", "broken",
                          "不对", "错了", "重做", "不是这样", "没用", "有问题"]
        let praise = ["ありがとう", "完璧", "いいね", "最高", "素晴らしい", "助か", "ばっちり", "さすが",
                      "thanks", "thank you", "perfect", "great", "awesome", "excellent", "nice work", "well done",
                      "谢谢", "完美", "很好", "太棒", "不错", "辛苦了"]
        if correction.contains(where: { t.contains($0) }) { return .correction }
        if praise.contains(where: { t.contains($0) }) { return .praise }
        return .movedOn
    }
}

/// 実行の成果
struct OrgOutcome: Codable, Equatable {
    /// completed / error / cancelled
    var state: String
    var seconds: Double
    var costUSD: Double?
    /// この依頼のために仲間へ頼んだ作業の数と、そのうち完了した数
    var tasks: Int
    var tasksOK: Int
}

enum OrgReward {
    /// 成果と反応から 0〜1 の点数。👍👎 がいちばん強く効く
    static func score(_ o: OrgOutcome?, _ reactions: [OrgReaction]) -> Double? {
        guard let o else { return nil }
        var r: Double
        switch o.state {
        case "completed": r = 0.65
        case "cancelled": r = 0.1
        default: r = 0.15
        }
        if o.tasks > 0 { r -= 0.25 * (1 - Double(o.tasksOK) / Double(o.tasks)) }
        if o.seconds > 900 { r -= 0.05 }
        for x in reactions {
            switch x {
            case .thumbsUp: r = max(r, 0.85) + 0.1
            case .thumbsDown: r = min(r, 0.25) - 0.1
            case .retry: r -= 0.25
            case .cancel: r -= 0.3
            case .correction: r -= 0.25
            case .praise: r += 0.25
            case .movedOn: r += 0.05
            }
        }
        return max(0, min(1, r))
    }
}

/// 1 回の依頼（エピソード）の記録。端末内（データフォルダの org/）にだけ保存する
struct OrgEpisode: Codable, Equatable {
    var id: String
    var agent: UUID
    var at: Date
    /// 学習のレポート用の短い抜き出し
    var preview: String
    var features: TaskFeatures
    var recommended: String
    /// 実際に組んだ型（form_team や仲間への依頼から。組まなければ solo）
    var used: String?
    var exploration: Bool
    var outcome: OrgOutcome?
    var reactions: [OrgReaction] = []

    var reward: Double? { OrgReward.score(outcome, reactions) }
    var usedKey: String { used ?? "solo" }
}

/// 進化している型の一覧の 1 つ
struct OrgGenomeState: Codable, Equatable {
    var genome: OrgGenome
    var generation: Int
    var parent: String?
    var retired: Bool = false
    var born: Date
}

/// おすすめ
struct OrgRecommendation {
    var genome: OrgGenome
    /// 見込みの点数（0〜1）
    var expected: Double
    /// よく似た過去の依頼の数（重み付き）
    var evidence: Double
    /// 見込みがいちばんの型ではなく、試しに選んだ
    var exploration: Bool
    var alternatives: [OrgGenome]
    var novel: Bool
}

enum OrgPolicy {
    /// 依頼の種類からの見込み（0〜1）。学習の前の出発点（重み 2 の仮の結果として使う）
    static func prior(_ g: OrgGenome, _ f: TaskFeatures) -> Double {
        let t = f.tags
        let short = t.contains("len:short") || t.contains("quick")
        let long = t.contains("len:long")
        var p: Double
        switch g.shape {
        case .solo:
            p = 0.62
            if short { p += 0.2 }
            if t.contains("multi") || long { p -= 0.15 }
            if t.contains("compare") { p -= 0.05 }
        case .parallel:
            p = 0.35
            if t.contains("multi") { p += 0.25 }
            if t.contains("compare") || t.contains("research") { p += 0.12 }
            if short { p -= 0.25 }
            if !t.contains("multi") { p -= 0.04 * Double(g.size - 2) }
        case .pipeline:
            p = 0.33
            if (t.contains("research") && (t.contains("writing") || t.contains("code"))) || (t.contains("code") && t.contains("test")) { p += 0.22 }
            if t.contains("plan") || t.contains("data") { p += 0.08 }
            if short { p -= 0.2 }
        case .ensemble:
            p = 0.28
            if t.contains("creative") { p += 0.27 }
            if t.contains("design") { p += 0.1 }
            if short { p -= 0.15 }
        case .hierarchy:
            p = 0.18
            if long && t.contains("multi") { p += 0.27 }
            if short { p -= 0.15 }
        }
        if g.reviewer {
            if !t.intersection(["review", "code", "writing", "translate"]).isEmpty { p += 0.08 } else { p -= 0.05 }
            if short { p -= 0.08 }
        }
        if t.contains("pc") && g.shape != .solo { p -= 0.15 }   // PC 操作は一人ずつしかできない
        return max(0.05, min(0.95, p))
    }

    /// 見込みの分布（Beta の α, β）と、似た過去の依頼の重み
    static func posterior(_ g: OrgGenome, _ f: TaskFeatures, episodes: [OrgEpisode]) -> (alpha: Double, beta: Double, evidence: Double) {
        let p0 = prior(g, f)
        var a = 1 + 2 * p0, b = 1 + 2 * (1 - p0), ev = 0.0
        for e in episodes {
            guard let r = e.reward, let used = OrgGenome(key: e.usedKey) else { continue }
            let family: Double
            if used == g { family = 1 } else if used.shape == g.shape && used.reviewer == g.reviewer { family = 0.3 } else { continue }
            let s = f.similarity(e.features)
            // よく似た依頼ほど強く、まったく似ていなくても全体の傾向として少しだけ
            let w = family * (4 * s * s + 0.12)
            a += w * r
            b += w * (1 - r)
            if used == g { ev += s * s }
        }
        return (a, b, ev)
    }

    /// 型を選ぶ。sample = false なら見込みがいちばんのもの（テスト・表示用）
    static func recommend(_ f: TaskFeatures, candidates: [OrgGenome], episodes: [OrgEpisode],
                          sample: Bool, rng: inout some RandomNumberGenerator) -> OrgRecommendation {
        let cands = candidates.isEmpty ? [OrgGenome(.solo)] : candidates
        // 人数が多いほど使用量が増えるので、少しだけ割り引く
        let cost = 0.015
        var scored: [(g: OrgGenome, mean: Double, draw: Double, ev: Double)] = []
        for g in cands {
            let (a, b, ev) = posterior(g, f, episodes: episodes)
            let mean = a / (a + b)
            let draw = sample ? Beta.sample(a, b, &rng) : mean
            scored.append((g, mean - cost * Double(g.agentCount), draw - cost * Double(g.agentCount), ev))
        }
        let bestMean = scored.max { $0.mean < $1.mean }!
        let pick = scored.max { $0.draw < $1.draw }!
        let alts = scored.sorted { $0.mean > $1.mean }.map(\.g).filter { $0 != pick.g }.prefix(3)
        let novel = !episodes.contains { $0.reward != nil && f.similarity($0.features) >= 0.35 }
        return OrgRecommendation(genome: pick.g, expected: max(0, min(1, pick.mean + cost * Double(pick.g.agentCount))),
                                 evidence: pick.ev, exploration: pick.g != bestMean.g, alternatives: Array(alts), novel: novel)
    }
}

/// 型の進化：成績のよい型を少し変えた型を足し、明らかに悪い型を引退させる
enum OrgEvolution {
    static let maxActive = 24

    static func stats(_ episodes: [OrgEpisode]) -> [String: (n: Int, mean: Double)] {
        var sum: [String: (Int, Double)] = [:]
        for e in episodes { if let r = e.reward { let v = sum[e.usedKey] ?? (0, 0); sum[e.usedKey] = (v.0 + 1, v.1 + r) } }
        return sum.mapValues { (n: $0.0, mean: $0.1 / Double($0.0)) }
    }

    /// 新しい一覧と、起きたこと（ログ・レポート用）
    static func evolve(_ population: [OrgGenomeState], episodes: [OrgEpisode], now: Date = Date()) -> ([OrgGenomeState], [String]) {
        var pop = population
        var events: [String] = []
        // 実際に使われた型（リーダーが自分で選んだもの）も一覧に入れる
        for e in episodes {
            if let g = OrgGenome(key: e.usedKey), !pop.contains(where: { $0.genome == g }) {
                pop.append(OrgGenomeState(genome: g, generation: (pop.map(\.generation).max() ?? 0), parent: nil, born: now))
                events.append("adopted \(g.key)")
            }
        }
        let st = stats(episodes)
        let gen = (pop.map(\.generation).max() ?? 0) + 1
        let active = pop.filter { !$0.retired }
        // 成績のよい型（2 件以上）から、少し変えた子を作る
        let elites = active.compactMap { s -> (OrgGenomeState, Double)? in
            guard let v = st[s.genome.key], v.n >= 2 else { return nil }
            return (s, v.mean)
        }.sorted { $0.1 > $1.1 }.prefix(2)
        var born = 0
        for (parent, _) in elites {
            for child in parent.genome.mutations() where born < 2 && pop.filter({ !$0.retired }).count < maxActive {
                if pop.contains(where: { $0.genome == child }) { continue }
                pop.append(OrgGenomeState(genome: child, generation: gen, parent: parent.genome.key, born: now))
                events.append("born \(child.key) from \(parent.genome.key)")
                born += 1
                break
            }
        }
        // 明らかに悪い型を引退させる（4 件以上で、いちばんよい型より 0.3 以上低い。「一人で」は残す）
        if let best = st.values.filter({ $0.n >= 2 }).map(\.mean).max() {
            for i in pop.indices where !pop[i].retired && pop[i].genome != OrgGenome(.solo) {
                if let v = st[pop[i].genome.key], v.n >= 4, v.mean < best - 0.3 {
                    pop[i].retired = true
                    events.append("retired \(pop[i].genome.key)")
                }
            }
        }
        return (pop, events)
    }
}

/// Beta 分布の乱数（Gamma の比。Marsaglia–Tsang）
enum Beta {
    static func sample(_ a: Double, _ b: Double, _ rng: inout some RandomNumberGenerator) -> Double {
        let x = gamma(a, &rng), y = gamma(b, &rng)
        return x + y > 0 ? x / (x + y) : 0.5
    }

    static func gamma(_ shape: Double, _ rng: inout some RandomNumberGenerator) -> Double {
        if shape < 1 {
            let u = Double.random(in: Double.ulpOfOne..<1, using: &rng)
            return gamma(shape + 1, &rng) * pow(u, 1 / shape)
        }
        let d = shape - 1.0 / 3, c = 1 / sqrt(9 * d)
        while true {
            var x: Double, v: Double
            repeat {
                x = normal(&rng)
                v = 1 + c * x
            } while v <= 0
            v = v * v * v
            let u = Double.random(in: Double.ulpOfOne..<1, using: &rng)
            if u < 1 - 0.0331 * x * x * x * x { return d * v }
            if log(u) < 0.5 * x * x + d * (1 - v + log(v)) { return d * v }
        }
    }

    static func normal(_ rng: inout some RandomNumberGenerator) -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &rng), u2 = Double.random(in: 0..<1, using: &rng)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// テスト用の決まった乱数
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
