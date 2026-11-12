// README 用のデモ録画ツール。
//
//   swiftc -O scripts/demo/recorder.swift -o .build/recorder
//   .build/recorder scripts/demo/<take>.json <出力フォルダ>
//
// - 指定した範囲に無地の背景ウィンドウを出し、Jellyfish AI のウィンドウとその背景だけを
//   ScreenCaptureKit で撮る（他のアプリ・通知・デスクトップは写らない）
// - タイムラインに沿って jellyfish:// URL を開いてアプリを操作する。
//   wait を付けた手順は、jellies.json の状態がそうなるまで待つ（Claude の応答時間に合わせる）
// - 出力：frame-00001.png …、frames.json（各フレームの時刻）、events.json（手順の時刻とクラゲの位置）
import AppKit
import CoreImage
import ScreenCaptureKit

struct Step: Decodable {
    var delay: Double?
    var mark: String?
    var url: String?
    var wait: Wait?
    var timeout: Double?
    var stop: Bool?
    struct Wait: Decodable { var agent: Int; var state: [String] }
}

struct Timeline: Decodable {
    var region: [Double]        // 左上原点のグローバル座標（ポイント）x, y, w, h
    var scale: Double?
    var fps: Double?
    var dataDir: String         // デモ用 JELLYFISH_DATA_DIR（状態待ちに使う）
    var background: [String]?   // グラデーションの色（#RRGGBB）
    var steps: [Step]
}

