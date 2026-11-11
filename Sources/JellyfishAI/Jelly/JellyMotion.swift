import Foundation
import CoreGraphics
import simd

/// 状態ごとの「動きの目標値」。現在値はこれに向かって指数的に近づくので、状態遷移は常に滑らか。
struct MotionParams {
    var period: Double      // 拍動周期 (s)
    var amp: Double         // 拍動の深さ 0..1
    var waveAmp: Double     // 触手の波の振幅
    var waveSpeed: Double   // 触手の波の速さ
    var glow: Double        // 発光強度
    var rotSpeed: Double    // 鉛直軸まわりの自転 (rad/s)
    var activity: Double    // 漂い・傾きの大きさ
    var wIdle: Double       // 縁の光：ゆっくり瞬く
    var wThink: Double      // 縁の光：きらきら瞬く
    var wWork: Double       // 縁の光：一周するように巡る
    var err: Double         // 赤への混色
    var desat: Double       // 彩度低下（キャンセル）
    var coreAmp: Double     // 中心コアの脈動の深さ
    var coreSpeed: Double
    var chaseSpeed: Double

    static func target(for s: AgentState) -> MotionParams {
        switch s {
        case .idle:
            return MotionParams(period: 3.6, amp: 0.55, waveAmp: 1.0, waveSpeed: 0.9, glow: 0.90, rotSpeed: 0.09, activity: 1.0,
                                wIdle: 1, wThink: 0, wWork: 0, err: 0, desat: 0, coreAmp: 0.35, coreSpeed: 0.9, chaseSpeed: 0)
        case .thinking:
            return MotionParams(period: 2.2, amp: 0.68, waveAmp: 1.1, waveSpeed: 1.4, glow: 1.05, rotSpeed: 0.16, activity: 1.0,
                                wIdle: 0, wThink: 1, wWork: 0, err: 0, desat: 0, coreAmp: 1.0, coreSpeed: 2.6, chaseSpeed: 0)
        case .working:
            return MotionParams(period: 1.2, amp: 0.92, waveAmp: 1.3, waveSpeed: 2.4, glow: 1.15, rotSpeed: 0.28, activity: 1.15,
                                wIdle: 0, wThink: 0, wWork: 1, err: 0, desat: 0, coreAmp: 0.7, coreSpeed: 4.0, chaseSpeed: 3.2)
        case .completed:
            return MotionParams(period: 3.6, amp: 0, waveAmp: 0.30, waveSpeed: 0, glow: 0.95, rotSpeed: 0, activity: 0,
                                wIdle: 0, wThink: 0, wWork: 0, err: 0, desat: 0, coreAmp: 0, coreSpeed: 0, chaseSpeed: 0)
        case .error:
            return MotionParams(period: 2.8, amp: 0.45, waveAmp: 0.7, waveSpeed: 0.8, glow: 0.95, rotSpeed: 0.05, activity: 0.45,
                                wIdle: 0, wThink: 0, wWork: 0, err: 1, desat: 0, coreAmp: 0.8, coreSpeed: 2.0, chaseSpeed: 0)
        case .cancelled:
            return MotionParams(period: 3.6, amp: 0, waveAmp: 0.30, waveSpeed: 0, glow: 0.55, rotSpeed: 0, activity: 0,
                                wIdle: 0, wThink: 0, wWork: 0, err: 0, desat: 0.80, coreAmp: 0, coreSpeed: 0, chaseSpeed: 0)
        }
    }

    mutating func approach(_ t: MotionParams, _ k: Double) {
        // 周期は対数空間で補間（速くなる/遅くなる変化が自然に見える）
        period = exp(log(period) + (log(t.period) - log(period)) * k)
        amp += (t.amp - amp) * k
        waveAmp += (t.waveAmp - waveAmp) * k
        waveSpeed += (t.waveSpeed - waveSpeed) * k
        glow += (t.glow - glow) * k
        rotSpeed += (t.rotSpeed - rotSpeed) * k
        activity += (t.activity - activity) * k
        wIdle += (t.wIdle - wIdle) * k
        wThink += (t.wThink - wThink) * k
        wWork += (t.wWork - wWork) * k
        err += (t.err - err) * k
        desat += (t.desat - desat) * k
        coreAmp += (t.coreAmp - coreAmp) * k
        coreSpeed += (t.coreSpeed - coreSpeed) * k
        chaseSpeed += (t.chaseSpeed - chaseSpeed) * k
    }
}

