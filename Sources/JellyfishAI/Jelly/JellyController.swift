import AppKit

/// クラゲ1体分の透明ウィンドウ。
/// - nonactivatingPanel: クリックしてもアプリが前面化せず、作業中のアプリのフォーカスを奪わない
/// - canJoinAllSpaces / fullScreenAuxiliary: どのデスクトップ・フルスクリーンアプリの上にも出る
final class JellyPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        ignoresMouseEvents = true
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// マウス操作を受けて JellyController へ渡す透明なビュー
final class JellyHostView: NSView {
    weak var controller: JellyController?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // ファイルをクラゲに落とすと、そのエージェントへの添付になる
    private func fileURLs(_ s: NSDraggingInfo) -> [URL] {
        (s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(sender).isEmpty else { return [] }
        controller?.avatar.poke()
        return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty, let c = controller else { return false }
        c.manager?.attachFiles(urls, to: c)
        return true
    }

    override func mouseDown(with event: NSEvent) { controller?.mouseDown(event) }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { controller?.rightMouseDown(event) }
}

/// クラゲ1体（= エージェント1体）の窓と操作を受け持つ。見た目は Avatar に委ねる。
final class JellyController: NSObject {
    private(set) var record: JellyRecord
    let panel: JellyPanel
    private let host: JellyHostView
    let avatar: Avatar
    weak var manager: JellyManager?

    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint = .zero
    private var dragged = false
    private var pressTimer: Timer?
    private var longPressFired = false
    static let longPressDuration = 0.65
    private(set) var isDragging = false
    private(set) var isVisible = false

    init(record: JellyRecord, avatar: Avatar, manager: JellyManager) {
        self.record = record
        self.avatar = avatar
        self.manager = manager
        panel = JellyPanel(size: avatar.size)
        host = JellyHostView(frame: NSRect(origin: .zero, size: avatar.size))
        super.init()
        host.controller = self
        host.registerForDraggedTypes([.fileURL])
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        avatar.view.frame = host.bounds
        avatar.view.autoresizingMask = [.width, .height]
        host.addSubview(avatar.view)
        panel.contentView = host
        panel.title = record.title
    }

    func update(_ change: (inout JellyRecord) -> Void) {
        change(&record)
        manager?.recordChanged()
    }

    // MARK: 表示

    func show(animated: Bool) {
        if let o = record.origin { panel.setFrameOrigin(o) }
        panel.orderFrontRegardless()
        isVisible = true
        avatar.setActive(true)
        if animated { avatar.spawn() }
    }

    func hide() {
        panel.orderOut(nil)
        isVisible = false
        avatar.setActive(false)
        panel.ignoresMouseEvents = true
    }

    var isAnimating: Bool { avatar.isAnimating }

    func setState(_ s: AgentState) {
        guard s != record.state || avatar.state != s else { return }
        update { $0.state = s }
        avatar.setState(s)
    }

    func moveTo(_ origin: NSPoint, persist: Bool) {
        panel.setFrameOrigin(origin)
        if persist { update { $0.origin = origin } }
        (avatar as? RealisticAvatar)?.windowMoved()
        manager?.team?.refresh()
    }

    func despawn(_ done: @escaping () -> Void) {
        guard isVisible else { close(); done(); return }
        avatar.despawn { [weak self] in
            self?.close()
            done()
        }
    }

    func close() {
        avatar.teardown()
        panel.orderOut(nil)
        panel.close()
        isVisible = false
    }

    // MARK: ポインタ（クリック透過の切り替え）

    /// スクリーン座標のポインタ位置を受け取り、クラゲの上ならマウスを受け付ける。
    /// クラゲ以外の透明部分はクリックが下のアプリへ素通りする。
    @discardableResult
    func updatePointer(_ p: NSPoint, allowed: Bool) -> Bool {
        guard isVisible else { return false }
        if isDragging { return true }
        let f = panel.frame
        let local = CGPoint(x: p.x - f.minX, y: p.y - f.minY)
        let inside = allowed && f.contains(p) && avatar.hitTest(local)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        avatar.pointerMoved(inside: inside, local: local)
        return inside
    }

    /// 体の中心（グローバル座標）
    var anchorPoint: CGPoint {
        CGPoint(x: panel.frame.minX + avatar.anchor.x, y: panel.frame.minY + avatar.anchor.y)
    }
    /// 名前ラベルの上端中央（グローバル座標）
    var labelPoint: CGPoint {
        CGPoint(x: panel.frame.minX + avatar.anchor.x, y: panel.frame.minY + avatar.labelY)
    }

    /// デモ録画用：長押しと同じ見た目・動作（jellyfish://press）
    func simulateLongPress() {
        avatar.pressBegan(duration: JellyController.longPressDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + JellyController.longPressDuration) { [weak self] in
            guard let self else { return }
            self.manager?.requestRemove(self)
        }
    }

    // MARK: マウス

    func mouseDown(_ e: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = panel.frame.origin
        dragged = false
        isDragging = true
        longPressFired = false
        // 長押しで消す
        pressTimer?.invalidate()
        let t = Timer(timeInterval: JellyController.longPressDuration, repeats: false) { [weak self] _ in
            guard let self, !self.dragged else { return }
            self.longPressFired = true
            self.isDragging = false
            self.manager?.requestRemove(self)
        }
        RunLoop.main.add(t, forMode: .common)
        pressTimer = t
        avatar.pressBegan(duration: JellyController.longPressDuration)
    }

    func mouseDragged(_ e: NSEvent) {
        guard let start = dragStartMouse else { return }
        let m = NSEvent.mouseLocation
        let dx = m.x - start.x, dy = m.y - start.y
        if !dragged && hypot(dx, dy) < 3 { return }
        if longPressFired { return }
        if !dragged {
            pressTimer?.invalidate()
            avatar.pressCancelled()
            avatar.dragBegan()
        }
        dragged = true
        panel.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
        (avatar as? RealisticAvatar)?.windowMoved()
        manager?.jellyDragged(self)
    }

    func mouseUp(_ e: NSEvent) {
        pressTimer?.invalidate()
        pressTimer = nil
        isDragging = false
        defer { dragStartMouse = nil }
        if longPressFired { return }
        avatar.pressCancelled()
        if dragged {
            avatar.dragEnded()
            update { $0.origin = panel.frame.origin }
            manager?.jellyDropped(self)
        } else {
            avatar.poke()
            manager?.jellyClicked(self)
        }
    }

    func rightMouseDown(_ e: NSEvent) {
        guard let menu = manager?.contextMenu(for: self) else { return }
        NSMenu.popUpContextMenu(menu, with: e, for: host)
    }
}
