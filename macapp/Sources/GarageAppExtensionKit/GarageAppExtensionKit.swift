import Foundation
import SwiftUI

/// What the app tells an extension's views about the app as it is now.
public struct GarageAppExtensionContext: Sendable, Equatable {
    /// The MCP server's HTTP endpoint while it is running, or nil (assistants use stdio).
    public var mcpHTTPEndpoint: URL?

    public init(mcpHTTPEndpoint: URL? = nil) {
        self.mcpHTTPEndpoint = mcpHTTPEndpoint
    }
}

/// A panel an extension adds to the MCP Server page, below the app's own sections.
@MainActor
public protocol GarageMCPServerPanel {
    /// Stable and unique among the panels a build links in.
    var id: String { get }

    func makeView(context: GarageAppExtensionContext) -> AnyView
}

/// A panel an extension adds to the Status page, above Health: for what a build wants seen first.
@MainActor
public protocol GarageStatusPanel {
    /// Stable and unique among the panels a build links in.
    var id: String { get }

    func makeView(context: GarageAppExtensionContext) -> AnyView
}

/// Work an extension keeps going for the app's whole life, outside any page.
@MainActor
public protocol GarageAppExtensionService {
    /// Stable and unique among the services a build links in.
    var id: String { get }

    /// GarageService listens and the helpers (the MCP service among them) know its address. Called
    /// at launch and again after each restart of the backend, so it must be idempotent.
    func backendDidStart()
}

/// Everything the extensions a build links in add to the app.
@MainActor
public struct GarageAppExtensionSet {
    public var statusPanels: [any GarageStatusPanel]
    public var mcpServerPanels: [any GarageMCPServerPanel]
    public var services: [any GarageAppExtensionService]

    public init(
        statusPanels: [any GarageStatusPanel] = [],
        mcpServerPanels: [any GarageMCPServerPanel] = [],
        services: [any GarageAppExtensionService] = []
    ) {
        self.statusPanels = statusPanels
        self.mcpServerPanels = mcpServerPanels
        self.services = services
    }

    /// No extensions: every build of this repository.
    public static var none: GarageAppExtensionSet { GarageAppExtensionSet() }
}
