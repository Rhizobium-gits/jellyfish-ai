import AppKit
import CryptoKit

/// すべてのクラゲの生成・配置・表示・永続化を管理する。
/// Phase 2 ではここに AgentRuntime（エージェントごとのプロセス管理）がぶら下がる。
final class JellyManager {
    let store: Store
    private(set) var settings: AppSettings
    private(set) var controllers: [JellyController] = []
    /// メニューバー表示の更新など
    var onChange: (() -> Void)?

    private var pointerTimer: Timer?
    private var lastDragMods: NSEvent.ModifierFlags = []
    /// クラゲごとのエージェント（セッション・プロセス・履歴）
    private var runtimes: [UUID: AgentRuntime] = [:]
    /// クラゲを消しても実行中なら最後まで動かすためのもの
    private var detached: [AgentRuntime] = []
    /// クラゲごとのチャットウィンドウ
    private var chats: [UUID: AgentChatController] = [:]
    /// エージェント同士の分業（つながり・依頼・受け渡しの表示）
    private(set) var team: TeamCoordinator?
    /// システムの音の聞き取り（同時に 1 つ）。値は AudioTranscriber（macOS 26 以降）
    private var listener: (agent: UUID, object: AnyObject)?
    /// 直近の文字起こしファイル（エージェントごと）
    private(set) var lastTranscript: [UUID: URL] = [:]

    private var lastPointer = NSPoint(x: -1, y: -1)
    private var pointerIdleTicks = 0
    private var saveScheduled = false

    var layout: AvatarLayout { AvatarFactory.layout(settings.avatarStyle, scale: settings.jellyScale) }
    var windowSize: CGSize { layout.size }

    init(store: Store) {
        self.store = store
        self.settings = store.loadSettings()
        BillingGuard.allowAPI = settings.allowAPIBilling
    }

    // MARK: 起動

