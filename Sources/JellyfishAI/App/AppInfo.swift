import AppKit

/// バージョン・リンク・「Jellyfish AI について」・アップデートの確認・初回の案内
enum AppInfo {
    static let repo = "Rhizobium-gits/jellyfish-ai"
    static let repoURL = URL(string: "https://github.com/\(repo)")!
    static let releasesURL = URL(string: "https://github.com/\(repo)/releases")!
    static let issuesURL = URL(string: "https://github.com/\(repo)/issues")!
    static let claudeSetupURL = URL(string: "https://code.claude.com/docs/en/setup")!

    /// Info.plist の CFBundleShortVersionString（scripts/build.sh が VERSION から入れる）。.app の外で動かすと "dev"
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "" }

    static func showAbout() {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .paragraphStyle: p,
                                                   .foregroundColor: NSColor.labelColor]
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .paragraphStyle: p,
                                                    .foregroundColor: NSColor.secondaryLabelColor]
        let credits = NSMutableAttributedString(string: L("デスクトップに住む Claude Code のエージェント") + "\n\n", attributes: body)
        var link = body
        link[.link] = repoURL
        credits.append(NSAttributedString(string: "github.com/\(repo)", attributes: link))
        credits.append(NSAttributedString(string: "\n\nMIT License\n" + L("非公式のアプリで、Anthropic とは関係ありません。\nClaude・Claude Code は Anthropic の商標です。"), attributes: small))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Jellyfish AI",
            .applicationVersion: version,
            .version: build,
            .credits: credits,
        ])
    }

    /// 初回起動の案内（クラゲの使い方・エージェントに与える権限・Claude Code の有無）。
    /// 起動した直後（ユーザーがアプリを開いた直後）にだけ出す
    static func showWelcome(manager: JellyManager, newJellyKey: String) {
        let a = NSAlert()
        a.messageText = L("Jellyfish AI へようこそ")
        a.icon = NSApp.applicationIconImage
        a.informativeText = L("""
        デスクトップのクラゲ 1 体が、AI のエージェント 1 体です。動かす AI は Claude（Claude Code）・ChatGPT（Codex）・Gemini から選べます。

        ・クラゲをクリック：話しかける
        ・%@：新しいクラゲ
        ・ドラッグ：移動 ／ 長押し：消す
        ・別のクラゲの近くで離す：つながってチームで分業

        エージェントは確認なしでファイルの作成・編集やコマンドの実行を行います（作業フォルダは既定でホーム。危ない操作は各 AI の安全の仕組みが止めます）。PC 操作は既定でオフです。いま与えている権限は、メニューバーのクラゲの「実行ポリシー」「PC 操作」で確認できます。

        次の画面で、使う AI にログインしてください。ログインはそれぞれの公式の画面で行い、Jellyfish は API キーを扱わず、勝手に課金しません。
        """, newJellyKey)
        a.addButton(withTitle: L("AI にログインする"))
        a.addButton(withTitle: L("使い方（README）"))
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        if r == .alertSecondButtonReturn { NSWorkspace.shared.open(repoURL) }
        // 初めての起動：Claude・ChatGPT・Gemini のログインの画面を出す
        manager.showAccounts()
        // 案内のあとにクラゲが分かるよう軽くつつく
        manager.controllers.first?.avatar.poke()
    }
}

/// "v1.2.0" と "1.10" のようなバージョン文字列の比較
enum AppVersion {
    static func parts(_ s: String) -> [Int] {
        let t = s.trimmingCharacters(in: .whitespaces)
        let core = t.hasPrefix("v") || t.hasPrefix("V") ? String(t.dropFirst()) : t
        // 1.2.0-beta.1 のような後ろの部分は無視する
        let main = core.split(separator: "-").first.map(String.init) ?? core
        return main.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        var x = parts(a), y = parts(b)
        let n = max(x.count, y.count)
        x += Array(repeating: 0, count: n - x.count)
        y += Array(repeating: 0, count: n - y.count)
        return y.lexicographicallyPrecedes(x)
    }
}

/// アップデートの確認。メニューから選んだときだけ GitHub の公開情報（最新リリースの番号）を 1 回読む。
/// 自動では確認しない（ユーザーが意図しない通信をしない）。ダウンロード・インストールはブラウザで本人が行う
enum UpdateChecker {
    static func check() {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(AppInfo.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = json?["tag_name"] as? String
            DispatchQueue.main.async {
                let a = NSAlert()
                a.icon = NSApp.applicationIconImage
                let current = AppInfo.version
                if let tag, status == 200 {
                    if AppVersion.isNewer(tag, than: current) {
                        a.messageText = L("新しいバージョン %@ があります", tag)
                        a.informativeText = L("いまのバージョンは %@ です。ダウンロードページから .dmg を入れ直してください（設定・クラゲ・会話はそのまま残ります）。", current)
                        a.addButton(withTitle: L("ダウンロードページを開く"))
                        a.addButton(withTitle: L("あとで"))
                    } else {
                        a.messageText = L("最新のバージョンです")
                        a.informativeText = "Jellyfish AI \(current)"
                        a.addButton(withTitle: "OK")
                    }
                } else {
                    a.messageText = L("アップデートを確認できませんでした")
                    a.informativeText = err?.localizedDescription ?? (status == 404 ? L("まだリリースがありません。") : L("GitHub から応答がありません（%ld）。", status))
                    a.addButton(withTitle: L("リリースのページを開く"))
                    a.addButton(withTitle: L("閉じる"))
                }
                NSApp.activate(ignoringOtherApps: true)
                let r = a.runModal()
                if a.buttons.count == 2, r == .alertFirstButtonReturn { NSWorkspace.shared.open(AppInfo.releasesURL) }
            }
        }.resume()
    }
}
