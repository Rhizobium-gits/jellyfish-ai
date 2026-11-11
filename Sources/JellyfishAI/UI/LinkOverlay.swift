import AppKit

extension JellyColor {
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(flat.x), green: CGFloat(flat.y), blue: CGFloat(flat.z), alpha: 1) }
}

/// クラゲ同士の線・名前ラベル・受け渡しの光を描く、画面全体の透明な重ね窓（クリックは素通し）。
/// - 線はドット絵に合わせた点線。依頼が流れている間だけ依頼元の色で流れる（それ以外は静止＝CPU を使わない）
/// - 依頼を出すと依頼元の色の四角い光が、結果が返ると依頼先の色の光が、線をたどって相手へ飛ぶ
/// - 線の近くにポインタを置くと ✂︎ が出て、クリックで切れる
final class LinkOverlay {
    struct Label { let id: UUID; let text: String; let at: CGPoint; let color: NSColor }
    /// ドラッグ中の「離すとつながる」表示：相手まで流れる点線と、相手を囲む輪
    struct Preview { let from: CGPoint; let to: CGPoint; let color: NSColor; let ok: Bool; let radius: CGFloat }
    /// 操作のヒント（at は吹き出しの上端中央）
    struct Pill { let id: String; let text: String; let at: CGPoint; let color: NSColor }
    static let warnColor = NSColor(srgbRed: 1, green: 0.42, blue: 0.38, alpha: 0.95)

    var onCut: ((JellyLink) -> Void)?

    private var windows: [OverlayWindow] = []
    private var segments: [(JellyLink, CGPoint, CGPoint)] = []
    private var flows: [JellyLink: (toward: UUID, color: NSColor)] = [:]
    /// ⌥ ドラッグで「離すと切れる」状態の線
    private var warn: Set<JellyLink> = []
    private var hasContent = false
    private var packetsInFlight = 0
    private let scissors = ScissorsPanel()
    private var scissorsLink: JellyLink?
    private var scissorsAt: CGPoint = .zero
    /// デモ用に ✂︎ を固定表示している間はポインタ追跡で消さない
    private var scissorsPinned = false

    init() {
        scissors.onClick = { [weak self] in
            guard let self, let l = self.scissorsLink else { return }
            self.hideScissors()
            self.onCut?(l)
        }
    }

    // MARK: - 描画の更新

    func update(segments: [(JellyLink, CGPoint, CGPoint)], labels: [Label], preview: Preview?,
                pills: [Pill] = [], warn: Set<JellyLink> = []) {
        self.segments = segments
        self.warn = warn
        syncWindows()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for w in windows {
            w.setLines(segments.map { l, p1, p2 in (l, w.local(p1), w.local(p2)) },
                       styler: { [weak self] l, layer in self?.style(layer, l) })
            w.setLabels(labels.map { Label(id: $0.id, text: $0.text, at: w.local($0.at), color: $0.color) })
            w.setPreview(preview.map { Preview(from: w.local($0.from), to: w.local($0.to), color: $0.color, ok: $0.ok, radius: $0.radius) })
            w.setPills(pills.map { Pill(id: $0.id, text: $0.text, at: w.local($0.at), color: $0.color) })
        }
        CATransaction.commit()
        hasContent = !segments.isEmpty || !labels.isEmpty || preview != nil || !pills.isEmpty
        updateVisibility()
        if let l = scissorsLink, !segments.contains(where: { $0.0 == l }) { hideScissors() }
    }

    private func style(_ layer: CAShapeLayer, _ l: JellyLink) {
        if l == scissorsLink || warn.contains(l) {
            layer.strokeColor = LinkOverlay.warnColor.cgColor
            layer.lineWidth = 3
            layer.removeAnimation(forKey: "flow")
        } else if let f = flows[l] {
            layer.strokeColor = f.color.withAlphaComponent(0.95).cgColor
            layer.lineWidth = 3.5
            if layer.animation(forKey: "flow") == nil {
                let a = CABasicAnimation(keyPath: "lineDashPhase")
                // 線は a → b の向きに描いている。位相を減らすと a → b へ流れる
                let forward = f.toward == l.b
                a.fromValue = forward ? 11 : 0
                a.toValue = forward ? 0 : 11
                a.duration = 0.45
                a.repeatCount = .infinity
                layer.add(a, forKey: "flow")
            }
        } else {
            layer.strokeColor = NSColor(white: 1, alpha: 0.6).cgColor
            layer.lineWidth = 3
            layer.removeAnimation(forKey: "flow")
        }
    }

