import Foundation
import OSLog
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "IngestEngine")

/// Engine handling security-scoped bookmark lifecycle and sandboxed access verification.
public final class IngestEngine: @unchecked Sendable {
    public static let shared = IngestEngine()

    private let lock = NSLock()
    private var activeRootURL: URL?
    private var isAccessingRootScope = false
    private var activeSourceURLs: [String: URL] = [:]

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    public init() {}

    deinit {
        revokeAccess()
    }

    // MARK: - JSON Helpers

    public func serialize<T: Encodable>(_ value: T) -> String? {
        guard let data = try? jsonEncoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func deserialize<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        guard let data = jsonString.data(using: .utf8) else {
            throw NSError(domain: "IngestEngine", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 payload"])
        }
        return try jsonDecoder.decode(type, from: data)
    }

    // MARK: - Security-Scoped Bookmark Management

    /// Sets root volume bookmark data and begins accessing the security-scoped resource.
    @discardableResult
    public func setRootVolumeBookmark(_ bookmarkData: Data) -> (success: Bool, message: String?) {
        lock.lock()
        defer { lock.unlock() }

        logger.info("IngestEngine.setRootVolumeBookmark resolving bookmark (\(bookmarkData.count) bytes)")
        stopAccessingRootScopeInternal()

        var isStale = false
        do {
            #if os(macOS)
            let resolvedURL: URL
            do {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }
            #else
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif

            let started = resolvedURL.startAccessingSecurityScopedResource()
            self.activeRootURL = resolvedURL
            self.isAccessingRootScope = started

            let scopeType = started ? "security-scoped" : "direct"
            let msg = "Resolved root bookmark: \(resolvedURL.path) (\(scopeType))"
            logger.info("\(msg, privacy: .public)")
            return (true, msg)
        } catch {
            let msg = "Failed to resolve root bookmark: \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            return (false, msg)
        }
    }

    /// Sets source bookmark data for a specific source path.
    @discardableResult
    public func setSourceBookmark(path: String, bookmarkData: Data) -> (success: Bool, message: String?) {
        lock.lock()
        defer { lock.unlock() }

        let resolvedPath = GarageAppGroup.expandingTilde(in: path)
        logger.info("IngestEngine.setSourceBookmark for path '\(resolvedPath, privacy: .public)' (\(bookmarkData.count) bytes)")
        if let existing = activeSourceURLs[resolvedPath] {
            existing.stopAccessingSecurityScopedResource()
        }

        var isStale = false
        do {
            #if os(macOS)
            let resolvedURL: URL
            do {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }
            #else
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif

            _ = resolvedURL.startAccessingSecurityScopedResource()
            activeSourceURLs[resolvedPath] = resolvedURL
            let msg = "Resolved source bookmark for \(resolvedPath)"
            logger.info("\(msg, privacy: .public)")
            return (true, msg)
        } catch {
            let msg = "Failed to resolve source bookmark for \(resolvedPath): \(error.localizedDescription)"
            logger.error("\(msg, privacy: .public)")
            return (false, msg)
        }
    }

    /// Revokes all active security-scoped access and clears stored references.
    public func revokeAccess() {
        lock.lock()
        defer { lock.unlock() }

        logger.info("IngestEngine.revokeAccess: revoking all active security scopes")
        stopAccessingRootScopeInternal()
        for (path, url) in activeSourceURLs {
            logger.info("Stopping access for source URL: '\(path, privacy: .public)'")
            url.stopAccessingSecurityScopedResource()
        }
        activeSourceURLs.removeAll()
    }

    private func stopAccessingRootScopeInternal() {
        if isAccessingRootScope, let rootURL = activeRootURL {
            rootURL.stopAccessingSecurityScopedResource()
            isAccessingRootScope = false
        }
        activeRootURL = nil
    }

    // MARK: - Access Testing Inside the XPC Sandbox

    /// Executes full filesystem and TCC access tests inside the XPC sandbox process.
    public func testVolumeAccess(request: VolumeAccessTestRequest) -> IngestVolumeAccessTestResult {
        // Apply root bookmark if passed in request
        if let rootData = request.rootBookmarkData {
            setRootVolumeBookmark(rootData)
        }

        // Apply source bookmarks if passed in request
        if let sourceBookmarks = request.sourceBookmarks {
            for (path, data) in sourceBookmarks {
                setSourceBookmark(path: path, bookmarkData: data)
            }
        }

        lock.lock()
        let targetURL = activeRootURL ?? URL(fileURLWithPath: "/")
        let isSecurityScoped = isAccessingRootScope
        lock.unlock()

        let fileManager = FileManager.default

        var rootItems: [URL] = []
        var rootAccessible = false
        do {
            rootItems = try fileManager.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            rootAccessible = true
        } catch {
            rootAccessible = false
        }

        let isRootVolume = targetURL.path == "/" || targetURL.path.hasPrefix("/Volumes")
        let commonSubpaths = ["System", "Library", "Applications", "Users", "Volumes"]
        var accessibleSubpaths: [String] = []
        var inaccessibleSubpaths: [String] = []

        if isRootVolume {
            for subpath in commonSubpaths {
                let subURL = targetURL.path == "/" ? URL(fileURLWithPath: "/\(subpath)") : targetURL.appendingPathComponent(subpath)
                if fileManager.isReadableFile(atPath: subURL.path) {
                    accessibleSubpaths.append("/\(subpath)")
                } else {
                    inaccessibleSubpaths.append("/\(subpath)")
                }
            }
        }

        // Test each source path
        var sourceResults: [IngestSourcePathAccessResult] = []
        for source in request.sourcePaths {
            let rawPath = source.root
            let slug = source.slug
            let resolvedPath = GarageAppGroup.expandingTilde(in: rawPath)
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDir)
            let isReadable = fileManager.isReadableFile(atPath: resolvedPath)
            var count: Int? = nil
            var errorMsg: String? = nil
            var canOpenFiles: Bool? = nil
            var sampleTested: Int? = nil
            var sampleOpened: Int? = nil
            var fileOpenError: String? = nil

            let tccCategory = detectTCCCategory(slug: slug, path: resolvedPath)
            let requiresTCC = !isReadable && exists && (tccCategory != nil)
            let helpMsg = requiresTCC ? tccHelpMessage(category: tccCategory) : nil

            if exists && isReadable {
                if isDir.boolValue {
                    do {
                        let contents = try fileManager.contentsOfDirectory(
                            at: URL(fileURLWithPath: resolvedPath),
                            includingPropertiesForKeys: [.isDirectoryKey],
                            options: [.skipsHiddenFiles]
                        )
                        count = contents.count

                        var testedCount = 0
                        var openedCount = 0
                        for itemURL in contents.prefix(10) {
                            var isSubDir: ObjCBool = false
                            if fileManager.fileExists(atPath: itemURL.path, isDirectory: &isSubDir), !isSubDir.boolValue {
                                testedCount += 1
                                if let handle = try? FileHandle(forReadingFrom: itemURL) {
                                    try? handle.close()
                                    openedCount += 1
                                } else {
                                    fileOpenError = "Failed to open file '\(itemURL.lastPathComponent)' for reading"
                                }
                            }
                        }
                        sampleTested = testedCount
                        sampleOpened = openedCount
                        canOpenFiles = testedCount == 0 ? true : (fileOpenError == nil && openedCount == testedCount)
                    } catch {
                        errorMsg = error.localizedDescription
                        canOpenFiles = false
                    }
                } else {
                    sampleTested = 1
                    if let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: resolvedPath)) {
                        try? handle.close()
                        sampleOpened = 1
                        canOpenFiles = true
                    } else {
                        sampleOpened = 0
                        canOpenFiles = false
                        fileOpenError = "Failed to open file for reading"
                    }
                }
            } else if !exists {
                errorMsg = "Path does not exist"
                canOpenFiles = false
            } else if !isReadable {
                if let cat = tccCategory {
                    errorMsg = "Needs permission (\(IngestSourcePathAccessResult.permissionName(of: cat)))"
                } else {
                    errorMsg = "Garage isn't allowed to read this folder"
                }
                canOpenFiles = false
            }

