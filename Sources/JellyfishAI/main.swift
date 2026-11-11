import AppKit

let args = CommandLine.arguments
// claude の子プロセスとして MCP の中継役になるモード（チーム機能）
if TeamBridge.handles(args) {
    exit(TeamBridge.run(args))
}
// 文字起こしの動作確認：JellyfishAI --transcribe file.aiff
if let i = args.firstIndex(of: "--transcribe"), args.count > i + 1 {
    if #available(macOS 26.0, *) {
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = 1
        let path = args[i + 1]
        Task.detached { code = await AudioTranscriber.transcribeFile(path); sem.signal() }
        sem.wait()
        exit(code)
    }
    exit(1)
}
if SnapshotTool.handles(args) {
    exit(SnapshotTool.run(args))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Dock に出さない常駐アプリ（Info.plist の LSUIElement と同じ効果）
app.setActivationPolicy(.accessory)
app.run()
