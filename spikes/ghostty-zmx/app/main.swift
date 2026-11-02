// Minimal AppKit host for one libghostty surface (feasibility spike).
//
// Env:
//   SPIKE_CMD   command for the surface (e.g. "/path/zmx attach spike-1")
//   SPIKE_OUT   directory for dumps/logs and the control file "cmd"
//   SPIKE_CONFIG optional ghostty config file to load (no default files are loaded)
//
// Control: write one line into $SPIKE_OUT/cmd. The app polls it every 200 ms, runs it, deletes it.
//   dump <tag>        write <tag>.viewport.txt and <tag>.screen.txt (screen = incl. scrollback)
//   recreate          free the surface and create a fresh one (timed)
//   drop / restore    free the surface (view stays) / create it again (simulates hidden workspace)
//   action <name>     ghostty_surface_binding_action (e.g. scroll_page_up, scroll_to_bottom)
//   type <text>       synthesize NSEvent keyDowns for each char and feed them through keyDown()
//   enter             synthesize a Return keyDown
//   quit              terminate

import AppKit
import GhosttyKit

let outDir = ProcessInfo.processInfo.environment["SPIKE_OUT"] ?? FileManager.default.currentDirectoryPath
let spikeCmd = ProcessInfo.processInfo.environment["SPIKE_CMD"] ?? "/bin/zsh -l"
let t0 = Date()

func log(_ s: String) {
    let line = String(format: "[%8.3f] ", Date().timeIntervalSince(t0)) + s + "\n"
    FileHandle.standardError.write(line.data(using: .utf8)!)
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("app.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: url)
    }
}

final class GApp {
    var app: ghostty_app_t!
    var config: ghostty_config_t!

    init() {
        let t = Date()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            fatalError("ghostty_init failed")
        }
        config = ghostty_config_new()
        if let p = ProcessInfo.processInfo.environment["SPIKE_CONFIG"] {
            ghostty_config_load_file(config, p)
        }
        ghostty_config_finalize(config)
        let n = ghostty_config_diagnostics_count(config)
        for i in 0..<n {
            let d = ghostty_config_get_diagnostic(config, i)
            log("config diagnostic: \(String(cString: d.message))")
        }

        var rt = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { ud in
                let me = Unmanaged<GApp>.fromOpaque(ud!).takeUnretainedValue()
                DispatchQueue.main.async { ghostty_app_tick(me.app) }
            },
            action_cb: { _, target, action in
                // Log a few interesting actions; return false = not handled (fine for a spike).
                switch action.tag {
                case GHOSTTY_ACTION_SET_TITLE:
                    let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
                    log("action set_title: \(title)")
                    return true
                case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
                    log("action show_child_exited")
                    return true
                case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_MOUSE_SHAPE, GHOSTTY_ACTION_MOUSE_VISIBILITY,
                     GHOSTTY_ACTION_CELL_SIZE, GHOSTTY_ACTION_PWD, GHOSTTY_ACTION_RENDERER_HEALTH,
                     GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_CONFIG_CHANGE,
                     GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_INITIAL_SIZE:
                    return false
                default:
                    log("action tag=\(action.tag.rawValue) (unhandled)")
                    return false
                }
            },
            read_clipboard_cb: { _, _, _, _, _, _ in GHOSTTY_CLIPBOARD_READ_UNAVAILABLE },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: { _, alive in log("close_surface_cb processAlive=\(alive)") }
        )
        app = ghostty_app_new(&rt, config)
        guard app != nil else { fatalError("ghostty_app_new failed") }
        log(String(format: "ghostty_init+config+app_new: %.1f ms", Date().timeIntervalSince(t) * 1000))
    }
}

final class TermView: NSView {
    let gapp: GApp
    var surface: ghostty_surface_t?

    init(gapp: GApp, frame: NSRect) {
        self.gapp = gapp
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func createSurface() {
        let t = Date()
        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
        cfg.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        cfg.font_size = 13
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
        let s: ghostty_surface_t? = spikeCmd.withCString { cmd in
            cfg.command = cmd
            return ghostty_surface_new(gapp.app, &cfg)
        }
        guard let s else { log("ghostty_surface_new FAILED"); return }
        surface = s
        updateScaleAndSize()
        ghostty_surface_set_focus(s, window?.isKeyWindow ?? true)
        log(String(format: "ghostty_surface_new+size: %.1f ms (cmd=%@)", Date().timeIntervalSince(t) * 1000, spikeCmd))
        waitForContent(since: t)
    }

    // Poll (main thread, 2 ms) until the viewport has text: time from surface_new to restored content.
    func waitForContent(since t: Date) {
        let txt = readText(GHOSTTY_POINT_VIEWPORT).trimmingCharacters(in: .whitespacesAndNewlines)
        if !txt.isEmpty {
            log(String(format: "first content in viewport after %.1f ms", Date().timeIntervalSince(t) * 1000))
            return
        }
        if Date().timeIntervalSince(t) > 5 { log("no content after 5 s"); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.002) { [weak self] in self?.waitForContent(since: t) }
    }

    func freeSurface() {
        guard let s = surface else { return }
        let t = Date()
        surface = nil
        ghostty_surface_free(s)
        log(String(format: "ghostty_surface_free: %.1f ms", Date().timeIntervalSince(t) * 1000))
    }

    func updateScaleAndSize() {
        guard let s = surface else { return }
        let fb = convertToBacking(bounds)
        let xs = bounds.width > 0 ? fb.width / bounds.width : 2
        let ys = bounds.height > 0 ? fb.height / bounds.height : 2
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        ghostty_surface_set_content_scale(s, xs, ys)
        ghostty_surface_set_size(s, UInt32(fb.width), UInt32(fb.height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateScaleAndSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScaleAndSize()
    }

    override func becomeFirstResponder() -> Bool {
        if let s = surface { ghostty_surface_set_focus(s, true) }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if let s = surface { ghostty_surface_set_focus(s, false) }
        return true
    }

    static func mods(_ f: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m: UInt32 = GHOSTTY_MODS_NONE.rawValue
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(m)
    }

    // Simplified version of Ghostty's own keyDown: no IME / NSTextInputClient, no keybinding menu.
    func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let s = surface else { return }
        var k = ghostty_input_key_s()
        k.action = action
        k.keycode = UInt32(event.keyCode)
        k.mods = Self.mods(event.modifierFlags)
        k.consumed_mods = Self.mods(event.modifierFlags.subtracting([.control, .command]))
        k.composing = false
        k.unshifted_codepoint = 0
        if let c = event.characters(byApplyingModifiers: []), let u = c.unicodeScalars.first {
            k.unshifted_codepoint = u.value
        }
        var text: String? = nil
        if action != GHOSTTY_ACTION_RELEASE, let chars = event.characters, !chars.isEmpty {
            if chars.unicodeScalars.count == 1, let u = chars.unicodeScalars.first,
               u.value < 0x20 || (u.value >= 0xF700 && u.value <= 0xF8FF) {
                // control chars / function keys: let ghostty encode from keycode+mods
                if u.value < 0x20, let alt = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control)) {
                    text = alt
                }
            } else {
                text = chars
            }
        }
        if let text {
            _ = text.withCString { p in k.text = p; return ghostty_surface_key(s, k) }
        } else {
            k.text = nil
            _ = ghostty_surface_key(s, k)
        }
    }

