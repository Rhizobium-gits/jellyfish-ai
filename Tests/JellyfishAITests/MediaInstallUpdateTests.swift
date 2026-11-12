import Foundation
import Testing
@testable import JellyfishAI

// チャットの画像・PDF・Web のプレビュー、CLI を入れてログイン、アップデートのテスト

@Suite struct ChatMediaTests {
    let exists: (String) -> Bool = { ["/tmp/a.png", "/tmp/doc.pdf", "/Users/me/b.jpg"].contains($0) }

    @Test func picksFilesAndURLs() {
        let text = "できました: /tmp/a.png と ![図](/tmp/doc.pdf)。参考 https://example.com/page。"
        let refs = ChatMedia.refs(in: text, fileExists: exists)
        #expect(refs.map(\.kind) == [.image, .pdf, .web])
        #expect(refs[0].url.path == "/tmp/a.png")
        #expect(refs[1].url.path == "/tmp/doc.pdf")
        // 文の終わりの句読点は URL に入れない
        #expect(refs[2].url.absoluteString == "https://example.com/page")
    }

    @Test func ignoresMissingFilesAndPathsInsideURLs() {
        let text = "/tmp/none.png は無い。https://example.com/img/x.png は Web のもの"
        let refs = ChatMedia.refs(in: text, fileExists: exists)
        #expect(refs.count == 1)
        #expect(refs[0].kind == .web)
        #expect(refs[0].url.absoluteString == "https://example.com/img/x.png")
    }

    @Test func onlyHTTPAndLimitAndDedup() {
        let text = "ftp://example.com/a file:///tmp/a.png `/tmp/a.png` /tmp/a.png https://a.example https://a.example"
        let refs = ChatMedia.refs(in: text, fileExists: exists)
        #expect(refs.filter { $0.kind == .web }.count == 1)
        #expect(refs.filter { $0.kind == .image }.count == 1)
        let many = (1...10).map { "https://e\($0).example" }.joined(separator: " ")
        #expect(ChatMedia.refs(in: many, limit: 3, fileExists: exists).count == 3)
    }

    @Test func agentURLsWaitForAClick() {
        // エージェントの返答の URL は読みに行かず、「表紙を見る」のリンクだけ出す
        let u = URL(string: "https://example.invalid/collect?d=secret")!
        let a = ChatMediaCache.shared.attachment(ChatMedia.Ref(kind: .web, url: u), webPreviews: true, autoWeb: false)
        #expect(a?.string.contains("表紙を見る") == true)
        var links: [URL] = []
        a?.enumerateAttribute(.link, in: NSRange(location: 0, length: a?.length ?? 0)) { v, _, _ in if let l = v as? URL { links.append(l) } }
        let p = try! #require(links.first { $0.scheme == ChatMediaCache.previewScheme })
        #expect(ChatMediaCache.target(of: p) == u)
        // Web のプレビューを止めていれば何も出さない
        #expect(ChatMediaCache.shared.attachment(ChatMedia.Ref(kind: .web, url: u), webPreviews: false, autoWeb: false) == nil)
        // http / https 以外は指せない
        #expect(ChatMediaCache.target(of: URL(string: "jellyfish-preview:file%3A%2F%2F%2Fetc%2Fpasswd")!) == nil)
        #expect(ChatMediaCache.target(of: URL(string: "https://example.com")!) == nil)
    }

    @Test func expandsHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let refs = ChatMedia.refs(in: "~/x.heic", fileExists: { $0 == home + "/x.heic" })
        #expect(refs.first?.url.path == home + "/x.heic")
    }

    @Test func fileCheckNeedsRealImageOrPDF() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jf-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("a.png")
        try Data([0x89, 0x50]).write(to: png)
        let txt = dir.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: txt)
        #expect(ChatMedia.fileOK(png.path))
        #expect(!ChatMedia.fileOK(txt.path))
        #expect(!ChatMedia.fileOK(dir.path))
    }
}

@Suite struct EngineInstallTests {
    @Test func claudeUsesOfficialInstaller() {
        let p = EngineInstall.plan(.claude, npm: "/opt/homebrew/bin/npm", npmWritable: true, brew: "/opt/homebrew/bin/brew")
        #expect(p?.tool == .official)
        #expect(p?.command == "curl -fsSL https://claude.ai/install.sh | bash")
    }

