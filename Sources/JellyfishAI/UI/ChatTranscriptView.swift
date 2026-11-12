import AppKit
import WebKit

/// チャットの会話の表示（表・数式・図・コードの色分け）。アプリの中の HTML（Resources/chat）を WKWebView で開き、
/// メッセージの一覧を JSON で渡す。ネットには取りに行かない（ページの CSP・画像は data: だけ・ナビゲーションは止める）。
/// リンクやボタンはページでは開かず、onOpen でアプリに渡す（アプリが確かめてから開く）
final class ChatTranscriptView: NSView, WKNavigationDelegate {
    let web: WKWebView
    private var ready = false
    private var pending: String?
    private var lastJS: String?
    private var scrollPending = false
    /// ページに渡したサムネイル（同じものは 2 回送らない。ページを読み直したら送り直す）
    private(set) var sentImages = Set<String>()
    /// ページのリンク・サムネイルが押されたとき
    var onOpen: ((String) -> Void)?
    /// ページを読み直したとき（全部を描き直してもらう）
    var onReload: (() -> Void)?

    /// まだ送っていないサムネイルだけを返し、送ったことにする
    func takeNewImages(_ all: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in all where !sentImages.contains(k) { out[k] = v; sentImages.insert(k) }
        return out
    }

    /// アプリの中の chat/index.html（無ければ nil）
    static var pageURL: URL? {
        var candidates = [Bundle.main.resourceURL?.appendingPathComponent("chat/index.html")]
        #if DEBUG
        // swift run のとき：ソースの Resources（配るビルドには、作った Mac の場所を入れない）
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/chat/index.html"))
        #endif
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    override init(frame: NSRect) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.suppressesIncrementalRendering = false
        let uc = WKUserContentController()
        cfg.userContentController = uc
        web = WKWebView(frame: frame, configuration: cfg)
        super.init(frame: frame)
        uc.add(MessageProxy(self), name: "jf")
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        // 窓のすりガラスの上に重ねるので、WebKit の白い背景を描かない（無い版では何もしない）
        if web.responds(to: Selector(("_setDrawsBackground:"))) { web.setValue(false, forKey: "drawsBackground") }
        web.underPageBackgroundColor = .clear
        web.autoresizingMask = [.width, .height]
        web.frame = bounds
        addSubview(web)
        if let page = ChatTranscriptView.pageURL {
            web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// メッセージの一覧を渡す（ページが読み込み終わる前なら、読み終わってから最後の 1 つだけ）
    func update(_ payload: [String: Any], scrollToEnd: Bool = false) {
        var p = payload
        if scrollToEnd || scrollPending { p["scrollToEnd"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: p), let json = String(data: data, encoding: .utf8) else { return }
        let js = "window.JF && JF.update(\(json));"
        lastJS = js
        if ready {
            scrollPending = false
            web.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pending = js
            scrollPending = scrollPending || scrollToEnd
        }
    }

    fileprivate func received(_ body: Any) {
        guard let d = body as? [String: Any], let type = d["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            if let js = pending ?? lastJS { pending = nil; web.evaluateJavaScript(js, completionHandler: nil) }
        case "open":
            if let href = d["href"] as? String, href.count < 4096 { onOpen?(href) }
        case "copy":
            if let text = d["text"] as? String, text.count < 2_000_000 {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default: break
        }
    }

    // MARK: ナビゲーション：最初のページを開くことだけ許す（リンクを押しても、ページの中では移動しない）

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = action.request.url, u.isFileURL, u.lastPathComponent == "index.html", action.navigationType == .other,
           let page = ChatTranscriptView.pageURL, u.standardizedFileURL.path == page.standardizedFileURL.path {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if action.navigationType == .linkActivated, let u = action.request.url { onOpen?(u.absoluteString) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // 表示のプロセスが落ちたら読み直す（アプリは落ちない）。サムネイルは送り直す
        ready = false
        sentImages.removeAll()
        onReload?()
        if let page = ChatTranscriptView.pageURL { web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent()) }
    }
}

/// WKUserContentController が強く持つので、間に挟んで循環を切る
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: ChatTranscriptView?
    init(_ t: ChatTranscriptView) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        // アプリの中のページからの知らせだけ受け取る
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true else { return }
        target?.received(message.body)
    }
}

extension NSColor {
    /// 「#RRGGBB」（ページの色に渡す）
    var hexRGB: String {
        guard let c = usingColorSpace(.sRGB) else { return "#0A84FF" }
        let v = { (x: CGFloat) in Int((max(0, min(1, x)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", v(c.redComponent), v(c.greenComponent), v(c.blueComponent))
    }
}
