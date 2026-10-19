import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum WebToolsSupport {
    static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebToolsFeatureError.permissionDenied("The web response was not an HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WebToolsFeatureError.permissionDenied("The web request failed with HTTP status \(httpResponse.statusCode).")
        }
    }

    /// A URLSession whose redirect handling is guarded by the network request
    /// policy, mirroring the interception approach of the Browser feature.
    /// Each hop (including the very first request, validated by the caller) is
    /// re-checked against URL restrictions and resolved addresses, so DNS
    /// rebinding and redirect chains into private networks are both rejected.
    static func makeURLSession(policy: WebNetworkRequestPolicy) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
#if canImport(Darwin)
        configuration.waitsForConnectivity = false
#endif
        return URLSession(configuration: configuration, delegate: WebRedirectGuard(policy: policy), delegateQueue: nil)
    }

    /// Fetches a URL with retry on transient failures (429, 5xx, network
    /// errors), backing off exponentially before each retry.
    static func fetchWithRetry(
        url: URL,
        session: URLSession = .shared,
        maxAttempts: Int = 3,
        timeout: TimeInterval = 20
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("ZenCODE/1.0", forHTTPHeaderField: "User-Agent")

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                if let http = response as? HTTPURLResponse,
                   http.statusCode == 429 || (500..<600).contains(http.statusCode) {
                    lastError = WebToolsFeatureError.permissionDenied(
                        "The web request failed with HTTP status \(http.statusCode)."
                    )
                    if attempt < maxAttempts - 1 {
                        try await sleepBeforeRetry(attempt)
                        continue
                    }
                }
                return (data, response)
            } catch is CancellationError {
                // Retrying a cancelled invocation would issue another request.
                throw CancellationError()
            } catch {
                guard !Task.isCancelled else { throw CancellationError() }
                lastError = error
                if attempt < maxAttempts - 1 {
                    try await sleepBeforeRetry(attempt)
                }
            }
        }
        throw lastError ?? WebToolsFeatureError.permissionDenied("The web request failed after \(maxAttempts) attempts.")
    }

    private static func sleepBeforeRetry(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 500_000_000)
    }

    /// Raw HTTP fetch used as the non-Apple fallback for `web.fetch`.
    static func rawFetchPreview(
        url: URL,
        maxBytes: Int,
        timeout: TimeInterval,
        policy: WebNetworkRequestPolicy
    ) async throws -> String {
        try policy.validateRequestURL(url.absoluteString)

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("ZenCODE/1.0", forHTTPHeaderField: "User-Agent")

        let session = makeURLSession(policy: policy)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        try validateHTTPResponse(response)
        let bodyData = Data(data.prefix(maxBytes))
        let body = String(data: bodyData, encoding: .utf8)
            ?? "<non-UTF-8 response body: \(bodyData.count) bytes>"
        let truncatedSuffix = data.count > bodyData.count
            ? "\n\n<truncated: \(data.count - bodyData.count) bytes omitted>"
            : ""

        return """
        url: \(response.url?.absoluteString ?? url.absoluteString)
        status: \(httpResponse?.statusCode ?? 0)
        content-type: \(httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "unknown")
        engine: URLSession (raw fetch)
        bytes: \(data.count)

        \(body)\(truncatedSuffix)
        """
    }
}