/// クラゲ1体の運動シミュレーション。描画とは独立（オフスクリーン描画でも同じものを使う）。
/// 座標はウィンドウローカルのポイント、左下原点。
final class JellyMotion {
    let R: Double              // 傘の半径 (pt)
    let size: CGSize           // ウィンドウサイズ (pt)
    let home: CGPoint          // 傘の縁の中心の定位置
    let color: JellyColor
    let seed: Double

    private(set) var state: AgentState
    private var target: MotionParams
    private(set) var cur: MotionParams

    private(set) var t: Double = 0
    private var phase: Double
    private var wavePhase: Double
    private var rot: Double
    private var chase: Double = 0
    private var corePhase: Double = 0
    private var driftT: Double
    private(set) var contraction: Double = 0
    private var prevContraction: Double = 0
    private(set) var bx: Double
    private(set) var by: Double
    private var vy: Double = 0
    private var ay: Double = 0
    private var tilt: Double = 0
    private var vxScreen: Double = 0
    private var lastScreen: SIMD2<Double>?

    // インタラクション
    private var poke: Double = 0          // クリック時の反応（0..1, 減衰）
    private var pokeT: Double = 10
    var hoverTarget: Double = 0
    private var hover: Double = 0

    // 出現・消滅
    private var spawnP: Double = 1
    private var despawnP: Double = 0
    private(set) var despawning = false
    var onDespawned: (() -> Void)?

    // 触手の遅れ用の位置履歴（スクリーン座標）
    private var history: [(t: Double, p: SIMD2<Double>)] = []
    private var histOffsets = [SIMD2<Double>](repeating: .zero, count: JellyShader.historyCount)

    /// 完全に静止したか（true なら描画ループを止めてよい）
    private(set) var settled = false

    static func windowSize(R: Double) -> CGSize { CGSize(width: (R * 4.6).rounded(), height: (R * 5.7).rounded()) }

    init(R: Double, color: JellyColor, state: AgentState, seed: Double) {
        self.R = R
        self.size = JellyMotion.windowSize(R: R)
        self.home = CGPoint(x: size.width / 2, y: size.height - R * (0.80 * 1.12 + 0.50))
        self.color = color
        self.seed = seed
        self.state = state
        self.target = MotionParams.target(for: state)
        self.cur = target
        self.phase = (seed * 0.731).truncatingRemainder(dividingBy: 1)
        self.wavePhase = seed * 3.1
        self.rot = seed * 1.7
        self.driftT = seed * 13.0
        self.bx = home.x
        self.by = home.y
    }

    func setState(_ s: AgentState, immediate: Bool = false) {
        state = s
        target = MotionParams.target(for: s)
        if immediate { cur = target }
        settled = false
    }

    func pokeNow() {
        pokeT = 0
        settled = false
    }

    func beginSpawn() {
        spawnP = 0
        settled = false
    }

    func beginDespawn(_ done: @escaping () -> Void) {
        despawning = true
        despawnP = 0
        onDespawned = done
        settled = false
    }

    var needsRedrawForHover: Bool { abs(hover - hoverTarget) > 0.01 }

    private var maxHistOffset = 0.0

    /// 60fps が必要な動きがあるか。待機中でゆったりしているときは 30fps に落として電力を節約する。
    var wantsHighFrameRate: Bool {
        if state == .thinking || state == .working || state.isTerminal { return true }
        if spawnP < 1 || despawning || pokeT < 1.5 || needsRedrawForHover { return true }
        if maxHistOffset > 1.0 || abs(vxScreen) > 1.0 { return true }   // ドラッグ直後の触手のなびき
        if abs(cur.amp - target.amp) > 0.02 || abs(cur.waveSpeed - target.waveSpeed) > 0.05 { return true }
        return false
    }

    // MARK: - シミュレーション

