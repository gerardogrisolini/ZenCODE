//
//  JiraSetupAndConfiguration.swift
//  ZenCODE
//

import Foundation
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif
import ZenCODECore

enum JiraSetupRunner {
    static func run() async -> Int32 {
        do {
            writeLine("Jira setup")
            writeLine("Configure a Jira Cloud site for ZenCODE.")
            writeLine("")

            let currentConfiguration = try? JiraConfigurationStore.load()
            let sitePromptDefault = currentConfiguration?.siteURLString
            guard let rawSiteURL = promptLine(
                "Jira site URL",
                defaultValue: sitePromptDefault,
                required: true
            ) else {
                throw JiraToolsError.invalidConfiguration("Jira site URL is required.")
            }

            let siteURL = try JiraStoredConfiguration.normalizedSiteURL(from: rawSiteURL)
            guard let email = promptLine(
                "Atlassian email",
                defaultValue: currentConfiguration?.email,
                required: true
            ) else {
                throw JiraToolsError.invalidConfiguration("Atlassian email is required.")
            }
            guard let apiToken = promptSecretLine("Atlassian API token", required: true) else {
                throw JiraToolsError.invalidConfiguration("Atlassian API token is required.")
            }

            let configuration = JiraStoredConfiguration(
                siteURLString: siteURL.absoluteString,
                email: email
            )
            let service = JiraRESTService(configuration: configuration, apiToken: apiToken)
            let accountName = try await service.validateCredentials()
            try JiraConfigurationStore.save(configuration)
            try JiraCredentialStore.save(apiToken, account: configuration.credentialAccount)

            writeLine("")
            writeLine("Jira connected: \(siteURL.host ?? siteURL.absoluteString) as \(accountName).")
            return 0
        } catch {
            writeLine("", stderr: true)
            writeLine("ZenCODE: \(error.localizedDescription)", stderr: true)
            return 1
        }
    }

    private static func promptLine(
        _ label: String,
        defaultValue: String? = nil,
        required: Bool = false
    ) -> String? {
        while true {
            let suffix = defaultValue?.trimmedNonEmpty.map { " [\($0)]" } ?? ""
            write("\(label)\(suffix): ")
            let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = value?.isEmpty == false ? value : defaultValue
            if let resolved = resolved?.trimmedNonEmpty {
                return resolved
            }
            guard required else {
                return nil
            }
            writeLine("\(label) is required.")
        }
    }

    private static func promptSecretLine(
        _ label: String,
        required: Bool = false
    ) -> String? {
        #if os(macOS)
        guard isatty(STDIN_FILENO) == 1 else {
            return promptLine(label, required: required)
        }

        while true {
            write("\(label): ")
            var originalAttributes = termios()
            guard tcgetattr(STDIN_FILENO, &originalAttributes) == 0 else {
                return promptLine(label, required: required)
            }

            var hiddenAttributes = originalAttributes
            hiddenAttributes.c_lflag &= ~tcflag_t(ECHO)
            guard tcsetattr(STDIN_FILENO, TCSANOW, &hiddenAttributes) == 0 else {
                return promptLine(label, required: required)
            }
            let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
            var restoreAttributes = originalAttributes
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &restoreAttributes)
            writeLine("")

            if let value = value?.trimmedNonEmpty {
                return value
            }
            guard required else {
                return nil
            }
            writeLine("\(label) is required.")
        }
        #else
        return promptLine(label, required: required)
        #endif
    }
}

struct JiraStoredConfiguration: Codable, Hashable, Sendable {
    let siteURLString: String
    let email: String

    var siteURL: URL {
        URL(string: siteURLString)!
    }

    var credentialAccount: String {
        "\(siteURL.host ?? siteURLString)|\(email.lowercased())"
    }

    static func normalizedSiteURL(from rawValue: String) throws -> URL {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.localizedCaseInsensitiveContains("://") {
            value = "https://\(value)"
        }

        guard var components = URLComponents(string: value),
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw JiraToolsError.invalidConfiguration("Invalid Jira site URL: \(rawValue)")
        }

        components.scheme = components.scheme?.lowercased() ?? "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw JiraToolsError.invalidConfiguration("Invalid Jira site URL: \(rawValue)")
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
        AppStorageDirectory
            .appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(filename)
            .standardizedFileURL
    }
}
