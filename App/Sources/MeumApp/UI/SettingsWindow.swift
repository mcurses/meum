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
    var updates: UpdateCenter?
    /// The section the window scrolls to when it opens (Help ▸ Keyboard Shortcuts…, Terminal ▸ Add Widget ▸ Get Widgets…).
    let nav = ScrollTarget()
    private var window: NSWindow?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: settings, widgets: widgets, checkForUpdates: checkForUpdates,
                                                                  updates: updates ?? UpdateCenter { nil }, nav: nav))
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

    /// Opens the window scrolled to a section: "widgets", "shortcuts", "hooks".
    func show(section: String) {
        show()
        nav.target = section
    }

    /// Debug: resize the content (to capture every section in one screenshot).
    func setHeight(_ h: CGFloat) { window?.setContentSize(NSSize(width: 560, height: h)) }

    var isVisible: Bool { window?.isVisible ?? false }
    var windowNumber: Int? { window?.windowNumber }
    /// For DebugControl's `click … settings`.
    var debugWindow: NSWindow? { window }
    func close() { window?.performClose(nil) }
}

struct SettingsView: View {
    @ObservedObject var model: AppSettings
    let widgets: WidgetManager?
    var checkForUpdates: (() -> Void)?
    @ObservedObject var updates: UpdateCenter
    @ObservedObject var nav: ScrollTarget
    @State private var configPath = ""
    /// The bundled Ghostty colour themes (read once).
    private let themes = GhosttyApp.shared.themeNames
    @State private var hooks: [String] = []
    @State private var hooksLoading = false
    /// nil until loaded: whether any Claude config dir has meum's hooks.
    @State private var hooksInstalled: Bool?
    @State private var hooksInstalling = false
    @State private var hooksMessage: String?
    @State private var error: String?

    private var s: MSettings { model.value }

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onAppear { scroll(proxy) }
                .onChange(of: nav.target) { _ in scroll(proxy) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let t = nav.target else { return }
        DispatchQueue.main.async {
            withAnimation { proxy.scrollTo(t, anchor: .top) }
            nav.target = nil
        }
    }

    private var form: some View {
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
                Toggle("Workspace metadata", isOn: plainBool("sidebarShowMetadata") { $0.sidebarShowMetadata })
                Toggle("Listening ports (dev servers)", isOn: plainBool("sidebarShowPorts") { $0.sidebarShowPorts })
                Toggle("Claude session dots", isOn: plainBool("sidebarShowAgentDots") { $0.sidebarShowAgentDots })
                if s.sidebarShowAgentDots, hooksInstalled == false {
                    Text("The dots need the Claude hooks, which aren't installed: see Claude hooks below.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Shortcut hints (⌘1…⌘9)", isOn: plainBool("sidebarShowShortcuts") { $0.sidebarShowShortcuts })
                Toggle("Pin on pinned workspaces", isOn: plainBool("sidebarShowPin") { $0.sidebarShowPin })
                Text("Status entries come from `meum status set`, metadata from `meum workspace meta`, the label chips from `meum workspace labels`. Folder and branch follow the focused tab. A port opens localhost in the browser.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            WidgetsSection(model: model, widgets: widgets, updates: updates, set: set).id("widgets")
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
                Picker("Colour theme", selection: Binding(get: { s.terminalTheme ?? "" },
                                                          set: { set("terminalTheme", $0.isEmpty ? .null : .string($0)) })) {
                    Text("meum default").tag("")
                    Divider()
                    ForEach(themes, id: \.self) { Text($0).tag($0) }
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
                Text("Loaded after meum's defaults and <state dir>/ghostty.conf; the font and colour theme above win over it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Gaps between cards catch clicks", isOn: plainBool("gapsCatchClicks") { $0.gapsCatchClicks })
                Text("Off: a click between cards reaches the app behind meum. The gaps you drag to resize always catch the mouse.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Reattach running sessions on launch", isOn: plainBool("reattachSessions") { $0.reattachSessions })
                Toggle("Resume Claude sessions after a reboot", isOn: plainBool("resumeClaude") { $0.resumeClaude })
            }
            Section {
                if let v = updates.appUpdate {
                    HStack {
                        UpdateDot()
                        Text("meum \(v) is available")
                        Spacer()
                        Button("Install…") { checkForUpdates?() }
                    }
                }
                Toggle("Check for updates automatically", isOn: plainBool("checkUpdates") { $0.checkUpdates })
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Check Now") { checkForUpdates?() }
                }
                Text("New versions come from github.com/mcurses/meum. Installing restarts meum; your terminals keep running.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HStack(spacing: 6) { Text("Updates"); if updates.appUpdate != nil { UpdateDot() } }
            }
            ShortcutsSection(model: model, set: set).id("shortcuts")
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
                Text("These hooks let meum see your Claude Code sessions: the coloured dots, \"waiting for you\" notifications, the session's name on its tab, and resume after a reboot. Installing adds meum's entries to each settings.json (after a backup) and leaves your other hooks alone.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(hooksInstalled == true ? "Reinstall" : "Install") { installHooks() }
                        .disabled(hooksInstalling || hooks.isEmpty)
                    Button("Refresh") { loadHooks() }
                    if hooksInstalling { ProgressView().controlSize(.small) }
                }
                if let hooksMessage {
                    Text(hooksMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("From a terminal") {
                    Text("meum hooks install --yes").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            .id("hooks")
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
            let sts = installer.targets(for: dirs).map { installer.status(of: $0) }
            let lines = sts.map { CLI.statusLine($0) }
            let any = sts.contains { !$0.installedEvents.isEmpty }
            DispatchQueue.main.async {
                hooks = lines
                hooksInstalled = any
                hooksLoading = false
            }
        }
    }

    /// `meum hooks install --yes` for every config dir, with the script from this bundle; then reloads.
    private func installHooks() {
        hooksInstalling = true
        hooksMessage = nil
        let exe = Bundle.main.resourceURL?.appendingPathComponent("bin/meum").path
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String] = [], err: [String] = []
            let env = CLIEnvironment(env: [:], home: NSHomeDirectory(), stdout: { out.append($0) },
                                     stderr: { err.append($0) }, readStdin: { "" }, executable: exe)
            let code = CLI.run(["hooks", "install", "--yes"], environment: env)
            let backups = out.filter { $0.contains("backup") }.count
            let msg = code == 0
                ? "Installed." + (backups > 0 ? " Backups were written next to each changed settings.json." : " Nothing needed changing.")
                    + " Claude Code sessions that are already running pick the hooks up when they restart."
                : "Install failed: " + (err + out.filter { $0.contains("ERROR") }).joined(separator: " ")
            DispatchQueue.main.async {
                hooksInstalling = false
                hooksMessage = msg
                loadHooks()
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

/// The small dot that marks an available update.
struct UpdateDot: View {
    var body: some View { Circle().fill(Color.orange).frame(width: 7, height: 7) }
}
