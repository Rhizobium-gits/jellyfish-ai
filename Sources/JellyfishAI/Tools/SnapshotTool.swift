import AppKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// ウィンドウを出さずにクラゲを PNG に描き出す開発用ツール。
///   --sheet out.png [--bg dark|light]        色 × 状態 の一覧
///   --strip out.png [--state s] [--color i] [--count n] [--interval sec] [--drag]
///   --icon out.png [--icon-source art.png]   アプリアイコン (1024px)。art を角丸の枠に収める（無ければクラゲのドット絵を描く）
///   --settle-test                            完了/キャンセルで本当に静止するかを検証
///   --account-menu out.png                   メニューのアカウントと使用量の欄（実際に claude から読む。明暗 2 つ並べる）
enum SnapshotTool {
    static func handles(_ args: [String]) -> Bool {
        args.contains("--sheet") || args.contains("--strip") || args.contains("--icon") || args.contains("--settle-test") || args.contains("--status-frames")
            || args.contains("--pixel-sheet") || args.contains("--account-menu") || args.contains("--chat-sample") || args.contains("--watch-bench")
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
        if let out = value("--icon") { return icon(out, source: value("--icon-source")) }
        if let out = value("--status-frames") { return statusFrames(out) }
        if let out = value("--account-menu") { return accountMenu(out) }
        if let out = value("--chat-sample") { return chatSample(out, dark: value("--bg") == "dark") }
        if let s = value("--watch-bench").flatMap(Double.init) {
            // 見守りの負担を測る：毎回読む場合と、変わったときだけ読む場合（どちらも Mac の中だけ・モデルは呼ばない）
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                print(await ScreenWatcher.bench(seconds: s, force: true))
                print(await ScreenWatcher.bench(seconds: s, force: false))
                sem.signal()
            }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            return 0
        }
        if args.contains("--settle-test") { return settleTest() }
        return 1
    }

    // MARK: - チャットの表示の見本（表・数式・図・コード）。画面の外の窓で描いて PNG に（モデルは呼ばない・前面に出さない）

    static func chatSample(_ out: String, dark: Bool) -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = NSRect(x: 0, y: 0, width: 760, height: 1900)
        let w = NSWindow(contentRect: size.offsetBy(dx: -6000, dy: -6000), styleMask: [.borderless], backing: .buffered, defer: false)
        let bg = NSVisualEffectView(frame: size)
        bg.material = .windowBackground
        bg.state = .active
        w.contentView = bg
        let v = ChatTranscriptView(frame: size)
        v.autoresizingMask = [.width, .height]
        bg.addSubview(v)
        w.orderFrontRegardless()
        let answer = """
        ## 四季の詩の比べ方

        | 季節 | 題 | 字数 | 評価 |
        |---|---|---:|:---:|
        | 春 | 霞の朝 | 31 | ★★★ |
        | 夏 | 蝉しぐれ | 28 | ★★☆ |
        | 秋 | 月の舟 | 33 | ★★★ |
        | 冬 | 雪明かり | 30 | ★★☆ |

        点数は $s = \\frac{1}{n}\\sum_{i=1}^{n} w_i x_i$ で、重みは $\\sum w_i = 1$ です。

        $$
        \\int_0^{2\\pi} \\sin^2\\theta\\,d\\theta = \\pi, \\qquad e^{i\\pi} + 1 = 0
        $$

        ```mermaid
        pie title 票の割合
          "春" : 34
          "夏" : 18
          "秋" : 31
          "冬" : 17
        ```

        ```mermaid
        xychart-beta
          title "季節ごとの点数"
          x-axis ["春", "夏", "秋", "冬"]
          y-axis "点数" 0 --> 100
          bar [82, 64, 88, 70]
          line [82, 64, 88, 70]
        ```

        ```mermaid
        flowchart LR
          A[依頼] --> B{分担する？}
          B -- はい --> C[仲間を作る]
          B -- いいえ --> D[一人で]
          C --> E[レビュー係が選ぶ]
        ```

        ```swift
        let best = poems.max { $0.score < $1.score }
        print(best?.title ?? "なし")
        ```

        値段の $5 と $10 は数式になりません。詳しくは [Mermaid の書き方](https://mermaid.js.org) を見てください。
        """
        let payload: [String: Any] = [
            "accent": "#D97757",
            "items": [
                ["id": "u", "kind": "user", "caption": L("あなた"), "captionStyle": "muted", "text": "四季の詩を比べて、表・数式・グラフで見せて"],
                ["id": "t", "kind": "tool", "text": "⚙︎ Bash: python3 score.py"],
                ["id": "a", "kind": "assistant", "caption": "Claude", "captionColor": "#D97757", "text": answer],
            ],
            "labels": ["copy": L("コピー"), "copied": L("コピーしました"), "diagramFailed": L("図にできませんでした（Mermaid の書き方を確かめてください）")],
        ]
        v.update(payload, scrollToEnd: false)
        let until = Date().addingTimeInterval(6)
        while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        var done = false
        var code: Int32 = 1
        v.web.takeSnapshot(with: nil) { img, err in
            if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                code = (try? png.write(to: URL(fileURLWithPath: out))) != nil ? 0 : 1
            } else {
                FileHandle.standardError.write(Data("snapshot failed: \(String(describing: err))\n".utf8))
            }
            done = true
        }
        let limit = Date().addingTimeInterval(10)
        while !done && Date() < limit { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        return code
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

    /// macOS のアイコンの枠（1024 の中に 824 の角丸）。この形なら macOS 26 でも灰色の枠に入れられず、縁の光と影はシステムが付ける
    static func icon(_ out: String, source: String? = nil) -> Int32 {
        let S = 1024
        let ctx = makeContext(S, S)
        let inset: CGFloat = 100
        let rect = CGRect(x: inset, y: inset, width: CGFloat(S) - inset * 2, height: CGFloat(S) - inset * 2)
        let path = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        if let source {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil),
                  let art = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                FileHandle.standardError.write("cannot read icon source: \(source)\n".data(using: .utf8)!)
                return 1
            }
            // 枠いっぱいに（縦横比を保って短い辺に合わせ、はみ出た分は切る）
            let k = max(rect.width / CGFloat(art.width), rect.height / CGFloat(art.height))
            let w = CGFloat(art.width) * k, h = CGFloat(art.height) * k
            ctx.interpolationQuality = .high
            ctx.draw(art, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            ctx.restoreGState()
            return write(ctx.makeImage()!, out)
        }
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

    // MARK: - account menu

    static func accountMenu(_ out: String) -> Int32 {
        let (snap, _) = ClaudeAccount.fetch(override: nil, skipUsageFor: nil)
        print("limits: \(snap.limits.map { "\($0.label) \($0.percent)%" }.joined(separator: ", "))  note: \(snap.note ?? "-")  plan: \(snap.account?.plan ?? "-")")
        let w = AccountMenu.width, pad: CGFloat = 8, gap: CGFloat = 20
        var panels: [NSBitmapImageRep] = []
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            // 実際のメニューと同じく、縦に積んだビューを AppKit に描かせる（isFlipped の文字の向きもそのまま）
            let views = AccountMenu.items(snap, loading: false).compactMap(\.view)
            let h = views.reduce(0) { $0 + $1.frame.height } + pad * 2
            let panel = NSBox(frame: NSRect(x: 0, y: 0, width: w, height: h))
            panel.boxType = .custom
            panel.borderWidth = 0
            panel.cornerRadius = 10
            panel.fillColor = .windowBackgroundColor
            panel.contentViewMargins = .zero
            panel.appearance = NSAppearance(named: name)
            var y = h - pad
            for v in views {
                y -= v.frame.height
                v.frame = NSRect(x: 0, y: y, width: w, height: v.frame.height)
                panel.addSubview(v)
            }
            guard let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) else { return 1 }
            panel.cacheDisplay(in: panel.bounds, to: rep)
            panels.append(rep)
        }
        let W = panels.reduce(0) { $0 + $1.pixelsWide } + Int(gap * 2)
        let H = panels.map(\.pixelsHigh).max() ?? 0
        let ctx = makeContext(W, H)
        var x = 0
        for p in panels {
            if let cg = p.cgImage { ctx.draw(cg, in: CGRect(x: x, y: H - p.pixelsHigh, width: p.pixelsWide, height: p.pixelsHigh)) }
            x += p.pixelsWide + Int(gap * 2)
        }
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

    /// メニューバーのアイコンのコマを並べた画像（確認用）
    static func statusFrames(_ out: String) -> Int32 {
        typealias P = MenuImages.StatusPose
        let poses: [P] = [P(), P(lift: 1), P(blink: true), P(dots: 1), P(dots: 2), P(dots: 3),
                          P(lift: 1, legs: 1, arms: true), P(legs: 2)]
        let scale: CGFloat = 4, cell: CGFloat = 18 * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell) * poses.count, pixelsHigh: Int(cell) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, bg) in [NSColor(white: 0.93, alpha: 1), NSColor(white: 0.15, alpha: 1)].enumerated() {
            bg.setFill()
            NSRect(x: 0, y: CGFloat(row) * cell, width: cell * CGFloat(poses.count), height: cell).fill()
            for (i, p) in poses.enumerated() {
                let img = MenuImages.statusFrame(p).copy() as! NSImage
                img.isTemplate = false
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r)
                    (row == 0 ? NSColor.black : NSColor.white).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: CGFloat(i) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
        return 0
    }
}
