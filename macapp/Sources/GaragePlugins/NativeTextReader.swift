import Foundation
import GaragePluginProto
import GarageTextFFI
import SwiftProtobuf

/// A reader plugin: one or more extractors that turn a file's bytes into text, answering the
/// messages of `proto/garage_plugin.proto` whether it runs in this process or in its own.
public protocol ExtractorPlugin: Sendable {
    func describe(_ request: Garage_Plugin_V1_DescribeRequest) throws -> Garage_Plugin_V1_DescribeResponse
    func extract(_ request: Garage_Plugin_V1_ExtractRequest) throws -> Garage_Plugin_V1_ExtractResponse
}

/// A call into a linked plugin that failed before it could answer: the request did not decode, or
/// the plugin panicked (and recovered). A file the plugin cannot read is not this: that comes back
/// as the response's `failure`.
public struct NativePluginError: Error, CustomStringConvertible, Equatable {
    public enum Status: Int32, Sendable {
        case badRequest = 1
        case panic = 2
        case unknown = -1
    }

    public let status: Status
    public let message: String

    public var description: String { "\(status): \(message)" }
}

/// Garage's text reader (Markdown, plain text, source code), written in Rust and linked into this
/// process through its C ABI (`rust/garage-text-ffi`).
public struct NativeTextReader: ExtractorPlugin {
    /// The contract version the linked library speaks.
    public static var contract: Garage_Plugin_V1_ContractVersion {
        Garage_Plugin_V1_ContractVersion(rawValue: Int(garage_text_contract_version())) ?? .unspecified
    }

    public init() {}

    public func describe(
        _ request: Garage_Plugin_V1_DescribeRequest = .init()
    ) throws -> Garage_Plugin_V1_DescribeResponse {
        try Garage_Plugin_V1_DescribeResponse(serializedData: Self.call(garage_text_describe, request))
    }

    public func extract(_ request: Garage_Plugin_V1_ExtractRequest) throws -> Garage_Plugin_V1_ExtractResponse {
        try Garage_Plugin_V1_ExtractResponse(serializedData: Self.call(garage_text_extract, request))
    }

    /// Reads one file, by its name (never its path) and its bytes.
    public func extract(fileName: String, content: Data, extractor: String = "") throws
        -> Garage_Plugin_V1_ExtractResponse
    {
        var request = Garage_Plugin_V1_ExtractRequest()
        request.fileName = fileName
        request.content = content
        request.extractor = extractor
        return try extract(request)
    }

    private typealias Entry = (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<GarageBuffer>?) -> Int32

    private static func call(_ entry: Entry, _ request: some SwiftProtobuf.Message) throws -> Data {
        let bytes = try request.serializedData()
        var buffer = GarageBuffer(data: nil, len: 0)
        let status = bytes.withUnsafeBytes { raw in
            entry(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, &buffer)
        }
        defer { garage_text_buffer_free(buffer) }
        let answer = buffer.data.map { Data(bytes: $0, count: buffer.len) } ?? Data()
        guard status == GARAGE_TEXT_OK else {
            throw NativePluginError(
                status: NativePluginError.Status(rawValue: status) ?? .unknown,
                message: String(decoding: answer, as: UTF8.self)
            )
        }
        return answer
    }
}
