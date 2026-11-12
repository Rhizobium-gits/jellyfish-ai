import Foundation
import ServiceManagement

/// ログイン時の自動起動（macOS 13+ の正式 API、SMAppService）。
/// .app バンドルとして起動している場合のみ有効。
enum LoginItem {
    static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    static var isEnabled: Bool {
        guard isAvailable else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static var statusText: String {
        guard isAvailable else { return "バンドル外で実行中" }
        switch SMAppService.mainApp.status {
        case .enabled: return "有効"
        case .notRegistered: return "無効"
        case .requiresApproval: return "システム設定で承認が必要"
        case .notFound: return "見つかりません"
        @unknown default: return "不明"
        }
    }

    /// 成功なら nil、失敗ならエラーメッセージ
    static func set(_ on: Bool) -> String? {
        guard isAvailable else { return L("アプリを .app として起動したときだけ設定できます") }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
