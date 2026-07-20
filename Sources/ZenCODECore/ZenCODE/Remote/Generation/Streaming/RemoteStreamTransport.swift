//
//  RemoteStreamTransport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation

/// Stateless HTTP/SSE transport helpers for remote generation streaming.
public enum RemoteStreamTransport {

    /// Shared decoder reused across the SSE streaming hot path. `jsonObject` is
    /// invoked once per streamed line, so recreating a `JSONDecoder` each call
    /// is pure allocation overhead. The decoder is never mutated after creation,
    /// which makes concurrent `decode` calls safe.
    public static let sharedStreamJSONDecoder = JSONDecoder()

    /// Retrying only a transient failure before the response head keeps the
    /// POST replay boundary deliberately narrower than a body-error allowlist.
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

    /// Builds the production NIO request from the shared wire components. The
    /// header array deliberately keeps order and duplicate field names.
    public static func buildHTTPStreamingRequest(
        path: String,
        body: [String: Any],
        provider: AgentRemoteProvider,
        apiKey: String?,
        endpointBaseURLOverride: URL? = nil
    ) throws -> RemoteHTTPStreamingRequest {
        let components = try streamRequestComponents(
            path: path,
            body: body,
            provider: provider,
            apiKey: apiKey,
            endpointBaseURLOverride: endpointBaseURLOverride
        )
        return RemoteHTTPStreamingRequest(
            url: components.url,
            method: "POST",
            headers: components.headers,
            body: components.body,
            timeout: .seconds(900)
        )
    }

    static func streamRequestComponents(
        path: String,
        body: [String: Any],
        provider: AgentRemoteProvider,
        apiKey: String?,
        endpointBaseURLOverride: URL? = nil
    ) throws -> StreamRequestComponents {
        let baseURL = endpointBaseURLOverride?.absoluteString ?? provider.baseURL
        var headers = [
            RemoteHTTPHeader(name: "Content-Type", value: "application/json"),
            RemoteHTTPHeader(name: "Accept", value: "text/event-stream")
        ]
        if let apiKey {
            headers.append(
                RemoteHTTPHeader(name: "Authorization", value: "Bearer \(apiKey)")
            )
        }
        return StreamRequestComponents(
            url: try endpointURL(path: path, baseURL: baseURL),
            headers: headers,
            body: try JSONValue(jsonObject: body).jsonData(
                outputFormatting: [.withoutEscapingSlashes]
            )
        )
    }

    static func shouldRetryStreamOpening(
        error: Error,
        attempt: Int
    ) -> Bool {
        guard attempt >= 0,
              attempt < maximumStreamOpeningRetries else {
            return false
        }
        guard let transportError = error as? RemoteTransportError else {
            return false
        }
        switch transportError {
        case .tlsFailure, .connectionFailure, .closed:
            // `RemoteTransportCore.openHTTPStream` returns only after the
            // response head. Therefore these errors are still in the bounded
            // opening window and are the only safe point for this retry loop.
            return true
        default:
            return false
        }
    }

    static func streamOpeningRetryDelayNanoseconds(attempt: Int) -> UInt64 {
        let exponent = UInt64(max(0, min(attempt, 10)))
        return streamOpeningRetryBaseDelayNanoseconds << exponent
    }

    // MARK: - Response validation

    public static func validateHTTPResponse(
        _ response: RemoteHTTPStreamingResponse,
        bodyLimit: Int = 64 * 1024
    ) async throws {
        guard !(200..<300).contains(response.status) else {
            return
        }
        let output = try await collectErrorBody(
            from: response.body,
            limit: bodyLimit
        )
        if let message = responseErrorMessage(from: output)?.nilIfBlank {
            throw RemoteGenerationClientError.remoteFailure(message)
        }
        if let output = output.nilIfBlank {
            throw RemoteGenerationClientError.remoteFailure(output)
        }
        throw RemoteGenerationClientError.httpStatus(response.status)
    }

    // MARK: - Error body

    public static func collectErrorBody(
        from body: RemoteHTTPBody,
        limit: Int = 64 * 1024
    ) async throws -> String {
        var data = Data()
        for try await chunk in body {
            if data.count >= limit {
                break
            }
            let remaining = limit - data.count
            data.append(contentsOf: chunk.prefix(remaining))
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
        // Keep this typed as a dictionary so overload resolution uses the
        // envelope-aware variant below rather than the generic `Any?` helper.
        // The generic variant intentionally only describes an error object;
        // this root response can instead carry that object under `error`.
        let nativeObject: [String: Any] = object.mapValues { $0.jsonObject }
        return responseErrorMessage(from: nativeObject)
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

    struct StreamRequestComponents {
        let url: URL
        let headers: [RemoteHTTPHeader]
        let body: Data
    }
}
