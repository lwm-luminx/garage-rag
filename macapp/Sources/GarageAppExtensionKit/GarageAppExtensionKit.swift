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

/// Everything the extensions a build links in add to the app.
@MainActor
public struct GarageAppExtensionSet {
    public var mcpServerPanels: [any GarageMCPServerPanel]

    public init(mcpServerPanels: [any GarageMCPServerPanel] = []) {
        self.mcpServerPanels = mcpServerPanels
    }

    /// No extensions: every build of this repository.
    public static var none: GarageAppExtensionSet { GarageAppExtensionSet() }
}
