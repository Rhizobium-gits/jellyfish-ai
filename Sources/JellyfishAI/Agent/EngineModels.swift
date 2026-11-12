import Foundation

/// Codex・Gemini で選べるモデル。名前を推測せず、それぞれの CLI が出す一覧から作る
///   Codex：`codex debug models`（モデルのカタログを JSON で出す。visibility が list のものだけ、priority の順。考える強さは supported_reasoning_levels）
///   Gemini：`gemini models -o json`（id・displayName・description）
/// どちらもモデルは呼ばない。一覧はデータフォルダに覚えておき（1 日）、メニュー・チャットを開いたときに裏で読み直す
struct EngineModel: Codable, Equatable {
    let id: String
    let name: String
    let detail: String?
    /// 選べる考える強さ（Codex の model_reasoning_effort。Gemini は空）
    let efforts: [String]
}

enum EngineModels {
    static func parseCodex(_ data: Data) -> [EngineModel] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = o["models"] as? [[String: Any]] else { return [] }
        return models
            .filter { ($0["visibility"] as? String) == "list" }
            .sorted { (($0["priority"] as? NSNumber)?.intValue ?? 999) < (($1["priority"] as? NSNumber)?.intValue ?? 999) }
            .compactMap { m in
                guard let slug = m["slug"] as? String, !slug.isEmpty else { return nil }
                let efforts = (m["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String } ?? []
                return EngineModel(id: slug, name: (m["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? slug,
                                   detail: (m["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }, efforts: efforts)
            }
    }

    static func parseGemini(_ data: Data) -> [EngineModel] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr.compactMap { m in
            guard let id = (m["id"] as? String) ?? (m["modelId"] as? String), !id.isEmpty else { return nil }
            return EngineModel(id: id, name: (m["displayName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                               detail: (m["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }, efforts: [])
        }
    }

    /// CLI から一覧を読む（待つ。裏のスレッドから呼ぶ）
    static func fetch(_ e: AgentEngine, cli: URL) -> [EngineModel]? {
        switch e {
        case .codex:
            // 古い版に「debug models」が無ければ呼ばない（--help は指示として送られない）
            guard (CLILocator.run(cli, ["debug", "--help"], timeout: 15) ?? "").contains("models"),
                  let out = CLILocator.run(cli, ["debug", "models"], timeout: 30, mergeStderr: false) else { return nil }
            let m = parseCodex(Data(out.utf8))
            return m.isEmpty ? nil : m
        case .gemini:
            // 「models」コマンドの無い版では「gemini models」が指示（プロンプト）として送られかねないので、
            // まず --help（指示としては送られない）で、そのコマンドがあることを確かめる
            guard (CLILocator.run(cli, ["models", "--help"], timeout: 20) ?? "").contains("gemini models"),
                  let out = CLILocator.run(cli, ["models", "--output-format", "json"], timeout: 40, mergeStderr: false) else { return nil }
            // 前に警告などの行が付くことがあるので、最初の「[」から読む
            guard let i = out.firstIndex(of: "[") else { return nil }
            let m = parseGemini(Data(out[i...].utf8))
            return m.isEmpty ? nil : m
        case .claude:
            return nil
        }
    }
}

/// モデルの一覧を覚えておく（エンジンごと）
final class EngineModelCatalog {
    private var failedAt: [AgentEngine: Date] = [:]
    static let shared = EngineModelCatalog()
    private var cache: [AgentEngine: (models: [EngineModel], at: Date)] = [:]
    private var loading = Set<AgentEngine>()
    private let lock = NSLock()
    /// 読み終わったとき（メインスレッド）
    var onChange: (() -> Void)?

    private struct Stored: Codable { var models: [EngineModel]; var at: Date }
    private func file(_ e: AgentEngine) -> URL { AppPaths.dataDir.appendingPathComponent("models-\(e.rawValue).json") }

    init() {
        for e in [AgentEngine.codex, .gemini] {
            if let d = try? Data(contentsOf: file(e)), let s = try? JSONDecoder().decode(Stored.self, from: d) { cache[e] = (s.models, s.at) }
        }
    }

    /// 覚えている一覧（待たない）
    func models(_ e: AgentEngine) -> [EngineModel] { lock.lock(); defer { lock.unlock() }; return cache[e]?.models ?? [] }

    func model(_ e: AgentEngine, id: String) -> EngineModel? { models(e).first { $0.id == id } }

    /// 古ければ裏で読み直す（1 日。force なら必ず）
    func refresh(_ e: AgentEngine, cli: @escaping () -> URL?, force: Bool = false) {
        guard e != .claude else { return }
        lock.lock()
        let fresh = cache[e].map { Date().timeIntervalSince($0.at) < 86_400 } ?? false
        // 読めなかったら 1 時間は読み直さない（失敗のたびに知らせて読み直す繰り返しにならないように）
        let backoff = failedAt[e].map { Date().timeIntervalSince($0) < 3600 } ?? false
        if (fresh && !force) || (backoff && !force) || loading.contains(e) { lock.unlock(); return }
        loading.insert(e)
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let found = cli().flatMap { EngineModels.fetch(e, cli: $0) }
            self.lock.lock()
            self.loading.remove(e)
            if let found { self.cache[e] = (found, Date()); self.failedAt[e] = nil } else { self.failedAt[e] = Date() }
            self.lock.unlock()
            guard let found else { return }
            if let d = try? JSONEncoder().encode(Stored(models: found, at: Date())) { try? d.write(to: self.file(e), options: .atomic) }
            DispatchQueue.main.async { self.onChange?() }
        }
    }
}
