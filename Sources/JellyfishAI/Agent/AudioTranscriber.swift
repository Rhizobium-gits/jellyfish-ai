import AVFAudio
import AppKit
import ScreenCaptureKit
import Speech

/// システムの音（Mac から流れている音。Jellyfish 自身の音は除く）を拾って、その場で文字にする。
/// - 音の取り込みは ScreenCaptureKit（画面収録の権限が必要）
/// - 文字起こしは macOS 26 の SpeechAnalyzer / SpeechTranscriber（端末内で処理。初回は言語モデルを OS がダウンロード）
/// - 確定した文を時刻つきでテキストファイルに追記する（議事録・翻訳はエージェントがこのファイルから作る）
@available(macOS 26.0, *)
final class AudioTranscriber: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let fileURL: URL
    private(set) var startedAt = Date()
    private(set) var lines: [String] = []
    private(set) var partial = ""
    private(set) var isRunning = false
    /// メインスレッドで呼ばれる
    var onUpdate: (() -> Void)?

    private var stream: SCStream?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private let audioQueue = DispatchQueue(label: "jellyfish.audio")
    private let handle: FileHandle?

    init(dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        fileURL = dir.appendingPathComponent("transcript-\(f.string(from: Date())).txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        super.init()
    }

    /// 使える言語（日本語を優先、なければ英語）
    static func locale(preferred: String) async -> Locale? {
        for id in [preferred, "ja-JP", "en-US"] {
            if let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) { return l }
        }
        return nil
    }

    func start(language: String = "ja-JP") async throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw NSError(domain: "Jellyfish", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "システムの音を拾うには画面収録の権限が必要です（システム設定 › プライバシーとセキュリティ › 画面収録 で Jellyfish AI を許可）"])
        }
        guard let loc = await AudioTranscriber.locale(preferred: language) else {
            throw NSError(domain: "Jellyfish", code: 2, userInfo: [NSLocalizedDescriptionKey: "この Mac では音声の文字起こしに対応した言語が見つかりません"])
        }
        let transcriber = SpeechTranscriber(locale: loc, preset: .progressiveTranscription)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
        analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (seq, cont) = AsyncStream<AnalyzerInput>.makeStream()
        input = cont
        let an = SpeechAnalyzer(modules: [transcriber])
        analyzer = an
        try await an.start(inputSequence: seq)
        startedAt = Date()
        write("# 文字起こし \(ISO8601DateFormatter().string(from: startedAt))（\(loc.identifier)、システムの音）\n")

        resultsTask = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if r.isFinal {
                        if !text.isEmpty {
                            let t = Int(r.range.start.seconds.isFinite ? r.range.start.seconds : Date().timeIntervalSince(self.startedAt))
                            let line = String(format: "[%02d:%02d] ", t / 60, t % 60) + text
                            self.write(line + "\n")
                            await MainActor.run { self.lines.append(line); self.partial = ""; self.onUpdate?() }
                        }
                    } else {
                        await MainActor.run { self.partial = text; self.onUpdate?() }
                    }
                }
            } catch {
                AppLog.write("transcriber results error: \(error)")
            }
        }

        // 音だけ欲しいので映像は最小（2×2・1fps）
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw NSError(domain: "Jellyfish", code: 3, userInfo: [NSLocalizedDescriptionKey: "ディスプレイが見つかりません"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
        try await s.startCapture()
        stream = s
        isRunning = true
        AppLog.write("transcriber started \(loc.identifier) → \(fileURL.lastPathComponent)")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        try? await stream?.stopCapture()
        stream = nil
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await resultsTask?.value
        let dur = Int(Date().timeIntervalSince(startedAt))
        write(String(format: "\n# 終了（%d 分 %d 秒）\n", dur / 60, dur % 60))
        try? handle?.close()
        AppLog.write("transcriber stopped lines=\(lines.count)")
        await MainActor.run { self.onUpdate?() }
    }

    private func write(_ s: String) {
        guard let d = s.data(using: .utf8) else { return }
        handle?.write(d)
    }

    // MARK: - ScreenCaptureKit

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let buf = pcmBuffer(sb) else { return }
        guard let target = analyzerFormat else { input?.yield(AnalyzerInput(buffer: buf)); return }
        if buf.format == target { input?.yield(AnalyzerInput(buffer: buf)); return }
        if converter == nil || converter?.inputFormat != buf.format {
            converter = AVAudioConverter(from: buf.format, to: target)
        }
        guard let conv = converter else { return }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio + 32)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if err == nil, out.frameLength > 0 { input?.yield(AnalyzerInput(buffer: out)) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppLog.write("transcriber stream stopped: \(error.localizedDescription)")
        Task { await self.stop() }
    }

    private func pcmBuffer(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
        var a = asbd.pointee
        guard let fmt = AVAudioFormat(streamDescription: &a) else { return nil }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        buf.frameLength = n
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }

    /// 音声ファイルを文字にする（動作確認用：`JellyfishAI --transcribe file.aiff`）
    static func transcribeFile(_ path: String) async -> Int32 {
        guard let loc = await locale(preferred: "ja-JP") else { print("対応言語なし"); return 1 }
        let tr = SpeechTranscriber(locale: loc, preset: .transcription)
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: [tr]) {
                print("言語モデルをダウンロード中…")
                try await req.downloadAndInstall()
            }
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let collect = Task { () -> [String] in
                var out: [String] = []
                for try await r in tr.results where r.isFinal { out.append(String(r.text.characters)) }
                return out
            }
            let an = try await SpeechAnalyzer(inputAudioFile: file, modules: [tr], finishAfterFile: true)
            _ = an
            let lines = try await collect.value
            print("[\(loc.identifier)] " + lines.joined(separator: " "))
            return 0
        } catch {
            print("失敗: \(error)")
            return 1
        }
    }
}
