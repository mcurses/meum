// AgentTracker: pure state machine from Claude Code hook events to per-tab agent state.
// No I/O, no clock of its own (callers pass `at:`), value type: wrap it in a lock or an actor to share it.
import Foundation

public enum AgentPhase: String, Codable, Equatable, Sendable {
    case running
    case idle
    case needsInput
}

public struct AgentState: Codable, Equatable, Sendable {
    public var sessionID: String
    /// Always the effective config dir (derived from the transcript path when the hook env had none).
    public var configDir: String?
    public var transcriptPath: String?
    public var cwd: String?
    public var phase: AgentPhase
    public var unread: Bool
    /// Seconds since 1970 of the last event applied (including duplicates-free refreshes).
    public var updatedAt: TimeInterval

    public init(sessionID: String, configDir: String? = nil, transcriptPath: String? = nil, cwd: String? = nil,
                phase: AgentPhase = .idle, unread: Bool = false, updatedAt: TimeInterval = 0) {
        self.sessionID = sessionID
        self.configDir = configDir
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.phase = phase
        self.unread = unread
        self.updatedAt = updatedAt
    }

    /// Equality ignoring `updatedAt`: what "changed" means for events.
    func sameContent(as o: AgentState) -> Bool {
        var a = self, b = o
        a.updatedAt = 0; b.updatedAt = 0
        return a == b
    }

    public var json: JSON { (try? JSON.from(self)) ?? .null }
}

public struct WorkspaceSummary: Codable, Equatable, Sendable {
    /// Tabs with a live agent session.
    public var live: Int
    public var running: Int
    public var anyUnread: Bool
    public var anyNeedsInput: Bool
    /// Sessions waiting on the user (permission prompt or question).
    public var needsInput: Int
    /// Sessions with an unread finished turn that are not waiting on the user.
    public var unread: Int

    public init(live: Int = 0, running: Int = 0, anyUnread: Bool = false, anyNeedsInput: Bool = false,
                needsInput: Int = 0, unread: Int = 0) {
        self.live = live
        self.running = running
        self.anyUnread = anyUnread
        self.anyNeedsInput = anyNeedsInput
        self.needsInput = needsInput
        self.unread = unread
    }

    public var json: JSON { (try? JSON.from(self)) ?? .null }
}

public enum AgentOutcome: Equatable, Sendable {
    /// Not an event we track (unknown hook name, irrelevant notification type, malformed payload).
    case ignored
    /// Same event seen again within the dedupe window (e.g. a settings.json shared between config dirs).
    case duplicate
    /// Recognised, state content unchanged (only the timestamp moved).
    case unchanged
    case changed(old: AgentState?, new: AgentState)
    case removed(old: AgentState)
}

public struct AgentTracker: Equatable, Sendable {
    /// Notifications meaning "Claude is blocked on you": a permission prompt or a question. Not `idle_prompt`: Claude
    /// Code sends that 60 s after any finished turn, so it would turn every read, finished session into "needs input"
    /// (`Stop` already marks a finished turn unread).
    public static let notificationTypesNeedingInput: Set<String> = ["permission_prompt", "elicitation_dialog"]

    public private(set) var agents: [String: AgentState] = [:]
    public private(set) var focusedTab: String?
    public var dedupeWindow: TimeInterval

    private struct Seen: Equatable, Sendable { var tab: String; var payload: JSON; var at: TimeInterval }
    private var recent: [Seen] = []

    public init(dedupeWindow: TimeInterval = 5) { self.dedupeWindow = dedupeWindow }

    public func state(of tab: String) -> AgentState? { agents[tab] }

    // MARK: hooks

