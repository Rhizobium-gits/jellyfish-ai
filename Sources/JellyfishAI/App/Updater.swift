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

    /// 署名が正しいか（中身が書き換えられていないか）。いまの版が証明書で署名されていれば、同じ証明書の署名であることも
    static func signatureProblem(new: URL, current: URL) -> String? {
        guard let code = staticCode(new) else { return L("署名を読めません。") }
        var req: SecRequirement?
        if !isAdhoc(current), let cur = staticCode(current) {
            var r: SecRequirement?
            if SecCodeCopyDesignatedRequirement(cur, [], &r) == errSecSuccess { req = r }
        }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckAllArchitectures) | UInt32(kSecCSCheckNestedCode))
        let st = SecStaticCodeCheckValidity(code, flags, req)
        if st == errSecSuccess { return nil }
        return req == nil ? L("署名が正しくありません（%ld）。", Int(st)) : L("いまの版と署名が違います（%ld）。自分でビルドした版は、ダウンロードページから入れ直してください。", Int(st))
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
            try runTool("/usr/bin/ditto", ["-x", "-k", zip.path, out.path])
            let app = out.appendingPathComponent("JellyfishAI.app", isDirectory: true)
            let attrs = try fm.attributesOfItem(atPath: app.path)
            guard attrs[.type] as? FileAttributeType == .typeDirectory else { throw Failure(message: L("中身が Jellyfish AI ではありません。")) }
            if let why = AppUpdater.bundleProblem(app, version: release.version, bundleID: Bundle.main.bundleIdentifier) { throw Failure(message: why) }
            if let why = AppUpdater.signatureProblem(new: app, current: Bundle.main.bundleURL) { throw Failure(message: why) }
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

    private func runTool(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(message: L("ダウンロードしたファイルを開けません。")) }
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
        let label = NSTextField(labelWithString: L("%@ をダウンロードしています…", release.version))
        label.font = .systemFont(ofSize: 13)
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

    @objc private func cancelUpdate() { task?.cancel(); session.invalidateAndCancel() }

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
