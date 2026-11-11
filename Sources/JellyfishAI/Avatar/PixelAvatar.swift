import AppKit
import QuartzCore

/// マウスを受けない描画専用ビュー（イベントは親の JellyHostView が受ける）
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// ドット絵の Claude キャラクター。
///
/// 負荷を抑える設計：
/// - ふわふわ浮く・跳ねる・揺れるといった連続的な動きは Core Animation に任せる
///   （WindowServer 側で補間されるので、アプリのメインスレッドは毎フレーム起きない）
/// - アプリが描き替えるのはドット絵のコマ（まばたき・手足）だけで、最大 8fps
/// - 完了・キャンセルでは揺れを減衰させて止め、タイマーもアニメーションも完全に無くす
final class PixelAvatar: Avatar {
    static func cell(scale: Double) -> Double { (6.0 * scale).rounded() }
    static let topMarginCells: CGFloat = 2.0
    static let bottomMarginCells: CGFloat = 0.5

    static func windowSize(scale: Double) -> CGSize {
        let P = CGFloat(cell(scale: scale))
        return CGSize(width: CGFloat(ClawdSprite.cols) * P,
                      height: (CGFloat(ClawdSprite.rows) + topMarginCells + bottomMarginCells) * P)
    }

    let view: NSView
    let size: CGSize
    private let P: CGFloat
    private let colors: ClawdColors
    private let glow: CGColor
    private let cacheKey: String

    private let root = CALayer()
    private let floatLayer = CALayer()
    private let hopLayer = CALayer()
    private let spriteLayer = CALayer()

    private(set) var state: AgentState
    private var timer: Timer?
    private var stateStart = CACurrentMediaTime()
    private var active = false
    private var settling = false
    private var settled = false

    // 表情・手足の状態
    private var pose = ClawdPose()
    private var shownPose: ClawdPose?
    private var nextBlink = CACurrentMediaTime() + 2.5
    private var blinkEnd = 0.0
    private var glance: (dx: Int, dy: Int, until: Double)?
    private var nextGlance = CACurrentMediaTime() + 6
    private var hoverLook: (dx: Int, dy: Int)?
    private var pokeEnd = 0.0
    private var dragging = false
    private var pressing = false
    private var landEnd = 0.0
    private let seed: Double

    init(record: JellyRecord, scale: Double) {
        P = CGFloat(PixelAvatar.cell(scale: scale))
        size = PixelAvatar.windowSize(scale: scale)
        colors = ClawdColors.from(record.color)
        let f = record.color.flat
        glow = CGColor(srgbRed: CGFloat(f.x), green: CGFloat(f.y), blue: CGFloat(f.z), alpha: 1)
        cacheKey = record.color.key
        state = record.state
        seed = Double(record.number) * 0.618

        let v = PassthroughView(frame: NSRect(origin: .zero, size: size))
        v.wantsLayer = true
        v.layer = root
        view = v

        root.frame = CGRect(origin: .zero, size: size)
        floatLayer.frame = root.bounds
        hopLayer.frame = root.bounds
        // 拡大・縮小はスプライトの足元を基準に
        let footY = PixelAvatar.bottomMarginCells * P + P * 1.0
        hopLayer.anchorPoint = CGPoint(x: 0.5, y: footY / size.height)
        hopLayer.position = CGPoint(x: size.width / 2, y: footY)

        spriteLayer.frame = CGRect(x: 0, y: PixelAvatar.bottomMarginCells * P,
                                   width: CGFloat(ClawdSprite.cols) * P, height: CGFloat(ClawdSprite.rows) * P)
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        spriteLayer.actions = ["contents": NSNull(), "opacity": NSNull()]
        // やわらかい発光（エージェント色の影）
        spriteLayer.shadowColor = glow
        spriteLayer.shadowOpacity = 0.55
        spriteLayer.shadowRadius = P * 0.9
        spriteLayer.shadowOffset = .zero
        spriteLayer.shouldRasterize = true
        spriteLayer.rasterizationScale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2

        root.addSublayer(floatLayer)
        floatLayer.addSublayer(hopLayer)
        hopLayer.addSublayer(spriteLayer)
        [root, floatLayer, hopLayer].forEach { $0.actions = ["transform": NSNull(), "opacity": NSNull(), "position": NSNull()] }

        pose = basePose(for: state, now: CACurrentMediaTime())
        render(force: true)
    }

