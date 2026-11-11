import Foundation

/// Claude Code 自身のセッション記録（~/.claude/projects/<プロジェクト>/<session-id>.jsonl）を読む。
/// クラゲの会話はここに残るので、VS Code やターミナルの `claude --resume` からも同じ会話を開ける。
struct ClaudeSessionInfo {
    let id: String
    let file: URL
    let cwd: String?
    let title: String
    let modified: Date
}

struct SessionMessage {
    enum Role { case user, assistant, tool }
    let role: Role
    let text: String
    let date: Date?
}

enum ClaudeSessions {
    static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// セッション ID からファイルを探す（プロジェクトのフォルダ名の付け方に依存しない）
    static func file(for sessionID: String) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        for d in dirs {
            let f = d.appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: f.path) { return f }
        }
        return nil
    }

    /// 全プロジェクトの最近のセッション
    static func recent(limit: Int) -> [ClaudeSessionInfo] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [(URL, Date)] = []
        for d in dirs {
            guard let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for f in items where f.pathExtension == "jsonl" {
                let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((f, m))
            }
        }
        files.sort { $0.1 > $1.1 }
        return files.prefix(limit).compactMap { info(file: $0.0, modified: $0.1) }
    }

    static func info(file: URL, modified: Date? = nil) -> ClaudeSessionInfo? {
        guard let h = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        // 先頭と末尾だけ読む（長いセッションでも軽く）
        try? h.seek(toOffset: 0)
        let head = h.readData(ofLength: 96_000)
        var tail = Data()
        if size > 96_000 {
            try? h.seek(toOffset: max(0, size - 160_000))
            tail = h.readDataToEndOfFile()
        }
        var title: String?
        var cwd: String?
        var firstPrompt: String?
        for chunk in [tail, head] {
            for line in chunk.split(separator: 0x0A) {
                guard let d = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                let t = d["type"] as? String
                if t == "ai-title", let s = d["aiTitle"] as? String { title = s }
                if t == "custom-title", let s = d["customTitle"] as? String { title = s }
                if cwd == nil, let c = d["cwd"] as? String { cwd = c }
                if firstPrompt == nil, t == "user", (d["isMeta"] as? Bool) != true,
                   let msg = d["message"] as? [String: Any], let s = msg["content"] as? String, !s.hasPrefix("<") {
                    firstPrompt = s
                }
            }
            if title != nil && cwd != nil { break }
        }
        let name = title ?? firstPrompt.map { String($0.prefix(40)) } ?? "（無題のセッション）"
        let mod = modified ?? ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
        return ClaudeSessionInfo(id: file.deletingPathExtension().lastPathComponent, file: file, cwd: cwd, title: name, modified: mod)
    }

    /// 会話を読み出す（ユーザーの指示・アシスタントの返答・ツールの使用）
    static func messages(in file: URL, limit: Int = 300) -> [SessionMessage] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out: [SessionMessage] = []
        for line in data.split(separator: 0x0A) {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = d["type"] as? String, type == "user" || type == "assistant",
                  (d["isSidechain"] as? Bool) != true, (d["isMeta"] as? Bool) != true,
                  let msg = d["message"] as? [String: Any] else { continue }
            let date = (d["timestamp"] as? String).flatMap { iso.date(from: $0) }
            if type == "user" {
                if let s = msg["content"] as? String {
                    if s.hasPrefix("<command-") || s.hasPrefix("<local-command") || s.hasPrefix("<system-reminder") { continue }
                    out.append(SessionMessage(role: .user, text: s, date: date))
                } else if let arr = msg["content"] as? [[String: Any]] {
                    let texts = arr.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
                        .filter { !$0.hasPrefix("<") }
                    if !texts.isEmpty { out.append(SessionMessage(role: .user, text: texts.joined(separator: "\n"), date: date)) }
                }
            } else if let arr = msg["content"] as? [[String: Any]] {
                for c in arr {
                    switch c["type"] as? String {
                    case "text":
                        if let t = c["text"] as? String, !t.isEmpty {
                            if let last = out.last, last.role == .assistant {
                                out[out.count - 1] = SessionMessage(role: .assistant, text: last.text + "\n\n" + t, date: last.date)
                            } else {
                                out.append(SessionMessage(role: .assistant, text: t, date: date))
                            }
                        }
                    case "tool_use":
                        let name = c["name"] as? String ?? "tool"
                        out.append(SessionMessage(role: .tool, text: StreamJSONParser.summarize(name, c["input"] as? [String: Any]), date: date))
                    default: break
                    }
                }
            }
        }
        return Array(out.suffix(limit))
    }
}
