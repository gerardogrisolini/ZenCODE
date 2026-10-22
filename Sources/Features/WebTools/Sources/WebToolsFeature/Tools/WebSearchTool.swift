import ToolCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import FeatureKit

struct WebSearchTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let query: String?
        let limit: Int?
        let domains: [String]?
    }

    static let name = "web.search"
    static let description = "Searches the public web and returns matching results with titles, URLs, and snippets."
    static let inputSchema = buildInputSchema(
        [.string("query"), .number("limit"), .array("domains")],
        required: ["query"]
    )

    /// The engine's HTML result page is a few hundred KiB at most; anything
    /// larger is not a result page and is cut off.
    static let maxResponseBytes = 2_000_000
    static let requestTimeout: TimeInterval = 20

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        guard let query = input.query?.nilIfBlank else { throw WebToolsFeatureError.missingArgument("query") }

        let limit = max(1, min(input.limit ?? 5, 10))
        let domains = WebToolsSupport.normalizedDomains(from: input.domains ?? [])
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kl", value: "wt-wt")
        ]
        guard let url = components.url else {
            throw WebToolsFeatureError.permissionDenied("Unable to build the web search request.")
        }

        let policy = WebNetworkRequestPolicy(environment: context.environment)
        let session = WebToolsSupport.makeURLSession(policy: policy, timeout: Self.requestTimeout)
        defer { session.finishTasksAndInvalidate() }
        let result = try await WebToolsSupport.fetchWithRetry(
            url: url,
            session: session,
            maxBytes: Self.maxResponseBytes,
            timeout: Self.requestTimeout
        )
        try WebToolsSupport.validateHTTPResponse(result.response)

        let html = WebToolsSupport.decodeBody(result.data, response: result.response)
        let results = WebToolsSupport.parseDuckDuckGoHTMLResults(html, limit: limit, domains: domains)
        guard !results.isEmpty else { return "Query: \(query)\nNo public web results found." }

        let renderedResults = results.enumerated().map { index, result in
            var lines = [
                "\(index + 1). \(result.title)",
                "   URL: \(result.url)"
            ]
            if !result.snippet.isEmpty {
                lines.append("   Snippet: \(result.snippet)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        return "Query: \(query)\n\(renderedResults)"
    }
}
