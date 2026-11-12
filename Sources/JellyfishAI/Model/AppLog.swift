import Foundation

/// ~/Library/Application Support/JellyfishAI/app.log への簡易ログ。
/// 指示の本文や画面の内容は書かない（状態・件数・エラーだけ）。2MB を超えたら app.1.log に入れ替える
enum AppLog {
    private static let url: URL = AppPaths.dataDir.appendingPathComponent("app.log")
    private static let fmt: ISO8601DateFormatter = ISO8601DateFormatter()
    private static let lock = NSLock()
    private static var checked = false

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        if !checked { checked = true; LogRotation.rotate(url, maxBytes: 2_000_000) }
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
}