    @Test func prefersWritableNpmThenBrew() {
        let npm = EngineInstall.plan(.codex, npm: "/opt/homebrew/bin/npm", npmWritable: true, brew: "/opt/homebrew/bin/brew")
        #expect(npm?.command == "/opt/homebrew/bin/npm install -g @openai/codex")
        // npm の入れ先に書けない（sudo が要る）なら Homebrew
        let brew = EngineInstall.plan(.codex, npm: "/usr/local/bin/npm", npmWritable: false, brew: "/opt/homebrew/bin/brew")
        #expect(brew?.command == "/opt/homebrew/bin/brew install --cask codex")
        let gem = EngineInstall.plan(.gemini, npm: nil, npmWritable: false, brew: "/usr/local/bin/brew")
        #expect(gem?.command == "/usr/local/bin/brew install gemini-cli")
        #expect(EngineInstall.plan(.gemini, npm: "/x/npm", npmWritable: true, brew: nil)?.command == "/x/npm install -g @google/gemini-cli")
        // どちらも無ければ入れない
        #expect(EngineInstall.plan(.codex, npm: nil, npmWritable: false, brew: nil) == nil)
        #expect(EngineInstall.plan(.gemini, npm: "/x/npm", npmWritable: false, brew: nil) == nil)
    }

    @Test func quotesUnusualPaths() {
        #expect(EngineInstall.word("/opt/homebrew/bin/npm") == "/opt/homebrew/bin/npm")
        #expect(EngineInstall.word("/Users/a b/npm") == "'/Users/a b/npm'")
        #expect(EngineInstall.word("/x/$(rm)") == "'/x/$(rm)'")
    }

    @Test func scriptInstallsThenLogsIn() {
        let p = EngineInstall.plan(.codex, npm: "/opt/homebrew/bin/npm", npmWritable: true, brew: nil)!
        let s = EngineInstall.script(p, allowAPI: false)
        #expect(s.hasPrefix("#!/bin/zsh -l\nunset "))
        #expect(s.contains("OPENAI_API_KEY"))
        #expect(s.contains("set -o pipefail"))
        #expect(s.contains("\n/opt/homebrew/bin/npm install -g @openai/codex\n"))
        #expect(s.contains("cli=\"$(command -v codex)\""))
        #expect(s.contains("exec \"$cli\" login"))
        #expect(!s.contains("sudo"))
        // 実行するコマンドは画面に出したものと同じ 1 つだけ
        #expect(s.components(separatedBy: "install -g @openai/codex").count == 3)  // 表示 1 回 + 実行 1 回
        let c = EngineInstall.script(EngineInstall.plan(.claude, npm: nil, npmWritable: false, brew: nil)!, allowAPI: true)
        #expect(!c.contains("unset "))
        #expect(c.contains("\ncurl -fsSL https://claude.ai/install.sh | bash\n"))
        #expect(c.contains("export PATH=\"$HOME/.local/bin:$PATH\""))
        #expect(c.contains("exec \"$cli\" auth login --claudeai"))
    }

    @Test func scriptsAreValidZsh() throws {
        let plans = [EngineInstall.plan(.claude, npm: nil, npmWritable: false, brew: nil)!,
                     EngineInstall.plan(.codex, npm: "/opt/homebrew/bin/npm", npmWritable: true, brew: nil)!,
                     EngineInstall.plan(.gemini, npm: nil, npmWritable: false, brew: "/Users/a b/brew")!]
        for p in plans {
            let f = FileManager.default.temporaryDirectory.appendingPathComponent("jf-install-\(UUID().uuidString).command")
            try EngineInstall.script(p, allowAPI: false).write(to: f, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: f) }
            let z = Process()
            z.executableURL = URL(fileURLWithPath: "/bin/zsh")
            z.arguments = ["-n", f.path]
            try z.run()
            z.waitUntilExit()
            #expect(z.terminationStatus == 0, "\(p.engine)")
        }
    }

    @Test func loginScriptUnchanged() {
        let s = EngineLogin.script(.gemini, cli: URL(fileURLWithPath: "/opt/homebrew/bin/gemini"), folder: URL(fileURLWithPath: "/tmp/w"), allowAPI: false)
        #expect(s.contains("cd '/tmp/w' || exit 1"))
        #expect(s.hasSuffix("exec '/opt/homebrew/bin/gemini'\n"))
    }
}

@Suite struct UpdaterTests {
    func json(tag: String = "v1.0.6", zipURL: String? = nil, sumsURL: String? = nil) -> [String: Any] {
        let base = "https://github.com/\(AppInfo.repo)/releases/download/\(tag)/"
        return [
            "tag_name": tag,
            "body": "notes",
            "assets": [
                ["name": "JellyfishAI-\(tag.dropFirst()).zip", "browser_download_url": zipURL ?? base + "JellyfishAI-\(tag.dropFirst()).zip"],
                ["name": "SHA256SUMS.txt", "browser_download_url": sumsURL ?? base + "SHA256SUMS.txt"],
                ["name": "JellyfishAI-\(tag.dropFirst()).dmg", "browser_download_url": base + "JellyfishAI-\(tag.dropFirst()).dmg"],
            ],
        ]
    }

