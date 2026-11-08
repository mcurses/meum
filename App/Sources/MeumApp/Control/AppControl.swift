import AppKit
import MeumControl
import MeumCore
import UserNotifications

/// The integration of the control channel into the app:
/// - starts the `ControlServer` on `<state dir>/meum.sock` with `AppAPI` as its handler;
/// - turns every model change into bus events (`ModelJSON.diff`), whoever caused it;
/// - feeds the agent dots from `AgentService` and keeps its focused tab in step with the UI;
/// - stores the agent snapshot on the tab for reboot resume;
/// - keeps the git branch of each workspace's focused tab cwd.
@MainActor
final class AppControl {
    /// A tab's role chips (its session's labels) going away, with why: chips that vanish should leave a trace.
    static func logChipDrop(_ tab: UUID, _ session: String, _ labels: [String], _ cause: String) {
        guard !labels.isEmpty else { return }
        Log.info("chips dropped: tab \(tab.uuidString.prefix(8)) session \(session.prefix(8)) [\(labels.joined(separator: ", "))]: \(cause)")
    }

    let bus = EventBus()
    let agents: AgentService
    let agentSource: LiveAgentStateSource
    let controller: WorkspaceController
    private(set) var server: ControlServer?
    /// The live settings (`settings.get` / `settings.set`); set by the app delegate.
    var settings: AppSettings?
    /// Opens Settings at a section ("widgets"): where a refused trust request sends the user.
    var onOpenSettings: ((String) -> Void)?
    /// The native widget host (`widget.list` / `widget.reload`); set by the app delegate, before its first reload.
    var widgets: WidgetManager? {
        didSet {
            installer.widgets = widgets
            widgets?.installer = installer
            installer.stopHelper = { [weak widgets] id in widgets?.stopHelper(id: id) }
            if let widgets { installer.pinExistingOnFirstRun(widgets.scan()) }
        }
    }
    /// The widget library: catalog, install, update, remove, and the trust check before a widget loads.
    weak var updater: Updater?
    lazy var installer = WidgetInstaller(paths: controller.paths) { [weak self] in self?.settings?.value ?? Settings() }
    private var appActive = NSApp.isActive
    private var focusedTab: UUID?
    private var branchTimer: Timer?
    private var portTimer: Timer?
    private var portScanRunning = false
    private var silentTimer: Timer?
    private var silentScanRunning = false
    /// Tabs seen running claude with no hook state on the previous scan (a mark needs two scans in a row, so a
    /// session that just started has time for its SessionStart hook).
    private var silentCandidates: Set<UUID> = []
    private var branchWork: DispatchWorkItem?
    private let notifier: Notifier

    init(controller: WorkspaceController) {
        self.controller = controller
        agents = AgentService(bus: bus)
        agentSource = LiveAgentStateSource(service: agents)
        notifier = Notifier()
        notifier.onOpen = { [weak controller] tab in
            NSApp.activate(ignoringOtherApps: true)
            controller?.selectTab(tab)
        }
    }

    /// Call before `controller.start()` so the first model events are published too.
    func attach() {
        controller.store.didMutate = { [weak self] old, new in self?.modelChanged(old: old, new: new) }
        controller.agents = agentSource
        controller.setSetting = { [weak self] key, value in
            do { try self?.settings?.set(key, value) } catch { Log.error("setting \(key): \(error)") }
        }
        agentSource.onChange = { [weak controller] in controller?.refreshChrome() }
        controller.onStatusClicked = { [weak self] ws, key, entry in
            self?.bus.publish("status.clicked", ["workspace": .string(ws.uuidString), "key": .string(key),
                                                 "value": .string(entry.value), "url": entry.url.map { .string($0) } ?? .null])
        }
    }

