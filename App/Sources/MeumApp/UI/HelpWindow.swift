import AppKit
import MeumCore
import SwiftUI

/// Help ▸ …: one small window with the things meum's surface doesn't say on its own (gestures, what the dots mean,
/// the command line tool and who may use it, how to uninstall). Each Help menu item opens it at its topic.
@MainActor
final class HelpWindowController: NSObject {
    enum Topic: String, CaseIterable { case start, dots, cli, uninstall }

    let nav = ScrollTarget()
    private let socket: String
    private var window: NSWindow?

    init(socket: String) { self.socket = socket }

    /// The bundled CLI, the path other shells and Claude Code need.
    static var cliPath: String {
        Bundle.main.resourceURL?.appendingPathComponent("bin/meum").path
            ?? "/Applications/\(Product.name).app/Contents/Resources/bin/meum"
    }

    static var mcpCommand: String { "claude mcp add --scope user meum -- \(cliPath) mcp" }

    func show(_ topic: Topic) {
        if window == nil {
            let host = NSHostingController(rootView: HelpView(nav: nav, socket: socket))
            let w = NSWindow(contentViewController: host)
            w.title = "\(Product.name) Help"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 520, height: 600))
            w.isReleasedWhenClosed = false
            w.center()
            w.setFrameAutosaveName("HelpWindow")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        nav.target = topic.rawValue
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var windowNumber: Int? { window?.windowNumber }
}

/// Where a scrolling form or page should go next (a section id); the view scrolls there and clears it.
final class ScrollTarget: ObservableObject {
    @Published var target: String?
}

struct HelpView: View {
    @ObservedObject var nav: ScrollTarget
    let socket: String
    @State private var copied: String?

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section("Getting started") {
                    bullet("A workspace is one project: its cards sit side by side, and each card holds tabs (terminals, or widgets such as a browser).")
                    bullet("New tabs, splits and widgets are in the Terminal menu; every shortcut is next to its menu item and can be changed in Settings ▸ Shortcuts.")
                    bullet("Drag a tab onto another card to move it, or onto a card's edge to split it. Double-click the gap between two cards to make them the same size.")
                    bullet("In the sidebar, ⌘-click and ⇧-click select several workspaces; right-click for groups, colour and pin. Workspace ▸ New Workspace (or +) adds one.")
                    bullet("Your terminals keep running when meum quits, and come back when it starts again.")
                    bullet("⌘, opens Settings.")
                }
                .id(HelpWindowController.Topic.start.rawValue)

                Section("What the dots and labels mean") {
                    bullet("The dots need meum's Claude hooks (Settings ▸ Claude hooks ▸ Install).")
                    legend(.systemOrange, "Claude is waiting for you: a permission or a question")
                    legend(.systemGreen, "Claude is working (on a tab)")
                    legend(.systemBlue, "Claude finished and you haven't looked yet")
                    legend(NSColor(white: 0.6, alpha: 1), "Claude is idle")
                    HStack(spacing: 8) {
                        Circle().stroke(Color(nsColor: NSColor(white: 0.6, alpha: 1)), lineWidth: 1.2).frame(width: 7, height: 7)
                        Text("A ring on a tab: Claude runs there, but meum hears nothing from it (no hooks in that profile, or it started before they were installed)")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    bullet("In the sidebar each Claude session in a workspace is one dot: orange, blue or grey. A folded group shows its most urgent one.")
                    bullet("Chips on a tab are labels the Claude session in it set on itself; chips on a sidebar row are the workspace's own labels. meum doesn't check who set them.")
                }
                .id(HelpWindowController.Topic.dots.rawValue)

                Section("Command line tool and Claude Code") {
                    bullet("In every meum tab the `meum` command is on the PATH: type `meum help` for everything it can do.")
                    LabeledContent("Elsewhere") {
                        HStack {
                            Text(HelpWindowController.cliPath).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button("Copy") { copy(HelpWindowController.cliPath, as: "path") }
                        }
                    }
                    bullet("To let every Claude Code session use meum (its own labels, the workspace's name and icon, widgets), add meum's MCP server once:")
                    HStack {
                        Text(HelpWindowController.mcpCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy") { copy(HelpWindowController.mcpCommand, as: "command") }
                    }
                    bullet("Any program running as you can use meum through its control socket: open tabs, type or paste into terminals, set labels and status. The socket is only open to your user:")
                    Text(socket).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let copied { Text("Copied the \(copied) to the clipboard.").font(.caption).foregroundStyle(.secondary) }
                }
                .id(HelpWindowController.Topic.cli.rawValue)

                Section("Uninstall") {
                    bullet("1. Remove the Claude hooks: `meum hooks uninstall --yes` in a meum tab (each settings.json keeps a backup).")
                    bullet("2. End the terminals: close their tabs, or turn off Settings ▸ Behaviour ▸ Reattach running sessions on launch and start meum once more.")
                    bullet("3. Quit meum and move meum.app to the Trash.")
                    bullet("4. Delete ~/.local/state/meum, ~/.local/share/meum and ~/.local/bin/meum-hook.")
                    bullet("If you added the MCP server: `claude mcp remove --scope user meum`.")
                }
                .id(HelpWindowController.Topic.uninstall.rawValue)
            }
            .formStyle(.grouped)
            .frame(minWidth: 440, minHeight: 360)
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

    private func copy(_ s: String, as what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = what
    }

    private func bullet(_ s: String) -> some View {
        Text(.init(s)).fixedSize(horizontal: false, vertical: true)
    }

    private func legend(_ c: NSColor, _ s: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(nsColor: c)).frame(width: 8, height: 8)
            Text(s)
        }
    }
}
