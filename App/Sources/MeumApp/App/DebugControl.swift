import AppKit
import Carbon
import GhosttyKit
import MeumControl
import MeumCore

/// A scriptable test entry point, enabled with `--debug-dir DIR` / `MEUM_DEBUG_DIR`.
///
/// On launch the app writes `DIR/pid` and `DIR/window.id` (the CGWindow number, for `screencapture -l`).
/// Commands go into `DIR/cmd`, one per line; the app polls every 100 ms, deletes the file, runs each line and
/// appends `ok <n> <line>` or `err <n> <line>: <reason>` to `DIR/events.log` (n counts from 1 per launch).
///
///   dump-model FILE                     the model plus live view state as JSON
///   dump-text TAB|focused FILE [all]    the surface's viewport (or screen incl. scrollback with `all`)
///   type TEXT                           key input into the focused surface (`\n` = Return, `\t` = Tab)
///   keys TEXT                           NSEvent keyDown/keyUp through the window (the real input path)
///   paste TEXT                          a paste into the focused surface
///   ime MARKED COMMIT                   NSTextInputClient: setMarkedText(MARKED) then insertText(COMMIT)
///   marked TEXT                         NSTextInputClient: setMarkedText(TEXT) only
///   action BINDING                      a Ghostty binding action on the focused surface (scroll_to_top …)
///   drop TAB file:PATH|text:T|png:PATH  a simulated drop onto a tab's terminal, from a private pasteboard
///   key KEYCODE                         a plain key press through the event queue (53: Escape)
///   chord COMBO [KEYCODE]               a key chord ("shift+cmd+r") through NSApp.sendEvent: local monitors, menu
///                                       key equivalents, then the key window (KEYCODE default: US layout)
///   record-shortcut ID                  Settings ▸ Shortcuts starts recording for action ID (the window must be open)
///   menu TITLE                          performs the menu item with that title (exercises the key bindings)
///   new-workspace [NAME]  select INDEX  rename INDEX NAME  move FROM TO  close-workspace INDEX
///   new-tab  split right|down  close-tab  focus DIR  resize DIR  next-tab  prev-tab
///   agent TAB|focused running|idle|needsInput|end [unread]   feeds a synthetic Claude hook to the agent tracker
///   snapshot TAB|focused SESSIONID      stores an AgentSnapshot on the tab (for the resume path)
///   rename-ui                           opens the sidebar's inline rename for the selected workspace
///   switcher open|close|toggle          Go to Workspace (⌘P); its state is "switcher" in dump-model
///   switcher query TEXT                 types TEXT into its field (replacing what is there)
///   switcher move N  switcher choose [N]   moves the selection by N rows; goes to the selected (or Nth) row
///   switcher shot FILE                  a PNG of its list (the field and the blur don't draw off screen)
///   quit
@MainActor
final class DebugControl {
    let dir: URL
    let controller: WorkspaceController
    let control: AppControl?
    /// Set by the app delegate.
    var settingsWindow: SettingsWindowController?
    var help: HelpWindowController?
    /// Links a status click would have opened (the debug instance opens nothing).
    var openedURLs: [String] = []
    /// How a debug instance answers "open links of this kind?" (`link-answer yes|no`); each question is recorded.
    var linkSchemeAnswer = false
    var linkSchemeQuestions: [String] = []
    private var timer: Timer?
    private var counter = 0

    init(dir: URL, controller: WorkspaceController, control: AppControl?) {
        self.dir = dir
        self.controller = controller
        self.control = control
    }

