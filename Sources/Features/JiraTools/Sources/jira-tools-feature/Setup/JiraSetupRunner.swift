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

    /// Runs the browser-based setup flow on macOS: the user completes the
    /// connection in a local web form; no terminal prompt is used, so it works
    /// while running as a tool subprocess. On other platforms the configuration
    /// is read from the `ZENCODE_JIRA_*` environment variables, validated
    /// against Jira, and only then persisted.
    private static func authenticate(reason: JiraAuthenticationReason) async throws -> JiraAuthenticatedConfiguration {
        #if os(macOS)
        let defaults = try? JiraConfigurationStore.load()
        return try await JiraBrowserSetup.authenticate(reason: reason, defaults: defaults)
        #else
        guard let resolved = try JiraEnvironmentConfiguration.resolve(
            environment: ProcessInfo.processInfo.environment
        ) else {
            throw JiraToolsError.environmentConfigurationRequired(
                missing: JiraEnvironmentConfiguration.allKeys,
                reason: reason.message
            )
        }
        let service = JiraRESTService(configuration: resolved.configuration, apiToken: resolved.apiToken)
        let accountName = try await service.validateCredentials()
        try JiraConfigurationStore.save(resolved.configuration)
        try JiraCredentialStore.save(resolved.apiToken, account: resolved.configuration.credentialAccount)
        return JiraAuthenticatedConfiguration(
            configuration: resolved.configuration,
            apiToken: resolved.apiToken,
            accountName: accountName
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
