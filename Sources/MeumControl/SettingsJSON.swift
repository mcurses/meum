// The settings as the control API shows them: one flat object of keys, validated on write.
//
//   settings.get {key?}         -> {"settings": {key: value…}, "path"} or {"key", "value"}
//   settings.set {key, value}   -> {"key", "value"} (the stored, normalised value); event settings.changed {key, value}
//
// Keys and value types (ranges are enforced; out-of-range numbers are an error, not clamped):
//   cardGap 0…48, cornerRadius 0…32, sidebarWidth 160…480, widgetHeight 40…800 | "auto",
//   background "glass"(="tint")|"vibrancy"|"liquid"|"solid", wallpaper bool (the pinned wallpaper under the material),
//   liquidStyle "regular"|"clear", focusFrameSaturation 0…1 (focused card frame: 1 workspace colour, 0 grey),
//   focusFrameOpacity 0…1, glassBlur 0…40, glassTint 0…1, solidColor "#rrggbb",
//   fontFamily string|null, fontSize 6…48, terminalTheme string|null (a bundled Ghostty theme's name), ghosttyConfigPath string|null, gapsCatchClicks bool,
//   reattachSessions bool, resumeClaude bool, sidebarCollapsed bool, checkUpdates bool (daily release check),
//   showStartHint bool (the one-line hint at the bottom of the window, until closed),
//   sidebarShowBranch, sidebarShowDirectory, sidebarShowStatus, sidebarShowMetadata, sidebarShowPorts, sidebarShowAgentDots,
//   sidebarShowShortcuts, sidebarShowPin, sidebarShowIcons bool   what a sidebar row shows besides the name
//   widgetOrder [widget id…]   top to bottom within each group (workspace widgets above global ones)
//   widgetCatalogURL "https://…"   the widget library's catalog.json (null restores the default)
//   widgetTeamIDs [Team ID…]   Developer ID teams whose signed widgets load without a pinned hash
//   widgetDeveloperMode bool   load unverified widgets too
//   (the three widget* trust keys are read-only here: settings.set refuses them, Settings ▸ Widgets changes them)
//   statusLinkSchemes [scheme…]   link schemes besides http(s) a status entry's click opens without asking; added
//                               when the user says yes in meum, read-only here like the widget trust keys
//   shortcuts {actionID: "cmd+shift+r" | null}   every action's combination in effect (null = none); setting it
//                                               takes an object of the actions to change
//   shortcut.<actionID> "cmd+shift+r" | "none" | null   one action; "none" removes its shortcut, null restores
//                                               the default (MeumCore/Shortcuts.swift lists actions and syntax)
import Foundation
import MeumCore

public enum SettingsJSON {
    /// Widget trust: what decides which native code loads into meum. Readable over the socket, changed only in
    /// Settings ▸ Widgets, so no program in a tab (a session, a script, a postinstall) can lower it for itself.
    /// The bundled theme names, for checking `terminalTheme` (the app sets it; nil accepts any plain name).
    nonisolated(unsafe) public static var themeNames: (() -> [String])?

    public static let socketReadOnly: Set<String> = ["widgetDeveloperMode", "widgetTeamIDs", "widgetCatalogURL",
                                                     "statusLinkSchemes"]

    /// The refusal a socket client gets for a read-only key.
    public static func socketRefusal(_ key: String) -> String {
        key == "statusLinkSchemes"
            ? "'statusLinkSchemes' can't be changed from a program: meum asks the user on the first click on a link of "
                + "a new kind, so nothing running in a tab can allow one for itself"
            : trustRefusal("'\(key)'")
    }

    /// The refusal a socket client gets for a trust change (`what`: the setting or the command it tried).
    public static func trustRefusal(_ what: String) -> String {
        "\(what) can't be changed from a program: widget trust is set only in meum's Settings ▸ Widgets, where nothing "
            + "running in a tab can do it for you (`meum widget allow` is gone too; use the Allow button there)"
    }

