// AgentService: thread-safe wrapper that joins the AgentTracker and the EventBus.
// The app's ControlHandler forwards `agent.hook` here and reads `states` for the `tree` response.
import Foundation

public final class AgentService: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker: AgentTracker
    public let bus: EventBus
    private let now: @Sendable () -> Date

    public init(bus: EventBus, tracker: AgentTracker = AgentTracker(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.bus = bus
        self.tracker = tracker
        self.now = now
    }

    /// Handles `agent.hook {tab, configDir?, payload}`. Publishes `agent.hook` (raw, unless a duplicate)
    /// and `agent.changed` (`{tab, agent: AgentState|null}`) events. Returns `{"outcome": "..."}`.
    public func handleHook(params: JSON) throws -> JSON {
        guard let tab = params["tab"]?.stringValue, !tab.isEmpty else {
            throw ControlError.invalidParams("agent.hook needs 'tab'")
        }
        guard let payload = params["payload"], payload.objectValue != nil else {
            throw ControlError.invalidParams("agent.hook needs an object 'payload'")
        }
        let configDir = (params["configDir"] ?? params["config_dir"])?.stringValue

        lock.lock()
        let outcome = tracker.apply(tab: tab, configDir: configDir, payload: payload, at: now())
        lock.unlock()

        let name: String
        switch outcome {
        case .ignored: name = "ignored"
        case .duplicate: name = "duplicate"
        case .unchanged: name = "unchanged"
        case .changed: name = "changed"
        case .removed: name = "removed"
        }
        if outcome != .duplicate {
            bus.publish("agent.hook", ["tab": .string(tab), "configDir": configDir.map { .string($0) } ?? .null, "payload": payload])
        }
        publish(outcome, tab: tab)
        return ["outcome": .string(name)]
    }

    private func publish(_ outcome: AgentOutcome, tab: String) {
        switch outcome {
        case .changed(_, let new): bus.publish("agent.changed", ["tab": .string(tab), "agent": new.json])
        case .removed: bus.publish("agent.changed", ["tab": .string(tab), "agent": .null])
        default: break
        }
    }

    /// Call when keyboard focus moves to a tab (clears its unread flag).
    public func setFocusedTab(_ tab: String?) {
        lock.lock()
        let changed = tracker.setFocusedTab(tab, at: now())
        lock.unlock()
        if let changed, let tab { bus.publish("agent.changed", ["tab": .string(tab), "agent": changed.json]) }
    }

    public func markRead(tabs: [String]) {
        lock.lock()
        let changed = tabs.compactMap { t in tracker.markRead(tab: t, at: now()).map { (t, $0) } }
        lock.unlock()
        for (t, s) in changed { bus.publish("agent.changed", ["tab": .string(t), "agent": s.json]) }
    }

    public func markUnread(tabs: [String]) {
        lock.lock()
        let changed = tabs.compactMap { t in tracker.markUnread(tab: t, at: now()).map { (t, $0) } }
        lock.unlock()
        for (t, s) in changed { bus.publish("agent.changed", ["tab": .string(t), "agent": s.json]) }
    }

    /// Call when a tab is closed.
    public func forget(tab: String) {
        lock.lock()
        let old = tracker.forget(tab: tab)
        lock.unlock()
        if old != nil { bus.publish("agent.changed", ["tab": .string(tab), "agent": .null]) }
    }

    public func state(of tab: String) -> AgentState? {
        lock.lock(); defer { lock.unlock() }
        return tracker.state(of: tab)
    }

    public func summary(tabs: [String]) -> WorkspaceSummary {
        lock.lock(); defer { lock.unlock() }
        return tracker.summary(tabs: tabs)
    }

    /// `{ "<tabID>": AgentState }` for the `tree` response.
    public var statesJSON: JSON {
        lock.lock(); defer { lock.unlock() }
        return .object(tracker.agents.mapValues(\.json))
    }
}