    func setFlow(_ l: JellyLink, toward: UUID?, color: NSColor) {
        if let t = toward { flows[l] = (t, color) } else { flows[l] = nil }
        restyle()
    }

    private func restyle() {
        for w in windows { w.restyle { [weak self] l, layer in self?.style(layer, l) } }
    }

    // MARK: - 受け渡しの光

    /// 点の列（クラゲの中心を線の順に）に沿って、四角い光を 3 つ流す
    func sendPackets(along points: [CGPoint], color: NSColor) {
        guard points.count > 1 else { return }
        syncWindows()
        var length: CGFloat = 0
        for i in 1..<points.count { length += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y) }
        let duration = max(0.5, Double(length / 480))
        packetsInFlight += 1
        updateVisibility()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            self.packetsInFlight -= 1
            self.updateVisibility()
        }
        for w in windows where w.intersects(points) {
            let local = points.map(w.local)
            for k in 0..<3 { w.addPacket(along: local, color: color, duration: duration, delay: Double(k) * 0.11) }
        }
        CATransaction.commit()
    }

    /// つながったとき：線が相手まで伸びる
    func linkCreated(_ l: JellyLink, from p1: CGPoint, to p2: CGPoint) {
        for w in windows { w.animateDraw(l) }
        sendPackets(along: [p1, p2], color: NSColor(white: 1, alpha: 1))
    }

    /// 切ったとき：真ん中から左右に縮んで消える
    func linkCut(from p1: CGPoint, to p2: CGPoint) {
        syncWindows()
        packetsInFlight += 1
        updateVisibility()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.packetsInFlight -= 1
            self?.updateVisibility()
        }
        for w in windows where w.intersects([p1, p2]) { w.addSnap(w.local(p1), w.local(p2)) }
        CATransaction.commit()
    }

    // MARK: - ✂︎

    func pointerMoved(_ p: CGPoint) {
        if scissorsPinned { return }
        if scissors.isVisible, hypot(p.x - scissorsAt.x, p.y - scissorsAt.y) < 18 { return }
        var best: (JellyLink, CGPoint, CGFloat)?
        for (l, a, b) in segments {
            let (q, d, t) = LinkOverlay.project(p, a, b)
            let len = hypot(b.x - a.x, b.y - a.y)
            // クラゲ本体の近く（両端）は除く
            guard len > 70, t * len > 34, (1 - t) * len > 34 else { continue }
            if d < 12, d < (best?.2 ?? .infinity) { best = (l, q, d) }
        }
        guard let (l, q, _) = best else { hideScissors(); return }
        scissorsAt = q
        if scissorsLink != l { scissorsLink = l; restyle() }
        scissors.show(at: q)
    }

    func showScissors(_ l: JellyLink, at p: CGPoint) {
        scissorsAt = p
        scissorsLink = l
        scissorsPinned = true
        restyle()
        scissors.show(at: p)
    }

    func hideScissors() {
        scissorsPinned = false
        guard scissors.isVisible || scissorsLink != nil else { return }
        scissors.orderOut(nil)
        if scissorsLink != nil { scissorsLink = nil; restyle() }
    }

    static func project(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGFloat, CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = max(dx * dx + dy * dy, 0.0001)
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
        return (q, hypot(p.x - q.x, p.y - q.y), t)
    }

    // MARK: - 窓（ディスプレイごと）

    private func syncWindows() {
        let frames = NSScreen.screens.map(\.frame)
        if windows.map(\.frame) != frames {
            windows.forEach { $0.orderOut(nil) }
            windows = NSScreen.screens.map { OverlayWindow(screen: $0) }
            restyle()
        }
    }

    private func updateVisibility() {
        let show = hasContent || packetsInFlight > 0
        for w in windows {
            if show && !w.isVisible { w.orderFrontRegardless() }
            if !show && w.isVisible { w.orderOut(nil) }
        }
    }
}

/// ディスプレイ 1 枚ぶんの透明な重ね窓
private final class OverlayWindow: NSPanel {
    private let root = CALayer()
    private var lines: [JellyLink: CAShapeLayer] = [:]
    private var labels: [UUID: CALayer] = [:]
    private var pills: [String: CALayer] = [:]
    private let previewLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    private let scale: CGFloat

