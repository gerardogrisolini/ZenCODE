//
//  OpenAIRealtimeModel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/09/26.
//

import Foundation

/// Model-ID based detection of OpenAI realtime voice models.
///
/// Realtime models are configured like any other OpenAI API model; no extra
/// protocol profile or persisted setting identifies them. The provider's base
/// URL supplies the host for the realtime WebSocket endpoint.
public enum OpenAIRealtimeModel {
    public static let modelIDPrefix = "gpt-realtime"

    public static func matches(provider: AgentRemoteProvider, modelID: String) -> Bool {
        provider.providerProfileID == .openAI
            && !provider.isChatGPTSubscriptionProvider
            && modelID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix(modelIDPrefix)
    }

    /// `wss://<host>/v1/realtime?model=<modelID>` for an HTTPS base URL. A
    /// plain-HTTP base URL maps to `ws`, so the transport security of the
    /// configured endpoint is never upgraded or downgraded silently.
    public static func webSocketURL(baseURL: String, modelID: String) -> URL? {
        guard let base = URLComponents(
            string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ),
            let host = base.host,
            !host.isEmpty else {
            return nil
        }

        var components = URLComponents()
        switch base.scheme?.lowercased() {
        case "https", "wss":
            components.scheme = "wss"
        case "http", "ws":
            components.scheme = "ws"
        default:
            return nil
        }
        components.host = host
        components.port = base.port
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: modelID)]
        return components.url
    }
}
