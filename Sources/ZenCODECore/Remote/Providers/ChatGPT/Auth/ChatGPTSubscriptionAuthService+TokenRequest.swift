//
//  ChatGPTSubscriptionAuthService+TokenRequest.swift
//  ZenCODE
//
//  HTTP OAuth token request of ChatGPT Subscription and its responses.
//

import Foundation

extension ChatGPTSubscriptionAuthService {
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    static func exchangeAuthorizationCode(
        code: String,
        verifier: String,
        redirectURI: String
    ) async throws -> CodexAgentCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI
        ])
    }

    static func refreshAccessToken(
        refreshToken: String
    ) async throws -> CodexAgentCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
    }

    private static func tokenRequest(
        parameters: [String: String]
    ) async throws -> CodexAgentCredentials {
        let request = RemoteHTTPStreamingRequest(
            url: tokenURL,
            method: "POST",
            headers: [
                RemoteHTTPHeader(
                    name: "Content-Type",
                    value: "application/x-www-form-urlencoded"
                )
            ],
            body: formURLEncodedBody(parameters)
        )
        let response = try await RemoteTransportCore().sendRequest(request)

        guard (200..<300).contains(response.status) else {
            throw ChatGPTSubscriptionAuthError.tokenExchangeFailed(
                status: response.status,
                body: String(decoding: response.body, as: UTF8.self)
            )
        }

        let tokenResponse: TokenResponse
        do {
            tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: response.body)
        } catch {
            throw ChatGPTSubscriptionAuthError.invalidTokenResponse
        }
        let accessToken = tokenResponse.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = tokenResponse.refreshToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty,
              !refreshToken.isEmpty,
              tokenResponse.expiresIn > 0 else {
            throw ChatGPTSubscriptionAuthError.invalidTokenResponse
        }

        return CodexAgentCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            accountID: try ChatGPTSubscriptionAuthService.chatGPTAccountID(from: accessToken)
        )
    }

    private static func formURLEncodedBody(_ values: [String: String]) -> Data {
        let encoded = values
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(urlEncoded(key))=\(urlEncoded(value))"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func urlEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
