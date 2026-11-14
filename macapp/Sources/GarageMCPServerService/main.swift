import GarageMCPServerServiceCore
import GarageXPCKit

// MARK: - Process Entry Point

let delegate = GarageMCPServerServiceDelegate()
delegate.bootstrap()
delegate.run()
