import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// ウィンドウを出さずにクラゲを PNG に描き出す開発用ツール。
///   --sheet out.png [--bg dark|light]        色 × 状態 の一覧
///   --strip out.png [--state s] [--color i] [--count n] [--interval sec] [--drag]
///   --icon out.png                           アプリアイコン (1024px)
///   --settle-test                            完了/キャンセルで本当に静止するかを検証
enum SnapshotTool {
    static func handles(_ args: [String]) -> Bool {
        args.contains("--sheet") || args.contains("--strip") || args.contains("--icon") || args.contains("--settle-test")
            || args.contains("--pixel-sheet")
    }

    static func run(_ args: [String]) -> Int32 {
        func value(_ k: String) -> String? {
            guard let i = args.firstIndex(of: k), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let out = value("--sheet") { return sheet(out, dark: value("--bg") != "light") }
        if let out = value("--pixel-sheet") { return pixelSheet(out, dark: value("--bg") != "light") }
        if let out = value("--strip") {
            return strip(out,
                         state: AgentState(rawValue: value("--state") ?? "idle") ?? .idle,
                         color: Int(value("--color") ?? "0") ?? 0,
                         count: Int(value("--count") ?? "8") ?? 8,
                         interval: Double(value("--interval") ?? "0.2") ?? 0.2,
                         drag: args.contains("--drag"),
                         dark: value("--bg") != "light",
                         scale: Double(value("--scale") ?? "2") ?? 2)
        }
        if let out = value("--icon") { return icon(out) }
        if args.contains("--settle-test") { return settleTest() }
        return 1
    }

    // MARK: -

    static let pxPerPt = 2.0
    static let R = 34.0

    static func render(_ m: JellyMotion, scale: Double = pxPerPt) -> CGImage? {
        let w = Int(m.size.width * scale), h = Int(m.size.height * scale)
        return JellyGPU.shared.renderImage(width: w, height: h,
                                           uniforms: m.uniforms(pixelsPerPoint: scale, drawableSize: CGSize(width: w, height: h)))
    }

    static func simulate(_ m: JellyMotion, seconds: Double, origin: (Double) -> CGPoint = { _ in .zero }) {
        var t = 0.0
        let dt = 1.0 / 60.0
        while t < seconds {
            m.step(dt: dt, windowOrigin: origin(t))
            t += dt
        }
    }

    static func makeContext(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    }

    static func fillBackground(_ ctx: CGContext, _ rect: CGRect, dark: Bool) {
        let colors: [CGFloat] = dark ? [0.05, 0.07, 0.11, 1, 0.02, 0.03, 0.05, 1] : [0.95, 0.95, 0.97, 1, 0.86, 0.88, 0.91, 1]
        let g = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colorComponents: colors, locations: [0, 1], count: 2)!
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.drawLinearGradient(g, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        ctx.restoreGState()
    }

    static func write(_ img: CGImage, _ path: String) -> Int32 {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dst = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst) ? 0 : 1
    }

    // MARK: - sheet

    static func sheet(_ out: String, dark: Bool) -> Int32 {
        let states = AgentState.allCases
        let colors = 6
        let size = JellyMotion.windowSize(R: R)
        let tw = Int(size.width * pxPerPt), th = Int(size.height * pxPerPt)
        let W = tw * states.count, H = th * colors
        let ctx = makeContext(W, H)
        fillBackground(ctx, CGRect(x: 0, y: 0, width: W, height: H), dark: dark)
        for ci in 0..<colors {
            for (si, s) in states.enumerated() {
                let m = JellyMotion(R: R, color: Palette.color(ci), state: s, seed: Double(ci * 7 + si) * 0.37 + 0.5)
                m.setState(s, immediate: true)
                // 終了状態は「動いていた状態から止まる」様子を再現するため、作業中から遷移させる
                if s.isTerminal {
                    m.setState(.working, immediate: true)
                    simulate(m, seconds: 2.0)
                    m.setState(s)
                    simulate(m, seconds: 10.0)
                } else {
                    simulate(m, seconds: 3.0 + Double(ci) * 0.37)
                }
                guard let img = render(m) else { continue }
                let y = H - (ci + 1) * th
                ctx.draw(img, in: CGRect(x: si * tw, y: y, width: tw, height: th))
            }
        }
        return write(ctx.makeImage()!, out)
    }

