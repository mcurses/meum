import AppKit
import MeumControl
import MeumCore
import SwiftUI

/// Settings ▸ Widgets: the stacked cards under the sidebar, top to bottom. A switch shows or hides a widget,
/// the arrows move it within its group (workspace widgets always sit above global ones). Below: the widget
/// library (install, update, remove), and "Allow" for a widget that is not from the library.
struct WidgetsSection: View {
    @ObservedObject var model: AppSettings
    let widgets: WidgetManager?
    @ObservedObject var updates: UpdateCenter
    let set: (String, JSON) -> Void
    @State private var rows: [Row] = []
    @State private var error: String?

    struct Row: Identifiable, Equatable {
        var id: String
        var name: String
        var scope: WidgetManager.Scope
        var enabled: Bool
        var error: String?
        var unverified: Bool = false
    }

    struct LibraryRow: Identifiable, Equatable {
        var id: String
        var name: String
        var description: String
        var version: String
        var installed: Bool
        var update: Bool
        var runs: Bool
        var needsMeum: String? = nil
    }
    @State private var library: [LibraryRow] = []
    @State private var libraryState = "not loaded"
    /// The last install, update or removal that failed, by widget id: shown on that widget's library row.
    @State private var libraryErrors: [String: String] = [:]
    @State private var busy: String?
    @State private var trustOpen = false
    @State private var catalogDraft = ""
    @State private var teamsDraft = ""

    private func syncTrustDrafts() {
        catalogDraft = model.value.widgetCatalogURL
        teamsDraft = model.value.widgetTeamIDs.joined(separator: ", ")
    }

