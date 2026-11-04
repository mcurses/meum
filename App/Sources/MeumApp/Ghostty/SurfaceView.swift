// adapted from thdxg/macterm (MIT), via umputun/agterm (MIT)
// meum: adapted from agterm agterm/Ghostty/GhosttySurfaceView.swift (+FirstResponder, +IO) at
// 80f822bfe5d697567e18a4ce0f15569a55a729ea. Kept: the surface lifecycle and its C-lifetime rules, the
// non-zero-size guard, focus and size plumbing, text reading and injection. Dropped: agterm's session model,
// overlays, HUD, spawn pacer, watermark, search, accessibility and drag-and-drop.

import AppKit
import GhosttyKit
import QuartzCore

/// A Metal-backed NSView hosting one libghostty surface (one tab's terminal).
///
/// `surface` and the strdup buffers are `nonisolated(unsafe)`: mutated only on the main actor (create /
/// destroy), and the C callbacks reading them are serialized by libghostty's tick model. The view is passed
/// to libghostty as unretained userdata; that is safe because `destroySurface()` is the only place the surface
/// is freed and the owner keeps the view alive until then.
final class SurfaceView: NSView {
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    let tabID: UUID
    let workingDirectory: String
    /// The surface's command (`<zmx> attach <name> ...`); nil runs the login shell.
    let command: String?
    let env: [String: String]

    /// Main-actor callbacks, set by the owning card.
    var onFocus: ((SurfaceView) -> Void)?
    var onExit: ((SurfaceView) -> Void)?
    var onTitle: ((SurfaceView, String) -> Void)?
    var onPwd: ((SurfaceView, String) -> Void)?

    nonisolated(unsafe) private var configCStrings: [UnsafeMutablePointer<CChar>] = []
    nonisolated(unsafe) private var envVars: [ghostty_env_var_s] = []
    private var pendingSurfaceCreation = false
    private(set) var isDestroyed = false
    private var didHandleProcessExit = false
    private(set) var createdAt: Date?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    /// When false, size changes are not pushed to the pty (the card is mid-animation); `commitSize()` pushes.
    var liveResize = true

    // IME state shared with SurfaceView+Input.swift (stored properties can't live in an extension).
    var _markedRange = NSRange(location: NSNotFound, length: 0)
    var _selectedRange = NSRange(location: NSNotFound, length: 0)
    var _markedText = ""
    var committingComposition = false
    var keyTextAccumulator: [String] = []
    var currentKeyEvent: NSEvent?
    var mouseShape: ghostty_action_mouse_shape_e = GHOSTTY_MOUSE_SHAPE_TEXT
    var pointerInside = false
    var lastReportedMousePoint: NSPoint?
    var trackingArea: NSTrackingArea?

