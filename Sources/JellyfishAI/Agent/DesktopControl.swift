import AppKit
import ApplicationServices
import ScreenCaptureKit

/// エージェントによる PC 操作（画面を見る・クリック・入力・キー・アプリを開く・画面の部品を読む）。
///
/// 安全のための決まり：
/// - クラゲごとに既定オフ。チャットの「🖱 PC 操作」でオンにしたエージェントにだけツールを見せる
/// - OS 正式の権限（アクセシビリティ・画面収録）が必要。設定はユーザーがシステム設定で行う
/// - 同時に操作できるのは 1 体だけ（運転席のロック）。操作中は画面の縁がその色で光り、名前を表示
/// - ユーザーが Esc を押したらすぐ止める（そのエージェントの PC 操作もオフに戻す）
/// - これらのツールは --allowedTools で事前許可しない＝毎回 Claude Code の Auto Mode の安全判定を通る
final class DesktopControl {
    static let shared = DesktopControl()

    /// 自分が送ったキー・マウスの印（Esc 監視で自分の Esc と区別する）
    private static let marker: Int64 = 0x4A454C59   // "JELY"

    private(set) var driver: UUID?
    private var driverName = ""
    private var lastAction = Date()
    private var escMonitors: [Any] = []
    private let border = ControlBorder()
    /// Esc で止められたとき（エージェント ID）
    var onUserStop: ((UUID) -> Void)?

    // MARK: - 権限

