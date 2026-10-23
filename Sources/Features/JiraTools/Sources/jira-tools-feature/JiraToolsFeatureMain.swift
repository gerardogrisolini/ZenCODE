import FeatureKit
import ToolCore

struct JiraSearchTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let query: String?
        let jql: String?
    }

    static let name = "jira.search"
    static let description = "Searches Jira issues and returns up to 12 selectable issue summaries. Pass either query or jql, not both. query accepts an issue key, an issue URL, or free text matched against summary, description, comments and text fields (wrap words in double quotes for an exact phrase). jql accepts a JQL expression sent as is, for example project = ABC AND status = \"In Progress\" ORDER BY updated DESC; it must contain at least one search condition."
    static let inputSchema = #"{"type":"object","properties":{"query":{"type":"string"},"jql":{"type":"string"}}}"#

    func run(_ input: Input, context _: FeatureContext) async throws -> String {
        let searchRequest = try JiraSearchRequest.resolve(query: input.query, jql: input.jql)
        let label = input.jql?.nilIfBlank ?? input.query?.nilIfBlank ?? ""

        let issues = try await JiraAuthenticatedService.run { service in
            try await service.searchIssues(searchRequest)
        }
        guard !issues.isEmpty else { return "Jira search: \(label)\nNo issues found." }
        return JiraToolRenderer.renderSearchResults(issues, query: label)
    }
}

struct JiraReadTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let issueKey: String?
        let issue_key: String?
        let key: String?
        let url: String?
        let query: String?
        let includeRaw: Bool?
        let include_raw: Bool?
    }

    static let name = "jira.read"
    static let description = "Loads a Jira issue and returns task context for the model without creating a local task."
    static let inputSchema = #"{"type":"object","properties":{"issueKey":{"type":"string"},"issue_key":{"type":"string"},"key":{"type":"string"},"url":{"type":"string"},"query":{"type":"string"},"includeRaw":{"type":"boolean"},"include_raw":{"type":"boolean"}}}"#

    func run(_ input: Input, context _: FeatureContext) async throws -> String {
        guard let query = [
            input.issueKey,
            input.issue_key,
            input.key,
            input.url,
            input.query
        ].compactMap({ $0?.nilIfBlank }).first else {
            throw JiraToolsError.missingArgument("issueKey")
        }

        let issue = try await JiraAuthenticatedService.run { service in
            try await service.loadIssue(matching: query)
        }
        return JiraToolRenderer.renderTaskContext(issue, includeRaw: input.includeRaw ?? input.include_raw ?? false)
    }
}

struct JiraSignOutTool: FeatureTool {
    struct Input: Decodable, Sendable {}
    static let name = "jira.signOut"
    static let description = "Clears the persisted Jira API token used by the Jira tools."
    static let inputSchema = #"{"type":"object","properties":{}}"#

    func run(_: Input, context _: FeatureContext) async throws -> String {
        let configuration: JiraStoredConfiguration
        do {
            configuration = try JiraConfigurationStore.load()
        } catch JiraToolsError.notConfigured {
            return "Jira is not configured; there are no credentials to clear."
        }
        try JiraCredentialStore.remove(account: configuration.credentialAccount)
        return "Jira credentials cleared. The next Jira tool call will start setup again."
    }
}

@main
struct JiraToolsFeatureMain {
    static func main() async {
        if CommandLine.arguments.dropFirst().contains("--setup") {
            let exitCode = await JiraSetupRunner.run()
            FeatureProcessProtocol.terminate(code: exitCode)
        }

        await FeatureRunner.run([
            AnyFeatureTool(JiraSearchTool()),
            AnyFeatureTool(JiraReadTool()),
            AnyFeatureTool(JiraSignOutTool())
        ])
    }
}

extension JiraSearchTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Jira issues", action: "Search", kind: .search, targetKeyPaths: ["query", "jql"])
    }
}

extension JiraReadTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Jira issue", action: "Read", kind: .read, targetKeyPaths: ["issueKey", "issue_key", "key", "url", "query"])
    }
}

extension JiraSignOutTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Jira account", action: "Sign out", kind: .manage, includesParameters: false)
    }
}
