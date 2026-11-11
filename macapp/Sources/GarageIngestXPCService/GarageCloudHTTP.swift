import Foundation

/// A cloud source's API over HTTPS (`garage_ingest.h`'s `http`): exactly the URL the ingest library
/// approved (Dropbox's two API origins, Microsoft Graph and the content hosts Graph redirects a OneDrive
/// download to), with no proxy, cookies or cache, and a redirect returned rather than followed. Nothing
/// here logs a request: its headers carry the token.
enum GarageCloudHTTP {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: false,
            kCFNetworkProxiesHTTPSEnable as String: false,
            kCFNetworkProxiesSOCKSEnable as String: false,
            kCFNetworkProxiesProxyAutoConfigEnable as String: false,
        ]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
    }()

    /// The hosts the library sends to; anything else is refused here too.
    static let allowedHosts: Set<String> = ["api.dropboxapi.com", "content.dropboxapi.com", "graph.microsoft.com", "www.googleapis.com"]

    /// The domains of the pre-authenticated URLs Graph redirects a OneDrive download to (the library
    /// sends no token there): the domain itself or any host below it.
    static let allowedDomains = ["sharepoint.com", "1drv.com", "livefilestore.com", "microsoftpersonalcontent.com"]

    /// Whether `host` (lower case) is one the library may send to.
    static func isAllowed(host: String) -> Bool {
        allowedHosts.contains(host) || allowedDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `{"method", "url", "headers": [[name, value]], "body_base64", "timeout_seconds"}` ->
    /// `{"status", "headers": [[name, value]], "body_base64"}`.
    static func send(_ object: [String: Any]) throws -> [String: Any] {
        guard
            let text = object["url"] as? String,
            let url = URL(string: text),
            url.scheme == "https",
            let host = url.host?.lowercased(),
            isAllowed(host: host),
            url.port == nil,
            url.user == nil
        else {
            throw Failure(message: "the ingest library asked for a URL that is not a cloud source's API")
        }
        var request = URLRequest(url: url)
        request.httpMethod = object["method"] as? String ?? "POST"
        request.timeoutInterval = (object["timeout_seconds"] as? Double).map { max($0, 1) } ?? 60
        for pair in object["headers"] as? [[String]] ?? [] where pair.count == 2 {
            request.setValue(pair[1], forHTTPHeaderField: pair[0])
        }
        if let body = object["body_base64"] as? String, !body.isEmpty {
            guard let data = Data(base64Encoded: body) else { throw Failure(message: "the request body is not base64") }
            request.httpBody = data
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = SendBox()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else if let response = response as? HTTPURLResponse {
                box.result = .success((response, data ?? Data()))
            } else {
                box.result = .failure(URLError(.badServerResponse))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        let (response, data) = try (box.result ?? .failure(URLError(.unknown))).get()
        // Only what the library reads; the rest stays here.
        let wanted = ["retry-after", "dropbox-api-result", "content-type", "location"]
        let headers: [[String]] = response.allHeaderFields.compactMap { key, value in
            guard let name = key as? String, wanted.contains(name.lowercased()) else { return nil }
            return [name, "\(value)"]
        }
        return ["status": response.statusCode, "headers": headers, "body_base64": data.base64EncodedString()]
    }

    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    /// Written once by the completion handler, read after the semaphore: no lock needed.
    private final class SendBox: @unchecked Sendable {
        var result: Result<(HTTPURLResponse, Data), Error>?
    }
}