    public static let keys: [String] = [
        "cardGap", "cornerRadius", "sidebarWidth", "sidebarCollapsed", "widgetHeight", "widgetOrder", "widgetCatalogURL", "widgetTeamIDs", "widgetDeveloperMode", "background", "wallpaper", "liquidStyle", "focusFrameSaturation", "focusFrameOpacity", "glassBlur", "glassTint",
        "solidColor", "fontFamily", "fontSize", "terminalTheme", "ghosttyConfigPath", "gapsCatchClicks", "reattachSessions",
        "resumeClaude", "shortcuts", "checkUpdates", "showStartHint", "statusLinkSchemes",
    ] + sidebarShowKeys

    /// The sidebar row's show/hide switches.
    public static let sidebarShowKeys: [String] = ["sidebarShowBranch", "sidebarShowDirectory", "sidebarShowStatus", "sidebarShowMetadata", "sidebarShowPorts", "sidebarShowAgentDots", "sidebarShowShortcuts", "sidebarShowPin", "sidebarShowIcons"]

    static let ranges: [String: ClosedRange<Double>] = [
        "cardGap": 0...48, "cornerRadius": 0...32, "sidebarWidth": 160...480, "widgetHeight": 40...800,
        "glassBlur": 0...40, "glassTint": 0...1, "focusFrameSaturation": 0...1, "focusFrameOpacity": 0...1, "fontSize": 6...48,
    ]

    static func num(_ d: Double) -> JSON { d == d.rounded() && abs(d) < 1e9 ? .int(Int(d)) : .double(d) }
    static func str(_ s: String?) -> JSON { s.map { .string($0) } ?? .null }

    public static func value(_ s: Settings, _ key: String) -> JSON? {
        switch key {
        case "cardGap": return num(s.cardGap)
        case "cornerRadius": return num(s.cornerRadius)
        case "sidebarWidth": return num(s.sidebarWidth)
        case "sidebarCollapsed": return .bool(s.sidebarCollapsed)
        case "widgetHeight": return s.widgetHeightAuto ? "auto" : num(s.widgetHeight)
        case "widgetOrder": return .array(s.widgetOrder.map { .string($0) })
        case "widgetCatalogURL": return .string(s.widgetCatalogURL)
        case "widgetTeamIDs": return .array(s.widgetTeamIDs.map { .string($0) })
        case "widgetDeveloperMode": return .bool(s.widgetDeveloperMode)
        case "background": return .string(s.background.rawValue)
        case "wallpaper": return .bool(s.wallpaper)
        case "focusFrameSaturation": return num(s.focusFrameSaturation)
        case "focusFrameOpacity": return num(s.focusFrameOpacity)
        case "liquidStyle": return .string(s.liquidStyle.rawValue)
        case "glassBlur": return num(s.glassBlur)
        case "glassTint": return num(s.glassTint)
        case "solidColor": return .string(s.solidColor)
        case "fontFamily": return str(s.fontFamily)
        case "fontSize": return num(s.fontSize)
        case "terminalTheme": return str(s.terminalTheme)
        case "ghosttyConfigPath": return str(s.ghosttyConfigPath)
        case "gapsCatchClicks": return .bool(s.gapsCatchClicks)
        case "reattachSessions": return .bool(s.reattachSessions)
        case "resumeClaude": return .bool(s.resumeClaude)
        case "checkUpdates": return .bool(s.checkUpdates)
        case "showStartHint": return .bool(s.showStartHint)
        case "sidebarShowBranch": return .bool(s.sidebarShowBranch)
        case "sidebarShowDirectory": return .bool(s.sidebarShowDirectory)
        case "sidebarShowStatus": return .bool(s.sidebarShowStatus)
        case "sidebarShowMetadata": return .bool(s.sidebarShowMetadata)
        case "sidebarShowPorts": return .bool(s.sidebarShowPorts)
        case "sidebarShowAgentDots": return .bool(s.sidebarShowAgentDots)
        case "sidebarShowShortcuts": return .bool(s.sidebarShowShortcuts)
        case "sidebarShowPin": return .bool(s.sidebarShowPin)
        case "sidebarShowIcons": return .bool(s.sidebarShowIcons)
        case "statusLinkSchemes": return .array(s.statusLinkSchemes.map { .string($0) })
        case "shortcuts":
            return .object(Dictionary(uniqueKeysWithValues: Shortcuts.actions.map { a in
                (a.id, Shortcuts.combo(a.id, in: s).map { .string($0.text) } ?? .null)
            }))
        default:
            if key.hasPrefix("shortcut."), Shortcuts.ids.contains(String(key.dropFirst(9))) {
                return Shortcuts.combo(String(key.dropFirst(9)), in: s).map { .string($0.text) } ?? .null
            }
            return nil
        }
    }

