// What can be updated: widgets from the library and meum itself. Checked in the background (shortly after launch,
// then every few hours) so the menu's "Settings…" and the settings window can show it without a manual refresh.
import Foundation
import MeumControl
import MeumCore

@MainActor
final class UpdateCenter: ObservableObject {
    /// Display names of installed widgets the library has a newer version of.
    @Published private(set) var widgetUpdates: [String] = []
    /// meum's newer release version, if the updater found one.
    @Published private(set) var appUpdate: String?
    /// The last catalog answer (`WidgetInstaller.catalogJSON`), for the settings window to show at once.
    @Published private(set) var catalog: JSON?
    /// Called whenever the number of updates changes (the menu's badge).
    var onChange: ((Int) -> Void)?

    private let installer: () -> WidgetInstaller?
    private var timer: Timer?
    static let interval: TimeInterval = 4 * 3600

    init(installer: @escaping () -> WidgetInstaller?) { self.installer = installer }

    var count: Int { widgetUpdates.count + (appUpdate == nil ? 0 : 1) }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in Task { try? await self?.checkWidgets() } }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { Task { try? await self?.checkWidgets() } }
        }
    }

    /// Fetches the catalog and records which installed widgets have an update. Returns the catalog answer.
    @discardableResult
    func checkWidgets() async throws -> JSON {
        guard let installer = installer() else { throw ControlError.unavailable("no widget library") }
        let r = try await installer.catalogJSON()
        setCatalog(r)
        return r
    }

    func setCatalog(_ r: JSON) {
        catalog = r
        let names = (r["widgets"]?.arrayValue ?? []).filter {
            $0["update"]?.boolValue == true && $0["runs"]?.boolValue != false
        }.compactMap { $0["displayName"]?.stringValue }
        if names != widgetUpdates { widgetUpdates = names; onChange?(count) }
    }

    func setAppUpdate(_ version: String?) {
        guard version != appUpdate else { return }
        appUpdate = version
        onChange?(count)
    }
}
