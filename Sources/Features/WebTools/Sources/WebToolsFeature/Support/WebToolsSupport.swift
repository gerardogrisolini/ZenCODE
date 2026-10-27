import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum WebToolsSupport {
    /// Browser-like user agent shared by the raw HTTP path and (later) the
    /// WebKit renderer, so search engines and sites see one consistent client.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) ZenCODE/1.0"

    static let acceptHeader = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    static let acceptLanguageHeader = "en-US,en;q=0.9,*;q=0.5"

    /// Upper bound for a server-requested `Retry-After` wait; a longer
    /// request is clamped so one tool call never stalls for minutes.
    static let maxRetryAfterSeconds: TimeInterval = 10

    static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebToolsFeatureError.permissionDenied("The web response was not an HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WebToolsFeatureError.permissionDenied("The web request failed with HTTP status \(httpResponse.statusCode).")
        }
    }

    /// A URLSession whose redirect handling is guarded by the network request
    /// policy and whose body size is bounded by ``loadBounded(_:session:maxBytes:)``.
    static func makeURLSession(policy: WebNetworkRequestPolicy, timeout: TimeInterval = 20) -> URLSession {
        makeBoundedSession(policy: policy, timeout: timeout)
    }

    static func makeRequest(url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(acceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// A POST request carrying `fields` as an `application/x-www-form-urlencoded`
    /// body, with the same headers as ``makeRequest(url:timeout:)``.
    static func makeFormPostRequest(url: URL, fields: [(name: String, value: String)], timeout: TimeInterval) -> URLRequest {
        var request = makeRequest(url: url, timeout: timeout)
        request.httpMethod = "POST"
        request.httpBody = Data(formURLEncoded(fields).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Fetches a URL with retry on transient failures (429, 5xx, network
    /// errors), backing off exponentially before each retry. Policy decisions
    /// (blocked redirects, oversized bodies) are final and never retried.
    static func fetchWithRetry(
        url: URL,
        session: URLSession,
        maxBytes: Int,
        maxAttempts: Int = 3,
        timeout: TimeInterval = 20
    ) async throws -> WebBoundedResponse {
        try await fetchWithRetry(
            request: makeRequest(url: url, timeout: timeout),
            session: session,
            maxBytes: maxBytes,
            maxAttempts: maxAttempts
        )
    }

    /// Retrying fetch for a prepared request (any method and body). On 429 and
    /// 503 a numeric `Retry-After` header replaces the exponential backoff for
    /// that attempt (see ``retryAfterDelay(from:)``).
    static func fetchWithRetry(
        request: URLRequest,
        session: URLSession,
        maxBytes: Int,
        maxAttempts: Int = 3
    ) async throws -> WebBoundedResponse {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            try Task.checkCancellation()
            do {
                let result = try await loadBounded(request, session: session, maxBytes: maxBytes)
                try Task.checkCancellation()
                let status = result.response.statusCode
                if status == 429 || (500..<600).contains(status) {
                    lastError = WebToolsFeatureError.permissionDenied(
                        "The web request failed with HTTP status \(status)."
                    )
                    if attempt < maxAttempts - 1 {
                        let serverDelay = status == 429 || status == 503
                            ? retryAfterDelay(from: result.response.value(forHTTPHeaderField: "Retry-After"))
                            : nil
                        try await sleepBeforeRetry(attempt, retryAfter: serverDelay)
                        continue
                    }
                }
                return result
            } catch let error as CancellationError {
                // Retrying a cancelled invocation would issue another request.
                throw error
            } catch let error as WebNetworkGuardError {
                throw error
            } catch let error as WebURLPolicyError {
                throw error
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

    private static func sleepBeforeRetry(_ attempt: Int, retryAfter: TimeInterval? = nil) async throws {
        if let retryAfter {
            try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
            return
        }
        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 500_000_000)
    }

    /// Parses a `Retry-After` header given in delta-seconds. Returns the wait
    /// clamped to ``maxRetryAfterSeconds``, or `nil` when the header is absent,
    /// negative, not finite, or an HTTP date (the caller then falls back to the
    /// exponential backoff).
    static func retryAfterDelay(from header: String?) -> TimeInterval? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              let seconds = Double(trimmed),
              seconds.isFinite,
              seconds >= 0 else {
            return nil
        }
        return min(seconds, maxRetryAfterSeconds)
    }

    /// Decodes a response body as text. The charset comes from the
    /// `Content-Type` header when present, otherwise from a `<meta charset>`
    /// / `http-equiv` declaration in the first bytes of an HTML body, and
    /// finally defaults to UTF-8. Decoding is lossy: invalid sequences (for
    /// example a multi-byte character cut by the byte limit) become U+FFFD
    /// instead of failing the whole body.
    static func decodeBody(_ data: Data, response: HTTPURLResponse?) -> String {
        let declared = response?.textEncodingName.flatMap(encoding(named:))
        let encoding = declared ?? sniffedHTMLEncoding(in: data) ?? .utf8
        if encoding == .utf8 {
            return String(decoding: data, as: UTF8.self)
        }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    /// IANA charset name to `String.Encoding`, for the handful of encodings
    /// seen on the public web. Support for a given encoding varies between
    /// Darwin Foundation and swift-corelibs-foundation; when the declared
    /// encoding cannot decode the body, ``decodeBody(_:response:)`` falls
    /// back to lossy UTF-8 instead of failing.
    static func encoding(named rawName: String) -> String.Encoding? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "utf-8", "utf8":
            return .utf8
        case "iso-8859-1", "iso8859-1", "latin1", "l1", "us-ascii", "ascii":
            return .isoLatin1
        case "iso-8859-2", "iso8859-2", "latin2":
            return .isoLatin2
        case "windows-1250", "cp1250":
            return .windowsCP1250
        case "windows-1251", "cp1251":
            return .windowsCP1251
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "windows-1253", "cp1253":
            return .windowsCP1253
        case "windows-1254", "cp1254":
            return .windowsCP1254
        case "utf-16", "utf16":
            return .utf16
        case "utf-16be":
            return .utf16BigEndian
        case "utf-16le":
            return .utf16LittleEndian
        case "shift_jis", "shift-jis", "sjis", "ms_kanji":
            return .shiftJIS
        case "euc-jp":
            return .japaneseEUC
        case "iso-2022-jp":
            return .iso2022JP
        case "macintosh", "mac-roman", "x-mac-roman":
            return .macOSRoman
        default:
            return nil
        }
    }

    /// Looks for `<meta charset="…">` or `<meta http-equiv="Content-Type"
    /// content="…; charset=…">` in the first 2 KiB, where the HTML standard
    /// requires the declaration to appear.
    static func sniffedHTMLEncoding(in data: Data) -> String.Encoding? {
        let head = String(decoding: data.prefix(2_048), as: UTF8.self)
        guard head.range(of: "<meta", options: .caseInsensitive) != nil else { return nil }
        let pattern = #"<meta[^>]*charset\s*=\s*["']?\s*([A-Za-z0-9._:-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: head, options: [], range: NSRange(head.startIndex..<head.endIndex, in: head)),
              let nameRange = Range(match.range(at: 1), in: head)
        else {
            return nil
        }
        return encoding(named: String(head[nameRange]))
    }
}