    @Test func readsRelease() {
        let r = AppUpdater.release(from: json())
        #expect(r?.version == "1.0.6")
        #expect(r?.zipName == "JellyfishAI-1.0.6.zip")
        #expect(r?.zip.absoluteString == "https://github.com/\(AppInfo.repo)/releases/download/v1.0.6/JellyfishAI-1.0.6.zip")
        #expect(r?.notes == "notes")
    }

    @Test func refusesOtherPlaces() {
        // 別のリポジトリ・別のホスト・別のタグのファイルは使わない
        #expect(AppUpdater.release(from: json(zipURL: "https://github.com/evil/jellyfish-ai/releases/download/v1.0.6/JellyfishAI-1.0.6.zip")) == nil)
        #expect(AppUpdater.release(from: json(zipURL: "https://example.com/JellyfishAI-1.0.6.zip")) == nil)
        #expect(AppUpdater.release(from: json(sumsURL: "http://github.com/\(AppInfo.repo)/releases/download/v1.0.6/SHA256SUMS.txt")) == nil)
        #expect(AppUpdater.release(from: json(zipURL: "https://github.com/\(AppInfo.repo)/releases/download/v1.0.5/JellyfishAI-1.0.6.zip")) == nil)
        #expect(AppUpdater.release(from: json(tag: "v1.0.6/../x")) == nil)
        #expect(AppUpdater.release(from: ["tag_name": "v1.0.6"]) == nil)
    }

    @Test func readsChecksums() {
        let sums = """
        1111111111111111111111111111111111111111111111111111111111111111  JellyfishAI-1.0.6.dmg
        ABCDEFabcdef0000000000000000000000000000000000000000000000000000  JellyfishAI-1.0.6.zip
        """
        #expect(AppUpdater.checksum(in: sums, for: "JellyfishAI-1.0.6.zip") == "abcdefabcdef0000000000000000000000000000000000000000000000000000")
        #expect(AppUpdater.checksum(in: sums, for: "JellyfishAI-1.0.7.zip") == nil)
        #expect(AppUpdater.checksum(in: "xyz  JellyfishAI-1.0.6.zip", for: "JellyfishAI-1.0.6.zip") == nil)
    }

    @Test func hashesFiles() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("jf-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        #expect(try AppUpdater.sha256(f) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func checksBundle() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("jf-up-\(UUID().uuidString)/JellyfishAI.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        let info: NSDictionary = ["CFBundleIdentifier": "ai.jellyfish.desktop", "CFBundleShortVersionString": "1.0.6"]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        #expect(AppUpdater.bundleProblem(app, version: "1.0.6", bundleID: "ai.jellyfish.desktop") == nil)
        #expect(AppUpdater.bundleProblem(app, version: "1.0.7", bundleID: "ai.jellyfish.desktop") != nil)
        #expect(AppUpdater.bundleProblem(app, version: "1.0.6", bundleID: "ai.jellyfish.desktop.orgtest") != nil)
        #expect(AppUpdater.bundleProblem(app, version: "1.0.6", bundleID: nil) != nil)
        // 署名の無いものは通さない
        #expect(AppUpdater.signatureProblem(new: app, current: app) != nil)
    }

    /// 実際のリリースで、ダウンロード → チェックサム → 展開 → 中身と署名の確認までを通す（ネットにつなぐので JELLYFISH_LIVE_UPDATE_TEST=1 のときだけ）
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JELLYFISH_LIVE_UPDATE_TEST"] == "1"))
    func liveReleaseVerifies() async throws {
        let tag = ProcessInfo.processInfo.environment["JELLYFISH_LIVE_UPDATE_TAG"] ?? "v1.0.5"
        let (j, _) = try await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/tags/\(tag)")!)
        let json = try #require(try JSONSerialization.jsonObject(with: j) as? [String: Any])
        let r = try #require(AppUpdater.release(from: json))
        let (sums, _) = try await URLSession.shared.data(from: r.sums)
        let expected = try #require(AppUpdater.checksum(in: String(decoding: sums, as: UTF8.self), for: r.zipName))
        let (tmp, _) = try await URLSession.shared.download(from: r.zip)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jf-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent(r.zipName)
        try FileManager.default.moveItem(at: tmp, to: zip)
        #expect(try AppUpdater.sha256(zip) == expected)
        let d = Process()
        d.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        d.arguments = ["-x", "-k", zip.path, dir.appendingPathComponent("new").path]
        try d.run()
        d.waitUntilExit()
        let app = dir.appendingPathComponent("new/JellyfishAI.app")
        #expect(AppUpdater.bundleProblem(app, version: r.version, bundleID: "ai.jellyfish.desktop") == nil)
        #expect(AppUpdater.signatureProblem(new: app, current: app) == nil)
        if FileManager.default.fileExists(atPath: "/Applications/JellyfishAI.app") {
            print("live: installed adhoc=\(AppUpdater.isAdhoc(URL(fileURLWithPath: "/Applications/JellyfishAI.app"))) release adhoc=\(AppUpdater.isAdhoc(app))",
                  "vs installed:", AppUpdater.signatureProblem(new: app, current: URL(fileURLWithPath: "/Applications/JellyfishAI.app")) ?? "ok")
        }
    }

