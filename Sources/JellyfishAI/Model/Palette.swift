import Foundation
import simd

/// クラゲ1体の固有色。
///   flat = ドット絵キャラクターの体色（1体目は Claude のオレンジ #D97757）
///   base / deep = リアルなクラゲの発光色と縁の濃い色
struct JellyColor {
    let key: String
    let name: String
    let flat: SIMD3<Float>
    let base: SIMD3<Float>
    let deep: SIMD3<Float>
}

enum Palette {
    /// 生成順に割り当てる固定色。赤系はエラー表示用に予約しているので使わない。
    static let named: [JellyColor] = [
        JellyColor(key: "orange", name: "オレンジ", flat: [0.851, 0.467, 0.341], base: [1.00, 0.56, 0.20], deep: [0.86, 0.30, 0.04]),
        JellyColor(key: "blue",   name: "ブルー", flat: [0.357, 0.553, 0.937],   base: [0.32, 0.64, 1.00], deep: [0.08, 0.30, 0.86]),
        JellyColor(key: "purple", name: "パープル", flat: [0.616, 0.482, 0.918], base: [0.68, 0.48, 1.00], deep: [0.40, 0.16, 0.84]),
        JellyColor(key: "green",  name: "グリーン", flat: [0.298, 0.718, 0.510], base: [0.32, 0.92, 0.58], deep: [0.04, 0.56, 0.30]),
        JellyColor(key: "pink",   name: "ピンク", flat: [0.890, 0.478, 0.698],   base: [1.00, 0.48, 0.76], deep: [0.86, 0.14, 0.50]),
        JellyColor(key: "yellow", name: "イエロー", flat: [0.886, 0.698, 0.227], base: [1.00, 0.86, 0.30], deep: [0.80, 0.56, 0.02]),
        JellyColor(key: "cyan",   name: "シアン", flat: [0.239, 0.710, 0.784],   base: [0.30, 0.90, 0.96], deep: [0.02, 0.52, 0.66]),
        JellyColor(key: "lime",   name: "ライム", flat: [0.576, 0.761, 0.290],   base: [0.72, 0.96, 0.32], deep: [0.40, 0.64, 0.04]),
        JellyColor(key: "indigo", name: "インディゴ", flat: [0.431, 0.455, 0.902], base: [0.50, 0.54, 1.00], deep: [0.20, 0.22, 0.80]),
        JellyColor(key: "amber",  name: "アンバー", flat: [0.890, 0.600, 0.290], base: [1.00, 0.72, 0.36], deep: [0.78, 0.42, 0.06]),
    ]

    /// index が固定色の数を超えたら、黄金角で色相を回して生成する（赤の帯は避ける）。
    static func color(_ index: Int) -> JellyColor {
        if index < named.count { return named[index] }
        let n = index - named.count
        var hue = (40.0 + Double(n) * 137.508).truncatingRemainder(dividingBy: 360.0)
        // 赤（エラー色）近辺 340°〜20° を避ける
        if hue > 330 || hue < 25 { hue = (hue + 60).truncatingRemainder(dividingBy: 360) }
        let base = hsv(hue, 0.62, 1.0)
        let deep = hsv(hue, 0.92, 0.82)
        let flat = hsv(hue, 0.60, 0.88)
        return JellyColor(key: "hue\(Int(hue))", name: "カラー\(index + 1)", flat: flat, base: base, deep: deep)
    }

    private static func hsv(_ h: Double, _ s: Double, _ v: Double) -> SIMD3<Float> {
        let c = v * s
        let hp = h / 60.0
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var rgb: (Double, Double, Double)
        switch hp {
        case 0..<1: rgb = (c, x, 0)
        case 1..<2: rgb = (x, c, 0)
        case 2..<3: rgb = (0, c, x)
        case 3..<4: rgb = (0, x, c)
        case 4..<5: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        let m = v - c
        return [Float(rgb.0 + m), Float(rgb.1 + m), Float(rgb.2 + m)]
    }
}
