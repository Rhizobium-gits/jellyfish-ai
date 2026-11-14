import AppKit
import CryptoKit
import Security

/// アップデート：ユーザーが許可したときだけ、GitHub のリリースから新しい版を取ってきて、確かめてから入れ替え、開き直す。
/// 取りに行くのはこのリポジトリのリリースのファイル（github.com/<repo>/releases/download/<tag>/）だけ。
/// 入れ替える前に確かめること：
/// - SHA256SUMS.txt のチェックサムと合うか（壊れていないか）
/// - 中身が Jellyfish AI（同じバンドル ID）で、リリースの番号のとおりの新しい版か
/// - コード署名が正しいか（Security フレームワーク）。いまの版が証明書で署名されていれば、同じ証明書の署名か
/// 作業中のクラゲがいるとき・アプリの場所に書けないときは入れ替えない（ダウンロードページを案内する）。
/// macOS がアプリの入れ替えを止めたら（アプリ管理）、その設定を案内するだけで回り道はしない
enum AppUpdater {
    struct Release: Equatable {
        let tag: String
        let version: String
        let zip: URL
        let zipName: String
        let sums: URL
        let notes: String
    }

    static var downloadPrefix: String { "https://github.com/\(AppInfo.repo)/releases/download/" }
    static let maxZipBytes = 300_000_000

    /// releases/latest の JSON から、入れ替えに使うファイルを選ぶ（このリポジトリのこのリリースのものだけ）
    static func release(from json: [String: Any]) -> Release? {
        guard let tag = json["tag_name"] as? String,
              tag.range(of: #"^v?[0-9]+(\.[0-9]+){1,3}$"#, options: .regularExpression) != nil else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ name: String) -> URL? {
            guard let a = assets.first(where: { $0["name"] as? String == name }),
                  let s = a["browser_download_url"] as? String,
                  s == downloadPrefix + tag + "/" + name,
                  let u = URL(string: s), u.scheme == "https", u.host == "github.com" else { return nil }
            return u
        }
        let zipName = "JellyfishAI-\(version).zip"
        guard let zip = asset(zipName), let sums = asset("SHA256SUMS.txt") else { return nil }
        return Release(tag: tag, version: version, zip: zip, zipName: zipName, sums: sums, notes: json["body"] as? String ?? "")
    }

