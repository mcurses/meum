// The meum model: value types only, Codable/Equatable/Sendable. See docs/design/architecture.md, "Model".

import Foundation

/// Snapshot of a Claude Code session running in a tab, kept for resuming it after a reboot.
public struct AgentSnapshot: Codable, Equatable, Sendable {
    public var sessionID: String
    public var configDir: String?
    public var transcriptPath: String?
    public var cwd: String?

    public init(sessionID: String, configDir: String? = nil, transcriptPath: String? = nil, cwd: String? = nil) {
        self.sessionID = sessionID
        self.configDir = configDir
        self.transcriptPath = transcriptPath
        self.cwd = cwd
    }
}

public struct Tab: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Last title the terminal reported (OSC 0/2), or a user-set one.
    public var title: String?
    /// Last known working directory (OSC 7), else the directory the tab was started in.
    public var cwd: String?
    /// A command the tab was started with instead of a plain shell (only used when its session is created).
    public var command: String?
    /// Set by the integration step from agent hooks; drives reboot resume.
    public var agent: AgentSnapshot?
    /// A widget tab: the id of the native widget shown instead of a terminal (no shell, no zmx session).
    public var widget: String?
    /// A widget tab's settings, JSON text the widget owns (MeumKit `configuration`).
    public var widgetConfig: String?

    public init(id: UUID = UUID(), title: String? = nil, cwd: String? = nil, command: String? = nil,
                agent: AgentSnapshot? = nil, widget: String? = nil, widgetConfig: String? = nil) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.command = command
        self.agent = agent
        self.widget = widget
        self.widgetConfig = widgetConfig
    }

    public var isWidget: Bool { widget != nil }
}

/// A tiled "window" with a tab strip. Never empty: closing its last tab removes the card.
public struct Card: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var tabs: [Tab]
    public var selectedTabID: UUID

    public init(id: UUID = UUID(), tabs: [Tab], selectedTabID: UUID? = nil) {
        precondition(!tabs.isEmpty, "a card has at least one tab")
        self.id = id
        self.tabs = tabs
        self.selectedTabID = selectedTabID ?? tabs[0].id
    }

    public init(id: UUID = UUID(), tab: Tab) { self.init(id: id, tabs: [tab]) }

    public var selectedTab: Tab { tabs.first { $0.id == selectedTabID } ?? tabs[0] }
    public var selectedIndex: Int { tabs.firstIndex { $0.id == selectedTabID } ?? 0 }
}

public enum SplitAxis: String, Codable, Sendable {
    /// Children side by side: `first` left, `second` right.
    case horizontal
    /// Children stacked: `first` on top, `second` below.
    case vertical
}

public struct Split: Codable, Equatable, Sendable, Identifiable {
    public static let minRatio = 0.1
    public static let maxRatio = 0.9

    public var id: UUID
    public var axis: SplitAxis
    /// Share of the first child, clamped to 0.1…0.9.
    public var ratio: Double {
        didSet { ratio = Split.clamp(ratio) }
    }
    public var first: LayoutNode
    public var second: LayoutNode

    public init(id: UUID = UUID(), axis: SplitAxis, ratio: Double = 0.5, first: LayoutNode, second: LayoutNode) {
        self.id = id
        self.axis = axis
        self.ratio = Split.clamp(ratio)
        self.first = first
        self.second = second
    }

    static func clamp(_ r: Double) -> Double {
        guard r.isFinite else { return 0.5 }
        return min(maxRatio, max(minRatio, r))
    }

    enum CodingKeys: String, CodingKey { case id, axis, ratio, first, second }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  axis: try c.decode(SplitAxis.self, forKey: .axis),
                  ratio: try c.decode(Double.self, forKey: .ratio),
                  first: try c.decode(LayoutNode.self, forKey: .first),
                  second: try c.decode(LayoutNode.self, forKey: .second))
    }
}

