import AppKit
import LinkPresentation
import QuickLookThumbnailing

/// チャットの中の画像・PDF・Web ページを、文の下に小さく表示する（Mac の標準の仕組みで）
/// - 画像・PDF：Quick Look のサムネイル（QLThumbnailGenerator）。押すと既定のアプリ（プレビューなど）で開く
/// - Web ページ：LinkPresentation（メッセージなどと同じリンクのプレビュー）で表紙の画像とタイトル。押すとブラウザで開く
/// 扱うのは、実在する画像・PDF のファイル（50MB まで）と http / https のページだけ。Web のプレビューはメニューで止められる。
/// Web のページを自動で読みに行くのは、ユーザー自身が書いた URL だけ。エージェントの返答に出てきた URL は、
/// 押したときだけ読みに行く（読み込んだ Web ページなどに仕込まれた指示で、エージェントが秘密を URL に入れて書いても、
/// アプリが勝手にそこへ送ってしまわないように）
enum ChatMedia {
    enum Kind: Equatable { case image, pdf, web }
    struct Ref: Hashable {
        let kind: Kind
        let url: URL
    }

    static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"]
    static let maxFileBytes = 50_000_000

    /// 文の中の画像・PDF のパス、Markdown の画像・リンク、URL を拾う（同じものは 1 回、最大 limit 個）
    static func refs(in text: String, limit: Int = 6, fileExists: (String) -> Bool = ChatMedia.fileOK) -> [Ref] {
        var out: [Ref] = []
        func add(_ r: Ref) { if !out.contains(r), out.count < limit { out.append(r) } }
        let ns = text as NSString
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Web のページ（先に見つけて、その中のパスはファイルとして拾わない）
        let urlRe = try! NSRegularExpression(pattern: #"https?://[^\s<>()\[\]"'`]+"#, options: [.caseInsensitive])
        let urlMatches = urlRe.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // ファイルのパス（/ か ~ で始まり、画像・PDF の拡張子で終わる。Markdown の ( ) やバッククォートの中も）
        let pathRe = try! NSRegularExpression(pattern: #"(?:~|/)[^\s"'`<>()\[\]]*?\.(?:png|jpe?g|gif|heic|heif|webp|tiff?|bmp|pdf)\b"#, options: [.caseInsensitive])
        for m in pathRe.matches(in: text, range: NSRange(location: 0, length: ns.length))
        where !urlMatches.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) {
            var p = ns.substring(with: m.range)
            if p.hasPrefix("~") { p = home + p.dropFirst() }
            guard p.hasPrefix("/"), fileExists(p) else { continue }
            let url = URL(fileURLWithPath: p)
            add(Ref(kind: url.pathExtension.lowercased() == "pdf" ? .pdf : .image, url: url))
        }
        for m in urlMatches {
            var s = ns.substring(with: m.range)
            while let last = s.last, ".,;:!?、。）」".contains(last) { s.removeLast() }
            guard let u = URL(string: s), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { continue }
            add(Ref(kind: .web, url: u))
        }
        return out
    }

    static func fileOK(_ path: String) -> Bool {
        let fm = FileManager.default
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &dir), !dir.boolValue,
              let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue, size <= maxFileBytes else { return false }
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExts.contains(ext) || ext == "pdf"
    }
}

/// サムネイルとリンクのプレビューを覚えておき、できたら知らせる
final class ChatMediaCache {
    static let shared = ChatMediaCache()
    private var thumbs: [String: NSImage] = [:]
    private var links: [URL: (title: String?, image: NSImage?)] = [:]
    private var pending = Set<String>()
    /// 押して「表紙を見る」を許した URL（このアプリが動いている間）
    private var allowedWeb = Set<URL>()
    private var failed = Set<String>()
    private let lock = NSLock()
    /// 何かができたとき（メインスレッド）
    var onUpdate: (() -> Void)?

    static let size = CGSize(width: 360, height: 220)
    static let previewScheme = "jellyfish-preview"

