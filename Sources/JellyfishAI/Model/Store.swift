import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// グローバルショートカットの定義（Carbon のキーコード + 修飾キー）
struct HotKeySpec: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let cmdL = HotKeySpec(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey))
    static let optCmdL = HotKeySpec(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | optionKey))
    static let ctrlOptL = HotKeySpec(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey))
    static let ctrlOptCmdL = HotKeySpec(keyCode: UInt32(kVK_ANSI_L), modifiers: UInt32(controlKey | optionKey | cmdKey))

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += HotKeySpec.keyName(keyCode)
        return s
    }

    static func keyName(_ code: UInt32) -> String {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z", kVK_Space: "Space",
        ]
        return map[Int(code)] ?? "#\(code)"
    }
}

/// アプリ設定。~/Library/Application Support/JellyfishAI/settings.json に保存。
/// 未知・欠落キーがあっても既定値で読めるよう手書きデコードにしている。
struct AppSettings: Codable {
    var newJellyHotKey: HotKeySpec = .cmdL
    /// ⌘L が他アプリに取られていた場合に使う代替
    var fallbackHotKey: HotKeySpec = .ctrlOptL
    var toggleVisibilityHotKey: HotKeySpec = .optCmdL
    /// この bundle ID のアプリが最前面にある間は ⌘L を解放する（ブラウザのアドレスバー等と共存したい場合）
    var hotKeyPassthroughApps: [String] = []
    var launchAtLogin: Bool = false
    /// クラゲの大きさ（1.0 = 標準）
    var jellyScale: Double = 1.0
    var maxFPS: Int = 60
    /// 待機中で動きが穏やかなときの fps（30 = 省電力、60 = 常になめらか）
    var calmFPS: Int = 30
    var allHidden: Bool = false
    /// 見た目（既定はドット絵の Claude キャラクター）
    var avatarStyle: AvatarStyle = .pixel
    /// チャットウィンドウの既定サイズ（最後にリサイズした大きさを覚える）
    /// 画面認識：自動判定 / 毎回 / しない、と撮る範囲
    var screenMode: ScreenMode = .auto
    var screenTarget: ScreenTarget = .activeDisplay
    var chatWidth: Double = 660
    var chatHeight: Double = 520
    /// claude 実行ファイル（空なら自動検出）
    var claudePath: String = ""
    /// Claude Code の権限モード。既定は Auto Mode（公式オプション --permission-mode auto）
    var permissionMode: String = "auto"
    /// 使うモデル（空なら Claude Code の既定）
    var model: String = ""
    /// エージェント同士の分業（線でつながった仲間に頼む・仲間を作る）を使うか
    var teamEnabled: Bool = true
    /// 「過去のセッション」から外した（アーカイブした）セッション ID。Claude Code の記録そのものは消さない
    var archivedSessions: [String] = []
    /// ユーザーが設定している MCP サーバー（Figma・Blender など）と claude.ai のコネクタを読み込むか
    var externalMCP: ExternalMCPMode = .auto
    /// 表示の言語（system = macOS に合わせる）
    var language: AppLanguage = .system
    /// 自律組織モード：ユーザーの依頼ごとに、エージェントが仕事に合ったチームを自分で組む（既定オフ。使用量が増えるため）
    var orgMode: Bool = false
    /// 自律組織の結果とユーザーの反応から、組織の選び方を学ぶ（端末内だけで計算し、どこにも送らない）
    var orgLearning: Bool = true
    /// 使う AI（クラゲごとに選んでいないときの既定）
    var engine: AgentEngine = .claude
    /// API キー（従量課金）でログインしている CLI を使ってよいか、API キーの環境変数を CLI に渡してよいか。
    /// 既定は許可しない（勝手に課金しない）。メニューで本人が確認してオンにしたときだけ
    var allowAPIBilling: Bool = false
    /// codex / gemini の実行ファイル（空なら自動で探す）
    var codexPath: String = ""
    var geminiPath: String = ""
    /// ChatGPT（Codex）・Gemini で、クラゲごとに選んでいないときのモデル（空なら CLI の既定）。値は CLI の一覧の id
    var codexModel: String = ""
    var geminiModel: String = ""
    /// チャットに Web ページのプレビュー（表紙の画像とタイトル）を出すか。出すときは、そのページを Mac の LinkPresentation が読みに行く
    var linkPreviews: Bool = true
    /// 見守りで「このアプリでは聞かない」にしたアプリ（バンドル ID）
    var watchIgnoredApps: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        newJellyHotKey = c.value(HotKeySpec.self, .newJellyHotKey, d.newJellyHotKey)
        fallbackHotKey = c.value(HotKeySpec.self, .fallbackHotKey, d.fallbackHotKey)
        toggleVisibilityHotKey = c.value(HotKeySpec.self, .toggleVisibilityHotKey, d.toggleVisibilityHotKey)
        hotKeyPassthroughApps = c.value([String].self, .hotKeyPassthroughApps, d.hotKeyPassthroughApps)
        launchAtLogin = c.value(Bool.self, .launchAtLogin, d.launchAtLogin)
        jellyScale = c.value(Double.self, .jellyScale, d.jellyScale)
        maxFPS = c.value(Int.self, .maxFPS, d.maxFPS)
        calmFPS = c.value(Int.self, .calmFPS, d.calmFPS)
        allHidden = c.value(Bool.self, .allHidden, d.allHidden)
        avatarStyle = c.value(AvatarStyle.self, .avatarStyle, d.avatarStyle)
        chatWidth = c.value(Double.self, .chatWidth, d.chatWidth)
        screenMode = c.value(ScreenMode.self, .screenMode, d.screenMode)
        screenTarget = c.value(ScreenTarget.self, .screenTarget, d.screenTarget)
        chatHeight = c.value(Double.self, .chatHeight, d.chatHeight)
        claudePath = c.value(String.self, .claudePath, d.claudePath)
        permissionMode = c.value(String.self, .permissionMode, d.permissionMode)
        model = c.value(String.self, .model, d.model)
        teamEnabled = c.value(Bool.self, .teamEnabled, d.teamEnabled)
        archivedSessions = c.value([String].self, .archivedSessions, d.archivedSessions)
        externalMCP = c.value(ExternalMCPMode.self, .externalMCP, d.externalMCP)
        language = c.value(AppLanguage.self, .language, d.language)
        orgMode = c.value(Bool.self, .orgMode, d.orgMode)
        orgLearning = c.value(Bool.self, .orgLearning, d.orgLearning)
        engine = c.value(AgentEngine.self, .engine, d.engine)
        allowAPIBilling = c.value(Bool.self, .allowAPIBilling, d.allowAPIBilling)
        codexPath = c.value(String.self, .codexPath, d.codexPath)
        geminiPath = c.value(String.self, .geminiPath, d.geminiPath)
        codexModel = c.value(String.self, .codexModel, d.codexModel)
        geminiModel = c.value(String.self, .geminiModel, d.geminiModel)
        linkPreviews = c.value(Bool.self, .linkPreviews, d.linkPreviews)
        watchIgnoredApps = c.value([String].self, .watchIgnoredApps, d.watchIgnoredApps)
    }
}