    @Test func refusesDevBuildLocation() {
        #expect(AppUpdater.locationProblem(URL(fileURLWithPath: "/tmp/JellyfishAI")) != nil)
    }
}

// ChatGPT（Codex）の使用量の枠・仲間の考える強さ・AI が変わったときの会話

@Suite struct CodexUsageTests {
    /// Codex の記録（rollout-*.jsonl）の token_count の行（この Mac の実物と同じ形）
    static func line(primary: Double = 1.0, secondary: Double = 12.0, primaryReset: Double, secondaryReset: Double, plan: String = "plus") -> String {
        #"{"timestamp":"2026-11-12T09:56:41.323Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":"# + "\(primary)" + #","window_minutes":300,"resets_at":"# + "\(Int(primaryReset))" + #"},"secondary":{"used_percent":"# + "\(secondary)" + #","window_minutes":10080,"resets_at":"# + "\(Int(secondaryReset))" + #"},"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"plan_type":""# + plan + #"","rate_limit_reached_type":null}}}"#
    }

    @Test func readsLimitsAndPlan() throws {
        let now = Date(timeIntervalSince1970: 1_794_470_000)
        let v = try #require(CodexUsage.parse(line: Self.line(primaryReset: 1_794_490_261, secondaryReset: 1_794_477_447), now: now))
        #expect(v.plan == "plus")
        #expect(CodexUsage.planName(v.plan) == "ChatGPT Plus")
        #expect(v.limits.map(\.label) == ["5 時間の枠", "今週の枠"])
        #expect(v.limits.map(\.percent) == [1, 12])
        #expect(v.limits[1].resetsAt == Date(timeIntervalSince1970: 1_794_477_447))
        #expect(v.observedAt != nil)
    }

    @Test func resetWindowsShowZero() throws {
        let now = Date(timeIntervalSince1970: 1_794_480_000)
        let v = try #require(CodexUsage.parse(line: Self.line(secondary: 80, primaryReset: 1_794_490_261, secondaryReset: 1_794_477_447), now: now))
        #expect(v.limits[1].percent == 0)
        #expect(v.limits[1].resetsAt == nil)
    }

    @Test func ignoresOtherLines() {
        #expect(CodexUsage.parse(line: #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":null}}"#) == nil)
        #expect(CodexUsage.parse(line: #"{"type":"response_item","payload":{"type":"message","content":"rate_limits"}}"#) == nil)
        #expect(CodexUsage.parse(line: "not json") == nil)
        #expect(CodexUsage.label(60) == "1 時間の枠")
        #expect(CodexUsage.label(1440) == "1 日の枠")
    }

