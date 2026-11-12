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
