import Foundation

/// 小数を整数にする。Swift の Int(…) は NaN・無限大・範囲外の値でアプリごと落ちるので、
/// AI から届いた数（PC 操作のクリック回数・スクロール量など）や、ほかのアプリ・ファイルから読んだ数はこれで直す
enum SafeNumber {
    /// 範囲に収めた整数（小数点以下は切り捨て）。NaN は nan の値（範囲に収めたもの）、+∞ / −∞ は範囲の端
    static func int<F: BinaryFloatingPoint>(_ v: F, in r: ClosedRange<Int> = -1_000_000_000...1_000_000_000, nan: Int = 0) -> Int {
        let d = Double(v)
        if d.isNaN { return min(max(nan, r.lowerBound), r.upperBound) }
        if d >= Double(r.upperBound) { return r.upperBound }
        if d <= Double(r.lowerBound) { return r.lowerBound }
        return Int(d)
    }
}
