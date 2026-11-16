import AppKit
import MeumControl
import MeumCore
import SwiftUI

/// The first-launch sheet (docs/design/architecture.md, "First launch and offers"): offers once what meum can wire for Claude Code (the hooks,
/// the MCP entry, the CLI link), does it on the person's yes with the CLI's own code, and lists what it wrote.
/// Help ▸ Set Up for Claude Code… opens it again.
@MainActor
final class SetupSheetController: NSObject {
    private var sheet: NSWindow?
    let model = SetupModel()
    /// Opens Help at the uninstall topic (set by the app delegate).
    var onUninstallHelp: (() -> Void)?

    /// On launch: shows the sheet once, when there is something to offer; `setupOffered` is set either way.
    func offerOnce(on window: NSWindow, settings: AppSettings) {
        guard !settings.value.setupOffered else { return }
        model.load { [weak self, weak window] hasOffers in
            settings.markSetupOffered()
            guard hasOffers, let self, let window else { return }
            self.present(on: window)
        }
    }

    /// Help ▸ Set Up for Claude Code…: always shows, also when everything is done.
    func show(on window: NSWindow) {
        if sheet != nil { return }
        model.load { [weak self, weak window] _ in
            guard let self, let window else { return }
            self.present(on: window)
        }
    }

    var isShown: Bool { sheet != nil }
    var debugState: [String: Any] {
        ["shown": sheet != nil, "phase": model.phase.rawValue, "offers": model.offers.map(\.step.rawValue),
         "lines": model.outcomes.flatMap(\.lines)]
    }

    /// For tests: a PNG of the sheet's view, rendered offscreen (AppKit's cache leaves SwiftUI text out). Controls
    /// may draw as placeholders; the text and layout are what this is for.
    func snapshot() -> Data? {
        let view = SetupView(model: model, close: {}, uninstall: {})
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        guard let cg = r.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// For tests: presses Set Up (or Not Now).
    func press(setUp: Bool) {
        if setUp { model.run() } else { close() }
    }

    private func present(on window: NSWindow) {
        guard sheet == nil else { return }
        let view = SetupView(model: model, close: { [weak self] in self?.close() },
                             uninstall: { [weak self] in self?.close(); self?.onUninstallHelp?() })
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.styleMask = [.titled]
        sheet = w
        window.beginSheet(w)
    }

    func dismiss() { close() }

    private func close() {
        guard let s = sheet else { return }
        s.sheetParent?.endSheet(s)
        sheet = nil
    }
}

@MainActor
final class SetupModel: ObservableObject {
    enum Phase: String { case loading, ready, running, done }
    @Published var phase: Phase = .loading
    @Published var offers: [ClaudeSetup.Offer] = []
    @Published var chosen: Set<ClaudeSetup.Step> = []
    @Published var outcomes: [ClaudeSetup.Outcome] = []
    @Published var claudeFound = true
    @Published var configDirs: [String] = []
    private var shell = ClaudeSetup.Shell(claude: nil, path: [])
    /// The home whose Claude config is wired (a debug instance points it at a scratch folder).
    var home = NSHomeDirectory()
    /// A debug instance offers every row from its build folder (it wires a scratch home only).
    var anyBundle = false
    /// This meum runs from outside /Applications: the MCP and link rows are left out, and the sheet says why.
    @Published var notInstalled = false

    static var cliPath: String { HelpWindowController.cliPath }

    func load(_ done: @escaping (Bool) -> Void) {
        phase = .loading
        outcomes = []
        let cli = Self.cliPath, home = self.home
        let installed = anyBundle || ClaudeSetup.isInstalledCLI(cli, home: home)
        DispatchQueue.global(qos: .userInitiated).async {
            let shell = ClaudeSetup.probeShell()
            let setup = ClaudeSetup(home: home, cli: cli)
            let offers = setup.offers(shell: shell, installedCLI: installed)
            let dirs = setup.configDirs
            DispatchQueue.main.async {
                self.shell = shell
                self.offers = offers
                self.chosen = Set(offers.map(\.step))
                self.claudeFound = shell.claude != nil
                self.notInstalled = !installed
                self.configDirs = dirs
                self.phase = .ready
                Log.info("setup: offers \(offers.map(\.step.rawValue)), claude \(shell.claude ?? "not found")")
                done(!offers.isEmpty)
            }
        }
    }

