import AppKit
import MeumCore

/// The menu bar. Every default key from the contract is a menu key equivalent, so it is discoverable and
/// wins over the terminal (key equivalents are offered to the menu before the focused surface sees the key).
/// Command keys that are not in the menu fall through to the surface and reach Ghostty's own bindings
/// (⌘C/⌘V via the Edit menu actions, ⌘K, ⌘+/⌘-).
@MainActor
final class MainMenu: NSObject {
    let controller: WorkspaceController

    init(controller: WorkspaceController) {
        self.controller = controller
    }

    func install(settings: Settings) {
        self.settings = settings
        let main = NSMenu()

        let app = NSMenu(title: Product.name)
        app.addItem(withTitle: "About \(Product.name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
        app.addItem(.separator())
        let upd = app.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        upd.target = self
        settingsItem = item(app, "Settings…", "settings", #selector(openSettings))
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(Product.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(Product.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        add(edit, to: main)

        let view = NSMenu(title: "View")
        item(view, "Toggle Sidebar", "toggleSidebar", #selector(toggleSidebar))
        add(view, to: main)

        let ws = NSMenu(title: "Workspace")
        item(ws, "New Workspace", "newWorkspace", #selector(newWorkspace))
        item(ws, "Go to Workspace…", "goToWorkspace", #selector(goToWorkspace))
        item(ws, "Previous Workspace", "previousWorkspace", #selector(prevWorkspace))
        item(ws, "Next Workspace", "nextWorkspace", #selector(nextWorkspace))
        item(ws, "Go to Next Waiting Session", "nextWaiting", #selector(nextWaiting))
        ws.addItem(.separator())
        for i in 1...9 {
            let mi = item(ws, "Workspace \(i)", "workspace\(i)", #selector(selectWorkspace(_:)))
            mi.tag = i - 1
        }
        ws.addItem(.separator())
        item(ws, "Rename Workspace…", "renameWorkspace", #selector(renameWorkspace))
        item(ws, "Close Workspace", "closeWorkspace", #selector(closeWorkspace))
        add(ws, to: main)

        let term = NSMenu(title: "Terminal")
        item(term, "New Tab", "newTab", #selector(newTab))
        item(term, "Split Right", "splitRight", #selector(splitRight))
        item(term, "Split Down", "splitDown", #selector(splitDown))
        item(term, "Close Tab", "closeTab", #selector(closeTab))
        let widgetItem = NSMenuItem(title: "Add Widget", action: nil, keyEquivalent: "")
        let widgetMenu = NSMenu(title: "Add Widget")
        widgetMenu.delegate = self
        widgetItem.submenu = widgetMenu
        term.addItem(widgetItem)
        term.addItem(.separator())
        item(term, "Previous Tab", "previousTab", #selector(prevTab))
        item(term, "Next Tab", "nextTab", #selector(nextTab))
        term.addItem(.separator())
        let dirs: [(String, Direction)] = [("Left", .left), ("Up", .up), ("Right", .right), ("Down", .down)]
        for (name, d) in dirs {
            item(term, "Focus Card \(name)", "focus\(name)", #selector(focusCard(_:))).representedObject = d.rawValue
        }
        term.addItem(.separator())
        for (name, d) in dirs {
            item(term, "Resize \(name)", "resize\(name)", #selector(resizeCard(_:))).representedObject = d.rawValue
        }
        add(term, to: main)

        // Window: registered as the app's windows menu, so macOS adds Fill, Centre, Move & Resize and the tiling
        // items, as for any other app's window
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        add(win, to: main)
        NSApp.windowsMenu = win

        // Help: registered as the app's help menu, so macOS adds its search field (it finds every menu item)
        let help = NSMenu(title: "Help")
        for (title, topic) in [("Getting Started", HelpWindowController.Topic.start),
                               ("What the Dots and Labels Mean", .dots),
                               ("Command Line Tool, Claude Code and Control Socket", .cli)] {
            let mi = help.addItem(withTitle: title, action: #selector(openHelp(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = topic.rawValue
        }
        let mcp = help.addItem(withTitle: "Copy the Claude Code Setup Command", action: #selector(copyMCPCommand), keyEquivalent: "")
        mcp.target = self
        help.addItem(.separator())
        let keys = help.addItem(withTitle: "Keyboard Shortcuts…", action: #selector(openSettingsSection(_:)), keyEquivalent: "")
        keys.target = self
        keys.representedObject = "shortcuts"
        help.addItem(.separator())
        let un = help.addItem(withTitle: "Uninstall…", action: #selector(openHelp(_:)), keyEquivalent: "")
        un.target = self
        un.representedObject = HelpWindowController.Topic.uninstall.rawValue
        add(help, to: main)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
        applyShortcuts(self.settings)
    }

    /// The menu items that carry a customisable shortcut, by action id (MeumCore `Shortcuts`).
    private var bound: [String: NSMenuItem] = [:]
    private var settings = Settings()

    /// Sets every bound item's key equivalent from the settings (defaults plus overrides). Called again on
    /// every settings change, so a new shortcut works at once.
    func applyShortcuts(_ s: Settings) {
        settings = s
        for (id, mi) in bound {
            let combo = Shortcuts.combo(id, in: s)
            mi.keyEquivalent = combo.map(Self.keyEquivalent) ?? ""
            var m: NSEvent.ModifierFlags = []
            if combo?.command == true { m.insert(.command) }
            if combo?.shift == true { m.insert(.shift) }
            if combo?.option == true { m.insert(.option) }
            if combo?.control == true { m.insert(.control) }
            mi.keyEquivalentModifierMask = m
        }
    }

    static func keyEquivalent(_ c: KeyCombo) -> String {
        func fn(_ k: Int) -> String { String(Character(UnicodeScalar(k)!)) }
        switch c.key {
        case "left": return fn(NSLeftArrowFunctionKey)
        case "right": return fn(NSRightArrowFunctionKey)
        case "up": return fn(NSUpArrowFunctionKey)
        case "down": return fn(NSDownArrowFunctionKey)
        case "return": return "\r"
        case "tab": return "\t"
        case "space": return " "
        case "delete": return "\u{8}"
        case "escape": return "\u{1b}"
        default:
            if c.key.count > 1, c.key.hasPrefix("f"), let n = Int(c.key.dropFirst()) { return fn(NSF1FunctionKey + n - 1) }
            return c.key
        }
    }

    private func add(_ menu: NSMenu, to main: NSMenu) {
        let mi = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        mi.submenu = menu
        main.addItem(mi)
    }

    /// A menu item whose shortcut is the action's (see `applyShortcuts`).
    @discardableResult
    private func item(_ menu: NSMenu, _ title: String, _ actionID: String, _ action: Selector) -> NSMenuItem {
        precondition(Shortcuts.action(actionID) != nil, "unknown shortcut action \(actionID)")
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
        bound[actionID] = mi
        return mi
    }

    /// Opens the settings window (set by the app delegate).
    var onSettings: (() -> Void)?
    private var settingsItem: NSMenuItem?
    /// "Settings…" carries a badge while widgets or meum itself have an update.
    func setUpdateCount(_ n: Int) {
        settingsItem?.badge = n > 0 ? .updates(count: n) : nil
    }
    var onCheckForUpdates: (() -> Void)?
    /// Opens the help window at a topic, and the settings window at a section (set by the app delegate).
    var onHelp: ((HelpWindowController.Topic) -> Void)?
    var onSettingsSection: ((String) -> Void)?
    @objc func openHelp(_ s: NSMenuItem) {
        if let t = (s.representedObject as? String).flatMap(HelpWindowController.Topic.init(rawValue:)) { onHelp?(t) }
    }
    @objc func openSettingsSection(_ s: NSMenuItem) {
        if let id = s.representedObject as? String { onSettingsSection?(id) }
    }
    /// Copies the `claude mcp add` line, then shows where it is explained.
    @objc func copyMCPCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HelpWindowController.mcpCommand, forType: .string)
        onHelp?(.cli)
    }
    @objc func checkForUpdates() { onCheckForUpdates?() }
    @objc func openSettings() { onSettings?() }
    @objc func newWorkspace() { controller.newWorkspace() }
    @objc func toggleSidebar() { controller.setSidebarCollapsed(!controller.settings.sidebarCollapsed) }
    @objc func prevWorkspace() { controller.selectAdjacentWorkspace(-1) }
    @objc func nextWorkspace() { controller.selectAdjacentWorkspace(1) }
    @objc func goToWorkspace() { controller.switcher.toggle() }
    @objc func nextWaiting() { if !controller.selectNextWaitingSession() { NSSound.beep() } }
    @objc func selectWorkspace(_ s: NSMenuItem) { controller.selectWorkspace(at: s.tag) }
    @objc func renameWorkspace() { controller.renameSelectedWorkspace() }
    @objc func closeWorkspace() { controller.closeSelectedWorkspace() }
    @objc func newTab() { controller.newTab() }
    @objc func splitRight() { controller.split(.right) }
    @objc func splitDown() { controller.split(.down) }
    @objc func addWidget(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        controller.addWidgetTab(id)
    }
    @objc func closeTab() {
        // ⌘W in another window (settings) closes that window, not a terminal tab
        if let w = NSApp.keyWindow, w !== controller.window { w.performClose(nil); return }
        controller.closeFocusedTab()
    }
    @objc func prevTab() { controller.selectAdjacentTab(-1) }
    @objc func nextTab() { controller.selectAdjacentTab(1) }
    @objc func focusCard(_ s: NSMenuItem) {
        if let d = (s.representedObject as? String).flatMap(Direction.init(rawValue:)) { controller.moveFocus(d) }
    }
    @objc func resizeCard(_ s: NSMenuItem) {
        if let d = (s.representedObject as? String).flatMap(Direction.init(rawValue:)) { controller.resize(d) }
    }
}

extension MainMenu: NSMenuDelegate {
    /// Terminal ▸ Add Widget: every installed widget, as a new card to the right of the focused one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Add Widget" else { return }
        menu.removeAllItems()
        let entries = controller.widgets?.scan() ?? []
        if entries.isEmpty {
            menu.addItem(withTitle: "No widgets installed", action: nil, keyEquivalent: "").isEnabled = false
        }
        for e in entries {
            let mi = NSMenuItem(title: e.displayName, action: #selector(addWidget(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = e.id
            menu.addItem(mi)
        }
        // always a way to the library, also when some widget is installed already
        menu.addItem(.separator())
        let get = menu.addItem(withTitle: "Get Widgets…", action: #selector(openSettingsSection(_:)), keyEquivalent: "")
        get.target = self
        get.representedObject = "widgets"
    }
}