    static var hasAccessibility: Bool { AXIsProcessTrusted() }
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// OS の確認ダイアログを出す（許可はユーザーがシステム設定で行う）
    static func requestPermissions() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    }

    static var permissionSummary: String {
        "アクセシビリティ: \(hasAccessibility ? "許可済み" : "未許可") / 画面収録: \(hasScreenRecording ? "許可済み" : "未許可")"
    }

    /// 「PC 操作」スイッチが守る範囲（ユーザーが実際の権限を正しく把握できるように）
    static let scopeNote = "「PC 操作」スイッチは、Jellyfish の PC 操作ツール（クリック・入力・画面の撮影など）をそのエージェントに渡すかどうかを決めます。macOS の許可は Jellyfish AI アプリ全体に付くため、スイッチがオフのエージェントでも、Claude Code が実行するコマンド（screencapture など）はアプリに付いた許可の範囲で動けます。使わなくなったら「システム設定 › プライバシーとセキュリティ」で許可を外してください。"

    // MARK: - 運転席（同時に 1 体だけ）

    /// 操作の前に呼ぶ。別のエージェントが操作中なら、その名前を返す
    func acquire(_ agent: UUID, name: String, color: NSColor) -> String? {
        if let d = driver, d != agent {
            if Date().timeIntervalSince(lastAction) > 90 { release(d) } else { return driverName }
        }
        lastAction = Date()
        if driver != agent {
            driver = agent
            driverName = name
            border.show(name: name, color: color)
            startEscMonitor()
        }
        return nil
    }

    func release(_ agent: UUID) {
        guard driver == agent else { return }
        driver = nil
        border.hide()
        stopEscMonitor()
    }

    private func startEscMonitor() {
        guard escMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in
            guard let self, e.keyCode == 53 else { return }
            // エージェントが自分で押した Esc は無視
            if e.cgEvent?.getIntegerValueField(.eventSourceUserData) == DesktopControl.marker { return }
            guard let d = self.driver else { return }
            AppLog.write("desktop control stopped by user (Esc)")
            self.release(d)
            self.onUserStop?(d)
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { escMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) { escMonitors.append(l) }
    }

    private func stopEscMonitor() {
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors.removeAll()
    }

    // MARK: - ツール定義（MCP）

    static let toolDefinitions: [[String: Any]] = [
        ["name": "screen_capture",
         "description": "画面を撮って PNG のパスを返す（Read ツールで開いて見る）。画像の 1 ピクセル = 1 ポイントで、画像上の (x, y) はグローバル座標 (origin_x + x, origin_y + y) に当たる。クリックなどの座標はこのグローバル座標で指定する。Jellyfish 自身のウィンドウは写らない。",
         "inputSchema": ["type": "object", "properties": [
            "display": ["type": "string", "description": "main（既定）/ all / 番号（1 から）"],
         ]]],
        ["name": "list_windows",
         "description": "画面に出ているウィンドウ（アプリ名・タイトル・位置と大きさ）を前面から順に返す。",
         "inputSchema": ["type": "object", "properties": [:] as [String: Any]]],
        ["name": "ui_elements",
         "description": "前面（または指定）アプリのウィンドウにあるボタン・入力欄・メニューなどの部品を、役割・名前・値・位置つきで返す（アクセシビリティ）。クリック位置を決めるのに使う。",
         "inputSchema": ["type": "object", "properties": [
            "app": ["type": "string", "description": "アプリ名（省略で前面のアプリ）"],
            "max": ["type": "number", "description": "返す部品の最大数（既定 150）"],
         ]]],
        ["name": "open_app",
         "description": "アプリを開いて前面にする（名前か bundle ID）。http / https の URL を渡すと既定のブラウザで開く。",
         "inputSchema": ["type": "object", "properties": [
            "name": ["type": "string"], "url": ["type": "string"],
         ]]],
        ["name": "mouse_click",
         "description": "グローバル座標 (x, y) をクリックする。",
         "inputSchema": ["type": "object", "required": ["x", "y"], "properties": [
            "x": ["type": "number"], "y": ["type": "number"],
            "button": ["type": "string", "description": "left（既定）/ right"],
            "count": ["type": "number", "description": "1（既定）/ 2 = ダブルクリック"],
         ]]],
        ["name": "mouse_drag",
         "description": "(from_x, from_y) から (to_x, to_y) へドラッグする。",
         "inputSchema": ["type": "object", "required": ["from_x", "from_y", "to_x", "to_y"], "properties": [
            "from_x": ["type": "number"], "from_y": ["type": "number"], "to_x": ["type": "number"], "to_y": ["type": "number"],
         ]]],
        ["name": "scroll",
         "description": "(x, y) の位置でスクロールする。dy が正で上、負で下（行単位）。",
         "inputSchema": ["type": "object", "required": ["x", "y", "dy"], "properties": [
            "x": ["type": "number"], "y": ["type": "number"], "dy": ["type": "number"], "dx": ["type": "number"],
         ]]],
        ["name": "type_text",
         "description": "前面のアプリのフォーカスされた欄に文字を入力する（日本語も可。IME は通さない）。先に対象の欄をクリックしておくこと。",
         "inputSchema": ["type": "object", "required": ["text"], "properties": ["text": ["type": "string"]]]],
        ["name": "press_keys",
         "description": "キーを押す。例: \"return\", \"esc\", \"tab\", \"cmd+s\", \"cmd+shift+4\", \"down\"。複数はスペース区切りで順に押す。",
         "inputSchema": ["type": "object", "required": ["keys"], "properties": ["keys": ["type": "string"]]]],
    ]

    static let systemPrompt = """
    # PC 操作（ユーザーがこのエージェントに許可済み）
    jellyfish MCP の screen_capture / list_windows / ui_elements / open_app / mouse_click / mouse_drag / scroll / type_text / press_keys でこの Mac を操作できます。
    - まず screen_capture で画面を撮り、Read で画像を見てから操作する。操作のあとは必ずもう一度撮って結果を確かめる
    - 座標はグローバル座標（screen_capture の origin を足す）。ボタンの位置は ui_elements の方が正確
    - 入力の前に open_app か対象の欄のクリックで、入力先を前面にする
    - 同時に PC を操作できるのは 1 体だけ。別のエージェントが操作中と返ったら、少し待ってからやり直す
    - パスワード・認証情報の入力、支払い・購入、メールやメッセージの送信、公開の投稿、削除などの取り返しのつかない操作は、ユーザーが明示的に頼んだ場合を除いてしない。ログイン・2 段階認証・支払いの画面に出たら止めてユーザーに伝える
    - ユーザーが Esc を押すと操作は止まる。止められたら続けずに、どこまでできたかを報告する
    """

    // MARK: - 実行

    /// メインスレッドで呼ぶ。完了で reply（テキスト, エラーか）
    func call(_ tool: String, _ a: [String: Any], agent: UUID, name: String, color: NSColor, dir: URL,
              reply: @escaping (String, Bool) -> Void) {
        func num(_ k: String) -> CGFloat? { (a[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
        let needsAX = ["mouse_click", "mouse_drag", "scroll", "type_text", "press_keys", "ui_elements"].contains(tool)
        if needsAX && !DesktopControl.hasAccessibility {
            reply("アクセシビリティの権限がありません。ユーザーに「システム設定 › プライバシーとセキュリティ › アクセシビリティ で Jellyfish AI を許可」してもらってください。", true)
            return
        }
        // 画面を読むだけのツールも含めて、使っている間は画面の縁を光らせ Esc で止められるようにする
        if ["mouse_click", "mouse_drag", "scroll", "type_text", "press_keys", "open_app",
            "screen_capture", "list_windows", "ui_elements"].contains(tool) {
            if let other = acquire(agent, name: name, color: color) {
                reply("いまは「\(other)」が PC を操作中です。少し待ってからやり直してください。", true)
                return
            }
        }
        lastAction = Date()
        switch tool {
        case "screen_capture":
            guard DesktopControl.hasScreenRecording else {
                reply("画面収録の権限がありません。ユーザーに「システム設定 › プライバシーとセキュリティ › 画面収録」で Jellyfish AI を許可してもらってください。", true)
                return
            }
            let which = (a["display"] as? String) ?? "main"
            Task { @MainActor in
                let r = await DesktopControl.capture(which, into: dir.appendingPathComponent("screens", isDirectory: true))
                reply(r.0, r.1)
            }
        case "list_windows":
            reply(TeamCoordinator.json(DesktopControl.windows()), false)
        case "ui_elements":
            let max = Int(num("max") ?? 150)
            reply(DesktopControl.uiElements(app: a["app"] as? String, max: min(max, 400)), false)
        case "open_app":
            if let s = a["url"] as? String {
                // Web ページだけ（jellyfish:// や他のアプリのスキーム・ファイルは開かない）
                guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else {
                    reply("url は http / https だけ開けます", true); return
                }
                NSWorkspace.shared.open(u)
                reply("開きました: \(u.absoluteString)", false)
            } else if let n = a["name"] as? String {
                DesktopControl.openApp(n, reply: reply)
            } else {
                reply("name か url が必要です", true)
            }
        case "mouse_click":
            guard let x = num("x"), let y = num("y") else { reply("x, y が必要です", true); return }
            let right = (a["button"] as? String) == "right"
            let count = Int(num("count") ?? 1)
            DesktopControl.click(CGPoint(x: x, y: y), right: right, count: max(1, min(count, 3)))
            reply("クリックしました (\(Int(x)), \(Int(y)))\(count > 1 ? " ×\(count)" : "")", false)
        case "mouse_drag":
            guard let fx = num("from_x"), let fy = num("from_y"), let tx = num("to_x"), let ty = num("to_y") else {
                reply("from_x, from_y, to_x, to_y が必要です", true); return
            }
            DesktopControl.drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty)) { reply("ドラッグしました", false) }
        case "scroll":
            guard let x = num("x"), let y = num("y"), let dy = num("dy") else { reply("x, y, dy が必要です", true); return }
            DesktopControl.scroll(at: CGPoint(x: x, y: y), dy: Int32(dy), dx: Int32(num("dx") ?? 0))
            reply("スクロールしました", false)
        case "type_text":
            guard let t = a["text"] as? String else { reply("text が必要です", true); return }
            DesktopControl.type(t) { reply("入力しました（\(t.count) 文字）", false) }
        case "press_keys":
            guard let k = a["keys"] as? String else { reply("keys が必要です", true); return }
            if let err = DesktopControl.press(k) { reply(err, true) } else { reply("押しました: \(k)", false) }
        default:
            reply("未知のツール: \(tool)", true)
        }
    }

    // MARK: - 画面

    private static func capture(_ which: String, into dir: URL) async -> (String, Bool) {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            var displays = content.displays.sorted { $0.frame.minX < $1.frame.minX }
            if which == "main" {
                displays = displays.filter { $0.displayID == CGMainDisplayID() }
            } else if let n = Int(which), n >= 1, n <= displays.count {
                displays = [displays[n - 1]]
            }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            var out: [[String: Any]] = []
            for (i, d) in displays.enumerated() {
                let filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
                let cfg = SCStreamConfiguration()
                // 1 ピクセル = 1 ポイント（画像の座標をそのままクリック座標に使える）
                cfg.width = Int(d.frame.width)
                cfg.height = Int(d.frame.height)
                cfg.showsCursor = true
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                let url = dir.appendingPathComponent("screen-\(stamp)-\(i + 1).png")
                if let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dst, img, nil)
                    CGImageDestinationFinalize(dst)
                }
                out.append(["path": url.path, "origin_x": Int(d.frame.minX), "origin_y": Int(d.frame.minY),
                            "width": Int(d.frame.width), "height": Int(d.frame.height),
                            "main": d.displayID == CGMainDisplayID()])
            }
            let m = NSEvent.mouseLocation
            let mainH = NSScreen.screens.first?.frame.height ?? 0
            return (TeamCoordinator.json(["displays": out, "mouse": ["x": Int(m.x), "y": Int(mainH - m.y)],
                                          "front_app": NSWorkspace.shared.frontmostApplication?.localizedName ?? ""]), false)
        } catch {
            return ("画面を撮れませんでした: \(error.localizedDescription)", true)
        }
    }

    private static func windows() -> [[String: Any]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0, (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) > 40 else { return nil }
            return ["app": w[kCGWindowOwnerName as String] as? String ?? "", "title": w[kCGWindowName as String] as? String ?? "",
                    "x": Int(b["X"] ?? 0), "y": Int(b["Y"] ?? 0), "width": Int(b["Width"] ?? 0), "height": Int(b["Height"] ?? 0)]
        }
    }

    // MARK: - アクセシビリティで部品を読む

    private static func uiElements(app name: String?, max: Int) -> String {
        let apps = NSWorkspace.shared.runningApplications
        guard let app = name.flatMap({ n in apps.first { $0.localizedName?.lowercased() == n.lowercased() || $0.bundleIdentifier == n } })
                ?? NSWorkspace.shared.frontmostApplication else { return "アプリが見つかりません" }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var out: [[String: Any]] = []
        func attr(_ e: AXUIElement, _ k: String) -> AnyObject? {
            var v: AnyObject?
            return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
        }
        func frame(_ e: AXUIElement) -> CGRect? {
            guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
            var pt = CGPoint.zero, sz = CGSize.zero
            guard CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
            AXValueGetValue(p as! AXValue, .cgPoint, &pt)
            AXValueGetValue(s as! AXValue, .cgSize, &sz)
            return CGRect(origin: pt, size: sz)
        }
        let interesting: Set<String> = ["AXButton", "AXTextField", "AXTextArea", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                                        "AXMenuButton", "AXLink", "AXTab", "AXMenuItem", "AXComboBox", "AXSlider", "AXCell",
                                        "AXStaticText", "AXImage", "AXSearchField", "AXDisclosureTriangle", "AXIncrementor"]
        var visited = 0
        func walk(_ e: AXUIElement, depth: Int) {
            guard out.count < max, visited < 4000, depth < 25 else { return }
            visited += 1
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if interesting.contains(role), let f = frame(e), f.width > 2, f.height > 2 {
                var item: [String: Any] = ["role": String(role.dropFirst(2)),
                                           "x": Int(f.midX), "y": Int(f.midY), "w": Int(f.width), "h": Int(f.height)]
                for (k, key) in [("title", kAXTitleAttribute), ("label", kAXDescriptionAttribute), ("value", kAXValueAttribute)] {
                    if let s = attr(e, key) as? String, !s.isEmpty { item[k] = String(s.prefix(80)) }
                }
                if role != "AXStaticText" || item["value"] != nil || item["title"] != nil { out.append(item) }
            }
            if let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
                for k in kids { walk(k, depth: depth + 1) }
            }
        }
        if let win = attr(root, kAXFocusedWindowAttribute), CFGetTypeID(win) == AXUIElementGetTypeID() {
            walk(win as! AXUIElement, depth: 0)
        } else {
            walk(root, depth: 0)
        }
        if let menu = attr(root, kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() {
            // メニューバーは上の階層だけ
            if let kids = attr(menu as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement] {
                for k in kids.prefix(15) {
                    if let t = attr(k, kAXTitleAttribute) as? String, let f = frame(k) {
                        out.append(["role": "MenuBarItem", "title": t, "x": Int(f.midX), "y": Int(f.midY)])
                    }
                }
            }
        }
        return TeamCoordinator.json(["app": app.localizedName ?? "", "elements": out,
                                     "note": "x, y は部品の中心（グローバル座標）"])
    }

    private static func openApp(_ n: String, reply: @escaping (String, Bool) -> Void) {
        let ws = NSWorkspace.shared
        let url = ws.urlForApplication(withBundleIdentifier: n)
            ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"]
                .map { URL(fileURLWithPath: $0).appendingPathComponent(n.hasSuffix(".app") ? n : "\(n).app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        if let running = ws.runningApplications.first(where: { $0.localizedName?.lowercased() == n.lowercased() }) {
            running.activate()
            reply("前面にしました: \(running.localizedName ?? n)", false)
            return
        }
        guard let url else { reply("アプリが見つかりません: \(n)", true); return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        ws.openApplication(at: url, configuration: cfg) { app, err in
            DispatchQueue.main.async {
                if let err { reply("開けませんでした: \(err.localizedDescription)", true) }
                else { reply("開きました: \(app?.localizedName ?? n)", false) }
            }
        }
    }

    // MARK: - マウスとキー（CGEvent。自分の印を付けて送る）

    private static let source: CGEventSource? = {
        let s = CGEventSource(stateID: .hidSystemState)
        s?.userData = marker
        return s
    }()

    private static func post(_ e: CGEvent?) {
        guard let e else { return }
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cghidEventTap)
    }

    private static func click(_ p: CGPoint, right: Bool, count: Int) {
        let (down, up, btn): (CGEventType, CGEventType, CGMouseButton) = right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: btn))
        for i in 1...count {
            let d = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: p, mouseButton: btn)
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            post(d)
            let u = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: p, mouseButton: btn)
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            post(u)
        }
    }

    private static func drag(from a: CGPoint, to b: CGPoint, done: @escaping () -> Void) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: a, mouseButton: .left))
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left))
        let steps = 20
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(i)) {
                let t = CGFloat(i) / CGFloat(steps)
                let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
                if i == steps {
                    post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))
                    done()
                }
            }
        }
    }

    private static func scroll(at p: CGPoint, dy: Int32, dx: Int32) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
        post(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
    }

    private static func type(_ text: String, done: @escaping () -> Void) {
        let units = Array(text.utf16)
        var chunks: [[UniChar]] = []
        var i = 0
        while i < units.count { chunks.append(Array(units[i..<min(i + 16, units.count)])); i += 16 }
        for (k, c) in chunks.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.012 * Double(k)) {
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    var chars = c
                    e?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
                    post(e)
                }
                if k == chunks.count - 1 { done() }
            }
        }
        if chunks.isEmpty { done() }
    }

    /// "cmd+shift+s return" のような指定を順に押す。わからないキーがあれば理由を返す
    private static func press(_ spec: String) -> String? {
        var combos: [(CGKeyCode, CGEventFlags)] = []
        for combo in spec.lowercased().split(separator: " ") {
            var flags: CGEventFlags = []
            var key: CGKeyCode?
            for part in combo.split(separator: "+").map(String.init) {
                switch part {
                case "cmd", "command", "⌘": flags.insert(.maskCommand)
                case "shift", "⇧": flags.insert(.maskShift)
                case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
                case "ctrl", "control", "⌃": flags.insert(.maskControl)
                case "fn": flags.insert(.maskSecondaryFn)
                default:
                    guard let k = keyCodes[part] else { return "わからないキー: \(part)（例: return, esc, tab, space, delete, up, down, left, right, a〜z, 0〜9, f1〜f12）" }
                    key = k
                }
            }
            guard let k = key else { return "キーがありません: \(combo)" }
            combos.append((k, flags))
        }
        for (k, f) in combos {
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: k, keyDown: down)
                e?.flags = f
                post(e)
            }
        }
        return nil
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51, "esc": 53, "escape": 53,
            "forwarddelete": 117, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
        ]
        let letters: [(String, CGKeyCode)] = [("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
                                              ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("o", 31), ("u", 32),
                                              ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("k", 40), ("n", 45), ("m", 46)]
        for (k, v) in letters { m[k] = v }
        let digits: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (i, v) in digits.enumerated() { m["\(i)"] = v }
        let fkeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, v) in fkeys.enumerated() { m["f\(i + 1)"] = v }
        return m
    }()
}

