import Combine
import Foundation
import MeumControl
import MeumCore

/// MeumCore's `Settings`, for files that also import SwiftUI (which has its own `Settings` scene).
typealias MSettings = Settings

/// The live settings. Every write, from the API or the settings window, goes through `set(_:_:)`: validated by
/// `SettingsJSON`, saved to `settings.json` (debounced), applied by `onChange`, published as
/// `settings.changed` events by AppControl.
@MainActor
final class AppSettings: ObservableObject {
    @Published private(set) var value: Settings
    let store: SettingsStore
    /// Called after every effective change with the old and new settings and the changed API keys.
    var onChange: ((_ old: Settings, _ new: Settings, _ keys: [String]) -> Void)?
    private var saveWork: DispatchWorkItem?

    init(store: SettingsStore) {
        self.store = store
        do {
            value = try store.load()
        } catch {
            Log.error("settings.json unreadable (\(error)); using defaults")
            value = Settings()
        }
    }

    /// Sets one key from a JSON value. Returns the stored (normalised) value.
    @discardableResult
    func set(_ key: String, _ json: JSON) throws -> JSON {
        var next = value
        try SettingsJSON.set(&next, key: key, value: json)
        commit(next)
        return SettingsJSON.value(value, key) ?? .null
    }

    private func commit(_ next: Settings) {
        guard next != value else { return }
        let old = value
        value = next
        let keys = SettingsJSON.keys.filter { SettingsJSON.value(old, $0) != SettingsJSON.value(next, $0) }
        saveSoon()
        onChange?(old, next, keys)
    }

    func saveSoon() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do { try store.save(value) } catch { Log.error("saving settings failed: \(error)") }
    }
}