    /// SHA256SUMS.txt（shasum -a 256 の出力）から、そのファイルのチェックサムを読む
    static func checksum(in sums: String, for name: String) -> String? {
        for line in sums.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            var file = String(parts[1])
            if file.hasPrefix("*") { file.removeFirst() }
            let h = parts[0].lowercased()
            if file == name, h.count == 64, h.allSatisfy(\.isHexDigit) { return h }
        }
        return nil
    }

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { hasher.update(data: d) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 入れ替え先（いま動いているアプリ）に書けるか。だめなら理由
    static func locationProblem(_ app: URL = Bundle.main.bundleURL) -> String? {
        guard app.pathExtension == "app" else { return L("アプリとして動いていません（開発中のビルド）。") }
        let parent = app.deletingLastPathComponent()
        let readOnly = (try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
        let fm = FileManager.default
        if readOnly || app.path.contains("/AppTranslocation/") || !fm.isWritableFile(atPath: parent.path) || !fm.isWritableFile(atPath: app.path) {
            return L("このアプリは書き換えられない場所（%@）から開かれています。アプリケーションフォルダに入れてから開き直すか、ダウンロードページから入れ直してください。", parent.path)
        }
        return nil
    }

    /// 取ってきたアプリが、Jellyfish AI のその版か
    static func bundleProblem(_ app: URL, version: String, bundleID: String?) -> String? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            return L("アプリの情報（Info.plist）を読めません。")
        }
        guard let bundleID, info["CFBundleIdentifier"] as? String == bundleID else { return L("中身が Jellyfish AI ではありません。") }
        guard info["CFBundleShortVersionString"] as? String == version else { return L("中身のバージョンがリリースと合いません。") }
        return nil
    }

    static func staticCode(_ url: URL) -> SecStaticCode? {
        var c: SecStaticCode?
        return SecStaticCodeCreateWithPath(url as CFURL, [], &c) == errSecSuccess ? c : nil
    }

    /// 仮の署名（ad-hoc）か。そうなら、入れ替えると macOS の許可を求め直されることがある
    static func isAdhoc(_ url: URL) -> Bool {
        guard let code = staticCode(url) else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let d = info as? [String: Any] else { return true }
        let flags = (d[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || d[kSecCodeInfoCertificates as String] == nil
    }

    static let validityFlags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode))

    static func designatedRequirement(_ url: URL) -> SecRequirement? {
        guard let code = staticCode(url) else { return nil }
        var r: SecRequirement?
        return SecCodeCopyDesignatedRequirement(code, [], &r) == errSecSuccess ? r : nil
    }

    /// 証明書 1 枚だけで署名され、その証明書が自己署名（発行者 = 主体）なら、その SHA-1（小文字の 16 進）と名前。
    /// scripts/signing.sh の「固定の署名」（この Mac で作った証明書）がこれ。Developer ID など認証局が出したもの（鎖が 2 枚以上）は nil
    static func selfSignedCertificate(_ url: URL) -> (sha1: String, name: String)? {
        guard let code = staticCode(url) else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let d = info as? [String: Any],
              let certs = d[kSecCodeInfoCertificates as String] as? [SecCertificate], certs.count == 1,
              let issuer = SecCertificateCopyNormalizedIssuerSequence(certs[0]) as Data?,
              let subject = SecCertificateCopyNormalizedSubjectSequence(certs[0]) as Data?,
              issuer == subject else { return nil }
        let der = SecCertificateCopyData(certs[0]) as Data
        let sha1 = Insecure.SHA1.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return (sha1, (SecCertificateCopySubjectSummary(certs[0]) as String?) ?? "")
    }

    /// その証明書の署名用の鍵がキーチェーンにあるか。security find-identity は一覧を出すだけで鍵は使わない（macOS の確認は出ない）
    static func hasSigningIdentity(sha1: String) -> Bool {
        guard let out = capture("/usr/bin/security", ["find-identity", "-p", "codesigning"], timeout: 15) else { return false }
        return identityList(out, contains: sha1)
    }

    /// security find-identity の出力（「  1) <40 桁の 16 進> "名前"」の行）に、その SHA-1 があるか
    static func identityList(_ out: String, contains sha1: String) -> Bool {
        let want = sha1.uppercased()
        guard want.count == 40, want.allSatisfy(\.isHexDigit) else { return false }
        return out.split(whereSeparator: \.isNewline).contains { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count >= 2 && parts[0].hasSuffix(")") && parts[1].uppercased() == want
        }
    }

    private static func capture(_ path: String, _ args: [String], timeout: Double) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    /// いまの版の署名（アップデートの説明に使う）
    enum CurrentSigning: Equatable {
        case adhoc
        /// この Mac で作った自己署名の証明書（固定の署名）。hasKey：署名用の鍵がキーチェーンにあるか
        case local(name: String, hasKey: Bool)
        /// 認証局が出した証明書（Developer ID など）
        case issued
    }

    static func currentSigning(_ app: URL = Bundle.main.bundleURL, hasKey: (String) -> Bool = { hasSigningIdentity(sha1: $0) }) -> CurrentSigning {
        if isAdhoc(app) { return .adhoc }
        guard let c = selfSignedCertificate(app) else { return .issued }
        return .local(name: c.name, hasKey: hasKey(c.sha1))
    }

    /// 取ってきた版を入れ替える前にすること
    enum SigningStep: Equatable {
        /// そのまま入れ替える（いまの版が仮の署名、または同じ証明書の署名）
        case keep
        /// いまの版が固定の署名：配布版はその証明書で署名されることがないので、この Mac の鍵で署名し直してから入れ替える（macOS の許可が続く）
        case resign(sha1: String)
        /// 固定の署名だが鍵がこの Mac に無い：配布版の署名のまま入れ替える（macOS の許可は求め直される）
        case releaseSignature
        case refuse(String)

        var isRefuse: Bool { if case .refuse = self { return true }; return false }
    }

    /// 署名が正しいか（中身が書き換えられていないか）を確かめ、入れ替える前にすることを決める。
    /// 認証局の証明書（Developer ID など）で署名された版からは、同じ人の署名の版にしか入れ替えない
    static func signingStep(new: URL, current: URL, hasKey: (String) -> Bool = { hasSigningIdentity(sha1: $0) }) -> SigningStep {
        guard let code = staticCode(new) else { return .refuse(L("署名を読めません。")) }
        let own = SecStaticCodeCheckValidity(code, validityFlags, nil)
        guard own == errSecSuccess else { return .refuse(L("署名が正しくありません（%ld）。", Int(own))) }
        if isAdhoc(current) { return .keep }
        guard let req = designatedRequirement(current) else { return .refuse(L("いまの版の署名を読めません。")) }
        let st = SecStaticCodeCheckValidity(code, validityFlags, req)
        if st == errSecSuccess { return .keep }
        if let c = selfSignedCertificate(current) { return hasKey(c.sha1) ? .resign(sha1: c.sha1) : .releaseSignature }
        return .refuse(L("いまの版と署名が違います（%ld）。作った人が同じことを確かめられないので入れ替えません。ダウンロードページから入れ直してください。", Int(st)))
    }

    /// 固定の署名で署名し直す codesign の引数（scripts/build.sh --sign と同じ形。エンタイトルメントは配布版の署名のものをそのまま使う）。
    /// 鍵は「常に許可」にしていなければ、macOS が「codesign がキーを使おうとしています」と確かめる
    static func resignArguments(_ app: URL, sha1: String) -> [String] {
        ["--force", "--sign", sha1.uppercased(), "--options", "runtime", "--preserve-metadata=entitlements", "--timestamp=none", app.path]
    }

    /// 署名し直した版が、いまの版の署名の決まり（同じ証明書・同じバンドル ID）を満たし、中身も正しいか
    static func satisfiesCurrent(new: URL, current: URL) -> Bool {
        guard let code = staticCode(new), let req = designatedRequirement(current) else { return false }
        return SecStaticCodeCheckValidity(code, validityFlags, req) == errSecSuccess
    }
}

