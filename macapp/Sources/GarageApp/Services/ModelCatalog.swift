import Foundation
import OSLog
import PythonXPCService

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "me.rickmark.garage-rag", category: "ModelCatalog")

/// Keeps the model catalog (`models.json`) current between releases.
///
/// The website serves a copy of the repository's `data/models/models.json`. At launch the app fetches it and,
/// when it decodes as a catalog with presets, saves it in the data folder, where `Paths.modelsJSON`
/// (and so the presets and `GARAGE_MODEL_MANIFEST` for Python) prefers it to the bundled copy.
/// Offline, a bad reply or a file that does not decode keeps whatever copy is already in use; the
/// bundled catalog is the fallback when nothing has been fetched.
enum ModelCatalog {
    static let remoteURL = URL(string: "https://garagerag.app/.data/models.json")!
    /// Whether the app fetches the catalog at launch (default on); UI tests turn it off.
    static let refreshAtLaunchDefaultsKey = "garage.modelCatalog.refreshAtLaunch"

    /// Where a fetched catalog is saved.
    static var fetchedURL: URL { GarageAppGroup.fetchedModelCatalog }

    /// Fetches the catalog from `url` and saves it at `destination` when it is usable and differs
    /// from what is saved there. Returns whether the saved catalog changed.
    @discardableResult
    static func refresh(
        from url: URL = remoteURL,
        to destination: URL = fetchedURL,
        session: URLSession = .shared
    ) async -> Bool {
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.info("Model catalog not updated: \(url.absoluteString, privacy: .public) answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return false
            }
            guard GarageConfigLoader.isUsableModelCatalog(data) else {
                logger.error("Model catalog not updated: \(url.absoluteString, privacy: .public) is not a usable models.json")
                return false
            }
            if let saved = try? Data(contentsOf: destination), saved == data {
                return false
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            logger.info("Model catalog updated from \(url.absoluteString, privacy: .public)")
            return true
        } catch {
            logger.info("Model catalog not updated: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
