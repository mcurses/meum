import AppKit
import MeumControl
import MeumCore
import SwiftUI

/// Settings ▸ Shortcuts: one row per action, grouped like the menu. Click a shortcut and press the new keys;
/// Escape cancels, Delete removes the shortcut, the arrow button restores the default.
struct ShortcutsSection: View {
    @ObservedObject var model: AppSettings
    let set: (String, JSON) -> Void
    @State private var recording: String?
    @State private var monitor: Any?

    static let recordRequest = Notification.Name("meum.debug.recordShortcut")

    private var groups: [String] {
        var seen: [String] = []
        for a in Shortcuts.actions where !seen.contains(a.group) { seen.append(a.group) }
        return seen
    }

    var body: some View {
        ForEach(groups, id: \.self) { group in
            Section(group == "App" ? "Shortcuts" : "Shortcuts: \(group)") {
                ForEach(Shortcuts.actions.filter { $0.group == group }, id: \.id) { a in row(a) }
            }
        }
        .onDisappear { stop() }
        // debug interface (`record-shortcut ID`): starts recording as a click on the shortcut would
        .onReceive(NotificationCenter.default.publisher(for: Self.recordRequest)) { n in
            if let id = n.object as? String { start(id) }
        }
    }

    @ViewBuilder private func row(_ a: ShortcutAction) -> some View {
        let combo = Shortcuts.combo(a.id, in: model.value)
        let conflicts = combo.map { Shortcuts.conflicts($0, except: a.id, in: model.value) } ?? []
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(a.title)
                if !conflicts.isEmpty {
                    Text("Also used by \(conflicts.map(\.title).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            Button(action: { recording == a.id ? stop() : start(a.id) }) {
                Text(recording == a.id ? "Press keys…" : (combo?.display ?? "—"))
                    .monospaced()
                    .frame(minWidth: 96)
            }
            .accessibilityIdentifier("shortcut.\(a.id)")
            Button(action: { stop(); set("shortcut.\(a.id)", .null) }) { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless)
                .help("Restore \(a.defaultCombo?.display ?? "no shortcut")")
                .disabled(model.value.shortcuts[a.id] == nil)
        }
    }

    private func start(_ id: String) {
        stop()
        recording = id
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    /// Returns true when the event was used (it then never reaches the menu or a terminal).
    private func handle(_ event: NSEvent) -> Bool {
        guard let id = recording else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = mods.intersection([.command, .control, .option, .shift]).isEmpty
        if plain, event.keyCode == 53 { stop(); return true }                           // escape: cancel
        if plain, event.keyCode == 51 || event.keyCode == 117 { stop(); set("shortcut.\(id)", "none"); return true }
        guard let combo = Self.combo(from: event) else { return true }
        guard combo.isUsable else { NSSound.beep(); return true }                      // keep waiting
        stop()
        set("shortcut.\(id)", .string(combo.text))
        return true
    }

    /// The combination a key event stands for, in the current keyboard layout.
    static func combo(from event: NSEvent) -> KeyCombo? {
        let m = event.modifierFlags
        var c = KeyCombo(key: "", command: m.contains(.command), shift: m.contains(.shift),
                         option: m.contains(.option), control: m.contains(.control))
        let names: [NSEvent.SpecialKey: String] = [
            .leftArrow: "left", .rightArrow: "right", .upArrow: "up", .downArrow: "down", .carriageReturn: "return",
            .tab: "tab", .delete: "delete", .f1: "f1", .f2: "f2", .f3: "f3", .f4: "f4", .f5: "f5", .f6: "f6",
            .f7: "f7", .f8: "f8", .f9: "f9", .f10: "f10", .f11: "f11", .f12: "f12",
        ]
        if let sk = event.specialKey, let n = names[sk] {
            c.key = n
        } else if event.keyCode == 49 {
            c.key = "space"
        } else if event.keyCode == 53 {
            c.key = "escape"
        } else {
            // the character without modifiers (so ⇧⌘R records "r", not "R"; ⌥ does not turn it into "®")
            guard let ch = event.characters(byApplyingModifiers: [])?.lowercased(), ch.count == 1 else { return nil }
            c.key = ch
        }
        return c
    }
}
