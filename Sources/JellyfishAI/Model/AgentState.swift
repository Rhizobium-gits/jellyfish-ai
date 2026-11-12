import Foundation

/// エージェントの実行状態。クラゲのアニメーションはこの値だけから決まる。
/// Phase 2 以降は AI プロセスの実イベントからのみ遷移させる（応答テキストからの推測はしない）。
enum AgentState: String, Codable, CaseIterable {
    case idle
    case thinking
    case working
    case completed
    case error
    case cancelled

    var label: String {
        switch self {
        case .idle: return L("待機")
        case .thinking: return L("思考中")
        case .working: return L("作業中")
        case .completed: return L("完了")
        case .error: return L("エラー")
        case .cancelled: return L("キャンセル済み")
        }
    }

    var englishLabel: String { rawValue.capitalized }

    /// 終了状態（クラゲが静止する状態）か
    var isTerminal: Bool { self == .completed || self == .cancelled }
}