    func start(socket: URL) {
        let api = AppAPI(control: self)
        let s = ControlServer(socketPath: socket.path, handler: ControlBridge(api: api), bus: bus,
                              log: { Log.info("control: \($0)") })
        do {
            try s.start()
            server = s
        } catch {
            Log.error("control server did not start on \(socket.path): \(error)")
        }
        updateFocus()
        refreshBranches()
        branchTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshBranches() }
        }
        refreshPorts()
        restoreAgents()
        portTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPorts() }
        }
        silentTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSilentAgents() }
        }
    }

    func stop() {
        branchTimer?.invalidate()
        portTimer?.invalidate()
        silentTimer?.invalidate()
        server?.stop()
    }

    func setAppActive(_ active: Bool) {
        appActive = active
        updateFocus(force: true)
    }

    // MARK: model -> events

    private func modelChanged(old: AppState, new: AppState) {
        for (type, data) in ModelJSON.diff(old: old, new: new) {
            bus.publish(type, data)
            if type == "tab.removed", let id = data["id"]?.stringValue { agents.forget(tab: id) }
            if type == "workspace.removed", let id = data["id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
                controller.workspaceExtras[id] = nil
            }
        }
        updateFocus()
        scheduleBranchRefresh()
    }

    /// The agent tracker's focused tab: the UI's focused tab while the app is active, none otherwise
    /// (a Stop in the visible tab while you are in another app still leaves it unread).
    private func updateFocus(force: Bool = false) {
        let tab = appActive ? ModelJSON.focusedTab(controller.store.state)?.tab : nil
        guard force || tab != focusedTab else { return }
        focusedTab = tab
        agents.setFocusedTab(tab?.uuidString)
    }

    // MARK: agent hooks -> snapshot

    /// Handles `agent.hook` and keeps `Tab.agent` (persisted in layout.json) in step with the session.
    func handleHook(_ params: JSON) throws -> JSON {
        guard let raw = params["tab"]?.stringValue, let tabID = UUID(uuidString: raw) else {
            throw ControlError.invalidParams("agent.hook needs 'tab' (a tab id)")
        }
        guard controller.store.state.workspace(containingTab: tabID) != nil else {
            return ["outcome": "unknown_tab"]
        }
        var p = params.objectValue ?? [:]
        p["tab"] = .string(tabID.uuidString)
        let result = try agents.handleHook(params: .object(p))
        let payload = params["payload"] ?? .null
        let event = payload["hook_event_name"]?.stringValue
        let current = controller.store.state.workspace(containingTab: tabID)?.tab(tabID)?.agent

        if event == "SessionEnd" {
            // An explicit exit (/exit, logout, /clear) ends the session for good. "other" covers `claude -p`
            // finishing but also a session killed by a signal (a reboot, a killed terminal): keep the snapshot,
            // so the tab can resume after a reboot.
            let reason = payload["reason"]?.stringValue ?? "other"
            let sid = payload["session_id"]?.stringValue
            if reason != "other", let current, sid == nil || sid == current.sessionID {
                if let l = current.labels { Self.logChipDrop(tabID, current.sessionID, l, "session ended (\(reason))") }
                controller.store.mutate(.cosmetic) { $0.updateTab(tabID) { $0.agent = nil } }
            } else if let current, current.labels != nil, sid == nil || sid == current.sessionID {
                // the snapshot stays for a resume, but an ended session shows no labels
                Self.logChipDrop(tabID, current.sessionID, current.labels ?? [], "session ended (other)")
                controller.store.mutate(.cosmetic) { $0.updateTab(tabID) { $0.agent?.labels = nil } }
            }
        } else if let st = agents.state(of: tabID.uuidString) {
            // the name is looked up off the main thread below; until then keep the one this session already had
            let same = current?.sessionID == st.sessionID
            let known = same ? current?.name : nil
            // labels belong to the session: a new session in the tab starts without
            let snap = AgentSnapshot(sessionID: st.sessionID, configDir: st.configDir,
                                     transcriptPath: st.transcriptPath, cwd: st.cwd, name: known,
                                     labels: same ? current?.labels : nil)
            if snap != current {
                if !same, let current, let l = current.labels {
                    Self.logChipDrop(tabID, current.sessionID, l, "another session (\(st.sessionID)) reported from the tab, \(event ?? "?")")
                }
                controller.store.mutate(.cosmetic) { $0.updateTab(tabID) { $0.agent = snap } }
            }
            refreshSessionName(tab: tabID, sessionID: st.sessionID, configDir: st.configDir)
        }
        return result
    }

    private let nameQueue = DispatchQueue(label: "meum.session-names", qos: .utility)

    /// Reads the session's name from Claude Code's record of it (it can change, e.g. on `/rename`) and stores it on
    /// the tab's snapshot if the tab still holds that session.
    private func refreshSessionName(tab: UUID, sessionID: String, configDir: String?) {
        nameQueue.async { [weak self] in
            let name = ClaudeSessionRecords.name(sessionID: sessionID, configDir: configDir)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self,
                          let cur = self.controller.store.state.workspace(containingTab: tab)?.tab(tab)?.agent,
                          cur.sessionID == sessionID, cur.name != name else { return }
                    self.controller.store.mutate(.cosmetic) { $0.updateTab(tab) { $0.agent?.name = name } }
                }
            }
        }
    }

    // MARK: notifications

    func notify(title: String, body: String?, tab: UUID?) -> JSON {
        notifier.post(title: title, body: body, tab: tab)
        bus.publish("notification", ["title": .string(title), "body": body.map { .string($0) } ?? .null,
                                     "tab": tab.map { .string($0.uuidString) } ?? .null])
        return ["posted": true, "authorization": .string(notifier.authorization)]
    }

    // MARK: git branch

    private func scheduleBranchRefresh() {
        branchWork?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.refreshBranches() } }
        branchWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    /// Reads `.git/HEAD` for each workspace's focused tab cwd off the main thread (file reads only, no git).
    func refreshBranches() {
        let dirs: [(UUID, String?)] = controller.store.state.workspaces.map { ws in
            (ws.id, ModelJSON.focusedTab(ws)?.cwd ?? ws.cwd)
        }
        // remotes: the workspace's directory first, then its tabs' directories
        let remoteDirs: [(UUID, [String])] = controller.store.state.workspaces.map { ws in
            (ws.id, (ws.cwd.map { [$0] } ?? []) + ModelJSON.cwds(ws))
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = dirs.map { id, dir in (id, dir.flatMap { GitHead.branch(at: $0) }) }
            let remotes = remoteDirs.map { id, dirs -> (UUID, [String]) in
                var seen: Set<String> = []
                return (id, dirs.compactMap { GitRemote.origin(at: $0) }.filter { seen.insert($0).inserted })
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applyBranches(found)
                    self?.applyRemotes(remotes)
                }
            }
        }
    }

    /// Listening TCP ports of each workspace's tab processes (their zmx sessions' process trees), off the main thread.
    /// After a restart the tracker knows no session until its next hook. A tab with a Claude snapshot whose zmx
    /// session still runs a `claude` process gets its dot back at once (idle, read); the next hook corrects it.
    func restoreAgents() {
        let sessions = controller.sessions
        let candidates: [(UUID, String, AgentSnapshot)] = controller.store.state.workspaces.flatMap { ws in
            ws.allTabs.compactMap { t in t.agent.map { (t.id, sessions.name(for: t.id), $0) } }
        }
        guard !candidates.isEmpty else { return }
        let service = agents
        DispatchQueue.global(qos: .utility).async {
            let pids = sessions.pids()
            let parents = ListeningPorts.parents()
            let now = Date().timeIntervalSince1970
            var restored: [String: AgentState] = [:]
            for (tab, name, snap) in candidates {
                guard let root = pids[name],
                      ListeningPorts.tree(of: root, parents: parents).contains(where: { ListeningPorts.name(of: $0) == "claude" })
                else { continue }
                restored[tab.uuidString] = AgentState(sessionID: snap.sessionID, configDir: snap.configDir,
                                                      transcriptPath: snap.transcriptPath, cwd: snap.cwd,
                                                      phase: .idle, unread: false, updatedAt: now)
            }
            Log.info("agents: restored \(restored.count) of \(candidates.count) Claude session(s) after launch")
            service.restore(restored)
        }
    }

    /// Marks tabs where claude runs but meum has heard no hook from it (hooks not installed in that profile, the
    /// script missing, or a claude started before the hooks were): the tab shows a hollow dot that says so.
    func refreshSilentAgents() {
        guard !silentScanRunning else { return }
        silentScanRunning = true
        let sessions = controller.sessions
        let tabs: [(UUID, String)] = controller.store.state.workspaces.flatMap { ws in
            ws.allTabs.map { ($0.id, sessions.name(for: $0.id)) }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pids = sessions.pids()
            let parents = ListeningPorts.parents()
            let running = Set(tabs.compactMap { tab, name -> UUID? in
                guard let root = pids[name] else { return nil }
                return ListeningPorts.tree(of: root, parents: parents).contains { ListeningPorts.name(of: $0) == "claude" } ? tab : nil
            })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.silentScanRunning = false
                    let unheard = Set(running.filter { self.agents.state(of: $0.uuidString) == nil })
                    let silent = unheard.intersection(self.silentCandidates)
                    self.silentCandidates = unheard
                    if silent != self.controller.silentAgentTabs { self.controller.silentAgentTabs = silent }
                }
            }
        }
    }

    func refreshPorts() {
        guard !portScanRunning else { return }
        portScanRunning = true
        let sessions = controller.sessions
        let tabsByWorkspace: [(UUID, [String])] = controller.store.state.workspaces.map { ws in
            (ws.id, ws.allTabs.map { sessions.name(for: $0.id) })
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pids = sessions.pids()
            var owner: [pid_t: UUID] = [:]
            for (ws, names) in tabsByWorkspace {
                for n in names { if let p = pids[n] { owner[p] = ws } }
            }
            let byPid = ListeningPorts.byRoot(Dictionary(uniqueKeysWithValues: owner.keys.map { ($0, $0) }))
            var found: [UUID: [Int]] = [:]
            for (pid, ports) in byPid { if let ws = owner[pid] { found[ws] = Array(Set((found[ws] ?? []) + ports)).sorted() } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.portScanRunning = false
                    self?.applyPorts(found)
                }
            }
        }
    }

    private func applyPorts(_ found: [UUID: [Int]]) {
        var extras = controller.workspaceExtras
        for ws in controller.store.state.workspaces {
            let ports = found[ws.id] ?? []
            guard (extras[ws.id]?.ports ?? []) != ports else { continue }
            var e = extras[ws.id] ?? WorkspaceExtras()
            e.ports = ports
            extras[ws.id] = e
            bus.publish("workspace.changed", ["id": .string(ws.id.uuidString), "fields": ["ports"],
                                              "ports": .array(ports.map { .int($0) })])
        }
        controller.workspaceExtras = extras
    }

    private func applyRemotes(_ found: [(UUID, [String])]) {
        var extras = controller.workspaceExtras
        for (id, remotes) in found where controller.store.state.workspace(id) != nil {
            guard (extras[id]?.remotes ?? []) != remotes else { continue }
            var e = extras[id] ?? WorkspaceExtras()
            e.remotes = remotes
            extras[id] = e
            bus.publish("workspace.changed", ["id": .string(id.uuidString), "fields": ["remotes"],
                                              "remotes": .array(remotes.map { .string($0) })])
        }
        controller.workspaceExtras = extras
    }

    private func applyBranches(_ found: [(UUID, String?)]) {
        var extras = controller.workspaceExtras
        for (id, branch) in found where controller.store.state.workspace(id) != nil {
            guard extras[id]?.branch != branch else { continue }
            var e = extras[id] ?? WorkspaceExtras()
            e.branch = branch
            extras[id] = e
            bus.publish("workspace.changed", ["id": .string(id.uuidString), "fields": ["branch"],
                                              "branch": branch.map { .string($0) } ?? .null])
        }
        controller.workspaceExtras = extras
    }
}

