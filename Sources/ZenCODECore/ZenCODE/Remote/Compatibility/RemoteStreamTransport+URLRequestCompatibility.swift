//
//  RemoteStreamTransport+URLRequestCompatibility.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension RemoteStreamTransport {
    /// Preserves the historical request-value builder for source compatibility.
    /// Consumers that execute a request must migrate to
    /// `buildHTTPStreamingRequest` and `RemoteTransportCore`.
    public static func buildStreamRequest(
        path: String,
        body: [String: Any],
        provider: AgentRemoteProvider,
        apiKey: String?
    ) throws -> URLRequest {
        let components = try streamRequestComponents(
            path: path,
            body: body,
            provider: provider,
            apiKey: apiKey
        )
        var request = URLRequest(url: components.url)
        request.httpMethod = "POST"
        for header in components.headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        request.httpBody = components.body
        return request
    }
}
