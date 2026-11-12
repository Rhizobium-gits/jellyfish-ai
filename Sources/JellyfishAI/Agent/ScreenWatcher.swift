import AppKit
import os
import ScreenCaptureKit
import Vision

/// 見守り：前面のウィンドウを **Mac の中だけで** 見て（アプリ名・ウィンドウ名・macOS 内蔵の文字認識）、
/// エラーっぽい表示に気づいたら、見守っているクラゲが「見る？」と聞く。見ている間のトークンは 0。
/// - どこにも送らない。認識した文字は覚えず、ログにも書かない
/// - エラーっぽいと分かったときだけ、そのウィンドウの 1 枚をクラゲのデータフォルダに残し、押されたときだけ送る（押されなければ消す）
/// - 画面が変わっていなければ文字認識をしない。離席中（入力が 5 分ない）は見ない
/// - パスワードの管理など、見ないアプリがある。画面収録の許可が無いときは何もしない（確認も出さない）
struct WatchFinding {
    let appName: String
    let bundleID: String?
    let windowTitle: String?
    /// 吹き出しに出す 1 行
    let snippet: String
    let image: CGImage
    let signature: String
}

/// エラーっぽい行を見つける（文字だけで決める。テストできるように分けてある）
enum WatchMatcher {
    /// 見ないアプリ（パスワード・鍵・ロック画面・Jellyfish 自身）
    static let excludedBundleIDs: Set<String> = [
        "ai.jellyfish.desktop", "com.apple.loginwindow", "com.apple.ScreenSaver.Engine", "com.apple.keychainaccess",
        "com.apple.Passwords", "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc",
    ]

    /// 英語は単語として（「NSError」「errorHandler」「on_error」のような名前の一部では数えない）
    private static let english = try! NSRegularExpression(pattern:
        #"\b(error|errors|failed|failure|fatal|exception|traceback|panic|crash(ed|es)?|segmentation fault|permission denied|access denied|not found|unable to|could not|couldn't|cannot be opened)\b"#,
        options: [.caseInsensitive])
    private static let cjk = ["エラー", "失敗", "できませんでした", "見つかりません", "問題が発生", "予期しない", "拒否されました",
                              "応答していません", "強制終了", "错误", "失败", "异常", "无法", "崩溃", "未找到", "被拒绝"]

