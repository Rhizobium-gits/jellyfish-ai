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
            // リンク（シンボリックリンク）は行き先で扱う（「report.png」という名前で実はスクリプト、を開かない）
            let url = resolvedFile(p) ?? URL(fileURLWithPath: p)
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

    static func fileOK(_ path: String) -> Bool { resolvedFile(path) != nil }

    /// リンクをたどった先が、ふつうのファイルで、画像・PDF の拡張子で、50MB までならその場所
    static func resolvedFile(_ path: String) -> URL? {
        let u = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true,
              (v.fileSize ?? Int.max) <= maxFileBytes else { return nil }
        let ext = u.pathExtension.lowercased()
        return imageExts.contains(ext) || ext == "pdf" ? u : nil
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

    /// チャットに出す 1 つぶん（会話の表示のページに渡す）。まだできていなければ、名前とリンクだけ
    struct Preview {
        var link: String
        var label: String
        var thumbKey: String?
        var thumbData: String?
        /// 押したときだけ読みに行く Web ページ（「表紙を見る」のリンク）
        var previewLink: String?
        var host: String?
    }

    /// autoWeb：Web のページを自動で読みに行ってよいか（ユーザー自身が打った URL だけ true）
    func preview(_ r: ChatMedia.Ref, webPreviews: Bool, autoWeb: Bool = true) -> Preview? {
        switch r.kind {
        case .image, .pdf:
            let label = (r.kind == .pdf ? "📄 " : "🖼 ") + r.url.lastPathComponent
            var p = Preview(link: r.url.absoluteString, label: label)
            if let img = thumbnail(r.url) {
                let k = key(r.url)
                p.thumbKey = k
                p.thumbData = dataURL(k, img)
            }
            return p
        case .web:
            guard webPreviews else { return nil }
            let host = r.url.host ?? r.url.absoluteString
            lock.lock()
            let allowed = autoWeb || allowedWeb.contains(r.url) || links[r.url] != nil
            lock.unlock()
            guard allowed else {
                // 押したときだけ読みに行く
                guard let pl = ChatMediaCache.previewLink(for: r.url) else { return nil }
                return Preview(link: r.url.absoluteString, label: "🔗 " + host, previewLink: pl.absoluteString, host: host)
            }
            guard let l = link(r.url) else { return nil }
            let title = (l.title?.isEmpty == false ? l.title! : host)
            var p = Preview(link: r.url.absoluteString, label: "🔗 " + title + " — " + host)
            if let img = l.image {
                let k = "web:" + r.url.absoluteString
                p.thumbKey = k
                p.thumbData = dataURL(k, img)
            }
            return p
        }
    }

    /// サムネイルを data: の URL に（ページはネットにもファイルにも取りに行かないので、中身ごと渡す。作ったものは覚えておく）
    private var dataURLs: [String: String] = [:]
    private func dataURL(_ key: String, _ img: NSImage) -> String? {
        lock.lock()
        if let d = dataURLs[key] { lock.unlock(); return d }
        lock.unlock()
        guard let d = ChatMediaCache.pngDataURL(img) else { return nil }
        lock.lock(); dataURLs[key] = d; lock.unlock()
        return d
    }

    static func pngDataURL(_ img: NSImage, maxEdge: CGFloat = 720) -> String? {
        let s = img.size
        let k = min(1, maxEdge / max(s.width, s.height, 1))
        let w = Int((s.width * k).rounded()), h = Int((s.height * k).rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
