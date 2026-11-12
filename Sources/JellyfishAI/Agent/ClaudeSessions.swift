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
            // size は符号なしなので、引き算の前に比べる（96KB〜160KB のときに引き算があふれてアプリが落ちていた）
            try? h.seek(toOffset: size > 160_000 ? size - 160_000 : 0)
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
        let name = title ?? firstPrompt.map { String($0.prefix(40)) } ?? L("（無題のセッション）")
        let mod = modified ?? ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
        // セッション ID は claude の --resume に渡すので、UUID の形のものだけ（「--x.jsonl」のような名前がオプションにならないように）
        let id = file.deletingPathExtension().lastPathComponent
        guard UUID(uuidString: id) != nil else { return nil }
        return ClaudeSessionInfo(id: id, file: file, cwd: cwd, title: name, modified: mod)
    }

    /// 読んだところまでの位置と結果（セッションのファイルは追記だけなので、次回は増えた分だけ読む）
    private static var parsed: [String: (offset: UInt64, out: [SessionMessage])] = [:]
    private static let parsedLock = NSLock()

    /// 会話を読み出す（ユーザーの指示・アシスタントの返答・ツールの使用）。
    /// 実行中は何度も呼ばれ、ファイルが数十 MB になることもあるので、前回の続きから読む
    static func messages(in file: URL, limit: Int = 300) -> [SessionMessage] {
        guard let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        parsedLock.lock()
        var state = parsed[file.path]
        parsedLock.unlock()
        if let s = state, s.offset > size { state = nil }   // 短くなった（書き直された）ら最初から
        var offset = state?.offset ?? 0
        var out = state?.out ?? []
        if offset < size {
            try? h.seek(toOffset: offset)
            let data = h.readDataToEndOfFile()
            // 書きかけの最後の行は次回に回す
            if let nl = data.lastIndex(of: 0x0A) {
                append(data[data.startIndex..<nl], to: &out)
                offset += UInt64(nl - data.startIndex + 1)
                if out.count > limit * 2 { out = Array(out.suffix(limit)) }
                parsedLock.lock()
                parsed[file.path] = (offset, out)
                parsedLock.unlock()
            }
        }
        return Array(out.suffix(limit))
    }

    private static func append(_ data: Data, to out: inout [SessionMessage]) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: 0x0A) {
            guard let d = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = d["type"] as? String, type == "user" || type == "assistant",
                  (d["isSidechain"] as? Bool) != true, (d["isMeta"] as? Bool) != true,
                  // 会話の要約（モデルが書いたもの）は、ユーザーの発言として出さない
                  (d["isCompactSummary"] as? Bool) != true, (d["isVisibleInTranscriptOnly"] as? Bool) != true,
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
    }
}
