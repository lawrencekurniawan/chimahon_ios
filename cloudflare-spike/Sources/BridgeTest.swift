import Foundation
import WebKit

/// Cloudflare cookie-bridge spike (FEASIBILITY.md §11.4 rung 2).
///
/// Proves end-to-end: WKWebView (real browser TLS/JS context) loads the target
/// site → cookies (`cf_clearance`, `__cf_bm`, session cookies…) harvested from
/// `WKWebsiteDataStore.default().httpCookieStore` → bridged into
/// `HTTPCookieStorage.shared` → URLSession reuses them **with the WebView's
/// exact User-Agent** (cf_clearance is UA+IP bound) → real API call succeeds.
///
/// Two probes hit the same endpoint:
///  - system path: plain URLSession (config: UA header + shared cookie storage)
///    — this is the production request path;
///  - logging path: HeaderLogURLProtocol captures the exact outgoing
///    Cookie/User-Agent headers as evidence.
final class BridgeTest: NSObject, WKNavigationDelegate {
    struct Verdict: Codable {
        var pass: Bool
        var target: String
        var finalURL: String?
        var loadFinished: Bool
        var loadError: String?
        var waitedSeconds: Double
        var cfClearanceFound: Bool
        var cookieNames: [String]
        var targetDomainCookies: [String]
        var userAgent: String?
        var apiURL: String?
        var apiStatus: Int?
        var apiJSONValid: Bool
        var apiBytes: Int
        var outgoingUA: String?
        var outgoingCookieHeaderHasAllTargetCookies: Bool
        var error: String?
    }

    static private var current: BridgeTest?

    static func run(target: String, settleSeconds: Double, completion: @escaping (Verdict) -> Void) {
        let runner = BridgeTest(target: target, settleSeconds: settleSeconds, completion: completion)
        current = runner
        runner.start()
    }

    private let target: String
    private let settleSeconds: Double
    private let completion: (Verdict) -> Void
    private var webView: WKWebView!
    private let startDate = Date()
    private var loadFinished = false
    private var loadError: String?
    private var pollTimer: Timer?
    private var watchdog: DispatchWorkItem?

    private init(target: String, settleSeconds: Double, completion: @escaping (Verdict) -> Void) {
        self.target = target
        self.settleSeconds = settleSeconds
        self.completion = completion
        super.init()
    }

    private func start() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default() // persistent: cf_clearance survives relaunches
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self