    static func isErrorLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.count >= 3, t.count <= 240 else { return false }
        if cjk.contains(where: { t.contains($0) }) { return true }
        return english.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    static func errorLines(_ lines: [String]) -> [String] {
        var out: [String] = []
        for l in lines where isErrorLine(l) {
            let t = l.trimmingCharacters(in: .whitespaces)
            if !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// 同じ表示かどうか（数字の違いだけなら同じとみなす：時刻・行番号・PID などで何度も聞かない）
    static func signature(app: String, title: String?, lines: [String]) -> String {
        let norm = lines.prefix(4).map { $0.lowercased().replacingOccurrences(of: #"[0-9]+"#, with: "#", options: .regularExpression) }
        return ([app, title ?? ""] + norm).joined(separator: "\u{1f}")
    }
}

final class ScreenWatcher {
    static let shared = ScreenWatcher()

    /// 見守っているクラゲがいるか（いなければ止まる）
    var isActive: () -> Bool = { false }
    /// 見ないアプリ（ユーザーが「このアプリでは聞かない」にしたもの）
    var ignoredApps: () -> Set<String> = { [] }
    /// 気づいたとき（メインスレッド）
    var onFinding: ((WatchFinding) -> Void)?

    static let interval: TimeInterval = 4
    private var timer: Timer?
    private let queue = DispatchQueue(label: "ai.jellyfish.watch", qos: .utility)
    private var busy = false
    /// ウィンドウごとの見た目（小さな明るさの格子）と、「変わったあと落ち着いたら読む」の状態
    private struct WinState { var grid: [UInt8]; var pending: Bool; var lastRead: Date }
    private var windows: [CGWindowID: WinState] = [:]
    /// 読むのは、変わったあと落ち着いたときだけ・この間隔より短くは読まない
    static let minReadInterval: TimeInterval = 8
    private var seen: [String: Date] = [:]
    private var quietUntil: [String: Date] = [:]
    private var lastNotified = Date.distantPast
    private let lock = NSLock()

    // 負担の目安（直近の分）
    private var samples: [(at: Date, cpu: Double, wall: Double, ocr: Bool)] = []
    private(set) var ticks = 0
    private(set) var ocrRuns = 0

    /// 見守りの有無に合わせて始める・止める
    func refresh() {
        if isActive() {
            guard timer == nil else { return }
            let t = Timer(timeInterval: ScreenWatcher.interval, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
            AppLog.write("watch: started")
        } else if let t = timer {
            t.invalidate()
            timer = nil
            lock.lock(); windows.removeAll(); lock.unlock()
            AppLog.write("watch: stopped")
        }
    }

    var isRunning: Bool { timer != nil }

    /// 気づいて知らせたあと、そのアプリでしばらく聞かない（✕ を押したらもっと長く）
    func quiet(_ app: String, for seconds: TimeInterval) {
        lock.lock(); quietUntil[app] = Date().addingTimeInterval(seconds); lock.unlock()
    }

    /// 直近 60 秒の、見守りに使った CPU（1 コアを 100%）と、文字認識をした回数
    func load(window: TimeInterval = 60) -> (cpuPercent: Double, ocrCount: Int, ticks: Int)? {
        lock.lock(); defer { lock.unlock() }
        let since = Date().addingTimeInterval(-window)
        let recent = samples.filter { $0.at >= since }
        guard !recent.isEmpty else { return nil }
        let span = max(ScreenWatcher.interval, min(window, Date().timeIntervalSince(recent.first!.at) + ScreenWatcher.interval))
        return (recent.reduce(0) { $0 + $1.cpu } / span * 100, recent.filter(\.ocr).count, recent.count)
    }

    static func processCPUSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }

    private func tick() {
        // 見守るクラゲがいなくなったら止まる
        guard isActive() else { refresh(); return }
        guard !busy, CGPreflightScreenCaptureAccess() else { return }
        // 離席中は見ない（画面が変わらないので）
        if let idle = ScreenWatcher.idleSeconds(), idle > 300 { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let bid = app.bundleIdentifier ?? ""
        if WatchMatcher.excludedBundleIDs.contains(bid) || bid == Bundle.main.bundleIdentifier || ignoredApps().contains(bid) { return }
        let appName = app.localizedName ?? bid
        lock.lock()
        let quiet = quietUntil[bid].map { $0 > Date() } ?? false
        lock.unlock()
        if quiet { return }
        guard let win = ScreenWatcher.frontWindow(pid: app.processIdentifier) else { return }
        busy = true
        let started = Date(), cpu0 = ScreenWatcher.processCPUSeconds()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            // まず小さく撮って、変わったか・落ち着いたかだけ見る（ここではまだ文字を読まない）
            let small = await ScreenWatcher.capture(windowID: win.id, maxEdge: 320)
            let read = small.map { self.shouldRead(window: win.id, grid: ScreenWatcher.grid($0)) } ?? false
            // 変わったあと落ち着いたときだけ、読める大きさで撮って読む
            let img = read ? await ScreenWatcher.capture(windowID: win.id, maxEdge: 1200) : nil
            self.process(img, window: win, app: appName, bundleID: bid, started: started, cpu0: cpu0)
        }
    }

    /// 前の格子と比べて、変わっていれば「読む待ち」にし、落ち着いていて待ちがあれば読む（読み過ぎない）
    private func shouldRead(window id: CGWindowID, grid: [UInt8]) -> Bool {
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        guard var st = windows[id] else {
            if windows.count > 64 { windows.removeAll() }
            windows[id] = WinState(grid: grid, pending: true, lastRead: .distantPast)
            return false
        }
        let changed = ScreenWatcher.changedFraction(st.grid, grid) > 0.004
        st.grid = grid
        if changed {
            st.pending = true
            windows[id] = st
            return false
        }
        guard st.pending, now.timeIntervalSince(st.lastRead) >= ScreenWatcher.minReadInterval else { windows[id] = st; return false }
        st.pending = false
        st.lastRead = now
        windows[id] = st
        return true
    }

    /// 撮ったあと（同期の処理。鍵はここで）
    private func process(_ img: CGImage?, window win: (id: CGWindowID, title: String?), app appName: String, bundleID bid: String,
                         started: Date, cpu0: Double) {
        var didOCR = false
        var finding: WatchFinding?
        defer {
            let cpu = ScreenWatcher.processCPUSeconds() - cpu0
            lock.lock()
            samples.append((Date(), cpu, Date().timeIntervalSince(started), didOCR))
            if samples.count > 200 { samples.removeFirst(samples.count - 200) }
            ticks += 1
            if didOCR { ocrRuns += 1 }
            lock.unlock()
            let f = finding
            DispatchQueue.main.async {
                self.busy = false
                if let f { self.onFinding?(f) }
            }
        }
        guard let img else { return }
        didOCR = true
        let lines = ScreenWatcher.recognize(img)
        let matched = WatchMatcher.errorLines(lines + [win.title].compactMap { $0 })
        guard let first = matched.first else { return }
        let sig = WatchMatcher.signature(app: bid, title: win.title, lines: matched)
        let now = Date()
        lock.lock()
        let dup = seen[sig].map { now.timeIntervalSince($0) < 1800 } ?? false
        let tooSoon = now.timeIntervalSince(lastNotified) < 60
        if !dup && !tooSoon {
            seen[sig] = now
            lastNotified = now
            if seen.count > 300 { seen = seen.filter { now.timeIntervalSince($0.value) < 1800 } }
        }
        lock.unlock()
        guard !dup, !tooSoon else { return }
        finding = WatchFinding(appName: appName, bundleID: bid, windowTitle: win.title, snippet: String(first.prefix(80)), image: img, signature: sig)
    }

    // MARK: 負担を測る（JellyfishAI --watch-bench 秒）

    /// 前面のウィンドウを 4 秒ごとに撮って読む。force = 毎回読む（画面がずっと変わるときの上限）、そうでなければ変わったときだけ
    static func bench(seconds: Double, force: Bool) async -> String {
        guard CGPreflightScreenCaptureAccess() else { return "no screen recording permission" }
        let t0 = Date(), cpu0 = processCPUSeconds()
        var shots = 0, ocrs = 0, captureMs = 0.0, ocrMs = 0.0, lines = 0
        var last: [UInt8]?, pending = true, lastRead = Date.distantPast
        while Date().timeIntervalSince(t0) < seconds {
            let tickStart = Date()
            if let app = NSWorkspace.shared.frontmostApplication, let w = frontWindow(pid: app.processIdentifier) {
                let c0 = Date()
                if let small = await capture(windowID: w.id, maxEdge: 320) {
                    captureMs += Date().timeIntervalSince(c0) * 1000
                    shots += 1
                    let g = grid(small)
                    let changed = last.map { changedFraction($0, g) > 0.004 } ?? true
                    last = g
                    if changed { pending = true }
                    let read = force || (!changed && pending && Date().timeIntervalSince(lastRead) >= minReadInterval)
                    if read, let img = await capture(windowID: w.id, maxEdge: 1200) {
                        pending = false
                        lastRead = Date()
                        let o0 = Date()
                        lines += recognize(img).count
                        ocrMs += Date().timeIntervalSince(o0) * 1000
                        ocrs += 1
                    }
                }
            }
            let rest = interval - Date().timeIntervalSince(tickStart)
            if rest > 0 { try? await Task.sleep(nanoseconds: UInt64(rest * 1_000_000_000)) }
        }
        let wall = Date().timeIntervalSince(t0), cpu = processCPUSeconds() - cpu0
        return String(format: "%@: %.0fs, small shots %d (avg %.0f ms), OCR %d (avg %.0f ms, %d lines), CPU %.2f%% of one core",
                      force ? "every tick" : "after change settles", wall, shots, shots > 0 ? captureMs / Double(shots) : 0,
                      ocrs, ocrs > 0 ? ocrMs / Double(ocrs) : 0, lines, cpu / wall * 100)
    }

    // MARK: Mac の中の仕組みだけで

    static func idleSeconds() -> Double? {
        let kinds: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]
        let t = kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
        return t.isFinite ? t : nil
    }

    /// そのアプリのいちばん前のふつうのウィンドウ
    static func frontWindow(pid: pid_t) -> (id: CGWindowID, title: String?)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) >= 120, (b["Height"] ?? 0) >= 60,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0.1,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            return (id, w[kCGWindowName as String] as? String)
        }
        return nil
    }