    var isAnimating: Bool { timer != nil || !(floatLayer.animationKeys() ?? []).isEmpty || !(hopLayer.animationKeys() ?? []).isEmpty }

    // MARK: - 状態

    func setState(_ s: AgentState) {
        let changed = s != state
        state = s
        stateStart = CACurrentMediaTime()
        settled = false
        settling = false
        if active { applyStateMotion(transition: changed) }
        pose = basePose(for: s, now: stateStart)
        render(force: true)
    }

    private func basePose(for s: AgentState, now: Double) -> ClawdPose {
        var p = ClawdPose()
        switch s {
        case .idle, .thinking, .working: break
        case .completed: p.eyes = .happy; p.mark = .check
        case .error: p.eyes = .cross; p.tone = .error; p.mark = .exclaim
        case .cancelled: p.eyes = .closed; p.tone = .cancelled
        }
        return p
    }

    /// 状態ごとの「連続的な動き」（Core Animation）を設定する
    private func applyStateMotion(transition: Bool) {
        hopLayer.removeAnimation(forKey: "shake")
        hopLayer.removeAnimation(forKey: "hopLoop")
        spriteLayer.opacity = state == .cancelled ? 0.78 : 1.0
        switch state {
        case .idle:
            setFloat(amplitude: P * 0.45, period: 3.6)
        case .thinking:
            setFloat(amplitude: P * 0.45, period: 2.3)
        case .working:
            setFloat(amplitude: P * 0.18, period: 1.6)
        case .error:
            setFloat(amplitude: P * 0.22, period: 3.8)
            addShakeLoop()
        case .completed, .cancelled:
            settleFloat()
        }
        startTimer()
    }

    private func currentY(_ layer: CALayer) -> CGFloat {
        (layer.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat) ?? 0
    }

