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
        let timeRange: String?
        let region: String?
    }

    static let name = "web.search"
    static let description = "Searches the public web (DuckDuckGo) and returns matching results with titles, URLs, and snippets. Supports restricting results to domains, a time range, and a region; fetches additional result pages when more results are requested."
    static let inputSchema = buildInputSchema(
        [
            .string("query", description: "Search query text. Search operators such as quotes and site: are passed through to the engine."),
            .number("limit", description: "Maximum number of results to return. Defaults to 5, clamped to 1-30; asking for more than one page of results costs extra requests."),
            .array("domains", description: "Optional domains to restrict results to, e.g. [\"swift.org\", \"github.com\"]. Adds site: terms to the query and keeps only results on those hosts or their subdomains."),
            .string("timeRange", enumValues: WebSearchTimeRange.allCases.map(\.rawValue), description: "Optional recency filter: day, week, month, or year. Omit for all time."),
            .string("region", description: "Optional DuckDuckGo region code (two letters, hyphen, two letters) such as us-en, it-it, de-de, or wt-wt for worldwide (the default).")
        ],
        required: ["query"]
    )

    /// The engine's HTML result page is a few hundred KiB at most; anything
    /// larger is not a result page and is cut off.
    static let maxResponseBytes = 2_000_000
    static let requestTimeout: TimeInterval = 20

    func run(_ input: Input, context: FeatureContext) async throws -> String {
        guard let query = input.query?.nilIfBlank else { throw WebToolsFeatureError.missingArgument("query") }

        let timeRange = try WebSearchTimeRange.parse(input.timeRange)
        let region = try WebToolsSupport.normalizedSearchRegion(input.region)
        let domains = WebToolsSupport.normalizedDomains(from: input.domains ?? [])
        let parameters = WebSearchParameters(
            query: WebToolsSupport.searchQuery(query, domains: domains),
            limit: WebToolsSupport.clampedSearchLimit(input.limit),
            domains: domains,
            timeRange: timeRange,
            region: region
        )

        let policy = WebNetworkRequestPolicy(environment: context.environment)
        let session = WebToolsSupport.makeURLSession(policy: policy, timeout: Self.requestTimeout)
        defer { session.finishTasksAndInvalidate() }
        let outcome = try await WebToolsSupport.performDuckDuckGoSearch(parameters, timeout: Self.requestTimeout) { request in
            let result = try await WebToolsSupport.fetchWithRetry(
                request: request,
                session: session,
                maxBytes: Self.maxResponseBytes
            )
            return WebSearchPageResponse(
                statusCode: result.response.statusCode,
                body: WebToolsSupport.decodeBody(result.data, response: result.response)
            )
        }
        return WebToolsSupport.renderSearchOutput(parameters: parameters, outcome: outcome)
    }
}