    init(screen: NSScreen) {
        scale = screen.backingScaleFactor
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        // 普通のウィンドウより上、クラゲ（.floating）より下
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        v.layer = root
        root.frame = v.bounds
        contentView = v
        previewLayer.fillColor = nil
        previewLayer.lineWidth = 3.5
        previewLayer.lineDashPattern = [6, 5]
        previewLayer.contentsScale = scale
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 3
        ringLayer.lineDashPattern = [5, 4]
        ringLayer.contentsScale = scale
        ringLayer.isHidden = true
        root.addSublayer(ringLayer)
        root.addSublayer(previewLayer)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: p.y - frame.minY) }

    func intersects(_ pts: [CGPoint]) -> Bool {
        guard let f = pts.first else { return false }
        var r = CGRect(origin: f, size: .zero)
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        return frame.intersects(r.insetBy(dx: -4, dy: -4))
    }

    func setLines(_ segs: [(JellyLink, CGPoint, CGPoint)], styler: (JellyLink, CAShapeLayer) -> Void) {
        let keep = Set(segs.map(\.0))
        for (l, layer) in lines where !keep.contains(l) { layer.removeFromSuperlayer(); lines[l] = nil }
        for (l, a, b) in segs {
            let layer = lines[l] ?? makeLine()
            if lines[l] == nil { lines[l] = layer; root.insertSublayer(layer, at: 0) }
            let p = CGMutablePath()
            p.move(to: a)
            p.addLine(to: b)
            layer.path = p
            styler(l, layer)
        }
    }

    func restyle(_ styler: (JellyLink, CAShapeLayer) -> Void) {
        for (l, layer) in lines { styler(l, layer) }
    }

    private func makeLine() -> CAShapeLayer {
        let s = CAShapeLayer()
        s.fillColor = nil
        s.lineWidth = 3
        s.lineCap = .butt
        s.lineDashPattern = [6, 5]
        s.shadowColor = NSColor.black.cgColor
        s.shadowOpacity = 0.35
        s.shadowRadius = 1.5
        s.shadowOffset = .zero
        s.contentsScale = scale
        return s
    }

    func animateDraw(_ l: JellyLink) {
        guard let layer = lines[l] else { return }
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = 0
        a.toValue = 1
        a.duration = 0.35
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(a, forKey: "draw")
    }

    /// 相手まで流れる点線 + 相手を囲んで脈打つ輪。動いているのはドラッグ中だけ
    func setPreview(_ pv: LinkOverlay.Preview?) {
        guard let pv else {
            if previewLayer.path != nil {
                previewLayer.path = nil
                previewLayer.removeAllAnimations()
                ringLayer.isHidden = true
                ringLayer.removeAllAnimations()
            }
            return
        }
        let color = (pv.ok ? pv.color : LinkOverlay.warnColor).cgColor
        let p = CGMutablePath()
        p.move(to: pv.from)
        p.addLine(to: pv.to)
        previewLayer.path = p
        previewLayer.strokeColor = color
        if previewLayer.animation(forKey: "flow") == nil {
            let a = CABasicAnimation(keyPath: "lineDashPhase")
            a.fromValue = 11
            a.toValue = 0
            a.duration = 0.4
            a.repeatCount = .infinity
            previewLayer.add(a, forKey: "flow")
        }
        let d = pv.radius * 2
        if ringLayer.bounds.width != d {
            ringLayer.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            ringLayer.path = CGPath(ellipseIn: ringLayer.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        }
        ringLayer.position = pv.to
        ringLayer.strokeColor = color
        ringLayer.isHidden = false
        if ringLayer.animation(forKey: "pulse") == nil {
            let a = CABasicAnimation(keyPath: "transform.scale")
            a.fromValue = 0.94
            a.toValue = 1.06
            a.duration = 0.45
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ringLayer.add(a, forKey: "pulse")
        }
    }

    func setPills(_ items: [LinkOverlay.Pill]) {
        let keep = Set(items.map(\.id))
        for (id, l) in pills where !keep.contains(id) { l.removeFromSuperlayer(); pills[id] = nil }
        for it in items where frame.contains(CGPoint(x: it.at.x + frame.minX, y: it.at.y + frame.minY)) {
            let pill = pills[it.id] ?? makeLabel()
            if pills[it.id] == nil { pills[it.id] = pill; root.addSublayer(pill) }
            configure(pill, text: it.text, at: it.at, color: it.color, size: 11.5, height: 20)
        }
    }

    func setLabels(_ items: [LinkOverlay.Label]) {
        let keep = Set(items.map(\.id))
        for (id, l) in labels where !keep.contains(id) { l.removeFromSuperlayer(); labels[id] = nil }
        for it in items where frame.contains(CGPoint(x: it.at.x + frame.minX, y: it.at.y + frame.minY)) {
            let pill = labels[it.id] ?? makeLabel()
            if labels[it.id] == nil { labels[it.id] = pill; root.addSublayer(pill) }
            configure(pill, text: it.text, at: it.at, color: it.color, size: 10.5, height: 16)
        }
    }

    private func configure(_ pill: CALayer, text: String, at: CGPoint, color: NSColor, size: CGFloat, height h: CGFloat) {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
        let ts = str.size()
        let pad = round(h * 0.38)
        let w = ceil(ts.width) + pad * 2
        pill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        pill.position = CGPoint(x: round(at.x), y: round(at.y - h / 2))
        pill.backgroundColor = color.blended(withFraction: 0.35, of: .black)?.withAlphaComponent(0.9).cgColor
        if let t = pill.sublayers?.first as? CATextLayer {
            t.string = str
            t.frame = CGRect(x: pad, y: (h - ceil(ts.height)) / 2, width: ceil(ts.width) + 1, height: ceil(ts.height))
        }
    }

    private func makeLabel() -> CALayer {
        let pill = CALayer()
        pill.cornerRadius = 3
        pill.contentsScale = scale
        let t = CATextLayer()
        t.contentsScale = scale
        t.alignmentMode = .left
        pill.addSublayer(t)
        return pill
    }

    func addPacket(along pts: [CGPoint], color: NSColor, duration: Double, delay: Double) {
        let s: CGFloat = 7
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        dot.backgroundColor = color.cgColor
        dot.shadowColor = color.cgColor
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 4
        dot.shadowOffset = .zero
        dot.position = pts.last!
        dot.opacity = 0
        root.addSublayer(dot)
        let path = CGMutablePath()
        path.move(to: pts[0])
        for p in pts.dropFirst() { path.addLine(to: p) }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.calculationMode = .paced
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.12, 0.85, 1]
        let g = CAAnimationGroup()
        g.animations = [move, fade]
        g.duration = duration
        g.beginTime = CACurrentMediaTime() + delay
        g.fillMode = .backwards
        g.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { dot.removeFromSuperlayer() }
        dot.add(g, forKey: "move")
        CATransaction.commit()
    }

    func addSnap(_ a: CGPoint, _ b: CGPoint) {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        for end in [a, b] {
            let s = makeLine()
            s.strokeColor = LinkOverlay.warnColor.cgColor
            let p = CGMutablePath()
            p.move(to: end)
            p.addLine(to: mid)
            s.path = p
            s.strokeEnd = 0
            root.addSublayer(s)
            let shrink = CABasicAnimation(keyPath: "strokeEnd")
            shrink.fromValue = 1
            shrink.toValue = 0
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let g = CAAnimationGroup()
            g.animations = [shrink, fade]
            g.duration = 0.32
            g.timingFunction = CAMediaTimingFunction(name: .easeIn)
            CATransaction.begin()
            CATransaction.setCompletionBlock { s.removeFromSuperlayer() }
            s.add(g, forKey: "snap")
            CATransaction.commit()
        }
    }
}

/// 線の上に出る小さな ✂︎ ボタン（クリックできる小窓。フォーカスは奪わない）
private final class ScissorsPanel: NSPanel {
    var onClick: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 26, height: 26), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        let v = ScissorsView(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        v.onClick = { [weak self] in self?.onClick?() }
        contentView = v
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(at p: CGPoint) {
        setFrameOrigin(NSPoint(x: round(p.x - 13), y: round(p.y - 13)))
        if !isVisible { orderFrontRegardless() }
    }
}

private final class ScissorsView: NSView {
    var onClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.12, green: 0.13, blue: 0.18, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        NSColor(white: 1, alpha: 0.85).setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1.5, dy: 1.5))
        ring.lineWidth = 1
        ring.stroke()
        let s = NSAttributedString(string: "✂︎", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold),
                                                               .foregroundColor: NSColor.white])
        let sz = s.size()
        s.draw(at: NSPoint(x: (bounds.width - sz.width) / 2, y: (bounds.height - sz.height) / 2))
    }
}
