//
//  ChatGPTSubscriptionAuthService+DeviceCode.swift
//  ZenCODE
//
//  Device code sign-in flow of ChatGPT Subscription.
//

import Foundation

extension ChatGPTSubscriptionAuthService {
    private static let deviceCodeURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/usercode")!
    private static let deviceTokenURL = URL(string: "https://auth.openai.com/api/accounts/deviceauth/token")!
    private static let deviceAuthorizationURL = URL(string: "https://auth.openai.com/codex/device")!
    private static let deviceRedirectURI = "https://auth.openai.com/deviceauth/callback"

    public static func signInWithDeviceCode(
        notifyUser: @Sendable (URL, String) async -> Void
    ) async throws -> CodexAgentCredentials {
        try await signInWithDeviceCode(
            persist: true,
            notifyUser: notifyUser
        )
    }

    static func signInWithDeviceCode(
        persist: Bool,
        notifyUser: @Sendable (URL, String) async -> Void
    ) async throws -> CodexAgentCredentials {
        let credentials = try await runDeviceCodeFlow(notifyUser: notifyUser)
        if persist {
            try ChatGPTSubscriptionAuthService.saveCredentials(credentials)
        }
        return credentials
    }

    public static func requestDeviceCode() async throws -> ChatGPTSubscriptionDeviceCode {
        let body = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID
        ])
        let request = RemoteHTTPStreamingRequest(
            url: deviceCodeURL,
            method: "POST",
            headers: [
                RemoteHTTPHeader(name: "Content-Type", value: "application/json"),
                RemoteHTTPHeader(name: "Accept", value: "application/json")
            ],
            body: body
        )
        let response = try await RemoteTransportCore().sendRequest(request)

        guard (200..<300).contains(response.status) else {
            throw ChatGPTSubscriptionAuthError.deviceCodeRequestFailed(
                status: response.status,
                body: String(decoding: response.body, as: UTF8.self)
            )
        }

        return try decodedDeviceCode(from: response.body)
    }

    private static func decodedDeviceCode(
        from data: Data
    ) throws -> ChatGPTSubscriptionDeviceCode {
        let responseBody: DeviceCodeResponse
        do {
            responseBody = try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
        } catch {
            throw ChatGPTSubscriptionAuthError.deviceCodeResponseInvalid
        }

        let userCode = responseBody.userCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceAuthID = responseBody.deviceAuthID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userCode.isEmpty,
              !deviceAuthID.isEmpty else {
            throw ChatGPTSubscriptionAuthError.deviceCodeResponseInvalid
        }
        return ChatGPTSubscriptionDeviceCode(
            userCode: userCode,
            deviceAuthID: deviceAuthID,
            verificationURL: deviceAuthorizationURL,
            pollInterval: max(responseBody.interval?.value ?? 5, 3)
        )
    }

    private static func runDeviceCodeFlow(
        notifyUser: @Sendable (URL, String) async -> Void
    ) async throws -> CodexAgentCredentials {
        let deviceCode = try await requestDeviceCode()
        await notifyUser(deviceCode.verificationURL, deviceCode.userCode)
        let authorization = try await pollDeviceAuthorization(deviceCode)
        return try await exchangeAuthorizationCode(
            code: authorization.authorizationCode,
            verifier: authorization.codeVerifier,
            redirectURI: deviceRedirectURI
        )
    }

    private static func pollDeviceAuthorization(
        _ deviceCode: ChatGPTSubscriptionDeviceCode
    ) async throws -> DeviceAuthorizationResponse {
        let deadline = Date().addingTimeInterval(15 * 60)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(
                nanoseconds: UInt64(deviceCode.pollInterval) * 1_000_000_000
            )

            let body = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": deviceCode.deviceAuthID,
                "user_code": deviceCode.userCode
            ])
            let request = RemoteHTTPStreamingRequest(
                url: deviceTokenURL,
                method: "POST",
                headers: [
                    RemoteHTTPHeader(name: "Content-Type", value: "application/json"),
                    RemoteHTTPHeader(name: "Accept", value: "application/json")
                ],
                body: body
            )
            let response = try await RemoteTransportCore().sendRequest(request)

            if (200..<300).contains(response.status) {
                let responseBody: DeviceAuthorizationResponse
                do {
                    responseBody = try JSONDecoder().decode(
                        DeviceAuthorizationResponse.self,
                        from: response.body
                    )
                } catch {
                    throw ChatGPTSubscriptionAuthError.deviceCodeResponseInvalid
                }
                guard !responseBody.authorizationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !responseBody.codeVerifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ChatGPTSubscriptionAuthError.deviceCodeResponseInvalid
                }
                return responseBody
            }
            if response.status == 403 || response.status == 404 {
                continue
            }
            throw ChatGPTSubscriptionAuthError.deviceCodePollingFailed(
                status: response.status,
                body: String(decoding: response.body, as: UTF8.self)
            )
        }
        throw ChatGPTSubscriptionAuthError.deviceCodeTimedOut
    }

#if DEBUG
    static func testDecodeDeviceCodeResponse(
        _ data: Data
    ) throws -> ChatGPTSubscriptionDeviceCode {
        try decodedDeviceCode(from: data)
    }
#endif
}

public struct ChatGPTSubscriptionDeviceCode: Equatable, Sendable {
    public let userCode: String
    public let deviceAuthID: String
    public let verificationURL: URL
    public let pollInterval: Int
}

private struct DeviceCodeResponse: Decodable {
    let userCode: String
    let deviceAuthID: String
    let interval: FlexibleInt?

    private enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case deviceAuthID = "device_auth_id"
        case interval
    }
}

private struct DeviceAuthorizationResponse: Decodable {
    let authorizationCode: String
    let codeVerifier: String

    private enum CodingKeys: String, CodingKey {
        case authorizationCode = "authorization_code"
        case codeVerifier = "code_verifier"
    }
}

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            value = intValue
            return
        }
        if let stringValue = try? container.decode(String.self) {
            let trimmedValue = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if let intValue = Int(trimmedValue) {
                value = intValue
                return
            }
        }
        throw DecodingError.typeMismatch(
            Int.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected an integer or integer string."
            )
        )
    }
}