    func start() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? "\(getpid())\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        try? "\(controller.window.windowNumber)\n".write(to: dir.appendingPathComponent("window.id"),
                                                         atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("cmd"))
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        log("ready pid=\(getpid()) window=\(controller.window.windowNumber)")
    }

    private func log(_ s: String) {
        let url = dir.appendingPathComponent("events.log")
        let line = s + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func poll() {
        let url = dir.appendingPathComponent("cmd")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        for raw in s.split(separator: "\n", omittingEmptySubsequences: true) {
            counter += 1
            let line = String(raw)
            do {
                try run(line)
                log("ok \(counter) \(line)")
            } catch {
                log("err \(counter) \(line): \(error)")
            }
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    private func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\t", with: "\t")
    }

    private func surface(_ ref: String) throws -> SurfaceView {
        if ref == "focused" {
            guard let s = controller.focusedSurface else { throw Failure(description: "no focused surface") }
            return s
        }
        guard let id = UUID(uuidString: ref), let s = controller.surface(forTab: id) else {
            throw Failure(description: "no surface for tab \(ref)")
        }
        return s
    }

    private func run(_ line: String) throws {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts[0]
        let rest = parts.count > 1 ? parts[1] : ""
        let args = rest.split(separator: " ").map(String.init)
        switch cmd {
        case "dump-model":
            guard let path = args.first else { throw Failure(description: "need FILE") }
            try dumpModel().write(to: URL(fileURLWithPath: path))
        case "dump-text":
            guard args.count >= 2 else { throw Failure(description: "need TAB FILE") }
            let s = try surface(args[0])
            guard let text = s.readText(all: args.count > 2 && args[2] == "all") else {
                throw Failure(description: "read_text failed")
            }
            try text.write(toFile: args[1], atomically: true, encoding: .utf8)
        case "type":
            try surface("focused").inject(text: unescape(rest))
        case "keys":
            try synthesizeKeys(unescape(rest))
        case "paste":
            try surface("focused").insertPasted(text: unescape(rest))
        case "ime":
            guard args.count >= 2 else { throw Failure(description: "need MARKED COMMIT") }
            let s = try surface("focused")
            s.setMarkedText(args[0], selectedRange: NSRange(location: args[0].utf16.count, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
            guard s.hasMarkedText() else { throw Failure(description: "marked text not set") }
            s.insertText(args[1], replacementRange: NSRange(location: NSNotFound, length: 0))
            guard !s.hasMarkedText() else { throw Failure(description: "marked text not cleared") }
        case "marked":
            let s = try surface("focused")
            s.setMarkedText(rest, selectedRange: NSRange(location: rest.utf16.count, length: 0),
                            replacementRange: NSRange(location: NSNotFound, length: 0))
        case "action":
            guard try surface("focused").performBindingAction(rest) else { throw Failure(description: "rejected") }
        case "chord":
            guard let combo = args.first.flatMap(KeyCombo.init) else { throw Failure(description: "need COMBO like shift+cmd+r") }
            var mods: NSEvent.ModifierFlags = []
            if combo.command { mods.insert(.command) }
            if combo.shift { mods.insert(.shift) }
            if combo.option { mods.insert(.option) }
            if combo.control { mods.insert(.control) }
            let chars = MainMenu.keyEquivalent(combo)
            let shown = combo.shift ? chars.uppercased() : chars
            let code = args.count > 1 ? UInt16(args[1]) ?? 0
                : (Self.layoutKeyCode(for: combo.key) ?? Self.usKeyCodes[Character(combo.key.count == 1 ? combo.key : " ")] ?? 0)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods,
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: NSApp.keyWindow?.windowNumber ?? controller.window.windowNumber,
                                                context: nil, characters: shown, charactersIgnoringModifiers: chars,
                                                isARepeat: false, keyCode: code) else { throw Failure(description: "event") }
                NSApp.sendEvent(ev)
            }
        case "key":
            // key KEYCODE: a plain key press (no modifiers) queued with NSApp.postEvent, so it passes the local
            // event monitors as a typed key does, e.g. `key 53` for Escape
            guard let code = args.first.flatMap(UInt16.init) else { throw Failure(description: "need KEYCODE") }
            let chars = code == 53 ? "\u{1b}" : ""
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: controller.window.windowNumber, context: nil,
                                                characters: chars, charactersIgnoringModifiers: chars,
                                                isARepeat: false, keyCode: code) else { throw Failure(description: "event") }
                NSApp.postEvent(ev, atStart: false)
            }
        case "drop":
            // drop TAB file:PATH | text:TEXT | png:PATH   a simulated drag onto a tab's terminal (its real
            // draggingEntered/performDragOperation), from a private pasteboard: the user's clipboard is untouched
            guard args.count >= 2, let id = UUID(uuidString: args[0]), let s = controller.surface(forTab: id) else {
                throw Failure(description: "need TAB file:PATH|text:TEXT|png:PATH")
            }
            let pb = NSPasteboard(name: .init("meum.debug.drop"))
            pb.clearContents()
            let what = args.dropFirst().joined(separator: " ")
            if what.hasPrefix("file:") {
                pb.writeObjects([URL(fileURLWithPath: String(what.dropFirst(5))) as NSURL])
            } else if what.hasPrefix("png:") {
                pb.setData(try Data(contentsOf: URL(fileURLWithPath: String(what.dropFirst(4)))), forType: .png)
            } else {
                pb.setString(what.hasPrefix("text:") ? String(what.dropFirst(5)) : what, forType: .string)
            }
            let info = DebugDrag(pasteboard: pb, window: controller.window)
            guard s.draggingEntered(info) == .copy else { throw Failure(description: "drop refused") }
            guard s.performDragOperation(info) else { throw Failure(description: "drop failed") }
        case "ghostty-reload":
            // what Settings > Terminal > Reload does: read the Ghostty config files again
            GhosttyApp.shared.reloadFromDisk()
        case "record-shortcut":
            NotificationCenter.default.post(name: ShortcutsSection.recordRequest, object: rest)
        case "menu":
            guard let item = Self.findMenuItem(rest, in: NSApp.mainMenu) else {
                throw Failure(description: "no menu item \(rest)")
            }
            item.menu?.performActionForItem(at: item.menu!.index(of: item))
        case "new-workspace":
            controller.newWorkspace(name: rest.isEmpty ? nil : rest)
        case "select":
            controller.selectWorkspace(at: Int(rest) ?? 0)
        case "rename":
            guard args.count >= 2, let i = Int(args[0]), controller.store.state.workspaces.indices.contains(i) else {
                throw Failure(description: "need INDEX NAME")
            }
            let name = rest.split(separator: " ", maxSplits: 1).map(String.init)[1]
            controller.sidebarRename(controller.store.state.workspaces[i].id, to: name)
        case "rename-field":
            // rename-field TEXT: types into the open inline rename field and presses Return
            guard let f = controller.sidebarCard.sidebar.renameField else { throw Failure(description: "no rename field open") }
            f.stringValue = rest
            _ = f.sendAction(f.action, to: f.target)
        case "move":
            guard args.count == 2, let from = Int(args[0]), let to = Int(args[1]),
                  controller.store.state.workspaces.indices.contains(from) else {
                throw Failure(description: "need FROM TO")
            }
            controller.sidebarMove(controller.store.state.workspaces[from].id, to: to)
        case "close-workspace":
            guard let i = Int(rest), controller.store.state.workspaces.indices.contains(i) else {
                throw Failure(description: "need INDEX")
            }
            controller.closeWorkspace(controller.store.state.workspaces[i].id)
        case "new-tab": controller.newTab()
        case "split":
            controller.split(rest == "down" ? .down : .right)
        case "close-tab": controller.closeFocusedTab()
        case "next-tab": controller.selectAdjacentTab(1)
        case "prev-tab": controller.selectAdjacentTab(-1)
        case "focus":
            guard let d = Direction(rawValue: rest) else { throw Failure(description: "bad direction") }
            controller.moveFocus(d)
        case "resize":
            guard let d = Direction(rawValue: rest) else { throw Failure(description: "bad direction") }
            controller.resize(d)
        case "open-url":
            // open-url URL: what opening a meum:// link does (without LaunchServices, which might pick another meum)
            guard let url = URL(string: rest), let app = NSApp.delegate as? AppDelegate else { throw Failure(description: "need URL") }
            app.openLink(url)
        case "link-answer":
            // link-answer yes|no: the answer to the next "open links of this kind?" questions
            linkSchemeAnswer = rest == "yes"
        case "agent":
            guard let control, args.count >= 2 else { throw Failure(description: "need TAB PHASE") }
            let tab = try surface(args[0]).tabID
            let sid = "debug-" + tab.uuidString.prefix(8).lowercased()
            func hook(_ event: String, _ extra: [String: JSON] = [:]) throws {
                var payload: [String: JSON] = ["hook_event_name": .string(event), "session_id": .string(sid),
                                               "cwd": .string(NSHomeDirectory())]
                for (k, v) in extra { payload[k] = v }
                _ = try control.handleHook(["tab": .string(tab.uuidString), "payload": .object(payload)])
            }
            if control.agents.state(of: tab.uuidString) == nil, args[1] != "end" { try hook("SessionStart", ["source": "startup"]) }
            switch args[1] {
            case "running": try hook("UserPromptSubmit", ["prompt": "debug"])
            case "idle": try hook("Stop")
            case "needsInput": try hook("Notification", ["notification_type": "permission_prompt", "message": "debug"])
            case "end": try hook("SessionEnd", ["reason": "prompt_input_exit"])
            default: throw Failure(description: "bad phase")
            }
            if args.count > 2, args[2] == "unread" { control.agents.markUnread(tabs: [tab.uuidString]) }
        case "window-frame":
            // window-frame X Y W H: sets the container window's frame (AppKit screen coordinates), as a window
            // manager (Rectangle, macOS tiling) does through Accessibility
            let v = args.compactMap(Double.init)
            guard v.count == 4 else { throw Failure(description: "need X Y W H") }
            controller.window.setFrame(NSRect(x: v[0], y: v[1], width: v[2], height: v[3]), display: true)
        case "dump-frames":
            // dump-frames FILE: the window frame, the root view's bounds and every card's frame and glass anchor
            guard let path = args.first else { throw Failure(description: "need FILE") }
            var lines = ["window \(controller.window.frame)", "root \(controller.root.bounds)"]
            for v in controller.allCardHosts where !v.isHidden {
                lines.append("card \(type(of: v)) frame \(v.frame) screen \(v.glass.screenRect)")
            }
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        case "snapshot":
            // stores an AgentSnapshot on the tab, as the integration step will from SessionStart hooks
            guard args.count >= 2 else { throw Failure(description: "need TAB SESSIONID") }
            let s = try surface(args[0])
            let id = args[1]
            controller.store.mutate(.cosmetic) { st in
                st.updateTab(s.tabID) { $0.agent = AgentSnapshot(sessionID: id, cwd: $0.cwd ?? NSHomeDirectory()) }
            }
        case "mouse":
            // mouse down|drag|up|move X Y [CLICKS] [MODS]: an NSEvent at container coordinates (top-left origin) sent
            // through the window, i.e. AppKit's own hit testing and mouse tracking (not the window server's)
            guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
                throw Failure(description: "need down|drag|up|move X Y")
            }
            let types: [String: NSEvent.EventType] = ["down": .leftMouseDown, "drag": .leftMouseDragged,
                                                      "up": .leftMouseUp, "move": .mouseMoved]
            guard let type = types[args[0]] else { throw Failure(description: "bad mouse event") }
            let w = controller.window
            let loc = NSPoint(x: x, y: w.frame.height - y)
            // optional 5th argument: modifiers, comma separated (shift,cmd)
            var mods: NSEvent.ModifierFlags = []
            if args.count > 4 {
                for m in args[4].split(separator: ",") {
                    switch m { case "shift": mods.insert(.shift); case "cmd": mods.insert(.command)
                    case "alt": mods.insert(.option); case "ctrl": mods.insert(.control); default: break }
                }
            }
            guard let ev = NSEvent.mouseEvent(with: type, location: loc, modifierFlags: mods,
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: counter,
                                              clickCount: args.count > 3 ? Int(args[3]) ?? 1 : 1,
                                              pressure: type == .leftMouseUp ? 0 : 1) else {
                throw Failure(description: "event")
            }
            w.sendEvent(ev)
        case "scroll":
            // scroll X Y DY: a scroll wheel event (pixels, positive scrolls the content down) at container
            // coordinates (top-left origin), handed to the view under that point
            guard args.count >= 3, let x = Double(args[0]), let y = Double(args[1]), let dy = Int32(args[2]) else {
                throw Failure(description: "need X Y DY")
            }
            let w = controller.window
            let screenH = NSScreen.screens.first?.frame.height ?? 0
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -dy, wheel2: 0, wheel3: 0)
            else { throw Failure(description: "event") }
            cg.location = CGPoint(x: w.frame.minX + x, y: screenH - (w.frame.maxY - y))
            guard let ev = NSEvent(cgEvent: cg),
                  let v = w.contentView?.hitTest(w.contentView!.convert(NSPoint(x: x, y: w.frame.height - y), from: nil))
            else { throw Failure(description: "no view there") }
            v.scrollWheel(with: ev)
        case "post-click":
            // post-click X Y: mouse down and up queued with NSApp.postEvent, the path real clicks take (local
            // event monitors see it; `click` sends to the window directly and skips them)
            guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else { throw Failure(description: "need X Y") }
            let w = controller.window
            let loc = NSPoint(x: x, y: w.frame.height - y)
            for t in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let ev = NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: counter, clickCount: 1,
                                                  pressure: t == .leftMouseUp ? 0 : 1) else { throw Failure(description: "event") }
                NSApp.postEvent(ev, atStart: false)
            }
        case "click":
            // click X Y [right] [settings]: mouse down and up at container coordinates (top-left origin), in the main
            // window or the settings window. The up is queued before the down is sent, so a control's tracking loop
            // (buttons, menus) finds it and returns.
            guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else {
                throw Failure(description: "need X Y [right] [settings]")
            }
            let right = args.contains("right")
            let w = args.contains("settings") ? (settingsWindow?.debugWindow ?? controller.window) : controller.window
            let loc = NSPoint(x: x, y: w.frame.height - y)
            func ev(_ t: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: w.windowNumber, context: nil, eventNumber: counter, clickCount: 1,
                                   pressure: t == .leftMouseUp || t == .rightMouseUp ? 0 : 1)
            }
            guard let down = ev(right ? .rightMouseDown : .leftMouseDown), let up = ev(right ? .rightMouseUp : .leftMouseUp) else {
                throw Failure(description: "event")
            }
            NSApp.postEvent(up, atStart: false)
            w.sendEvent(down)
        case "sidebar-menu":
            // sidebar-menu X Y TITLE[>SUBTITLE]: builds the sidebar's context menu for that point (container
            // coordinates) and performs the item with that title, without showing the menu
            guard args.count >= 3, let x = Double(args[0]), let y = Double(args[1]) else { throw Failure(description: "need X Y TITLE") }
            let path = args[2...].joined(separator: " ").split(separator: ">").map(String.init)
            let w = controller.window
            guard let ev = NSEvent.mouseEvent(with: .rightMouseDown, location: NSPoint(x: x, y: w.frame.height - y), modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                                              context: nil, eventNumber: counter, clickCount: 1, pressure: 1),
                  var menu = controller.sidebarCard.sidebar.menu(for: ev) else { throw Failure(description: "no menu there") }
            for (n, title) in path.enumerated() {
                guard let i = menu.items.firstIndex(where: { $0.title == title }) else {
                    throw Failure(description: "no item '\(title)' in \(menu.items.map(\.title))")
                }
                if n == path.count - 1 { menu.performActionForItem(at: i) } else if let sub = menu.items[i].submenu { menu = sub }
            }
        case "settings-window":
            guard let settingsWindow else { throw Failure(description: "no settings window") }
            if rest == "close" { settingsWindow.close() } else { settingsWindow.show() }
            if args.count == 2, args[0] == "height", let h = Double(args[1]) { settingsWindow.setHeight(h) }
        case "rename-ui":
            controller.renameSelectedWorkspace()
        case "switcher":
            let sw = controller.switcher
            switch args.first ?? "" {
            case "open": sw.open()
            case "close": sw.close()
            case "toggle": sw.toggle()
            case "query": sw.setQuery(rest.split(separator: " ", maxSplits: 1).dropFirst().first.map(String.init) ?? "")
            case "move": sw.move(Int(args.dropFirst().first ?? "1") ?? 1)
            case "choose": sw.choose(args.dropFirst().first.flatMap { Int($0) })
            case "shot":
                guard let path = args.dropFirst().first else { throw Failure(description: "need FILE") }
                try sw.snapshot().write(to: URL(fileURLWithPath: path))
            default: throw Failure(description: "switcher open|close|toggle|query TEXT|move N|choose [N]|shot FILE")
            }
        case "quit":
            NSApp.terminate(nil)
        default:
            throw Failure(description: "unknown command")
        }
    }

    static func findMenuItem(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.title == title, item.action != nil { return item }
            if let sub = item.submenu { sub.delegate?.menuNeedsUpdate?(sub) }   // menus built on open (Add Widget)
            if let found = findMenuItem(title, in: item.submenu) { return found }
        }
        return nil
    }

    /// keyDown/keyUp NSEvents sent through the window, so they take the same path as real keys (menu key
    /// equivalents first, then the first responder's keyDown with interpretKeyEvents). The key codes are US
    /// positions; the characters are explicit.
    private func synthesizeKeys(_ text: String) throws {
        let w = controller.window
        for ch in text {
            let s = String(ch)
            let code: UInt16 = s == "\n" ? 36 : (s == "\t" ? 48 : (Self.usKeyCodes[Character(s.lowercased())] ?? 0))
            let chars = s == "\n" ? "\r" : s
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false,
                                                keyCode: code) else { throw Failure(description: "event") }
                w.sendEvent(ev)
            }
        }
    }

    /// The key code that types `char` (unmodified) in the current keyboard layout, so chords match what a real
    /// keyboard sends (Max types Colemak-DH).
    static func layoutKeyCode(for char: String) -> UInt16? {
        guard char.count == 1,
              let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> UInt16? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            for code in UInt16(0)..<128 {
                var dead: UInt32 = 0
                var len = 0
                var buf = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &buf)
                if st == noErr, len == 1, String(utf16CodeUnits: buf, count: 1) == char { return code }
            }
            return nil
        }
    }

    static let usKeyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
        "n": 45, "m": 46, ".": 47, " ": 49, "/": 44, "'": 39, ";": 41, ",": 43,
    ]

    private func dumpModel() throws -> Data {
        let st = controller.store.state
        let stateJSON = try JSONSerialization.jsonObject(with: LayoutStore.encoder().encode(st))
        var surfaces: [[String: Any]] = []
        for (cardID, v) in controller.cardViews {
            for (tab, s) in v.surfaces {
                let g = s.gridSize
                surfaces.append([
                    "tab": tab.uuidString, "card": cardID.uuidString, "realized": s.isRealized,
                    "visible": !s.isHidden, "columns": g.columns, "rows": g.rows,
                    "firstResponder": controller.window.firstResponder === s,
                    "marked": s.markedTextForDebug,
                    "frame": [s.frame.minX, s.frame.minY, s.frame.width, s.frame.height],
                ])
            }
        }
        var cards: [String: Any] = [:]
        for (id, v) in controller.cardViews {
            cards[id.uuidString] = [v.frame.minX, v.frame.minY, v.frame.width, v.frame.height]
        }
        let out: [String: Any] = [
            "state": stateJSON,
            "shownWorkspace": controller.shownWorkspaceID?.uuidString ?? NSNull(),
            "surfaces": surfaces,
            "cardFrames": cards,
            "sidebarFrame": [controller.sidebarCard.frame.minX, controller.sidebarCard.frame.minY,
                             controller.sidebarCard.frame.width, controller.sidebarCard.frame.height],
            "widgetFrames": controller.widgetCards.map { v in
                v.isHidden ? [] : [v.frame.minX, v.frame.minY, v.frame.width, v.frame.height]
            },
            "windowFrame": [controller.window.frame.minX, controller.window.frame.minY,
                            controller.window.frame.width, controller.window.frame.height],
            "keyWindow": controller.window.isKeyWindow,
            "switcher": controller.switcher.debugState,
            "dividers": controller.dividerViews.map { id, v in
                ["split": id.uuidString, "axis": v.axis.rawValue,
                 "frame": [v.frame.minX, v.frame.minY, v.frame.width, v.frame.height]] as [String: Any]
            },
            "mainScreenHeight": NSScreen.screens.first?.frame.height ?? 0,
            "settingsWindow": settingsWindow?.isVisible ?? false,
            "updates": ["count": settingsWindow?.updates?.count ?? 0, "widgets": settingsWindow?.updates?.widgetUpdates ?? [],
                        "app": settingsWindow?.updates?.appUpdate ?? ""] as [String: Any],
            "settingsWindowNumber": settingsWindow?.windowNumber ?? 0,
            "helpWindowNumber": help?.windowNumber ?? 0,
            "startHint": {
                let h = controller.tipsCard
                guard !h.isHidden else { return [CGFloat]() }
                let r = h.convert(h.bounds, to: controller.root)
                return [r.minX, r.minY, r.width, r.height]
            }(),
            "cornerRadius": controller.sidebarCard.glass.radius,
            "catchClicks": controller.root.catchClicks,
            "renameFieldOpen": controller.sidebarCard.sidebar.renameField != nil,
            "animating": controller.isAnimating,
            "tabDragging": controller.tabDrag != nil,
            "openedURLs": openedURLs,
            "linkSchemeQuestions": linkSchemeQuestions,
            "statusLinks": controller.sidebarCard.sidebar.statusHits.map { h -> [String: Any] in
                let r = controller.sidebarCard.sidebar.convert(h.0, to: controller.root)
                return ["key": h.2, "frame": [r.minX, r.minY, r.width, r.height]]
            },
            "sidebarTips": controller.sidebarCard.sidebar.tipRects.map { $0.1 },
            "sidebarRows": {
                let sb = controller.sidebarCard.sidebar
                return zip(sb.rows, sb.frames).map { row, f -> [String: Any] in
                    let r = sb.convert(f, to: controller.root)
                    var o: [String: Any] = ["frame": [r.minX, r.minY, r.width, r.height]]
                    switch row {
                    case .header(let gi):
                        o["group"] = sb.groups[gi].name; o["collapsed"] = sb.groups[gi].collapsed
                    case .workspace(let i):
                        let it = sb.items[i]
                        o["workspace"] = it.name; o["primary"] = it.selected; o["marked"] = sb.marked.contains(it.id)
                    }
                    return o
                }
            }(),
            "pid": Int(getpid()),
            "zmxPrefix": controller.sessions.prefix,
            "ghosttyDiagnostics": GhosttyApp.shared.diagnostics,
        ]
        return try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    }
}

/// The minimum of an NSDraggingInfo for the `drop` debug command.
final class DebugDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, window: NSWindow?) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
    }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
