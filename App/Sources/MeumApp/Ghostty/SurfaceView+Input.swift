// adapted from thdxg/macterm (MIT), via umputun/agterm (MIT)
// meum: adapted from agterm agterm/Ghostty/GhosttySurfaceView+Input.swift at
// 80f822bfe5d697567e18a4ce0f15569a55a729ea. Kept verbatim in substance: keyDown with interpretKeyEvents and the
// full NSTextInputClient (dead keys, IME composition, the committed-composition fence), modifier translation,
// mouse buttons, scrolling, cursor shapes and the Edit-menu actions. Dropped: agterm's pane lead, status
// clearing, link-policy and HUD hooks. Drag-and-drop came back later (meum's own, after agterm's).

import AppKit
import GhosttyKit

extension SurfaceView {
    // MARK: - Drops

    /// Files, text and images can be dropped onto a terminal (the registered types are set in `init`).
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        GhosttyCallbacks.hasInsertable(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        GhosttyCallbacks.hasInsertable(sender.draggingPasteboard) ? .copy : []
    }

    /// Inserts what was dropped as a paste: file paths shell-escaped and space-joined, text verbatim, image data
    /// as the path of a saved PNG. Bracketed when the program asked for it, so a multi-line drop is not run line
    /// by line. The terminal that took the drop gets the keyboard.
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let text = GhosttyCallbacks.pasteboardText(sender.draggingPasteboard, imagesAsFiles: true) else { return false }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.insertPasted(text: text)
        }
        return true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            super.keyDown(with: event)
            return
        }
        let action: ghostty_input_action_e = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.control), !flags.contains(.command), !flags.contains(.option), !hasMarkedText() {
            var ke = buildKeyEvent(from: event, action: action)
            let text = event.charactersIgnoringModifiers ?? event.characters ?? ""
            if text.isEmpty {
                ke.text = nil
                _ = ghostty_surface_key(surface, ke)
            } else {
                text.withCString { ptr in
                    ke.text = ptr
                    _ = ghostty_surface_key(surface, ke)
                }
            }
            return
        }

        if flags.contains(.command) {
            var ke = buildKeyEvent(from: event, action: action)
            ke.text = nil
            _ = ghostty_surface_key(surface, ke)
            return
        }

        let hadMarkedText = hasMarkedText()
        currentKeyEvent = event
        keyTextAccumulator = []
        let translationEvent = translatedEvent(for: event)
        interpretKeyEvents([translationEvent])
        currentKeyEvent = nil

        var ke = buildKeyEvent(from: event, action: action)
        ke.consumed_mods = consumedMods(translationEvent.modifierFlags)
        ke.composing = hasMarkedText() || hadMarkedText

        if !keyTextAccumulator.isEmpty {
            var commitKE = ke
            commitKE.composing = false
            for text in keyTextAccumulator {
                text.withCString { ptr in
                    commitKE.text = ptr
                    _ = ghostty_surface_key(surface, commitKE)
                }
            }
        } else if !hasMarkedText() {
            let text = filterSpecial(event.characters ?? "")
            if !text.isEmpty, !ke.composing {
                text.withCString { ptr in
                    ke.text = ptr
                    _ = ghostty_surface_key(surface, ke)
                }
            } else {
                ke.consumed_mods = GHOSTTY_MODS_NONE
                ke.text = nil
                _ = ghostty_surface_key(surface, ke)
            }
        }
    }

    override func doCommand(by _: Selector) {}

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        var ke = buildKeyEvent(from: event, action: GHOSTTY_ACTION_RELEASE)
        ke.text = nil
        _ = ghostty_surface_key(surface, ke)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        var ke = buildKeyEvent(from: event, action: isFlagPress(event) ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE)
        ke.text = nil
        _ = ghostty_surface_key(surface, ke)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect,
                                            .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    private func mousePoint(from event: NSEvent) -> NSPoint {
        let local = convert(event.locationInWindow, from: nil)
        // the view is flipped, so local.y already grows downwards like libghostty's
        return NSPoint(x: local.x, y: local.y)
    }

    private func reportMousePos(from event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
        lastReportedMousePoint = pt
    }

    override func mouseDown(with event: NSEvent) {
        guard let surface else { return }
        window?.makeFirstResponder(self)
        updateGhosttyFocus()
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, mods(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, mods(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let surface else { super.otherMouseDown(with: event); return }
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, let surface else { super.otherMouseUp(with: event); return }
        reportMousePos(from: event)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, mods(event))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseMoved(with event: NSEvent) {
        reportMousePos(from: event)
        if pointerInside { Self.nsCursor(for: mouseShape).set() }
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        reportMousePos(from: event)
    }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        pointerInside = false
        ghostty_surface_mouse_pos(surface, -1, -1, mods(event))
        lastReportedMousePoint = NSPoint(x: -1, y: -1)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        let pt = mousePoint(from: event)
        if pt != lastReportedMousePoint {
            ghostty_surface_mouse_pos(surface, pt.x, pt.y, mods(event))
            lastReportedMousePoint = pt
        }
        var scrollMods: ghostty_input_scroll_mods_t = 0
        if event.hasPreciseScrollingDeltas { scrollMods |= 1 }
        ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, scrollMods)
    }

    override func cursorUpdate(with event: NSEvent) {
        Self.nsCursor(for: mouseShape).set()
    }

    func applyMouseShape(_ shape: ghostty_action_mouse_shape_e) {
        guard shape != mouseShape else { return }
        mouseShape = shape
        if pointerInside, !isHidden { Self.nsCursor(for: shape).set() }
    }

    private static func nsCursor(for shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT: return .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB: return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP: return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU: return .contextualMenu
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE, GHOSTTY_MOUSE_SHAPE_W_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
            return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE, GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
            return .resizeUpDown
        default: return .arrow
        }
    }

    // MARK: - Key event helpers

    private func buildKeyEvent(from event: NSEvent, action: ghostty_input_action_e) -> ghostty_input_key_s {
        var ke = ghostty_input_key_s()
        ke.action = action
        ke.keycode = UInt32(event.keyCode)
        ke.mods = mods(event)
        ke.consumed_mods = GHOSTTY_MODS_NONE
        ke.composing = false
        ke.text = nil
        ke.unshifted_codepoint = unshiftedCodepoint(from: event)
        return ke
    }

    private func consumedMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: m)
    }

    func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        var m = GHOSTTY_MODS_NONE.rawValue
        let f = event.modifierFlags
        if f.contains(.shift) { m |= GHOSTTY_MODS_SHIFT.rawValue }
        if f.contains(.control) { m |= GHOSTTY_MODS_CTRL.rawValue }
        if f.contains(.option) { m |= GHOSTTY_MODS_ALT.rawValue }
        if f.contains(.command) { m |= GHOSTTY_MODS_SUPER.rawValue }
        if f.contains(.capsLock) { m |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = f.rawValue
        let leftShift: UInt = 0x02, rightShift: UInt = 0x04
        let leftCtrl: UInt = 0x01, rightCtrl: UInt = 0x2000
        let leftAlt: UInt = 0x20, rightAlt: UInt = 0x40
        let leftCmd: UInt = 0x08, rightCmd: UInt = 0x10
        if raw & rightShift != 0, raw & leftShift == 0 { m |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & rightCtrl != 0, raw & leftCtrl == 0 { m |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & rightAlt != 0, raw & leftAlt == 0 { m |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & rightCmd != 0, raw & leftCmd == 0 { m |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(rawValue: m)
    }

    private func isFlagPress(_ event: NSEvent) -> Bool {
        let f = event.modifierFlags
        switch event.keyCode {
        case 56, 60: return f.contains(.shift)
        case 58, 61: return f.contains(.option)
        case 59, 62: return f.contains(.control)
        case 55, 54: return f.contains(.command)
        case 57: return f.contains(.capsLock)
        default: return false
        }
    }

    private func filterSpecial(_ text: String) -> String {
        guard let scalar = text.unicodeScalars.first else { return "" }
        let v = scalar.value
        // control characters (DEL included: Backspace reports 0x7F) and AppKit's function-key range are keys, not
        // text. Sent as text, Option would count as consumed and alt+backspace bindings would never match.
        if v < 0x20 || v == 0x7F || (0xF700...0xF8FF).contains(v) { return "" }
        return text
    }

    /// A synthetic NSEvent whose modifier flags reflect libghostty's translation policy: with
    /// macos-option-as-alt on, Option is stripped so `characters(byApplyingModifiers:)` gives the plain char.
    private func translatedEvent(for event: NSEvent) -> NSEvent {
        guard let surface else { return event }
        let translationModsRaw = ghostty_surface_key_translation_mods(surface, mods(event)).rawValue
        var translationFlags = event.modifierFlags
        for (bit, flag) in [
            (GHOSTTY_MODS_SHIFT.rawValue, NSEvent.ModifierFlags.shift),
            (GHOSTTY_MODS_CTRL.rawValue, NSEvent.ModifierFlags.control),
            (GHOSTTY_MODS_ALT.rawValue, NSEvent.ModifierFlags.option),
            (GHOSTTY_MODS_SUPER.rawValue, NSEvent.ModifierFlags.command),
        ] {
            if translationModsRaw & bit != 0 { translationFlags.insert(flag) } else { translationFlags.remove(flag) }
        }
        if translationFlags == event.modifierFlags { return event }
        let translatedChars = event.characters(byApplyingModifiers: translationFlags) ?? ""
        return NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: translationFlags,
                                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                characters: translatedChars,
                                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                                isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }

    private func unshiftedCodepoint(from event: NSEvent) -> UInt32 {
        // characters(byApplyingModifiers:) is only valid for key up/down; a FlagsChanged event would assert
        guard event.type == .keyDown || event.type == .keyUp,
              let chars = event.characters(byApplyingModifiers: []),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }
}

// MARK: - NSTextInputClient

extension SurfaceView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange _: NSRange) {
        // the commit fence: see commitOrDiscardComposition
        guard !committingComposition else { return }
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !text.isEmpty else { return }
        _markedRange = NSRange(location: NSNotFound, length: 0)
        _markedText = ""
        if let surface { ghostty_surface_preedit(surface, nil, 0) }
        if currentKeyEvent != nil {
            keyTextAccumulator.append(text)
        } else if let surface {
            text.withCString { ptr in
                var ke = ghostty_input_key_s()
                ke.action = GHOSTTY_ACTION_PRESS
                ke.text = ptr
                _ = ghostty_surface_key(surface, ke)
            }
        }
    }

    /// `ghostty_surface_preedit` takes a BYTE length over UTF-8; `NSRange` is UTF-16 over the string AppKit sees.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange _: NSRange) {
        guard let surface else { return }
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        _markedRange = text.isEmpty
            ? NSRange(location: NSNotFound, length: 0)
            : NSRange(location: 0, length: text.utf16.count)
        _markedText = text
        _selectedRange = selectedRange
        text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
    }

    func unmarkText() {
        guard let surface else { return }
        _markedRange = NSRange(location: NSNotFound, length: 0)
        _markedText = ""
        ghostty_surface_preedit(surface, nil, 0)
    }

    func selectedRange() -> NSRange {
        hasMarkedText() ? _selectedRange : NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange { _markedRange }
    func hasMarkedText() -> Bool { _markedRange.location != NSNotFound }

    /// The in-flight composition's text, empty when none (for the debug dump).
    var markedTextForDebug: String { hasMarkedText() ? _markedText : "" }

    /// Ends a live IME composition before a programmatic insert by COMMITTING it (what AppKit does when a field
    /// gives up a composition), then tears the input-method session down. `committingComposition` fences that
    /// one call so an input method that finalizes on teardown cannot land the same characters twice.
    func commitOrDiscardComposition() {
        guard hasMarkedText() else { return }
        if _markedText.isEmpty {
            unmarkText()
        } else {
            insertText(_markedText, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        guard window?.firstResponder === self else { return }
        committingComposition = true
        inputContext?.discardMarkedText()
        committingComposition = false
    }

    func attributedSubstring(forProposedRange _: NSRange, actualRange _: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle, .backgroundColor] }

    func characterIndex(for _: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange _: NSRange, actualRange _: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x = 0.0, y = 0.0, w = 0.0, h = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        // libghostty's point is top-left based, which matches this flipped view
        let viewPt = NSPoint(x: x, y: y)
        let windowPt = convert(viewPt, to: nil)
        let screenPt = window?.convertPoint(toScreen: windowPt) ?? windowPt
        return NSRect(x: screenPt.x, y: screenPt.y - h, width: w, height: h)
    }
}

// MARK: - Standard Edit menu (responder chain)

extension SurfaceView: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) { performBindingAction("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { performBindingAction("paste_from_clipboard") }
    override func selectAll(_ sender: Any?) { performBindingAction("select_all") }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            guard let surface else { return false }
            return ghostty_surface_has_selection(surface)
        case #selector(paste(_:)):
            return surface != nil && GhosttyCallbacks.hasInsertable(.general)
        case #selector(selectAll(_:)):
            return surface != nil
        default:
            return true
        }
    }
}
