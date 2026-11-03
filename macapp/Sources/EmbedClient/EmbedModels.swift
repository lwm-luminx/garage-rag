import Foundation

/// What to embed: one model's slug, or every registered model when nil.
public struct EmbedBackfillRequest: Codable, Sendable, Equatable {
    public var model: String?
    public var batchSize: Int?
    public var limit: Int?
    public var skipVerify: Bool

    public init(model: String? = nil, batchSize: Int? = nil, limit: Int? = nil, skipVerify: Bool = false) {
        self.model = model
        self.batchSize = batchSize
        self.limit = limit
        self.skipVerify = skipVerify
    }

    enum CodingKeys: String, CodingKey {
        case model
        case batchSize = "batch_size"
        case limit
        case skipVerify = "skip_verify"
    }
}

/// One step of a backfill, a `BackfillStatus` field for field: `complete`, `skipped`, `started`,
/// `progress` or `finished`, with the model's counts and the message the CLI prints.
public struct EmbedBackfillEvent: Codable, Sendable, Equatable {
    public var modelSlug: String
    public var phase: String
    public var total: Int
    public var embedded: Int
    public var failed: Int
    public var remaining: Int
    public var batches: Int
    public var message: String

    public init(modelSlug: String, phase: String, total: Int = 0, embedded: Int = 0, failed: Int = 0, remaining: Int = 0, batches: Int = 0, message: String) {
        self.modelSlug = modelSlug
        self.phase = phase
        self.total = total
        self.embedded = embedded
        self.failed = failed
        self.remaining = remaining
        self.batches = batches
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case modelSlug = "model_slug"
        case phase, total, embedded, failed, remaining, batches, message
    }
}

/// The end of a backfill: each model's outcome, or why it stopped.
public struct EmbedBackfillReply: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case ok
        case failed
        case notFound = "not_found"
        case cancelled
        case busy
    }

    public var status: Status
    public var outcomes: [EmbedBackfillEvent]
    public var error: String?

    public init(status: Status, outcomes: [EmbedBackfillEvent] = [], error: String? = nil) {
        self.status = status
        self.outcomes = outcomes
        self.error = error
    }
}

/// A backfill that did not finish.
public struct EmbedBackfillError: LocalizedError, Equatable, Sendable {
    public let status: EmbedBackfillReply.Status
    public let message: String

    public init(status: EmbedBackfillReply.Status, message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }
}
