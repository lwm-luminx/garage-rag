import Foundation
import PythonKit
import PythonXPCService

/// Command line smoke test for the embedded Python runtime used by the XPC services.
///
/// Usage: `python_embed_smoke`. It links PythonXPCService.framework like the services, so site-python, libpq and
/// libtesseract come from the framework it loads (or set `GARAGE_SITE_PYTHON` to another site-python directory).
/// Exits non-zero when the interpreter fails to start or any self test fails.
let runtime = GaragePythonRuntime.shared

// Initialize from a GCD worker exactly like GarageXPCServiceBase.bootstrap() does (host queue → ensurePythonReady),
// so the large-stack hop inside initializeIfNeeded() is exercised rather than the 8 MB main thread.
let initResult: Result<GaragePythonEnvironment, Error> = DispatchQueue(label: "smoke.host", qos: .utility).sync {
    runtime.initializeIfNeeded()
}
switch initResult {
case .success(let environment):
    print("Python ready: \(runtime.pythonVersion ?? "?")")
    print("  home:          \(environment.home.path)")
    print("  lib-dynload:   \(environment.libDynloadDir.path)")
    print("  site-packages: \(environment.sitePackagesDir.path)")
case .failure(let error):
    fputs("Python initialization failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}

// Exercise concurrent GIL acquisition from a second thread while the tests run.
let background = Thread {
    for _ in 0..<50 {
        _ = try? runtime.withGIL { _ = Python.import("time").sleep(0.005) }
    }
}
background.start()

let tests: [GarageXPCSelfTest] = [
    GarageXPCStandardSelfTests.pythonRuntime(runtime: runtime),
    GarageXPCStandardSelfTests.stdlibExtensions(),
    GarageXPCStandardSelfTests.sitePackages(modules: ["grpc", "psycopg", "google.protobuf", "garage_rag"]),
    GarageXPCStandardSelfTests.libpq(runtime: runtime),
    GarageXPCStandardSelfTests.tlsTrust(runtime: runtime),
    GarageXPCStandardSelfTests.libtesseract(),
    GarageXPCStandardSelfTests.gitHistory(),
    GarageXPCStandardSelfTests.serviceModule("garage_rag.ingest", attributes: ["ingest_xpc", "cancel_ingest"]),
    GarageXPCStandardSelfTests.serviceModule("garage_rag.service.server", attributes: ["create_grpc_server"]),
    GarageXPCStandardSelfTests.database(urlProvider: { ProcessInfo.processInfo.environment[GarageXPCConfigurationKey.databaseURL] }),
    // Regression: Python driven from a 512 KB GCD worker thread used to overflow the stack (SIGBUS in
    // _PyEval_EvalFrameDefault) as soon as the interpreter recursed a few hundred frames deep.
    GarageXPCSelfTest(name: "Deep Recursion From GCD", description: "Runs a 10000-frame Python recursion from a DispatchQueue worker via withGIL.", requiresPython: false) {
        var outcome: Result<String, Error> = .failure(GaragePythonRuntimeError.notInitialized)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let callerStack = pthread_get_stacksize_np(pthread_self())
            outcome = Result {
                try runtime.withGIL {
                    let pythonStack = pthread_get_stacksize_np(pthread_self())
                    let sys = try Python.attemptImport("sys")
                    sys.setrecursionlimit(20000)
                    let namespace = Python.dict()
                    _ = try Python.import("builtins").exec.throwing.dynamicallyCall(withArguments: [
                        "def f(n):\n    return 0 if n == 0 else 1 + f(n - 1)\nresult = f(10000)", namespace,
                    ])
                    return "caller stack: \(callerStack / 1024) KB, python stack: \(pythonStack / 1024) KB, result: \(namespace["result"])"
                }
            }
            group.leave()
        }
        group.wait()
        return try outcome.get()
    },
]

var failed = 0
for result in GarageXPCSelfTestRunner.run(tests, runtime: runtime) {
    print("[\(result.status.rawValue.uppercased())] \(result.name) (\(Int(result.durationMs))ms): \(result.summary)")
    if result.status == .failed {
        failed += 1
        print(result.details.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n"))
    }
}
exit(failed == 0 ? 0 : 1)
