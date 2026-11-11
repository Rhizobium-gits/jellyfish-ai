import AppKit

/// クロージャで動く NSMenuItem
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [.command],
         checked: Bool = false, image: NSImage? = nil, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        state = checked ? .on : .off
        self.image = image
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

extension NSMenuItem {
    static func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

enum MenuImages {
    /// エージェント色の丸
    static func dot(_ c: JellyColor, state: AgentState) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        return NSImage(size: size, flipped: false) { rect in
            let col: NSColor
            switch state {
            case .error: col = NSColor(srgbRed: 1, green: 0.32, blue: 0.28, alpha: 1)
            case .cancelled: col = NSColor(white: 0.6, alpha: 1)
            default: col = NSColor(srgbRed: CGFloat(c.base.x), green: CGFloat(c.base.y), blue: CGFloat(c.base.z), alpha: 1)
            }
            col.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
    }

    /// メニューバー用の Claude キャラクターのシルエット（テンプレート画像、目は抜き）
    static func statusIcon() -> NSImage {
        let rows = [
            ".#########.",
            ".#########.",
            "##.#####.##",
            "###########",
            ".#########.",
            ".#########.",
            ".#.#...#.#.",
            ".#.#...#.#.",
        ]
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            let c: CGFloat = 1.5
            let ox = (18 - 11 * c) / 2, oy = (18 - 8 * c) / 2
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: ox + CGFloat(x) * c, y: oy + CGFloat(y) * c, width: c, height: c).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}
