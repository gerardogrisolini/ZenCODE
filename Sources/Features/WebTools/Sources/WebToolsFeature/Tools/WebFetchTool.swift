import ToolCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(WebKit)
import WebKit
#endif
import FeatureKit

struct WebFetchTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let url: String?
        let maxBytes: Int?
        let timeoutSeconds: Int?
        var format: String? = nil
        var offset: Int? = nil
        var includeLinks: Bool? = nil
        var mainContentOnly: Bool? = nil
        var selector: String? = nil
        var render: String? = nil
    }

    static let name = "web.fetch"
    static let description = "Fetches an HTTP or HTTPS URL restricted to public network destinations and returns its content "
        + "as Markdown (default), plain text, or HTML, after a header of 'name: value' lines: note (zero or more: fallbacks, "
        + "cuts), url (final), status, title, engine, content-type, scope (HTML conversions), pages and bytes (PDF, binary), "
        + "length, range (when only part of the content is returned), and description (page meta description). "
        + "HTML pages are converted with navigation, sidebars, and footers removed; on macOS they "
        + "are first rendered in a silent offscreen WebKit view (JavaScript executed), elsewhere fetched raw. JSON and "
        + "text are returned as is, PDF text is extracted on macOS. Long content is read in several calls with offset. "
        + "Private, loopback, link-local, and otherwise non-public destinations are rejected, including redirect "
        + "chains that resolve to them."
    static let inputSchema = buildInputSchema(
        [
            .string("url", description: "HTTP or HTTPS URL of a public web page or file."),
            .number("maxBytes", description: "Byte budget (UTF-8) for the returned content, not counting the header lines and the Links section. Defaults to 120000, clamped to 1024-1000000. Longer content is cut at a UTF-8 character (scalar) boundary and ends with a hint giving the offset to continue from."),
            .number("timeoutSeconds", description: "Time limit in seconds for loading (and rendering) the page. Defaults to 20, clamped to 1-120. When WebKit hands over to the raw path, the fallback keeps at least 5 s, so the total can exceed the limit by up to 5 s."),
            .string("format", enumValues: WebFetchFormat.allCases.map(\.rawValue), description: "markdown (default): headings, lists, tables, and links as Markdown. text: plain text without markup. html: the HTML as received (raw) or as rendered after JavaScript (elements hidden by CSS carry a hidden attribute added by the renderer), cut to maxBytes. JSON, plain text, and PDF text are returned as text in every format."),
            .number("offset", description: "Byte offset into the converted content, for reading long content over several calls: pass the offset from the previous call's truncation hint. Defaults to 0; must be below the reported length."),
            .boolean("includeLinks", description: "Append a '## Links' section with up to 80 unique links from the content as - [text](url), only on the first call (offset 0) and not counted in maxBytes. false also renders anchors as plain text. Defaults to true. With format html there is no Links section."),
            .boolean("mainContentOnly", description: "Convert only the main content (the <main>, [role=main], or largest <article> element, else the page body) and drop navigation, sidebars, footers, menus, and dialogs. false converts the whole page body unchanged. Defaults to true; ignored when selector is set."),
            .string("selector", description: "Optional CSS selector; only the matching elements are converted, in document order, with nothing removed inside them. Supports tag, *, #id, .class, [attr], [attr=v], ^= $= *= ~= |=, descendant and > combinators, and comma-separated groups, e.g. 'h1, h2' or 'article .content'."),
            .string("render", enumValues: WebFetchRenderMode.allCases.map(\.rawValue), description: "auto (default): render HTML pages in WebKit with JavaScript where available (macOS), otherwise fetch raw; non-HTML documents (JSON, text, PDF) are always fetched raw. raw: a single HTTP request without JavaScript; faster, works everywhere. rendered: always use WebKit; where WebKit is unavailable, falls back to raw and says so in a note line.")
        ],
        required: ["url"]
    )

    /// Minimum time left for the raw request when the rendered attempt
    /// falls back to it.
    static let minimumFallbackTimeout: TimeInterval = 5

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        guard let rawURL = input.url?.nilIfBlank else { throw WebToolsFeatureError.missingArgument("url") }

        // One policy validates the initial URL and every redirect the fetch
        // later follows, so an untrusted public page cannot pivot into a
        // private network or metadata endpoint mid-flight.
        let requestPolicy = WebNetworkRequestPolicy(environment: context.environment)
        try requestPolicy.validateRequestURL(rawURL)
        guard let url = URL(string: rawURL) else { throw WebToolsFeatureError.invalidURL(rawURL) }
        let scheme = url.scheme?.lowercased()
        guard let scheme, ["http", "https"].contains(scheme) else {
            throw WebToolsFeatureError.unsupportedScheme(scheme ?? "(none)")
        }

        let options = try WebFetchOptions(input)
        let document = try await fetchDocument(url: url, options: options, policy: requestPolicy)
        return try WebFetchOutput.render(document, options: options)
    }

    private func fetchDocument(
        url: URL,
        options: WebFetchOptions,
        policy: WebNetworkRequestPolicy
    ) async throws -> WebFetchDocument {
        #if canImport(WebKit)
        guard options.render != .raw else {
            return try await WebToolsSupport.rawFetchDocument(url: url, options: options, timeout: options.timeout, policy: policy)
        }
        let clock = ContinuousClock()
        let started = clock.now
        // The raw fallback gets what is left of the caller's time budget.
        func fallbackTimeout() -> TimeInterval {
            let elapsed = clock.now - started
            let used = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return max(options.timeout - used, min(options.timeout, Self.minimumFallbackTimeout))
        }
        do {
            let page = try await WebKitPageRenderer.render(url: url, timeout: options.timeout, requestPolicy: policy)
            return try WebFetchContent.renderedDocument(
                html: page.html,
                finalURL: page.finalURL,
                title: page.title,
                status: page.statusCode,
                mimeType: page.mimeType,
                htmlWasCut: page.htmlWasCut,
                blockedSubframeCount: page.blockedSubframeCount,
                options: options
            )
        } catch let error as WebNetworkGuardError {
            guard case .contentBlockerUnavailable = error else { throw error }
            // Never render in WebKit without the content blocker. The raw
            // path only fetches the main document through the guarded
            // session, so it is safe without one.
            var document = try await WebToolsSupport.rawFetchDocument(
                url: url,
                options: options,
                timeout: fallbackTimeout(),
                policy: policy
            )
            document.notes.insert(error.localizedDescription, at: 0)
            return document
        } catch let error as WebRenderError {
            // A non-HTML main document (JSON, PDF, text, ...) is extracted
            // from the raw response; WebKit would only show it in a viewer.
            var document = try await WebToolsSupport.rawFetchDocument(
                url: url,
                options: options,
                timeout: fallbackTimeout(),
                policy: policy
            )
            if options.render == .rendered, case let .nonHTMLContent(mimeType, _) = error {
                document.notes.insert("the main document is \(mimeType), not HTML, so it was fetched without WebKit", at: 0)
            }
            return document
        }
        #else
        var document = try await WebToolsSupport.rawFetchDocument(url: url, options: options, timeout: options.timeout, policy: policy)
        if options.render == .rendered {
            document.notes.insert("WebKit rendering is not available on this platform; the page was fetched without JavaScript", at: 0)
        }
        return document
        #endif
    }

    /// Cuts `text` at a UTF-8 scalar boundary so that it fits in `maxBytes`:
    /// a multi-byte scalar is never split (`prefix(_:)` on `String` counts
    /// characters, so multi-byte text could exceed the byte budget), but a
    /// grapheme cluster made of several scalars may be.
    static func truncated(_ text: String, toBytes maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var index = text.utf8.index(text.utf8.startIndex, offsetBy: maxBytes)
        while index > text.startIndex, !text.utf8[index].isUTF8ScalarStart {
            index = text.utf8.index(before: index)
        }
        return String(text[..<index])
    }
}
