// Keyboard shortcuts: the actions that have one, their defaults, and the text form of a key combination.
//
// A combination is written "cmd+shift+r": modifiers (cmd, shift, opt, ctrl) then the key, joined by "+".
// The key is the character the key types without modifiers in the current keyboard layout ("r", "[", "1", ","),
// or a name: left, right, up, down, return, tab, space, delete, escape, f1…f12. Menus match key equivalents by
// character, so a combination follows the layout (Colemak "r" is wherever Colemak puts r).
//
// Settings keep only overrides (`Settings.shortcuts`, action id -> combination, "" = no shortcut); everything
// else uses the default below.

import Foundation

public struct KeyCombo: Equatable, Hashable, Sendable {
    public var command = false
    public var shift = false
    public var option = false
    public var control = false
    /// Lowercased character, or a key name (see the file comment).
    public var key: String

    public init(key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    public static let keyNames: Set<String> = [
        "left", "right", "up", "down", "return", "tab", "space", "delete", "escape",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    /// Parses "cmd+shift+r". Accepts "⌘⇧R"-free aliases: command, opt, option, alt, ctrl, control. A lone "+" key is
    /// written "plus".
    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, !last.isEmpty else { return nil }
        var c = KeyCombo(key: "")
        for m in parts.dropLast() {
            switch m {
            case "cmd", "command": c.command = true
            case "shift": c.shift = true
            case "opt", "option", "alt": c.option = true
            case "ctrl", "control": c.control = true
            default: return nil
            }
        }
        let key = last == "plus" ? "+" : last
        guard key.count == 1 || Self.keyNames.contains(key) else { return nil }
        c.key = key
        self = c
    }

    /// The text form, modifiers in a fixed order: "cmd+shift+r".
    public var text: String {
        var p: [String] = []
        if control { p.append("ctrl") }
        if option { p.append("opt") }
        if shift { p.append("shift") }
        if command { p.append("cmd") }
        p.append(key == "+" ? "plus" : key)
        return p.joined(separator: "+")
    }

    /// The menu-style form: "⇧⌘R".
    public var display: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        let names: [String: String] = [
            "left": "←", "right": "→", "up": "↑", "down": "↓", "return": "↩", "tab": "⇥", "space": "Space",
            "delete": "⌫", "escape": "⎋",
        ]
        return s + (names[key] ?? key.uppercased())
    }

    /// A shortcut needs a modifier, except function keys (a plain letter would steal typing from the terminal).
    public var isUsable: Bool { command || control || option || key.hasPrefix("f") && key.count > 1 }
}

public struct ShortcutAction: Sendable, Equatable {
    public var id: String
    public var title: String
    public var group: String
    public var defaultCombo: KeyCombo?

    init(_ id: String, _ title: String, _ group: String, _ combo: String?) {
        self.id = id
        self.title = title
        self.group = group
        self.defaultCombo = combo.flatMap(KeyCombo.init)
    }
}

public enum Shortcuts {
    /// Every action with a shortcut, in menu order.
    public static let actions: [ShortcutAction] = {
        var a: [ShortcutAction] = [
            .init("settings", "Settings…", "App", "cmd+,"),
            .init("toggleSidebar", "Toggle Sidebar", "View", "ctrl+cmd+s"),
            .init("newWorkspace", "New Workspace", "Workspace", "cmd+n"),
            .init("previousWorkspace", "Previous Workspace", "Workspace", "shift+cmd+["),
            .init("nextWorkspace", "Next Workspace", "Workspace", "shift+cmd+]"),
        ]
        for i in 1...9 { a.append(.init("workspace\(i)", "Workspace \(i)", "Workspace", "cmd+\(i)")) }
        a += [
            .init("renameWorkspace", "Rename Workspace…", "Workspace", "shift+cmd+r"),
            .init("closeWorkspace", "Close Workspace", "Workspace", "shift+cmd+w"),
            .init("newTab", "New Tab", "Terminal", "cmd+t"),
            .init("splitRight", "Split Right", "Terminal", "cmd+d"),
            .init("splitDown", "Split Down", "Terminal", "shift+cmd+d"),
            .init("closeTab", "Close Tab", "Terminal", "cmd+w"),
            .init("previousTab", "Previous Tab", "Terminal", "cmd+["),
            .init("nextTab", "Next Tab", "Terminal", "cmd+]"),
        ]
        for d in ["Left", "Up", "Right", "Down"] {
            a.append(.init("focus\(d)", "Focus Card \(d)", "Terminal", "opt+cmd+\(d.lowercased())"))
        }
        for d in ["Left", "Up", "Right", "Down"] {
            a.append(.init("resize\(d)", "Resize \(d)", "Terminal", "ctrl+cmd+\(d.lowercased())"))
        }
        return a
    }()

    public static let ids: Set<String> = Set(actions.map(\.id))

    public static func action(_ id: String) -> ShortcutAction? { actions.first { $0.id == id } }

    /// The combination in effect for an action: the override if there is one ("" = none), else the default.
    public static func combo(_ id: String, in settings: Settings) -> KeyCombo? {
        if let o = settings.shortcuts[id] { return o.isEmpty ? nil : KeyCombo(o) }
        return action(id)?.defaultCombo
    }

    /// Other actions that use the same combination (shown as a conflict in the settings window).
    public static func conflicts(_ combo: KeyCombo, except id: String, in settings: Settings) -> [ShortcutAction] {
        actions.filter { $0.id != id && Self.combo($0.id, in: settings) == combo }
    }
}