/// 操作中の目印：画面の縁をエージェントの色で光らせ、上に「〇〇 が操作中 — Esc で止める」
private final class ControlBorder {
    private var windows: [NSPanel] = []

    func show(name: String, color: NSColor) {
        hide()
        for s in NSScreen.screens {
            let w = NSPanel(contentRect: s.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.setFrame(s.frame, display: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let v = NSView(frame: NSRect(origin: .zero, size: s.frame.size))
            v.wantsLayer = true
            let b = CALayer()
            b.frame = v.bounds
            b.borderColor = color.withAlphaComponent(0.85).cgColor
            b.borderWidth = 4
            b.shadowColor = color.cgColor
            b.shadowOpacity = 0.9
            b.shadowRadius = 8
            b.shadowOffset = .zero
            v.layer?.addSublayer(b)
            if s == NSScreen.screens.first {
                let t = CATextLayer()
                let str = NSAttributedString(string: "🖱 \(name) が操作中 — Esc で止める", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .bold), .foregroundColor: NSColor.white])
                let sz = str.size()
                let pill = CALayer()
                pill.backgroundColor = color.blended(withFraction: 0.3, of: .black)?.withAlphaComponent(0.92).cgColor
                pill.cornerRadius = 11
                let top = s.frame.height - (s.frame.height - s.visibleFrame.maxY + s.frame.minY) - 30
                pill.frame = CGRect(x: (s.frame.width - sz.width) / 2 - 12, y: top, width: sz.width + 24, height: 22)
                t.string = str
                t.contentsScale = s.backingScaleFactor
                t.frame = CGRect(x: 12, y: (22 - sz.height) / 2, width: sz.width + 2, height: sz.height)
                pill.addSublayer(t)
                v.layer?.addSublayer(pill)
            }
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}
