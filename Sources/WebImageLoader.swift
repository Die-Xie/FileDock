import Foundation

/// Fetches a dropped web image without writing files or sharing browser credentials.
@MainActor enum HubWebImageLoader {
    @discardableResult
    static func fetch(url: URL, completion: @escaping (Result<Data, Error>) -> Void) -> URLSessionDataTask? {
        guard HubImageDownload.validURL(url) else {
            completion(.failure(HubImageDownloadError.invalidURL))
            return nil
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let delegate = HubImageDownload(completion: completion)
        let queue = OperationQueue()
        queue.name = "FolderHubReplica.WebImageDownload"
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        delegate.session = session
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        task.resume()
        return task
    }
}

private enum HubImageDownloadError: LocalizedError {
    case invalidURL, invalidResponse, notImage, tooLarge, redirectLimit, emptyImage
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "图片地址必须是有效的 HTTP 或 HTTPS 地址，且不能包含登录凭据。"
        case .invalidResponse: return "图片服务器未返回成功响应。"
        case .notImage: return "此地址没有返回图片。"
        case .tooLarge: return "图片超过 32 MiB，未保存。"
        case .redirectLimit: return "图片地址重定向次数过多。"
        case .emptyImage: return "图片服务器返回了空内容。"
        }
    }
}

/// All mutable download state is confined to the session's serial delegate queue.
private final class HubImageDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let limit = 32 * 1024 * 1024
    var session: URLSession?
    private var data = Data()
    private var redirects = 0
    private var finished = false
    private let completion: (Result<Data, Error>) -> Void

    init(completion: @escaping (Result<Data, Error>) -> Void) { self.completion = completion }

    static func validURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            completionHandler(.cancel); finish(.failure(HubImageDownloadError.invalidResponse)); return
        }
        guard response.mimeType?.lowercased().hasPrefix("image/") == true else {
            completionHandler(.cancel); finish(.failure(HubImageDownloadError.notImage)); return
        }
        guard response.expectedContentLength <= Self.limit else {
            completionHandler(.cancel); finish(.failure(HubImageDownloadError.tooLarge)); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard !finished else { return }
        guard chunk.count <= Self.limit - data.count else {
            dataTask.cancel(); finish(.failure(HubImageDownloadError.tooLarge)); return
        }
        data.append(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard !finished else { completionHandler(nil); return }
        redirects += 1
        guard redirects <= 5 else { completionHandler(nil); finish(.failure(HubImageDownloadError.redirectLimit)); return }
        guard let url = request.url, Self.validURL(url) else { completionHandler(nil); finish(.failure(HubImageDownloadError.invalidURL)); return }
        var clean = URLRequest(url: url)
        clean.cachePolicy = .reloadIgnoringLocalCacheData
        clean.timeoutInterval = 20
        clean.setValue("image/*", forHTTPHeaderField: "Accept")
        completionHandler(clean)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Retain normal TLS trust validation; never answer HTTP or proxy credential challenges.
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error { finish(.failure(error)) }
        else if data.isEmpty { finish(.failure(HubImageDownloadError.emptyImage)) }
        else { finish(.success(data)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        data = Data()
        session?.invalidateAndCancel()
        session = nil
        DispatchQueue.main.async { [completion] in completion(result) }
    }
}
