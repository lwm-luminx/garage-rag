import Foundation

/// Structured progress update from an ingest run.
public struct IngestProgressUpdate: Codable, Sendable, Equatable {
    public let source: String
    public let phase: String
    public let seen: Int
    public let totalItems: Int
    public let indexed: Int
    public let skipped: Int
    public let failed: Int
    public let placeholders: Int
    public let chunksWritten: Int
    public let itemType: String
    public let progress: Double
    public let message: String
    public let error: String?
    public let currentItem: String?

    public init(
        source: String,
        phase: String = "ingest",
        seen: Int = 0,
        totalItems: Int = 0,
        indexed: Int = 0,
        skipped: Int = 0,
        failed: Int = 0,
        placeholders: Int = 0,
        chunksWritten: Int = 0,
        itemType: String = "items",
        progress: Double = 0.0,
        message: String = "",
        error: String? = nil,
        currentItem: String? = nil
    ) {
        self.source = source
        self.phase = phase
        self.seen = seen
        self.totalItems = totalItems
        self.indexed = indexed
        self.skipped = skipped
        self.failed = failed
        self.placeholders = placeholders
        self.chunksWritten = chunksWritten
        self.itemType = itemType
        self.progress = progress
        self.message = message
        self.error = error
        self.currentItem = currentItem
    }

    enum CodingKeys: String, CodingKey {
        case source
        case phase
        case seen
        case totalItems = "total_items"
        case indexed
        case skipped
        case failed
        case placeholders
        case chunksWritten = "chunks_written"
        case itemType = "item_type"
        case progress
        case message
        case error
        case currentItem = "current_item"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        self.phase = try container.decodeIfPresent(String.self, forKey: .phase) ?? "ingest"
        self.seen = try container.decodeIfPresent(Int.self, forKey: .seen) ?? 0
        self.totalItems = try container.decodeIfPresent(Int.self, forKey: .totalItems) ?? 0
        self.indexed = try container.decodeIfPresent(Int.self, forKey: .indexed) ?? 0
        self.skipped = try container.decodeIfPresent(Int.self, forKey: .skipped) ?? 0
        self.failed = try container.decodeIfPresent(Int.self, forKey: .failed) ?? 0
        self.placeholders = try container.decodeIfPresent(Int.self, forKey: .placeholders) ?? 0
        self.chunksWritten = try container.decodeIfPresent(Int.self, forKey: .chunksWritten) ?? 0
        self.itemType = try container.decodeIfPresent(String.self, forKey: .itemType) ?? "items"
        self.progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0.0
        self.message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.currentItem = try container.decodeIfPresent(String.self, forKey: .currentItem)
    }

    public var isComplete: Bool {
        phase == "complete"
    }

    public var isCancelled: Bool {
        phase == "cancelled"
    }

    public var isError: Bool {
        phase == "error" || error != nil
    }

    public var formattedPercent: String {
        String(format: "%.0f%%", min(100.0, max(0.0, progress * 100.0)))
    }
}

/// Options configuring an ingest run.
public struct IngestOptions: Codable, Sendable, Equatable {
    public let includeCode: Bool
    public let limit: Int?
    public let force: Bool
    public let grpcHost: String?
    public let grpcPort: Int?
    public let databaseUrl: String?
    public let lmStudioApiToken: String?
    /// The app's per-launch gRPC token (`GARAGE_GRPC_TOKEN`), for an ingest that persists over gRPC.
    public let grpcToken: String?

    public init(
        includeCode: Bool = false,
        limit: Int? = nil,
        force: Bool = false,
        grpcHost: String? = nil,
        grpcPort: Int? = nil,
        databaseUrl: String? = nil,
        lmStudioApiToken: String? = nil,
        grpcToken: String? = nil
    ) {
        self.includeCode = includeCode
        self.limit = limit
        self.force = force
        self.grpcHost = grpcHost
        self.grpcPort = grpcPort
        self.databaseUrl = databaseUrl
        self.lmStudioApiToken = lmStudioApiToken
        self.grpcToken = grpcToken
    }