    @Test func findsTheNewestRecord() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("jf-codex-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_794_470_000)
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let dir = home.appendingPathComponent(String(format: "sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = [#"{"type":"session_meta","payload":{}}"#,
                    Self.line(primary: 3, primaryReset: 1_794_490_261, secondaryReset: 1_794_477_447),
                    #"{"type":"response_item","payload":{"type":"message"}}"#,
                    Self.line(primary: 7, primaryReset: 1_794_490_261, secondaryReset: 1_794_477_447)].joined(separator: "\n") + "\n"
        try body.write(to: dir.appendingPathComponent("rollout-2026-11-12T10-00-00-x.jsonl"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        let v = try #require(CodexUsage.read(home: home, now: now))
        #expect(v.limits.first?.percent == 7)
        #expect(CodexUsage.read(home: home.appendingPathComponent("none"), now: now) == nil)
        #expect(CodexUsage.home(["CODEX_HOME": "/tmp/x"]).path == "/tmp/x")
    }
}

@Suite struct TeammateEffortTests {
    @Test func claudeEfforts() {
        #expect(TeamCoordinator.requestedEffort("High", engine: .claude, model: nil).0 == "high")
        #expect(TeamCoordinator.requestedEffort(nil, engine: .claude, model: nil) == (nil, nil))
        let (v, err) = TeamCoordinator.requestedEffort("ultra", engine: .claude, model: nil)
        #expect(v == nil)
        #expect(err?.contains("max") == true)
    }

    @Test func geminiHasNoEffort() {
        let (v, err) = TeamCoordinator.requestedEffort("high", engine: .gemini, model: nil)
        #expect(v == nil && err != nil)
        #expect(TeamCoordinator.effortList(.gemini).isEmpty)
    }

    @Test func codexWithoutCatalogTakesPlainNames() {
        // 一覧を読めていない（テストの環境）ときは、英小文字の名前だけ通す
        guard EngineModelCatalog.shared.models(.codex).isEmpty else { return }
        #expect(TeamCoordinator.requestedEffort("high", engine: .codex, model: nil).0 == "high")
        #expect(TeamCoordinator.requestedEffort("hi\"gh", engine: .codex, model: nil).0 == nil)
    }
}

/// 起動のしかたを覚えるだけの AI（プロセスを動かさない）
final class RecordingBackend: AgentBackend {
    final class Handle: AgentHandle {
        var isRunning = true
        var processID: Int32? { nil }
        func cancel() { isRunning = false }
    }
    let engine: AgentEngine
    var assignsSessionID: Bool { engine == .codex }
    var displayName: String { engine.displayName }
    var defaultModel: String? { nil }
    var policyDescription: String { "" }
    var calls: [(sessionID: String, resume: Bool, model: String?)] = []
    var onEvent: ((AgentEvent) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    init(_ e: AgentEngine) { engine = e }
    func run(prompt: String, sessionID: String, resume: Bool, cwd: URL, logDir: URL, options: AgentRunOptions,
             onEvent: @escaping (AgentEvent) -> Void, onExit: @escaping (Int32, String) -> Void) throws -> AgentHandle {
        calls.append((sessionID, resume, options.model))
        self.onEvent = onEvent
        self.onExit = onExit
        return Handle()
    }
}

@Suite struct EngineSwitchTests {
    @Test func defaultEngineChangeStartsANewConversation() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("jf-switch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let claude = RecordingBackend(.claude), codex = RecordingBackend(.codex)
        var current: AgentBackend = claude
        let rt = AgentRuntime(agentID: UUID(), baseDir: base, backendProvider: { _ in current })
        rt.model = "sonnet"
        #expect(rt.submit("1 回目"))
        let first = try #require(claude.calls.first)
        #expect(first.resume == false)
        claude.onEvent?(.started(session: first.sessionID, model: "claude-sonnet", permissionMode: "auto"))
        claude.onEvent?(.finished(success: true, result: "ok", costUSD: nil, durationMs: nil))
        claude.onExit?(0, "")
        #expect(!rt.isRunning)
        // 同じ AI なら続き
        #expect(rt.submit("2 回目"))
        #expect(claude.calls.last?.resume == true)
        #expect(claude.calls.last?.sessionID == first.sessionID)
        claude.onEvent?(.finished(success: true, result: "ok", costUSD: nil, durationMs: nil))
        claude.onExit?(0, "")
        // 既定の AI が ChatGPT に変わった：Claude の会話を Codex で続けようとしない。Claude のモデルの指定も外す
        current = codex
        #expect(rt.submit("3 回目"))
        let c = try #require(codex.calls.first)
        #expect(c.resume == false)
        #expect(c.sessionID != first.sessionID)
        #expect(c.model == nil)
        #expect(rt.model == nil)
        // 返答の見出しのために、ターンごとの AI を覚えている
        #expect(rt.turns.map(\.engine) == ["claude", "claude", "codex"])
    }
}

@Suite struct AttachmentsForEveryAITests {
    @Test func codexGetsImagesBeforeThePrompt() {
        let a = CodexBackend.arguments(prompt: "見て", sessionID: nil, model: nil, images: [URL(fileURLWithPath: "/tmp/s 1.png")])
        let i = a.firstIndex(of: "--image")!
        #expect(a[i + 1] == "/tmp/s 1.png")
        #expect(i < a.firstIndex(of: "--")!)
        #expect(a.last == "見て")
        let r = CodexBackend.arguments(prompt: "続き", sessionID: "0199a213-81c0-7800-8aa1-bbab2a035a53", model: nil,
                                       images: [URL(fileURLWithPath: "/tmp/a.png"), URL(fileURLWithPath: "/tmp/b.png")])
        #expect(r.filter { $0 == "--image" }.count == 2)
        #expect(Array(r.suffix(2)) == ["0199a213-81c0-7800-8aa1-bbab2a035a53", "続き"])
    }

    @Test func readsAttachedFilesOnlyFromTheAttachmentSection() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jf-att-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("screen.png"), txt = dir.appendingPathComponent("transcript.txt")
        try Data([1]).write(to: png)
        try Data("x".utf8).write(to: txt)
        let text = "- \(png.path) は本文の中なので数えない" + AgentChatController.attachMarker + "\n- \(txt.path)\n- /nonexistent/x.png"
            + ScreenContext.marker + "\n- \(png.path)\n"
        let files = AgentRuntime.attachedFiles(in: text)
        #expect(files.map(\.lastPathComponent) == ["transcript.txt", "screen.png"])
        #expect(AgentRuntime.attachedFiles(in: "添付なし - /tmp") == [])
    }
}

/// scripts/update.sh を、偽のリリースの情報（JELLYFISH_RELEASE_JSON）と偽のアプリで動かす（ネットにつながない・入れ替えない）
@Suite struct UpdateScriptTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func fakeApp(_ dir: URL, version: String, id: String = "ai.jellyfish.desktop") throws -> URL {
        let app = dir.appendingPathComponent("JellyfishAI.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
        info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        return app
    }

    func release(_ dir: URL, tag: String, zipURL: String? = nil) throws -> URL {
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let base = "https://github.com/\(AppInfo.repo)/releases/download/\(tag)/"
        let json: [String: Any] = ["tag_name": tag, "assets": [
            ["name": "JellyfishAI.dmg", "browser_download_url": base + "JellyfishAI.dmg"],
            ["name": "JellyfishAI-\(v).zip", "browser_download_url": zipURL ?? base + "JellyfishAI-\(v).zip"],
            ["name": "SHA256SUMS.txt", "browser_download_url": base + "SHA256SUMS.txt"],
        ]]
        let f = dir.appendingPathComponent("latest-\(UUID().uuidString).json")
        try JSONSerialization.data(withJSONObject: json).write(to: f)
        return f
    }

    func run(_ args: [String], json: URL) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.root.appendingPathComponent("scripts/update.sh").path] + args
        var env = ProcessInfo.processInfo.environment
        env["JELLYFISH_RELEASE_JSON"] = json.path
        env["JELLYFISH_UPDATE_TEST"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("jf-upd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func ignoresTestOverridesOutsideTests() throws {
        let script = try String(contentsOf: Self.root.appendingPathComponent("scripts/update.sh"), encoding: .utf8)
        #expect(script.contains(#"if [[ "${JELLYFISH_UPDATE_TEST:-}" == 1 ]]; then REPO="${JELLYFISH_REPO:-$REPO}"; else unset JELLYFISH_RELEASE_JSON; fi"#))
        #expect(script.contains("REPO=Rhizobium-gits/jellyfish-ai\n"))
    }

    @Test func reportsANewerRelease() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let app = try fakeApp(d, version: "1.0.6")
        let (rc, out) = try run(["--check", "--app", app.path], json: try release(d, tag: "v1.0.7"))
        #expect(rc == 10)
        #expect(out.contains("1.0.7"))
        #expect(out.contains("releases/download/v1.0.7/JellyfishAI-1.0.7.zip"))
    }

    @Test func comparesVersionsAsNumbers() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        // 1.0.10 は 1.0.9 より新しい（文字の順ではない）
        let (rc, out) = try run(["--check", "--app", try fakeApp(d, version: "1.0.10").path], json: try release(d, tag: "v1.0.9"))
        #expect(rc == 0)
        #expect(out.contains("最新です"))
        let (rc2, _) = try run(["--check", "--app", try fakeApp(try tmp(), version: "1.0.9").path], json: try release(d, tag: "v1.0.10"))
        #expect(rc2 == 10)
    }

    @Test func refusesFilesFromElsewhere() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let app = try fakeApp(d, version: "1.0.6")
        let (rc, out) = try run(["--check", "--app", app.path],
                                json: try release(d, tag: "v1.0.7", zipURL: "https://example.com/JellyfishAI-1.0.7.zip"))
        #expect(rc == 1)
        #expect(out.contains("見つかりません"))
        let (rc2, _) = try run(["--check", "--app", app.path], json: try release(d, tag: "v1.0.7;rm"))
        #expect(rc2 == 1)
    }

