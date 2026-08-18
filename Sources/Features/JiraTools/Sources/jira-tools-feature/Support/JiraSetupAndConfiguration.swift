//
//  JiraSetupAndConfiguration.swift
//  ZenCODE
//

import Foundation
import ToolCore

enum JiraSetupRunner {
    static func run() async -> Int32 {
        do {
            let result = try await authenticate(reason: .manual)
            let host = result.configuration.siteURL.host ?? result.configuration.siteURLString
            writeLine("Jira connected: \(host) as \(result.accountName).", stderr: true)
            return 0
        } catch {
            writeLine("", stderr: true)
            writeLine("ZenCODE: \(error.localizedDescription)", stderr: true)
            return 1
        }
    }

    static func authenticateFromTool(reason: JiraAuthenticationReason) async throws -> JiraRESTService {
        let result = try await authenticate(reason: reason)
        return JiraRESTService(configuration: result.configuration, apiToken: result.apiToken)
    }

    /// Runs the browser-based setup flow. The user completes the connection in a
    /// local web form; no terminal prompt is used, so it works while running as a
    /// tool subprocess.
    private static func authenticate(
        reason: JiraAuthenticationReason
    ) async throws -> JiraAuthenticatedConfiguration {
        #if os(macOS)
        let defaults = try? JiraConfigurationStore.load()
        return try await JiraBrowserSetup.authenticate(reason: reason, defaults: defaults)
        #else
        throw JiraToolsError.browserSetupFailed(
            "Jira browser setup is only available on macOS."
        )
        #endif
    }
}

enum JiraAuthenticationReason {
    case manual
    case missingConfiguration
    case missingCredentials
    case invalidCredentials

    var message: String {
        switch self {
        case .manual:
            return "Configure a Jira Cloud site for ZenCODE."
        case .missingConfiguration:
            return "No Jira configuration was found. Configure a Jira Cloud site to continue."
        case .missingCredentials:
            return "No Jira API token was found. Enter a token to continue."
        case .invalidCredentials:
            return "The stored Jira API token is not valid. Enter a new token to continue."
        }
    }
}

struct JiraStoredConfiguration: Codable, Hashable, Sendable {
    let siteURLString: String
    let email: String

    /// Validated and normalised at construction time so `siteURL` never
    /// force-unwraps.
    private let validatedSiteURL: URL

    var siteURL: URL { validatedSiteURL }

    var credentialAccount: String {
        "\(siteURL.host ?? siteURLString)|\(email.lowercased())"
    }

    private enum CodingKeys: String, CodingKey {
        case siteURLString, email
    }

    init(siteURLString: String, email: String) throws {
        let url = try Self.normalizedSiteURL(from: siteURLString)
        self.siteURLString = url.absoluteString
        self.email = email
        self.validatedSiteURL = url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawURLString = try container.decode(String.self, forKey: .siteURLString)
        // Normalization failures propagate as `JiraToolsError` (not
        // `DecodingError`) so stored `http://` configurations surface an
        // actionable message instead of failing as generic corrupt JSON.
        let url = try Self.normalizedSiteURL(from: rawURLString)
        self.siteURLString = url.absoluteString
        self.email = try container.decode(String.self, forKey: .email)
        self.validatedSiteURL = url
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(siteURLString, forKey: .siteURLString)
        try container.encode(email, forKey: .email)
    }

    /// Normalizes the user- or store-supplied Jira site URL.
    ///
    /// HTTPS is mandatory: the REST client authenticates with an email/API
    /// token pair sent as a Basic `Authorization` header, which must never
    /// travel over an unencrypted connection. The function is fail-closed —
    /// `http` (and every other scheme) is rejected with an explicit error
    /// that tells the user which `https` URL to use. URLs without a scheme
    /// default to `https`.
    static func normalizedSiteURL(from rawValue: String) throws -> URL {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitScheme = value.localizedCaseInsensitiveContains("://")
        if !hasExplicitScheme {
            value = "https://\(value)"
        }

        guard var components = URLComponents(string: value),
              let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            throw JiraToolsError.invalidConfiguration(
                "Invalid Jira site URL: \(rawValue). Enter the full site URL, e.g. https://your-domain.atlassian.net."
            )
        }

        guard components.user == nil, components.password == nil else {
            throw JiraToolsError.invalidConfiguration(
                "Jira site URL must not embed credentials: \(rawValue). Provide the Atlassian email and API token in their own fields instead."
            )
        }

        let scheme = components.scheme?.lowercased() ?? "https"
        guard scheme == "https" else {
            if scheme == "http" {
                throw JiraToolsError.invalidConfiguration(
                    "Jira site URL must use HTTPS: 'http://\(host)' would send your Atlassian credentials over an unencrypted connection. Use 'https://\(host)' instead."
                )
            }
            throw JiraToolsError.invalidConfiguration(
                "Unsupported Jira site URL scheme '\(scheme)'. Only https site URLs are supported."
            )
        }

        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw JiraToolsError.invalidConfiguration("Invalid Jira site URL: \(rawValue).")
        }
        return url
    }
}

enum JiraConfigurationStore {
    private static let filename = "jira.json"

    static func load(fileManager: FileManager = .default) throws -> JiraStoredConfiguration {
        let url = configurationURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url) else {
            throw JiraToolsError.notConfigured
        }
        do {
            return try JSONDecoder().decode(JiraStoredConfiguration.self, from: data)
        } catch let error as JiraToolsError {
            // Preserve the actionable reason (e.g. a stored `http://` site
            // URL) instead of collapsing every failure into "invalid JSON".
            throw JiraToolsError.invalidConfiguration(
                "Invalid Jira configuration at \(url.path). \(error.localizedDescription)"
            )
        } catch {
            throw JiraToolsError.invalidConfiguration("Invalid jira.json at \(url.path).")
        }
    }

    static func save(
        _ configuration: JiraStoredConfiguration,
        fileManager: FileManager = .default
    ) throws {
        let url = configurationURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: [.atomic])
    }

    private static func configurationURL(fileManager: FileManager = .default) -> URL {
        JiraFeatureStorageDirectory
            .supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(filename)
            .standardizedFileURL
    }
}

private enum JiraFeatureStorageDirectory {
    private static let supportDirectoryEnvironmentKey = "ZENCODE_SUPPORT_DIRECTORY"
    private static let supportDirectoryName = ".zencode"

    static func supportDirectoryURL(fileManager: FileManager = .default) -> URL {
        if let configuredPath = normalizedPath(ProcessInfo.processInfo.environment[supportDirectoryEnvironmentKey]) {
            return URL(fileURLWithPath: configuredPath, isDirectory: true)
                .standardizedFileURL
        }
        return homeDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    private static func homeDirectoryURL(fileManager: FileManager) -> URL {
        #if os(Windows)
        if let profile = normalizedPath(ProcessInfo.processInfo.environment["USERPROFILE"]) {
            return URL(fileURLWithPath: profile, isDirectory: true)
        }
        #else
        if let home = normalizedPath(ProcessInfo.processInfo.environment["HOME"]) {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        #endif
        return fileManager.homeDirectoryForCurrentUser
    }

    private static func normalizedPath(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
