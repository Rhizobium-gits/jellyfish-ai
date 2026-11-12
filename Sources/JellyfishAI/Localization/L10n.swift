import Foundation

/// 表示の言語（メニューバーのクラゲ › 🌐 言語 · Language · 语言）
enum AppLanguage: String, Codable, CaseIterable {
    /// macOS の「優先する言語」に合わせる（日本語・英語・中国語のどれでもなければ英語）
    case system
    case ja, en, zh

    /// メニューに出す名前（どの言語で表示していても読めるよう、それぞれの言語で書く）
    var nativeName: String {
        switch self {
        case .system: return L("自動（システムに合わせる）")
        case .ja: return "日本語"
        case .en: return "English"
        case .zh: return "简体中文"
        }
    }

    /// system を実際の言語にする
    func resolved(preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for p in preferred {
            let code = p.lowercased()
            if code.hasPrefix("ja") { return .ja }
            if code.hasPrefix("zh") { return .zh }
            if code.hasPrefix("en") { return .en }
        }
        return .en
    }
}

/// 画面の文字の翻訳。ソースには日本語をそのまま書き、L("…") で包む。
/// 英語・中国語は Strings+en.swift / Strings+zh.swift の表（日本語 → 訳）から引き、無ければ日本語のまま出す。
/// 差し込む値は %@（文字列）・%ld（整数 Int）で書き、L("「%@」が操作中", name) のように渡す。訳でも同じ数だけ使う
/// （順番を変えるときは %1$@ %2$@）。
enum L10n {
    private static let lock = NSLock()
    private static var _setting: AppLanguage = .system
    private static var _current: AppLanguage = AppLanguage.system.resolved()
    /// 環境変数 JELLYFISH_LANGUAGE=ja|en|zh で、設定より優先して決める（テスト・画面の確認用）
    static let override: AppLanguage? = ProcessInfo.processInfo.environment["JELLYFISH_LANGUAGE"]
        .flatMap(AppLanguage.init(rawValue:)).flatMap { $0 == .system ? nil : $0 }

    static var setting: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return _setting }
        set {
            lock.lock()
            _setting = newValue
            _current = newValue.resolved()
            lock.unlock()
        }
    }

    /// いま表示している言語（ja / en / zh）
    static var current: AppLanguage {
        if let o = override { return o }
        lock.lock(); defer { lock.unlock() }; return _current
    }

    static func table(_ lang: AppLanguage) -> [String: String] {
        switch lang {
        case .en: return en
        case .zh: return zh
        default: return [:]
        }
    }

    static func translate(_ ja: String, to lang: AppLanguage) -> String {
        guard lang != .ja, lang != .system else { return ja }
        return table(lang)[ja] ?? ja
    }
}

/// 画面に出す文字（日本語で書いたものを、いまの言語に訳す）
func L(_ ja: String) -> String { L10n.translate(ja, to: L10n.current) }

/// 値を差し込む文字（%@ / %ld）
func L(_ ja: String, _ args: CVarArg...) -> String {
    String(format: L10n.translate(ja, to: L10n.current), arguments: args)
}
