import GarageXPCKit
import GarageXPCServiceCore

// MARK: - Process Entry Point

let delegate = makeGarageXPCServiceDelegate()
delegate.bootstrap()
delegate.run()
