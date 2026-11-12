import AppKit
import Foundation
import Testing
@testable import JellyfishAI

// 画面・claude・権限を使わない判定ロジックのテスト

@Suite struct URLRouteTests {
    func allowed(_ s: String, automation: Bool = false) -> Bool { URLRoutes.allowed(URL(string: s)!, automation: automation) }

    @Test func publicRoutesAreAllowed() {
        for r in ["new", "toggle", "show", "hide", "arrange", "open?agent=1", "style?v=pixel", "scale?v=1.2"] {
            #expect(allowed("jellyfish://\(r)"), "\(r)")
        }
    }

    @Test func dangerousRoutesNeedAutomation() {
        for r in ["prompt?agent=1&text=hi", "type?agent=1&text=hi", "pc?agent=1&on=1", "folder?agent=1&path=/",
                  "remove?agent=1", "login?on=1", "new?cwd=/tmp", "PROMPT?agent=1&text=hi", "New?cwd=/tmp",
                  "rename?agent=1&name=x", "link?a=1&b=2", "move?agent=1&dx=1", "press?agent=1", "debug"] {
            #expect(!allowed("jellyfish://\(r)"), "\(r)")
            #expect(allowed("jellyfish://\(r)", automation: true), "\(r)")
        }
    }

    @Test func otherSchemesAreRefused() {
        #expect(!allowed("https://example.com/new"))
        #expect(!allowed("https://example.com/new", automation: true))
    }
}

@Suite struct VersionTests {
    @Test func comparesNumerically() {
        #expect(AppVersion.isNewer("v1.10.0", than: "1.9.9"))
        #expect(AppVersion.isNewer("1.0.1", than: "1.0"))
        #expect(!AppVersion.isNewer("v1.0.0", than: "1.0.0"))
        #expect(!AppVersion.isNewer("1.0", than: "1.0.0"))
        #expect(!AppVersion.isNewer("0.9.0", than: "1.0.0"))
        #expect(AppVersion.isNewer("2.0.0-beta.1", than: "1.9.0"))
    }

    @Test func devBuildIsOlderThanAnyRelease() {
        #expect(AppVersion.isNewer("v1.0.0", than: "dev"))
    }
}

@Suite struct ExternalMCPTests {
    let servers = ["blender", "figma", "my-db", "gh"]

    @Test func matchesNamesCaseInsensitively() {
        #expect(ExternalMCP.mentioned(in: "Blender でシーンを作って", servers: servers) == ["blender"])
        #expect(ExternalMCP.mentioned(in: "FIGMA のデザインを見て", servers: servers) == ["figma"])
        #expect(ExternalMCP.mentioned(in: "my-db から読んで", servers: servers) == ["my-db"])
    }

    @Test func matchesJapaneseAliases() {
        #expect(ExternalMCP.mentioned(in: "ブレンダーで立方体", servers: servers) == ["blender"])
        #expect(ExternalMCP.mentioned(in: "フィグマとブレンダー", servers: servers) == ["blender", "figma"])
    }

    @Test func ignoresUnrelatedTextAndVeryShortNames() {
        #expect(ExternalMCP.mentioned(in: "README を直して", servers: servers).isEmpty)
        // 2 文字の名前は普通の単語に紛れるので名前だけでは反応しない
        #expect(ExternalMCP.mentioned(in: "light と ghost", servers: servers).isEmpty)
    }

    @Test func noteNamesTheServers() {
        let n = ExternalMCP.notLoadedNote(["blender", "figma"], canLoad: true)
        #expect(n.contains("blender, figma"))
        #expect(n.contains("blender を使って"))
        #expect(ExternalMCP.notLoadedNote([], canLoad: false).contains("外部ツール（MCP）"))
    }
}