    private func sineKeyframes(_ A: CGFloat, period: Double) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values = [0, A, 0, -A, 0]
        a.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        let out = CAMediaTimingFunction(name: .easeOut), inn = CAMediaTimingFunction(name: .easeIn)
        a.timingFunctions = [out, inn, out, inn]
        a.duration = period
        a.repeatCount = .infinity
        return a
    }

    /// 浮遊ループ。今の位置から滑らかにつないで、新しい振幅・周期で浮かぶ
    private func setFloat(amplitude A: CGFloat, period: Double) {
        let cur = currentY(floatLayer)
        floatLayer.removeAllAnimations()
        let lead = 0.4
        let tin = CABasicAnimation(keyPath: "transform.translation.y")
        tin.fromValue = cur
        tin.toValue = 0
        tin.duration = lead
        tin.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        floatLayer.add(tin, forKey: "floatIn")
        let loop = sineKeyframes(A, period: period)
        loop.beginTime = floatLayer.convertTime(CACurrentMediaTime(), from: nil) + lead
        floatLayer.add(loop, forKey: "float")
    }

    /// 揺れを数回で減衰させて完全に止める
    private func settleFloat() {
        let cur = currentY(floatLayer)
        floatLayer.removeAllAnimations()
        settling = true
        let A = max(abs(cur), P * 0.35)
        let s: CGFloat = cur >= 0 ? 1 : -1
        let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
        a.values = [cur, -s * A * 0.55, s * A * 0.28, -s * A * 0.10, 0]
        a.keyTimes = [0, 0.28, 0.56, 0.8, 1]
        a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        a.duration = 2.4
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.settling, self.state.isTerminal else { return }
            self.settling = false
            self.settled = true
            self.stopTimer()
            self.render(force: false)
        }
        floatLayer.add(a, forKey: "settle")
        CATransaction.commit()
    }

    private func addShakeLoop() {
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        let d = P * 0.35
        shake.values = [0, -d, d, -d, d * 0.6, 0, 0]
        shake.keyTimes = [0, 0.04, 0.08, 0.12, 0.16, 0.2, 1]
        shake.duration = 2.6
        shake.repeatCount = .infinity
        hopLayer.add(shake, forKey: "shake")
    }

    // MARK: - コマ送り（まばたき・手足）

    private func startTimer() {
        guard active, timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let el = now - stateStart
        var p = basePose(for: state, now: now)

        switch state {
        case .idle:
            if now > nextGlance && glance == nil {
                glance = (dx: Bool.random() ? 1 : -1, dy: Int.random(in: -1...0), until: now + 1.1)
                nextGlance = now + Double.random(in: 5...9)
            }
            if let g = glance { if now < g.until { p.eyes = .open(dx: g.dx, dy: g.dy) } else { glance = nil } }
            // ときどき脚をトントン
            let tap = (el + seed * 3).truncatingRemainder(dividingBy: 7.0)
            if tap < 0.25 { p.legs = .walkA } else if tap < 0.5 { p.legs = .walkB }
        case .thinking:
            // 目がきょろきょろ、頭上に「…」が増えていく
            let gl = [(-1, -1), (-1, -1), (1, -1), (1, -1), (0, -1), (0, 0)]
            let gi = Int(el / 0.45) % gl.count
            p.eyes = .open(dx: gl[gi].0, dy: gl[gi].1)
            p.mark = .dots(Int(el / 0.38) % 4)
        case .working:
            // 腕を交互にせわしなく、脚は足踏み、ときどき小さく跳ねる
            let f = Int(el * 8)
            p.arms = f % 2 == 0 ? .leftUp : .rightUp
            p.legs = (f / 2) % 2 == 0 ? .walkA : .walkB
            let beat = f % 8
            if beat == 3 { p.legs = .crouch } else if beat == 4 || beat == 5 { p.lift = 1 }
            p.eyes = .open(dx: 0, dy: f % 16 < 8 ? 1 : 0)
        case .error:
            p.mark = Int(el / 0.4) % 3 == 2 ? .none : .exclaim
        case .completed, .cancelled:
            break
        }

        // まばたき（終了状態以外）
        if !state.isTerminal && state != .error {
            if now > nextBlink {
                blinkEnd = now + 0.13
                nextBlink = now + Double.random(in: 2.2...5.5)
                if Double.random(in: 0...1) < 0.2 { nextBlink = now + 0.35 }  // たまに二度まばたき
            }
            if now < blinkEnd { p.eyes = .closed }
            if let h = hoverLook, now >= blinkEnd, case .open = p.eyes { p.eyes = .open(dx: h.dx, dy: h.dy) }
        }

        // 操作への反応
        if now < pokeEnd { p.arms = .raised; if case .open = p.eyes { p.eyes = .open(dx: 0, dy: -1) } }
        if dragging { p.arms = .raised; p.legs = .dangle; p.eyes = state.isTerminal ? p.eyes : .open(dx: 0, dy: 1); p.lift = 0 }
        if now < landEnd { p.legs = .crouch }
        if pressing { p.eyes = .closed; p.arms = .down; p.mark = .none }

        pose = p
        render(force: false)

        // 終了状態は揺れが収まり、反応も終わったらタイマーを止める
        if state.isTerminal && settled && now > pokeEnd && now > landEnd && !dragging { stopTimer() }
    }

    private func render(force: Bool) {
        if !force, shownPose == pose { return }
        shownPose = pose
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spriteLayer.contents = ClawdSprite.image(pose, colors: colors, key: cacheKey)
        CATransaction.commit()
    }

    // MARK: - 操作

    func hitTest(_ p: CGPoint) -> Bool {
        let dy = currentY(floatLayer) + currentY(hopLayer)
        let base = PixelAvatar.bottomMarginCells * P
        let rows = CGFloat(ClawdSprite.rows)
        // スプライト本体（キャンバスの列 2..12、行 3..10）を少し広めに
        let rect = CGRect(x: 1.5 * P, y: base + (rows - 11) * P - 0.5 * P + dy,
                          width: 12 * P, height: 9 * P)
        return rect.contains(p)
    }

    func pointerMoved(inside: Bool, local: CGPoint) {
        guard inside, !state.isTerminal, state != .error else {
            if hoverLook != nil { hoverLook = nil; if active { tick() } }
            return
        }
        // 目でカーソルを追う
        let cx = size.width / 2
        let cy = PixelAvatar.bottomMarginCells * P + (CGFloat(ClawdSprite.rows) - 5) * P
        let dx = local.x < cx - P * 1.5 ? -1 : (local.x > cx + P * 1.5 ? 1 : 0)
        let dy = local.y > cy + P ? -1 : (local.y < cy - P * 1.5 ? 1 : 0)
        if hoverLook?.dx != dx || hoverLook?.dy != dy {
            hoverLook = (dx, dy)
            if active { startTimer(); tick() }
        }
    }

    func poke() {
        pokeEnd = CACurrentMediaTime() + 0.42
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, P * 1.4, 0]
        hop.keyTimes = [0, 0.42, 1]
        hop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        hop.duration = 0.4
        hop.isAdditive = true
        hopLayer.add(hop, forKey: "poke")
        landEnd = pokeEnd + 0.12
        startTimer()
        tick()
    }

    func dragBegan() {
        dragging = true
        startTimer()
        tick()
    }

    func dragEnded() {
        dragging = false
        landEnd = CACurrentMediaTime() + 0.15
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale.y")
        bounce.values = [1, 0.86, 1.06, 1]
        bounce.keyTimes = [0, 0.3, 0.65, 1]
        bounce.duration = 0.35
        hopLayer.add(bounce, forKey: "land")
        startTimer()
        tick()
    }

    // MARK: - 出現・消滅・表示

    func spawn() {
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.15
        pop.toValue = 1.0
        pop.damping = 11
        pop.stiffness = 240
        pop.mass = 1
        pop.duration = pop.settlingDuration
        hopLayer.add(pop, forKey: "spawn")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.18
        hopLayer.add(fade, forKey: "spawnFade")
        pokeEnd = CACurrentMediaTime() + 0.5
        startTimer()
    }

    func despawn(_ done: @escaping () -> Void) {
        stopTimer()
        pressing = false
        CATransaction.begin()
        CATransaction.setCompletionBlock(done)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.toValue = 0.1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.toValue = 0
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.byValue = P * 2
        let g = CAAnimationGroup()
        g.animations = [shrink, fade, rise]
        g.duration = 0.32
        g.timingFunction = CAMediaTimingFunction(name: .easeIn)
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        hopLayer.add(g, forKey: "despawn")
        CATransaction.commit()
    }

    func setActive(_ a: Bool) {
        guard a != active else { return }
        active = a
        if a {
            settled = false
            applyStateMotion(transition: false)
            tick()
        } else {
            stopTimer()
            floatLayer.removeAllAnimations()
            hopLayer.removeAllAnimations()
        }
    }

    func setFrameRates(max: Int, calm: Int) {}

    /// 長押し：少し遅れてから、ぎゅっと縮みながら震えだす（離せば元に戻る）
    func pressBegan(duration: Double) {
        let delay = 0.15
        let now = hopLayer.convertTime(CACurrentMediaTime(), from: nil)
        let squeeze = CABasicAnimation(keyPath: "transform.scale")
        squeeze.fromValue = 1.0
        squeeze.toValue = 0.72
        squeeze.beginTime = now + delay
        squeeze.duration = duration - delay
        squeeze.timingFunction = CAMediaTimingFunction(name: .easeIn)
        squeeze.fillMode = .forwards
        squeeze.isRemovedOnCompletion = false
        hopLayer.add(squeeze, forKey: "press")
        let tremble = CAKeyframeAnimation(keyPath: "transform.translation.x")
        let d = P * 0.22
        tremble.values = [0, -d, d, -d, d, 0]
        tremble.duration = 0.12
        tremble.repeatCount = Float((duration - delay) / 0.12)
        tremble.beginTime = now + delay
        tremble.isAdditive = true
        hopLayer.add(tremble, forKey: "pressShake")
        pressing = true
        startTimer()
    }

    func pressCancelled() {
        pressing = false
        guard hopLayer.animation(forKey: "press") != nil else { return }
        let cur = (hopLayer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1
        hopLayer.removeAnimation(forKey: "press")
        hopLayer.removeAnimation(forKey: "pressShake")
        let back = CASpringAnimation(keyPath: "transform.scale")
        back.fromValue = cur
        back.toValue = 1.0
        back.damping = 12
        back.stiffness = 300
        back.duration = back.settlingDuration
        hopLayer.add(back, forKey: "pressBack")
        if active { tick() }
    }

    func teardown() {
        stopTimer()
        root.removeAllAnimations()
        floatLayer.removeAllAnimations()
        hopLayer.removeAllAnimations()
    }
}
