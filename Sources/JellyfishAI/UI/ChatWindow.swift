import AppKit

/// Enter で送信、Shift(またはOption)+Enter で改行、Esc で閉じる。
/// 日本語入力の変換中（marked text がある間）の Enter / Esc は IME に渡す。
/// チャットウィンドウの背景。どこにファイルを落としても添付になる
final class DropEffectView: NSVisualEffectView {
    var onFiles: (([URL]) -> Void)?
    static func urls(_ s: NSDraggingInfo) -> [URL] {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { DropEffectView.urls(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = DropEffectView.urls(sender)
        guard !u.isEmpty else { return false }
        onFiles?(u)
        return true
    }
}

final class PromptTextView: NSTextView {
    var onSubmit: (() -> Void)?
    /// 入力欄にファイルを落としたときはパスを文字で入れず、添付にする
    var onDropFiles: (([URL]) -> Void)?
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let u = DropEffectView.urls(sender)
        if !u.isEmpty, let cb = onDropFiles { cb(u); return true }
        return super.performDragOperation(sender)
    }
    var onEscape: (() -> Void)?
    var placeholder: String = "" { didSet { needsDisplay = true } }

    override func keyDown(with e: NSEvent) {
        if hasMarkedText() { super.keyDown(with: e); return }
        switch e.keyCode {
        case 53: onEscape?(); return
        case 36, 76:
            if e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else {
                onSubmit?()
            }
            return
        default: break
        }
        super.keyDown(with: e)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let pad = textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + pad, y: textContainerInset.height),
                                       withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// エージェント1体ぶんのチャットウィンドウ。
/// 普通のウィンドウとして 閉じる / しまう（Dock） / 拡大・フルスクリーン / 端をドラッグして自由にリサイズ ができる。
/// 会話は Claude Code 自身のセッション記録から表示するので、VS Code やターミナルで開いたときと同じ内容になる。
final class AgentChatController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    let window: NSWindow
    let runtime: AgentRuntime
    private(set) weak var jelly: JellyController?
    weak var manager: JellyManager?

    private let titleLabel = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "")
    private let dot = NSImageView()
    private let cancelButton = NSButton(title: "キャンセル", target: nil, action: nil)
    private let retryButton = NSButton(title: "再実行", target: nil, action: nil)
    private let folderButton = NSButton(title: "", target: nil, action: nil)
    private let terminalButton = NSButton(title: "Claude Code で開く", target: nil, action: nil)
    private let renameButton = NSButton(title: "名前", target: nil, action: nil)
    private let pcButton = NSButton(title: "🖱 PC 操作", target: nil, action: nil)
    private let listenButton = NSButton(title: "🎧", target: nil, action: nil)
    private var listenTimer: Timer?
    private let transcript = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    private let transcriptScroll = NSScrollView()
    private let input = PromptTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 44))
    private let inputScroll = NSScrollView()
    private let footer = NSTextField(labelWithString: "")
    private let screenPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let attachButton = NSButton(title: "📎", target: nil, action: nil)
    private let attachLabel = NSTextField(labelWithString: "")
    private let clearAttachButton = NSButton(title: "添付を外す", target: nil, action: nil)
    private var pendingAttachments: [URL] = []
    /// チャットを開く前に使っていたアプリ（画面認識でどの画面を撮るか・アプリ名に使う）
    private var contextApp: NSRunningApplication?
    private var capturing = false
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effortPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var inputHeight: NSLayoutConstraint!
    private var attachRow: NSStackView?

    /// 選べるモデル（Claude Code の --model に渡す値。エイリアスは常に最新版を指す）
    static let models: [(label: String, value: String?)] = [
        ("モデル: 既定", nil),
        ("Fable 5.2", "fable"),
        ("Opus 5.5", "opus"),
        ("Sonnet 5.5", "sonnet"),
        ("Haiku 5.5", "claude-haiku-5-5"),
    ]
    /// 考える強さ（--effort）
    static let efforts: [(label: String, value: String?)] = [
        ("強さ: 既定", nil),
        ("low（速い）", "low"),
        ("medium", "medium"),
        ("high", "high"),
        ("xhigh", "xhigh"),
        ("max（最も深く）", "max"),
    ]

    private var previousApp: NSRunningApplication?
    /// ⌘L で作ったばかりのクラゲへの最初の指示は、送信したらウィンドウを閉じて元の作業に戻す
    var closeAfterFirstSubmit = false
    private var reloadScheduled = false
    private var lastRenderedCount = -1

    init(jelly: JellyController, runtime: AgentRuntime, size: NSSize) {
        self.jelly = jelly
        self.runtime = runtime
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 240)
        window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.setFrameAutosaveName("JellyfishChat-\(jelly.record.id.uuidString)")
        build()
        refresh()
        reloadTranscript()
    }

    var isVisible: Bool { window.isVisible || window.isMiniaturized }

    // MARK: 構築

    private func build() {
        let bg = DropEffectView()
        bg.registerForDraggedTypes([.fileURL])
        bg.onFiles = { [weak self] u in self?.addAttachments(u) }
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .active
        window.contentView = bg

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.font = .systemFont(ofSize: 12)
        stateLabel.textColor = .secondaryLabelColor
        stateLabel.lineBreakMode = .byTruncatingTail
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.imageScaling = .scaleNone
        for b in [cancelButton, retryButton, folderButton, terminalButton, renameButton, pcButton, listenButton] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11.5)
            b.target = self
        }
        cancelButton.action = #selector(cancelTask)
        renameButton.action = #selector(renameAgent)
        pcButton.action = #selector(togglePC)
        listenButton.action = #selector(toggleListen)
        listenButton.setButtonType(.pushOnPushOff)
        listenButton.toolTip = "システムの音（会議・動画など）を聞き取って文字にする。止めると文字起こしを添付するので「議事録にして」「翻訳して」と頼める"
        pcButton.setButtonType(.pushOnPushOff)
        pcButton.toolTip = "このエージェントに PC 操作（画面を見る・クリック・入力）を許す。操作中は画面の縁が光り、Esc で止まる。次の指示から反映"
        renameButton.toolTip = "このエージェントの名前を変える（仲間どうしはこの名前で呼び合います）"
        retryButton.action = #selector(retryTask)
        folderButton.action = #selector(chooseFolder)
        folderButton.toolTip = "作業フォルダを変更"
        terminalButton.action = #selector(openInTerminal)
        terminalButton.toolTip = "同じセッションをターミナルの claude --resume で開く"

        let titleRow = NSStackView(views: [dot, titleLabel, NSView(), renameButton, retryButton, cancelButton])
        titleRow.orientation = .horizontal
        titleRow.spacing = 8
        let infoRow = NSStackView(views: [stateLabel])
        infoRow.orientation = .horizontal

        for (p, items) in [(modelPopup, AgentChatController.models.map(\.label)), (effortPopup, AgentChatController.efforts.map(\.label)),
                           (screenPopup, ScreenMode.allCases.map(\.label))] {
            p.addItems(withTitles: items)
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11.5)
            p.bezelStyle = .accessoryBarAction
            p.target = self
        }
        modelPopup.action = #selector(modelChanged)
        screenPopup.action = #selector(screenModeChanged)
        screenPopup.toolTip = "「この画面」などと書いたとき、送信時の画面を撮って添付する（Jellyfish のウィンドウは写りません）"
        for b in [attachButton, clearAttachButton] {
            b.bezelStyle = .accessoryBarAction
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11.5)
            b.target = self
        }
        attachButton.action = #selector(attachFiles)
        attachButton.toolTip = "画像やファイルを添付（添付があるときは画面の自動添付より優先）"
        clearAttachButton.action = #selector(clearAttachments)
        attachLabel.font = .systemFont(ofSize: 11.5)
        attachLabel.textColor = .secondaryLabelColor
        attachLabel.lineBreakMode = .byTruncatingMiddle
        effortPopup.action = #selector(effortChanged)
        modelPopup.toolTip = "このクラゲが使うモデル（次の指示から反映）"
        effortPopup.toolTip = "考える強さ（--effort。次の指示から反映）"
        let controlsRow = NSStackView(views: [modelPopup, effortPopup, screenPopup, attachButton, pcButton, listenButton, folderButton, NSView(), terminalButton])
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 6
        // 幅が足りないときはウィンドウを広げず、フォルダ名・ポップアップの文字を省略して縮める
        controlsRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        (folderButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
        folderButton.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let minFolder = folderButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
        minFolder.priority = .init(255)
        minFolder.isActive = true
        for p in [modelPopup, effortPopup, screenPopup] { p.setContentCompressionResistancePriority(.init(240), for: .horizontal) }
        terminalButton.setContentCompressionResistancePriority(.init(260), for: .horizontal)

        configureScrollable(transcript)
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.drawsBackground = false
        transcript.textContainerInset = NSSize(width: 6, height: 8)
        transcriptScroll.documentView = transcript
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.borderType = .noBorder

        configureScrollable(input)
        input.font = .systemFont(ofSize: 14.5)
        input.isRichText = false
        input.allowsUndo = true
        input.drawsBackground = false
        input.textContainerInset = NSSize(width: 8, height: 9)
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.onSubmit = { [weak self] in self?.submit() }
        input.onDropFiles = { [weak self] u in self?.addAttachments(u) }
        input.onEscape = { [weak self] in self?.closeAndReturn() }
        input.delegate = self
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.autohidesScrollers = true
        inputScroll.drawsBackground = false
        inputScroll.borderType = .noBorder
        inputScroll.wantsLayer = true
        inputScroll.layer?.cornerRadius = 12
        inputScroll.layer?.borderWidth = 1
        inputScroll.layer?.borderColor = NSColor.separatorColor.cgColor
        inputScroll.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.55).cgColor

        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        footer.lineBreakMode = .byTruncatingTail

        let attachRow = NSStackView(views: [attachLabel, clearAttachButton, NSView()])
        attachRow.orientation = .horizontal
        attachRow.spacing = 6
        self.attachRow = attachRow
        let stack = NSStackView(views: [titleRow, infoRow, transcriptScroll, attachRow, inputScroll, controlsRow, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 34, left: 16, bottom: 12, right: 16)   // 上はタイトルバー（信号ボタン）の分
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        transcriptScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        bg.addSubview(stack)

        inputHeight = inputScroll.heightAnchor.constraint(equalToConstant: 46)
        var cs: [NSLayoutConstraint] = [
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
            inputHeight,
        ]
        attachRow.isHidden = true
        for v in [titleRow, infoRow, transcriptScroll, attachRow, inputScroll, controlsRow, footer] as [NSView] {
            cs.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32))
        }
        NSLayoutConstraint.activate(cs)
    }

    private func configureScrollable(_ tv: NSTextView) {
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: tv.frame.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
    }

    // MARK: 表示

    func show(near jelly: JellyController, focusInput: Bool = true) {
        self.jelly = jelly
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front; contextApp = front }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { placeIfNeeded(near: jelly) }
        manager?.chatWindowVisibilityChanged()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if focusInput { window.makeFirstResponder(input) }
        refresh()
        reloadTranscript()
    }

    /// 保存された位置が無い（初回）なら、クラゲの左側に出す
    private func placeIfNeeded(near jelly: JellyController) {
        let key = "NSWindow Frame JellyfishChat-\(jelly.record.id.uuidString)"
        if UserDefaults.standard.string(forKey: key) != nil, window.frame.width > 0,
           NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { return }
        let jf = jelly.panel.frame
        let vf = (jelly.panel.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var f = window.frame
        f.origin.x = jf.minX - f.width + 8
        if f.minX < vf.minX + 8 { f.origin.x = jf.maxX - 8 }
        f.origin.y = jf.maxY - f.height
        f.origin.x = min(max(f.minX, vf.minX + 8), vf.maxX - f.width - 8)
        f.origin.y = min(max(f.minY, vf.minY + 8), vf.maxY - f.height - 8)
        window.setFrame(f, display: false)
    }

    func resizeKeepingTop(_ size: NSSize) {
        var f = window.frame
        f.origin.y = f.maxY - size.height
        f.size = size
        if let vf = (window.screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = min(max(f.minX, vf.minX + 8), vf.maxX - f.width - 8)
            f.origin.y = min(max(f.minY, vf.minY + 8), vf.maxY - f.height - 8)
        }
        window.setFrame(f, display: false)
    }

    func closeAndReturn() {
        window.orderOut(nil)
        manager?.chatWindowVisibilityChanged()
        previousApp?.activate()
        previousApp = nil
    }

    /// ヘッダー（状態・ボタン）を更新し、会話の再読込を予約する
    func refresh() {
        guard let jelly else { return }
        let r = jelly.record
        let sessionTitle = runtime.sessionTitle
        window.title = "\(r.title) · \(r.color.name)" + (sessionTitle.map { " — \($0)" } ?? "")
        titleLabel.stringValue = sessionTitle ?? "\(r.title) · \(r.color.name)"
        dot.image = MenuImages.dot(r.color, state: r.state)

        let running = runtime.isRunning
        var st = "\(r.title) · \(r.state.label)"
        if running, let a = runtime.activity { st += " — \(a)" }
        if capturing { st = "\(r.title) · 📷 画面を取り込んでいます…" }
        if let m = runtime.activeModel { st += "  ·  \(m)" }
        if let p = manager?.team?.pendingDescription(for: r.id) { st += "  ·  \(p)" }
        // 線でつながった仲間（この人たちに分担を頼める）
        let mates = (manager?.settings.teamEnabled ?? false) ? (manager?.team?.teammateNames(for: r.id) ?? []) : []
        if !mates.isEmpty {
            let shown = mates.prefix(3).joined(separator: "・") + (mates.count > 3 ? " ほか \(mates.count - 3) 体" : "")
            st += "  ·  👥 \(shown) とチーム"
        }
        if running, !runtime.externalLoaded.isEmpty { st += "  ·  🧩 " + runtime.externalLoaded.joined(separator: "・") }
        if let l = manager?.listeningStatus(jelly) { st = "\(r.title) · " + l }
        screenPopup.selectItem(at: ScreenMode.allCases.firstIndex(of: manager?.settings.screenMode ?? .auto) ?? 0)
        modelPopup.selectItem(at: AgentChatController.models.firstIndex { $0.value == runtime.model } ?? 0)
        effortPopup.selectItem(at: AgentChatController.efforts.firstIndex { $0.value == runtime.effort } ?? 0)
        effortPopup.isEnabled = manager?.supportsEffort ?? true
        let listening = manager?.isListening(jelly) ?? false
        listenButton.state = listening ? .on : .off
        listenButton.title = listening ? "🎧 停止" : "🎧"
        if listening, listenTimer == nil {
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(t, forMode: .common)
            listenTimer = t
        } else if !listening {
            listenTimer?.invalidate()
            listenTimer = nil
        }
        pcButton.state = runtime.pcControl ? .on : .off
        pcButton.title = runtime.pcControl ? "🖱 PC 操作: オン" : "🖱 PC 操作"
        stateLabel.stringValue = st
        cancelButton.isHidden = !running
        let last = runtime.lastTurn
        retryButton.isHidden = running || last == nil || last?.state == .completed
        terminalButton.isHidden = !runtime.sessionStarted
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        folderButton.title = "📁 " + runtime.cwd.path.replacingOccurrences(of: home, with: "~")

        input.isEditable = !running && !capturing
        let teamHint = mates.isEmpty ? "" : "（つながっている \(mates.prefix(2).joined(separator: "・"))\(mates.count > 2 ? " たち" : "") に分担させることもできます）"
        input.placeholder = running ? "実行中です。終わったら続けて指示できます"
            : (runtime.turns.isEmpty && !runtime.sessionStarted ? "\(r.title) に頼みたいことを入力…" : "この結果に続けて指示する…") + teamHint
        footer.stringValue = "⏎ 送信   ⇧⏎ 改行   esc 閉じる   ·   \(manager?.policyDescription ?? "")   ·   記録: Claude Code のセッション"
        scheduleReload()
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.reloadScheduled = false
            self?.reloadTranscript()
        }
    }

    // MARK: 会話の表示

    func reloadTranscript() {
        guard let jelly else { return }
        let accent = NSColor(srgbRed: CGFloat(jelly.record.color.flat.x), green: CGFloat(jelly.record.color.flat.y),
                             blue: CGFloat(jelly.record.color.flat.z), alpha: 1)
        let out = NSMutableAttributedString()
        let caption: (String, NSColor) -> NSAttributedString = { s, c in
            let ps = NSMutableParagraphStyle(); ps.paragraphSpacingBefore = 12
            return NSAttributedString(string: s + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                                     .foregroundColor: c, .paragraphStyle: ps])
        }
        var messages: [SessionMessage] = []
        if let f = runtime.sessionFile { messages = ClaudeSessions.messages(in: f) }
        if messages.isEmpty {
            // セッション記録がまだ無い（起動前に失敗した等）ときは自前の履歴から
            for t in runtime.turns {
                messages.append(SessionMessage(role: .user, text: t.prompt, date: t.startedAt))
                if let r = t.result, !r.isEmpty, t.state != .error { messages.append(SessionMessage(role: .assistant, text: r, date: t.endedAt)) }
            }
        }
        var lastRole: SessionMessage.Role?
        for m in messages {
            switch m.role {
            case .user:
                var text = m.text
                var notes: [String] = []
                // 仲間のエージェントからの依頼（TeamCoordinator が付けた目印）
                if text.hasPrefix(TeamCoordinator.requestMarker), let end = text.range(of: "]\n") {
                    let from = String(text[text.index(text.startIndex, offsetBy: TeamCoordinator.requestMarker.count)..<end.lowerBound])
                    text = String(text[end.upperBound...])
                    if let f = text.range(of: TeamCoordinator.requestFooter) { text = String(text[..<f.lowerBound]) }
                    out.append(caption("📨 \(from) からの依頼", accent))
                } else {
                    out.append(caption("あなた", .secondaryLabelColor))
                }
                if let r = text.range(of: ScreenContext.marker) {
                    let block = String(text[r.upperBound...])
                    text = String(text[..<r.lowerBound])
                    notes.append(block.contains(".png") ? "📷 画面を添付しました" : "📷 画面の添付に失敗しました")
                }
                if let r = text.range(of: AgentChatController.attachMarker) {
                    let names = text[r.upperBound...].split(separator: "\n").filter { $0.hasPrefix("- ") }
                        .map { ($0.dropFirst(2) as NSString).lastPathComponent }
                    text = String(text[..<r.lowerBound])
                    notes.append("📎 " + names.joined(separator: ", "))
                }
                out.append(NSAttributedString(string: text + "\n", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium),
                                                                                  .foregroundColor: NSColor.labelColor]))
                for n in notes {
                    out.append(NSAttributedString(string: n + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11.5),
                                                                                    .foregroundColor: NSColor.secondaryLabelColor]))
                }
            case .assistant:
                if lastRole != .tool || true { out.append(caption("Claude", accent)) }
                out.append(Markdown.render(m.text, size: 14))
                out.append(NSAttributedString(string: "\n"))
            case .tool:
                let ps = NSMutableParagraphStyle(); ps.paragraphSpacingBefore = 4
                out.append(NSAttributedString(string: "⚙︎ " + m.text + "\n",
                                              attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                                                           .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: ps]))
            }
            lastRole = m.role
        }
        if let last = runtime.lastTurn, last.state == .error || last.state == .cancelled, let e = last.error, !e.isEmpty {
            out.append(caption(last.state == .error ? "エラー" : "キャンセル", .systemRed))
            out.append(NSAttributedString(string: e + "\n", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                                                                           .foregroundColor: NSColor.systemRed]))
        }
        if runtime.isRunning {
            out.append(caption("Claude", accent))
            out.append(NSAttributedString(string: "… \(runtime.activity ?? "作業中")\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: accent]))
        }
        if out.length == 0 {
            out.append(NSAttributedString(string: "まだ会話はありません。下の欄に指示を入力してください。\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.tertiaryLabelColor]))
        }

        // 一番下を見ていたときだけ自動で追従する
        let clip = transcriptScroll.contentView
        let atBottom = clip.bounds.maxY >= (transcript.frame.height - 30) || lastRenderedCount < 0
        transcript.textStorage?.setAttributedString(out)
        lastRenderedCount = out.length
        if atBottom { transcript.scrollToEndOfDocument(nil) }
    }

    // MARK: 操作

    static let attachMarker = "\n\n---\n[添付ファイル]"

    private func submit() {
        guard !runtime.isRunning, !capturing else { return }
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var prompt = text
        let attach = pendingAttachments
        if !attach.isEmpty {
            prompt += AgentChatController.attachMarker + "\n" + attach.map { "- \($0.path)" }.joined(separator: "\n")
                + "\n画像やファイルは Read ツールで開いて内容を確認してください。"
        }
        input.string = ""
        relayoutInput()
        setAttachments([])

        // 画面を指す指示なら、送信時点の画面を撮って添える（明示的な添付があればそちらを優先）
        let mode = manager?.settings.screenMode ?? .auto
        let wantScreen = attach.isEmpty && (mode == .always || (mode == .auto && ScreenIntent.refersToScreen(text)))
        guard wantScreen else { send(prompt); return }

        capturing = true
        refresh()
        let app = contextApp
        let target = manager?.settings.screenTarget ?? .activeDisplay
        let dir = runtime.dir.appendingPathComponent("attachments", isDirectory: true)
        Task { @MainActor [weak self] in
            let ctx = await ScreenContext.capture(frontApp: app, target: target, into: dir)
            guard let self else { return }
            self.capturing = false
            var p = prompt + ctx.promptSuffix
            if let note = ctx.note { p += ScreenContext.marker + "\n" + note + "（画像なしで進めてください）" }
            AppLog.write("screen capture images=\(ctx.images.count) app=\(ctx.appName ?? "-") note=\(ctx.note ?? "-")")
            self.send(p)
        }
    }

    private var typingTimer: Timer?

    /// デモ録画・自動テスト用：入力欄に 1 文字ずつ打ち込み、少し間をおいて Enter と同じ送信をする
    func typeAndSubmit(_ text: String, cps rawCPS: Double) {
        let cps = rawCPS.isFinite ? min(max(rawCPS, 1), 60) : 14
        typingTimer?.invalidate()
        let chars = Array(text)
        var i = 0
        input.string = ""
        let t = Timer(timeInterval: 1 / cps, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if i < chars.count {
                self.input.string.append(chars[i])
                i += 1
                self.input.needsDisplay = true
                self.relayoutInput()
            } else if i < chars.count + Int(cps * 0.6) {
                i += 1   // 打ち終わってから送信まで少し待つ
            } else {
                t.invalidate()
                self.typingTimer = nil
                self.submit()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        typingTimer = t
    }

    private func send(_ prompt: String) {
        runtime.submit(prompt)
        refresh()
        // PC 操作のときは、エージェントが実際の画面を見て操作できるようにチャットを閉じて元のアプリに戻す
        if closeAfterFirstSubmit || runtime.pcControl {
            closeAfterFirstSubmit = false
            closeAndReturn()
        }
    }

    /// 添付に加える（同じファイルは 1 回だけ）
    func addAttachments(_ urls: [URL]) {
        var cur = pendingAttachments
        for u in urls where !cur.contains(u) { cur.append(u) }
        setAttachments(cur)
        window.makeFirstResponder(input)
    }

    private func setAttachments(_ urls: [URL]) {
        pendingAttachments = urls
        attachRow?.isHidden = urls.isEmpty
        attachLabel.stringValue = "📎 " + urls.map(\.lastPathComponent).joined(separator: ", ")
    }

    @objc private func attachFiles() {
        let op = NSOpenPanel()
        op.canChooseFiles = true
        op.canChooseDirectories = false
        op.allowsMultipleSelection = true
        op.prompt = "添付"
        op.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let self else { return }
            self.setAttachments(self.pendingAttachments + op.urls)
            self.window.makeFirstResponder(self.input)
        }
    }

    @objc private func clearAttachments() { setAttachments([]) }

    @objc private func screenModeChanged() {
        let m = ScreenMode.allCases[max(0, screenPopup.indexOfSelectedItem)]
        manager?.updateSettings { $0.screenMode = m }
        window.makeFirstResponder(input)
    }

    @objc private func modelChanged() {
        runtime.model = AgentChatController.models[max(0, modelPopup.indexOfSelectedItem)].value
        window.makeFirstResponder(input)
    }

    @objc private func effortChanged() {
        runtime.effort = AgentChatController.efforts[max(0, effortPopup.indexOfSelectedItem)].value
        window.makeFirstResponder(input)
    }

    /// クラゲを作り直したとき（見た目・大きさの変更）に付け替える
    func attach(jelly: JellyController) {
        self.jelly = jelly
        refresh()
    }

    @objc private func cancelTask() { runtime.cancel() }
    @objc private func renameAgent() { if let j = jelly { manager?.promptRename(j) } }

    @objc private func toggleListen() {
        if let j = jelly { manager?.toggleListening(j) }
        refresh()
    }

    /// 入力欄のヒントを一時的に変える
    func setInputHint(_ s: String) {
        input.placeholder = s
    }

    @objc private func togglePC() {
        let on = !runtime.pcControl
        runtime.pcControl = on
        if on && !(DesktopControl.hasAccessibility && DesktopControl.hasScreenRecording) {
            let a = NSAlert()
            a.messageText = "PC 操作には macOS の許可が必要です"
            a.informativeText = "「システム設定 › プライバシーとセキュリティ」の「アクセシビリティ」と「画面収録」で Jellyfish AI を許可してください（許可したあとアプリの再起動が必要なことがあります）。\n\n今の状態: \(DesktopControl.permissionSummary)\n\n" + DesktopControl.scopeNote
            a.addButton(withTitle: "許可の画面を開く")
            a.addButton(withTitle: "あとで")
            if a.runModal() == .alertFirstButtonReturn { DesktopControl.requestPermissions() }
        }
        refresh()
    }
    @objc private func retryTask() { runtime.retry() }

    @objc private func chooseFolder() {
        let op = NSOpenPanel()
        op.canChooseDirectories = true
        op.canChooseFiles = false
        op.allowsMultipleSelection = false
        op.directoryURL = runtime.cwd
        op.prompt = "このフォルダで作業"
        op.message = "このクラゲが作業するフォルダを選んでください（新しいセッションとして始まります）"
        op.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = op.url, let self else { return }
            self.runtime.changeFolder(url)
            self.refresh()
        }
    }

    /// 同じセッションをターミナルで開く（.command ファイル経由。オートメーション権限は不要）
    @objc private func openInTerminal() {
        guard runtime.sessionStarted, let claude = manager?.claudeExecutable else { return }
        let script = """
        #!/bin/zsh -l
        cd \(shellQuote(runtime.cwd.path)) && exec \(shellQuote(claude.path)) --resume \(shellQuote(runtime.sessionID))
        """
        let url = runtime.dir.appendingPathComponent("open-in-claude.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: 入力欄の高さ（1〜7 行で伸びる）

    func textDidChange(_ notification: Notification) { relayoutInput() }

    private func relayoutInput() {
        guard let tc = input.textContainer, let lm = input.layoutManager else { return }
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height + input.textContainerInset.height * 2 + 2
        inputHeight.constant = min(max(h, 46), 170)
    }

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        // ユーザーが端をドラッグして決めた大きさを、次に開くウィンドウの既定にする（⌘L の小さな入力欄の大きさは覚えない）
        if !window.styleMask.contains(.fullScreen) { manager?.rememberChatSize(window.frame.size) }
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.manager?.chatWindowVisibilityChanged() }
    }

    func windowDidMiniaturize(_ notification: Notification) { manager?.chatWindowVisibilityChanged() }
    func windowDidDeminiaturize(_ notification: Notification) { manager?.chatWindowVisibilityChanged() }
}

/// 返答の Markdown を読みやすく整形する（見出し・箇条書き・太字・斜体・インラインコード・リンク・コードブロック）
enum Markdown {
    static func render(_ text: String, size: CGFloat) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base = NSFont.systemFont(ofSize: size)
        let mono = NSFont.monospacedSystemFont(ofSize: size - 1.5, weight: .regular)
        let parts = text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                var code = part
                if let nl = code.firstIndex(of: "\n") { code = String(code[code.index(after: nl)...]) }
                code = code.trimmingCharacters(in: .newlines)
                let ps = NSMutableParagraphStyle()
                ps.headIndent = 10; ps.firstLineHeadIndent = 10; ps.paragraphSpacing = 4; ps.paragraphSpacingBefore = 4
                out.append(NSAttributedString(string: code + "\n", attributes: [
                    .font: mono, .foregroundColor: NSColor.labelColor,
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.18), .paragraphStyle: ps]))
                continue
            }
            let lines = part.components(separatedBy: "\n")
            for (j, rawLine) in lines.enumerated() {
                var line = rawLine
                var font = base
                let ps = NSMutableParagraphStyle()
                ps.lineSpacing = 2
                if let m = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                    let level = line[m].filter { $0 == "#" }.count
                    line.removeSubrange(m)
                    font = NSFont.systemFont(ofSize: size + CGFloat(max(0, 4 - level)), weight: .bold)
                    ps.paragraphSpacingBefore = 6
                } else if let m = line.range(of: #"^(\s*)[-*+]\s+"#, options: .regularExpression) {
                    let indent = line[m].prefix { $0 == " " }.count
                    line.replaceSubrange(m, with: String(repeating: "  ", count: indent / 2) + "• ")
                    ps.headIndent = 14 + CGFloat(indent) * 4
                }
                out.append(inline(line, font: font, mono: mono, paragraph: ps))
                if j < lines.count - 1 { out.append(NSAttributedString(string: "\n", attributes: [.font: base])) }
            }
        }
        return out
    }

    private static func inline(_ s: String, font: NSFont, mono: NSFont, paragraph: NSParagraphStyle) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        guard let parsed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: s, attributes: attrs)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var a = attrs
            if let intent = run.inlinePresentationIntent {
                var f = font
                if intent.contains(.stronglyEmphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                if intent.contains(.code) {
                    f = mono
                    a[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.25)
                }
                a[.font] = f
            }
            // 返答の中のリンクは Web とメールだけ押せるようにする（jellyfish:// や他のアプリのスキームは開かない）
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") { a[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: a))
        }
        return out
    }
}
