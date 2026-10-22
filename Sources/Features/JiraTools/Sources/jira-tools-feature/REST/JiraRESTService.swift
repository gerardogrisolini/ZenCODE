import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ToolCore

struct JiraIssueSummary: Hashable, Sendable {
    let key: String
    let summary: String
    let status: String?
    let issueType: String?
    let assignee: String?
    let url: URL
}

struct JiraIssueDetail: Sendable {
    let key: String
    let summary: String
    let status: String?
    let issueType: String?
    let assignee: String?
    let priority: String?
    let url: URL
    let description: String?
    let acceptanceCriteria: [String]
    let designURLs: [String]
    let referenceURLs: [String]
    let notableFields: [(name: String, value: String)]
    let rawPayload: JSONValue
}

actor JiraRESTService {
    private let configuration: JiraStoredConfiguration
    private let apiToken: String
    /// Dedicated session so redirects are validated before the Basic
    /// `Authorization` header is replayed (see ``JiraRESTSessionDelegate``).
    private let urlSession: URLSession

    /// Upper bound for a single Jira REST call. The feature invocation
    /// timeout is much longer, but a stalled connection must not consume it.
    static let requestTimeout: TimeInterval = 30
    static let resourceTimeout: TimeInterval = 120

    init(configuration: JiraStoredConfiguration, apiToken: String) {
        self.configuration = configuration
        self.apiToken = apiToken
        let delegate = JiraRESTSessionDelegate(siteHost: configuration.siteURL.host ?? "")
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = Self.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = Self.resourceTimeout
        self.urlSession = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        urlSession.finishTasksAndInvalidate()
    }

    static func loadConfigured() throws -> JiraRESTService {
        let configuration = try JiraConfigurationStore.load()
        let apiToken = try JiraCredentialStore.load(account: configuration.credentialAccount)
        return JiraRESTService(configuration: configuration, apiToken: apiToken)
    }

    func validateCredentials() async throws -> String {
        let result = try await request(path: "/rest/api/3/myself", queryItems: [])
        return result["displayName"]?.stringValue
            ?? result["emailAddress"]?.stringValue
            ?? configuration.email
    }

    func searchIssues(matching query: String) async throws -> [JiraIssueSummary] {
        if let issueKey = JiraIssueKeyExtractor.issueKey(in: query) {
            let issue = try await fetchIssue(issueKey: issueKey)
            return [JiraIssueParser.summary(from: issue)]
        }

        let result = try await request(
            path: "/rest/api/3/issue/picker",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "currentJQL", value: "")
            ]
        )
        let summaries = JiraIssueParser.issueSummaries(fromPickerResult: result, siteURL: configuration.siteURL)
        return Array(summaries.prefix(12))
    }

    func loadIssue(matching query: String) async throws -> JiraIssueDetail {
        if let issueKey = JiraIssueKeyExtractor.issueKey(in: query) {
            return try await fetchIssue(issueKey: issueKey)
        }

        let matches = try await searchIssues(matching: query)
        guard matches.count == 1,
              let issueKey = matches.first?.key else {
            if matches.isEmpty {
                throw JiraToolsError.requestFailed(
                    "No Jira issues matched '\(query)'. Pass an issue key or URL, or refine the query with jira.search."
                )
            }
            throw JiraToolsError.requestFailed(
                "Jira search returned \(matches.count) issues. Call jira.search first, then call jira.read with the selected issue key."
            )
        }
        return try await fetchIssue(issueKey: issueKey)
    }

    private func fetchIssue(issueKey: String) async throws -> JiraIssueDetail {
        let result = try await request(
            path: "/rest/api/3/issue/\(issueKey)",
            queryItems: [
                URLQueryItem(name: "fields", value: "*all"),
                URLQueryItem(name: "expand", value: "names")
            ],
            notFound: { message in .issueNotFound(issueKey, message: message) }
        )
        guard let detail = JiraIssueParser.issueDetail(from: result, siteURL: configuration.siteURL) else {
            throw JiraToolsError.issueNotFound(issueKey)
        }
        return detail
    }

    /// Fail-closed defense in depth: even though `JiraStoredConfiguration`
    /// normalizes the site URL to HTTPS, no request carrying credentials is
    /// ever sent over a non-TLS connection.
    static func requireHTTPS(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw JiraToolsError.requestFailed(
                "Jira requests require HTTPS. Refusing to send credentials to '\(url.absoluteString)'. Use an https:// site URL."
            )
        }
    }

    /// RFC 3986 unreserved characters. Everything else in a query name or
    /// value is percent-encoded, including `+`, which Jira (like every
    /// `application/x-www-form-urlencoded` parser) would otherwise decode as a
    /// space, and `&`/`=`, which would split the parameter.
    private static let queryUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    static func percentEncodedQuery(_ items: [URLQueryItem]) -> String? {
        guard !items.isEmpty else { return nil }
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: queryUnreserved) ?? ""
        }
        return items
            .map { item in
                guard let value = item.value else { return encode(item.name) }
                return "\(encode(item.name))=\(encode(value))"
            }
            .joined(separator: "&")
    }

    private func request(
        path: String,
        queryItems: [URLQueryItem],
        notFound: ((String) -> JiraToolsError)? = nil
    ) async throws -> JSONValue {
        guard var components = URLComponents(url: configuration.siteURL, resolvingAgainstBaseURL: false) else {
            throw JiraToolsError.requestFailed("Unable to build Jira request URL.")
        }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        components.percentEncodedQuery = Self.percentEncodedQuery(queryItems)
        guard let url = components.url else { throw JiraToolsError.requestFailed("Unable to build Jira request URL.") }
        try Self.requireHTTPS(url)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JiraToolsError.requestFailed("Invalid Jira response.")
        }
        let responseText = responseMessage(from: data)
        switch httpResponse.statusCode {
        case 200..<300:
            break
        case 300..<400:
            // The redirect delegate refused to follow a hop that would have
            // left the configured origin (see `JiraRedirectPolicy`).
            throw JiraToolsError.requestFailed(
                "Jira redirected the request (HTTP \(httpResponse.statusCode)) to another origin; the redirect was refused to protect your credentials. Check the configured Jira site URL."
            )
        case 401:
            throw JiraToolsError.authenticationFailed(statusCode: httpResponse.statusCode, message: responseText)
        case 403:
            throw JiraToolsError.requestFailed(
                "Jira denied access (HTTP 403). The account may lack permission for this project or issue. \(responseText)"
            )
        case 404:
            if let notFound {
                throw notFound(responseText)
            }
            throw JiraToolsError.requestFailed("Jira request failed with HTTP 404. \(responseText)")
        case 429:
            let retryAfter = Self.headerValue("Retry-After", in: httpResponse)
            let retryHint = retryAfter.map { " Retry after \($0) seconds." } ?? " Retry later."
            throw JiraToolsError.requestFailed("Jira rate limit exceeded (HTTP 429).\(retryHint) \(responseText)")
        default:
            throw JiraToolsError.requestFailed(
                "Jira request failed with HTTP \(httpResponse.statusCode). \(responseText)"
            )
        }

        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw JiraToolsError.requestFailed("Invalid Jira JSON response.")
        }
    }

    private var authorizationHeader: String {
        let credentials = "\(configuration.email):\(apiToken)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }

    /// Case-insensitive header lookup that works identically on Darwin and
    /// swift-corelibs-foundation.
    private static func headerValue(_ name: String, in response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, key.caseInsensitiveCompare(name) == .orderedSame else { continue }
            return (value as? String)?.nilIfBlank
        }
        return nil
    }

    private func responseMessage(from data: Data) -> String {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let message = value["message"]?.stringValue {
                return message
            }
            if let messages = value["errorMessages"]?.arrayValue,
               !messages.isEmpty {
                return messages.compactMap(\.stringValue).joined(separator: " ")
            }
        }
        return String(decoding: data.prefix(400), as: UTF8.self)
    }
}