    @Test func refusesOtherApps() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let app = try fakeApp(d, version: "1.0.6", id: "com.example.other")
        let (rc, out) = try run(["--check", "--app", app.path], json: try release(d, tag: "v1.0.7"))
        #expect(rc == 1)
        #expect(out.contains("Jellyfish AI ではありません"))
    }

    @Test func asksBeforeReplacing() throws {
        // --yes も端末も無ければ、入れ替えに進まない
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let app = try fakeApp(d, version: "1.0.6")
        let (rc, out) = try run(["--app", app.path], json: try release(d, tag: "v1.0.7"))
        #expect(rc == 1)
        #expect(out.contains("--yes"))
        #expect(!out.contains("ダウンロードしています"))
    }

    @Test func terminalCommandPrefersTheSourceCheckout() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let data = d.appendingPathComponent("data"), src = d.appendingPathComponent("src dir")
        let app = try fakeApp(d, version: "1.0.6")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        // アプリの中の update.sh
        let bundled = app.appendingPathComponent("Contents/Resources/update.sh")
        try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/bash\n".write(to: bundled, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundled.path)
        #expect(AppUpdater.terminalCommand(dataDir: data, bundle: app) == "'\(bundled.path)' --yes --app '\(app.path)'")
        // ソースから入れていれば git pull → install.sh
        try FileManager.default.createDirectory(at: src.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        let gitConfig = src.appendingPathComponent(".git/config")
        // 取り込み元が別のリポジトリなら使わない
        try "[remote \"origin\"]\n\turl = https://github.com/someone/else.git\n".write(to: gitConfig, atomically: true, encoding: .utf8)
        for d in [src, src.appendingPathComponent("scripts")] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path) }
        let s = src.appendingPathComponent("scripts/update.sh")
        try "#!/bin/bash\n".write(to: s, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.path)
        try (src.path + "\n").write(to: data.appendingPathComponent("source-checkout"), atomically: true, encoding: .utf8)
        #expect(AppUpdater.terminalCommand(dataDir: data, bundle: app)?.contains("--source") == false)
        try "[remote \"origin\"]\n\turl = https://github.com/\(AppInfo.repo).git\n".write(to: gitConfig, atomically: true, encoding: .utf8)
        #expect(AppUpdater.terminalCommand(dataDir: data, bundle: app) == "cd '\(src.path)' && scripts/update.sh --source --yes")
        // ほかの人も書き換えられるスクリプトなら使わない
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: s.path)
        #expect(AppUpdater.terminalCommand(dataDir: data, bundle: app)?.contains("--source") == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.path)
        // 覚えた場所が git の checkout でなければ使わない（.git がただのファイルでも使わない）
        try FileManager.default.removeItem(at: src.appendingPathComponent(".git"))
        try "gitdir: /tmp/x".write(to: src.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        #expect(AppUpdater.terminalCommand(dataDir: data, bundle: app)?.contains("--source") == false)
        #expect(AppUpdater.terminalCommand(dataDir: data, bundle: d.appendingPathComponent("none.app")) == nil)
    }
}