    init(tabID: UUID, workingDirectory: String, command: String?, env: [String: String]) {
        self.tabID = tabID
        self.workingDirectory = workingDirectory
        self.command = command
        self.env = env
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        registerForDraggedTypes([.fileURL, .URL, .string, .png, .tiff])
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateGhosttyFocus() }
            })
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        if let surface { ghostty_surface_free(surface) }
        configCStrings.forEach { free($0) }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isRealized: Bool { surface != nil }

    var liveFocus: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    func updateGhosttyFocus() {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, liveFocus)
    }

    // MARK: - Lifecycle

    func createSurface() {
        guard !isDestroyed, surface == nil, let app = GhosttyApp.shared.app else { return }
        let backing = convertToBacking(bounds).size
        guard window != nil, backing.width > 0, backing.height > 0 else {
            // a Metal layer created at zero size renders blank: wait for a real size
            pendingSurfaceCreation = true
            return
        }
        pendingSurfaceCreation = false

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(window?.backingScaleFactor ?? 2.0)
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        // the strdup'd buffers must outlive ghostty_surface_new: retained here, freed in destroySurface
        configCStrings.forEach { free($0) }
        configCStrings = []
        if let p = strdup(workingDirectory) {
            configCStrings.append(p)
            config.working_directory = UnsafePointer(p)
        }
        if let command, let p = strdup(command) {
            configCStrings.append(p)
            config.command = UnsafePointer(p)
            config.wait_after_command = false
        }
        envVars = []
        for (k, v) in env {
            guard let kp = strdup(k), let vp = strdup(v) else { continue }
            configCStrings.append(kp)
            configCStrings.append(vp)
            envVars.append(ghostty_env_var_s(key: UnsafePointer(kp), value: UnsafePointer(vp)))
        }
        ghostty_app_set_color_scheme(app, GHOSTTY_COLOR_SCHEME_DARK)
        if envVars.isEmpty {
            surface = ghostty_surface_new(app, &config)
        } else {
            surface = envVars.withUnsafeMutableBufferPointer { buf in
                config.env_vars = buf.baseAddress
                config.env_var_count = buf.count
                return ghostty_surface_new(app, &config)
            }
        }
        guard let surface else {
            // libghostty declines while the display sleeps; retry on the next layout pass
            pendingSurfaceCreation = true
            Log.info("surface creation failed for tab \(tabID); will retry")
            return
        }
        createdAt = Date()
        ghostty_surface_set_color_scheme(surface, GHOSTTY_COLOR_SCHEME_DARK)
        if let screen = window?.screen ?? NSScreen.main,
           let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 {
            ghostty_surface_set_display_id(surface, displayID)
        }
        pushSize()
        updateGhosttyFocus()
    }

    /// Frees the surface (the zmx client exits; the session lives on). The view is retired afterwards.
    func destroySurface() {
        isDestroyed = true
        onExit = nil
        onFocus = nil
        onTitle = nil
        onPwd = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let surface { ghostty_surface_free(surface) }
        surface = nil
        // a freed surface leaves its last frame on the layer; drop the layer libghostty installed
        let plain = CALayer()
        plain.frame = layer?.frame ?? bounds
        layer = plain
        configCStrings.forEach { free($0) }
        configCStrings = []
        envVars = []
    }

    /// Both SHOW_CHILD_EXITED and close_surface_cb can fire for one exit; the owner decides (it closes the
    /// tab, which destroys this view, or leaves a failed start on screen and waits for the next call).
    func handleProcessExit() {
        guard !isDestroyed else { return }
        didHandleProcessExit = true
        onExit?(self)
    }

    var hasExited: Bool { didHandleProcessExit }

    /// Whether the process exited within `seconds` of starting (a failed start, not a user `exit`).
    func exitedEarly(within seconds: TimeInterval = 1.5) -> Bool {
        guard let createdAt else { return true }
        return Date().timeIntervalSince(createdAt) < seconds
    }

    func applyTitle(_ title: String) { onTitle?(self, title) }
    func applyPwd(_ pwd: String) { onPwd?(self, pwd) }

    // MARK: - Size and visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        if surface == nil { createSurface() } else { pushSize() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if pendingSurfaceCreation { createSurface() }
        if liveResize { pushSize() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        pushSize()
    }

    func pushSize() {
        guard let surface, let window else { return }
        let size = convertToBacking(bounds).size
        guard size.width > 0, size.height > 0 else { return }
        let scale = Double(window.backingScaleFactor)
        if let l = layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            l.contentsScale = CGFloat(scale)
            CATransaction.commit()
        }
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
        ghostty_surface_refresh(surface)
    }

    /// Tells libghostty whether the surface is on screen, so a hidden tab stops rendering.
    func setVisible(_ visible: Bool) {
        isHidden = !visible
        if let surface { ghostty_surface_set_occlusion(surface, visible) }
    }

    var gridSize: (columns: Int, rows: Int) {
        guard let surface else { return (0, 0) }
        let s = ghostty_surface_size(surface)
        return (Int(s.columns), Int(s.rows))
    }

    // MARK: - First responder

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface {
            // window.firstResponder is not yet self inside this call, so liveFocus reads stale: push directly
            ghostty_surface_set_focus(surface, window?.isKeyWindow ?? false)
        }
        if ok { onFocus?(self) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    // MARK: - Text IO

    /// Reads the viewport (`all == false`) or the whole screen including scrollback.
    func readText(all: Bool) -> String? {
        guard let surface else { return nil }
        // a zero-init ghostty_point_s is ACTIVE/EXACT, not viewport/top-left: set tag and coord on both ends
        let tag = all ? GHOSTTY_POINT_SCREEN : GHOSTTY_POINT_VIEWPORT
        var sel = ghostty_selection_s()
        sel.top_left = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0)
        sel.bottom_right = ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0)
        sel.rectangle = false
        var t = ghostty_text_s()
        guard ghostty_surface_read_text(surface, sel, &t) else { return nil }
        defer { ghostty_surface_free_text(surface, &t) }
        guard let ptr = t.text, t.text_len > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(t.text_len)), as: UTF8.self)
    }

    /// Inserts text as a paste (bracketed when the program asked for it); `submit` then presses Return on the
    /// same surface, so the Return reaches the program after the pasted text, never before it.
    func insertPasted(text: String, submit: Bool = false) {
        guard let surface else { return }
        commitOrDiscardComposition()
        if !text.isEmpty { text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) } }
        if submit { sendReturn(to: surface) }
    }

    /// Types text as key input; `\n` becomes a Return key press.
    func inject(text: String) {
        guard let surface else { return }
        commitOrDiscardComposition()
        let parts = text.components(separatedBy: "\n")
        for (i, part) in parts.enumerated() {
            if !part.isEmpty {
                part.withCString { ptr in
                    var ke = ghostty_input_key_s()
                    ke.action = GHOSTTY_ACTION_PRESS
                    ke.text = ptr
                    _ = ghostty_surface_key(surface, ke)
                }
            }
            if i < parts.count - 1 { sendReturn(to: surface) }
        }
    }

    private func sendReturn(to surface: ghostty_surface_t) {
        for action in [GHOSTTY_ACTION_PRESS, GHOSTTY_ACTION_RELEASE] {
            var ke = ghostty_input_key_s()
            ke.action = action
            ke.keycode = 36
            ke.mods = GHOSTTY_MODS_NONE
            ke.consumed_mods = GHOSTTY_MODS_NONE
            if action == GHOSTTY_ACTION_PRESS {
                "\r".withCString { p in ke.text = p; _ = ghostty_surface_key(surface, ke) }
            } else {
                _ = ghostty_surface_key(surface, ke)
            }
        }
    }

    @discardableResult
    func performBindingAction(_ action: String) -> Bool {
        guard let surface else { return false }
        return action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
    }
}
