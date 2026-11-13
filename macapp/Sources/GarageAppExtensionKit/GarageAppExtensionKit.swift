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

/// What an extension puts in the Status page's top-right corner, in its toolbar: for the account a build is signed
/// in to (the App Store build's Garage Door, which signs in with Apple).
@MainActor
public protocol GarageStatusAccessory {
    /// Stable and unique among the accessories a build links in.
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
    public var statusAccessories: [any GarageStatusAccessory]
    public var mcpServerPanels: [any GarageMCPServerPanel]
    public var services: [any GarageAppExtensionService]
    /// Whether the Graph page (and the "Show in Graph" actions that lead to it) is offered. Off in
    /// the open-source build, where the knowledge graph is not finished; a build that ships it turns it on.
    public var showsGraph: Bool
    /// Whether the Models page offers fact distillation (its Distillation tab and the Overall card).
    /// Off in the open-source build; a build that ships it turns it on.
    public var showsDistillation: Bool

    public init(
        statusPanels: [any GarageStatusPanel] = [],
        statusAccessories: [any GarageStatusAccessory] = [],
        mcpServerPanels: [any GarageMCPServerPanel] = [],
        services: [any GarageAppExtensionService] = [],
        showsGraph: Bool = false,
        showsDistillation: Bool = false
    ) {
        self.statusPanels = statusPanels
        self.statusAccessories = statusAccessories
        self.mcpServerPanels = mcpServerPanels
        self.services = services
        self.showsGraph = showsGraph
        self.showsDistillation = showsDistillation
    }

    /// No extensions: every build of this repository.
    public static var none: GarageAppExtensionSet { GarageAppExtensionSet() }
}
