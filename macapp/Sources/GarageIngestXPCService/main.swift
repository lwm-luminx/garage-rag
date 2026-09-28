import PythonXPCService
import GarageIngestXPCServiceCore

// MARK: - Process Entry Point

let delegate = makeGarageIngestXPCServiceDelegate()
delegate.bootstrap()
delegate.run()