    /// ウィンドウの一覧を毎回取ると重いので、同じウィンドウなら 10 秒は使い回す
    private static let windowCache = OSAllocatedUnfairLock<(id: CGWindowID, window: SCWindow, at: Date)?>(initialState: nil)

    private static func scWindow(_ id: CGWindowID) async -> SCWindow? {
        if let c = windowCache.withLock({ $0 }), c.id == id, Date().timeIntervalSince(c.at) < 10 { return c.window }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let w = content.windows.first(where: { $0.windowID == id }) else { return nil }
        windowCache.withLock { $0 = (id, w, Date()) }
        return w
    }

    /// そのウィンドウだけを撮る（長辺 maxEdge まで）
    static func capture(windowID: CGWindowID, maxEdge: CGFloat = 1200) async -> CGImage? {
        guard let w = await scWindow(windowID) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let scale = min(2, maxEdge / max(w.frame.width, w.frame.height, 1))
        cfg.width = max(1, Int(w.frame.width * scale))
        cfg.height = max(1, Int(w.frame.height * scale))
        cfg.showsCursor = false
        if let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) { return img }
        // 閉じた・動いたなどで使い回しが古ければ、取り直して次に
        windowCache.withLock { $0 = nil }
        return nil
    }

    /// 見た目が変わったかを見るための小さな明るさの格子（横 24 × 縦 16）
    static func grid(_ img: CGImage, w: Int = 24, h: Int = 16) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return px }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }

    /// 格子のうち、はっきり明るさが変わったマスの割合（カーソルの点滅のような小さな変化は数えない）
    static func changedFraction(_ a: [UInt8], _ b: [UInt8], threshold: Int = 8) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var n = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > threshold { n += 1 }
        return Double(n) / Double(a.count)
    }

    /// macOS 内蔵の文字認識（Vision。この Mac の中だけで動く）
    static func recognize(_ img: CGImage) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.recognitionLanguages = ["ja-JP", "en-US", "zh-Hans"]
        req.minimumTextHeight = 0.01
        let h = VNImageRequestHandler(cgImage: img, options: [:])
        guard (try? h.perform([req])) != nil else { return [] }
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// PNG に（押されたときに送る 1 枚。クラゲのデータフォルダに）
    static func savePNG(_ img: CGImage, to url: URL) -> Bool {
        let rep = NSBitmapImageRep(cgImage: img)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }
}