    public static let `default` = IngestOptions()

    enum CodingKeys: String, CodingKey {
        case includeCode = "include_code"
        case limit
        case force
        case grpcHost = "grpc_host"
        case grpcPort = "grpc_port"
        case databaseUrl = "database_url"
        case lmStudioApiToken = "lmstudio_api_token"
        case grpcToken = "grpc_token"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.includeCode = try container.decodeIfPresent(Bool.self, forKey: .includeCode) ?? false
        self.limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        self.force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
        self.grpcHost = try container.decodeIfPresent(String.self, forKey: .grpcHost)
        self.grpcPort = try container.decodeIfPresent(Int.self, forKey: .grpcPort)
        self.databaseUrl = try container.decodeIfPresent(String.self, forKey: .databaseUrl)
        self.lmStudioApiToken = try container.decodeIfPresent(String.self, forKey: .lmStudioApiToken)
        self.grpcToken = try container.decodeIfPresent(String.self, forKey: .grpcToken)
    }
}

/// Result returned from an ingest request.
public struct IngestResult: Codable, Sendable, Equatable {
    public let succeeded: Bool
    public let message: String?

    public init(succeeded: Bool, message: String? = nil) {
        self.succeeded = succeeded
        self.message = message
    }
}

/// Description of an ingest source to test access for.
public struct SourcePathTestItem: Codable, Sendable, Equatable {
    public let slug: String
    public let root: String

    public init(slug: String, root: String) {
        self.slug = slug
        self.root = root
    }
}

/// Request sent to the XPC service to perform volume and source access testing inside the sandbox.
public struct VolumeAccessTestRequest: Codable, Sendable, Equatable {
    public let rootBookmarkData: Data?
    public let sourceBookmarks: [String: Data]?
    public let sourcePaths: [SourcePathTestItem]

    public init(
        rootBookmarkData: Data? = nil,
        sourceBookmarks: [String: Data]? = nil,
        sourcePaths: [SourcePathTestItem] = []
    ) {
        self.rootBookmarkData = rootBookmarkData
        self.sourceBookmarks = sourceBookmarks
        self.sourcePaths = sourcePaths
    }

    enum CodingKeys: String, CodingKey {
        case rootBookmarkData = "root_bookmark_data"
        case sourceBookmarks = "source_bookmarks"
        case sourcePaths = "source_paths"
    }
}