// 「🔐 権限」：まとめて許可・取り消し（tccutil と open は記録するだけの偽物に差し替える）
@Suite struct PermissionsTests {
    func runScript(_ args: [String]) throws -> (Int32, String, String) {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("jf-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let log = d.appendingPathComponent("calls.txt")
        for name in ["tccutil", "open"] {
            let f = d.appendingPathComponent(name)
            try "#!/bin/bash\necho \"\(name) $*\" >> '\(log.path)'\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [UpdateScriptTests.root.appendingPathComponent("scripts/permissions.sh").path] + args
        var env = ProcessInfo.processInfo.environment
        env["JELLYFISH_BUNDLE_ID"] = "ai.jellyfish.desktop.test"
        env["JELLYFISH_TCCUTIL"] = d.appendingPathComponent("tccutil").path
        env["JELLYFISH_OPEN"] = d.appendingPathComponent("open").path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self), (try? String(contentsOf: log, encoding: .utf8)) ?? "")
    }

    @Test func grantResetsOnlyThisAppsStaleEntries() throws {
        let (rc, out, calls) = try runScript(["grant", "Accessibility", "ScreenCapture"])
        #expect(rc == 0)
        #expect(calls == "tccutil reset Accessibility ai.jellyfish.desktop.test\ntccutil reset ScreenCapture ai.jellyfish.desktop.test\nopen -g jellyfish://permissions?done=grant\n")
        #expect(out.contains("tccutil reset Accessibility ai.jellyfish.desktop.test"))
        // 何も付けなければ、扱うサービスすべて
        let (_, _, all) = try runScript(["grant"])
        #expect(all.components(separatedBy: "tccutil reset ").count - 1 == 7)
        #expect(!all.contains("reset All"))
    }

