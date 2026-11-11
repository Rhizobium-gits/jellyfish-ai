import CoreGraphics
import Foundation

/// Claude Code のマスコット（Claude 公式の clawd.svg と同じ 11×8 のドット絵）を、
/// 表情・手足のポーズ違いで描き分ける。
///
/// 基本形（clawd.svg から読み取ったもの。# = 体、E = 目）
///     .#########.
///     .#########.
///     ##E#####E##     ← 左右の端が腕
///     ###########
///     .#########.
///     .#########.
///     .#.#...#.#.     ← 4 本の脚
///     .#.#...#.#.
///
/// キャンバスは 15×12 マス（上 3 マスは「…」「!」「✓」などの表示用、左右 2 マスは腕の余白）。
/// 1 マスを 2×2 のサブピクセルで描くので、目だけは半マス単位で動かせる。
struct ClawdPose: Hashable {
    enum Eyes: Hashable { case open(dx: Int, dy: Int), closed, happy, cross }
    enum Arms: Hashable { case normal, up, down, leftUp, rightUp, raised }
    enum Legs: Hashable { case stand, walkA, walkB, crouch, dangle }
    enum Mark: Hashable { case none, dots(Int), exclaim, check }
    enum Tone: Hashable { case normal, error, cancelled }

    var eyes: Eyes = .open(dx: 0, dy: 0)
    var arms: Arms = .normal
    var legs: Legs = .stand
    var mark: Mark = .none
    var tone: Tone = .normal
    /// 体を何マス持ち上げるか（ぴょんと跳ねるコマ）
    var lift: Int = 0
}

struct ClawdColors {
    let body: CGColor
    let eye: CGColor
    let mark: CGColor

    static func from(_ c: JellyColor) -> ClawdColors {
        let b = c.flat
        return ClawdColors(body: CGColor(srgbRed: CGFloat(b.x), green: CGFloat(b.y), blue: CGFloat(b.z), alpha: 1),
                           eye: CGColor(srgbRed: 0.09, green: 0.07, blue: 0.06, alpha: 1),
                           mark: CGColor(srgbRed: CGFloat(b.x), green: CGFloat(b.y), blue: CGFloat(b.z), alpha: 1))
    }

    static let errorBody = CGColor(srgbRed: 0.90, green: 0.33, blue: 0.30, alpha: 1)
    static let cancelledBody = CGColor(srgbRed: 0.56, green: 0.55, blue: 0.54, alpha: 1)
    static let warn = CGColor(srgbRed: 1.00, green: 0.78, blue: 0.27, alpha: 1)
}

enum ClawdSprite {
    static let cols = 15
    static let rows = 12
    static let sub = 2                       // 1 マス = 2×2 サブピクセル
    static let origin = (x: 2, y: 3)         // スプライト左上のマス
    static var pixelWidth: Int { cols * sub }
    static var pixelHeight: Int { rows * sub }

    private static var cache: [String: CGImage] = [:]

    static func image(_ pose: ClawdPose, colors: ClawdColors, key: String) -> CGImage {
        let k = "\(key)|\(pose.hashValue)"
        if let img = cache[k] { return img }
        let img = draw(pose, colors: colors)
        if cache.count > 400 { cache.removeAll() }
        cache[k] = img
        return img
    }

    private static func draw(_ pose: ClawdPose, colors: ClawdColors) -> CGImage {
        let W = pixelWidth, H = pixelHeight
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)

        // サブピクセル (x, y) を塗る（y は上から）
        func px(_ x: Int, _ y: Int, _ c: CGColor) {
            guard x >= 0, y >= 0, x < W, y < H else { return }
            ctx.setFillColor(c)
            ctx.fill(CGRect(x: x, y: H - 1 - y, width: 1, height: 1))
        }
        // マス (cx, cy) を塗る（キャンバス座標）
        func cell(_ cx: Int, _ cy: Int, _ c: CGColor) {
            for dx in 0..<sub { for dy in 0..<sub { px(cx * sub + dx, cy * sub + dy, c) } }
        }