enum JiraAuthenticatedService {
    static func run<T>(_ operation: (JiraRESTService) async throws -> T) async throws -> T {
        let resolved = try await configuredService()
        do {
            return try await operation(resolved.service)
        } catch let error as JiraToolsError {
            guard !resolved.didAuthenticate,
                  let reason = error.authenticationReason else {
                throw error
            }
            let service = try await JiraSetupRunner.authenticateFromTool(reason: reason)
            return try await operation(service)
        }
    }

    private static func configuredService() async throws -> ServiceResolution {
        do {
            return ServiceResolution(service: try JiraRESTService.loadConfigured(), didAuthenticate: false)
        } catch let error as JiraToolsError {
            guard let reason = error.authenticationReason else { throw error }
            return ServiceResolution(
                service: try await JiraSetupRunner.authenticateFromTool(reason: reason),
                didAuthenticate: true
            )
        }
    }

    private struct ServiceResolution: Sendable {
        let service: JiraRESTService
        let didAuthenticate: Bool
    }
}

extension JiraToolsError {
    var authenticationReason: JiraAuthenticationReason? {
        switch self {
        case .notConfigured:
            return .missingConfiguration
        case .missingCredentials:
            return .missingCredentials
        case .authenticationFailed:
            return .invalidCredentials
        default:
            return nil
        }
    }
}

