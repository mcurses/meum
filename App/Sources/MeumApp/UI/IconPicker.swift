import AppKit
import MeumCore
import SwiftUI

/// Right-click a workspace ▸ Icon…: a popover with SF Symbols to pick from (the calm kind), a field for any other
/// symbol name or up to two characters, and None (the name's first letter).
struct IconPickerView: View {
    let current: String?
    let pick: (String?) -> Void
    @State private var custom = ""
    @State private var error: String?

    static let symbols = [
        "terminal", "hammer", "wrench.and.screwdriver", "gearshape", "cpu", "server.rack", "externaldrive", "antenna.radiowaves.left.and.right",
        "globe", "cloud", "bolt", "flame", "leaf", "sun.max", "moon", "star",
        "sparkles", "wand.and.stars", "brain", "atom", "flask", "testtube.2", "ant", "ladybug",
        "cube", "shippingbox", "puzzlepiece", "square.grid.2x2", "list.bullet", "chart.bar", "chart.line.uptrend.xyaxis", "tag",
        "doc.text", "book", "bookmark", "folder", "tray", "archivebox", "pencil", "paintbrush",
        "paintpalette", "photo", "film", "camera", "music.note", "waveform", "mic", "headphones",
        "bubble.left.and.bubble.right", "envelope", "bell", "calendar", "clock", "map", "flag", "house",
        "building.2", "person.2", "briefcase", "cart", "creditcard", "lock", "key", "gamecontroller",
        "laptopcomputer", "desktopcomputer", "iphone", "keyboard", "airplane", "car", "heart", "graduationcap",
    ]

    static func controller(current: String?, pick: @escaping (String?) -> Void) -> NSViewController {
        NSHostingController(rootView: IconPickerView(current: current, pick: pick))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 8), spacing: 4) {
                ForEach(Self.symbols.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil },
                        id: \.self) { name in
                    let raw = WorkspaceIcon.symbolPrefix + name
                    Button { pick(raw) } label: {
                        Image(systemName: name).font(.system(size: 14, weight: .medium)).frame(width: 30, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(current == raw ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help(name)
                }
            }
            HStack {
                TextField("Other SF Symbol name, or up to two letters", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(apply)
                Button("Set", action: apply).disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("None (first letter)") { pick(nil) }
                Spacer()
                Link("Browse SF Symbols", destination: URL(string: "https://developer.apple.com/sf-symbols/")!)
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 290)
    }

    /// A symbol name (with or without "sf:") becomes a symbol; one or two characters stay text.
    private func apply() {
        let s = custom.trimmingCharacters(in: .whitespaces)
        let raw: String
        if s.hasPrefix(WorkspaceIcon.symbolPrefix) || (s.count > 2 && NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil) {
            raw = s.hasPrefix(WorkspaceIcon.symbolPrefix) ? s : WorkspaceIcon.symbolPrefix + s
        } else {
            raw = s
        }
        guard let icon = WorkspaceIcon(raw) else {
            error = "Not an SF Symbol name, and longer than two characters."
            return
        }
        if case .symbol(let name) = icon, NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil {
            error = "No SF Symbol named '\(name)'."
            return
        }
        pick(icon.raw)
    }
}
