import Foundation
import GRPC
import GarageAppExtensionKit
import NIO
import proto_garage_proto_swift

/// The Access page's calls (docs/plans/access-policies.md) over GarageService, as the plain values of
/// `GarageAccessBackend`, which the page's Rego editor and any editor an extension adds both use.
extension GarageGRPCService: GarageAccessBackend {
    private func accessCall<T>(
        _ body: @MainActor (Garage_GarageServiceAsyncClient, CallOptions) async throws -> T
    ) async throws -> T {
        if status != .running {
            try await start()
        }
        let client = Garage_GarageServiceAsyncClient(channel: getOrCreateChannel(), defaultCallOptions: GarageGRPCAuth.callOptions())
        var options = GarageGRPCAuth.callOptions()
        options.timeLimit = .timeout(.seconds(60))
        do {
            return try await body(client, options)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw GarageGRPCError.rpcFailed(Self.describe(error))
        }
    }

    private static func message(_ policy: GarageAccessPolicy) -> Garage_AccessPolicy {
        var message = Garage_AccessPolicy()
        message.name = policy.name
        message.rego = policy.rego
        message.enabled = policy.enabled
        return message
    }

    func listPolicies() async throws -> GarageAccessPolicies {
        let response = try await accessCall {
            try await $0.listAccessPolicies(Garage_ListAccessPoliciesRequest(), callOptions: $1)
        }
        return GarageAccessPolicies(
            policies: response.policies.map {
                GarageAccessPolicy(name: $0.name, rego: $0.rego, enabled: $0.enabled, updatedAt: $0.updatedAt)
            },
            builtinRego: response.builtinRego,
            engine: response.engine,
            editable: response.editable,
            callers: response.callers.map { GarageAccessCaller(caller: $0.caller, label: $0.label) }
        )
    }

    func putPolicy(_ policy: GarageAccessPolicy, checkOnly: Bool) async throws -> String {
        var request = Garage_PutAccessPolicyRequest()
        request.policy = Self.message(policy)
        request.checkOnly = checkOnly
        return try await accessCall { try await $0.putAccessPolicy(request, callOptions: $1) }.message
    }

    func removePolicy(named name: String) async throws -> String {
        var request = Garage_RemoveAccessPolicyRequest()
        request.name = name
        return try await accessCall { try await $0.removeAccessPolicy(request, callOptions: $1) }.message
    }

    func listRules() async throws -> [GarageAccessRule] {
        let response = try await accessCall {
            try await $0.listAccessRules(Garage_ListAccessRulesRequest(), callOptions: $1)
        }
        return response.rules.map {
            GarageAccessRule(name: $0.name, ruleJSON: $0.ruleJson, enabled: $0.enabled, pending: $0.pending)
        }
    }

    func putRule(json: String) async throws -> String {
        var request = Garage_PutAccessRuleRequest()
        request.ruleJson = json
        return try await accessCall { try await $0.putAccessRule(request, callOptions: $1) }.message
    }

    func removeRule(named name: String) async throws -> String {
        var request = Garage_RemoveAccessRuleRequest()
        request.name = name
        return try await accessCall { try await $0.removeAccessRule(request, callOptions: $1) }.message
    }

    func listDefaults() async throws -> [GarageAccessDefault] {
        let response = try await accessCall {
            try await $0.listAccessDefaults(Garage_ListAccessDefaultsRequest(), callOptions: $1)
        }
        return response.defaults.map { GarageAccessDefault(target: $0.target, effect: $0.effect) }
    }

    func setDefault(target: String, effect: String) async throws -> String {
        var request = Garage_SetAccessDefaultRequest()
        request.target = target
        request.effect = effect
        return try await accessCall { try await $0.setAccessDefault(request, callOptions: $1) }.message
    }

    func test(caller: String, draft: GarageAccessPolicy?) async throws -> GarageAccessTestResult {
        var request = Garage_TestAccessRequest()
        request.caller = caller
        if let draft {
            request.draft = Self.message(draft)
        }
        let response = try await accessCall { try await $0.testAccess(request, callOptions: $1) }
        return GarageAccessTestResult(
            callerKind: response.callerKind,
            transport: response.transport,
            registrationName: response.registrationName,
            targets: response.targets,
            policies: response.policies,
            decisionJSON: response.decisionJson,
            contentRules: response.contentRules.map { (name: $0.name, pending: $0.pending) },
            seesEverything: response.seesEverything,
            filterSQL: response.filterSql,
            filterParams: response.filterParams
        )
    }
}
