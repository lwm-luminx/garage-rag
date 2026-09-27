import SwiftUI

// The MCP page's rows as plain values: what the server row says, one line per assistant, and the
// summary over the list. Kept out of the view so the wording can be tested without a window.

/// The server row: a tinted circle, a title and one line under it.
struct MCPServerHeadline: Equatable {
    let symbol: String
    let tint: Color
    let isActive: Bool
    let title: String
    let detail: String
    var detailIsError = false

    /// - Parameters:
    ///   - test: the last check that the server answers; ignored unless the server is running.
    ///   - connectedCount: assistants registered with the server, which reach it only while it runs.
    ///   - httpEnabled: whether the app serves HTTP at all; off, a stopped server is the normal state.
    init(
        status: GarageMCPStatus,
        test: MCPTestResult?,
        isTesting: Bool,
        isDatabaseRunning: Bool,
        connectedCount: Int,
        httpEnabled: Bool = true
    ) {
        if status == .stopped && !httpEnabled {
            self.init(
                symbol: "terminal",
                tint: .green,
                isActive: connectedCount > 0,
                title: "HTTP off",
                detail: "Connected assistants start Garage themselves and talk to it over stdio; no port is open. Start the HTTP server only for an assistant that needs an address."
            )
            return
        }
        switch status {
        case .running:
            if isTesting {
                self.init(symbol: "server.rack", tint: .green, isActive: true, title: "Running", detail: "Checking that it answers…")
            } else if let test, !test.isSuccess {
                self.init(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    isActive: true,
                    title: "Running, but not answering",
                    detail: test.errorMessage ?? "The last check got no reply.",
                    detailIsError: true
                )
            } else if let test {
                let tools = test.tools.count
                self.init(
                    symbol: "checkmark",
                    tint: .green,
                    isActive: true,
                    title: "Running",
                    detail: "Answering on this Mac only · \(tools) \(MCPPagePresentation.plural("tool", tools))"
                )
            } else {
                self.init(symbol: "server.rack", tint: .green, isActive: true, title: "Running", detail: "Listening on this Mac only")
            }
        case .starting:
            self.init(
                symbol: "server.rack",
                tint: .blue,
                isActive: true,
                title: "Starting…",
                detail: isDatabaseRunning ? "Starting the server…" : "Starting the database first…"
            )
        case .stopping:
            self.init(symbol: "server.rack", tint: .blue, isActive: true, title: "Stopping…", detail: "Stopping the server…")
        case .stopped:
            var detail = connectedCount > 0
                ? "\(connectedCount) connected \(MCPPagePresentation.plural("assistant", connectedCount)) can't reach Garage until it runs."
                : "Assistants reach Garage through this server once they're connected."
            if !isDatabaseRunning {
                detail += " Starting it also starts the database."
            }
            self.init(symbol: "server.rack", tint: .secondary, isActive: false, title: "Stopped", detail: detail)
        case .failed(let message):
            self.init(
                symbol: "xmark",
                tint: .red,
                isActive: true,
                title: "Couldn't start",
                detail: message,
                detailIsError: true
            )
        }
    }

    init(symbol: String, tint: Color, isActive: Bool, title: String, detail: String, detailIsError: Bool = false) {
        self.symbol = symbol
        self.tint = tint
        self.isActive = isActive
        self.title = title
        self.detail = detail
        self.detailIsError = detailIsError
    }
}

/// One assistant in the list: where it stands with this server and the one thing to do about it.
struct MCPClientRowPresentation: Equatable {
    enum State: Equatable {
        /// Registered and pointing at this server's address (or a stdio entry, which has none).
        case connected
        /// Registered, but at an address the server no longer listens on (the port changed).
        case outdated(registeredURL: String)
        /// The assistant's config file exists and has no entry for Garage.
        case notConnected
        /// No config file: the assistant is probably not installed.
        case notInstalled
    }

    let state: State
    let symbol: String
    let tint: Color
    let isActive: Bool
    let status: String
    /// The row's button: Connect, Update, or nothing when it is connected (Disconnect is in its menu).
    let actionTitle: String?

    /// - Parameter endpoint: the HTTP address assistants are registered at, or nil when HTTP is off
    ///   and they run `garage-mcp` over stdio; an HTTP entry is then out of date.
    init(client: MCPClientConfig, endpoint: URL?) {
        symbol = Self.symbol(for: client.id)
        if client.isRegistered {
            if let url = client.registeredURL, endpoint == nil {
                state = .outdated(registeredURL: url)
                tint = .orange
                isActive = true
                status = "Points at \(url), but the HTTP server is off"
                actionTitle = "Update"
            } else if let url = client.registeredURL, let endpoint, !Self.sameEndpoint(url, endpoint) {
                state = .outdated(registeredURL: url)
                tint = .orange
                isActive = true
                status = "Points at \(url), not \(endpoint.absoluteString)"
                actionTitle = "Update"
            } else {
                state = .connected
                tint = .green
                isActive = true
                status = "Connected"
                actionTitle = nil
            }
        } else if client.existsOnDisk {
            state = .notConnected
            tint = .blue
            isActive = false
            status = "Installed, not connected"
            actionTitle = "Connect"
        } else {
            state = .notInstalled
            tint = .secondary
            isActive = false
            status = "Not found on this Mac"
            actionTitle = "Connect"
        }
    }

    var isConnected: Bool { state == .connected }

    var isOutdated: Bool {
        if case .outdated = state { return true }
        return false
    }

    /// The glyph in the row's circle: what kind of assistant it is.
    static func symbol(for clientId: String) -> String {
        switch clientId {
        case "claude-desktop": "bubble.left.and.text.bubble.right"
        case "project", "claude-code-user": "terminal"
        case "lmstudio": "cpu"
        case "cursor", "cursor-global": "cursorarrow.rays"
        case "vscode", "vscode-global": "chevron.left.forwardslash.chevron.right"
        case "windsurf": "wind"
        case "zed": "bolt"
        default: "puzzlepiece.extension"
        }
    }

    /// The same server, ignoring a trailing slash and the case of the host.
    static func sameEndpoint(_ registered: String, _ endpoint: URL) -> Bool {
        func normalized(_ string: String) -> String {
            var value = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while value.hasSuffix("/") { value.removeLast() }
            return value
        }
        return normalized(registered) == normalized(endpoint.absoluteString)
    }
}

enum MCPPagePresentation {
    /// The line over the assistant list.
    static func clientSummary(_ rows: [MCPClientRowPresentation]) -> String {
        let installed = rows.filter { $0.state != .notInstalled }
        let connected = rows.filter(\.isConnected).count
        let outdated = rows.filter(\.isOutdated).count
        if installed.isEmpty {
            return "No assistants found on this Mac"
        }
        var summary: String
        if connected == 0 && outdated == 0 {
            summary = "None of \(installed.count) installed \(plural("assistant", installed.count)) connected yet"
        } else if connected == installed.count {
            summary = connected == 1 ? "Your assistant is connected" : "All \(connected) installed assistants are connected"
        } else {
            summary = "\(connected) of \(installed.count) installed \(plural("assistant", installed.count)) connected"
        }
        if outdated > 0 {
            summary += " · \(outdated) \(outdated == 1 ? "needs" : "need") updating"
        }
        return summary
    }

    /// Whether Connect All has anything to do: an installed assistant that is not connected, or
    /// one that points at an old address.
    static func canConnectAll(_ rows: [MCPClientRowPresentation]) -> Bool {
        rows.contains { $0.state != .notInstalled && !$0.isConnected }
    }

    static func plural(_ word: String, _ count: Int) -> String {
        count == 1 ? word : word + "s"
    }
}
