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
        case .auto: return L("画面: 自動判定")
        case .always: return L("画面: 毎回添付")
        case .never: return L("画面: 添付しない")
        }
    }
}

enum ScreenTarget: String, Codable, CaseIterable {
    case activeDisplay, allDisplays
}

enum ScreenIntent {
    /// 画面を指す言い回し（日本語・英語・中国語）。
    /// 「一覧を表示して」「ポートが開いているか」「このコードを直して」（コードを貼った場合）のような普通の指示で
    /// 画面全体を撮って送らないよう、画面・ウィンドウ・ページをはっきり指すものだけにしている
    static let phrases: [String] = [
        "この画面", "今の画面", "いまの画面", "画面の", "画面に", "画面上", "画面を見", "画面で",
        "表示されて", "表示中の", "映って", "写って", "今開いて", "いま開いて", "見えている", "見えてる",
        "このウィンドウ", "このページ", "このサイト", "このタブ", "このスライド", "スクショ", "スクリーンショット",
        "this screen", "my screen", "on screen", "on the screen", "screenshot", "currently open",
        "i'm looking at", "im looking at", "this page", "this window",
        "i’m looking at", "what am i looking at", "this tab", "this slide",
        "这个屏幕", "当前屏幕", "我的屏幕", "屏幕上", "屏幕中", "这个画面", "当前画面",
        "这个窗口", "这个页面", "这个网页", "这个标签页", "这张幻灯片", "截图", "截屏",
        "正在显示", "当前打开", "我正在看",
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
        s += L("ユーザーがこの指示を出した時点の画面のスクリーンショット:") + "\n"
        for u in images { s += "- \(u.path)\n" }
        if let a = appName {
            s += (windowTitle.map { L("前面のアプリ: %@「%@」", a, $0) } ?? L("前面のアプリ: %@", a)) + "\n"
        }
        s += L("「この画面」「表示されている〜」などはこの画像の内容を指しています。まず Read ツールで画像を開いて内容（アプリ・ウィンドウ・テキスト・コード・グラフ・エラーなど）を確認してから作業してください。")
        return s
    }

    static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }

    /// 撮影。frontApp は「チャットを開く前に使っていたアプリ」（どの画面を撮るかとアプリ名に使う）
    static func capture(frontApp: NSRunningApplication?, target: ScreenTarget, into dir: URL) async -> ScreenContext {
        var ctx = ScreenContext(images: [], appName: frontApp?.localizedName, windowTitle: nil, note: nil)
        // 確認を出すのは起動しているあいだに 1 回だけ（クラゲを足して指示するたびに確認が出ないように）
        if !DesktopControl.requestScreenRecordingOnce() || !CGPreflightScreenCaptureAccess() {
            ctx.note = L("画面収録の許可が効いていないため、画面を添付できませんでした。") + DesktopControl.screenRecordingHint
            return ctx
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
            ctx.note = L("画面の取得に失敗しました: %@", error.localizedDescription)
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
