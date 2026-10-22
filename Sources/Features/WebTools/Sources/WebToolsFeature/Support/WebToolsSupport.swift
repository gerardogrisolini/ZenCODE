import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum WebToolsSupport {
    static let userAgent = "ZenCODE/1.0"

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
        let request = makeRequest(url: url, timeout: timeout)

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
                        try await sleepBeforeRetry(attempt)
                        continue
                    }
                }
                return result
            } catch is CancellationError {
                // Retrying a cancelled invocation would issue another request.
                throw CancellationError()
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

    private static func sleepBeforeRetry(_ attempt: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt))) * 500_000_000)
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

    /// Raw HTTP fetch used as the non-WebKit path for `web.fetch`: the only
    /// request it makes is for the main document, through the guarded
    /// session, so every hop is policy-checked and the body is never read
    /// beyond `maxBytes`.
    static func rawFetchPreview(
        url: URL,
        maxBytes: Int,
        timeout: TimeInterval,
        policy: WebNetworkRequestPolicy
    ) async throws -> String {
        try policy.validateRequestURL(url.absoluteString)

        let session = makeBoundedSession(policy: policy, timeout: timeout)
        defer { session.finishTasksAndInvalidate() }
        let result = try await loadBounded(makeRequest(url: url, timeout: timeout), session: session, maxBytes: maxBytes)
        try validateHTTPResponse(result.response)
        let body = decodeBody(result.data, response: result.response)
        let truncatedSuffix: String
        if result.wasTruncated {
            if let expected = result.expectedContentLength, expected > Int64(result.data.count) {
                truncatedSuffix = "\n\n<truncated: \(expected - Int64(result.data.count)) bytes omitted>"
            } else {
                truncatedSuffix = "\n\n<truncated at \(result.data.count) bytes>"
            }
        } else {
            truncatedSuffix = ""
        }

        return """
        url: \(result.response.url?.absoluteString ?? url.absoluteString)
        status: \(result.response.statusCode)
        content-type: \(result.response.value(forHTTPHeaderField: "Content-Type") ?? "unknown")
        engine: URLSession (raw fetch)
        bytes: \(result.data.count)

        \(body)\(truncatedSuffix)
        """
    }
}
