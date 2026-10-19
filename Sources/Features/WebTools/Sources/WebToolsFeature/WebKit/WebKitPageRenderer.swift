// WebKit rendering (Apple platforms only)

import ToolCore
import Foundation
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

@MainActor
final class WebKitPageRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let requestPolicy: WebNetworkRequestPolicy
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var didResume = false
    private var timeoutTask: Task<Void, Never>?

    private init(requestPolicy: WebNetworkRequestPolicy) {
        self.requestPolicy = requestPolicy
        let configuration = WKWebViewConfiguration()
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1365, height: 900), configuration: configuration)
        super.init()
        self.webView.navigationDelegate = self
        self.webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) ZenCODE/1.0"
    }

    static func render(
        url: URL,
        timeout: TimeInterval,
        requestPolicy: WebNetworkRequestPolicy
    ) async throws -> RenderedPage {
        let renderer = WebKitPageRenderer(requestPolicy: requestPolicy)
        return try await renderer.load(url: url, timeout: timeout)
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

        try await waitUntilSettled(timeout: settleBudget)

        let title = (try? await evaluateString("document.title")) ?? ""
        let finalURL = (try? await evaluateString("location.href")) ?? url.absoluteString
        let markdown = try await evaluateString(WebKitPageRenderer.extractionJS)
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
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(javaScript) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let string = value as? String {
                    continuation.resume(returning: string)
                } else if let value {
                    continuation.resume(returning: String(describing: value))
                } else {
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// Server and client navigations must pass the same public-network policy
    /// as the initial request. This is what stops a public page from
    /// redirecting the main frame into loopback or a metadata endpoint.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        Task { @MainActor in
            do {
                guard navigationAction.targetFrame?.isMainFrame == true else {
                    decisionHandler(.allow)
                    return
                }
                try await requestPolicy.validateRequestURLOffloaded(navigationAction.request.url?.absoluteString ?? "")
                decisionHandler(.allow)
            } catch {
                decisionHandler(.cancel)
                resume(.failure(error))
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
        resume(.failure(error))
    }

    static let extractionJS = #"""
    (() => {
      const clean = s => (s || '').replace(/\s+/g, ' ').trim();
      const visible = el => {
        const r = el.getBoundingClientRect();
        const st = getComputedStyle(el);
        return r.width > 0 && r.height > 0 &&
          st.display !== 'none' && st.visibility !== 'hidden' && st.opacity !== '0';
      };
      const lines = [
        '# ' + (clean(document.title) || location.href),
        '',
        'URL: ' + location.href,
        '',
        '## Content'
      ];
      const blocks = [...document.body.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,pre,blockquote,td,th')];
      const seen = new Set();
      for (const el of blocks) {
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
        lines.push('', s);
        if (lines.join('\n').length > 400000) { lines.push('', '[Content truncated by extractor.]'); break; }
      }
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
