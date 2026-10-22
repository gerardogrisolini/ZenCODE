import Foundation
import ToolCore

enum JiraToolsError: LocalizedError {
    case missingArgument(String)
    case notConfigured
    case invalidConfiguration(String)
    case missingCredentials
    case authenticationFailed(statusCode: Int, message: String)
    case browserSetupFailed(String)
    case browserSetupTimedOut
    case requestFailed(String)
    case issueNotFound(String, message: String? = nil)
    case keychain(Int32)
    case environmentConfigurationRequired(missing: [String], reason: String? = nil)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name):
            return "Missing Jira tool argument: \(name)."
        case .notConfigured:
            return "Jira is not configured. The next interactive Jira tool call will start setup."
        case let .invalidConfiguration(message):
            return message
        case .missingCredentials:
            return "Jira API token was not found. The next interactive Jira tool call will start setup."
        case let .authenticationFailed(statusCode, message):
            return "Jira authentication failed with HTTP \(statusCode). \(message)"
        case let .browserSetupFailed(message):
            return message
        case .browserSetupTimedOut:
            return "Jira setup timed out waiting for the browser sign-in. Run the Jira tool again to retry."
        case let .requestFailed(message):
            return message
        case let .issueNotFound(issueKey, message):
            guard let message = message?.nilIfBlank else {
                return "Unable to load Jira issue \(issueKey) from the REST API."
            }
            return "Jira issue \(issueKey) was not found (HTTP 404): the issue does not exist or the account cannot view it. \(message)"
        case let .keychain(status):
            return "Unable to access the Jira API token in Keychain (\(status))."
        case let .environmentConfigurationRequired(missing, reason):
            let prefix = reason.map { "\($0) " } ?? ""
            return "\(prefix)Jira is not configured. On Linux, set ZENCODE_JIRA_SITE_URL, ZENCODE_JIRA_EMAIL and ZENCODE_JIRA_API_TOKEN in the environment of `zen` and retry (missing: \(missing.joined(separator: ", ")))."
        }
    }
}
