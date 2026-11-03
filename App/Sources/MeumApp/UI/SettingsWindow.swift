import AppKit
import MeumControl
import MeumCore
import SwiftUI

/// The settings window (⌘,). Every control writes through `AppSettings.set(key, value)`, the same call
/// `settings.set` makes over the API, so a change from here is applied live and published as an event.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let settings: AppSettings
    weak var widgets: WidgetManager?
    var checkForUpdates: (() -> Void)?
    private var window: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: settings, widgets: widgets, checkForUpdates: checkForUpdates))
            let w = NSWindow(contentViewController: host)
            w.title = "\(Product.name) Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 560, height: 720))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("SettingsWindow")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Debug: resize the content (to capture every section in one screenshot).
    func setHeight(_ h: CGFloat) { window?.setContentSize(NSSize(width: 560, height: h)) }

    var isVisible: Bool { window?.isVisible ?? false }
    var windowNumber: Int? { window?.windowNumber }
    func close() { window?.performClose(nil) }
}

struct SettingsView: View {
    @ObservedObject var model: AppSettings
    let widgets: WidgetManager?
    var checkForUpdates: (() -> Void)?
    @State private var configPath = ""
    @State private var hooks: [String] = []
    @State private var hooksLoading = false
    @State private var error: String?

    private var s: MSettings { model.value }