    /// Applies one hook event for a tab. `configDir` is `$CLAUDE_CONFIG_DIR` from the hook environment
    /// (nil or "" for the default `~/.claude`). `payload` is the hook JSON from stdin.
    @discardableResult
    public mutating func apply(tab: String, configDir: String?, payload: JSON, at now: Date) -> AgentOutcome {
        let t = now.timeIntervalSince1970
        guard case .object = payload, let event = payload["hook_event_name"]?.stringValue else { return .ignored }

        recent.removeAll { t - $0.at > dedupeWindow || t < $0.at }
        if recent.contains(where: { $0.tab == tab && $0.payload == payload }) { return .duplicate }
        recent.append(Seen(tab: tab, payload: payload, at: t))
        if recent.count > 64 { recent.removeFirst(recent.count - 64) }

        let sid = payload["session_id"]?.stringValue
        let old = agents[tab]

        switch event {
        case "SessionStart":
            guard let sid, !sid.isEmpty else { return .ignored }
            // Overwrite: resume keeps the id, fork/clear give a new one.
            var s = AgentState(sessionID: sid, phase: .idle, unread: false, updatedAt: t)
            fill(&s, payload: payload, envConfigDir: configDir)
            return commit(tab, old: old, new: s)

        case "UserPromptSubmit", "Stop":
            guard let sid, !sid.isEmpty else { return .ignored }
            var s = upsert(old, sid: sid, payload: payload, envConfigDir: configDir, at: t)
            if event == "UserPromptSubmit" {
                s.phase = .running
                s.unread = false
            } else {
                s.phase = .idle
                s.unread = (tab != focusedTab)
            }
            return commit(tab, old: old, new: s)

        case "Notification":
            guard let kind = payload["notification_type"]?.stringValue,
                  Self.notificationTypesNeedingInput.contains(kind),
                  let sid, !sid.isEmpty else { return .ignored }
            var s = upsert(old, sid: sid, payload: payload, envConfigDir: configDir, at: t)
            s.phase = .needsInput
            s.unread = true
            return commit(tab, old: old, new: s)

        case "SessionEnd":
            guard let old else { return .ignored }
            // An old session ending after its replacement started (/clear ordering) must not drop the new one.
            if let sid, !sid.isEmpty, sid != old.sessionID { return .ignored }
            agents[tab] = nil
            return .removed(old: old)

        default:
            return .ignored
        }
    }

    private func upsert(_ old: AgentState?, sid: String, payload: JSON, envConfigDir: String?, at t: TimeInterval) -> AgentState {
        var s = old ?? AgentState(sessionID: sid)
        if old?.sessionID != sid { s = AgentState(sessionID: sid); s.configDir = old?.configDir }
        s.updatedAt = t
        fill(&s, payload: payload, envConfigDir: envConfigDir)
        return s
    }

    private func fill(_ s: inout AgentState, payload: JSON, envConfigDir: String?) {
        if let p = payload["transcript_path"]?.stringValue, !p.isEmpty { s.transcriptPath = p }
        if let c = payload["cwd"]?.stringValue, !c.isEmpty { s.cwd = c }
        if let e = envConfigDir, !e.isEmpty {
            s.configDir = e
        } else if let p = s.transcriptPath, let d = Self.configDir(fromTranscript: p) {
            s.configDir = d
        }
    }

    private mutating func commit(_ tab: String, old: AgentState?, new: AgentState) -> AgentOutcome {
        agents[tab] = new
        if let old, old.sameContent(as: new) { return .unchanged }
        return .changed(old: old, new: new)
    }

    /// `<dir>/projects/<slug>/<session>.jsonl` -> `<dir>`.
    public static func configDir(fromTranscript path: String) -> String? {
        guard let r = path.range(of: "/projects/", options: .backwards) else { return nil }
        let d = String(path[path.startIndex..<r.lowerBound])
        return d.isEmpty ? nil : d
    }

    // MARK: focus and read state

    /// Records which tab has keyboard focus (nil: none). Focusing a tab marks its agent read.
    /// Returns the new state when that cleared an unread flag.
    @discardableResult
    public mutating func setFocusedTab(_ tab: String?, at now: Date = Date()) -> AgentState? {
        focusedTab = tab
        guard let tab else { return nil }
        return markRead(tab: tab, at: now)
    }

    @discardableResult
    public mutating func markRead(tab: String, at now: Date = Date()) -> AgentState? {
        guard var s = agents[tab], s.unread else { return nil }
        s.unread = false
        s.updatedAt = now.timeIntervalSince1970
        agents[tab] = s
        return s
    }

    /// Marks every listed tab read (a workspace passes its tab ids). Returns the tabs that changed.
    @discardableResult
    public mutating func markRead(tabs: [String], at now: Date = Date()) -> [String] {
        tabs.filter { markRead(tab: $0, at: now) != nil }
    }

    @discardableResult
    public mutating func markUnread(tab: String, at now: Date = Date()) -> AgentState? {
        guard var s = agents[tab], !s.unread else { return nil }
        s.unread = true
        s.updatedAt = now.timeIntervalSince1970
        agents[tab] = s
        return s
    }

    /// Drops a tab's agent (the tab was closed).
    @discardableResult
    public mutating func forget(tab: String) -> AgentState? {
        if focusedTab == tab { focusedTab = nil }
        return agents.removeValue(forKey: tab)
    }

    // MARK: summaries

    public func summary(tabs: [String]) -> WorkspaceSummary {
        var s = WorkspaceSummary()
        for t in tabs {
            guard let a = agents[t] else { continue }
            s.live += 1
            if a.phase == .running { s.running += 1 }
            if a.unread { s.anyUnread = true }
            if a.phase == .needsInput { s.anyNeedsInput = true; s.needsInput += 1 } else if a.unread { s.unread += 1 }
        }
        return s
    }
}
