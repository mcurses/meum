import Foundation
import MeumCore

/// Owns the live `AppState`, persists it, and tells the UI about changes.
///
/// Structural mutations (anything that changes workspaces, cards, tabs or selection) save at once; volatile
/// ones (a title or cwd reported by the terminal) save debounced, and on quit.
@MainActor
final class WorkspaceStore {
    enum Change {
        /// The tree, selection or focus changed: re-layout (animated if `animate`).
        case structure(animate: Bool)
        /// Only names, colours, titles or cwds changed: redraw chrome.
        case cosmetic
    }

    private(set) var state: AppState
    let persistence: LayoutStore
    var onChange: ((Change) -> Void)?
    /// Called after every effective mutation with the state before and after, whoever caused it (UI, keys, API).
    /// The control channel turns it into bus events.
    var didMutate: ((_ old: AppState, _ new: AppState) -> Void)?
    private var saveWork: DispatchWorkItem?

    init(persistence: LayoutStore) {
        self.persistence = persistence
        do {
            state = try persistence.load() ?? AppState()
        } catch {
            Log.error("layout.json unreadable (\(error)); moved aside as \(persistence.quarantine()?.path ?? "?")")
            state = AppState()
        }
        state.normalize()
    }

    func mutate(_ change: Change = .structure(animate: true), save: Bool = true, _ f: (inout AppState) -> Void) {
        let before = state
        f(&state)
        guard state != before else { return }
        if save {
            saveNow()
        } else {
            saveSoon()
        }
        didMutate?(before, state)
        onChange?(change)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        do { try persistence.save(state) } catch { Log.error("saving layout failed: \(error)") }
    }

    func saveSoon(after seconds: TimeInterval = 2) {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - Agent state seam

/// Per-tab agent state as the sidebar and tab strips show it. The integration step feeds this from
/// MeumControl's AgentTracker (`LiveAgentStateSource`).
struct TabAgentState: Equatable {
    enum Phase: String { case running, idle, needsInput }
    var phase: Phase
    var unread: Bool
}

struct WorkspaceAgentSummary: Equatable {
    var liveSessions: Int = 0
    var anyUnread = false
    var anyNeedsInput = false
    /// Of `liveSessions`: waiting on the user, and finished-but-unread (not waiting).
    var needsInput = 0
    var unread = 0
    /// Of `liveSessions`: working right now.
    var running = 0
}

@MainActor
protocol AgentStateSource: AnyObject {
    func state(forTab tab: UUID) -> TabAgentState?
    func summary(forWorkspace ws: Workspace) -> WorkspaceAgentSummary
    /// Called by the source whenever anything it reports changes.
    var onChange: (() -> Void)? { get set }
}
