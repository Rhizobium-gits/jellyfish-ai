import AppKit
import Carbon.HIToolbox

/// Carbon の RegisterEventHotKey によるグローバルショートカット。
/// アクセシビリティ権限なしで、アプリが背面にあっても動く。
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var installed = false
    private let signature: OSType = 0x4A45_4C59 // 'JELY'

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if st == noErr {
                let id = hk.id
                DispatchQueue.main.async { HotKeyCenter.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// 登録。他アプリが同じ組み合わせを登録済みなら eventHotKeyExistsErr が返る。
    func register(id: UInt32, _ spec: HotKeySpec, action: @escaping () -> Void) -> OSStatus {
        installHandlerIfNeeded()
        unregister(id)
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(spec.keyCode, spec.modifiers, EventHotKeyID(signature: signature, id: id),
                                     GetApplicationEventTarget(), 0, &ref)
        if st == noErr, let ref {
            refs[id] = ref
            actions[id] = action
        }
        return st
    }

    func unregister(_ id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        actions.removeValue(forKey: id)
    }

    func isRegistered(_ id: UInt32) -> Bool { refs[id] != nil }

    private func fire(_ id: UInt32) {
        AppLog.write("hotkey fired id=\(id)")
        actions[id]?()
    }
}

/// アプリのショートカット方針：
/// 1. 設定のキー（既定 ⌘L）を登録
/// 2. 他アプリに取られていたら代替キー（既定 ⌃⌥L）にフォールバックし、メニューに表示
/// 3. 設定した「素通しアプリ」が最前面の間だけ一時的に解放（ブラウザの ⌘L 等と共存したい場合）
final class Shortcuts {
    enum ID: UInt32 { case newJelly = 1, toggleVisibility = 2 }

    private let manager: JellyManager
    private(set) var activeNewJelly: HotKeySpec?
    private(set) var activeToggle: HotKeySpec?
    private(set) var conflictNote: String?
    private(set) var suspendedForApp: String?
    var onChange: (() -> Void)?

    init(manager: JellyManager) {
        self.manager = manager
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontAppChanged(app?.bundleIdentifier)
        }
    }

    func registerAll() {
        registerNewJelly()
        AppLog.write("hotkey newJelly: \(activeNewJelly?.display ?? "none") \(conflictNote ?? "")")
        let s = manager.settings
        if HotKeyCenter.shared.register(id: ID.toggleVisibility.rawValue, s.toggleVisibilityHotKey, action: { [weak self] in
            self?.manager.toggleAllHidden()
        }) == noErr {
            activeToggle = s.toggleVisibilityHotKey
        } else {
            activeToggle = nil
        }
        AppLog.write("hotkey toggle: \(activeToggle?.display ?? "none")")
        onChange?()
    }

    private func registerNewJelly() {
        let s = manager.settings
        let action: () -> Void = { [weak self] in self?.manager.spawn() }
        conflictNote = nil
        if HotKeyCenter.shared.register(id: ID.newJelly.rawValue, s.newJellyHotKey, action: action) == noErr {
            activeNewJelly = s.newJellyHotKey
        } else if HotKeyCenter.shared.register(id: ID.newJelly.rawValue, s.fallbackHotKey, action: action) == noErr {
            activeNewJelly = s.fallbackHotKey
            conflictNote = "\(s.newJellyHotKey.display) は他のアプリが使用中のため \(s.fallbackHotKey.display) を使用"
        } else {
            activeNewJelly = nil
            conflictNote = "\(s.newJellyHotKey.display) と \(s.fallbackHotKey.display) はどちらも使用中"
        }
    }

    private func frontAppChanged(_ bundleID: String?) {
        let list = manager.settings.hotKeyPassthroughApps
        if let id = bundleID, list.contains(id) {
            if HotKeyCenter.shared.isRegistered(ID.newJelly.rawValue) {
                HotKeyCenter.shared.unregister(ID.newJelly.rawValue)
                suspendedForApp = id
                onChange?()
            }
        } else if suspendedForApp != nil {
            suspendedForApp = nil
            registerNewJelly()
            onChange?()
        }
    }
}
