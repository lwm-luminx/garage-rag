import Foundation
import GarageXPCKit
import LlamaClient

/// Self test for a service that loads or embeds with llama_xpc models: LlamaXPCService must answer
/// this process over NSXPC, through the endpoint the app handed over, or on-demand loads cannot work.
/// Skipped until the app has handed one over; the service re-runs it when one arrives.
public enum LlamaEndpointSelfTest {
    public static func make(store: GarageLlamaEndpointStore = .shared) -> GarageXPCSelfTest {
        GarageXPCSelfTest(
            name: GarageLlamaEndpointStore.dependentSelfTestName,
            description: "Reaches LlamaXPCService over NSXPC, through the endpoint the app hands over, which on-demand model loads go through.",
            requiresPython: false
        ) {
            guard let endpoint = store.endpoint else {
                throw GarageXPCSelfTestSkipped("LlamaXPCService endpoint not handed over yet: the Garage app hands it over after launch")
            }
            // Made here, not in the task: the endpoint is not Sendable, the client is.
            let client = LlamaClient(endpoint: endpoint)
            let semaphore = DispatchSemaphore(value: 0)
            let box = PingBox()
            Task.detached {
                do {
                    let reply = try await client.ping()
                    let models = (try? await client.listModels().data.map(\.id)) ?? []
                    box.set(.success("\(reply)\nResident: \(models.isEmpty ? "none" : models.joined(separator: ", "))"))
                } catch {
                    box.set(.failure(error))
                }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 10) == .success, let result = box.get() else {
                throw GarageXPCSelfTestFailure("LlamaXPCService did not answer within 10 seconds")
            }
            switch result {
            case .success(let text):
                return text
            case .failure(let error):
                throw GarageXPCSelfTestFailure("LlamaXPCService is unreachable through the handed-over endpoint", details: error.localizedDescription)
            }
        }
    }
}

private final class PingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, Error>?

    func set(_ value: Result<String, Error>) {
        lock.lock()
        result = value
        lock.unlock()
    }

    func get() -> Result<String, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}
