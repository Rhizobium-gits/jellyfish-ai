import Foundation
import Testing
@testable import JellyfishAI

// 使っている途中でアプリが落ちないためのテスト（1.2.1）

@Suite struct SafeNumberTests {
    /// Int(…) は NaN・無限大・範囲外で落ちる。AI から届いた数（クリック回数・スクロール量）でも落ちないこと
    @Test func clampsInsteadOfTrapping() {
        #expect(SafeNumber.int(2.9, in: 1...3) == 2)
        #expect(SafeNumber.int(0, in: 1...3) == 1)
        #expect(SafeNumber.int(1e300, in: 1...3) == 3)
        #expect(SafeNumber.int(-1e300, in: 1...3) == 1)
        #expect(SafeNumber.int(Double.infinity, in: -10_000...10_000) == 10_000)
        #expect(SafeNumber.int(-Double.infinity, in: -10_000...10_000) == -10_000)
        #expect(SafeNumber.int(Double.nan, in: 1...3) == 1)
        #expect(SafeNumber.int(Double.nan) == 0)
        #expect(SafeNumber.int(Double(Int.max)) == 1_000_000_000)
        #expect(SafeNumber.int(CGFloat(-12.7)) == -12)
        // スクロール量は Int32 に入る範囲になる
        let dy = SafeNumber.int(1e10, in: -10_000...10_000)
        #expect(Int32(exactly: dy) != nil)
    }
}

@Suite struct DespawnSourceTests {
    /// 消したクラゲの透明な窓が残る不具合（1.2.0 まで）：消える動きの終わりを弱い参照で待っていたので、
    /// 一覧から外した時点でクラゲが消え、窓を閉じる処理が走らなかった。実機では 2 体消して窓が残らないことを確かめた。
    /// ここでは、強く持つ・必ず閉じる・クリックを素通りさせる、の 3 つがコードから消えていないことを確かめる
    @Test func despawnAlwaysClosesWindow() throws {
        let here = URL(fileURLWithPath: #filePath)
        let src = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/JellyfishAI/Jelly/JellyController.swift")
        let s = try String(contentsOf: src, encoding: .utf8)
        let start = try #require(s.range(of: "func despawn("))
        let body = String(s[start.lowerBound...].prefix(1400))
        #expect(body.contains("panel.ignoresMouseEvents = true"))
        #expect(!body.contains("[weak self] in\n            self?.close()"))
        #expect(body.contains("asyncAfter"))
        #expect(body.contains("close()"))
    }
}