    @Test func revokeResetsEverythingForThisAppOnly() throws {
        let (rc, _, calls) = try runScript(["revoke"])
        #expect(rc == 0)
        #expect(calls == "tccutil reset All ai.jellyfish.desktop.test\nopen -g jellyfish://permissions?done=revoke\n")
    }

    @Test func refusesUnknownServices() throws {
        let (rc, _, calls) = try runScript(["grant", "Accessibility", "All;rm"])
        #expect(rc == 2)
        #expect(calls.isEmpty)
        let (rc2, _, _) = try runScript(["delete"])
        #expect(rc2 == 2)
    }

    @Test func resetsOnlyWhatIsNotWorking() {
        let s: [AppPermission: Bool?] = [.accessibility: false, .screenRecording: true, .fullDiskAccess: false, .automation: nil]
        #expect(AppPermission.servicesToReset(s) == ["Accessibility", "SystemPolicyAllFiles", "SystemPolicyDesktopFolder",
                                                     "SystemPolicyDocumentsFolder", "SystemPolicyDownloadsFolder"])
        #expect(AppPermission.servicesToReset([.accessibility: true, .screenRecording: true, .fullDiskAccess: true, .automation: nil]).isEmpty)
    }

    @Test func commandIsQuotedAndFiltered() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("jf-permapp-\(UUID().uuidString)/Jelly fish.app")
        let s = d.appendingPathComponent("Contents/Resources/permissions.sh")
        try FileManager.default.createDirectory(at: s.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d.deletingLastPathComponent()) }
        try "#!/bin/bash\n".write(to: s, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.path)
        #expect(AppPermission.command("grant", services: ["Accessibility", "x; rm -rf ~"], bundle: d) == "'\(s.path)' grant Accessibility")
        #expect(AppPermission.command("revoke", bundle: d) == "'\(s.path)' revoke")
        #expect(AppPermission.command("revoke", bundle: d.deletingLastPathComponent().appendingPathComponent("none.app")) == nil)
    }

    @Test func fullDiskAccessProbeOnlyOpensTheFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("jf-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(!AppPermission.hasFullDiskAccess(home: home))
        let f = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: f)
        #expect(AppPermission.hasFullDiskAccess(home: home))
    }

    @Test func settingsLinksPointAtPrivacyPanes() {
        for p in AppPermission.allCases {
            #expect(p.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_"))
        }
    }
}

@Suite struct ScriptHygieneTests {
    /// bash は「$VAR」のすぐ後ろの全角文字を変数名の一部として読む（set -u だと落ちる）。${VAR} と書く
    @Test func variablesBeforeFullWidthTextAreBraced() throws {
        let dir = UpdateScriptTests.root.appendingPathComponent("scripts")
        let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "sh" }
        #expect(!files.isEmpty)
        let re = try NSRegularExpression(pattern: #"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]"#)
        for f in files {
            let s = try String(contentsOf: f, encoding: .utf8)
            let hits = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { (s as NSString).substring(with: $0.range) }
            #expect(hits.isEmpty, "\(f.lastPathComponent): \(hits)")
        }
    }
}

@Suite struct ReviewFixTests {
    @Test func symlinkedThumbnailsMustPointAtImages() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("jf-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        let script = d.appendingPathComponent("run.command"), png = d.appendingPathComponent("real.png")
        try "#!/bin/zsh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        try Data([0x89, 0x50]).write(to: png)
        let fake = d.appendingPathComponent("report.png"), good = d.appendingPathComponent("chart.png")
        try FileManager.default.createSymbolicLink(at: fake, withDestinationURL: script)
        try FileManager.default.createSymbolicLink(at: good, withDestinationURL: png)
        // 「report.png」という名前でもスクリプトを指していれば、表示も開くこともしない
        #expect(ChatMedia.resolvedFile(fake.path) == nil)
        #expect(!ChatMedia.fileOK(fake.path))
        #expect(ChatMedia.refs(in: fake.path).isEmpty)
        // 画像を指すリンクは、行き先の画像として扱う
        #expect(ChatMedia.resolvedFile(good.path)?.lastPathComponent == "real.png")
        #expect(ChatMedia.refs(in: good.path).first?.url.lastPathComponent == "real.png")
        #expect(ChatMedia.resolvedFile(d.path) == nil)
    }

    @Test func typedTextStopsAtTheAttachmentSections() {
        let p = "見て https://example.com" + AgentChatController.attachMarker + "\n- /tmp/a.png" + ScreenContext.marker + "\n- /tmp/s.png"
        #expect(AgentChatController.typedText(p) == "見て https://example.com")
        #expect(AgentChatController.typedText("  ただの指示  ") == "ただの指示")
    }
}