    private static func pulseShape(_ f: Double) -> Double {
        let rise = 0.26
        if f < rise { return pow(sin(f / rise * .pi / 2), 1.6) }
        let x = (f - rise) / (1 - rise)
        return pow(max(0, 1 - x), 2.6)
    }

    private static func smooth(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }

    private static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.4, c3 = c1 + 1
        let p = min(max(x, 0), 1) - 1
        return 1 + c3 * p * p * p + c1 * p * p
    }

    func step(dt rawDt: Double, windowOrigin: CGPoint) {
        let dt = min(max(rawDt, 1.0 / 240.0), 1.0 / 15.0)
        t += dt

        let calming = state.isTerminal
        let tau = calming ? 0.8 : 0.8
        cur.approach(target, 1 - exp(-dt / tau))
        hover += (hoverTarget - hover) * (1 - exp(-dt / 0.15))

        // 位相の積分（速度が 0 に近づけば模様もそのまま凍る）
        let jitter = 1 + 0.6 * sin(t * 7.3) * cur.err
        phase = (phase + dt / cur.period * jitter).truncatingRemainder(dividingBy: 1)
        wavePhase += dt * cur.waveSpeed * 1.6
        rot += dt * cur.rotSpeed
        chase += dt * cur.chaseSpeed
        corePhase += dt * cur.coreSpeed
        driftT += dt

        // 収縮（拍動 + クリック反応 + 出現時のひと泳ぎ）
        pokeT += dt
        let pokeEnv = pokeT < 0.12 ? JellyMotion.smooth(pokeT / 0.12) : exp(-(pokeT - 0.12) / 0.35)
        poke = pokeT < 3 ? pokeEnv : 0
        var c = cur.amp * JellyMotion.pulseShape(phase) + 0.45 * poke
        if spawnP < 1 {
            spawnP = min(1, spawnP + dt / 1.3)
            c += 0.6 * sin(min(spawnP / 0.55, 1) * .pi)
        }
        if despawning {
            despawnP = min(1, despawnP + dt / 0.9)
            c += 0.5 * sin(min(despawnP / 0.5, 1) * .pi)
        }
        c = min(max(c, 0), 1)
        let dc = (c - prevContraction) / dt
        prevContraction = c
        contraction = c

        // 縦方向：収縮で推力 → バネで定位置へ戻る（押して、ゆっくり沈む）
        let thrust = 0.5 * R * max(dc, 0)
        // 終了状態では減衰を強めて、上下の揺れを素早く収める
        ay = thrust - 2.25 * (by - home.y) - (calming ? 3.2 : 1.6) * vy
        vy += ay * dt
        by += vy * dt
        by = min(max(by, home.y - R * 0.9), home.y + R * 0.55)

        // 横方向：ゆっくり漂う（activity が 0 になれば定位置で止まる）
        let drift = R * 0.20 * (0.65 * sin(0.19 * driftT + seed) + 0.35 * sin(0.43 * driftT + seed * 2.3))
        bx = home.x + drift * cur.activity

        // 傾き：スクリーン上の横速度（ドラッグ含む）に応じて頭を進行方向へ
        let sc = SIMD2<Double>(Double(windowOrigin.x) + bx, Double(windowOrigin.y) + by)
        if let last = lastScreen {
            let vx = (sc.x - last.x) / dt
            vxScreen += (vx - vxScreen) * (1 - exp(-dt / 0.22))
        }
        lastScreen = sc
        let tiltTarget = min(max(-vxScreen * 0.0045, -0.45), 0.45) + 0.045 * sin(0.37 * t + seed) * cur.activity
        tilt += (tiltTarget - tilt) * (1 - exp(-dt / 0.35))

        // 履歴 → 遅れオフセット
        history.append((t, sc))
        let horizon = t - Double(JellyShader.historyCount) / 30.0 - 0.1
        if let firstKeep = history.firstIndex(where: { $0.t >= horizon }), firstKeep > 1 {
            history.removeFirst(firstKeep - 1)
        }
        var idx = history.count - 1
        var maxOff = 0.0
        for k in 0..<JellyShader.historyCount {
            let lagT = t - Double(k) / 30.0
            while idx > 0 && history[idx].t > lagT { idx -= 1 }
            let p: SIMD2<Double>
            if idx >= history.count - 1 {
                p = history[history.count - 1].p
            } else {
                let a = history[idx], b = history[idx + 1]
                let f = b.t > a.t ? min(max((lagT - a.t) / (b.t - a.t), 0), 1) : 0
                p = a.p + (b.p - a.p) * f
            }
            // 触手がウィンドウからはみ出さないよう、遅れ量を tanh で滑らかに頭打ちにする
            let raw = p - sc
            let lx = R * 1.0, ly = R * 0.8
            let off = SIMD2<Double>(lx * tanh(raw.x / lx), ly * tanh(raw.y / ly))
            histOffsets[k] = off
            maxOff = max(maxOff, simd_length(off))
        }
        maxHistOffset = maxOff

        if despawning && despawnP >= 1 {
            let cb = onDespawned
            onDespawned = nil
            DispatchQueue.main.async { cb?() }
        }

        // 静止判定：終了状態で、すべての動きが十分小さくなったら止める
        settled = calming
            && cur.amp < 0.006 && cur.activity < 0.006 && cur.waveSpeed < 0.006 && cur.rotSpeed < 0.002
            && cur.coreAmp < 0.006 && cur.chaseSpeed < 0.006
            && abs(vy) < 0.02 && abs(ay) < 0.02 && contraction < 0.002
            && pokeT > 2.5 && spawnP >= 1 && !despawning
            && maxOff < 0.15 && abs(vxScreen) < 0.05 && !needsRedrawForHover
    }

    // MARK: - シェーダへ渡す値

    func uniforms(pixelsPerPoint s: Double, drawableSize: CGSize) -> [SIMD4<Float>] {
        var u = [SIMD4<Float>](repeating: .zero, count: JellyShader.uniformCount)

        var scale = 1.0
        var opacity = 1.0
        var lift = 0.0
        if spawnP < 1 {
            let e = JellyMotion.easeOutBack(spawnP)
            scale = 0.45 + 0.55 * e
            opacity = JellyMotion.smooth(spawnP / 0.45)
            lift = -R * 0.7 * (1 - JellyMotion.smooth(spawnP))
        }
        if despawning {
            scale *= 1 - 0.2 * despawnP
            opacity *= 1 - JellyMotion.smooth(despawnP)
            lift += R * 0.8 * JellyMotion.smooth(despawnP)
        }

        func f(_ x: Double) -> Float { Float(x) }
        u[0] = [f(drawableSize.width), f(drawableSize.height), f(s), f(t)]
        u[1] = [f(bx * s), f((by + lift) * s), f(R * s * scale), f(contraction)]
        u[2] = SIMD4(color.base, f(opacity))
        u[3] = SIMD4(color.deep, f(1 - cur.desat))
        u[4] = [f(cur.glow), f(cur.waveAmp), f(wavePhase), f(rot)]
        u[5] = [f(cur.wIdle), f(cur.wThink), f(cur.wWork), f(chase)]
        // 終了状態では coreAmp → 0 で一定の明るさに落ち着く
        let corePulse = 0.5 + 0.5 * cur.coreAmp * sin(corePhase)
        u[6] = [f(tilt), f(corePulse), f(poke), f(cur.err)]
        u[7] = [f(hover), 1, 0, 0]
        for k in 0..<JellyShader.historyCount {
            let o = histOffsets[k] * s
            u[8 + k] = [f(o.x), f(o.y), 0, 0]
        }
        return u
    }

    /// クリック・ドラッグを受け付ける領域か（ウィンドウローカル pt）
    func hitTest(_ p: CGPoint) -> Bool {
        let qx = (Double(p.x) - bx) / R
        let qy = (Double(p.y) - by) / R
        // 傘（少し広め）
        if qy >= -0.30 {
            let ex = qx / 1.08, ey = qy >= 0 ? qy / 0.95 : qy / 0.35
            if ex * ex + ey * ey < 1 { return true }
        }
        // 傘の下、口腕の付け根あたり
        if abs(qx) < 0.42 && qy < 0 && qy > -1.15 { return true }
        return false
    }
}