    override func keyDown(with event: NSEvent) { sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS) }
    override func keyUp(with event: NSEvent) { sendKey(event, action: GHOSTTY_ACTION_RELEASE) }

    override func scrollWheel(with event: NSEvent) {
        guard let s = surface else { return }
        var x = event.scrollingDeltaX, y = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas { x *= 2; y *= 2 }
        // scroll mods bitfield: bit0 = precision
        ghostty_surface_mouse_scroll(s, x, y, event.hasPreciseScrollingDeltas ? 1 : 0)
    }

    func readText(_ tag: ghostty_point_tag_e) -> String {
        guard let s = surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(s, sel, &text) else { return "<read_text failed>" }
        defer { ghostty_surface_free_text(s, &text) }
        return String(cString: text.text)
    }

    func dump(_ tag: String) {
        let base = URL(fileURLWithPath: outDir)
        let vp = readText(GHOSTTY_POINT_VIEWPORT)
        let sc = readText(GHOSTTY_POINT_SCREEN)
        try? vp.write(to: base.appendingPathComponent("\(tag).viewport.txt"), atomically: true, encoding: .utf8)
        try? sc.write(to: base.appendingPathComponent("\(tag).screen.txt"), atomically: true, encoding: .utf8)
        let size = surface.map { ghostty_surface_size($0) }
        log("dump \(tag): viewport \(vp.split(separator: "\n").count) lines, screen \(sc.split(separator: "\n").count) lines, grid \(size?.columns ?? 0)x\(size?.rows ?? 0)")
    }

    func synthKey(char: String, keyCode: UInt16) {
        guard let w = window else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: w.windowNumber, context: nil, characters: char,
                                         charactersIgnoringModifiers: char, isARepeat: false, keyCode: keyCode) {
                if type == .keyDown { keyDown(with: ev) } else { keyUp(with: ev) }
            }
        }
    }
}

// US-ANSI virtual keycodes for the characters we synthesize.
let keyCodes: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40,
    "n": 45, "m": 46, ".": 47, " ": 49, "/": 44, "_": 27, ">": 47, "'": 39, "\"": 39, "$": 21,
]

final class Delegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: TermView!
    var gapp: GApp!

    func applicationDidFinishLaunching(_ n: Notification) {
        log("launch pid=\(getpid()) cmd=\(spikeCmd)")
        gapp = GApp()
        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 960, height: 620),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ghostty-zmx spike (pid \(getpid()))"
        view = TermView(gapp: gapp, frame: window.contentView!.bounds)
        view.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        ghostty_app_set_focus(gapp.app, true)
        view.createSurface()
        try? "\(window.windowNumber)\n".write(to: URL(fileURLWithPath: outDir).appendingPathComponent("window.id"), atomically: true, encoding: .utf8)
        log("windowNumber=\(window.windowNumber)")

        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.pollControl() }
    }

    func pollControl() {
        let url = URL(fileURLWithPath: outDir).appendingPathComponent("cmd")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: url)
        for raw in s.split(separator: "\n") {
            let line = String(raw)
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let c = parts.first else { continue }
            let arg = parts.count > 1 ? parts[1] : ""
            log("control: \(line)")
            switch c {
            case "dump": view.dump(arg.isEmpty ? "dump" : arg)
            case "recreate":
                let t = Date(); view.freeSurface(); view.createSurface()
                log(String(format: "recreate total: %.1f ms", Date().timeIntervalSince(t) * 1000))
            case "drop": view.freeSurface()
            case "restore": view.createSurface()
            case "action":
                if let s = view.surface {
                    let ok = arg.withCString { ghostty_surface_binding_action(s, $0, UInt(arg.utf8.count)) }
                    log("binding_action \(arg) -> \(ok)")
                }
            case "type":
                for ch in arg { view.synthKey(char: String(ch), keyCode: keyCodes[Character(ch.lowercased())] ?? 0) }
            case "enter": view.synthKey(char: "\r", keyCode: 36)
            case "quit": NSApp.terminate(nil)
            default: log("unknown control \(c)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
app.run()