    var body: some View {
        Section("Widgets") {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Tips")
                    Text("built in: a few things no menu shows").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { model.value.showStartHint }, set: { set("showStartHint", .bool($0)) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if rows.isEmpty {
                Text("No widgets installed in \(widgets?.directory.path ?? "the widgets folder").")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { r in row(r) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            Toggle("Card height: automatic", isOn: Binding(get: { model.value.widgetHeightAuto },
                                                         set: { set("widgetHeight", $0 ? "auto" : .double(model.value.widgetHeight)) }))
            if !model.value.widgetHeightAuto {
                HStack {
                    Text("Card height")
                    Slider(value: Binding(get: { model.value.widgetHeight }, set: { set("widgetHeight", .double(($0 / 2).rounded() * 2)) }),
                           in: 40...600)
                    Text("\(Int(model.value.widgetHeight)) pt").monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
            Text("Workspace widgets show the selected workspace and sit above the global ones.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section {
            ForEach(library) { r in libraryRow(r) }
            HStack {
                Text(libraryState).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { loadLibrary() }.disabled(busy != nil)
            }
            Toggle("Developer mode: load widgets that are not verified",
                   isOn: Binding(get: { model.value.widgetDeveloperMode }, set: { set("widgetDeveloperMode", .bool($0)) }))
            DisclosureGroup("Where widgets come from", isExpanded: $trustOpen) {
                HStack {
                    TextField("Library address", text: $catalogDraft, prompt: Text(Settings.defaultWidgetCatalogURL))
                        .onSubmit { set("widgetCatalogURL", catalogDraft.isEmpty ? .null : .string(catalogDraft)) }
                    Button("Default") { set("widgetCatalogURL", .null) }
                        .disabled(model.value.widgetCatalogURL == Settings.defaultWidgetCatalogURL)
                }
                TextField("Trusted developer teams", text: $teamsDraft, prompt: Text("Team IDs, comma-separated"))
                    .onSubmit {
                        let ids = teamsDraft.split(whereSeparator: { $0 == "," || $0 == " " }).map { JSON.string(String($0)) }
                        set("widgetTeamIDs", .array(ids))
                    }
                Text("Only here: no program running in a tab can change these, turn on developer mode or allow a widget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { syncTrustDrafts() }
            .onChange(of: model.value.widgetCatalogURL) { _ in syncTrustDrafts() }
            .onChange(of: model.value.widgetTeamIDs) { _ in syncTrustDrafts() }
        }
        header: {
            HStack(spacing: 6) {
                Text("Widget Library")
                if !updates.widgetUpdates.isEmpty {
                    UpdateDot()
                    Text(updates.widgetUpdates.count == 1 ? "update available" : "\(updates.widgetUpdates.count) updates available")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        // show the last background check at once, then fetch afresh every time the settings open
        .onAppear { if let c = updates.catalog { show(c) }; loadLibrary() }
        .onChange(of: model.value.widgetDeveloperMode) { widgets?.reload(); refresh() }
        .onAppear { refresh() }
        .onChange(of: model.value.widgetOrder) { refresh() }
    }

    @ViewBuilder private func row(_ r: Row) -> some View {
        let group = rows.filter { $0.scope == r.scope }
        let i = group.firstIndex(of: r) ?? 0
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name)
                Text(r.scope == .workspace ? "follows the workspace"
                     : r.scope == .tile ? "only as a tab (Terminal ▸ Add Widget)" : "same on every workspace")
                    .font(.caption).foregroundStyle(.secondary)
                if let e = r.error { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            if r.unverified {
                Button("Allow") { allow(r) }
                    .help("Trust this widget as it is now. Only do this for widgets you built or got from someone you trust.")
            }
            Button { move(r, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless).disabled(i == 0 || !r.enabled)
            Button { move(r, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless).disabled(i == group.count - 1 || !r.enabled)
            Toggle("", isOn: Binding(get: { r.enabled }, set: { enable(r, $0) })).labelsHidden().toggleStyle(.switch)
        }
    }

    private func refresh() {
        guard let w = widgets else { rows = []; return }
        let entries = WidgetManager.ordered(w.scan(), order: model.value.widgetOrder)
        // tile-only widgets (the browser) are listed too when they need attention
        rows = entries.compactMap { e in
            let unverified = w.trustKind(e) == "unverified"
            guard e.scope != .tile || unverified else { return nil }
            return Row(id: e.id, name: e.displayName, scope: e.scope, enabled: !e.disabled,
                       error: w.slots.first { $0.entry?.folder == e.folder }?.error
                           ?? (unverified ? "not verified: not loaded" : nil),
                       unverified: unverified)
        }
    }

    @ViewBuilder private func libraryRow(_ r: LibraryRow) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(r.name)  ").bold() + Text(r.version).foregroundStyle(.secondary)
                if !r.description.isEmpty { Text(r.description).font(.caption).foregroundStyle(.secondary) }
                if let e = libraryErrors[r.id] { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            if busy == r.id {
                ProgressView().controlSize(.small)
            } else if !r.runs {
                Text(r.needsMeum.map { "needs meum \($0)" } ?? "not for this Mac").font(.caption).foregroundStyle(.secondary)
            } else if r.installed {
                if r.update {
                    UpdateDot()
                    Button("Update") { install(r, update: true) }
                }
                Button("Remove") { remove(r) }
            } else {
                Button("Install") { install(r, update: false) }
            }
        }
        .disabled(busy != nil && busy != r.id)
    }

    private func loadLibrary() {
        guard let installer = widgets?.installer else { libraryState = "no library"; return }
        busy = ""
        libraryState = "loading…"
        Task { @MainActor in
            defer { busy = nil }
            do {
                let r = try await installer.catalogJSON()
                updates.setCatalog(r)
                show(r)
                libraryState = library.isEmpty ? "The library is empty." : "From \(installer.catalogURL ?? "the catalog")"
            } catch {
                libraryState = "Library unavailable: \(error)"
            }
        }
    }

    private func show(_ r: JSON) {
        library = (r["widgets"]?.arrayValue ?? []).map { w in
            LibraryRow(id: w["id"]?.stringValue ?? "", name: w["displayName"]?.stringValue ?? "",
                       description: w["description"]?.stringValue ?? "", version: w["version"]?.stringValue ?? "",
                       installed: w["installed"]?.boolValue ?? false, update: w["update"]?.boolValue ?? false,
                       runs: w["runs"]?.boolValue ?? true, needsMeum: w["needsMeum"]?.stringValue)
        }
    }

    private func install(_ r: LibraryRow, update: Bool) {
        guard let installer = widgets?.installer else { return }
        busy = r.id
        Task { @MainActor in
            do { _ = try await installer.install(r.id, updateOnly: update); libraryErrors[r.id] = nil }
            catch { libraryErrors[r.id] = "\(error)" }
            busy = nil
            refresh()
            loadLibrary()
        }
    }

    private func remove(_ r: LibraryRow) {
        do { _ = try widgets?.installer?.remove(r.id, data: false); libraryErrors[r.id] = nil }
        catch { libraryErrors[r.id] = "\(error)" }
        refresh()
        loadLibrary()
    }

    private func allow(_ r: Row) {
        do { _ = try widgets?.installer?.allow(r.id); error = nil } catch { self.error = "\(error)" }
        refresh()
    }

    private func move(_ r: Row, by d: Int) {
        var ids = rows.map(\.id)
        guard let i = ids.firstIndex(of: r.id) else { return }
        // swap with the neighbour in the same group
        var j = i + d
        while j >= 0, j < rows.count, rows[j].scope != r.scope { j += d }
        guard j >= 0, j < rows.count else { return }
        ids.swapAt(i, j)
        set("widgetOrder", .array(ids.map { .string($0) }))
        refresh()
    }

    private func enable(_ r: Row, _ on: Bool) {
        do { try widgets?.setEnabled(r.id, on); error = nil } catch { self.error = "\(error)" }
        refresh()
    }
}