    var body: some View {
        Form {
            Section("Layout") {
                slider("Gap between cards", "cardGap", 0...40, step: 1, unit: "pt") { $0.cardGap }
                slider("Corner radius", "cornerRadius", 0...28, step: 1, unit: "pt") { $0.cornerRadius }
                slider("Sidebar width", "sidebarWidth", 160...480, step: 4, unit: "pt") { $0.sidebarWidth }
            }
            Section("Sidebar") {
                Toggle("Git branch", isOn: plainBool("sidebarShowBranch") { $0.sidebarShowBranch })
                Toggle("Folder", isOn: plainBool("sidebarShowDirectory") { $0.sidebarShowDirectory })
                Toggle("Status entries", isOn: plainBool("sidebarShowStatus") { $0.sidebarShowStatus })
                Toggle("Workspace labels", isOn: plainBool("sidebarShowMetadata") { $0.sidebarShowMetadata })
                Toggle("Listening ports (dev servers)", isOn: plainBool("sidebarShowPorts") { $0.sidebarShowPorts })
                Toggle("Claude session dots", isOn: plainBool("sidebarShowAgentDots") { $0.sidebarShowAgentDots })
                Toggle("Shortcut hints (⌘1…⌘9)", isOn: plainBool("sidebarShowShortcuts") { $0.sidebarShowShortcuts })
                Toggle("Pin on pinned workspaces", isOn: plainBool("sidebarShowPin") { $0.sidebarShowPin })
                Text("Status entries come from `meum status set`, workspace labels from `meum workspace meta`. Folder and branch follow the focused tab. A port opens localhost in the browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            WidgetsSection(model: model, widgets: widgets, set: set)
            Section("Background") {
                Picker("Material", selection: Binding(get: { s.background }, set: { set("background", .string($0.rawValue)) })) {
                    Text("Tint").tag(MSettings.Background.glass)
                    Text("Vibrancy").tag(MSettings.Background.vibrancy)
                    if GlassView.liquidAvailable { Text("Liquid Glass").tag(MSettings.Background.liquid) }
                    Text("Solid colour").tag(MSettings.Background.solid)
                }
                .pickerStyle(.segmented)
                if s.background == .liquid {
                    Picker("Liquid Glass", selection: Binding(get: { s.liquidStyle }, set: { set("liquidStyle", .string($0.rawValue)) })) {
                        Text("Regular").tag(MSettings.LiquidStyle.regular)
                        Text("Clear").tag(MSettings.LiquidStyle.clear)
                    }
                    .pickerStyle(.segmented)
                }
                if s.background != .solid {
                    Toggle("Pinned wallpaper underneath", isOn: plainBool("wallpaper") { $0.wallpaper })
                    Text(s.wallpaper ? "The material shows your desktop picture, blurred and still, not the windows behind meum."
                                     : "The material shows whatever is behind meum.")
                        .font(.caption).foregroundStyle(.secondary)
                    if s.wallpaper {
                        slider("Wallpaper blur", "glassBlur", 0...30, step: 0.5, unit: "pt") { $0.glassBlur }
                    }
                    slider("Tint", "glassTint", 0...1, step: 0.01, unit: "") { $0.glassTint }
                } else {
                    ColorPicker("Colour", selection: Binding(get: { Color(nsColor: SidebarView.nsColor(hex: s.solidColor) ?? .black) },
                                                             set: { set("solidColor", .string(Self.hex($0))) }),
                                supportsOpacity: false)
                }
                slider("Focus frame colour", "focusFrameSaturation", 0...1, step: 0.05, unit: "") { $0.focusFrameSaturation }
                slider("Focus frame strength", "focusFrameOpacity", 0...1, step: 0.05, unit: "") { $0.focusFrameOpacity }
                Text("The frame of the focused card: colour 1 is the workspace colour, 0 grey.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Terminal") {
                Picker("Font", selection: Binding(get: { s.fontFamily ?? "" },
                                                  set: { set("fontFamily", $0.isEmpty ? .null : .string($0)) })) {
                    Text("Ghostty default").tag("")
                    Divider()
                    ForEach(Self.monospacedFamilies(including: s.fontFamily), id: \.self) { Text($0).tag($0) }
                }
                HStack {
                    Text("Font size")
                    Spacer()
                    Text("\(Self.fmt(s.fontSize)) pt").monospacedDigit().foregroundStyle(.secondary)
                    Stepper("", value: Binding(get: { s.fontSize }, set: { set("fontSize", .double($0)) }), in: 6...48, step: 1)
                        .labelsHidden()
                }
                LabeledContent("Extra Ghostty config") {
                    HStack {
                        TextField("", text: $configPath, prompt: Text("none"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { set("ghosttyConfigPath", configPath.isEmpty ? .null : .string(configPath)) }
                        Button("Choose…") { chooseConfig() }
                        if s.ghosttyConfigPath != nil {
                            Button("Reload") { GhosttyApp.shared.reloadFromDisk() }
                                .help("Read the config file again after editing it")
                            Button("Clear") { configPath = ""; set("ghosttyConfigPath", .null) }
                        }
                    }
                }
                Text("Loaded after meum's defaults and <state dir>/ghostty.conf; the font above wins over it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Gaps between cards catch clicks", isOn: plainBool("gapsCatchClicks") { $0.gapsCatchClicks })
                Text("Off: a click between cards reaches the app behind meum. The gaps you drag to resize always catch the mouse.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Reattach running sessions on launch", isOn: plainBool("reattachSessions") { $0.reattachSessions })
                Toggle("Resume Claude sessions after a reboot", isOn: plainBool("resumeClaude") { $0.resumeClaude })
            }
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: plainBool("checkUpdates") { $0.checkUpdates })
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { checkForUpdates?() }
                }
                Text("New versions come from github.com/mcurses/meum. Installing restarts meum; your terminals keep running.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ShortcutsSection(model: model, set: set)
            Section("Claude hooks") {
                if hooksLoading && hooks.isEmpty {
                    ProgressView().controlSize(.small)
                } else if hooks.isEmpty {
                    Text("No Claude config directories found (~/.claude*).").foregroundStyle(.secondary)
                } else {
                    ForEach(hooks, id: \.self) { line in
                        Text(line).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                }
                LabeledContent("Install from a terminal") {
                    Text("meum hooks install --yes").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                Button("Refresh") { loadHooks() }
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            Section {
                LabeledContent("Settings file") {
                    Text(model.store.url.path).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 400)
        .onAppear {
            configPath = s.ghosttyConfigPath ?? ""
            loadHooks()
        }
    }

    // MARK: controls

    private func set(_ key: String, _ value: JSON) {
        do { try model.set(key, value); error = nil } catch { self.error = "\(error)" }
    }

    private func slider(_ title: String, _ key: String, _ range: ClosedRange<Double>, step: Double, unit: String,
                        _ get: @escaping (MSettings) -> Double) -> some View {
        HStack {
            Text(title)
            Slider(value: Binding(get: { get(model.value) }, set: { set(key, .double(($0 / step).rounded() * step)) }),
                   in: range)
            Text(unit.isEmpty ? String(format: "%.2f", get(s)) : "\(Self.fmt(get(s))) \(unit)")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
        }
    }

    private func plainBool(_ key: String, _ get: @escaping (MSettings) -> Bool) -> Binding<Bool> {
        bool(key, get: get, json: { .bool($0) })
    }

    private func bool(_ key: String, get: @escaping (MSettings) -> Bool, json: @escaping (Bool) -> JSON) -> Binding<Bool> {
        Binding(get: { get(model.value) }, set: { set(key, json($0)) })
    }

    private func chooseConfig() {
        let p = NSOpenPanel()
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.showsHiddenFiles = true
        p.message = "Choose a Ghostty config file"
        if p.runModal() == .OK, let url = p.url {
            configPath = url.path
            set("ghosttyConfigPath", .string(url.path))
        }
    }

    /// `meum hooks status` per config dir, read-only, off the main thread.
    private func loadHooks() {
        hooksLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let installer = HookInstaller(home: NSHomeDirectory())
            let dirs = HookInstaller.discoverConfigDirs(home: NSHomeDirectory())
            let lines = installer.targets(for: dirs).map { CLI.statusLine(installer.status(of: $0)) }
            DispatchQueue.main.async {
                hooks = lines
                hooksLoading = false
            }
        }
    }

    // MARK: helpers

    static func fmt(_ d: Double) -> String { d == d.rounded() ? String(Int(d)) : String(format: "%.1f", d) }

    static func hex(_ c: Color) -> String {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .black
        return String(format: "#%02x%02x%02x", Int(n.redComponent * 255), Int(n.greenComponent * 255), Int(n.blueComponent * 255))
    }

    private static let families: [String] = {
        let fm = NSFontManager.shared
        return fm.availableFontFamilies.filter { fam in
            guard let f = fm.font(withFamily: fam, traits: [], weight: 5, size: 12) else { return false }
            return f.isFixedPitch && !fam.hasPrefix(".")
        }.sorted()
    }()

    static func monospacedFamilies(including current: String?) -> [String] {
        guard let current, !current.isEmpty, !families.contains(current) else { return families }
        return [current] + families
    }
}
