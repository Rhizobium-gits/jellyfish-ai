import AppKit

let args = CommandLine.arguments
if SnapshotTool.handles(args) {
    exit(SnapshotTool.run(args))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Dock に出さない常駐アプリ（Info.plist の LSUIElement と同じ効果）
app.setActivationPolicy(.accessory)
app.run()
