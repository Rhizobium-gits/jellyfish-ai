import Foundation

/// ~/Library/Application Support/JellyfishAI/app.log への簡易ログ（Phase 2 ではエージェント別ログを別に持つ）
enum AppLog {
    private static let url: URL = AppPaths.dataDir.appendingPathComponent("app.log")
    private static let fmt: ISO8601DateFormatter = ISO8601DateFormatter()

    static func write(_ msg: String) {
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }
}
