// adapted from thdxg/macterm (MIT), via umputun/agterm (MIT)
// meum: adapted from agterm agterm/Ghostty/GhosttyCallbacks.swift at 80f822bfe5d697567e18a4ce0f15569a55a729ea
// (kept: tick coalescing, title/pwd/exit/mouse/url actions, clipboard read/write; dropped: agterm's pane lead,
// remote, search, notifications and clipboard prompts; protocol clipboard reads are denied).

import AppKit
import GhosttyKit
import os

/// Routes libghostty runtime callbacks to the terminal views.
///
/// `@unchecked Sendable`, NOT `@MainActor`: the C closures run synchronously off whatever thread libghostty
/// calls from, and this router holds no mutable state besides a lock. Every `@MainActor` touch hops via
/// `DispatchQueue.main.async`, copying any C string first: the `char*` lives only for that callback.
final class GhosttyCallbacks: @unchecked Sendable {
    /// Coalesces libghostty wakeups into one queued main-thread tick. The flag clears before the tick so a
    /// wakeup arriving during it re-schedules instead of being dropped.
    private let tickScheduled = OSAllocatedUnfairLock(initialState: false)

    func wakeup() {
        let already = tickScheduled.withLock { s -> Bool in
            if s { return true }
            s = true
            return false
        }
        guard !already else { return }
        DispatchQueue.main.async { [self] in
            tickScheduled.withLock { $0 = false }
            MainActor.assumeIsolated { GhosttyApp.shared.tick() }
        }
    }

