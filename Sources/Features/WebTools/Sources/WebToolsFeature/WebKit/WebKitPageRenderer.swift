// WebKit rendering (Apple platforms only)

import ToolCore
import Foundation
import Synchronization
#if canImport(WebKit)
import WebKit
#endif
import FeatureKit

/// Failures of the rendered path that send the tool to the raw path.
enum WebRenderError: LocalizedError, Equatable, Sendable {
    /// The main document is not an HTML page (JSON, PDF, text, XML, ...);
    /// WebKit would only show it in a viewer, so the raw path extracts it.
    case nonHTMLContent(mimeType: String, statusCode: Int?)

    var errorDescription: String? {
        switch self {
        case let .nonHTMLContent(mimeType, statusCode):
            let status = statusCode.map { " (HTTP \($0))" } ?? ""
            return "The main document is \(mimeType)\(status), not HTML; it was not rendered in WebKit."
        }
    }
}

#if canImport(WebKit)

struct RenderedPage: Sendable {
    let finalURL: String
    let title: String
    /// `document.documentElement.outerHTML` after rendering, with elements
    /// hidden by computed style marked `hidden`, cut at
    /// ``WebKitPageRenderer/maxHTMLLength`` UTF-16 code units.
    let html: String
    let htmlWasCut: Bool
    /// HTTP status and MIME type of the main-frame response, when known.
    let statusCode: Int?
    let mimeType: String?
    let blockedSubframeCount: Int
}

/// Compiles the content rule list from ``WebContentBlockerRules`` once per
/// process and caches it. Compilation happens on the main actor (WebKit
/// requirement) in a UUID-named directory under the system temporary
/// directory, created once per process (retries after a failure reuse it)
/// and removed at process exit. Every renderer waits for the same compilation
/// and receives the same ``WebNetworkGuardError/contentBlockerUnavailable(_:)``
/// on failure, so a failure is observed consistently and never races with a
/// successful render.
@MainActor
enum WebContentRuleListProvider {
    static let compilationTimeout: TimeInterval = 10
    static let identifier = "zencode-webtools-nonpublic-destinations"

    private static var cached: WKContentRuleList?
    private static var inFlight: Task<WKContentRuleList, Error>?
    /// Read by the `atexit` handler, which may run on any thread.
    private static nonisolated let storeDirectory = Mutex<URL?>(nil)