        let w = DispatchWorkItem { [weak self] in self?.finish(error: "watchdog timeout (90s)") }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: w)

        guard let url = URL(string: target) else {
            finish(error: "bad target URL: \(target)")
            return
        }
        webView.load(URLRequest(url: url))
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadFinished = true
        beginSettleCountdown()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadError = error.localizedDescription
        beginSettleCountdown() // still harvest whatever cookies exist
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if loadError == nil { loadError = error.localizedDescription }
        beginSettleCountdown()
    }

    // MARK: - Challenge settle window

    /// Cloudflare challenge JS (if any) runs after page load. Poll for
    /// `cf_clearance`; if it appears we proceed immediately, otherwise wait out
    /// the settle window and proceed with whatever cookies exist (site may have
    /// no wall at all — FEASIBILITY.md §11 probe).
    private func beginSettleCountdown() {
        guard pollTimer == nil else { return }
        let deadline = Date().addingTimeInterval(settleSeconds)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let cleared = cookies.contains { $0.name == "cf_clearance" }
                if cleared || Date() > deadline {
                    t.invalidate()
                    self.pollTimer = nil
                    self.harvest(webViewUserAgent: nil, remaining: cookies)
                }
            }
        }
    }

    // MARK: - Harvest + bridge + probes

    private func harvest(webViewUserAgent: String?, remaining: [HTTPCookie]) {
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] result, _ in
            guard let self else { return }
            let ua = result as? String
            // The cookies were already fetched by the poll; refresh once more to
            // catch any that arrived in the last interval.
            self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                self.bridge(cookies: cookies, ua: ua)
            }
        }
    }

    private func bridge(cookies: [HTTPCookie], ua: String?) {
        // The bridge itself: copy every WebView cookie into the storage URLSession reads.
        let storage = HTTPCookieStorage.shared
        for c in cookies { storage.setCookie(c) }

        let targetHost = URL(string: target)?.host ?? ""
        let targetDomainCookies = cookies.filter { $0.domain.hasSuffix(targetHost) }.map(\.name).sorted()
        let hasClearance = cookies.contains { $0.name == "cf_clearance" }

        // Pick the API probe: real chapter-list endpoint for nhattruyenqq,
        // otherwise just re-fetch the target itself.
        let apiURLString: String
        if targetHost.contains("nhattruyenqq") {
            apiURLString = "https://\(targetHost)/Comic/Services/ComicService.asmx/ChapterList?slug=fog-land"
        } else {
            apiURLString = target
        }

        HeaderLogURLProtocol.reset(host: URL(string: apiURLString)?.host ?? targetHost)
        let group = DispatchGroup()
        var apiStatus: Int?
        var apiJSONValid = false
        var apiBytes = 0

        // Probe 1 — production path (system protocol attaches cookies itself).
        let sysCfg = URLSessionConfiguration.default
        sysCfg.httpShouldSetCookies = true
        sysCfg.httpCookieAcceptPolicy = .always
        sysCfg.httpCookieStorage = storage
        if let ua { sysCfg.httpAdditionalHeaders = ["User-Agent": ua] }
        group.enter()
        URLSession(configuration: sysCfg).dataTask(with: URLRequest(url: URL(string: apiURLString)!)) { data, response, _ in
            apiStatus = (response as? HTTPURLResponse)?.statusCode
            apiBytes = data?.count ?? 0
            if let data,
               (try? JSONSerialization.jsonObject(with: data)) != nil {
                apiJSONValid = true
            }
            group.leave()
        }.resume()

        // Probe 2 — evidence path (captures exact outgoing headers).
        let logCfg = URLSessionConfiguration.default
        logCfg.httpShouldSetCookies = true
        logCfg.httpCookieAcceptPolicy = .always
        logCfg.httpCookieStorage = storage
        if let ua { logCfg.httpAdditionalHeaders = ["User-Agent": ua] }
        logCfg.protocolClasses = [HeaderLogURLProtocol.self] + (logCfg.protocolClasses ?? [])
        group.enter()
        URLSession(configuration: logCfg).dataTask(with: URLRequest(url: URL(string: apiURLString)!)) { _, _, _ in
            group.leave()
        }.resume()

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let captured = HeaderLogURLProtocol.captured()
            let outgoingUA = captured.headers?["user-agent"]
            let cookieHeader = captured.headers?["cookie"] ?? ""
            let missing = targetDomainCookies.filter { !cookieHeader.contains($0) }
            self.finish(
                error: nil,
                verdictPatch: { v in
                    v.finalURL = self.webView.url?.absoluteString
                    v.loadFinished = self.loadFinished
                    v.loadError = self.loadError
                    v.waitedSeconds = Date().timeIntervalSince(self.startDate)
                    v.cfClearanceFound = hasClearance
                    v.cookieNames = cookies.map(\.name).sorted()
                    v.targetDomainCookies = targetDomainCookies
                    v.userAgent = ua
                    v.apiURL = apiURLString
                    v.apiStatus = apiStatus
                    v.apiJSONValid = apiJSONValid
                    v.apiBytes = apiBytes
                    v.outgoingUA = outgoingUA
                    v.outgoingCookieHeaderHasAllTargetCookies = !targetDomainCookies.isEmpty && missing.isEmpty
                }
            )
        }
    }

    // MARK: - Verdict

    private func finish(error: String?, verdictPatch: ((inout Verdict) -> Void)? = nil) {
        watchdog?.cancel()
        var v = Verdict(
            pass: false,
            target: target,
            finalURL: nil,
            loadFinished: loadFinished,
            loadError: loadError,
            waitedSeconds: Date().timeIntervalSince(startDate),
            cfClearanceFound: false,
            cookieNames: [],
            targetDomainCookies: [],
            userAgent: nil,
            apiURL: nil,
            apiStatus: nil,
            apiJSONValid: false,
            apiBytes: 0,
            outgoingUA: nil,
            outgoingCookieHeaderHasAllTargetCookies: false,
            error: error
        )
        verdictPatch?(&v)
        // Pass = the mechanism works: page loaded, target-domain cookies flow
        // into the outgoing URLSession request, UA matches the WebView, and the
        // real API answers 200 with JSON. cfClearanceFound is informational
        // (site may have no active wall — §11).
        v.pass = v.loadFinished
            && v.apiStatus == 200
            && v.apiJSONValid
            && (v.userAgent != nil ? v.userAgent == v.outgoingUA : true)
            && v.outgoingCookieHeaderHasAllTargetCookies
        BridgeTest.current = nil
        completion(v)
    }
}
