import AppKit
import ScreenCaptureKit

/// 画面認識：指示が「いま見ている画面」を指していそうなら、その時点の画面を撮ってエージェントに渡す。
/// - 撮影は OS 正式の ScreenCaptureKit。権限は「システム設定 > プライバシーとセキュリティ > 画面収録」
/// - Jellyfish 自身のウィンドウ（クラゲ・チャット）は写さない＝チャットの後ろにある画面がそのまま写る
/// - 画像はエージェントのフォルダに保存し、パスを指示に添える（Claude Code が Read ツールで画像として読む）
enum ScreenMode: String, Codable, CaseIterable {
    case auto, always, never
    var label: String {
        switch self {
        case .auto: return "画面: 自動判定"
        case .always: return "画面: 毎回添付"
        case .never: return "画面: 添付しない"
        }
    }
}

enum ScreenTarget: String, Codable, CaseIterable {
    case activeDisplay, allDisplays
}

enum ScreenIntent {
    /// 画面を指す言い回し（日本語・英語）
    static let phrases: [String] = [
        "この画面", "今の画面", "いまの画面", "画面の", "画面に", "画面上", "画面を見", "画面で",
        "表示されて", "表示して", "表示中", "映って", "写って", "今開いて", "いま開いて", "開いている", "開いてる",
        "見ている", "見てる", "見えている", "このウィンドウ", "このページ", "このサイト", "このタブ",
        "このエラー", "この図", "このグラフ", "この画像", "このスライド", "このデザイン", "この表",
        "このコード", "このモデル", "この部分", "ここの", "スクショ", "スクリーンショット",
        "this screen", "my screen", "on screen", "on the screen", "screenshot", "currently open",
        "i'm looking at", "im looking at", "this page", "this window", "this error", "this chart", "this figure",
    ]

    static func refersToScreen(_ text: String) -> Bool {
        let t = text.lowercased()
        return phrases.contains { t.contains($0) }
    }
}

struct ScreenContext {
    var images: [URL]
    var appName: String?
    var windowTitle: String?
    var note: String?

    /// 指示の末尾に付ける説明（チャット表示ではこの部分を「📷 画面を添付」に置き換える）
    static let marker = "\n\n---\n[Jellyfish 画面コンテキスト]"

    var promptSuffix: String {
        guard !images.isEmpty else { return "" }
        var s = ScreenContext.marker + "\n"
        s += "ユーザーがこの指示を出した時点の画面のスクリーンショット:\n"
        for u in images { s += "- \(u.path)\n" }
        if let a = appName { s += "前面のアプリ: \(a)" + (windowTitle.map { "「\($0)」" } ?? "") + "\n" }
        s += "「この画面」「表示されている〜」などはこの画像の内容を指しています。まず Read ツールで画像を開いて内容（アプリ・ウィンドウ・テキスト・コード・グラフ・エラーなど）を確認してから作業してください。"
        return s
    }

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// 撮影。frontApp は「チャットを開く前に使っていたアプリ」（どの画面を撮るかとアプリ名に使う）
    static func capture(frontApp: NSRunningApplication?, target: ScreenTarget, into dir: URL) async -> ScreenContext {
        var ctx = ScreenContext(images: [], appName: frontApp?.localizedName, windowTitle: nil, note: nil)
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()   // 初回はシステムの許可ダイアログが出る
            if !CGPreflightScreenCaptureAccess() {
                ctx.note = "画面収録の権限がないため画面を添付できませんでした（システム設定 > プライバシーとセキュリティ > 画面収録 で Jellyfish AI を許可）"
                return ctx
            }
        }
        let win = frontWindow(of: frontApp)
        ctx.windowTitle = win?.title
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            var displays = content.displays
            if target == .activeDisplay {
                let id = win.flatMap { displayID(containing: $0.bounds) } ?? displayUnderMouse() ?? CGMainDisplayID()
                displays = displays.filter { $0.displayID == id }
                if displays.isEmpty { displays = Array(content.displays.prefix(1)) }
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            for (i, d) in displays.enumerated() {
                let filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                // 文字が読めてトークンを使いすぎない解像度に：長辺 1568px まで、実際の画素より大きくはしない
                // （画像のトークンはおよそ面積に比例。2560×1440 で約 4,700、1568×882 で約 1,800）
                let scale = min(nativeScale(of: d.displayID), maxLongEdge / max(d.frame.width, d.frame.height))
                cfg.width = Int(d.frame.width * scale)
                cfg.height = Int(d.frame.height * scale)
                cfg.showsCursor = false
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                let url = dir.appendingPathComponent("screen-\(stamp)\(displays.count > 1 ? "-d\(i + 1)" : "").png")
                if write(img, to: url) { ctx.images.append(url) }
            }
        } catch {
            ctx.note = "画面の取得に失敗しました: \(error.localizedDescription)"
        }
        return ctx
    }

    static let maxLongEdge: CGFloat = 1568

    /// そのディスプレイの 1 ポイントあたりの画素数（Retina = 2、外部の 1080p など = 1）
    private static func nativeScale(of id: CGDirectDisplayID) -> CGFloat {
        let s = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }
        return s?.backingScaleFactor ?? 2.0
    }

    // MARK: -

    private struct WindowInfo { let title: String?; let bounds: CGRect }

    /// そのアプリの一番手前のウィンドウ（タイトルの取得には画面収録の権限が要る）
    private static func frontWindow(of app: NSRunningApplication?) -> WindowInfo? {
        guard let pid = app?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if rect.width < 50 || rect.height < 50 { continue }
            let title = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return WindowInfo(title: title, bounds: rect)
        }
        return nil
    }

    private static func displayID(containing rect: CGRect) -> CGDirectDisplayID? {
        var id = CGDirectDisplayID()
        var count: UInt32 = 0
        let p = CGPoint(x: rect.midX, y: rect.midY)
        guard CGGetDisplaysWithPoint(p, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }

    private static func displayUnderMouse() -> CGDirectDisplayID? {
        let m = NSEvent.mouseLocation
        guard let s = NSScreen.screens.first(where: { $0.frame.contains(m) }) else { return nil }
        return s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    private static func write(_ img: CGImage, to url: URL) -> Bool {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dst, img, nil)
        return CGImageDestinationFinalize(dst)
    }
}