    func run() {
        let todo = offers.filter { chosen.contains($0.step) }
        guard !todo.isEmpty else { return }
        phase = .running
        let shell = self.shell, cli = Self.cliPath, home = self.home
        DispatchQueue.global(qos: .userInitiated).async {
            let setup = ClaudeSetup(home: home, cli: cli)
            var outcomes: [ClaudeSetup.Outcome] = []
            for o in todo {
                switch o.step {
                case .hooks: outcomes.append(Self.installHooks(dirs: o.configDirs, cli: cli, home: home))
                case .mcp: outcomes.append(setup.addMCP(shell: shell, dirs: o.configDirs, run: Self.runProcess))
                case .cli: outcomes.append(setup.linkCLI())
                }
            }
            DispatchQueue.main.async {
                self.outcomes = outcomes
                self.phase = .done
                for o in outcomes { for l in o.lines { Log.info("setup \(o.step.rawValue): \(l)") } }
            }
        }
    }

    /// `meum hooks install --yes` for the given folders, as Settings ▸ Claude hooks does.
    nonisolated static func installHooks(dirs: [String], cli: String, home: String) -> ClaudeSetup.Outcome {
        var out: [String] = [], err: [String] = []
        let env = CLIEnvironment(env: [:], home: home, stdout: { out.append($0) }, stderr: { err.append($0) },
                                 readStdin: { "" }, executable: cli)
        let args = ["hooks", "install", "--yes"] + dirs.flatMap { ["--config-dir", $0] }
        let code = CLI.run(args, environment: env)
        let tilde: (String) -> String = { $0.replacingOccurrences(of: home + "/", with: "~/") }
        if code != 0 {
            return .init(step: .hooks, lines: ["hooks install failed: " + tilde((err + out).joined(separator: " "))], ok: false)
        }
        var lines = dirs.map { "\(tilde($0))/settings.json: meum's hooks added" }
        let backups = out.filter { $0.contains("backup") }.count
        if backups > 0 { lines.append("a backup was written next to each changed settings.json") }
        lines.append("~/.local/bin/meum-hook: written")
        return .init(step: .hooks, lines: lines, ok: true)
    }

    nonisolated static func runProcess(_ exe: String, _ args: [String], _ env: [String: String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (127, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel
    let close: () -> Void
    let uninstall: () -> Void

    static func title(_ s: ClaudeSetup.Step) -> String {
        switch s {
        case .hooks: return "Status dots on Claude tabs"
        case .mcp: return "meum's tools inside Claude Code"
        case .cli: return "The meum command in every shell"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up meum for Claude Code").font(.headline)
            switch model.phase {
            case .loading:
                HStack { ProgressView().controlSize(.small); Text("Looking at what is set up…").foregroundStyle(.secondary) }
            case .ready, .running:
                if model.offers.isEmpty {
                    Text("Everything is set up: the hooks, meum's tools in Claude Code and the command line tool.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.offers, id: \.step) { o in
                    Toggle(isOn: Binding(get: { model.chosen.contains(o.step) },
                                         set: { if $0 { model.chosen.insert(o.step) } else { model.chosen.remove(o.step) } })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(o.step))
                            Text(o.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(model.phase == .running)
                }
                if model.notInstalled {
                    Text("meum's tools for Claude Code and the meum command: move meum to Applications first, then Help ▸ Set Up for Claude Code… offers them.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if !model.claudeFound && !model.offers.contains(where: { $0.step == .mcp }) {
                    Text("meum's tools for Claude Code: `claude` was not found in your shell. The setup command is under Help, for later.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if !model.configDirs.isEmpty {
                    Text("Claude config folders found: " + model.configDirs.map { $0.replacingOccurrences(of: model.home, with: "~") }.joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    if model.phase == .running { ProgressView().controlSize(.small) }
                    Button(model.offers.isEmpty ? "Close" : "Not Now", action: close).keyboardShortcut(.cancelAction)
                    if !model.offers.isEmpty {
                        Button("Set Up") { model.run() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(model.chosen.isEmpty || model.phase == .running)
                    }
                }
            case .done:
                ForEach(model.outcomes, id: \.step) { o in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: o.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(o.ok ? Color.green : Color.orange)
                            Text(Self.title(o.step))
                        }
                        ForEach(o.lines, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
                Text("Claude Code sessions that are already running pick this up when they restart. Help ▸ Uninstall… undoes all of it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("How to Undo…", action: uninstall)
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