    static func ruleList() async throws -> WKContentRuleList {
        if let cached { return cached }
        if let inFlight { return try await inFlight.value }
        // The wrapping happens inside the shared task so that every waiter,
        // not only the caller that started the compilation, sees
        // `contentBlockerUnavailable` and can fall back to the raw path.
        let task = Task<WKContentRuleList, Error> { @MainActor in
            do {
                let list = try await compile()
                cached = list
                return list
            } catch {
                throw WebNetworkGuardError.contentBlockerUnavailable(error.localizedDescription)
            }
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    /// The per-process store directory, created on first use and reused by
    /// later compilation attempts so failed attempts never leak directories.
    private static func ensureStoreDirectory() throws -> URL {
        if let existing = storeDirectory.withLock({ $0 }) { return existing }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-webtools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storeDirectory.withLock { $0 = directory }
        Self.installExitCleanupOnce()
        return directory
    }

    private static func compile() async throws -> WKContentRuleList {
        let directory = try ensureStoreDirectory()

        guard let store = WKContentRuleListStore(url: directory) else {
            throw WebToolsFeatureError.permissionDenied("WKContentRuleListStore could not be created at \(directory.path).")
        }
        let encoded = try WebContentBlockerRules.encodedRuleList()
        let box = WebSingleResumeBox<WKContentRuleList>()
        let timeout = Task(name: "WebTools.rule-list-compile-timeout") {
            try? await Task.sleep(nanoseconds: UInt64(compilationTimeout * 1_000_000_000))
            box.resume(throwing: WebToolsFeatureError.permissionDenied(
                "Timed out compiling the content rule list after \(Int(compilationTimeout))s."
            ))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            box.attach(continuation)
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: encoded) { list, error in
                if let error {
                    box.resume(throwing: error)
                } else if let list {
                    box.resume(returning: list)
                } else {
                    box.resume(throwing: WebToolsFeatureError.permissionDenied("The content rule list compiled to nothing."))
                }
            }
        }
    }

    private static var exitCleanupInstalled = false

    /// The store directory lives only as long as the process; `atexit` runs
    /// on normal termination, and the temporary directory is reaped by the
    /// system otherwise.
    private static func installExitCleanupOnce() {
        guard !exitCleanupInstalled else { return }
        exitCleanupInstalled = true
        atexit {
            if let directory = WebContentRuleListProvider.storeDirectory.withLock({ $0 }) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }
}

@MainActor
final class WebKitPageRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let requestPolicy: WebNetworkRequestPolicy
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var didResume = false
    private var timeoutTask: Task<Void, Never>?
    /// Set when a subframe navigation was refused; reported alongside the
    /// page so callers know part of the content was withheld.
    private(set) var blockedSubframeCount = 0
    /// Recorded from the main-frame navigation response.
    private var mainFrameStatusCode: Int?
    private var mainFrameMIMEType: String?

    private init(requestPolicy: WebNetworkRequestPolicy, ruleList: WKContentRuleList?) {
        self.requestPolicy = requestPolicy
        let configuration = WKWebViewConfiguration()
        // Nothing from a fetched page (cookies, storage, cache) survives the
        // tool invocation or leaks into another one.
        configuration.websiteDataStore = .nonPersistent()
        if let ruleList {
            configuration.userContentController.add(ruleList)
        }
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1365, height: 900), configuration: configuration)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.customUserAgent = WebToolsSupport.userAgent
    }

    /// Renders `url`, never exceeding `timeout` overall (navigation, settle
    /// polling and extraction included). Fails closed when the content rule
    /// list that confines subresource loads to public hosts is unavailable.
    /// Under the explicit host-level private-network opt-in the rule list is
    /// not installed: the opt-in exists precisely to reach such hosts.
    static func render(
        url: URL,
        timeout: TimeInterval,
        requestPolicy: WebNetworkRequestPolicy
    ) async throws -> RenderedPage {
        let ruleList = requestPolicy.urlPolicy.allowsPrivateNetwork
            ? nil
            : try await WebContentRuleListProvider.ruleList()
        let renderer = WebKitPageRenderer(requestPolicy: requestPolicy, ruleList: ruleList)
        defer { renderer.tearDown() }
        // Overall deadline: navigation, settle polling and extraction together
        // never exceed `timeout`, whatever the page does.
        let deadline = Task(name: "WebTools.render-deadline") { @MainActor [weak renderer] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            renderer?.abort(with: WebToolsFeatureError.permissionDenied(
                "Timed out rendering the page after \(Int(timeout))s."
            ))
        }
        defer { deadline.cancel() }
        return try await renderer.load(url: url, timeout: timeout)
    }

    private var abortError: (any Error)?
    /// Evaluations in flight, resumed with the abort error on deadline so a
    /// slow script cannot hold the render past its budget.
    private var pendingEvaluations: [ObjectIdentifier: WebSingleResumeBox<String>] = [:]

    /// Stops everything in flight and makes the pending phase (navigation,
    /// settle polling or extraction) throw `error`.
    private func abort(with error: any Error) {
        abortError = error
        webView.stopLoading()
        resume(.failure(error))
        let pending = pendingEvaluations.values
        pendingEvaluations.removeAll()
        for box in pending {
            box.resume(throwing: error)
        }
    }

    private func checkAborted() throws {
        if let abortError { throw abortError }
    }

    private func tearDown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private func load(url: URL, timeout: TimeInterval) async throws -> RenderedPage {
        let navigationBudget = timeout * 0.6
        let settleBudget = min(timeout - navigationBudget, 6)

        // Cancellation stops the web view and resumes the continuation; `resume(_:)` is exactly-once.
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.loadContinuation = continuation
                self.didResume = false
                self.timeoutTask = Task(name: "WebTools.navigation-timeout") { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(navigationBudget * 1_000_000_000))
                    self?.resume(.failure(WebToolsFeatureError.permissionDenied(
                        "Timed out loading the page after \(Int(navigationBudget))s."
                    )))
                }
                self.webView.load(URLRequest(url: url))
            }
        } onCancel: {
            Task(name: "WebTools.navigation-cancellation") { @MainActor [weak self] in
                self?.webView.stopLoading()
                self?.resume(.failure(CancellationError()))
            }
        }
        try Task.checkCancellation()
        try checkAborted()

        try await waitUntilSettled(timeout: settleBudget)
        try checkAborted()

        let title = (try? await evaluateString("document.title")) ?? ""
        let finalURL = (try? await evaluateString("location.href")) ?? url.absoluteString
        let html = try await evaluateString(WebKitPageRenderer.extractionJS)
        try checkAborted()
        return RenderedPage(
            finalURL: finalURL,
            title: title,
            html: html,
            htmlWasCut: html.utf16.count >= Self.maxHTMLLength,
            statusCode: mainFrameStatusCode,
            mimeType: mainFrameMIMEType,
            blockedSubframeCount: blockedSubframeCount
        )
    }

    /// Polls until the page is ready and its rendered text length stops
    /// growing. One script per poll reports both values. A complete document
    /// may return after one stable check once ``quickSettle`` elapsed;
    /// otherwise two stable checks and ``minSettle`` are required.
    private func waitUntilSettled(timeout: TimeInterval) async throws {
        let start = Date()
        let deadline = start.addingTimeInterval(min(timeout, 6))
        let pollInterval: UInt64 = 200_000_000 // 200 ms
        var lastLength = -1
        var stableChecks = 0

        try await Task.sleep(nanoseconds: pollInterval)

        while Date() < deadline {
            try Task.checkCancellation()
            try checkAborted()
            let probe = Self.parseSettleProbe((try? await evaluateString(Self.settleProbeJS)) ?? "")
            let isReady = probe.readyState == "complete" || probe.readyState == "interactive"

            if isReady, probe.textLength > 0, probe.textLength == lastLength {
                stableChecks += 1
                if Self.isSettled(
                    readyState: probe.readyState,
                    stableChecks: stableChecks,
                    elapsed: Date().timeIntervalSince(start)
                ) {
                    return
                }
            } else {
                stableChecks = 0
            }
            lastLength = probe.textLength
            try await Task.sleep(nanoseconds: pollInterval)
        }
    }

    nonisolated static let minSettle: TimeInterval = 0.8
    nonisolated static let quickSettle: TimeInterval = 0.5
    nonisolated static let requiredStableChecks = 2

    nonisolated static func isSettled(readyState: String, stableChecks: Int, elapsed: TimeInterval) -> Bool {
        if readyState == "complete", stableChecks >= 1, elapsed >= quickSettle {
            return true
        }
        return stableChecks >= requiredStableChecks && elapsed >= minSettle
    }

    /// `readyState|innerTextLength`, read in one evaluation per poll.
    nonisolated static let settleProbeJS =
        "(document.readyState || '') + '|' + String(((document.body && document.body.innerText) || '').length)"

    nonisolated static func parseSettleProbe(_ value: String) -> (readyState: String, textLength: Int) {
        guard let separator = value.lastIndex(of: "|") else { return ("", 0) }
        return (String(value[..<separator]), Int(value[value.index(after: separator)...]) ?? 0)
    }

    private func resume(_ result: Result<Void, Error>) {
        guard !didResume else { return }
        didResume = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = loadContinuation
        loadContinuation = nil
        switch result {
        case .success:
            continuation?.resume()
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    private func evaluateString(_ javaScript: String) async throws -> String {
        try checkAborted()
        let box = WebSingleResumeBox<String>()
        let key = ObjectIdentifier(box)
        pendingEvaluations[key] = box
        defer { pendingEvaluations[key] = nil }
        return try await withCheckedThrowingContinuation { continuation in
            box.attach(continuation)
            webView.evaluateJavaScript(javaScript) { value, error in
                if let error {
                    box.resume(throwing: error)
                } else if let string = value as? String {
                    box.resume(returning: string)
                } else if let value {
                    box.resume(returning: String(describing: value))
                } else {
                    box.resume(returning: "")
                }
            }
        }
    }

    /// Decision for a navigation action, factored out so it can be unit
    /// tested without a live WKWebView: a refused main-frame navigation
    /// fails the whole render with the policy error, a refused subframe
    /// navigation only cancels that frame. A navigation without a target
    /// frame (window.open) is treated like a subframe: it can never become
    /// the rendered document, but it must not reach a non-public host either.
    enum NavigationDecision: Sendable {
        case allow
        case cancelMainFrame(any Error)
        case cancelSubframe

        var isAllowed: Bool {
            if case .allow = self { return true }
            return false
        }
    }

    nonisolated static func decide(
        url rawURL: String,
        isMainFrame: Bool,
        policy: WebNetworkRequestPolicy
    ) async -> NavigationDecision {
        // `about:blank`, `about:srcdoc`, `data:` and `blob:` subframes have no
        // network destination of their own; their subresources are still
        // filtered by the content rule list and their later navigations come
        // back through this decision.
        if !isMainFrame, let scheme = URLComponents(string: rawURL)?.scheme?.lowercased(),
           ["about", "data", "blob"].contains(scheme) {
            return .allow
        }
        do {
            try await policy.validateRequestURLOffloaded(rawURL)
            return .allow
        } catch {
            return isMainFrame ? .cancelMainFrame(error) : .cancelSubframe
        }
    }

    /// Server and client navigations, in the main frame and in every
    /// subframe, must pass the same public-network policy as the initial
    /// request. This is what stops a public page from redirecting the main
    /// frame into loopback or a metadata endpoint, or embedding such a host
    /// in an iframe. Subresource loads never reach this delegate; the
    /// content rule list installed at construction covers them for literal
    /// non-public hosts (DNS-rebound public names are out of scope there).
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        Task { @MainActor in
            let rawURL = navigationAction.request.url?.absoluteString ?? ""
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
            switch await Self.decide(url: rawURL, isMainFrame: isMainFrame, policy: requestPolicy) {
            case .allow:
                decisionHandler(.allow)
            case let .cancelMainFrame(error):
                decisionHandler(.cancel)
                resume(.failure(error))
            case .cancelSubframe:
                decisionHandler(.cancel)
                blockedSubframeCount += 1
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(.success(()))
    }

    /// Decision for a navigation response, factored out for unit tests:
    /// subframes always load (their requests already passed the navigation
    /// policy); a main-frame document that is not an HTML page fails the
    /// render so the tool extracts it through the raw path instead.
    enum ResponseDecision: Sendable, Equatable {
        case allow
        case cancelMainFrame(WebRenderError)
    }

    nonisolated static func decideResponse(mimeType: String?, statusCode: Int?, isMainFrame: Bool) -> ResponseDecision {
        guard isMainFrame, !WebFetchContent.isHTMLDocumentMIMEType(mimeType) else { return .allow }
        return .cancelMainFrame(.nonHTMLContent(
            mimeType: WebFetchContent.normalizedMIMEType(mimeType) ?? "unknown",
            statusCode: statusCode
        ))
    }

    /// Records the main-frame status (WebKit renders error pages, so a 4xx
    /// or 5xx is reported in the output instead of failing) and refuses
    /// non-HTML main documents.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        if navigationResponse.isForMainFrame {
            mainFrameStatusCode = statusCode
            mainFrameMIMEType = response.mimeType
        }
        switch Self.decideResponse(
            mimeType: response.mimeType,
            statusCode: statusCode,
            isMainFrame: navigationResponse.isForMainFrame
        ) {
        case .allow:
            decisionHandler(.allow)
        case let .cancelMainFrame(error):
            decisionHandler(.cancel)
            resume(.failure(error))
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resume(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A cancelled provisional navigation (NSURLErrorCancelled, code -999)
        // after a policy refusal is already reported through `resume`; any
        // other failure is the real cause.
        resume(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        resume(.failure(WebToolsFeatureError.permissionDenied("The WebKit content process terminated while rendering the page.")))
    }

    /// Upper bound, in UTF-16 code units, of the HTML handed to the converter.
    nonisolated static let maxHTMLLength = 8 * 1024 * 1024

    /// Marks every element the page hides by computed style (`display:none`
    /// or `visibility:hidden`) with the `hidden` attribute, which the Swift
    /// converter skips, then returns the serialized document. Styles are read
    /// for every element before any attribute is written, so the walk never
    /// forces a style recalculation per element. Box sizes are deliberately
    /// ignored: zero-size wrappers often hold visible, overflowing children.
    nonisolated static let extractionJS = #"""
    (() => {
      const LIMIT = \#(maxHTMLLength);
      if (document.body) {
        const hidden = [];
        for (const el of document.body.querySelectorAll('*')) {
          const style = getComputedStyle(el);
          if (style.display === 'none' || style.visibility === 'hidden') hidden.push(el);
        }
        for (const el of hidden) el.setAttribute('hidden', '');
      }
      const root = document.documentElement;
      const html = root ? root.outerHTML : '';
      return html.length > LIMIT ? html.slice(0, LIMIT) : html;
    })()
    """#
}

#endif
