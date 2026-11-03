import GarageEmbedXPCServiceCore
import GarageXPCKit

// MARK: - Process Entry Point

let delegate = makeGarageEmbedXPCServiceDelegate()
delegate.bootstrap()
delegate.run()
