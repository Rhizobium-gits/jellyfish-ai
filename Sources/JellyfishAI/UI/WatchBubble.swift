import AppKit

/// 見守りのクラゲが出す吹き出し：「エラーっぽいのが出たよ、見る？」。
/// 前面に出ても入力先は奪わない（キーにならないパネル）。押せるのは「見る」「✕」「このアプリでは聞かない」だけ
final class WatchBubble: NSObject {
    private let panel: NSPanel
    private var timer: Timer?
    private var onShow: (() -> Void)?
    private var onDismiss: (() -> Void)?
    private var onIgnoreApp: (() -> Void)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    init(appName: String, snippet: String, accent: NSColor, near anchor: NSRect,
         onShow: @escaping () -> Void, onDismiss: @escaping () -> Void, onIgnoreApp: @escaping () -> Void) {
        self.onShow = onShow
        self.onDismiss = onDismiss
        self.onIgnoreApp = onIgnoreApp
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 110), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView()
        bg.material = .popover
        bg.state = .active
        // すりガラスを角丸に切る（NSVisualEffectView は maskImage で）。縁はクラゲの色
        bg.maskImage = WatchBubble.roundedMask(radius: 12)
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.masksToBounds = true
        bg.layer?.borderWidth = 1.5
        bg.layer?.borderColor = accent.withAlphaComponent(0.8).cgColor

        let title = NSTextField(labelWithString: L("エラーっぽいのが出たよ、見る？"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(labelWithString: "\(appName)：\(snippet)")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 2
        detail.cell?.wraps = true
        detail.preferredMaxLayoutWidth = 270

        let show = NSButton(title: L("見る"), target: self, action: #selector(showTapped))
        show.bezelStyle = .rounded
        show.keyEquivalent = "\r"
        let close = NSButton(title: "✕", target: self, action: #selector(dismissTapped))
        close.bezelStyle = .rounded
        close.toolTip = L("閉じる（この画像は送らずに消します）")
        let ignore = NSButton(title: L("このアプリでは聞かない"), target: self, action: #selector(ignoreTapped))
        ignore.isBordered = false
        ignore.font = .systemFont(ofSize: 10.5)
        ignore.contentTintColor = .secondaryLabelColor
        let buttons = NSStackView(views: [show, close, NSView(), ignore])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let note = NSTextField(labelWithString: L("押すと、このウィンドウの 1 枚だけを送ります"))
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor

        let stack = NSStackView(views: [title, detail, buttons, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 9, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            stack.widthAnchor.constraint(equalToConstant: 300),
        ])
        panel.contentView = bg
        bg.layoutSubtreeIfNeeded()
        let size = NSSize(width: 300, height: max(96, stack.fittingSize.height))
        panel.setContentSize(size)
        panel.setFrameOrigin(WatchBubble.origin(for: size, near: anchor))
    }

    static func roundedMask(radius r: CGFloat) -> NSImage {
        let edge = r * 2 + 1
        let img = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }

    /// クラゲの上（入らなければ左）に、画面の中に収まるように
    static func origin(for size: NSSize, near a: NSRect, screens: [NSRect] = NSScreen.screens.map(\.visibleFrame)) -> NSPoint {
        let screen = screens.first { $0.intersects(a) } ?? screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var p = NSPoint(x: a.midX - size.width / 2, y: a.maxY + 6)
        if p.y + size.height > screen.maxY { p = NSPoint(x: a.minX - size.width - 8, y: a.midY - size.height / 2) }
        p.x = min(max(p.x, screen.minX + 6), screen.maxX - size.width - 6)
        p.y = min(max(p.y, screen.minY + 6), screen.maxY - size.height - 6)
        return p
    }

    /// 出す（前面に出すが、入力先は奪わない）。90 秒で自動で閉じる（送らずに消す）
    func present() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.2; panel.animator().alphaValue = 1 }
        timer = Timer.scheduledTimer(withTimeInterval: 90, repeats: false) { [weak self] _ in self?.dismissTapped() }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        onShow = nil; onDismiss = nil; onIgnoreApp = nil
    }

    @objc private func showTapped() { let f = onShow; close(); f?() }
    @objc private func dismissTapped() { let f = onDismiss; close(); f?() }
    @objc private func ignoreTapped() { let f = onIgnoreApp; close(); f?() }
}
