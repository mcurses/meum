// A stand-in for cmux's CmuxExtensionKit, just big enough for Tamago's sidebar sources to compile
// UNCHANGED inside meum. Every type and member below is one Tamago actually uses; the shapes copy the
// real SDK (tamago/build/cmux-sdk, commit ddd4a01) minus ExtensionKit, XPC and scope filtering.
//
// The one invention is how `@main` works: the real protocol refines ExtensionKit's AppExtension,
// whose `main()` starts an XPC extension process. Here `main()` builds the extension object and
// hands it to the meum host (any NSObject subclass registered as `MeumSidebarHostApp` that conforms
// to `CmuxShimHostApp`), which shows `body` in its own window.

import Foundation
import SwiftUI

// MARK: - Manifest and scopes (used only by TamagoSidebarExtension.manifest)

public enum CmuxExtensionScope: String, Codable, CaseIterable, Sendable {
    case workspaceList, workspaceMetadata, surfaceMetadata, workspacePaths, notifications, networkPorts, pullRequests
}

public enum CmuxExtensionActionScope: String, Codable, CaseIterable, Sendable {
    case createWorkspace, selectWorkspace, closeWorkspace, createSurface, selectSurface, closeSurface,
         splitSurface, zoomSurface, navigateWorkspace, navigateSurface, openURL, createWorkspaceWithPath
}

public struct CmuxExtensionManifest: Sendable {
    public var id: String
    public var displayName: String
    public var readScopes: [CmuxExtensionScope]
    public var actionScopes: [CmuxExtensionActionScope]
    public init(id: String, displayName: String, readScopes: [CmuxExtensionScope] = [], actionScopes: [CmuxExtensionActionScope] = []) {
        self.id = id; self.displayName = displayName; self.readScopes = readScopes; self.actionScopes = actionScopes
    }
}

// MARK: - Snapshot (what the sidebar draws)

public struct CmuxSidebarWorkspace: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var isPinned: Bool
    public var gitBranch: String?
    public var unreadCount: Int
    public init(id: UUID, title: String, isPinned: Bool = false, gitBranch: String? = nil, unreadCount: Int = 0) {
        self.id = id; self.title = title; self.isPinned = isPinned; self.gitBranch = gitBranch; self.unreadCount = unreadCount
    }
}

public struct CmuxSidebarSnapshot: Equatable, Sendable {
    public var sequence: UInt64
    public var selectedWorkspaceID: UUID?
    public var workspaces: [CmuxSidebarWorkspace]
    public init(sequence: UInt64, selectedWorkspaceID: UUID?, workspaces: [CmuxSidebarWorkspace]) {
        self.sequence = sequence; self.selectedWorkspaceID = selectedWorkspaceID; self.workspaces = workspaces
    }
}

// MARK: - Host channel and context

/// Commands from the sidebar back to the host. Tamago only ever calls `selectWorkspace`.
@MainActor
public struct CmuxSidebarHost {
    private let select: @MainActor (UUID) async throws -> Void
    public init(selectWorkspace: @escaping @MainActor (UUID) async throws -> Void) { select = selectWorkspace }
    public func selectWorkspace(_ id: UUID) async throws { try await select(id) }
}

public struct CmuxSidebarContext: Sendable {
    public let snapshot: CmuxSidebarSnapshot
    public let host: CmuxSidebarHost
    @MainActor public init(snapshot: CmuxSidebarSnapshot, host: CmuxSidebarHost) {
        self.snapshot = snapshot; self.host = host
    }
}

// MARK: - The extension protocol and its entry point

@MainActor
public protocol CmuxSidebarExtension: AnyObject {
    static var manifest: CmuxExtensionManifest { get }
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
    func update(context: CmuxSidebarContext)
    init()
}

/// Implemented by the app that hosts the sidebar (meum). Found at run time by its Objective-C name.
@MainActor
public protocol CmuxShimHostApp: AnyObject {
    static func run(sidebar: any CmuxSidebarExtension, body: AnyView)
}

public extension CmuxSidebarExtension {
    static func main() {
        guard let host = NSClassFromString("MeumSidebarHostApp") as? CmuxShimHostApp.Type else {
            fatalError("no MeumSidebarHostApp class linked into this binary")
        }
        let ext = Self.init()
        host.run(sidebar: ext, body: AnyView(ext.body))
    }
}
