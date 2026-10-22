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
    }

    static let name = "web.fetch"
    static let description = "Opens an HTTP or HTTPS URL restricted to public network destinations. On Apple platforms it renders the page in a silent in-process WebKit view (JavaScript executed) and returns extracted Markdown; on other platforms it falls back to a raw HTTP fetch preview. Private, loopback, link-local, and otherwise non-public destinations are rejected, including redirect chains that resolve to them."
    static let inputSchema = buildInputSchema(
        [.string("url"), .number("maxBytes"), .number("timeoutSeconds")],
        required: ["url"]
    )

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

        let maxBytes = max(1_024, min(input.maxBytes ?? 120_000, 1_000_000))
        let timeout = TimeInterval(max(1, min(input.timeoutSeconds ?? 20, 120)))

        #if canImport(WebKit)
        let page: RenderedPage
        do {
            page = try await WebKitPageRenderer.render(url: url, timeout: timeout, requestPolicy: requestPolicy)
        } catch let error as WebNetworkGuardError {
            guard case .contentBlockerUnavailable = error else { throw error }
            // Never render in WebKit without the content blocker. The raw
            // path only fetches the main document through the guarded
            // session, so it is safe without one.
            let preview = try await WebToolsSupport.rawFetchPreview(
                url: url,
                maxBytes: maxBytes,
                timeout: timeout,
                policy: requestPolicy
            )
            return "note: \(error.localizedDescription)\n" + preview
        }
        let fullMarkdown = page.markdown
        let markdown = Self.truncated(fullMarkdown, toBytes: maxBytes)
        let truncatedSuffix = fullMarkdown.utf8.count > markdown.utf8.count
            ? "\n\n<truncated: \(fullMarkdown.utf8.count - markdown.utf8.count) bytes omitted>"
            : ""
        return """
        url: \(page.finalURL)
        title: \(page.title)
        engine: WebKit (rendered, JavaScript executed)

        \(markdown)\(truncatedSuffix)
        """
        #else
        return try await WebToolsSupport.rawFetchPreview(
            url: url,
            maxBytes: maxBytes,
            timeout: timeout,
            policy: requestPolicy
        )
        #endif
    }

    /// Cuts `text` so that it fits in `maxBytes` of UTF-8 without splitting
    /// a character; `prefix(_:)` on `String` counts characters, so a page of
    /// multi-byte text could otherwise exceed the requested byte budget.
    static func truncated(_ text: String, toBytes maxBytes: Int) -> String {
        guard text.utf8.count > maxBytes else { return text }
        var index = text.utf8.index(text.utf8.startIndex, offsetBy: maxBytes)
        while index > text.startIndex, !text.utf8[index].isUTF8ScalarStart {
            index = text.utf8.index(before: index)
        }
        return String(text[..<index])
    }
}

private extension UInt8 {
    /// True when a UTF-8 code unit begins a scalar (not a continuation byte).
    var isUTF8ScalarStart: Bool { self & 0xC0 != 0x80 }
}