/// `ControlHandler` for the server: hops every call onto the main actor, where the model lives.
struct ControlBridge: ControlHandler {
    let api: AppAPI
    func handle(method: String, params: JSON) async throws -> JSON {
        switch method {
        case MeumMethod.widgetSend, MeumMethod.widgetScreenshot:
            return try await api.handleAsync(method: method, params: params)   // the widget answers later
        case MeumMethod.updateCheck, MeumMethod.updateInstall:
            return try await api.handleUpdate(method: method, params: params)
        case _ where MeumMethod.widgetAsync.contains(method):
            return try await api.handleLibrary(method: method, params: params)   // waits for the network
        default:
            return try await MainActor.run { try api.handle(method: method, params: params) }
        }
    }
}

/// Feeds the sidebar and tab strip dots from MeumControl's AgentService.
@MainActor
final class LiveAgentStateSource: AgentStateSource {
    let service: AgentService
    var onChange: (() -> Void)?
    private var observer: EventBus.Subscription?
    private var pending = false

    init(service: AgentService) {
        self.service = service
        observer = service.bus.addObserver(filter: EventFilter(patterns: ["agent.changed"])) { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.changed() } }
        }
    }

    private func changed() { onChange?() }

    func state(forTab tab: UUID) -> TabAgentState? {
        guard let s = service.state(of: tab.uuidString) else { return nil }
        let phase: TabAgentState.Phase
        switch s.phase {
        case .running: phase = .running
        case .idle: phase = .idle
        case .needsInput: phase = .needsInput
        }
        return TabAgentState(phase: phase, unread: s.unread)
    }

    func summary(forWorkspace ws: Workspace) -> WorkspaceAgentSummary {
        let s = service.summary(tabs: ws.allTabs.map(\.id.uuidString))
        return WorkspaceAgentSummary(liveSessions: s.live, anyUnread: s.anyUnread, anyNeedsInput: s.anyNeedsInput,
                                     needsInput: s.needsInput, unread: s.unread, running: s.running)
    }
}