/// The binary split tree (BSP) of a workspace.
public indirect enum LayoutNode: Codable, Equatable, Sendable {
    case split(Split)
    case card(Card)

    enum CodingKeys: String, CodingKey { case split, card }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try c.decodeIfPresent(Split.self, forKey: .split) {
            self = .split(s)
        } else {
            self = .card(try c.decode(Card.self, forKey: .card))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .split(let s): try c.encode(s, forKey: .split)
        case .card(let card): try c.encode(card, forKey: .card)
        }
    }
}

public struct Workspace: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// `#rrggbb`, nil for no colour.
    public var color: String?
    /// The workspace's icon in the collapsed sidebar: an emoji or up to two characters ("🚀", "vi"), or an SF
    /// Symbol as `sf:<name>` ("sf:leaf"). nil: the name's first letter. See `WorkspaceIcon`.
    public var icon: String?
    public var pinned: Bool
    /// Key/value labels any tool can set and read (`meum workspace meta set`), saved with the workspace. Keys are
    /// namespaced by convention ("board.project"). nil when there are none (and in state saved before they existed).
    public var metadata: [String: String]?
    /// Default directory for new tabs.
    public var cwd: String?
    public var root: LayoutNode?
    public var focusedCardID: UUID?
    /// The sidebar group it belongs to (`AppState.groups`); nil: none.
    public var group: UUID?

    public init(id: UUID = UUID(), name: String, color: String? = nil, icon: String? = nil, pinned: Bool = false,
                cwd: String? = nil, root: LayoutNode? = nil, focusedCardID: UUID? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.icon = icon
        self.pinned = pinned
        self.cwd = cwd
        self.root = root
        self.focusedCardID = focusedCardID
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var workspaces: [Workspace]
    public var selectedWorkspaceID: UUID?
    /// Sidebar groups. Their members (`Workspace.group`) sit next to each other in `workspaces`; a group's place
    /// in the sidebar is its first member's. A group without members is dropped (`normalizeGroups`).
    public var groups: [WorkspaceGroup]

    public init(workspaces: [Workspace] = [], selectedWorkspaceID: UUID? = nil, groups: [WorkspaceGroup] = []) {
        self.version = AppState.currentVersion
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
        self.groups = groups
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        workspaces = try c.decode([Workspace].self, forKey: .workspaces)
        selectedWorkspaceID = try c.decodeIfPresent(UUID.self, forKey: .selectedWorkspaceID)
        groups = try c.decodeIfPresent([WorkspaceGroup].self, forKey: .groups) ?? []   // state from before groups
    }
}

/// A collapsible group of workspaces in the sidebar.
public struct WorkspaceGroup: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Folded: the sidebar shows only the group's header.
    public var collapsed: Bool

    public init(id: UUID = UUID(), name: String, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
    }
}

/// A workspace icon as stored in `Workspace.icon`.
public enum WorkspaceIcon: Equatable, Sendable {
    /// An emoji or up to two characters.
    case text(String)
    /// An SF Symbol name.
    case symbol(String)

    public static let symbolPrefix = "sf:"

    /// Parses and checks an icon string; nil for anything else (empty, too long, a bad symbol name).
    public init?(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(Self.symbolPrefix) {
            let name = String(s.dropFirst(Self.symbolPrefix.count))
            guard !name.isEmpty, name.count <= 64,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") }) else { return nil }
            self = .symbol(name)
        } else {
            guard !s.isEmpty, s.count <= 2 else { return nil }
            self = .text(s)
        }
    }

    /// What `Workspace.icon` stores for this icon.
    public var raw: String {
        switch self {
        case .text(let t): return t
        case .symbol(let n): return Self.symbolPrefix + n
        }
    }

    /// The fallback for a workspace without an icon: the first letter of its name, upper-cased.
    public static func fallback(forName name: String) -> WorkspaceIcon {
        let first = name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
        return .text(first)
    }
}
