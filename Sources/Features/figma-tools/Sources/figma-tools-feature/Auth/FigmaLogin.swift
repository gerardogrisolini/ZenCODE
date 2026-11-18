//
//  FigmaLogin.swift
//  ZenCODE
//
//  Figma sign-in. The feature opens a local sign-in page in the user's
//  browser, verifies the access token entered there against Figma
//  (`GET /v1/me`), and stores the login with FigmaCredentialStore. Tools
//  start it automatically when nobody is signed in or Figma rejects the
//  stored login. Credentials are never read from environment variables.
//

import Foundation
import ToolCore

enum FigmaLoginReason: Equatable, Sendable {
    case manual
    case notSignedIn
    case unusableStoredLogin(String)
    case rejected(String)

    var message: String {
        switch self {
        case .manual:
            return "Connect your Figma account to ZenCODE."
        case .notSignedIn:
            return "ZenCODE is not signed in to Figma yet. Sign in to continue."
        case let .unusableStoredLogin(detail):
            return "The stored Figma login is not usable (\(detail)). Sign in again to continue."
        case let .rejected(detail):
            return "Figma rejected the stored login (\(detail)). Sign in again to continue."
        }
    }
}

enum FigmaLogin {
    /// How long a tool call waits for the user to finish signing in. The
    /// manifest's invocation timeout is longer than this.
    static let timeout: TimeInterval = 600

    /// Runs the browser sign-in and stores the verified login.
    static func signIn(reason: FigmaLoginReason, store: FigmaCredentialStore) async throws -> FigmaStoredCredential {
        #if os(macOS)
        let server = try FigmaLoginServer(reason: reason) { token in
            await verify(token: token)
        }
        let credential: FigmaStoredCredential
        do {
            let port = try await server.start()
            let url = URL(string: "http://127.0.0.1:\(port)/")!
            log("Figma login: sign in on the page opened in your browser (\(url.absoluteString)).")
            openBrowser(url)
            credential = try await server.waitForResult(timeout: timeout)
        } catch is CancellationError {
            server.stop()
            throw FigmaToolsError.loginFailed("the sign-in was cancelled.")
        } catch {
            server.stop()
            throw error
        }
        // Stop first so no other in-flight submission can win, then persist
        // the single accepted login exactly once.
        server.stop()
        try store.save(credential)
        log("Figma login: signed in as \(credential.accountLabel).")
        return credential
        #else
        throw FigmaToolsError.loginUnavailable
        #endif
    }

    /// Checks a submitted token against Figma without touching local state.
    static func verify(token rawToken: String) async -> Result<FigmaStoredCredential, FigmaLoginValidationError> {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .failure(FigmaLoginValidationError(message: "Paste your Figma access token."))
        }
        guard FigmaCredentialStore.isWellFormedToken(token) else {
            return .failure(FigmaLoginValidationError(
                message: "That does not look like a Figma access token. Paste it exactly as Figma shows it."
            ))
        }
        do {
            let me = try await FigmaRESTClient(accessToken: token).me()
            return .success(FigmaStoredCredential(
                accessToken: token,
                accountHandle: me["handle"]?.stringValue,
                accountEmail: me["email"]?.stringValue,
                signedInAt: Date()
            ))
        } catch let error as FigmaToolsError {
            let message: String
            if case let .authenticationFailed(detail) = error {
                message = "Figma did not accept this token: \(detail) Check that it is current and has the \(FigmaLoginPage.requiredScopes.joined(separator: " and ")) scopes."
            } else {
                message = error.localizedDescription
            }
            return .failure(FigmaLoginValidationError(message: message))
        } catch {
            return .failure(FigmaLoginValidationError(message: "Could not reach Figma: \(error.localizedDescription)"))
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    #if os(macOS)
    private static func openBrowser(_ url: URL) {
        let openURL = URL(fileURLWithPath: "/usr/bin/open")
        guard FileManager.default.isExecutableFile(atPath: openURL.path) else { return }
        let process = Process()
        process.executableURL = openURL
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
    #endif
}

/// Runs Figma API work with the stored login, signing in first when needed
/// and signing in again once if Figma rejects the stored login.
enum FigmaSession {
    static func run<T>(
        environment: [String: String],
        _ operation: (FigmaRESTClient) async throws -> T
    ) async throws -> T {
        let store = FigmaCredentialStore(environment: environment)
        var credential: FigmaStoredCredential
        var signedInNow = false
        do {
            if let stored = try store.load() {
                credential = stored
            } else {
                credential = try await FigmaLogin.signIn(reason: .notSignedIn, store: store)
                signedInNow = true
            }
        } catch let FigmaToolsError.invalidCredentialStore(detail) {
            credential = try await FigmaLogin.signIn(reason: .unusableStoredLogin(detail), store: store)
            signedInNow = true
        }

        do {
            return try await operation(FigmaRESTClient(accessToken: credential.accessToken))
        } catch let FigmaToolsError.authenticationFailed(detail) where !signedInNow {
            credential = try await FigmaLogin.signIn(reason: .rejected(detail), store: store)
            return try await operation(FigmaRESTClient(accessToken: credential.accessToken))
        }
    }

    /// The stored login without any network access or sign-in prompt.
    static func storedLogin(environment: [String: String]) -> FigmaStoredCredential? {
        try? FigmaCredentialStore(environment: environment).load()
    }
}