/// scripts/install.sh が覚えたソースのフォルダ（データフォルダの source-checkout）。
/// そのフォルダのスクリプトをターミナルで動かすので、次をすべて満たすときだけ使う：
/// git の checkout（.git がフォルダ）で取り込み元がこのリポジトリ、フォルダとスクリプトが自分のもので、ほかの人が書き換えられない
enum SourceCheckout {
    static func validated(dataDir: URL = AppPaths.dataDir, needs scripts: [String] = ["update.sh"]) -> String? {
        guard let raw = try? String(contentsOf: dataDir.appendingPathComponent("source-checkout"), encoding: .utf8) else { return nil }
        let dir = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard dir.hasPrefix("/"), !dir.contains("\n"),
              fm.fileExists(atPath: dir + "/.git", isDirectory: &isDir), isDir.boolValue,
              let config = try? String(contentsOfFile: dir + "/.git/config", encoding: .utf8),
              config.contains("github.com/\(AppInfo.repo)") || config.contains("github.com:\(AppInfo.repo)") else { return nil }
        func mine(_ p: String) -> Bool {
            guard let a = try? fm.attributesOfItem(atPath: p),
                  (a[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  let perm = (a[.posixPermissions] as? NSNumber)?.intValue else { return false }
            return perm & 0o022 == 0
        }
        guard mine(dir), mine(dir + "/scripts") else { return nil }
        for s in scripts {
            let p = dir + "/scripts/" + s
            guard fm.isExecutableFile(atPath: p), mine(p) else { return nil }
        }
        return dir
    }
}

extension AppUpdater {
    /// Jellyfish AI を開き直す（画面収録の許可は、開き直すまで効かない）。作業中のクラゲがいれば false
    @discardableResult
    static func relaunch(manager: JellyManager?) -> Bool {
        if manager?.anyAgentBusy == true { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ $i -gt 300 ] && exit 0; sleep 0.1; done; /usr/bin/open "$2""#,
                       "jellyfish-relaunch", String(getpid()), Bundle.main.bundleURL.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        AppLog.write("relaunch")
        NSApp.terminate(nil)
        return true
    }

    /// ターミナルで上げるときのコマンド（許可を求める画面にそのまま出し、そのとおりに実行する）。
    /// ソースから入れていれば（scripts/install.sh が覚えた場所に git の checkout と scripts/update.sh があれば）ソースから
    /// （git pull --ff-only → scripts/install.sh）、そうでなければアプリの中の update.sh でリリース版に上げる
    static func terminalCommand(dataDir: URL = AppPaths.dataDir, bundle: URL = Bundle.main.bundleURL) -> String? {
        let q = EngineLogin.shellQuote
        let fm = FileManager.default
        if let dir = SourceCheckout.validated(dataDir: dataDir) {
            return "cd \(q(dir)) && scripts/update.sh --source --yes"
        }
        let script = bundle.appendingPathComponent("Contents/Resources/update.sh")
        guard bundle.pathExtension == "app", fm.isExecutableFile(atPath: script.path) else { return nil }
        return "\(q(script.path)) --yes --app \(q(bundle.path))"
    }

    /// そのコマンドをターミナルで動かす（データフォルダの update.command）
    static func runInTerminal(_ command: String) -> Bool {
        let q = EngineLogin.shellQuote
        let text = ["#!/bin/zsh -l", "clear",
                    "printf '%s\\n\\n  %s\\n\\n' \(q("🪼 Jellyfish AI: " + L("新しい版に上げます（あなたが許可したコマンド）:"))) \(q(command))",
                    command].joined(separator: "\n") + "\n"
        return EngineLogin.openScript(text, name: "update")
    }
}

/// 1 回のアップデート（ダウンロード → 確かめる → 入れ替える → 開き直す）。進み具合を小さな画面に出す
final class UpdateSession: NSObject, URLSessionTaskDelegate {
    private static var current: UpdateSession?
    private let release: AppUpdater.Release
    private weak var manager: JellyManager?
    private let work = AppPaths.dataDir.appendingPathComponent("update", isDirectory: true)
    private var panel: NSPanel?
    private var label: NSTextField?
    private var task: Task<Void, Never>?
    private var running: Process?
    private let runningLock = NSLock()
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    private struct Failure: Error { let message: String }

    private init(release: AppUpdater.Release, manager: JellyManager?) {
        self.release = release
        self.manager = manager
    }

    static func start(_ release: AppUpdater.Release, manager: JellyManager?) {
        guard current == nil else { current?.panel?.makeKeyAndOrderFront(nil); return }
        if manager?.anyAgentBusy == true {
            UpdateChecker.fallback(L("作業中のクラゲがいます。終わってからもう一度アップデートしてください。"), offerPage: false)
            return
        }
        if let why = AppUpdater.locationProblem() { UpdateChecker.fallback(why, offerPage: true); return }
        let s = UpdateSession(release: release, manager: manager)
        current = s
        s.showPanel()
        s.task = Task { await s.run() }
    }

    // MARK: 取ってくる・確かめる

    private func run() async {
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: work)
            try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let (sumsData, sumsResp) = try await session.data(from: release.sums, delegate: self)
            guard (sumsResp as? HTTPURLResponse)?.statusCode == 200, sumsData.count < 100_000,
                  let expected = AppUpdater.checksum(in: String(decoding: sumsData, as: UTF8.self), for: release.zipName) else {
                throw Failure(message: L("チェックサムの一覧（SHA256SUMS.txt）に %@ がありません。", release.zipName))
            }
            let (tmp, resp) = try await session.download(from: release.zip, delegate: self)
            let zip = work.appendingPathComponent(release.zipName)
            try fm.moveItem(at: tmp, to: zip)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: L("ダウンロードできませんでした。")) }
            let size = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0, size < AppUpdater.maxZipBytes else { throw Failure(message: L("ダウンロードしたファイルの大きさがおかしいです。")) }
            try Task.checkCancellation()
            await setStatus(L("確かめています…"))
            guard try AppUpdater.sha256(zip) == expected else {
                throw Failure(message: L("チェックサムが合いません（ダウンロードが壊れているか、書き換えられています）。"))
            }
            let out = work.appendingPathComponent("new", isDirectory: true)
            try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, out.path], failure: L("ダウンロードしたファイルを開けません。"))
            let app = out.appendingPathComponent("JellyfishAI.app", isDirectory: true)
            let attrs = try fm.attributesOfItem(atPath: app.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw Failure(message: L("中身が Jellyfish AI ではありません。")) }
            if let why = AppUpdater.bundleProblem(app, version: release.version, bundleID: Bundle.main.bundleIdentifier) { throw Failure(message: why) }
            let current = Bundle.main.bundleURL
            switch AppUpdater.signingStep(new: app, current: current) {
            case .keep: break
            case .refuse(let why): throw Failure(message: why)
            case .releaseSignature:
                AppLog.write("update: fixed-signing key not found; installing with the release signature")
            case .resign(let sha1):
                await setStatus(L("この Mac の固定の署名で署名し直しています…\nmacOS が「codesign がキーを使おうとしています」と確かめたら「許可」を押してください。"))
                try runTool("/usr/bin/codesign", AppUpdater.resignArguments(app, sha1: sha1),
                            failure: L("この Mac の固定の署名で署名し直せませんでした（macOS の確認で「許可」を押さなかったか、鍵が使えません）。いまの版はそのままです。"))
                guard AppUpdater.satisfiesCurrent(new: app, current: current) else {
                    throw Failure(message: L("署名し直した版が、いまの版の署名と合いません。いまの版はそのままです。"))
                }
                AppLog.write("update: re-signed with the fixed signing certificate")
            }
            try Task.checkCancellation()
            await MainActor.run { self.install(app) }
        } catch is CancellationError {
            await MainActor.run { self.finish() }
        } catch let f as Failure {
            await MainActor.run { self.failed(f.message) }
        } catch {
            await MainActor.run { self.failed((error as NSError).code == NSURLErrorCancelled ? nil : error.localizedDescription) }
        }
    }

    /// 道具を動かして終わるのを待つ。キャンセルされたら止める（codesign が macOS の確認を待っているときも）
    private func runTool(_ path: String, _ args: [String], failure: String) throws {
        try Task.checkCancellation()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        runningLock.lock(); running = p; runningLock.unlock()
        defer { runningLock.lock(); running = nil; runningLock.unlock() }
        p.waitUntilExit()
        try Task.checkCancellation()
        guard p.terminationStatus == 0 else { throw Failure(message: failure) }
    }

    /// リダイレクトは GitHub（github.com・*.githubusercontent.com）の https の中だけ
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let u = request.url, u.scheme == "https", let h = u.host?.lowercased(),
              h == "github.com" || h.hasSuffix(".githubusercontent.com") else { completionHandler(nil); return }
        completionHandler(request)
    }

    // MARK: 入れ替える

    private func install(_ newApp: URL) {
        if manager?.anyAgentBusy == true {
            failed(L("作業中のクラゲがいます。終わってからもう一度アップデートしてください。"), offerPage: false)
            return
        }
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let backup = work.appendingPathComponent("previous.app", isDirectory: true)
        do {
            try fm.moveItem(at: current, to: backup)
        } catch {
            failed(L("macOS がアプリの入れ替えを止めました（%@）。システム設定 › プライバシーとセキュリティ › アプリ管理 で Jellyfish AI を許可してからもう一度試すか、ダウンロードページから入れ直してください。", error.localizedDescription))
            return
        }
        do {
            try fm.moveItem(at: newApp, to: current)
        } catch {
            let why = error.localizedDescription
            do {
                try fm.moveItem(at: backup, to: current)
                failed(L("新しい版を置けませんでした（%@）。いまの版はそのままです。", why))
            } catch {
                // 元に戻せなかったときは、いまの版を消さずに残して場所を伝える
                finish(keepFiles: true)
                UpdateChecker.fallback(L("新しい版を置けず、元にも戻せませんでした（%@）。いまの版は %@ に残しています。", why, backup.path), offerPage: true)
            }
            return
        }
        // 終わるのを待ってから新しい版を開き、古い版を消す（1 分たっても終わらなければ開かない。次に開いたときに新しい版になる）
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", #"i=0; while kill -0 "$1" 2>/dev/null; do i=$((i+1)); [ $i -gt 600 ] && exit 0; sleep 0.1; done; /usr/bin/open "$2"; rm -rf "$3""#,
                       "jellyfish-update", String(getpid()), current.path, work.path]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            AppLog.write("update helper failed: \(error.localizedDescription)")
        }
        AppLog.write("update installed: \(release.version); relaunching")
        setStatusNow(L("新しい版を開いています…"))
        NSApp.terminate(nil)
    }

    // MARK: 画面

    private func showPanel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        p.title = L("Jellyfish AI のアップデート")
        p.isReleasedWhenClosed = false
        let label = NSTextField(wrappingLabelWithString: L("%@ をダウンロードしています…", release.version))
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = 340
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let cancel = NSButton(title: L("キャンセル"), target: self, action: #selector(cancelUpdate))
        cancel.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [label, bar, cancel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 340).isActive = true
        p.contentView = stack
        p.center()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        panel = p
        self.label = label
    }

    @MainActor private func setStatus(_ s: String) { label?.stringValue = s }
    private func setStatusNow(_ s: String) { label?.stringValue = s }

    @objc private func cancelUpdate() {
        task?.cancel()
        session.invalidateAndCancel()
        runningLock.lock(); let p = running; runningLock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    private func finish(keepFiles: Bool = false) {
        panel?.close()
        panel = nil
        if !keepFiles { try? FileManager.default.removeItem(at: work) }
        UpdateSession.current = nil
    }

    private func failed(_ message: String?, offerPage: Bool = true) {
        finish()
        if let message {
            AppLog.write("update failed: \(message)")
            UpdateChecker.fallback(message, offerPage: offerPage)
        }
    }
}
