import Foundation
import Security
import Testing
@testable import JellyfishAI

// 固定の署名（scripts/signing.sh の自己署名）で入れた版でも、アプリの「アップデートする」で上げられること（1.2.2）。
// 1.2.1 までは、いまの版が証明書で署名されていると「同じ証明書の署名の版」しか受け付けず、
// 配布版（仮の署名）はこの Mac の証明書で署名されることがないので、いつも「いまの版と署名が違います（-67050）」で止まっていた

@Suite struct UpdateSigningTests {
    @Test func readsIdentityList() {
        let out = """
        Policy: Code Signing
          Matching identities
          1) 4C1CE39E06751DF5ADC4E7E84A2FC308F6231900 "Jellyfish AI Local Signing" (CSSMERR_TP_NOT_TRUSTED)
             1 identities found

          Valid identities only
             0 valid identities found
        """
        #expect(AppUpdater.identityList(out, contains: "4c1ce39e06751df5adc4e7e84a2fc308f6231900"))
        #expect(!AppUpdater.identityList(out, contains: "0000000000000000000000000000000000000000"))
        // 名前や途中の一部では見つけたことにしない
        #expect(!AppUpdater.identityList(out, contains: "Jellyfish AI Local Signing"))
        #expect(!AppUpdater.identityList(out, contains: "4C1CE39E06751DF5ADC4"))
        #expect(!AppUpdater.identityList("", contains: "4c1ce39e06751df5adc4e7e84a2fc308f6231900"))
    }

    @Test func resignsLikeBuildScript() {
        let app = URL(fileURLWithPath: "/tmp/x/JellyfishAI.app")
        let args = AppUpdater.resignArguments(app, sha1: "4c1ce39e06751df5adc4e7e84a2fc308f6231900")
        // 証明書は SHA-1 で指定（名前が同じ別の証明書を使わない）・Hardened Runtime・エンタイトルメントは配布版のまま・時刻サーバーに問い合わせない
        #expect(args == ["--force", "--sign", "4C1CE39E06751DF5ADC4E7E84A2FC308F6231900", "--options", "runtime",
                         "--preserve-metadata=entitlements", "--timestamp=none", "/tmp/x/JellyfishAI.app"])
    }

    @Test func unsignedIsRefused() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent("jf-sig-\(UUID().uuidString)/JellyfishAI.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(AppUpdater.signingStep(new: app, current: app).isRefuse)
        #expect(!AppUpdater.satisfiesCurrent(new: app, current: app))
    }

    /// 実際に証明書で署名して確かめる（キーチェーンの検索リストにある、署名用の鍵の SHA-1 を
    /// JELLYFISH_SIGNING_TEST_IDENTITY に、仮の署名のアプリを JELLYFISH_SIGNING_TEST_APP に入れたときだけ）。
    /// 認証局の証明書の鎖で署名する鍵を JELLYFISH_SIGNING_TEST_ISSUED_IDENTITY に入れると、そちらは入れ替えないことも確かめる
    @Test(.enabled(if: ProcessInfo.processInfo.environment["JELLYFISH_SIGNING_TEST_IDENTITY"] != nil))
    func resignsReleaseForFixedSigning() throws {
        let env = ProcessInfo.processInfo.environment
        let sha1 = try #require(env["JELLYFISH_SIGNING_TEST_IDENTITY"]).lowercased()
        let source = URL(fileURLWithPath: try #require(env["JELLYFISH_SIGNING_TEST_APP"]))
        #expect(AppUpdater.isAdhoc(source))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jf-resign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        func copy(_ name: String) throws -> URL {
            let to = dir.appendingPathComponent(name).appendingPathComponent("JellyfishAI.app")
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try run("/usr/bin/ditto", [source.path, to.path])
            return to
        }
        let current = try copy("current"), release = try copy("release")

        // 仮の署名どうし：そのまま
        #expect(AppUpdater.currentSigning(current) == .adhoc)
        #expect(AppUpdater.signingStep(new: release, current: current) == .keep)

        // いまの版を固定の署名にする（scripts/build.sh --sign と同じ形）
        try run("/usr/bin/codesign", AppUpdater.resignArguments(current, sha1: sha1))
        let cert = try #require(AppUpdater.selfSignedCertificate(current))
        #expect(cert.sha1 == sha1)
        #expect(AppUpdater.currentSigning(current) == .local(name: cert.name, hasKey: true))
        #expect(AppUpdater.currentSigning(current, hasKey: { _ in false }) == .local(name: cert.name, hasKey: false))

        // 1.2.1 まではここで止まっていた（配布版はいまの版の署名の決まりを満たさない）
        #expect(!AppUpdater.satisfiesCurrent(new: release, current: current))
        // 鍵があれば署名し直す・無ければ配布版の署名のまま
        #expect(AppUpdater.signingStep(new: release, current: current) == .resign(sha1: sha1))
        #expect(AppUpdater.signingStep(new: release, current: current, hasKey: { _ in false }) == .releaseSignature)

        // 署名し直すと、いまの版と同じ証明書の署名になり（macOS の許可が続く）、エンタイトルメントと Hardened Runtime も残る
        let entitlementsBefore = try signingInfo(release)[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        try run("/usr/bin/codesign", AppUpdater.resignArguments(release, sha1: sha1))
        #expect(AppUpdater.satisfiesCurrent(new: release, current: current))
        #expect(AppUpdater.signingStep(new: release, current: current) == .keep)
        let info = try signingInfo(release)
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        #expect(flags & SecCodeSignatureFlags.runtime.rawValue != 0)
        #expect(flags & SecCodeSignatureFlags.adhoc.rawValue == 0)
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        #expect(entitlements?["com.apple.security.automation.apple-events"] as? Bool == true)
        #expect(entitlements?.keys.sorted() == entitlementsBefore?.keys.sorted())

        // 署名し直したあとで中身を書き換えたものは通さない
        let tampered = try copy("tampered")
        try run("/usr/bin/codesign", AppUpdater.resignArguments(tampered, sha1: sha1))
        try Data("x".utf8).write(to: tampered.appendingPathComponent("Contents/Resources/update.sh"))
        #expect(AppUpdater.signingStep(new: tampered, current: current).isRefuse)
        #expect(!AppUpdater.satisfiesCurrent(new: tampered, current: current))

        // 認証局の証明書（Developer ID など）で署名された版からは、別の署名の版に入れ替えない
        if let issued = env["JELLYFISH_SIGNING_TEST_ISSUED_IDENTITY"] {
            let byCA = try copy("issued")
            try run("/usr/bin/codesign", AppUpdater.resignArguments(byCA, sha1: issued))
            #expect(AppUpdater.selfSignedCertificate(byCA) == nil)
            #expect(AppUpdater.currentSigning(byCA) == .issued)
            let fresh = try copy("fresh")
            #expect(AppUpdater.signingStep(new: fresh, current: byCA).isRefuse)
            #expect(AppUpdater.signingStep(new: release, current: byCA).isRefuse)
        }
    }

    private func signingInfo(_ app: URL) throws -> [String: Any] {
        let code = try #require(AppUpdater.staticCode(app))
        var info: CFDictionary?
        #expect(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess)
        return try #require(info as? [String: Any])
    }

    private func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "\(path) \(args.joined(separator: " "))")
    }
}