    // MARK: - strip（時間方向の連続コマ）

    static func strip(_ out: String, state: AgentState, color: Int, count: Int, interval: Double, drag: Bool, dark: Bool, scale: Double) -> Int32 {
        let m = JellyMotion(R: R, color: Palette.color(color), state: state, seed: 0.9)
        m.setState(state, immediate: true)
        let size = m.size
        let tw = Int(size.width * scale), th = Int(size.height * scale)
        let ctx = makeContext(tw * count, th)
        fillBackground(ctx, CGRect(x: 0, y: 0, width: tw * count, height: th), dark: dark)
        // ドラッグ試験：0.6 秒かけて右へ 120pt 動かし、その後止める
        let origin: (Double) -> CGPoint = { t in
            guard drag else { return .zero }
            let p = min(max((t - 2.0) / 0.6, 0), 1)
            return CGPoint(x: 120 * p * p * (3 - 2 * p), y: 0)
        }
        var t = 0.0
        simulate(m, seconds: 2.0, origin: origin)
        t = 2.0
        for i in 0..<count {
            guard let img = render(m, scale: scale) else { continue }
            ctx.draw(img, in: CGRect(x: i * tw, y: 0, width: tw, height: th))
            let end = t + interval
            while t < end {
                m.step(dt: 1.0 / 60.0, windowOrigin: origin(t))
                t += 1.0 / 60.0
            }
        }
        return write(ctx.makeImage()!, out)
    }

    // MARK: - pixel sheet（ドット絵のコマ一覧）

    static func pixelPoses() -> [(String, ClawdPose)] {
        var a: [(String, ClawdPose)] = []
        a.append(("idle", ClawdPose()))
        a.append(("blink", ClawdPose(eyes: .closed)))
        a.append(("glance", ClawdPose(eyes: .open(dx: 1, dy: -1))))
        a.append(("think1", ClawdPose(eyes: .open(dx: -1, dy: -1), mark: .dots(1))))
        a.append(("think3", ClawdPose(eyes: .open(dx: 1, dy: -1), mark: .dots(3))))
        a.append(("work1", ClawdPose(eyes: .open(dx: 0, dy: 1), arms: .leftUp, legs: .walkA)))
        a.append(("work2", ClawdPose(eyes: .open(dx: 0, dy: 1), arms: .rightUp, legs: .walkB)))
        a.append(("crouch", ClawdPose(arms: .down, legs: .crouch)))
        a.append(("hop", ClawdPose(arms: .rightUp, legs: .walkA, lift: 1)))
        a.append(("done", ClawdPose(eyes: .happy, mark: .check)))
        a.append(("error", ClawdPose(eyes: .cross, mark: .exclaim, tone: .error)))
        a.append(("cancel", ClawdPose(eyes: .closed, tone: .cancelled)))
        a.append(("drag", ClawdPose(eyes: .open(dx: 0, dy: 1), arms: .raised, legs: .dangle)))
        return a
    }