/// クラゲ1体 = エージェント1体の永続レコード。
/// Phase 2 でセッション ID・作業ディレクトリ・履歴への参照をここに追加する。
struct JellyRecord: Codable, Identifiable {
    var id: UUID
    var number: Int
    var colorIndex: Int
    /// ウィンドウ原点（スクリーン座標）。nil なら自動配置スロット
    var origin: CGPoint?
    var hidden: Bool
    var state: AgentState
    var createdAt: Date
    /// ユーザー（または仲間を作ったエージェント）が付けた名前。nil なら「Agent N」
    var name: String?
    /// エージェントが create_teammate で作った場合の作成元と、作成の深さ（ユーザーが作ったものは 0）
    var parentID: UUID?
    var depth: Int?
    /// 自律組織モードで form_team が作った仲間（仕事が変わって要らなくなったら片付ける）
    var orgSpawned: Bool?

    var color: JellyColor { Palette.color(colorIndex) }
    var title: String { name ?? "Agent \(number)" }
}

/// クラゲ同士のつながり（無向）。同じつながりの塊が 1 つのチームになる
struct JellyLink: Codable, Hashable {
    let a: UUID
    let b: UUID
    init(_ x: UUID, _ y: UUID) {
        if x.uuidString < y.uuidString { a = x; b = y } else { a = y; b = x }
    }
    func contains(_ id: UUID) -> Bool { a == id || b == id }
    func other(_ id: UUID) -> UUID { a == id ? b : a }
}

private extension KeyedDecodingContainer {
    func value<T: Decodable>(_ type: T.Type, _ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(type, forKey: key)) ?? nil) ?? fallback
    }
}

/// データの保存先。普段は ~/Library/Application Support/JellyfishAI。
/// 環境変数 JELLYFISH_DATA_DIR を付けて起動すると別の場所を使う（デモ録画・テストで普段のクラゲや会話に触れないため）
enum AppPaths {
    static let dataDir: URL = {
        let dir: URL
        let fm = FileManager.default
        // 会話の生イベント（ツールの結果）・画面の画像・文字起こしが入るので、本人だけが開けるフォルダにする
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        if let p = ProcessInfo.processInfo.environment["JELLYFISH_DATA_DIR"], !p.isEmpty {
            dir = URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
            // 指定された既存のフォルダの権限は変えない（新しく作るときだけ本人専用に）
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: ownerOnly)
        } else {
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("JellyfishAI", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: ownerOnly)
            // 1.0.2 までに作ったフォルダは 755 なので、本人専用に直す
            try? fm.setAttributes(ownerOnly, ofItemAtPath: dir.path)
        }
        return dir
    }()

    private static var lockFD: Int32 = -1

    /// このデータフォルダの排他ロック（プロセスが終われば OS が外す）
    static func acquireInstanceLock() -> Bool {
        let fd = open(dataDir.appendingPathComponent(".instance.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        lockFD = fd
        return true
    }
}

final class Store {
    let dir: URL
    private var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    private var jelliesURL: URL { dir.appendingPathComponent("jellies.json") }
    private var linksURL: URL { dir.appendingPathComponent("links.json") }

    func loadLinks() -> [JellyLink] {
        guard let data = try? Data(contentsOf: linksURL) else { return [] }
        return (try? JSONDecoder().decode([JellyLink].self, from: data)) ?? []
    }

    func save(links: [JellyLink]) { write(links, to: linksURL) }

    init() {
        dir = AppPaths.dataDir
    }

    func loadSettings() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    func save(_ settings: AppSettings) {
        write(settings, to: settingsURL)
    }

    /// クラゲの記録が保存されたことがあるか（初回起動の判定）
    var hasSavedJellies: Bool { FileManager.default.fileExists(atPath: jelliesURL.path) }

    func loadJellies() -> [JellyRecord] {
        guard let data = try? Data(contentsOf: jelliesURL) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([JellyRecord].self, from: data)) ?? []
    }

    func save(_ jellies: [JellyRecord]) {
        write(jellies, to: jelliesURL)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value) else { return }
        // 書き込み途中でクラッシュしても壊れないよう atomic に
        try? data.write(to: url, options: .atomic)
    }
}
