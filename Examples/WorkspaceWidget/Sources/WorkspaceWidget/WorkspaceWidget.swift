import AppKit
import MeumKit
import SwiftUI

@_cdecl("meum_widget_main")
public func meumWidgetMain() -> UnsafeMutableRawPointer {
    MeumWidgetRegistration(manifest: .init(id: "io.github.mcurses.meum.workspace", displayName: "Workspace",
                                           version: "1")) { host in
        WorkspaceWidget(host: host)
    }.export()
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var workspace: MeumWorkspaceInfo?
    @Published var appearance = MeumWidgetAppearance()
}

/// Follows the selected workspace (`workspaceDidChange`). A workspace in the home folder has no project, so the
/// card hides itself there (`setPreferredHeight(0)`), as a project widget would.
@MainActor
final class WorkspaceWidget: MeumWidget {
    let host: MeumWidgetHost
    let model = WorkspaceModel()
    lazy var view: NSView = {
        let v = NSHostingView(rootView: WorkspaceView(model: model))
        v.sizingOptions = []
        return v
    }()

    init(host: MeumWidgetHost) {
        self.host = host
        model.appearance = host.appearance
        workspaceDidChange(host.selectedWorkspace)
    }

    func appearanceDidChange(_ a: MeumWidgetAppearance) { model.appearance = a }

    func workspaceDidChange(_ ws: MeumWorkspaceInfo?) {
        model.workspace = ws
        let home = NSHomeDirectory()
        let hasProject = ws?.cwd.map { !$0.isEmpty && $0 != home && $0 != home + "/" } ?? false
        host.setPreferredHeight(hasProject ? 52 + CGFloat((ws?.remote == nil ? 0 : 1) + (ws?.metadata.count ?? 0)) * 14 : 0)
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(model.workspace?.name ?? "no workspace").font(.caption.weight(.semibold)).lineLimit(1)
            }
            Text(((model.workspace?.cwd ?? "") as NSString).abbreviatingWithTildeInPath)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let r = model.workspace?.remote {
                Text(r).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            ForEach((model.workspace?.metadata ?? [:]).sorted(by: { $0.key < $1.key }), id: \.key) { k, v in
                Text("\(k): \(v)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, model.appearance.scheme == .dark ? .dark : .light)
    }

    private var color: Color {
        guard let hex = model.workspace?.color, hex.count == 7, let v = UInt32(hex.dropFirst(), radix: 16) else { return .gray }
        return Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}