/// Pure redirect decision for Jira REST calls. `URLSession` replays the Basic
/// `Authorization` header on cross-origin redirects, so a redirect that leaves
/// the configured HTTPS origin must be blocked: it would leak the Atlassian
/// credentials to an unrelated destination. Only an exact same-origin redirect
/// is allowed; subdomains are different origins and are rejected.
enum JiraRedirectPolicy {
    /// Fail-closed decision used by the URLSession delegate for every redirect
    /// hop of a Jira REST call. The destination must have the same HTTPS origin
    /// as the request and must match the configured site host exactly. Host
    /// comparison is case-insensitive and treats a trailing FQDN dot as
    /// equivalent; the effective port is part of the origin comparison.
    static func allowsRedirect(siteHost: String, from origin: URL, to destination: URL) -> Bool {
        guard let destinationScheme = destination.scheme?.lowercased(),
              destinationScheme == "https",
              let destinationHost = canonicalHost(destination.host) else {
            return false
        }
        guard let originScheme = origin.scheme?.lowercased(),
              originScheme == "https",
              canonicalHost(origin.host) != nil else {
            return false
        }

        guard sameOrigin(origin, destination) else { return false }
        return isHostEquivalent(siteHost, to: destinationHost)
    }

    /// Compares canonical host names exactly. A trailing FQDN dot is ignored,
    /// but a subdomain is never considered equivalent to its parent host.
    static func isHostEquivalent(_ originHost: String, to destinationHost: String) -> Bool {
        guard let origin = canonicalHost(originHost),
              let destination = canonicalHost(destinationHost) else {
            return false
        }
        return destination == origin
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == "https",
              rhs.scheme?.lowercased() == "https",
              let lhsHost = canonicalHost(lhs.host),
              let rhsHost = canonicalHost(rhs.host),
              lhsHost == rhsHost,
              effectivePort(of: lhs) == effectivePort(of: rhs) else {
            return false
        }
        return true
    }

    private static func effectivePort(of url: URL) -> Int? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        return url.port ?? 443
    }

    private static func canonicalHost(_ host: String?) -> String? {
        guard var value = host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        value = value.lowercased()
        if value.hasSuffix(".") {
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }
}

/// URLSession delegate that gates every redirect hop of a Jira REST call.
/// Blocking (returning `nil`) prevents the credential-bearing request from
/// being replayed against the redirect target.
final class JiraRESTSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let siteHost: String

    init(siteHost: String) {
        self.siteHost = siteHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let origin = task.originalRequest?.url ?? request.url
        guard let origin, let destination = request.url else {
            completionHandler(nil)
            return
        }
        let allowed = JiraRedirectPolicy.allowsRedirect(siteHost: siteHost, from: origin, to: destination)
        completionHandler(allowed ? request : nil)
    }
}