    static func pixelSheet(_ out: String, dark: Bool) -> Int32 {
        let poses = pixelPoses()
        let colorsN = 6
        let scale = 2.0
        let P = CGFloat(PixelAvatar.cell(scale: 1.0) * scale)       // 1 マスの px
        let tileW = Int(CGFloat(ClawdSprite.cols) * P), tileH = Int(CGFloat(ClawdSprite.rows + 1) * P)
        let W = tileW * poses.count, H = tileH * colorsN
        let ctx = makeContext(W, H)
        fillBackground(ctx, CGRect(x: 0, y: 0, width: W, height: H), dark: dark)
        ctx.interpolationQuality = .none
        for ci in 0..<colorsN {
            let jc = Palette.color(ci)
            let colors = ClawdColors.from(jc)
            for (i, (_, pose)) in poses.enumerated() {
                let img = ClawdSprite.image(pose, colors: colors, key: jc.key)
                let rect = CGRect(x: CGFloat(i * tileW), y: CGFloat(H - (ci + 1) * tileH) + P * 0.5,
                                  width: CGFloat(ClawdSprite.cols) * P, height: CGFloat(ClawdSprite.rows) * P)
                ctx.saveGState()
                let f = jc.flat
                ctx.setShadow(offset: .zero, blur: P * 0.9 * 2,
                              color: CGColor(srgbRed: CGFloat(f.x), green: CGFloat(f.y), blue: CGFloat(f.z), alpha: 0.55))
                ctx.draw(img, in: rect)
                ctx.restoreGState()
            }
        }
        return write(ctx.makeImage()!, out)
    }

    // MARK: - icon

    static func icon(_ out: String) -> Int32 {
        let S = 1024
        let ctx = makeContext(S, S)
        let inset: CGFloat = 100
        let rect = CGRect(x: inset, y: inset, width: CGFloat(S) - inset * 2, height: CGFloat(S) - inset * 2)
        let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        let g = CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colorComponents: [0.05, 0.13, 0.24, 1, 0.01, 0.03, 0.08, 1], locations: [0, 1], count: 2)!
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 512), endRadius: 560, options: [.drawsAfterEndLocation])
        // Claude キャラクターを大きく描く（ドット絵なので補間なし）
        let jc = Palette.color(0)
        let img = ClawdSprite.image(ClawdPose(), colors: ClawdColors.from(jc), key: jc.key)
        let P: CGFloat = 52
        let w = CGFloat(ClawdSprite.cols) * P, h = CGFloat(ClawdSprite.rows) * P
        ctx.interpolationQuality = .none
        ctx.setShadow(offset: .zero, blur: 70, color: CGColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.6))
        ctx.draw(img, in: CGRect(x: (CGFloat(S) - w) / 2, y: (CGFloat(S) - h) / 2 - P * 0.6, width: w, height: h))
        ctx.restoreGState()
        return write(ctx.makeImage()!, out)
    }

    // MARK: - settle test

    static func settleTest() -> Int32 {
        var ok = true
        for s in [AgentState.completed, .cancelled] {
            let m = JellyMotion(R: R, color: Palette.color(1), state: .working, seed: 0.4)
            m.setState(.working, immediate: true)
            simulate(m, seconds: 3)
            m.setState(s)
            var t = 0.0
            while !m.settled && t < 30 {
                m.step(dt: 1.0 / 60.0, windowOrigin: .zero)
                t += 1.0 / 60.0
            }
            print(String(format: "%@: %@ after %.2fs", s.rawValue, m.settled ? "settled" : "NOT settled", t))
            ok = ok && m.settled
            // 静止後に描画結果が変化しないことを確認（2 フレームの差分）
            if m.settled, let a = render(m) {
                m.step(dt: 1.0 / 60.0, windowOrigin: .zero)
                if let b = render(m) {
                    let diff = maxPixelDiff(a, b)
                    print("  frame diff after settle: \(diff)")
                    ok = ok && diff <= 2
                }
            }
        }
        for s in [AgentState.idle, .thinking, .working, .error] {
            let m = JellyMotion(R: R, color: Palette.color(0), state: s, seed: 0.4)
            m.setState(s, immediate: true)
            simulate(m, seconds: 5)
            print("\(s.rawValue): settled=\(m.settled) (expected false)")
            ok = ok && !m.settled
        }
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }

    static func maxPixelDiff(_ a: CGImage, _ b: CGImage) -> Int {
        guard let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return 999 }
        let pa = CFDataGetBytePtr(da)!, pb = CFDataGetBytePtr(db)!
        let n = min(CFDataGetLength(da), CFDataGetLength(db))
        var m = 0
        for i in 0..<n { m = max(m, abs(Int(pa[i]) - Int(pb[i]))) }
        return m
    }
}