@Suite struct SettingsTests {
    func decode(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func emptyFileGivesDefaults() throws {
        let s = try decode("{}")
        #expect(s.permissionMode == "auto")
        #expect(s.externalMCP == .auto)
        #expect(s.teamEnabled)
        #expect(s.newJellyHotKey == .cmdL)
    }

    @Test func badOrUnknownValuesFallBackInsteadOfFailing() throws {
        let s = try decode(#"{"jellyScale": "big", "externalMCP": "sometimes", "someFutureKey": 1, "maxFPS": 30}"#)
        #expect(s.jellyScale == 1.0)
        #expect(s.externalMCP == .auto)
        #expect(s.maxFPS == 30)
    }

    @Test func roundTrips() throws {
        var s = AppSettings()
        s.externalMCP = .never
        s.claudePath = "~/bin/claude"
        s.archivedSessions = ["a", "b"]
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        #expect(back.externalMCP == .never)
        #expect(back.claudePath == "~/bin/claude")
        #expect(back.archivedSessions == ["a", "b"])
    }
}

@Suite struct ModelTests {
    @Test func linkIsUndirected() {
        let a = UUID(), b = UUID()
        #expect(JellyLink(a, b) == JellyLink(b, a))
        #expect(JellyLink(a, b).other(a) == b)
    }

    @Test func recordTitleFallsBackToNumber() {
        var r = JellyRecord(id: UUID(), number: 7, colorIndex: 0, origin: nil, hidden: false, state: .idle, createdAt: Date())
        #expect(r.title == "Agent 7")
        r.name = "調査係"
        #expect(r.title == "調査係")
    }
}

@Suite struct ScreenIntentTests {
    @Test func explicitScreenReferencesTrigger() {
        for t in ["この画面のエラーを直して", "表示されているボタンの意味は？", "スクショを見て", "what's on my screen?", "このページを要約して"] {
            #expect(ScreenIntent.refersToScreen(t), "\(t)")
        }
    }

    @Test func ordinaryInstructionsDoNotTrigger() {
        for t in ["ファイル一覧を表示して", "3000 番ポートが開いているか確認して", "このコードを直して\n```swift\nlet a = 1\n```",
                  "ログを見てる時間を減らしたい", "このエラーの原因は？ TypeError: x is undefined", "README を直して"] {
            #expect(!ScreenIntent.refersToScreen(t), "\(t)")
        }
    }
}

@Suite struct ProcessTreeTests {
    @Test func findsOwnParent() {
        #expect(ProcessTree.parent(of: getpid()) == getppid())
        #expect(ProcessTree.isDescendant(getpid(), of: getppid()))
    }

    @Test func rejectsUnrelatedProcesses() {
        #expect(!ProcessTree.isDescendant(getppid(), of: getpid()))
        #expect(!ProcessTree.isDescendant(getpid(), of: 999_999))
        #expect(!ProcessTree.isDescendant(0, of: getpid()))
    }
}

@Suite struct SessionReaderTests {
    func line(_ type: String, _ content: String) -> String {
        let obj: [String: Any] = ["type": type, "timestamp": "2026-11-12T00:00:00.000Z",
                                  "message": ["role": type, "content": type == "user" ? content as Any : [["type": "text", "text": content]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    @Test func readsIncrementallyAndWaitsForCompleteLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jf-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("s.jsonl")
        try (line("user", "こんにちは") + "\n" + line("assistant", "はい") + "\n").write(to: f, atomically: true, encoding: .utf8)
        #expect(ClaudeSessions.messages(in: f).map(\.text) == ["こんにちは", "はい"])

        // 書きかけの行は数えず、続きが書かれたら読む。続けて届いた返答は 1 つにまとまる
        let h = try FileHandle(forWritingTo: f)
        h.seekToEndOfFile()
        let next = line("assistant", "続き")
        h.write(Data(next.prefix(10).utf8))
        #expect(ClaudeSessions.messages(in: f).map(\.text) == ["こんにちは", "はい"])
        h.write(Data((String(next.dropFirst(10)) + "\n").utf8))
        try h.close()
        #expect(ClaudeSessions.messages(in: f).map(\.text) == ["こんにちは", "はい\n\n続き"])

        // 書き直されて短くなったら最初から読み直す
        try (line("user", "別の会話") + "\n").write(to: f, atomically: true, encoding: .utf8)
        #expect(ClaudeSessions.messages(in: f).map(\.text) == ["別の会話"])
    }
}

@Suite struct NumberingTests {
    @Test func reusesTheSmallestFreeNumber() {
        #expect(JellyManager.lowestFree([], from: 1) == 1)
        #expect(JellyManager.lowestFree([1, 2, 3], from: 1) == 4)
        #expect(JellyManager.lowestFree([1, 3, 21], from: 1) == 2)
        #expect(JellyManager.lowestFree([21], from: 1) == 1)
        #expect(JellyManager.lowestFree([0, 1], from: 0) == 2)
    }

    @Test func oldSettingsWithCounterStillLoad() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"nextAgentNumber": 22, "maxFPS": 30}"#.utf8))
        #expect(s.maxFPS == 30)
    }
}

@Suite struct RenumberTests {
    @Test func compactsInCurrentOrder() {
        #expect(JellyManager.compactNumbers([21]) == [21: 1])
        #expect(JellyManager.compactNumbers([3, 1, 7]) == [3: 2, 7: 3])
        #expect(JellyManager.compactNumbers([1, 2, 3]).isEmpty)
        #expect(JellyManager.compactNumbers([]).isEmpty)
    }
}

@Suite struct JanitorTests {
    @Test func removesRawLogsOfDeletedAgentsOnly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("jf-janitor-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let live = UUID(), gone = UUID()
        func make(_ id: UUID, _ rel: String) throws {
            let u = root.appendingPathComponent("agents/\(id.uuidString)/\(rel)")
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: u)
        }
        for id in [live, gone] {
            try make(id, "events.jsonl")
            try make(id, "history.json")
            try make(id, "attachments/screen-1.png")
            try make(id, "transcripts/transcript-1.txt")
        }
        DataJanitor.cleanUpRemovedAgents(dataDir: root, live: [live], minAge: 0)
        func exists(_ id: UUID, _ rel: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent("agents/\(id.uuidString)/\(rel)").path) }
        // 消したクラゲ：生イベントと画像だけ消え、履歴と文字起こしは残る
        #expect(!exists(gone, "events.jsonl"))
        #expect(!exists(gone, "attachments"))
        #expect(exists(gone, "history.json"))
        #expect(exists(gone, "transcripts/transcript-1.txt"))
        // いるクラゲ：何も消えない
        #expect(exists(live, "events.jsonl"))
        #expect(exists(live, "attachments/screen-1.png"))
    }

    @Test func leavesRecentlyTouchedFoldersAlone() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("jf-janitor-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let id = UUID()
        let u = root.appendingPathComponent("agents/\(id.uuidString)/events.jsonl")
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u)
        DataJanitor.cleanUpRemovedAgents(dataDir: root, live: [])
        #expect(fm.fileExists(atPath: u.path))
    }
}