            sourceResults.append(IngestSourcePathAccessResult(
                slug: slug,
                rawPath: rawPath,
                resolvedPath: resolvedPath,
                exists: exists,
                isReadable: isReadable,
                isDirectory: isDir.boolValue,
                itemCount: count,
                errorMessage: errorMsg,
                tccCategory: tccCategory,
                requiresTCCPermission: requiresTCC || (!isReadable && exists),
                tccHelpMessage: helpMsg,
                canOpenFiles: canOpenFiles,
                sampleFilesTested: sampleTested,
                sampleFilesOpened: sampleOpened,
                fileOpenErrorMessage: fileOpenError
            ))
        }

        let rootVolumeAccessible: Bool
        if isRootVolume {
            rootVolumeAccessible = rootAccessible && (!accessibleSubpaths.isEmpty || !rootItems.isEmpty)
        } else {
            rootVolumeAccessible = rootAccessible && fileManager.isReadableFile(atPath: targetURL.path)
        }

        let allSourcesAccessible = sourceResults.isEmpty || sourceResults.allSatisfy(\.isAccessible)
        let isOverallAccessible = rootVolumeAccessible && allSourcesAccessible

        let message: String
        if !sourceResults.isEmpty {
            let totalCount = sourceResults.count
            if isOverallAccessible {
                message = "Volume & source access verified at '\(targetURL.path)' in XPC process. All \(totalCount) ingest source \(totalCount == 1 ? "path is" : "paths are") accessible."
            } else if !rootVolumeAccessible {
                message = "Root volume access test failed for '\(targetURL.path)' in XPC process."
            } else {
                let inaccessible = sourceResults.filter { !$0.isAccessible }
                let details = inaccessible.map { res in
                    let label = res.slug.isEmpty ? res.rawPath : res.slug
                    return "\(label) (\(res.statusDescription))"
                }.joined(separator: ", ")
                message = "Volume access granted at '\(targetURL.path)' in XPC process, but \(inaccessible.count) of \(totalCount) ingest source \(totalCount == 1 ? "path is" : "paths are") inaccessible: \(details)"
            }
        } else {
            if rootVolumeAccessible {
                if !accessibleSubpaths.isEmpty {
                    message = "Full volume access verified at '\(targetURL.path)' in XPC process. Found \(rootItems.count) root items, and \(accessibleSubpaths.count) common directories are readable."
                } else {
                    message = "Volume access verified at '\(targetURL.path)' in XPC process. Found \(rootItems.count) items."
                }
            } else {
                message = "Volume access test failed for '\(targetURL.path)' in XPC process. The directory could not be enumerated or read."
            }
        }

        return IngestVolumeAccessTestResult(
            isAccessible: isOverallAccessible,
            testedPath: targetURL.path,
            rootItemsCount: rootItems.count,
            accessibleSubpaths: accessibleSubpaths,
            inaccessibleSubpaths: inaccessibleSubpaths,
            sourcePathResults: sourceResults,
            message: message,
            isSecurityScoped: isSecurityScoped
        )
    }

    private func detectTCCCategory(slug: String, path: String) -> String? {
        let lowerSlug = slug.lowercased()
        let lowerPath = GarageAppGroup.expandingTilde(in: path).lowercased()

        if lowerSlug == "apple-sms" || lowerSlug == "sms" || lowerSlug == "messages" || lowerSlug == "imessage"
            || lowerPath.contains("/library/messages") || lowerPath.hasSuffix("/messages") {
            return "apple-sms"
        }
        if lowerSlug == "apple-mail" || lowerSlug == "mail" || lowerSlug == "maildir"
            || lowerPath.contains("/library/mail") || lowerPath.hasSuffix("/mail") {
            return "apple-mail"
        }
        if lowerSlug == "documents" || lowerPath.contains("/documents") {
            return "documents"
        }
        if lowerSlug == "downloads" || lowerPath.contains("/downloads") {
            return "downloads"
        }
        if lowerSlug == "desktop" || lowerPath.contains("/desktop") {
            return "desktop"
        }
        return nil
    }

    private func tccHelpMessage(category: String?) -> String? {
        switch category {
        case "apple-sms":
            return "macOS keeps Messages (~/Library/Messages) behind Full Disk Access, so Garage can't index your SMS and iMessage history without it, even if you choose the folder. Turn on Garage in System Settings → Privacy & Security → Full Disk Access, then quit and reopen Garage. The App Store version then also needs access to ~/Library/Messages, or your startup disk, granted on the Sources page."
        case "apple-mail":
            return "macOS keeps Mail (~/Library/Mail) behind Full Disk Access, so Garage can't index your email without it, even if you choose the folder. Turn on Garage in System Settings → Privacy & Security → Full Disk Access, then quit and reopen Garage. The App Store version then also needs access to ~/Library/Mail, or your startup disk, granted on the Sources page."
        case "documents":
            return "Permission to access your Documents directory is required to index local documents."
        case "downloads":
            return "Permission to access your Downloads directory is required to index downloaded items."
        case "desktop":
            return "Permission to access your Desktop directory is required to index desktop files."
        default:
            return nil
        }
    }
}