/// Result of testing access to an individual source path inside the XPC sandbox.
public struct IngestSourcePathAccessResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String { slug.isEmpty ? rawPath : "\(slug):\(rawPath)" }
    public let slug: String
    public let rawPath: String
    public let resolvedPath: String
    public let exists: Bool
    public let isReadable: Bool
    public let isDirectory: Bool
    public let itemCount: Int?
    public let errorMessage: String?
    public let tccCategory: String?
    public let requiresTCCPermission: Bool
    public let tccHelpMessage: String?
    public let canOpenFiles: Bool?
    public let sampleFilesTested: Int?
    public let sampleFilesOpened: Int?
    public let fileOpenErrorMessage: String?

    public init(
        slug: String,
        rawPath: String,
        resolvedPath: String,
        exists: Bool,
        isReadable: Bool,
        isDirectory: Bool,
        itemCount: Int?,
        errorMessage: String? = nil,
        tccCategory: String? = nil,
        requiresTCCPermission: Bool = false,
        tccHelpMessage: String? = nil,
        canOpenFiles: Bool? = nil,
        sampleFilesTested: Int? = nil,
        sampleFilesOpened: Int? = nil,
        fileOpenErrorMessage: String? = nil
    ) {
        self.slug = slug
        self.rawPath = rawPath
        self.resolvedPath = resolvedPath
        self.exists = exists
        self.isReadable = isReadable
        self.isDirectory = isDirectory
        self.itemCount = itemCount
        self.errorMessage = errorMessage
        self.tccCategory = tccCategory
        self.requiresTCCPermission = requiresTCCPermission
        self.tccHelpMessage = tccHelpMessage
        self.canOpenFiles = canOpenFiles
        self.sampleFilesTested = sampleFilesTested
        self.sampleFilesOpened = sampleFilesOpened
        self.fileOpenErrorMessage = fileOpenErrorMessage
    }

    public var isAccessible: Bool {
        exists && isReadable && errorMessage == nil && (canOpenFiles ?? true)
    }

    /// The name people know a protected category by ("Messages" for `apple-sms`).
    public static func permissionName(of category: String) -> String {
        switch category {
        case "apple-sms": return "Messages"
        case "apple-mail": return "Mail"
        case "documents": return "Documents"
        case "downloads": return "Downloads"
        case "desktop": return "Desktop"
        default: return category
        }
    }

    public var statusDescription: String {
        if !exists {
            return "Path does not exist"
        }
        if !isReadable {
            if let cat = tccCategory {
                return "Needs permission (\(Self.permissionName(of: cat)))"
            }
            return "Garage isn't allowed to read this folder"
        }
        if let error = errorMessage {
            return "Error: \(error)"
        }
        if let fileErr = fileOpenErrorMessage {
            return "Listing OK, but opening files failed: \(fileErr)"
        }
        if let count = itemCount {
            if let opened = sampleFilesOpened, opened > 0 {
                return "Accessible (\(count) \(count == 1 ? "item" : "items"), \(opened) test file\(opened == 1 ? "" : "s") opened)"
            }
            return "Accessible (\(count) \(count == 1 ? "item" : "items"))"
        }
        if let opened = sampleFilesOpened, opened > 0 {
            return "Accessible (file opened)"
        }
        return "Accessible"
    }

    enum CodingKeys: String, CodingKey {
        case slug
        case rawPath = "raw_path"
        case resolvedPath = "resolved_path"
        case exists
        case isReadable = "is_readable"
        case isDirectory = "is_directory"
        case itemCount = "item_count"
        case errorMessage = "error_message"
        case tccCategory = "tcc_category"
        case requiresTCCPermission = "requires_tcc_permission"
        case tccHelpMessage = "tcc_help_message"
        case canOpenFiles = "can_open_files"
        case sampleFilesTested = "sample_files_tested"
        case sampleFilesOpened = "sample_files_opened"
        case fileOpenErrorMessage = "file_open_error_message"
    }
}

/// Overall result of volume and source access testing inside the XPC sandbox.
public struct IngestVolumeAccessTestResult: Codable, Sendable, Equatable {
    public let isAccessible: Bool
    public let testedPath: String
    public let rootItemsCount: Int
    public let accessibleSubpaths: [String]
    public let inaccessibleSubpaths: [String]
    public let sourcePathResults: [IngestSourcePathAccessResult]
    public let message: String
    public let isSecurityScoped: Bool

    public init(
        isAccessible: Bool,
        testedPath: String,
        rootItemsCount: Int,
        accessibleSubpaths: [String],
        inaccessibleSubpaths: [String],
        sourcePathResults: [IngestSourcePathAccessResult],
        message: String,
        isSecurityScoped: Bool
    ) {
        self.isAccessible = isAccessible
        self.testedPath = testedPath
        self.rootItemsCount = rootItemsCount
        self.accessibleSubpaths = accessibleSubpaths
        self.inaccessibleSubpaths = inaccessibleSubpaths
        self.sourcePathResults = sourcePathResults
        self.message = message
        self.isSecurityScoped = isSecurityScoped
    }

    enum CodingKeys: String, CodingKey {
        case isAccessible = "is_accessible"
        case testedPath = "tested_path"
        case rootItemsCount = "root_items_count"
        case accessibleSubpaths = "accessible_subpaths"
        case inaccessibleSubpaths = "inaccessible_subpaths"
        case sourcePathResults = "source_path_results"
        case message
        case isSecurityScoped = "is_security_scoped"
    }
}
