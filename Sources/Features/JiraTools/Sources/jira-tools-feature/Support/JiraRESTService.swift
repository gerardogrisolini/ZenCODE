//
//  JiraRESTService.swift
//  ZenCODE
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ToolCore

struct JiraIssueSummary: Hashable, Sendable {
    let key: String
    let summary: String
    let status: String?
    let issueType: String?
    let assignee: String?
    let url: URL
}

struct JiraIssueDetail: Sendable {
    let key: String
    let summary: String
    let status: String?
    let issueType: String?
    let assignee: String?
    let priority: String?
    let url: URL
    let description: String?
    let acceptanceCriteria: [String]
    let designURLs: [String]
    let referenceURLs: [String]
    let notableFields: [(name: String, value: String)]
    let rawPayload: JSONValue
}

actor JiraRESTService {
    private let configuration: JiraStoredConfiguration
    private let apiToken: String

    init(configuration: JiraStoredConfiguration, apiToken: String) {
        self.configuration = configuration
        self.apiToken = apiToken
    }

    static func loadConfigured() throws -> JiraRESTService {
        let configuration = try JiraConfigurationStore.load()
        let apiToken = try JiraCredentialStore.load(account: configuration.credentialAccount)
        return JiraRESTService(configuration: configuration, apiToken: apiToken)
    }

    func validateCredentials() async throws -> String {
        let result = try await request(
            path: "/rest/api/3/myself",
            queryItems: []
        )
        return result["displayName"]?.stringValue
            ?? result["emailAddress"]?.stringValue
            ?? configuration.email
    }

    func searchIssues(matching query: String) async throws -> [JiraIssueSummary] {
        if let issueKey = JiraIssueKeyExtractor.issueKey(in: query) {
            let issue = try await fetchIssue(issueKey: issueKey)
            return [JiraIssueParser.summary(from: issue)]
        }

        let result = try await request(
            path: "/rest/api/3/issue/picker",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "currentJQL", value: "")
            ]
        )
        let summaries = JiraIssueParser.issueSummaries(
            fromPickerResult: result,
            siteURL: configuration.siteURL
        )
        return Array(summaries.prefix(12))
    }

    func loadIssue(matching query: String) async throws -> JiraIssueDetail {
        if let issueKey = JiraIssueKeyExtractor.issueKey(in: query) {
            return try await fetchIssue(issueKey: issueKey)
        }

        let matches = try await searchIssues(matching: query)
        guard matches.count == 1,
              let issueKey = matches.first?.key else {
            throw JiraToolsError.requestFailed(
                "Jira search returned \(matches.count) issues. Call jira.search first, then call jira.read with the selected issue key."
            )
        }
        return try await fetchIssue(issueKey: issueKey)
    }

    private func fetchIssue(issueKey: String) async throws -> JiraIssueDetail {
        let result = try await request(
            path: "/rest/api/3/issue/\(issueKey)",
            queryItems: [
                URLQueryItem(name: "fields", value: "*all"),
                URLQueryItem(name: "expand", value: "names")
            ]
        )
        guard let detail = JiraIssueParser.issueDetail(
            from: result,
            siteURL: configuration.siteURL
        ) else {
            throw JiraToolsError.issueNotFound(issueKey)
        }
        return detail
    }

    private func request(path: String, queryItems: [URLQueryItem]) async throws -> JSONValue {
        guard var components = URLComponents(url: configuration.siteURL, resolvingAgainstBaseURL: false) else {
            throw JiraToolsError.requestFailed("Unable to build Jira request URL.")
        }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw JiraToolsError.requestFailed("Unable to build Jira request URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JiraToolsError.requestFailed("Invalid Jira response.")
        }
        let responseText = responseMessage(from: data)
        if httpResponse.statusCode == 401 {
            throw JiraToolsError.authenticationFailed(
                statusCode: httpResponse.statusCode,
                message: responseText
            )
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw JiraToolsError.requestFailed(
                "Jira request failed with HTTP \(httpResponse.statusCode). \(responseText)"
            )
        }

        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw JiraToolsError.requestFailed("Invalid Jira JSON response.")
        }
    }

    private var authorizationHeader: String {
        let credentials = "\(configuration.email):\(apiToken)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }

    private func responseMessage(from data: Data) -> String {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let message = value["message"]?.stringValue {
                return message
            }
            if let messages = value["errorMessages"]?.arrayValue,
               !messages.isEmpty {
                return messages.compactMap(\.stringValue).joined(separator: " ")
            }
        }
        return String(decoding: data.prefix(400), as: UTF8.self)
    }
}

enum JiraAuthenticatedService {
    static func run<T>(
        _ operation: (JiraRESTService) async throws -> T
    ) async throws -> T {
        let resolved = try await configuredService()
        do {
            return try await operation(resolved.service)
        } catch let error as JiraToolsError {
            guard !resolved.didAuthenticate,
                  let reason = error.authenticationReason else {
                throw error
            }
            let service = try await JiraSetupRunner.authenticateFromTool(reason: reason)
            return try await operation(service)
        }
    }

    private static func configuredService() async throws -> ServiceResolution {
        do {
            return ServiceResolution(
                service: try JiraRESTService.loadConfigured(),
                didAuthenticate: false
            )
        } catch let error as JiraToolsError {
            guard let reason = error.authenticationReason else {
                throw error
            }
            return ServiceResolution(
                service: try await JiraSetupRunner.authenticateFromTool(reason: reason),
                didAuthenticate: true
            )
        }
    }

    private struct ServiceResolution: Sendable {
        let service: JiraRESTService
        let didAuthenticate: Bool
    }
}

extension JiraToolsError {
    var authenticationReason: JiraAuthenticationReason? {
        switch self {
        case .notConfigured:
            return .missingConfiguration
        case .missingCredentials:
            return .missingCredentials
        case .authenticationFailed:
            return .invalidCredentials
        default:
            return nil
        }
    }
}
