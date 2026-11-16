// AgentService: thread-safe wrapper that joins the AgentTracker and the EventBus.
// The app's ControlHandler forwards `agent.hook` here and reads `states` for the `tree` response.
import Foundation

public final class AgentService: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker: AgentTracker
    public let bus: EventBus
    private let now: @Sendable () -> Date
    /// Whether a hook that ran on terminal `tty` may speak for `tab` (HookOrigin). nil takes every hook.
    public var originCheck: (@Sendable (_ tab: String, _ tty: String) -> Bool)?
    /// Tabs whose Claude session meum resumed and that have sent no hook since: session id and when.
    private var starting: [String: (sessionID: String, since: Date)] = [:]

    public init(bus: EventBus, tracker: AgentTracker = AgentTracker(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.bus = bus
        self.tracker = tracker
        self.now = now
    }

    /// Handles `agent.hook {tab, tty?, configDir?, projectDir?, payload}`. Publishes `agent.hook` (raw, unless a duplicate)
    /// and `agent.changed` (`{tab, agent: AgentState|null}`) events. Returns `{"outcome": "..."}`.
    /// A hook that says which terminal it ran on (`tty`) and isn't the tab's own gets `foreign`: nothing is recorded
    /// or published (a session elsewhere that inherited the tab's MEUM_TAB).
    public func handleHook(params: JSON) throws -> JSON {
        guard let tab = params["tab"]?.stringValue, !tab.isEmpty else {
            throw ControlError.invalidParams("agent.hook needs 'tab'")
        }
        guard let payload = params["payload"], payload.objectValue != nil else {
            throw ControlError.invalidParams("agent.hook needs an object 'payload'")
        }
        let configDir = (params["configDir"] ?? params["config_dir"])?.stringValue
        if let tty = params["tty"]?.stringValue, let originCheck, !originCheck(tab, tty) {
            return ["outcome": "foreign"]
        }

        let projectDir = (params["projectDir"] ?? params["project_dir"])?.stringValue
        lock.lock()
        starting[tab] = nil
        let outcome = tracker.apply(tab: tab, configDir: configDir, projectDir: projectDir, payload: payload, at: now())
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

    /// Restores idle states for tabs whose Claude session survived a restart (tabs with a state are left alone).
    public func restore(_ states: [String: AgentState]) {
        lock.lock()
        let set = states.compactMap { t, s in tracker.restore(tab: t, state: s).map { (t, $0) } }
        lock.unlock()
        for (t, s) in set { bus.publish("agent.changed", ["tab": .string(t), "agent": s.json]) }
    }

    /// Call when meum starts `claude --resume` in a tab: until its first hook the tab counts as starting.
    public func resuming(tab: String, sessionID: String) {
        lock.lock()
        starting[tab] = (sessionID, now())
        lock.unlock()
    }

    /// Tabs still starting after `limit` seconds turn to "waiting for you" (a question before Claude Code's start,
    /// such as a confirmation, holds back every hook). Call periodically. Returns the tabs that changed.
    @discardableResult
    public func checkStarting(limit: TimeInterval = 20) -> [String] {
        lock.lock()
        let t = now()
        let due = starting.filter { t.timeIntervalSince($0.value.since) >= limit }
        var changed: [(String, AgentState)] = []
        for (tab, s) in due {
            starting[tab] = nil
            if let st = tracker.markWaiting(tab: tab, sessionID: s.sessionID, at: t) { changed.append((tab, st)) }
        }
        lock.unlock()
        for (tab, s) in changed { bus.publish("agent.changed", ["tab": .string(tab), "agent": s.json]) }
        return changed.map(\.0)
    }

    /// Call when a tab is closed.
    public func forget(tab: String) {
        lock.lock()
        starting[tab] = nil
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
