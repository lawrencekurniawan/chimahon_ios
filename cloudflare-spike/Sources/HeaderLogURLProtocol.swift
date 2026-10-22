import Foundation
import WebKit

/// Header-logging URLProtocol (FEASIBILITY.md §11.4 spike evidence tool).
///
/// Registered *in front of* the system protocol for one host so we can see the
/// exact outgoing `Cookie:` + `User-Agent:` headers of a URLSession request.
/// Requests are forwarded to a private ephemeral session with an empty
/// protocolClasses list — otherwise the inner session would recurse into this
/// same protocol.
///
/// Note: when a custom protocol replaces the system HTTP protocol, the system
/// no longer attaches cookies, so this class replicates that behavior itself
/// from `HTTPCookieStorage.shared` (which is exactly the storage the spike
/// bridges WKWebView cookies into) — making the logged header a faithful
/// picture of what CFNetwork would send in the production client.
final class HeaderLogURLProtocol: URLProtocol {
    private(set) static var capturedHost: String?
    private(set) static var lastHeaders: [String: String]?
    private(set) static var lastURL: URL?
    private static let queue = DispatchQueue(label: "chimahon.headerlog")

    /// Inner session for forwarding: NO custom protocols (no recursion) and
    /// ephemeral storage (no double cookie handling).
    private static let forwardSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = []
        return URLSession(configuration: c)
    }()

    static func reset(host: String) {
        queue.sync {
            capturedHost = host
            lastHeaders = nil
            lastURL = nil
        }
    }

    static func captured() -> (host: String?, url: URL?, headers: [String: String]?) {
        queue.sync { (capturedHost, lastURL, lastHeaders) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return queue.sync { host == capturedHost }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var req = request
        // Replicate system-protocol cookie attachment for visibility.
        if let url = req.url,
           let cookies = HTTPCookieStorage.shared.cookies(for: url),
           !cookies.isEmpty {
            for (k, v) in HTTPCookie.requestHeaderFields(with: cookies) {
                req.setValue(v, forHTTPHeaderField: k)
            }
        }
        var headers: [String: String] = [:]
        req.allHTTPHeaderFields?.forEach { headers[$0.key.lowercased()] = $0.value }
        HeaderLogURLProtocol.queue.sync {
            if req.url?.host == HeaderLogURLProtocol.capturedHost {
                HeaderLogURLProtocol.lastHeaders = headers
                HeaderLogURLProtocol.lastURL = req.url
            }
        }

        let task = HeaderLogURLProtocol.forwardSession.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        task.resume()
    }

    override func stopLoading() {}
}