    /// 「表紙を見る」のリンク（押されたら allow(link:) で読みに行く）
    static func previewLink(for url: URL) -> URL? {
        guard let enc = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "\(previewScheme):\(enc)")
    }

    /// 「表紙を見る」のリンクが指す Web ページ（http / https だけ）
    static func target(of link: URL) -> URL? {
        guard link.scheme == previewScheme,
              let raw = link.absoluteString.dropFirst(previewScheme.count + 1).removingPercentEncoding,
              let u = URL(string: raw), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else { return nil }
        return u
    }

    /// 押された「表紙を見る」のリンクなら、その URL を許して読みに行き、true
    @discardableResult
    func allow(link: URL) -> Bool {
        guard let u = ChatMediaCache.target(of: link) else { return false }
        lock.lock(); allowedWeb.insert(u); lock.unlock()
        _ = self.link(u)
        return true
    }

    private func key(_ url: URL) -> String {
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "\(url.path)@\(m)"
    }

    /// ファイルのサムネイル（無ければ作り始めて nil）
    func thumbnail(_ url: URL) -> NSImage? {
        let k = key(url)
        lock.lock()
        if let t = thumbs[k] { lock.unlock(); return t }
        if pending.contains(k) || failed.contains(k) { lock.unlock(); return nil }
        pending.insert(k)
        lock.unlock()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: ChatMediaCache.size, scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            self.lock.lock()
            self.pending.remove(k)
            if let img = rep?.nsImage { self.thumbs[k] = img } else { self.failed.insert(k) }
            self.lock.unlock()
            DispatchQueue.main.async { self.onUpdate?() }
        }
        return nil
    }

    /// Web ページのタイトルと表紙の画像（無ければ読み始めて nil）
    func link(_ url: URL) -> (title: String?, image: NSImage?)? {
        let k = "web:" + url.absoluteString
        lock.lock()
        if let l = links[url] { lock.unlock(); return l }
        if pending.contains(k) || failed.contains(k) { lock.unlock(); return nil }
        pending.insert(k)
        lock.unlock()
        DispatchQueue.main.async {
            let p = LPMetadataProvider()
            p.timeout = 10
            p.startFetchingMetadata(for: url) { meta, _ in
                func done(_ title: String?, _ img: NSImage?) {
                    self.lock.lock()
                    self.pending.remove(k)
                    if title == nil && img == nil { self.failed.insert(k) } else { self.links[url] = (title, img) }
                    self.lock.unlock()
                    DispatchQueue.main.async { self.onUpdate?() }
                }
                guard let meta else { done(nil, nil); return }
                let provider = meta.imageProvider ?? meta.iconProvider
                guard let provider, provider.canLoadObject(ofClass: NSImage.self) else { done(meta.title, nil); return }
                provider.loadObject(ofClass: NSImage.self) { obj, _ in done(meta.title, obj as? NSImage) }
            }
        }
        return nil
    }

    /// チャットに入れる 1 つぶん（画像は押すと開く）。まだできていなければ「読み込み中」の 1 行
    /// autoWeb：Web のページを自動で読みに行ってよいか（ユーザー自身が書いた URL だけ true）
    func attachment(_ r: ChatMedia.Ref, webPreviews: Bool, autoWeb: Bool = true) -> NSAttributedString? {
        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.secondaryLabelColor]
        switch r.kind {
        case .image, .pdf:
            let name = r.url.lastPathComponent
            guard let img = thumbnail(r.url) else {
                return NSAttributedString(string: (r.kind == .pdf ? "📄 " : "🖼 ") + name + "\n", attributes: small.merging([.link: r.url]) { $1 })
            }
            let out = NSMutableAttributedString(attributedString: ChatMediaCache.imageAttachment(img, link: r.url))
            out.append(NSAttributedString(string: "\n" + (r.kind == .pdf ? "📄 " : "🖼 ") + name + "\n", attributes: small.merging([.link: r.url]) { $1 }))
            return out
        case .web:
            guard webPreviews else { return nil }
            lock.lock()
            let allowed = autoWeb || allowedWeb.contains(r.url) || links[r.url] != nil
            lock.unlock()
            guard allowed else {
                // 押したときだけ読みに行く
                guard let p = ChatMediaCache.previewLink(for: r.url) else { return nil }
                let out = NSMutableAttributedString(string: "🔗 " + (r.url.host ?? r.url.absoluteString) + "  ", attributes: small.merging([.link: r.url]) { $1 })
                out.append(NSAttributedString(string: L("表紙を見る"), attributes: small.merging([.link: p, .toolTip: L("このページを読みに行って、表紙の画像とタイトルを出します")]) { $1 }))
                out.append(NSAttributedString(string: "\n", attributes: small))
                return out
            }
            guard let l = link(r.url) else { return nil }
            let out = NSMutableAttributedString()
            if let img = l.image { out.append(ChatMediaCache.imageAttachment(img, link: r.url)); out.append(NSAttributedString(string: "\n")) }
            let title = (l.title?.isEmpty == false ? l.title! : r.url.host ?? r.url.absoluteString)
            out.append(NSAttributedString(string: "🔗 " + title + " — " + (r.url.host ?? "") + "\n", attributes: small.merging([.link: r.url]) { $1 }))
            return out
        }
    }

    static func imageAttachment(_ img: NSImage, link: URL) -> NSAttributedString {
        let a = NSTextAttachment()
        a.image = img
        let s = img.size
        let k = min(1, size.width / max(s.width, 1), size.height / max(s.height, 1))
        a.bounds = CGRect(x: 0, y: 0, width: s.width * k, height: s.height * k)
        let m = NSMutableAttributedString(attributedString: NSAttributedString(attachment: a))
        m.addAttribute(.link, value: link, range: NSRange(location: 0, length: m.length))
        m.addAttribute(.toolTip, value: link.isFileURL ? link.path : link.absoluteString, range: NSRange(location: 0, length: m.length))
        return m
    }
}
