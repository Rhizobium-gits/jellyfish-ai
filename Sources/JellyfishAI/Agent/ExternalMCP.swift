import Foundation

/// ユーザーが Claude Code に設定している MCP サーバー（Figma・Blender など）や claude.ai のコネクタを、
/// エージェントの実行ごとに読み込むかどうか。
/// - 読み込まないときは公式オプション `--strict-mcp-config` を付け、Jellyfish 自身の MCP（チーム・PC 操作）だけで動かす
///   （実測：Haiku 5.5 で 1 回あたり約 4,800 トークン減り、起動も約 0.9 秒速い）
/// - 「呼んだときだけ」なら、指示にサーバー名（例：Blender / ブレンダー）が入っていたターンから読み込み、
///   同じ会話のあいだは読み込んだままにする（続きの指示で名前を書き直さなくてよい）
enum ExternalMCPMode: String, Codable, CaseIterable {
    case auto, always, never

    var label: String {
        switch self {
        case .auto: return L("呼んだときだけ（指示に名前があれば読み込む）")
        case .always: return L("いつも読み込む")
        case .never: return L("使わない")
        }
    }
}

enum ExternalMCP {
    /// サーバー名のほかに、指示の中でこう書かれていたら呼んだとみなす
    static let aliases: [String: [String]] = [
        "blender": ["ブレンダー"],
        "figma": ["フィグマ"],
        "github": ["ギットハブ"],
        "notion": ["ノーション"],
        "slack": ["スラック"],
        "playwright": ["プレイライト"],
    ]

    private static var cache: (key: String, names: [String])?
    private static let lock = NSLock()

    /// その作業フォルダで Claude Code が読み込む MCP サーバーの名前。
    /// ~/.claude.json のユーザー設定とプロジェクト設定、作業フォルダ（とその上）の .mcp.json から、名前だけを読む
    /// （URL・コマンド・環境変数などの中身は読まない・保存しない）
    static func serverNames(cwd: URL) -> [String] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let userConfig = home.appendingPathComponent(".claude.json")
        var files = [userConfig]
        var dir = cwd.standardizedFileURL
        while true {
            files.append(dir.appendingPathComponent(".mcp.json"))
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == home.path { break }
            dir = parent
        }
        let stamp = files.map { f -> String in
            let d = (try? fm.attributesOfItem(atPath: f.path)[.modificationDate] as? Date) ?? nil
            return "\(f.path)@\(d?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "|")
        lock.lock(); defer { lock.unlock() }
        if let c = cache, c.key == stamp { return c.names }

        var names: [String] = []
        func keys(_ obj: Any?) -> [String] { ((obj as? [String: Any])?["mcpServers"] as? [String: Any]).map { Array($0.keys) } ?? [] }
        if let d = try? Data(contentsOf: userConfig), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            names += keys(j)
            let projects = j["projects"] as? [String: Any] ?? [:]
            names += keys(projects[cwd.standardizedFileURL.path])
        }
        for f in files.dropFirst() {
            if let d = try? Data(contentsOf: f), let j = try? JSONSerialization.jsonObject(with: d) { names += keys(j) }
        }
        var seen = Set<String>()
        names = names.filter { seen.insert($0.lowercased()).inserted }.sorted()
        cache = (stamp, names)
        return names
    }

    /// 指示の中で名前が出てきたサーバー
    static func mentioned(in text: String, servers: [String]) -> [String] {
        let t = text.lowercased()
        return servers.filter { s in
            let n = s.lowercased()
            if n.count >= 3, t.contains(n) { return true }
            return (aliases[n] ?? []).contains { t.contains($0) }
        }
    }

    /// 読み込まなかったときにエージェントへ伝える一言
    static func notLoadedNote(_ servers: [String], canLoad: Bool) -> String {
        let list = servers.isEmpty ? L("claude.ai のコネクタ") : L("%@ と claude.ai のコネクタ", servers.joined(separator: ", "))
        let how = canLoad
            ? L("それらが必要な作業なら、ユーザーに「%@ を使って」のように名前を入れて頼み直してもらうよう伝えてください。", servers.first ?? "Blender")
            : L("ユーザーが Jellyfish の設定で外部ツールを使わないようにしています。必要ならメニューバーの「外部ツール（MCP）」で切り替えられると伝えてください。")
        return L("（Jellyfish より）この実行ではトークンを節約するため、ユーザーが設定している外部の MCP サーバー（%@）を読み込んでいません。%@", list, how)
    }

    /// 仲間からの依頼のターンで読み込まなかったとき
    static func notLoadedForRequestNote(_ servers: [String]) -> String {
        let list = servers.isEmpty ? L("claude.ai のコネクタ") : L("%@ と claude.ai のコネクタ", servers.joined(separator: ", "))
        return L("（Jellyfish より）この実行は仲間からの依頼なので、外部の MCP サーバー（%@）は読み込んでいません（依頼文に名前があっても読み込みません）。必要なら、ユーザーが依頼元のエージェントにそのツールの名前を入れて頼むよう、依頼元に伝えてください。", list)
    }
}
