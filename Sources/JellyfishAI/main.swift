import AppKit

let args = CommandLine.arguments
// claude の子プロセスとして MCP の中継役になるモード（チーム機能）
if TeamBridge.handles(args) {
    exit(TeamBridge.run(args))
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
