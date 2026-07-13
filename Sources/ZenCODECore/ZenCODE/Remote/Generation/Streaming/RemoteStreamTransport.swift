//
//  RemoteStreamTransport.swift
//  ZenCODE
//
//  HTTP/SSE transport utilities for remote streaming. All methods are static —
//  no mutable state is carried, so they are safe to call from actor-isolated
//  and concurrent contexts alike.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Stateless HTTP/SSE transport helpers for remote generation streaming.
public enum RemoteStreamTransport {

    /// Shared decoder reused across the SSE streaming hot path. `jsonObject` is
    /// invoked once per streamed line, so recreating a `JSONDecoder` each call
    /// is pure allocation overhead. The decoder is never mutated after creation,
    /// which makes concurrent `decode` calls safe.
    public static let sharedStreamJSONDecoder = JSONDecoder()

    /// Retrying only a failed TLS negotiation keeps the POST replay boundary
    /// deliberately narrower than a general transport-error allowlist.
    static let maximumStreamOpeningRetries = 2
    static let streamOpeningRetryBaseDelayNanoseconds: UInt64 = 500_000_000

    // MARK: - URL construction

    public static func endpointURL(path: String, baseURL: String) throws -> URL {
        guard var components = URLComponents(string: baseURL) else {
            throw RemoteGenerationClientError.invalidBaseURL(baseURL)
        }
        // Build the joined path explicitly so an existing query on the base URL
        // is preserved and duplicate slashes are collapsed.
        let basePathComponents = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
        let extraPathComponents = path
            .split(separator: "/", omittingEmptySubsequences: true)
        let joined = (basePathComponents + extraPathComponents).joined(separator: "/")
        components.path = joined.isEmpty ? "" : "/" + joined
        guard let url = components.url else {
            throw RemoteGenerationClientError.invalidBaseURL(baseURL)
        }
        return url
    }

    // MARK: - HTTP request

    public static func buildStreamRequest(
        path: String,
        body: [String: Any],
        provider: AgentRemoteProvider,
        apiKey: String?
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpointURL(path: path, baseURL: provider.baseURL))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONValue(jsonObject: body).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        )
        return request
    }

    static func shouldRetryStreamOpening(
        error: Error,
        attempt: Int
    ) -> Bool {
        guard attempt >= 0,
              attempt < maximumStreamOpeningRetries else {
            return false
        }
        return urlErrorCode(from: error) == .secureConnectionFailed
    }

    static func streamOpeningRetryDelayNanoseconds(attempt: Int) -> UInt64 {
        let exponent = UInt64(max(0, min(attempt, 10)))
        return streamOpeningRetryBaseDelayNanoseconds << exponent
    }

    private static func urlErrorCode(from error: Error) -> URLError.Code? {
        if let urlError = error as? URLError {
            return urlError.code
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return nil
        }
        return URLError.Code(rawValue: nsError.code)
    }

    // MARK: - Response validation

    public static func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteGenerationClientError.httpStatus(httpResponse.statusCode)
        }
    }

    public static func validateHTTPResponse(
        _ response: URLResponse,
        bytes: URLSession.AsyncBytes,
        bodyLimit: Int = 64 * 1024
    ) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let output = try await collectErrorBody(from: bytes, limit: bodyLimit)
            if let message = responseErrorMessage(from: output)?.nilIfBlank {
                throw RemoteGenerationClientError.remoteFailure(message)
            }
            if let output = output.nilIfBlank {
                throw RemoteGenerationClientError.remoteFailure(output)
            }
            throw RemoteGenerationClientError.httpStatus(httpResponse.statusCode)
        }
    }

    // MARK: - Error body

    public static func collectErrorBody(
        from bytes: URLSession.AsyncBytes,
        limit: Int = 64 * 1024
    ) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit {
                break
            }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SSE / JSON helpers

    public static func ssePayload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else {
            return nil
        }
        return String(trimmed.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func jsonObject(from payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let value = try? sharedStreamJSONDecoder.decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            return nil
        }
        return object.mapValues(\.jsonObject)
    }

    // MARK: - Error message extraction

    public static func responseErrorMessage(from output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            for line in output.split(whereSeparator: \.isNewline) {
                guard let payload = ssePayload(from: String(line)),
                      payload != "[DONE]",
                      let sseObject = jsonObject(from: payload) else {
                    continue
                }
                if let message = responseErrorMessage(from: sseObject)?.nilIfBlank {
                    return message
                }
            }
            return output.nilIfBlank
        }
        return responseErrorMessage(from: object.mapValues(\.jsonObject))
    }

    public static func responseErrorMessage(from object: [String: Any]) -> String? {
        if let message = RemoteGenerationClient.stringValue(object["message"])?.nilIfBlank {
            return message
        }
        if let errorObject = object["error"] as? [String: Any] {
            return RemoteGenerationClient.stringValue(errorObject["message"])?.nilIfBlank
                ?? RemoteGenerationClient.stringValue(errorObject["code"])?.nilIfBlank
                ?? RemoteGenerationClient.stringValue(errorObject["type"])?.nilIfBlank
        }
        if let error = RemoteGenerationClient.stringValue(object["error"])?.nilIfBlank {
            return error
        }
        return nil
    }

    public static func responseErrorMessage(from value: Any?) -> String? {
        if let string = value as? String {
            return string.nilIfBlank
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        return RemoteGenerationClient.stringValue(object["message"])?.nilIfBlank
            ?? RemoteGenerationClient.stringValue(object["metadata"])?.nilIfBlank
            ?? RemoteGenerationClient.stringValue(object["code"])?.nilIfBlank
            ?? RemoteGenerationClient.stringValue(object["type"])?.nilIfBlank
    }

    public static func responseFailureMessage(
        from object: [String: Any],
        fallbackType: String
    ) -> String {
        if let response = object["response"] as? [String: Any],
           let message = responseErrorMessage(from: response["error"]) {
            return message
        }
        if let message = responseErrorMessage(from: object["error"]) {
            return message
        }
        return fallbackType
    }

    public static func toolExposureDiagnostic(from descriptors: [DirectToolDescriptor]) -> String {
        let names = descriptors.map(\.name).filter { !$0.isEmpty }.sorted()
        let sample = names.prefix(8).joined(separator: ",")
        let suffix = names.count > 8 ? ",..." : ""
        return "Remote tools exposed: \(names.count)[\(sample)\(suffix)]"
    }
}