    func start() {
        var records = store.loadJellies()
        if records.isEmpty { records = [makeRecord()] }
        for r in records { _ = addController(r) }
        ensureOnScreen()
        if !settings.allHidden {
            for c in controllers where !c.record.hidden { c.show(animated: true) }
        }
        startPointerTracking()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.ensureOnScreen()
            self?.team?.refresh()
        }
        save()
        team = TeamCoordinator(manager: self, store: store)
        team?.org.onChange = { [weak self] in self?.onChange?() }
        team?.start()
        EngineAuth.shared.onChange = { [weak self] in
            self?.accountsWindow?.refresh()
            self?.onChange?()
        }
        // サムネイル・Web のプレビューができたら、開いているチャットを描き直す（続けて届いても 1 回に）
        ChatMediaCache.shared.onUpdate = { [weak self] in self?.scheduleTranscriptReload() }
        // モデルの一覧が届いたら、開いているチャットの選択肢を作り直す
        EngineModelCatalog.shared.onChange = { [weak self] in
            guard let self else { return }
            for (_, chat) in self.chats { chat.refresh() }
        }
        // 使う AI のログイン状態を先に確かめておく（最初の指示で待たないように）
        refreshEngineStatus()
    }

    static let languageChanged = Notification.Name("JellyfishLanguageChanged")

    /// メニューバーの「🧠 モデル（既定）」の名前（クラゲごとに選んでいないときに使うモデル）
    var defaultModelName: String { JellyManager.modelSettingName(settings.model) }

    static func modelSettingName(_ m: String) -> String {
        if m.isEmpty { return L("Claude Code に任せる") }
        if m == ModelRouter.auto { return L("🤖 自動") }
        return ModelRouter.displayName(m)
    }

    /// 既定のモデル（設定の model）を変える。"" = Claude Code に任せる、"auto" = 自動
    func setDefaultModel(_ m: String) {
        updateSettings { $0.model = m }
        if m == ModelRouter.auto { refreshUsageForAutoModel() }
        for (_, chat) in chats { chat.refresh() }
    }

    /// 「自動」が Fable を使ってよいか決めるのに、今週の使用量を読んでおく（1 分以内に読んでいれば何もしない。モデルは呼ばない）
    func refreshUsageForAutoModel() {
        ClaudeAccount.shared.refreshIfStale(claudeOverride: settings.claudePath)
    }

    /// 表示の言語を変える。開いているチャットは作り直す（ボタンや案内の文字を新しい言語にする）
    func setLanguage(_ lang: AppLanguage) {
        guard lang != settings.language else { return }
        settings.language = lang
        L10n.setting = lang
        store.save(settings)
        let open = chats.filter { $0.value.isVisible }.map(\.key)
        for (_, chat) in chats { chat.window.orderOut(nil); chat.window.close() }
        chats.removeAll()
        for id in open { if let c = controllers.first(where: { $0.record.id == id }) { openChat(for: c, activate: false) } }
        chatWindowVisibilityChanged()
        team?.refresh()
        onChange?()
        NotificationCenter.default.post(name: JellyManager.languageChanged, object: nil)
        AppLog.write("language: \(lang.rawValue) -> \(L10n.current.rawValue)")
    }

    private func makeRecord() -> JellyRecord {
        let ci = JellyManager.lowestFree(Set(controllers.map { $0.record.colorIndex }), from: 0)
        // 番号も色と同じく、今いるクラゲで空いている一番小さいものを使う（消した番号は使い回すので増え続けない）
        let n = JellyManager.lowestFree(Set(controllers.map { $0.record.number }), from: 1)
        return JellyRecord(id: UUID(), number: n, colorIndex: ci, origin: nil,
                           hidden: false, state: .idle, createdAt: Date())
    }

    static func lowestFree(_ used: Set<Int>, from start: Int) -> Int {
        var n = start
        while used.contains(n) { n += 1 }
        return n
    }

    /// 番号を 1 から詰め直すときの対応（今の番号の小さい順に 1, 2, 3…）。変わらないものは含めない
    static func compactNumbers(_ numbers: [Int]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (i, n) in numbers.sorted().enumerated() where n != i + 1 { map[n] = i + 1 }
        return map
    }

    /// 番号が 1, 2, 3… と詰まっているか（メニューの「番号を 1 から振り直す」を出すかどうか）
    var numbersAreCompact: Bool { JellyManager.compactNumbers(controllers.map(\.record.number)).isEmpty }

    /// 番号を 1 から振り直す（今の番号の小さい順）。名前を付けたクラゲは表示名が変わらない
    func renumber() {
        let map = JellyManager.compactNumbers(controllers.map(\.record.number))
        guard !map.isEmpty else { return }
        for c in controllers {
            guard let n = map[c.record.number] else { continue }
            c.update { $0.number = n }
            c.panel.title = c.record.title
            chats[c.record.id]?.refresh()
        }
        team?.refresh()
        save()
        onChange?()
        AppLog.write("renumber: \(map.count) agents")
    }

    private func addController(_ r: JellyRecord) -> JellyController {
        let avatar = AvatarFactory.make(settings.avatarStyle, record: r, scale: settings.jellyScale,
                                        maxFPS: settings.maxFPS, calmFPS: settings.calmFPS)
        let c = JellyController(record: r, avatar: avatar, manager: self)
        controllers.append(c)
        attachRuntime(to: c)
        if r.origin == nil {
            c.moveTo(freeSlotOrigin(excluding: c), persist: true)
        } else {
            c.panel.setFrameOrigin(r.origin!)
        }
        return c
    }

    // MARK: 生成・削除

    /// 新しいクラゲ（エージェント）を生成する。既存のクラゲには一切触れない。
    @discardableResult
    func spawn(openChat open: Bool = true, activate: Bool = true) -> JellyController {
        if settings.allHidden { setAllHidden(false) }
        let c = addController(makeRecord())
        c.show(animated: true)
        save()
        onChange?()
        // 生成したらすぐ指示を打ち込めるように（activate: false は外からの URL。入力先は奪わない）
        if open { DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak c] in
            guard let self, let c, self.controllers.contains(where: { $0 === c }) else { return }
            self.openChat(for: c, quickCapture: true, activate: activate)
        } }
        return c
    }

    // MARK: エージェント

    /// クラゲのエンジン（nil = 既定の「使う AI」）のバックエンド。CLI が見つからない・使えない版なら nil
    func backend(for e: AgentEngine?) -> AgentBackend? {
        switch e ?? settings.engine {
        case .claude:
            return backend()
        case .codex:
            guard let i = CLILocator.find(.codex, override: settings.codexPath), i.missing == nil else { return nil }
            return CodexBackend(install: i, model: settings.codexModel.isEmpty ? nil : settings.codexModel)
        case .gemini:
            guard let i = CLILocator.find(.gemini, override: settings.geminiPath), i.missing == nil else { return nil }
            return GeminiBackend(install: i, model: settings.geminiModel.isEmpty ? nil : settings.geminiModel)
        }
    }

    func cliPath(_ e: AgentEngine) -> String? {
        switch e {
        case .claude: return settings.claudePath
        case .codex: return settings.codexPath
        case .gemini: return settings.geminiPath
        }
    }

    var cliPaths: [AgentEngine: String] { [.claude: settings.claudePath, .codex: settings.codexPath, .gemini: settings.geminiPath] }

    /// 実行の前の確認：サブスクリプション（アカウント）でログインしているときだけ動かす。
    /// API キー（従量課金）でログインしているときは、ユーザーがメニューで許可していなければ動かさない（勝手に課金しない。Claude も同じ）
    func preflight(_ b: AgentBackend) -> String? {
        let e = b.engine
        var s = EngineAuth.shared.status(e, claudePath: settings.claudePath, cliPath: cliPath(e))
        // 止める前に、いま確かめ直す（ターミナルでログインした直後でも、覚えていた古い状態で止めない）
        if !s.usable { s = EngineAuth.shared.status(e, claudePath: settings.claudePath, cliPath: cliPath(e), maxAge: 0) }
        return JellyManager.preflightMessage(e, s, allowAPI: settings.allowAPIBilling)
    }

    /// 動かさない理由（テストあり）。nil なら動かしてよい
    static func preflightMessage(_ e: AgentEngine, _ s: EngineStatus, allowAPI: Bool) -> String? {
        switch s.login {
        case .subscription:
            return nil
        case .paidAPI(let how):
            return allowAPI ? nil : L("%@ は %@（従量課金）でログインしているので使いません（勝手に課金しないため）。%@ でログインし直すか、メニューバーのクラゲ › 🔑 アカウントと AI で「API キー（従量課金）での利用を許可」をオンにしてください", e.displayName, how, e.accountKind)
        case .loggedOut:
            return L("%@ にログインしていません。メニューバーのクラゲ › 🔑 アカウントと AI から、%@ でログインしてください", e.displayName, e.accountKind)
        case .notInstalled:
            return L("%@ が入っていません。メニューバーのクラゲ › 🔑 アカウントと AI に、入れ方があります", e.cliTitle)
        case .unsupported(let m):
            return L("この版の %@ では使えません（%@ がありません）。%@ を新しくしてください", e.cliTitle, m, e.cliTitle)
        case .unknown:
            // 確かめられなかったとき（CLI の一時的な不調など）は止めない。API キーの環境変数は渡していないので、勝手に従量課金にはならない
            return nil
        }
    }

    /// Codex・Gemini のモデルの一覧を、古ければ裏で読み直す（モデルは呼ばない）
    func refreshModels(_ e: AgentEngine, force: Bool = false) {
        guard e != .claude else { return }
        let path = cliPath(e)
        EngineModelCatalog.shared.refresh(e, cli: { CLILocator.find(e, override: path)?.url }, force: force)
    }

    /// ChatGPT・Gemini の既定のモデル（"" = CLI の既定）
    func setDefaultModel(_ m: String, for e: AgentEngine) {
        switch e {
        case .claude: setDefaultModel(m)
        case .codex: updateSettings { $0.codexModel = m }
        case .gemini: updateSettings { $0.geminiModel = m }
        }
        for (_, chat) in chats { chat.refresh() }
    }

    func defaultModelID(_ e: AgentEngine) -> String {
        switch e {
        case .claude: return settings.model
        case .codex: return settings.codexModel
        case .gemini: return settings.geminiModel
        }
    }

    /// その AI の既定のモデルの名前（チャット・メニューの表示用）
    func defaultModelLabel(_ e: AgentEngine) -> String {
        if e == .claude { return defaultModelName }
        let id = defaultModelID(e)
        if id.isEmpty { return L("%@ の設定", e.cliTitle) }
        return EngineModelCatalog.shared.model(e, id: id)?.name ?? id
    }

    func reloadOpenChats() {
        for (_, chat) in chats where chat.isVisible { chat.reloadTranscript() }
    }

    private var transcriptReload: DispatchWorkItem?
    private func scheduleTranscriptReload() {
        transcriptReload?.cancel()
        let w = DispatchWorkItem { [weak self] in
            for (_, chat) in self?.chats ?? [:] where chat.isVisible { chat.reloadTranscript() }
        }
        transcriptReload = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    /// 使う AI（既定）を変える
    func setDefaultEngine(_ e: AgentEngine) {
        updateSettings { $0.engine = e }
        for (_, chat) in chats { chat.refresh() }
        AppLog.write("engine default: \(e.rawValue)")
    }

    /// API キー（従量課金）での利用の許可。オンにするときは本人に確かめる
    func setAllowAPIBilling(_ on: Bool) {
        if on {
            let a = NSAlert()
            a.messageText = L("API キー（従量課金）での利用を許可しますか？")
            a.informativeText = L("オンにすると、API キーでログインしている AI もエージェントとして動き、シェルの設定にある API キー（ANTHROPIC_API_KEY・OPENAI_API_KEY・GEMINI_API_KEY など）も CLI に渡します。使った分だけ、それぞれの API の料金がかかります。ふだんはオフのまま、サブスクリプション（Claude・ChatGPT・Google のアカウント）でログインして使ってください。")
            a.alertStyle = .warning
            a.addButton(withTitle: L("許可する"))
            a.addButton(withTitle: L("キャンセル"))
            NSApp.activate(ignoringOtherApps: true)
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        updateSettings { $0.allowAPIBilling = on }
        BillingGuard.allowAPI = on
        refreshEngineStatus()
        accountsWindow?.refresh()
        AppLog.write("allowAPIBilling: \(on)")
    }

    /// ログイン状態を裏で確かめ直す
    func refreshEngineStatus(_ engines: [AgentEngine] = AgentEngine.allCases, relocate: Bool = false) {
        EngineAuth.shared.refresh(engines, claudePath: settings.claudePath, cliPaths: cliPaths, relocate: relocate)
    }

    /// AI ごと・モデルごとの使用量（端末内）
    lazy var usage = UsageLedger(url: store.dir.appendingPathComponent("usage.json"))

    /// 使用量を数えるときのアカウント（メールは保存しない。Claude はメールの短いハッシュ、ほかはサービス名）
    func usageAccount(_ e: AgentEngine) -> String {
        switch e {
        case .claude:
            // メニューのアカウント欄、なければ起動時に確かめたログインの状態（「メール · プラン」）から
            let email = ClaudeAccount.shared.snapshot?.account?.email
                ?? EngineAuth.shared.cached(.claude)?.account?.components(separatedBy: " · ").first { $0.contains("@") }
            guard let email else { return "claude" }
            return "claude#" + JellyManager.shortHash(email)
        case .codex: return "ChatGPT"
        case .gemini: return "Google"
        }
    }

    static func shortHash(_ s: String) -> String {
        SHA256.hash(data: Data(s.lowercased().utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    /// 使用量の表に出すアカウントの名前（いまログインしている Claude のアカウントならメール）
    func usageAccountLabel(_ stored: String, engine: AgentEngine) -> String {
        let email = ClaudeAccount.shared.snapshot?.account?.email
            ?? EngineAuth.shared.cached(.claude)?.account?.components(separatedBy: " · ").first { $0.contains("@") }
        if engine == .claude, stored.hasPrefix("claude#"), let email, stored == "claude#" + JellyManager.shortHash(email) {
            return email
        }
        if stored.hasPrefix("claude#") { return L("別のアカウント（%@）", String(stored.dropFirst("claude#".count))) }
        if stored == "-" || stored == "claude" { return "" }
        return stored
    }

    /// 「アカウントと AI」の画面（初めての起動のときにも出す）
    private var accountsWindow: AccountsWindowController?

    func showAccounts() {
        if accountsWindow == nil {
            let w = AccountsWindowController(manager: self)
            accountsWindow = w
            EngineAuth.shared.onChange = { [weak self] in
                self?.accountsWindow?.refresh()
                self?.onChange?()
            }
        }
        refreshEngineStatus(relocate: true)
        accountsWindow?.show()
    }

    /// その AI の公式のログインをターミナルで開く（Jellyfish はパスワード・トークン・API キーを扱わない）。
    /// 入っていなければ、許可を求めてから入れて、続けてログインする
    func openLogin(_ e: AgentEngine, folder: URL? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let cli: URL?
            switch e {
            case .claude: cli = ClaudeLocator.best(override: self.settings.claudePath)?.url
            case .codex: cli = CLILocator.find(.codex, override: self.settings.codexPath, maxAge: 0)?.url
            case .gemini: cli = CLILocator.find(.gemini, override: self.settings.geminiPath, maxAge: 0)?.url
            }
            DispatchQueue.main.async {
                guard let cli else { self.offerInstall(e); return }
                if !EngineLogin.open(e, cli: cli, folder: folder, allowAPI: self.settings.allowAPIBilling) { NSSound.beep() }
                AppLog.write("login opened: \(e.rawValue)\(folder == nil ? "" : " (folder)")")
            }
        }
    }

    /// CLI を入れるかを聞く。許可されたら、そのコマンドをターミナルで実行し、続けてログインを始める
    func offerInstall(_ e: AgentEngine) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let npm = e == .claude ? nil : EngineInstall.findTool("npm")
            let prefix = npm.flatMap { EngineInstall.npmPrefix($0) }
            let brew = e == .claude ? nil : EngineInstall.findTool("brew")
            let plan = EngineInstall.plan(e, npm: npm, npmWritable: prefix?.writable ?? false, brew: brew)
            DispatchQueue.main.async { self.askInstall(e, plan: plan, npmPrefix: prefix?.path) }
        }
    }

    private func askInstall(_ e: AgentEngine, plan: EngineInstall.Plan?, npmPrefix: String?) {
        let a = NSAlert()
        a.icon = NSApp.applicationIconImage
        guard let plan else {
            a.messageText = L("%@ が入っていません", e.cliTitle)
            a.informativeText = (e == .codex
                ? L("ChatGPT のデスクトップアプリを入れて ChatGPT にログインすると、その中の Codex CLI をそのまま使えます。") + "\n\n" : "")
                + L("npm（Node.js）も Homebrew も見つからないため、ここからは入れられません。公式の案内に従って入れてから、もう一度ログインしてください。")
            a.addButton(withTitle: L("公式の案内を開く"))
            a.addButton(withTitle: L("閉じる"))
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(e.setupURL) }
            return
        }
        let whereNote: String
        switch plan.tool {
        case .official: whereNote = L("Anthropic の公式インストーラで、あなたのホームの ~/.local/bin に入れます。")
        case .npm: whereNote = L("npm の公式パッケージを、npm のグローバル（%@）に入れます。", npmPrefix ?? "npm prefix -g")
        case .brew: whereNote = L("Homebrew の公式パッケージとして入れます。")
        }
        a.messageText = L("%@ を入れてログインしますか？", e.cliTitle)
        a.informativeText = L("%@ が入っていません。許可すると、ターミナルで次のコマンドを実行して入れ、続けてログインを始めます。あとはブラウザでログインするだけです。", e.cliTitle)
            + "\n\n" + plan.command + "\n\n" + whereNote + "\n"
            + L("管理者のパスワード（sudo）は使いません。Jellyfish はパスワード・API キーを扱いません。")
        a.addButton(withTitle: L("入れてログイン"))
        a.addButton(withTitle: L("公式の案内を開く"))
        a.addButton(withTitle: L("キャンセル"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            guard EngineInstall.open(plan, allowAPI: settings.allowAPIBilling) else { NSSound.beep(); return }
            let via: String
            switch plan.tool { case .official: via = "official"; case .npm: via = "npm"; case .brew: via = "brew" }
            AppLog.write("install opened: \(e.rawValue) via \(via)")
            watchInstall(e)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(e.setupURL)
        default: break
        }
    }

    /// 入れている間、入ったか・ログインできたかを見に行く（15 分まで）
    private var installWatch: [AgentEngine: Timer] = [:]
    private func watchInstall(_ e: AgentEngine) {
        installWatch[e]?.invalidate()
        let start = Date()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if EngineAuth.shared.cached(e)?.usable == true || Date().timeIntervalSince(start) > 900 {
                t.invalidate()
                self.installWatch[e] = nil
                return
            }
            self.refreshEngineStatus([e], relocate: true)
        }
        RunLoop.main.add(t, forMode: .common)
        installWatch[e] = t
    }

    func backend() -> AgentBackend? {
        guard let install = ClaudeLocator.best(override: settings.claudePath) else { return nil }
        let b = ClaudeCodeBackend(install: install, permissionMode: settings.permissionMode,
                                  model: settings.model.isEmpty ? nil : settings.model)
        if ClaudeCodeBackend.refusedSetting(settings.permissionMode, install: install), loggedRefusedMode != settings.permissionMode {
            loggedRefusedMode = settings.permissionMode
            AppLog.write("permissionMode \(settings.permissionMode.prefix(40)) refused; using \(b.permissionMode)")
        }
        return b
    }
    private var loggedRefusedMode: String?

    /// 画面表示用（待たない。起動直後は「確認中」）
    private var peekBackend: ClaudeCodeBackend? {
        guard case .found(let install) = ClaudeLocator.status(override: settings.claudePath) else { return nil }
        return ClaudeCodeBackend(install: install, permissionMode: settings.permissionMode,
                                 model: settings.model.isEmpty ? nil : settings.model)
    }

    var policyDescription: String {
        if let b = peekBackend { return b.policyDescription }
        if case .detecting = ClaudeLocator.status(override: settings.claudePath) { return L("Claude Code を確認中…") }
        return L("claude が見つかりません")
    }

    /// 実際に付ける --permission-mode（その版に auto が無ければ acceptEdits に落ちる）
    var effectivePermissionMode: String { peekBackend?.permissionMode ?? settings.permissionMode }

    /// settings.json の permissionMode を使わずに置き換えているとき、その値（bypassPermissions など）
    var refusedPermissionMode: String? {
        guard case .found(let install) = ClaudeLocator.status(override: settings.claudePath),
              ClaudeCodeBackend.refusedSetting(settings.permissionMode, install: install) else { return nil }
        return settings.permissionMode
    }

    var claudePathDescription: String {
        switch ClaudeLocator.status(override: settings.claudePath) {
        case .found(let i): return "\(i.versionString)  \(i.url.path)"
        case .detecting: return L("確認中…")
        case .notFound: return L("未検出（Claude Code をインストールしてください）")
        }
    }

    /// 起動直後に claude の検出（バージョン・オプション確認）を済ませておく
    func prefetchBackend() {
        let override = settings.claudePath
        DispatchQueue.global(qos: .utility).async { _ = ClaudeLocator.best(override: override) }
    }

    func runtime(for c: JellyController) -> AgentRuntime? { runtimes[c.record.id] }

    private func attachRuntime(to c: JellyController) {
        let rt = runtimes[c.record.id] ?? AgentRuntime(agentID: c.record.id, baseDir: store.dir,
                                                       backendProvider: { [weak self] e in self?.backend(for: e) })
        runtimes[c.record.id] = rt
        rt.preflight = { [weak self] b in self?.preflight(b) }
        let rid = c.record.id
        rt.extraDirs = { [weak self] in self?.team?.handoffDirs(for: rid) ?? [] }
        rt.onUsage = { [weak self] e, m, i, o, cached in
            guard let self else { return }
            self.usage.add(engine: e, model: m, account: self.usageAccount(e), input: i, output: o, cached: cached)
        }
        rt.defaultEngine = { [weak self] in self?.settings.engine ?? .claude }
        rt.onState = { [weak self, weak c] s in
            c?.setState(s)
            self?.onChange?()
        }
        rt.onUpdate = { [weak self, weak c] in
            guard let self, let c else { return }
            self.chats[c.record.id]?.refresh()
        }
        let id = c.record.id
        rt.mcpPolicy = { [weak self] text, cwd, loadedInSession in
            let servers = ExternalMCP.serverNames(cwd: cwd)
            let mode = self?.settings.externalMCP ?? .auto
            switch mode {
            case .always:
                return .init(load: true, servers: servers, note: nil)
            case .never:
                return .init(load: false, servers: servers, note: ExternalMCP.notLoadedNote(servers, canLoad: false))
            case .auto:
                // 仲間からの依頼の文に名前が書いてあっても読み込まない（依頼文は Web ページなどに誘導された仲間が書いたかもしれない）。
                // 依頼元がユーザーの指示で外部ツールを読み込んで動いているときだけ、同じように読み込む
                if let from = self?.team?.requester(ofRunning: id) {
                    let fromRT = self?.controllers.first { $0.record.id == from }.flatMap { self?.runtime(for: $0) }
                    let fromLoaded = fromRT.map { $0.isRunning && !$0.externalLoaded.isEmpty } ?? false
                    if loadedInSession || fromLoaded { return .init(load: true, servers: servers, note: nil) }
                    return .init(load: false, servers: servers, note: ExternalMCP.notLoadedForRequestNote(servers))
                }
                let named = ExternalMCP.mentioned(in: text, servers: servers)
                if loadedInSession || !named.isEmpty { return .init(load: true, servers: servers, note: nil) }
                return .init(load: false, servers: servers, note: ExternalMCP.notLoadedNote(servers, canLoad: true))
            }
        }
        rt.teamConfig = { [weak self, weak c, weak rt] in
            guard let self, let c, let rt else { return nil }
            return self.team?.runConfig(for: c, runtime: rt)
        }
        rt.onTurnEnded = { [weak self] turn in self?.team?.turnEnded(agent: id, turn: turn) }
        // 前回の終了時に動いていた場合など、記録と状態がずれていたら記録側に合わせる
        if !rt.isRunning, let last = rt.lastTurn, c.record.state != last.state,
           !(c.record.state == .idle && last.state == .completed) {
            c.setState(last.state)
        } else if !rt.isRunning && (c.record.state == .thinking || c.record.state == .working) {
            c.setState(.idle)
        }
    }

    /// チャットウィンドウを開く。quickCapture（⌘L で作った直後）は、最初の指示を送ったら閉じて元の作業に戻す
    func openChat(for c: JellyController, quickCapture: Bool = false, activate: Bool = true) {
        guard let rt = runtimes[c.record.id] else { return }
        let chat: AgentChatController
        if let existing = chats[c.record.id] {
            chat = existing
            // ⌘L の小さな入力欄のまま開き直したときは、会話が読める普段の大きさに広げる
            if !existing.isVisible, !rt.turns.isEmpty || rt.sessionStarted,
               existing.window.frame.height < settings.chatHeight - 1 {
                existing.resizeKeepingTop(NSSize(width: settings.chatWidth, height: settings.chatHeight))
            }
        } else {
            let fresh = rt.turns.isEmpty && !rt.sessionStarted
            let size = fresh ? NSSize(width: settings.chatWidth, height: max(300, settings.chatHeight * 0.6))
                             : NSSize(width: settings.chatWidth, height: settings.chatHeight)
            chat = AgentChatController(jelly: c, runtime: rt, size: size)
            chat.manager = self
            chats[c.record.id] = chat
        }
        chat.closeAfterFirstSubmit = quickCapture
        chat.show(near: c, activate: activate)
    }

    /// デモ録画・自動テスト用：チャットの入力欄に 1 文字ずつ打ち込んで送信する（jellyfish://type）
    func typePrompt(_ text: String, into c: JellyController, cps: Double, quick: Bool = false) {
        if chats[c.record.id]?.isVisible != true { openChat(for: c, quickCapture: quick) }
        chats[c.record.id]?.typeAndSubmit(text, cps: cps)
    }

    var claudeExecutable: URL? { ClaudeLocator.best(override: settings.claudePath)?.url }
    var supportsEffort: Bool {
        if case .found(let i) = ClaudeLocator.status(override: settings.claudePath) { return i.supportsEffort }
        return false
    }

    func rememberChatSize(_ size: NSSize) {
        guard size.width >= 380, size.height >= 240 else { return }
        settings.chatWidth = Double(size.width)
        settings.chatHeight = Double(size.height)
        scheduleSave()
    }

    /// チャットウィンドウが 1 つでも出て（またはしまわれて）いる間は普通のアプリとして Dock・⌘Tab に出す
    func chatWindowVisibilityChanged() {
        let any = chats.values.contains { $0.isVisible }
        let want: NSApplication.ActivationPolicy = any ? .regular : .accessory
        if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
    }

    /// 過去の Claude Code セッション（プロジェクト）をクラゲで呼び出す
    func resumeSession(_ info: ClaudeSessionInfo) {
        if let c = controllers.first(where: { runtimes[$0.record.id]?.sessionID == info.id }) {
            if c.record.hidden || settings.allHidden { setHidden(c, false); if settings.allHidden { setAllHidden(false) } }
            openChat(for: c)
            return
        }
        if settings.allHidden { setAllHidden(false) }
        let c = addController(makeRecord())
        runtimes[c.record.id]?.bind(to: info)
        c.setState(.completed)
        c.show(animated: true)
        save()
        onChange?()
        openChat(for: c)
    }

    // MARK: 聞き取り（システムの音 → 文字起こし）

    func isListening(_ c: JellyController) -> Bool { listener?.agent == c.record.id }

    /// 聞き取り中の表示（経過時間と最後の文）
    func listeningStatus(_ c: JellyController) -> String? {
        guard #available(macOS 26.0, *), listener?.agent == c.record.id, let t = listener?.object as? AudioTranscriber else { return nil }
        let s = Int(Date().timeIntervalSince(t.startedAt))
        let last = t.partial.isEmpty ? (t.lines.last.map { String($0.dropFirst(8)) } ?? "") : t.partial
        return L("🎧 聞き取り中 %@", String(format: "%d:%02d", s / 60, s % 60)) + (last.isEmpty ? "" : " — " + String(last.suffix(40)))
    }

    /// 聞き取りの開始・停止。止めたら文字起こしをチャットの添付にする（「議事録にして」「英訳して」などと続けて頼める）
    func toggleListening(_ c: JellyController) {
        guard #available(macOS 26.0, *) else {
            alert(L("聞き取りには macOS 26 以降が必要です"), "")
            return
        }
        if let cur = listener, let t = cur.object as? AudioTranscriber {
            listener = nil
            let agent = cur.agent
            Task { @MainActor in
                await t.stop()
                self.lastTranscript[agent] = t.fileURL
                if let ctl = self.controllers.first(where: { $0.record.id == agent }) {
                    self.openChat(for: ctl)
                    self.chats[agent]?.addAttachments([t.fileURL])
                    self.chats[agent]?.setInputHint(L("文字起こしを添付しました。例:「議事録にまとめて」「英語に翻訳して」「要点と ToDo を出して」"))
                }
                self.onChange?()
            }
            if agent == c.record.id { return }
        }
        guard let rt = runtimes[c.record.id] else { return }
        let t = AudioTranscriber(dir: rt.dir.appendingPathComponent("transcripts", isDirectory: true))
        listener = (c.record.id, t)
        let id = c.record.id
        t.onUpdate = { [weak self] in self?.chats[id]?.refresh() }
        chats[id]?.refresh()
        Task { @MainActor in
            do {
                try await t.start()
                self.lastTranscript[id] = t.fileURL
            } catch {
                if self.listener?.agent == id { self.listener = nil }
                self.alert(L("聞き取りを始められませんでした"), error.localizedDescription)
            }
            self.chats[id]?.refresh()
            self.onChange?()
        }
    }

    /// 文字起こしの中身（エージェントの read_transcript 用）
    func transcriptText(for id: UUID, sinceLine: Int) -> (path: String, lines: [String], live: Bool)? {
        guard let url = lastTranscript[id], let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = s.split(separator: "\n").map(String.init).filter { $0.hasPrefix("[") }
        return (url.path, Array(lines.dropFirst(max(0, sinceLine))), listener?.agent == id)
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// 「過去のセッション」の一覧から外す / 戻す（Claude Code のセッションファイルには触れない）
    func setArchived(_ sessionID: String, _ on: Bool) {
        updateSettings { s in
            s.archivedSessions.removeAll { $0 == sessionID }
            if on { s.archivedSessions.append(sessionID) }
        }
    }

    /// ファイルをクラゲに落としたとき：チャットを開いて添付に加える
    func attachFiles(_ urls: [URL], to c: JellyController) {
        openChat(for: c)
        chats[c.record.id]?.addAttachments(urls)
    }

    /// そのセッションを使っているクラゲの番号（メニュー表示用）
    func agentNumber(forSession id: String) -> Int? {
        controllers.first { runtimes[$0.record.id]?.sessionID == id }?.record.number
    }

    /// 長押しで消す。実行中なら、勝手にキャンセルせず確認する。
    func requestRemove(_ c: JellyController) {
        guard let rt = runtimes[c.record.id], rt.isRunning else {
            remove(c)
            return
        }
        let a = NSAlert()
        a.messageText = L("%@ はまだ作業中です", c.record.title)
        a.informativeText = L("クラゲを消しても、作業はバックグラウンドで最後まで続けられます。結果は履歴（ログ）に残ります。")
        a.addButton(withTitle: L("作業は続けて、クラゲだけ消す"))
        a.addButton(withTitle: L("作業をキャンセルして消す"))
        a.addButton(withTitle: L("やめる"))
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            rt.onState = nil
            rt.onUpdate = nil
            detached.append(rt)
            rt.onState = { [weak self, weak rt] s in
                if s.isTerminal || s == .error { self?.detached.removeAll { $0 === rt } }
            }
            remove(c)
        case .alertSecondButtonReturn:
            rt.cancel()
            remove(c)
        default:
            c.avatar.pressCancelled()
        }
    }

    /// クラゲを削除する。
    /// Phase 2: 実行中タスクがある場合はキャンセルするか継続するかを確認し、勝手にキャンセルしない。
    func remove(_ c: JellyController) {
        team?.removeAgent(c.record.id)
        if let chat = chats.removeValue(forKey: c.record.id) {
            chat.window.orderOut(nil)
            chat.window.close()
            chatWindowVisibilityChanged()
        }
        if let rt = runtimes.removeValue(forKey: c.record.id) {
            if rt.isRunning {
                // 実行中のまま参照を手放すと claude が止められなくなるので、終わるまで持っておく（終了時にも止める）
                if !detached.contains(where: { $0 === rt }) {
                    rt.onUpdate = nil
                    detached.append(rt)
                    rt.onState = { [weak self, weak rt] s in
                        if s.isTerminal || s == .error { self?.detached.removeAll { $0 === rt } }
                    }
                }
            } else {
                rt.onState = nil
                rt.onUpdate = nil
                rt.deleteScratchFiles()
            }
        }
        controllers.removeAll { $0 === c }
        c.despawn {}
        team?.refresh()
        save()
        onChange?()
    }

    // MARK: 名前

    /// 他のクラゲと重ならない名前（重なれば「名前 2」「名前 3」…）
    func uniqueName(_ base: String, excluding me: JellyController? = nil) -> String {
        let used = Set(controllers.filter { $0 !== me }.map { $0.record.title.lowercased() })
        if !used.contains(base.lowercased()) { return base }
        var i = 2
        while used.contains("\(base) \(i)".lowercased()) { i += 1 }
        return "\(base) \(i)"
    }

    /// 名前を変える。空なら「Agent N」に戻す。問題があればその理由を返す
    @discardableResult
    func rename(_ c: JellyController, to raw: String) -> String? {
        let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.count > 24 { return L("名前は 24 文字までです") }
        if !n.isEmpty, let other = controllers.first(where: { $0 !== c && $0.record.title.lowercased() == n.lowercased() }) {
            return L("「%@」は %@ のクラゲが使っています", n, other.record.color.name)
        }
        c.update { $0.name = n.isEmpty ? nil : n }
        c.panel.title = c.record.title
        chats[c.record.id]?.refresh()
        team?.refresh()
        onChange?()
        return nil
    }

    func promptRename(_ c: JellyController) {
        let a = NSAlert()
        a.messageText = L("%@（%@）の名前", c.record.title, c.record.color.name)
        a.informativeText = L("エージェント同士はこの名前で呼び合います。空にすると「Agent %ld」に戻ります。", c.record.number)
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.stringValue = c.record.name ?? ""
        f.placeholderString = "Agent \(c.record.number)"
        a.accessoryView = f
        a.addButton(withTitle: L("変更"))
        a.addButton(withTitle: L("キャンセル"))
        a.window.initialFirstResponder = f
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if let err = rename(c, to: f.stringValue) {
            let e = NSAlert()
            e.messageText = L("名前を変えられませんでした")
            e.informativeText = err
            e.runModal()
        }
    }

    // MARK: チーム

    /// エージェントが create_teammate で仲間を作る：呼んだクラゲの隣に出し、作業フォルダ・モデル・強さを引き継ぐ
    func spawnTeammate(near parent: JellyController, name: String, orgSpawned: Bool = false, engine: AgentEngine? = nil) -> JellyController? {
        guard controllers.count < TeamCoordinator.maxAgents else { return nil }
        if settings.allHidden { setAllHidden(false) }
        if parent.record.hidden { setHidden(parent, false) }
        var r = makeRecord()
        r.name = name
        if orgSpawned { r.orgSpawned = true }
        r.parentID = parent.record.id
        r.depth = (parent.record.depth ?? 0) + 1
        r.origin = adjacentOrigin(near: parent)
        let c = addController(r)
        if let prt = runtimes[parent.record.id], let rt = runtimes[c.record.id] {
            // 仲間は、指定がなければ作った側と同じ AI で動く（AI ごとの得意なことで分担するときは engine を指定）
            rt.changeEngine(engine ?? prt.effectiveEngine)
            rt.changeFolder(prt.cwd)
            // モデル・強さは AI ごとに名前が違うので、同じ AI のときだけ受け継ぐ（Claude の「max」を Codex に渡さない）
            if rt.effectiveEngine == prt.effectiveEngine {
                rt.model = prt.model
                rt.effort = prt.effort
            }
        }
        c.show(animated: true)
        save()
        onChange?()
        return c
    }

    /// 隣（体 1 つ分）の空いている場所。左 → 斜め → 上下の順に探す
    private func adjacentOrigin(near p: JellyController) -> NSPoint {
        let L = layout
        let size = L.size
        let o = p.panel.frame.origin
        // 線と受け渡しの光が見えるよう、体 1.5 個ぶん離して置く
        let sx = L.stepX * 1.5, sy = L.stepY * 1.35
        let offsets: [(CGFloat, CGFloat)] = [(-sx, 0), (-sx * 0.6, -sy), (-sx * 0.6, sy), (0, -sy), (0, sy),
                                             (-sx * 1.6, -sy), (-sx * 1.6, sy), (-2 * sx, 0), (sx * 0.5, -sy), (sx * 0.5, sy)]
        let vf = (p.panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let others = controllers.filter { $0 !== p && !$0.record.hidden }.map { $0.panel.frame.origin } + [o]
        for (dx, dy) in offsets {
            let c = NSPoint(x: o.x + dx, y: o.y + dy)
            let core = NSRect(origin: c, size: size).insetBy(dx: size.width * 0.2, dy: size.height * 0.2)
            guard vf.contains(core) else { continue }
            if others.contains(where: { hypot($0.x - c.x, $0.y - c.y) < size.width * 0.7 }) { continue }
            return c
        }
        return freeSlotOrigin(excluding: nil)
    }

    func jellyDragBegan(_ c: JellyController, origin: NSPoint) { team?.jellyDragBegan(c, origin: origin) }
    func jellyDragged(_ c: JellyController, mods: NSEvent.ModifierFlags) { team?.jellyDragged(c, mods: mods) }
    func jellyDropped(_ c: JellyController, mods: NSEvent.ModifierFlags) { team?.jellyDropped(c, mods: mods) }

    /// つながりが変わった：開いているチャットの「チーム」表示を更新
    func teamChanged() {
        for chat in chats.values where chat.isVisible { chat.refresh() }
    }

    /// デモ録画用：ドラッグと同じ経路で動かして、最後に置く（隣ならつながる）。mods で ⇧ / ⌥ を押した扱いにできる
    func demoDrag(_ c: JellyController, by d: CGVector, duration: Double = 0.8, mods: NSEvent.ModifierFlags = []) {
        let start = c.panel.frame.origin
        let steps = 24
        c.avatar.dragBegan()
        team?.jellyDragBegan(c, origin: start)
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * Double(i) / Double(steps)) { [weak self, weak c] in
                guard let self, let c else { return }
                let t = Double(i) / Double(steps)
                let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                c.panel.setFrameOrigin(NSPoint(x: start.x + d.dx * e, y: start.y + d.dy * e))
                self.jellyDragged(c, mods: mods)
                if i == steps {
                    // 置く前に一瞬止めて「離すとつながる」を見せる
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak c] in
                        guard let self, let c else { return }
                        c.avatar.dragEnded()
                        c.update { $0.origin = c.panel.frame.origin }
                        self.jellyDropped(c, mods: mods)
                    }
                }
            }
        }
    }

    func controller(number: Int) -> JellyController? { controllers.first { $0.record.number == number } }

    // MARK: 表示・非表示（非表示でもバックグラウンド処理は止めない）

    func setAllHidden(_ hidden: Bool) {
        settings.allHidden = hidden
        store.save(settings)
        for c in controllers where !c.record.hidden {
            hidden ? c.hide() : c.show(animated: true)
        }
        team?.refresh()
        onChange?()
    }

    func toggleAllHidden() { setAllHidden(!settings.allHidden) }

    func setHidden(_ c: JellyController, _ hidden: Bool) {
        c.update { $0.hidden = hidden }
        if hidden { c.hide() } else if !settings.allHidden { c.show(animated: true) }
        team?.refresh()
        onChange?()
    }

    func resetPosition(_ c: JellyController) {
        c.moveTo(freeSlotOrigin(excluding: c), persist: true)
    }

    func arrangeAll() {
        var placed: [JellyController] = []
        for c in controllers {
            let o = freeSlotOrigin(excluding: c, among: placed)
            c.moveTo(o, persist: true)
            placed.append(c)
        }
    }

    // MARK: 設定

    func setScale(_ s: Double) {
        guard abs(s - settings.jellyScale) > 0.001 else { return }
        settings.jellyScale = s
        store.save(settings)
        rebuildControllers()
    }

    func setFrameRates(max: Int, calm: Int) {
        settings.maxFPS = max
        settings.calmFPS = calm
        store.save(settings)
        controllers.forEach { $0.avatar.setFrameRates(max: max, calm: calm) }
        onChange?()
    }

    func setStyle(_ style: AvatarStyle) {
        guard style != settings.avatarStyle else { return }
        settings.avatarStyle = style
        store.save(settings)
        rebuildControllers()
    }

    func updateSettings(_ change: (inout AppSettings) -> Void) {
        change(&settings)
        store.save(settings)
        onChange?()
    }

    /// サイズ変更時：クラゲの上端中央を基準に作り直す
    private func rebuildControllers() {
        let old = controllers
        controllers = []
        for c in old {
            var r = c.record
            let f = c.panel.frame
            let size = windowSize
            r.origin = NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height)
            c.close()
            let n = addController(r)
            chats[r.id]?.attach(jelly: n)
            if !settings.allHidden && !r.hidden { n.show(animated: true) }
        }
        team?.refresh()
        save()
        onChange?()
    }

    // MARK: 配置

    /// 画面右端から縦に並べ、互い違いにずらした「群れ」の配置スロット
    private func slotOrigins(on screen: NSScreen) -> [NSPoint] {
        let vf = screen.visibleFrame
        let L = layout
        let size = L.size
        let stepY = L.stepY
        let stepX = L.stepX
        let rows = max(1, Int((vf.height * 0.90 - size.height) / stepY) + 1)
        var out: [NSPoint] = []
        for col in 0..<8 {
            for row in 0..<rows {
                let stagger: CGFloat = row % 2 == 1 ? L.stagger : 0
                let x = vf.maxX - size.width + L.edgeOverhang - CGFloat(col) * stepX + stagger
                // 最上段はアプリのツールバーと重なりやすいので、少し下から並べる
                let y = vf.maxY - size.height - vf.height * 0.10 - CGFloat(row) * stepY
                out.append(NSPoint(x: x, y: y))
            }
        }
        return out
    }

    private func freeSlotOrigin(excluding me: JellyController?, among: [JellyController]? = nil) -> NSPoint {
        guard let screen = NSScreen.screens.first else { return .zero }
        let others = (among ?? controllers).filter { $0 !== me && !$0.record.hidden }.map { $0.panel.frame.origin }
        let minDist = windowSize.width * 0.45
        let slots = slotOrigins(on: screen)
        for s in slots where !others.contains(where: { hypot($0.x - s.x, $0.y - s.y) < minDist }) {
            return s
        }
        return slots[0]
    }

    /// ディスプレイ構成が変わってクラゲが画面外に出たら、空きスロットへ戻す
    func ensureOnScreen() {
        for c in controllers {
            let f = c.panel.frame
            let core = f.insetBy(dx: f.width * 0.3, dy: f.height * 0.3)
            if !NSScreen.screens.contains(where: { $0.frame.intersects(core) }) {
                c.moveTo(freeSlotOrigin(excluding: c), persist: true)
            }
        }
    }

    // MARK: ポインタ追跡（透明部分はクリックを素通しさせる）

    private func startPointerTracking() {
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.pollPointer() }
        RunLoop.main.add(t, forMode: .common)
        pointerTimer = t
    }

    private func pollPointer() {
        // ドラッグ中に ⇧ / ⌥ を押した・離したら、マウスが止まっていても表示を切り替える
        if let d = controllers.first(where: { $0.isBeingDragged }) {
            let mods = NSEvent.modifierFlags.intersection([.shift, .option])
            if mods != lastDragMods { lastDragMods = mods; team?.jellyDragged(d, mods: mods) }
        } else {
            lastDragMods = []
        }
        let p = NSEvent.mouseLocation
        if p == lastPointer {
            // ポインタが止まっていても、クラゲ側が漂って位置が変わるので時々は再判定する
            pointerIdleTicks += 1
            if pointerIdleTicks < 10 { return }
        }
        pointerIdleTicks = 0
        lastPointer = p
        var hovered: JellyController?
        for c in controllers.reversed() {
            if c.updatePointer(p, allowed: hovered == nil) { hovered = c }
        }
        team?.pointerMoved(p, over: hovered)
    }

    // MARK: イベント

    func jellyClicked(_ c: JellyController) {
        openChat(for: c)
        onChange?()
    }

    /// アプリ終了時：実行中のエージェントを中断して記録を残す
    /// 「🔐 権限」の画面。done は permissions.sh から（grant = 古い許可を消し終わった）
    private var permissionsWindow: PermissionsWindowController?
    func showPermissions(done: String? = nil) {
        let w = permissionsWindow ?? PermissionsWindowController(manager: self)
        permissionsWindow = w
        if done == "grant" { w.grantFinished() } else { w.show() }
    }

    /// まとめて取り消す前に：すべてのクラゲの PC 操作をオフにし、操作中なら止め、🎧 の聞き取りを止める
    func disableAllPrivileges() {
        if let d = DesktopControl.shared.driver { DesktopControl.shared.release(d) }
        for rt in runtimes.values where rt.pcControl { rt.pcControl = false }
        for rt in detached where rt.pcControl { rt.pcControl = false }
        if let cur = listener, let c = controllers.first(where: { $0.record.id == cur.agent }) { toggleListening(c) }
        for (_, chat) in chats { chat.refresh() }
        AppLog.write("privileges disabled (pc control off, listening stopped)")
    }

    /// 作業中のクラゲがいるか（アップデートで入れ替える前に確かめる）
    var anyAgentBusy: Bool { runtimes.values.contains { $0.isRunning } || detached.contains { $0.isRunning } }

    func shutdown() {
        for rt in runtimes.values where rt.isRunning { rt.cancel() }
        for rt in detached where rt.isRunning { rt.cancel() }
        team?.shutdown()
        usage.flush()
        save()
    }

    func recordChanged() {
        scheduleSave()
        onChange?()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.saveScheduled = false
            self?.save()
        }
    }

    func save() {
        store.save(controllers.map { $0.record })
        store.save(settings)
    }

    // MARK: メニュー

    func agentMenuItems(for c: JellyController, includeHeader: Bool) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let r = c.record
        if includeHeader {
            let h = NSMenuItem.header("\(r.title) · \(r.color.name) · \(r.state.label)")
            h.image = MenuImages.dot(r.color, state: r.state)
            items.append(h)
            items.append(.separator())
        }
        items.append(ClosureMenuItem(L("チャットを開く…")) { [weak self, weak c] in if let c { self?.openChat(for: c) } })
        items.append(ClosureMenuItem(L("名前を変える…")) { [weak self, weak c] in if let c { self?.promptRename(c) } })
        if let team, settings.teamEnabled {
            // ドラッグしなくても、離れたクラゲとつなげる
            let others = controllers.filter { $0 !== c && !$0.record.hidden && !team.isLinked(r.id, $0.record.id) }
            if !others.isEmpty {
                let li = NSMenuItem(title: L("つなぐ"), action: nil, keyEquivalent: "")
                let lm = NSMenu()
                lm.autoenablesItems = false
                for o in others {
                    let oid = o.record.id
                    let it = ClosureMenuItem(L("🔗 %@ とつなぐ", o.record.title), image: MenuImages.dot(o.record.color, state: o.record.state)) {
                        [weak team] in team?.link(r.id, oid)
                    }
                    it.isEnabled = team.canLink(r.id, oid)
                    if !it.isEnabled { it.toolTip = L("チームは %ld 体まで", TeamCoordinator.maxTeamSize) }
                    lm.addItem(it)
                }
                li.submenu = lm
                items.append(li)
            }
        }
        if let team, !team.neighbors(r.id).isEmpty {
            let li = NSMenuItem(title: L("つながり"), action: nil, keyEquivalent: "")
            let lm = NSMenu()
            lm.autoenablesItems = false
            if let p = team.pendingDescription(for: r.id) { lm.addItem(.header(p)) }
            for n in team.neighbors(r.id) {
                lm.addItem(ClosureMenuItem(L("✂︎ %@ とのつながりを切る", team.name(n))) { [weak team] in team?.unlink(r.id, n) })
            }
            lm.addItem(.separator())
            lm.addItem(ClosureMenuItem(L("すべてのつながりを切る")) { [weak team] in team?.unlinkAll(r.id) })
            li.submenu = lm
            items.append(li)
        }
        if let rt = runtimes[c.record.id], rt.isRunning {
            items.append(ClosureMenuItem(L("作業をキャンセル")) { [weak rt] in rt?.cancel() })
        }
        let preview = NSMenuItem(title: L("状態プレビュー"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for s in AgentState.allCases {
            sub.addItem(ClosureMenuItem(L("%@（%@）", s.label, s.englishLabel), checked: r.state == s) { [weak c] in
                c?.setState(s)
            })
        }
        preview.submenu = sub
        items.append(preview)
        if r.hidden {
            items.append(ClosureMenuItem(L("表示する")) { [weak self, weak c] in if let c { self?.setHidden(c, false) } })
        } else {
            items.append(ClosureMenuItem(L("このクラゲを隠す")) { [weak self, weak c] in if let c { self?.setHidden(c, true) } })
        }
        items.append(ClosureMenuItem(L("定位置に戻す")) { [weak self, weak c] in if let c { self?.resetPosition(c) } })
        items.append(.separator())
        items.append(ClosureMenuItem(L("このクラゲを削除")) { [weak self, weak c] in if let c { self?.requestRemove(c) } })
        return items
    }

    func contextMenu(for c: JellyController) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        agentMenuItems(for: c, includeHeader: true).forEach { m.addItem($0) }
        return m
    }
}