@Suite struct PromptHistoryTests {
    @Test func walksBackAndForthAndRestoresTheDraft() {
        var h = PromptHistory()
        let load = { ["一つ目", "二つ目", "三つ目"] }
        #expect(h.older(current: "書きかけ", load: load) == "三つ目")
        #expect(h.older(current: "三つ目", load: load) == "二つ目")
        #expect(h.older(current: "二つ目", load: load) == "一つ目")
        #expect(h.older(current: "一つ目", load: load) == nil)      // いちばん古いところで止まる
        #expect(h.newer() == "二つ目")
        #expect(h.newer() == "三つ目")
        #expect(h.newer() == "書きかけ")                            // 下書きに戻る
        #expect(h.newer() == nil)
        #expect(!h.isBrowsing)
    }

    @Test func emptyHistoryDoesNothing() {
        var h = PromptHistory()
        #expect(h.older(current: "", load: { [] }) == nil)
        #expect(h.newer() == nil)
    }

    @Test func keepsOnlyWhatTheUserTyped() {
        let raw = [
            "README を直して",
            "この画面のエラーは？" + ScreenContext.marker + "\n画像: /tmp/screen.png",
            "これを見て" + AgentChatController.attachMarker + "\n- /tmp/a.pdf",
            TeamCoordinator.requestMarker + "Agent 2]\n調べて" + TeamCoordinator.requestFooter,
            "続けて", "続けて",
            "  ",
        ]
        #expect(AgentChatController.typedPrompts(raw) == ["README を直して", "この画面のエラーは？", "これを見て", "続けて"])
    }
}

