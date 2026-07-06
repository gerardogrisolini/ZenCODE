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
import ToolCore

enum JiraSetupRunner {
    static func run() async -> Int32 {
        do {
            _ = try await authenticate(reason: .manual, console: .standard)
            return 0
        } catch {
            writeLine("", stderr: true)
            writeLine("ZenCODE: \(error.localizedDescription)", stderr: true)
            return 1
        }
    }

    static func authenticateFromTool(reason: JiraAuthenticationReason) async throws -> JiraRESTService {
        let console = try JiraSetupConsole.terminal()
        let result = try await authenticate(reason: reason, console: console)
        return JiraRESTService(configuration: result.configuration, apiToken: result.apiToken)
    }

    private static func authenticate(
        reason: JiraAuthenticationReason,
        console: JiraSetupConsole
    ) async throws -> JiraAuthenticatedConfiguration {
        console.writeLine("Jira setup")
        console.writeLine(reason.message)
        console.writeLine("")

        let currentConfiguration = try? JiraConfigurationStore.load()
        let sitePromptDefault = currentConfiguration?.siteURLString
        guard let rawSiteURL = console.promptLine(
            "Jira site URL",
            defaultValue: sitePromptDefault,
            required: true
        ) else {
            throw JiraToolsError.invalidConfiguration("Jira site URL is required.")
        }

        let siteURL = try JiraStoredConfiguration.normalizedSiteURL(from: rawSiteURL)
        guard let email = console.promptLine(
            "Atlassian email",
            defaultValue: currentConfiguration?.email,
            required: true
        ) else {
            throw JiraToolsError.invalidConfiguration("Atlassian email is required.")
        }
        guard let apiToken = console.promptSecretLine("Atlassian API token", required: true) else {
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

        console.writeLine("")
        console.writeLine("Jira connected: \(siteURL.host ?? siteURL.absoluteString) as \(accountName).")
        return JiraAuthenticatedConfiguration(configuration: configuration, apiToken: apiToken)
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

private struct JiraAuthenticatedConfiguration {
    let configuration: JiraStoredConfiguration
    let apiToken: String
}

private struct JiraSetupConsole: @unchecked Sendable {
    let input: FileHandle
    let output: FileHandle
    let terminalFileDescriptor: Int32?

    static var standard: JiraSetupConsole {
        JiraSetupConsole(
            input: .standardInput,
            output: .standardOutput,
            terminalFileDescriptor: STDIN_FILENO
        )
    }

    static func terminal() throws -> JiraSetupConsole {
        #if os(macOS) || os(Linux)
        let fileDescriptor = open("/dev/tty", O_RDWR)
        guard fileDescriptor >= 0, isatty(fileDescriptor) == 1 else {
            if fileDescriptor >= 0 {
                close(fileDescriptor)
            }
            throw JiraToolsError.interactiveAuthenticationUnavailable
        }
        let terminal = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        return JiraSetupConsole(
            input: terminal,
            output: terminal,
            terminalFileDescriptor: fileDescriptor
        )
        #else
        throw JiraToolsError.interactiveAuthenticationUnavailable
        #endif
    }

    func promptLine(
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

    func promptSecretLine(
        _ label: String,
        required: Bool = false
    ) -> String? {
        #if os(macOS) || os(Linux)
        guard let terminalFileDescriptor,
              isatty(terminalFileDescriptor) == 1 else {
            return promptLine(label, required: required)
        }

        while true {
            write("\(label): ")
            var originalAttributes = termios()
            guard tcgetattr(terminalFileDescriptor, &originalAttributes) == 0 else {
                return promptLine(label, required: required)
            }

            var hiddenAttributes = originalAttributes
            hiddenAttributes.c_lflag &= ~tcflag_t(ECHO)
            guard tcsetattr(terminalFileDescriptor, TCSANOW, &hiddenAttributes) == 0 else {
                return promptLine(label, required: required)
            }
            let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
            var restoreAttributes = originalAttributes
            _ = tcsetattr(terminalFileDescriptor, TCSANOW, &restoreAttributes)
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

    func write(_ string: String) {
        output.write(Data(string.utf8))
    }

    func writeLine(_ string: String) {
        write(string + "\n")
    }

    func readLine() -> String? {
        var data = Data()
        while true {
            let chunk = input.readData(ofLength: 1)
            guard let byte = chunk.first else {
                return data.isEmpty ? nil : String(data: data, encoding: .utf8)
            }
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                return String(data: data, encoding: .utf8)
            }
            data.append(byte)
        }
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
