import AppKit
import MetalKit

/// マウスを受けない MTKView（イベントは親の JellyHostView が受ける）
final class PassthroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 半透明のリアルなクラゲ（Metal シェーダで描画）。見た目メニューから選べる別スタイル。
final class RealisticAvatar: NSObject, Avatar, MTKViewDelegate {
    let motion: JellyMotion
    private let mtkView: PassthroughMTKView
    var view: NSView { mtkView }
    var size: CGSize { motion.size }
    var state: AgentState { motion.state }

    private var maxFPS: Int
    private var calmFPS: Int
    private var active = false
    private var dragging = false
    private var lastFrame: CFTimeInterval = 0

    init(record: JellyRecord, R: Double, maxFPS: Int, calmFPS: Int) {
        self.maxFPS = maxFPS
        self.calmFPS = calmFPS
        motion = JellyMotion(R: R, color: record.color, state: record.state, seed: Double(record.number) * 0.618 + 0.3)
        mtkView = PassthroughMTKView(frame: NSRect(origin: .zero, size: motion.size), device: JellyGPU.shared.device)
        super.init()
        mtkView.colorPixelFormat = JellyGPU.shared.pixelFormat
        mtkView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        mtkView.framebufferOnly = true
        mtkView.preferredFramesPerSecond = maxFPS
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = true
        mtkView.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        mtkView.layer?.isOpaque = false
        mtkView.layer?.backgroundColor = .clear
        mtkView.delegate = self
    }

    var isAnimating: Bool { !mtkView.isPaused }

    private func resume() {
        guard active, mtkView.isPaused else { return }
        lastFrame = CACurrentMediaTime()
        mtkView.isPaused = false
    }

    func setState(_ s: AgentState) { motion.setState(s); resume() }
    func hitTest(_ p: CGPoint) -> Bool { motion.hitTest(p) }

    func pointerMoved(inside: Bool, local: CGPoint) {
        let h: Double = inside ? 1 : 0
        if motion.hoverTarget != h { motion.hoverTarget = h; resume() }
    }

    func poke() { motion.pokeNow(); resume() }
    func spawn() { motion.beginSpawn(); resume() }

    func despawn(_ done: @escaping () -> Void) {
        guard active else { done(); return }
        motion.beginDespawn(done)
        resume()
    }

    func dragBegan() { dragging = true; resume() }
    func dragEnded() { dragging = false; resume() }
    /// ドラッグ中は窓の移動で触手がなびくので描画を続ける
    func windowMoved() { resume() }

    func setActive(_ a: Bool) {
        active = a
        if a { resume() } else { mtkView.isPaused = true }
    }

    func setFrameRates(max: Int, calm: Int) {
        maxFPS = max
        calmFPS = calm
        resume()
    }

    func teardown() {
        mtkView.isPaused = true
        mtkView.delegate = nil
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastFrame == 0 ? 1.0 / 60.0 : now - lastFrame
        lastFrame = now
        motion.step(dt: dt, windowOrigin: view.window?.frame.origin ?? .zero)
        let fps = (motion.wantsHighFrameRate || dragging) ? maxFPS : min(calmFPS, maxFPS)
        if view.preferredFramesPerSecond != fps { view.preferredFramesPerSecond = fps }

        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = JellyGPU.shared.queue.makeCommandBuffer() else { return }
        let scale = Double(view.drawableSize.width / max(view.bounds.width, 1))
        JellyGPU.shared.encode(cb, pass: rpd, uniforms: motion.uniforms(pixelsPerPoint: scale, drawableSize: view.drawableSize))
        cb.present(drawable)
        cb.commit()
        // 完了・キャンセルで動きが収まったら描画そのものを止める
        if motion.settled && !dragging { view.isPaused = true }
    }
}