@MainActor @Suite struct PromptKeyTests {
    func key(_ code: UInt16, _ ch: Int) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: String(UnicodeScalar(ch)!), charactersIgnoringModifiers: String(UnicodeScalar(ch)!),
                         isARepeat: false, keyCode: code)!
    }
    let up = (UInt16(126), 0xF700), down = (UInt16(125), 0xF701)

    @Test func arrowsRecallOnlyFromTheEdgeLines() {
        let v = PromptTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        var calls: [Bool] = []
        v.onHistory = { older in calls.append(older); return true }
        func caret(_ loc: Int) { v.setSelectedRange(NSRange(location: loc, length: 0)) }

        // 空の入力欄：↑ で呼び出す
        v.keyDown(with: key(up.0, up.1))
        #expect(calls == [true])

        // 2 行の入力
        v.string = "1 行目\n2 行目"
        let end = (v.string as NSString).length
        caret(end)                       // 2 行目：↑ は呼び出さない（カーソル移動に任せる）、↓ は呼び出す
        #expect(!v.caretOnFirstLine && v.caretOnLastLine)
        v.keyDown(with: key(up.0, up.1))
        #expect(calls == [true])
        v.keyDown(with: key(down.0, down.1))
        #expect(calls == [true, false])
        caret(2)                         // 1 行目：↑ は呼び出す、↓ は呼び出さない
        #expect(v.caretOnFirstLine && !v.caretOnLastLine)
        v.keyDown(with: key(down.0, down.1))
        #expect(calls == [true, false])
        v.keyDown(with: key(up.0, up.1))
        #expect(calls == [true, false, true])

        // 範囲を選んでいるときは呼び出さない
        v.setSelectedRange(NSRange(location: 0, length: 3))
        v.keyDown(with: key(up.0, up.1))
        #expect(calls == [true, false, true])
    }

    @Test func wrappedLongLineCountsAsSeveralLines() {
        let v = PromptTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 200))
        v.string = String(repeating: "とても長い指示の文です。", count: 8)
        v.setSelectedRange(NSRange(location: (v.string as NSString).length, length: 0))
        #expect(!v.caretOnFirstLine)      // 折り返した最後の行にいる
        #expect(v.caretOnLastLine)
        v.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(v.caretOnFirstLine)
        #expect(!v.caretOnLastLine)
    }

    @Test func doesNothingWhileRunning() {
        let v = PromptTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        var called = false
        v.onHistory = { _ in called = true; return true }
        v.isEditable = false
        v.keyDown(with: key(up.0, up.1))
        #expect(!called)
    }
}

@Suite struct AccountTests {
    let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tokyo
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func readsWeeklyLimitsFromUsage() {
        let text = """
        You are currently using your subscription to power your Claude Code usage

        Current week (all models): 57% used · resets Nov 13 at 2:59am (Asia/Tokyo)
        Current week (Fable): 76% used · resets Nov 13 at 2:59am (Asia/Tokyo)

        What's contributing to your usage?
          98%  Give "general-purpose" subagents a cheaper model
        """
        let limits = ClaudeAccount.parseUsage(text, now: date(2026, 11, 12, 13, 30))
        #expect(limits.map(\.label) == ["今週（全モデル）", "今週（Fable）"])
        #expect(limits.map(\.percent) == [57, 76])
        #expect(limits.allSatisfy { $0.resetsAt == date(2026, 11, 13, 2, 59) })
    }

    @Test func resetTimes() {
        let now = date(2026, 11, 12, 16, 0)
        #expect(ClaudeAccount.parseReset("3pm (Asia/Tokyo)", now: now) == date(2026, 11, 13, 15, 0))   // もう過ぎたので明日
        #expect(ClaudeAccount.parseReset("11:30pm (Asia/Tokyo)", now: now) == date(2026, 11, 12, 23, 30))
        #expect(ClaudeAccount.parseReset("Nov 13 at 12am (Asia/Tokyo)", now: now) == date(2026, 11, 13, 0, 0))
        #expect(ClaudeAccount.parseReset("Jan 2 at 12pm (Asia/Tokyo)", now: date(2026, 12, 30, 9, 0)) == date(2027, 1, 2, 12, 0))
        #expect(ClaudeAccount.parseReset("next Tuesday", now: now) == nil)
        #expect(ClaudeAccount.parseReset("3pm (Not/AZone)", now: now) == nil)
    }

    @Test func unreadableResetKeepsText() {
        let l = ClaudeAccount.parseUsage("Current session: 12% used · resets soon")
        #expect(l == [ClaudeAccount.Limit(label: "今のセッション", percent: 12, resetsAt: nil, resetsText: "soon")])
    }

    @Test func accountAndPlan() {
        let json = #"{"loggedIn": true, "authMethod": "claude.ai", "email": "someone@example.com", "subscriptionType": "max", "planTier": "max_20x"}"#
        let a = ClaudeAccount.parseAccount(Data(json.utf8))
        #expect(a == ClaudeAccount.Account(loggedIn: true, email: "someone@example.com", plan: "Max 20x"))
        #expect(ClaudeAccount.parseAccount(Data(#"{"loggedIn": false}"#.utf8))?.loggedIn == false)
        #expect(ClaudeAccount.parseAccount(Data("not json".utf8)) == nil)
        #expect(ClaudeAccount.planLabel(subscription: "pro", tier: nil) == "Pro")
        #expect(ClaudeAccount.planLabel(subscription: nil, tier: "max_5x") == nil)
    }
}