    func action(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_PWD:
            guard let view = surfaceView(from: target), let ptr = action.action.pwd.pwd else { return true }
            let pwd = String(cString: ptr)
            DispatchQueue.main.async { MainActor.assumeIsolated { view.applyPwd(pwd) } }
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view = surfaceView(from: target), let ptr = action.action.set_title.title else { return true }
            let title = String(cString: ptr)
            DispatchQueue.main.async { MainActor.assumeIsolated { view.applyTitle(title) } }
            return true
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            // returning false lets ghostty print its "process exited" notice; the view decides whether the
            // exit closes the tab (a normal shell exit) or stays visible (a failed start).
            guard let view = surfaceView(from: target) else { return false }
            DispatchQueue.main.async { MainActor.assumeIsolated { view.handleProcessExit() } }
            return false
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            DispatchQueue.main.async { NSCursor.setHiddenUntilMouseMoves(hidden) }
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let view = surfaceView(from: target) else { return true }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async { MainActor.assumeIsolated { view.applyMouseShape(shape) } }
            return true
        case GHOSTTY_ACTION_OPEN_URL:
            // `open_url.url` is a length-delimited slice, not NUL-terminated: honour `.len`.
            let u = action.action.open_url
            guard let ptr = u.url else { return true }
            let link = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(u.len)), as: UTF8.self)
            DispatchQueue.main.async {
                guard let url = URL(string: link), let scheme = url.scheme?.lowercased(),
                      ["http", "https", "mailto", "file"].contains(scheme) else { return }
                if url.isFileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } else {
                    NSWorkspace.shared.open(url)
                }
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            return true
        default:
            return false
        }
    }

    struct ClipboardRead {
        let userdata: UnsafeMutableRawPointer?
        let location: ghostty_clipboard_e
        let state: UnsafeMutableRawPointer?
        let mimes: UnsafePointer<UnsafePointer<CChar>?>?
        let mimesLen: UInt
        let list: Bool
    }

    /// A paste (⌘V or `paste_from_clipboard`) asks for text/plain; answer from the pasteboard.
    func readClipboard(_ read: ClipboardRead) -> ghostty_clipboard_read_result_e {
        guard let surface = surface(from: read.userdata) else { return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED }
        let text = Self.pasteboardText(Self.pasteboard(for: read.location))
        let wantsText = (0..<Int(read.mimesLen)).contains { i in
            read.mimes?[i].map { String(cString: $0) == "text/plain" } ?? false
        }
        guard wantsText || read.list else { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE }
        // an empty pasteboard still answers a text request with a zero-length representation, so an OSC 52
        // reader waiting for the reply does not hang.
        let data = Data((text ?? "").utf8)
        let available = read.list && text != nil ? ["text/plain"] : []
        Self.complete(surface, mime: wantsText ? "text/plain" : nil, data: data, available: available,
                      state: read.state)
        return GHOSTTY_CLIPBOARD_READ_STARTED
    }

    /// Protocol (OSC 52 / kitty) clipboard reads that ghostty wants confirmed are denied: meum has no prompt.
    func denyClipboard(ud: UnsafeMutableRawPointer?, state: UnsafeMutableRawPointer?) {
        guard let surface = surface(from: ud) else { return }
        ghostty_surface_deny_clipboard_request(surface, state)
    }

    func writeClipboard(location: ghostty_clipboard_e, content: UnsafePointer<ghostty_clipboard_content_s>?,
                        len: UInt) {
        guard let content, len > 0 else { return }
        var text: String?
        for item in UnsafeBufferPointer(start: content, count: Int(len)) {
            guard let mime = item.mime, String(cString: mime) == "text/plain", let data = item.data else { continue }
            text = String(decoding: UnsafeRawBufferPointer(start: data, count: item.len), as: UTF8.self)
        }
        guard let text else { return }
        let pb = Self.pasteboard(for: location)
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard {
        guard location == GHOSTTY_CLIPBOARD_SELECTION else { return .general }
        return NSPasteboard(name: .init((Bundle.main.bundleIdentifier ?? "io.github.mcurses.meum") + ".selection"))
    }

    /// File URLs become shell-escaped paths, space-joined; a plain string comes back verbatim.
    static func pasteboardText(_ pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { shellEscape($0.path) }.joined(separator: " ")
        }
        return pb.string(forType: .string).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func shellEscape(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./,:@%+=")
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func complete(_ surface: ghostty_surface_t, mime: String?, data: Data, available: [String],
                                 state: UnsafeMutableRawPointer?) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
        defer {
            strings.forEach { free($0) }
            buffer.deallocate()
        }
        data.withUnsafeBytes { b in if let src = b.baseAddress { buffer.copyMemory(from: src, byteCount: b.count) } }
        var contents: [ghostty_clipboard_content_s] = []
        if let mime, let m = strdup(mime) {
            strings.append(m)
            contents.append(ghostty_clipboard_content_s(mime: m, data: buffer.assumingMemoryBound(to: CChar.self),
                                                        len: data.count))
        }
        var avail: [UnsafePointer<CChar>?] = []
        for a in available {
            if let p = strdup(a) { strings.append(p); avail.append(UnsafePointer(p)) }
        }
        contents.withUnsafeBufferPointer { cb in
            avail.withUnsafeBufferPointer { ab in
                var c = ghostty_clipboard_complete_s(contents: cb.baseAddress, contents_len: cb.count,
                                                     available: ab.baseAddress, available_len: ab.count,
                                                     confirmed: false, remember: false)
                ghostty_surface_complete_clipboard_request(surface, &c, state)
            }
        }
    }

    func closeSurface(ud: UnsafeMutableRawPointer?) {
        guard let ud else { return }
        // the card retains the view until destroySurface() runs (the only place ghostty_surface_free is
        // called), so takeUnretainedValue() is safe. Never close or free synchronously from this callback.
        let view = Unmanaged<SurfaceView>.fromOpaque(ud).takeUnretainedValue()
        DispatchQueue.main.async { MainActor.assumeIsolated { view.handleProcessExit() } }
    }

    private func surfaceView(from target: ghostty_target_s) -> SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
              let ud = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(ud).takeUnretainedValue()
    }

    private func surface(from ud: UnsafeMutableRawPointer?) -> ghostty_surface_t? {
        guard let ud else { return nil }
        return Unmanaged<SurfaceView>.fromOpaque(ud).takeUnretainedValue().surface
    }
}