/// Resumes a Claude Code session in a tab whose zmx session is gone (after a reboot).
final class ClaudeResumeProvider: ResumeProvider {
    func resumeCommand(for snapshot: AgentSnapshot, tab: Tab) -> String? {
        ResumeCommand.build(ResumeInfo(sessionID: snapshot.sessionID, configDir: snapshot.configDir,
                                       cwd: snapshot.cwd ?? tab.cwd))
    }
}

/// macOS notifications for `notify`, tied to a tab: clicking one shows that tab.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onOpen: (@MainActor (UUID) -> Void)?
    private(set) var authorization = "unknown"
    private var requested = false

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter needs a bundle (crashes for a bare binary)
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
        center?.getNotificationSettings { [weak self] s in self?.authorization = Self.name(s.authorizationStatus) }
    }

    static func name(_ s: UNAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    func post(title: String, body: String?, tab: UUID?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        content.sound = .default
        if let tab { content.userInfo = ["tab": tab.uuidString]; content.threadIdentifier = tab.uuidString }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let send = { center.add(req) { err in if let err { Log.error("notification failed: \(err)") } } }
        if requested { send(); return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] ok, err in
            if let err { Log.error("notification authorization: \(err)") }
            self?.authorization = ok ? "authorized" : "denied"
            if ok { send() }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let tab = (response.notification.request.content.userInfo["tab"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { if let tab { self?.onOpen?(tab) } }
        }
        completionHandler()
    }
}
