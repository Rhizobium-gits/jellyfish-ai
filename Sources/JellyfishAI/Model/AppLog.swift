import Foundation

/// ~/Library/Application Support/JellyfishAI/app.log への簡易ログ。
/// 指示の本文や画面の内容は書かない（状態・件数・エラーだけ）。2MB を超えたら app.1.log に入れ替える
enum AppLog {
    private static let url: URL = AppPaths.dataDir.appendingPathComponent("app.log")
    private static let fmt: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let lock = NSLock()
    /// 前に大きさを確かめてから書いたバイト数（起動したまま何週間も動いても、際限なく大きくならないように）
    private static var sinceCheck = Int.max

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        if sinceCheck > 100_000 { sinceCheck = 0; LogRotation.rotate(url, maxBytes: 2_000_000) }
        sinceCheck += data.count
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}

enum LogRotation {
    /// maxBytes を超えていたら foo.log → foo.1.log（前の .1 は消す）
    static func rotate(_ url: URL, maxBytes: Int) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue, size > maxBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(url.pathExtension)
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: url, to: old)
    }
}

/// 起動時の片付け：エージェントに渡した画面の画像は 7 日で消す（会話の中身は Claude Code のセッションに残る）
enum DataJanitor {
    static func cleanUp(dataDir: URL, olderThan days: Double = 7) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-days * 86_400)
        let agents = dataDir.appendingPathComponent("agents", isDirectory: true)
        guard let ids = try? fm.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil) else { return }
        var removed = 0
        for a in ids {
            for sub in ["attachments", "screens"] {
                let dir = a.appendingPathComponent(sub, isDirectory: true)
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
                for f in files where f.lastPathComponent.hasPrefix("screen") && ["png", "jpg"].contains(f.pathExtension.lowercased()) {
                    let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    if m < cutoff, (try? fm.removeItem(at: f)) != nil { removed += 1 }
                }
            }
        }
        if removed > 0 { AppLog.write("cleanup: removed \(removed) old screen images") }
    }

    /// もういないクラゲ（1.0.0 より前に消したものなど）のフォルダから、生イベントと画面の画像を消す。
    /// 履歴（history.json）・設定（meta.json）・文字起こしは残す。直近 minAge 秒に触ったフォルダは作りかけかもしれないので触らない
    static func cleanUpRemovedAgents(dataDir: URL, live: Set<UUID>, minAge: TimeInterval = 600) {
        let fm = FileManager.default
        let agents = dataDir.appendingPathComponent("agents", isDirectory: true)
        guard let dirs = try? fm.contentsOfDirectory(at: agents, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        var cleaned = 0
        for d in dirs {
            guard let id = UUID(uuidString: d.lastPathComponent), !live.contains(id) else { continue }
            let m = (try? d.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if Date().timeIntervalSince(m) < minAge { continue }
            var any = false
            for name in AgentRuntime.scratchNames {
                let u = d.appendingPathComponent(name)
                if fm.fileExists(atPath: u.path), (try? fm.removeItem(at: u)) != nil { any = true }
            }
            if any { cleaned += 1 }
        }
        if cleaned > 0 { AppLog.write("cleanup: removed raw events/images of \(cleaned) deleted agents") }
    }
}
