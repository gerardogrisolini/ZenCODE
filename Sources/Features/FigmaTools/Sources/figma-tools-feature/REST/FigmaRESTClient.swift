//
//  FigmaRESTClient.swift
//  ZenCODE
//
//  Minimal client for the Figma cloud REST API (https://api.figma.com).
//  Authenticates with the access token of the stored Figma login, sent in
//  the X-Figma-Token header.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ToolCore

struct FigmaRESTClient: Sendable {
    static let host = "api.figma.com"
    /// Upper bounds that keep one invocation from exhausting memory.
    static let maximumJSONBytes = 64 * 1024 * 1024
    static let maximumImageBytes = 32 * 1024 * 1024

    private let accessToken: String
    private let session: URLSession

    init(accessToken: String, session: URLSession? = nil) {
        self.accessToken = accessToken
        self.session = session ?? Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    // MARK: Endpoints

    /// `GET /v1/me` (scope `current_user:read`).
    func me() async throws -> JSONValue {
        try await getJSON(path: "/v1/me")
    }

    /// `GET /v1/files/:key` limited to `depth` levels (pages = 1).
    func file(key: String, depth: Int) async throws -> JSONValue {
        try await getJSON(
            path: "/v1/files/\(key)",
            query: [URLQueryItem(name: "depth", value: String(depth))]
        )
    }

    /// `GET /v1/files/:key/nodes?ids=...`; returns the node entry for `id`
    /// (`document`, `components`, `styles`, ...).
    func node(key: String, id: String, depth: Int?) async throws -> (file: JSONValue, entry: JSONValue) {
        var query = [URLQueryItem(name: "ids", value: id)]
        if let depth {
            query.append(URLQueryItem(name: "depth", value: String(depth)))
        }
        let response = try await getJSON(path: "/v1/files/\(key)/nodes", query: query)
        guard let entry = response["nodes"]?[id], entry["document"]?.objectValue != nil else {
            throw FigmaToolsError.nodeNotFound(nodeID: id, fileKey: key)
        }
        return (response, entry)
    }

    /// `GET /v1/images/:key?ids=...`; returns the temporary render URL.
    func renderURL(key: String, id: String, format: String, scale: Double) async throws -> URL {
        let response = try await getJSON(
            path: "/v1/images/\(key)",
            query: [
                URLQueryItem(name: "ids", value: id),
                URLQueryItem(name: "format", value: format),
                URLQueryItem(name: "scale", value: FigmaFormat.number(scale))
            ]
        )
        if let error = response["err"]?.stringValue?.nilIfBlank {
            throw FigmaToolsError.renderFailed(error)
        }
        guard let link = response["images"]?[id]?.stringValue,
              let url = URL(string: link),
              url.scheme?.lowercased() == "https" else {
            throw FigmaToolsError.renderFailed(
                "Figma returned no image for node \(id); it may be invisible, empty, or not renderable."
            )
        }
        return url
    }

    /// `GET /v1/files/:key/variables/local` (Enterprise plan, scope
    /// `file_variables:read`).
    func localVariables(key: String) async throws -> JSONValue {
        try await getJSON(path: "/v1/files/\(key)/variables/local")
    }

    /// Downloads a rendered image from the temporary URL returned by Figma.
    /// The token is not sent to the image host.
    func downloadImage(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FigmaToolsError.invalidResponse("image download returned no HTTP response.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw FigmaToolsError.renderFailed("image download failed with HTTP \(httpResponse.statusCode).")
        }
        guard !data.isEmpty, data.count <= Self.maximumImageBytes else {
            throw FigmaToolsError.renderFailed(
                data.isEmpty ? "the rendered image is empty." : "the rendered image exceeds \(Self.maximumImageBytes / 1_048_576) MB; lower scale."
            )
        }
        return data
    }

    // MARK: Transport

    func getJSON(path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = path
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else {
            throw FigmaToolsError.invalidResponse("could not build a request URL for \(path).")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(accessToken, forHTTPHeaderField: "X-Figma-Token")
        request.setValue("ZenCODE figma-tools", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FigmaToolsError.invalidResponse("no HTTP response for \(path).")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw Self.error(status: httpResponse.statusCode, data: data, response: httpResponse)
        }
        guard data.count <= Self.maximumJSONBytes else {
            throw FigmaToolsError.invalidResponse(
                "response larger than \(Self.maximumJSONBytes / 1_048_576) MB; narrow the node or lower depth."
            )
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw FigmaToolsError.invalidResponse("invalid JSON for \(path).")
        }
    }

    static func error(status: Int, data: Data, response: HTTPURLResponse) -> FigmaToolsError {
        if status == 429 {
            return .rateLimited(
                retryAfter: response.value(forHTTPHeaderField: "Retry-After")?.nilIfBlank,
                limitType: response.value(forHTTPHeaderField: "X-Figma-Rate-Limit-Type")?.nilIfBlank
            )
        }
        let body = try? JSONDecoder().decode(JSONValue.self, from: data)
        let serverMessage = body?["err"]?.stringValue?.nilIfBlank
            ?? body?["message"]?.stringValue?.nilIfBlank
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        let sentence = serverMessage.hasSuffix(".") ? serverMessage : serverMessage + "."
        if isTokenRejection(status: status, serverMessage: serverMessage) {
            return .authenticationFailed(sentence)
        }
        let hint = status == 404
            ? " The file or node does not exist, or the signed-in account cannot open it."
            : ""
        return .http(status: status, message: sentence + hint)
    }
}

/// 401 always means the login is unusable; Figma reports invalid, expired,
/// or under-scoped tokens as 403 with a token/scope message. Other 403s
/// (for example a file shared with someone else) keep the current login.
func isTokenRejection(status: Int, serverMessage: String) -> Bool {
    if status == 401 { return true }
    guard status == 403 else { return false }
    let message = serverMessage.lowercased()
    return message.contains("token") || message.contains("scope") || message.contains("credential")
}

extension JSONValue {
    /// Object member lookup; `nil` for non-objects or missing keys.
    subscript(_ key: String) -> JSONValue? {
        objectValue?[key]
    }
}