let args = CommandLine.arguments
let demoApp = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/JellyfishAI.app")
guard args.count >= 3 else { print("usage: recorder <timeline.json> <outdir>"); exit(2) }
let timeline = try! JSONDecoder().decode(Timeline.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func color(_ hex: String) -> CGColor {
    var v: UInt64 = 0
    Scanner(string: hex.replacingOccurrences(of: "#", with: "")).scanHexInt64(&v)
    return CGColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let tl: Timeline
    var stream: SCStream?
    var backdrop: NSWindow!
    let writeQueue = DispatchQueue(label: "write")
    let ci = CIContext()
    var frames: [[String: Any]] = []
    var events: [[String: Any]] = []
    var start = Date()
    var frameNo = 0
    let lock = NSLock()

    init(_ tl: Timeline) { self.tl = tl }

    var regionTopLeft: CGRect { CGRect(x: tl.region[0], y: tl.region[1], width: tl.region[2], height: tl.region[3]) }

    func showBackdrop() {
        let primaryHeight = NSScreen.screens[0].frame.height
        let r = regionTopLeft
        let cocoa = NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
        let w = NSWindow(contentRect: cocoa, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .normal
        w.isOpaque = true
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let v = NSView(frame: NSRect(origin: .zero, size: cocoa.size))
        v.wantsLayer = true
        let g = CAGradientLayer()
        g.frame = v.bounds
        g.colors = (tl.background ?? ["#1F2A4D", "#34507E", "#6F95BD"]).map(color)
        g.startPoint = CGPoint(x: 0, y: 1)
        g.endPoint = CGPoint(x: 1, y: 0)
        v.layer = g
        w.contentView = v
        w.orderFrontRegardless()
        backdrop = w
    }

    func startCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let me = ProcessInfo.processInfo.processIdentifier
        let apps = content.applications.filter { $0.processID == me || $0.bundleIdentifier == "ai.jellyfish.desktop" }
        guard apps.contains(where: { $0.bundleIdentifier == "ai.jellyfish.desktop" }) else {
            print("JellyfishAI が起動していません"); exit(1)
        }
        let r = regionTopLeft
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }) else {
            print("範囲を含むディスプレイがありません"); exit(1)
        }
        let filter = SCContentFilter(display: display, including: apps, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let scale = tl.scale ?? 2
        cfg.sourceRect = CGRect(x: r.minX - display.frame.minX, y: r.minY - display.frame.minY, width: r.width, height: r.height)
        cfg.width = Int(r.width * scale)
        cfg.height = Int(r.height * scale)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(tl.fps ?? 20))
        cfg.showsCursor = false
        cfg.queueDepth = 8
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
        start = Date()
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        let t = Date().timeIntervalSince(start)
        guard let img = ci.createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))) else { return }
        lock.lock(); frameNo += 1; let n = frameNo; frames.append(["n": n, "t": t]); lock.unlock()
        writeQueue.async {
            let url = outDir.appendingPathComponent(String(format: "frame-%05d.png", n))
            if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, img, nil)
                CGImageDestinationFinalize(d)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { print("stream stopped: \(error)") }

    /// jellies.json から各クラゲの状態を読む
    func state(of agent: Int) -> String? {
        let url = URL(fileURLWithPath: (tl.dataDir as NSString).expandingTildeInPath).appendingPathComponent("jellies.json")
        guard let d = try? Data(contentsOf: url), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return nil }
        return arr.first { ($0["number"] as? Int) == agent }?["state"] as? String
    }

    /// その時点の Jellyfish のウィンドウ（位置は録画範囲内の座標）
    func jellyWindows() -> [[String: Any]] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "ai.jellyfish.desktop").map(\.processIdentifier))
        let r = regionTopLeft
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
            return ["x": (b["X"] ?? 0) - r.minX, "y": (b["Y"] ?? 0) - r.minY, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0,
                    "layer": w[kCGWindowLayer as String] as? Int ?? 0]
        }
    }

    func log(_ mark: String) {
        let t = Date().timeIntervalSince(start)
        events.append(["mark": mark, "t": t, "windows": jellyWindows()])
        print(String(format: "%6.2f  %@", t, mark))
    }

    /// 全クラゲの状態を 10Hz で見て、変わったら events に残す（字幕のタイミング用）
    var lastStates: [Int: String] = [:]
    func watchStates() {
        let url = URL(fileURLWithPath: (tl.dataDir as NSString).expandingTildeInPath).appendingPathComponent("jellies.json")
        guard let d = try? Data(contentsOf: url), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { return }
        for j in arr {
            guard let n = j["number"] as? Int, let st = j["state"] as? String, lastStates[n] != st else { continue }
            lastStates[n] = st
            log("state:\(n):\(st)")
        }
    }

    func run() async {
        // アプリの起動を待つ（起動直後のクラゲ出現アニメーションが落ち着くまで）
        for _ in 0..<100 where NSRunningApplication.runningApplications(withBundleIdentifier: "ai.jellyfish.desktop").isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await MainActor.run { showBackdrop() }
        try? await Task.sleep(nanoseconds: 400_000_000)
        do { try await startCapture() } catch { print("capture failed: \(error)"); exit(1) }
        await MainActor.run {
            log("start")
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.watchStates() }
            RunLoop.main.add(t, forMode: .common)
        }
        for step in tl.steps {
            if let d = step.delay { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
            if let w = step.wait {
                let limit = Date().addingTimeInterval(step.timeout ?? 180)
                while Date() < limit, !(state(of: w.agent).map(w.state.contains) ?? false) {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            if let u = step.url, let url = URL(string: u) {
                // 作業中のアプリからフォーカスを奪わないよう、前面化せずに URL を渡す。
                // アプリケーションフォルダにも Jellyfish AI があるので、録画用に起動した dist/ の方へ明示して渡す
                await MainActor.run {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = false
                    NSWorkspace.shared.open([url], withApplicationAt: demoApp, configuration: cfg) { _, _ in }
                }
            }
            if let m = step.mark { await MainActor.run { log(m) } }
            if step.stop == true { break }
        }
        try? await stream?.stopCapture()
        writeQueue.sync {}
        let meta: [String: Any] = lock.withLock { ["region": tl.region, "scale": tl.scale ?? 2, "frames": frames, "events": events] }
        let d = try! JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
        try! d.write(to: outDir.appendingPathComponent("timeline.json"))
        print("frames: \(frames.count)")
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let recorder = Recorder(timeline)
Task { await recorder.run() }
app.run()
