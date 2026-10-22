// WebKit rendering (Apple platforms only)

import ToolCore
import Foundation
import Synchronization
#if canImport(WebKit)
import WebKit
#endif
import FeatureKit

#if canImport(WebKit)

struct RenderedPage: Sendable {
    let finalURL: String
    let title: String
    let markdown: String
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
        self.webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) ZenCODE/1.0"
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
        var markdown = try await evaluateString(WebKitPageRenderer.extractionJS)
        try checkAborted()
        if blockedSubframeCount > 0 {
            markdown += "\n\n[\(blockedSubframeCount) embedded frame(s) pointing at non-public hosts were not loaded.]"
        }
        return RenderedPage(finalURL: finalURL, title: title, markdown: markdown)
    }

    /// Polls until the page is ready and its rendered text length stops growing.
    private func waitUntilSettled(timeout: TimeInterval) async throws {
        let start = Date()
        let deadline = start.addingTimeInterval(min(timeout, 6))
        let pollInterval: UInt64 = 200_000_000 // 200 ms
        let minSettle: TimeInterval = 0.8
        let requiredStableChecks = 2
        var lastLength = -1
        var stableChecks = 0

        try await Task.sleep(nanoseconds: pollInterval)

        while Date() < deadline {
            try Task.checkCancellation()
            try checkAborted()
            let ready = (try? await evaluateString("document.readyState")) ?? ""
            let lengthString = (try? await evaluateString(
                "String(((document.body && document.body.innerText) || '').length)"
            )) ?? "0"
            let length = Int(lengthString) ?? 0
            let isReady = ready == "complete" || ready == "interactive"

            if isReady, length > 0, length == lastLength {
                stableChecks += 1
                if stableChecks >= requiredStableChecks,
                   Date().timeIntervalSince(start) >= minSettle {
                    return
                }
            } else {
                stableChecks = 0
            }
            lastLength = length
            try await Task.sleep(nanoseconds: pollInterval)
        }
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

    /// Visible-content extractor. Output is accumulated as a byte budget
    /// instead of re-joining the whole array on every block, so a page with
    /// tens of thousands of blocks stays linear.
    static let extractionJS = #"""
    (() => {
      const LIMIT = 400000;
      const clean = s => (s || '').replace(/\s+/g, ' ').trim();
      const visible = el => {
        const r = el.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) return false;
        const st = getComputedStyle(el);
        return st.display !== 'none' && st.visibility !== 'hidden' && st.opacity !== '0';
      };
      const lines = [
        '# ' + (clean(document.title) || location.href),
        '',
        'URL: ' + location.href,
        '',
        '## Content'
      ];
      let size = lines.reduce((n, l) => n + l.length + 1, 0);
      const push = s => { lines.push('', s); size += s.length + 2; };
      const blocks = document.body ? document.body.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,pre,blockquote,td,th') : [];
      const seen = new Set();
      let truncated = false;
      for (const el of blocks) {
        if (size > LIMIT) { truncated = true; break; }
        if (el.closest('script,style,noscript,template')) continue;
        if (!visible(el)) continue;
        const tag = el.tagName;
        let s = '';
        if (/^H[1-6]$/.test(tag)) s = '#'.repeat(Number(tag[1])) + ' ' + clean(el.innerText);
        else if (tag === 'LI') s = '- ' + clean(el.innerText);
        else if (tag === 'PRE') s = '```\n' + (el.innerText || '').replace(/\s+$/, '') + '\n```';
        else if (tag === 'BLOCKQUOTE') s = '> ' + clean(el.innerText);
        else s = clean(el.innerText);
        s = s.trim();
        if (!s || seen.has(s)) continue;
        seen.add(s);
        push(s);
      }
      if (truncated) push('[Content truncated by extractor.]');
      lines.push('', '## Visible links');
      let n = 0;
      const linkSeen = new Set();
      for (const a of document.querySelectorAll('a[href]')) {
        if (!visible(a)) continue;
        const text = clean(a.innerText || a.textContent);
        if (text.length < 3) continue;
        let u;
        try { u = new URL(a.href); } catch (e) { continue; }
        if (!/^https?:$/.test(u.protocol) || linkSeen.has(u.href)) continue;
        linkSeen.add(u.href);
        lines.push('- [' + text.slice(0, 160) + '](' + u.href + ')');
        if (++n >= 80) break;
      }
      return lines.join('\n');
    })()
    """#
}

#endif