        let body: CGColor
        switch pose.tone {
        case .normal: body = colors.body
        case .error: body = ClawdColors.errorBody
        case .cancelled: body = ClawdColors.cancelledBody
        }

        let crouch = pose.legs == .crouch
        let ox = origin.x
        let oy = origin.y - pose.lift + (crouch ? 1 : 0)

        // 体（6 段 × 9 列）。しゃがむときは 1 段下がり、脚が短くなる
        for r in 0..<6 { for c in 1...9 { cell(ox + c, oy + r, body) } }

        // 腕（左 = 列 0、右 = 列 10）
        let armRows: (left: [Int], right: [Int])
        switch pose.arms {
        case .normal: armRows = ([2, 3], [2, 3])
        case .up: armRows = ([1, 2], [1, 2])
        case .down: armRows = ([3, 4], [3, 4])
        case .leftUp: armRows = ([1, 2], [3, 4])
        case .rightUp: armRows = ([3, 4], [1, 2])
        case .raised: armRows = ([1, 2], [1, 2])
        }
        for r in armRows.left { cell(ox + 0, oy + r, body) }
        for r in armRows.right { cell(ox + 10, oy + r, body) }
        if pose.arms == .raised {
            cell(ox - 1, oy + 0, body)
            cell(ox + 11, oy + 0, body)
        }

        // 脚（列 1, 3, 7, 9）
        let legCols = [1, 3, 7, 9]
        let lengths: [Int]
        switch pose.legs {
        case .stand: lengths = [2, 2, 2, 2]
        case .walkA: lengths = [2, 1, 2, 1]
        case .walkB: lengths = [1, 2, 1, 2]
        case .crouch: lengths = [1, 1, 1, 1]
        case .dangle: lengths = [3, 3, 3, 3]
        }
        for (i, c) in legCols.enumerated() {
            for r in 0..<lengths[i] { cell(ox + c, oy + 6 + r, body) }
        }

        // 目（マス (2,2) と (8,2)）
        let eyeY = (oy + 2) * sub
        let lx = (ox + 2) * sub, rx = (ox + 8) * sub
        let e = colors.eye
        switch pose.eyes {
        case .open(let dx, let dy):
            for x in [lx, rx] {
                for i in 0..<2 { for j in 0..<2 { px(x + dx + i, eyeY + dy + j, e) } }
            }
        case .closed:
            for x in [lx, rx] { px(x, eyeY + 1, e); px(x + 1, eyeY + 1, e) }
        case .happy:
            // ^ ^（3 サブピクセル幅。左右対称になるよう外側へ半マスずらす）
            for (x, s) in [(lx - 1, 0), (rx, 0)] {
                _ = s
                px(x, eyeY + 1, e); px(x + 1, eyeY, e); px(x + 2, eyeY + 1, e)
            }
        case .cross:
            for x in [lx - 1, rx] {
                px(x, eyeY - 1, e); px(x + 2, eyeY - 1, e)
                px(x + 1, eyeY, e)
                px(x, eyeY + 1, e); px(x + 2, eyeY + 1, e)
            }
        }

        // 頭上の表示（キャンバス上 3 マス）
        switch pose.mark {
        case .none: break
        case .dots(let n):
            for i in 0..<min(n, 3) { cell(5 + i * 2, 1, colors.mark) }
        case .exclaim:
            let x = 12 * sub + 1
            for y in 0..<3 { px(x, y, ClawdColors.warn); px(x + 1, y, ClawdColors.warn) }
            px(x, 4, ClawdColors.warn); px(x + 1, 4, ClawdColors.warn)
            px(x, 5, ClawdColors.warn); px(x + 1, 5, ClawdColors.warn)
        case .check:
            let pts = [(23, 3), (24, 4), (25, 5), (26, 4), (27, 3), (28, 2), (29, 1)]
            for (x, y) in pts { px(x, y, colors.mark) }
        }

        return ctx.makeImage()!
    }
}