    public static func object(_ s: Settings) -> JSON {
        .object(Dictionary(uniqueKeysWithValues: keys.map { ($0, value(s, $0)!) }))
    }

    /// Applies one key. Throws `invalid_params` for an unknown key or a bad value.
    public static func set(_ s: inout Settings, key: String, value v: JSON) throws {
        func number() throws -> Double {
            guard let d = v.doubleValue ?? v.stringValue.flatMap(Double.init), d.isFinite else {
                throw ControlError.invalidParams("'\(key)' needs a number")
            }
            if let r = ranges[key], !r.contains(d) {
                throw ControlError.invalidParams("'\(key)' must be within \(num(r.lowerBound).compactString)…\(num(r.upperBound).compactString)")
            }
            return d
        }
        func bool() throws -> Bool {
            if let b = v.boolValue { return b }
            if let t = v.stringValue?.lowercased(), ["true", "false", "on", "off", "1", "0", "yes", "no"].contains(t) {
                return ["true", "on", "1", "yes"].contains(t)
            }
            throw ControlError.invalidParams("'\(key)' needs true or false")
        }
        func optionalString() throws -> String? {
            if v.isNull { return nil }
            guard let t = v.stringValue else { throw ControlError.invalidParams("'\(key)' needs a string or null") }
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        switch key {
        case "cardGap": s.cardGap = try number()
        case "cornerRadius": s.cornerRadius = try number()
        case "sidebarWidth": s.sidebarWidth = try number()
        case "widgetHeight":
            if v.stringValue?.lowercased() == "auto" { s.widgetHeightAuto = true } else {
                s.widgetHeight = try number()
                s.widgetHeightAuto = false
            }
        case "widgetOrder":
            let items = v.arrayValue ?? v.stringValue.map { $0.split(whereSeparator: { $0 == "," || $0 == " " }).map { JSON.string(String($0)) } }
            guard let items, items.allSatisfy({ $0.stringValue != nil }) else {
                throw ControlError.invalidParams("'widgetOrder' needs a list of widget ids")
            }
            s.widgetOrder = items.compactMap(\.stringValue).filter { !$0.isEmpty }
        case "widgetCatalogURL":
            if v.isNull { s.widgetCatalogURL = Settings.defaultWidgetCatalogURL; break }
            guard let u = v.stringValue, let url = URL(string: u), ["https", "file"].contains(url.scheme ?? "") else {
                throw ControlError.invalidParams("'widgetCatalogURL' must be an https:// (or file://) URL")
            }
            s.widgetCatalogURL = u
        case "widgetTeamIDs":
            let items = v.arrayValue ?? v.stringValue.map { $0.split(whereSeparator: { $0 == "," || $0 == " " }).map { JSON.string(String($0)) } }
            let ids = items?.compactMap(\.stringValue).map { $0.uppercased() } ?? []
            guard items != nil, ids.allSatisfy({ $0.count == 10 && $0.allSatisfy { $0.isLetter || $0.isNumber } }) else {
                throw ControlError.invalidParams("'widgetTeamIDs' needs a list of 10-character Team IDs")
            }
            s.widgetTeamIDs = ids
        case "widgetDeveloperMode": s.widgetDeveloperMode = try bool()
        case "background":
            let raw = v.stringValue?.lowercased() == "tint" ? "glass" : v.stringValue?.lowercased()
            guard let b = raw.flatMap({ Settings.Background(rawValue: $0) }) else {
                throw ControlError.invalidParams("'background' must be one of glass (tint), vibrancy, liquid, solid")
            }
            s.background = b
        case "wallpaper": s.wallpaper = try bool()
        case "focusFrameSaturation": s.focusFrameSaturation = try number()
        case "focusFrameOpacity": s.focusFrameOpacity = try number()
        case "liquidStyle":
            guard let st = v.stringValue.flatMap({ Settings.LiquidStyle(rawValue: $0.lowercased()) }) else {
                throw ControlError.invalidParams("'liquidStyle' must be regular or clear")
            }
            s.liquidStyle = st
        case "glassBlur": s.glassBlur = try number()
        case "glassTint": s.glassTint = try number()
        case "solidColor":
            var h = (v.stringValue ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if !h.hasPrefix("#") { h = "#" + h }
            guard h.count == 7, UInt32(h.dropFirst(), radix: 16) != nil else {
                throw ControlError.invalidParams("'solidColor' must be #rrggbb")
            }
            s.solidColor = h
        case "fontFamily": s.fontFamily = try optionalString().map(Settings.configSafe)
        case "terminalTheme":
            let name = try optionalString()
            if let name, !name.isEmpty {
                guard Settings.isThemeName(name), themeNames?().contains(name) ?? true else {
                    throw ControlError.invalidParams("'terminalTheme' must be the name of a bundled theme (Settings ▸ Terminal lists them)")
                }
            }
            s.terminalTheme = name
        case "fontSize": s.fontSize = try number()
        case "ghosttyConfigPath": s.ghosttyConfigPath = try optionalString().map { ($0 as NSString).expandingTildeInPath }
        case "gapsCatchClicks": s.gapsCatchClicks = try bool()
        case "sidebarCollapsed": s.sidebarCollapsed = try bool()
        case "reattachSessions": s.reattachSessions = try bool()
        case "resumeClaude": s.resumeClaude = try bool()
        case "checkUpdates": s.checkUpdates = try bool()
        case "showStartHint": s.showStartHint = try bool()
        case "sidebarShowBranch": s.sidebarShowBranch = try bool()
        case "sidebarShowDirectory": s.sidebarShowDirectory = try bool()
        case "sidebarShowStatus": s.sidebarShowStatus = try bool()
        case "sidebarShowMetadata": s.sidebarShowMetadata = try bool()
        case "sidebarShowPorts": s.sidebarShowPorts = try bool()
        case "sidebarShowAgentDots": s.sidebarShowAgentDots = try bool()
        case "sidebarShowShortcuts": s.sidebarShowShortcuts = try bool()
        case "sidebarShowPin": s.sidebarShowPin = try bool()
        case "sidebarShowIcons": s.sidebarShowIcons = try bool()
        case "statusLinkSchemes":
            let items = v.isNull ? [] : v.arrayValue?.compactMap(\.stringValue).map { $0.lowercased() }
            guard let items, items.allSatisfy({ StatusLink.isScheme($0) && !StatusLink.alwaysOpen.contains($0) && StatusLink.mayRemember($0) }) else {
                throw ControlError.invalidParams("'statusLinkSchemes' needs a list of URL schemes other than http(s), file, shortcuts and x-apple.systempreferences (those are asked about every time)")
            }
            s.statusLinkSchemes = Array(NSOrderedSet(array: items)).compactMap { $0 as? String }
        case "shortcuts":
            guard let o = v.objectValue else { throw ControlError.invalidParams("'shortcuts' needs an object {actionID: combination}") }
            for (id, c) in o { try setShortcut(&s, id: id, value: c) }
        default:
            if key.hasPrefix("shortcut.") {
                try setShortcut(&s, id: String(key.dropFirst(9)), value: v)
                return
            }
            throw ControlError.invalidParams("unknown setting '\(key)'; known: \(keys.joined(separator: ", "))")
        }
    }

    /// One action's shortcut: a combination, "none"/"" (no shortcut) or null/"default" (the default).
    static func setShortcut(_ s: inout Settings, id: String, value v: JSON) throws {
        guard let action = Shortcuts.action(id) else {
            throw ControlError.invalidParams("unknown shortcut action '\(id)'; known: \(Shortcuts.actions.map(\.id).joined(separator: ", "))")
        }
        let text = v.isNull ? "default" : (v.stringValue ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        switch text {
        case "default":
            s.shortcuts[id] = nil
        case "", "none":
            s.shortcuts[id] = action.defaultCombo == nil ? nil : ""
        default:
            guard let combo = KeyCombo(text) else {
                throw ControlError.invalidParams("'\(text)' is not a key combination; write it like cmd+shift+r")
            }
            guard combo.isUsable else {
                throw ControlError.invalidParams("'\(text)' needs cmd, ctrl or opt (a plain key would be typed into the terminal)")
            }
            s.shortcuts[id] = combo == action.defaultCombo ? nil : combo.text
        }
    }
}
