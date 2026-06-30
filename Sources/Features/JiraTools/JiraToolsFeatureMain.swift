//
//  main.swift
//  jira-tools-feature
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Darwin
import Security
#elseif os(Linux)
import Glibc
#endif
import ZenCODECore
import FeatureKit

struct JiraSearchTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let query: String?
    }

    typealias Output = String

    static let name = "jira.search"
    static let description = "Searches Jira issues by issue key, issue URL, or text and returns selectable issue summaries."
    static let inputSchema = #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#

    func run(_ input: Input, context _: FeatureContext) async throws -> String {
        guard let query = input.query?.trimmedNonEmpty else {
            throw JiraToolsError.missingArgument("query")
        }

        let service = try JiraRESTService.loadConfigured()
        let issues = try await service.searchIssues(matching: query)
        guard !issues.isEmpty else {
            return "Jira search: \(query)\nNo issues found."
        }
        return JiraToolRenderer.renderSearchResults(issues, query: query)
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

    typealias Output = String

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
        ].compactMap({ $0?.trimmedNonEmpty }).first else {
            throw JiraToolsError.missingArgument("issueKey")
        }

        let service = try JiraRESTService.loadConfigured()
        let issue = try await service.loadIssue(matching: query)
        return JiraToolRenderer.renderTaskContext(
            issue,
            includeRaw: input.includeRaw ?? input.include_raw ?? false
        )
    }
}

struct JiraSignOutTool: FeatureTool {
    struct Input: Decodable, Sendable {}
    typealias Output = String

    static let name = "jira.signOut"
    static let description = "Clears the persisted Jira API token used by the Jira tools."
    static let inputSchema = #"{"type":"object","properties":{}}"#

    func run(_: Input, context _: FeatureContext) async throws -> String {
        let configuration = try JiraConfigurationStore.load()
        try JiraCredentialStore.remove(account: configuration.credentialAccount)
        return "Jira credentials cleared. Run `/feature enable jira-tools` to configure Jira again."
    }
}

@main
struct JiraToolsFeatureMain {
    static func main() async {
        if CommandLine.arguments.dropFirst().contains("--setup") {
            let exitCode = await JiraSetupRunner.run()
            terminate(code: exitCode)
        }

        await FeatureRunner.run([
            AnyFeatureTool(JiraSearchTool()),
            AnyFeatureTool(JiraReadTool()),
            AnyFeatureTool(JiraSignOutTool())
        ])
    }

    private static func terminate(code: Int32) -> Never {
        #if canImport(Darwin) || canImport(Glibc)
        exit(code)
        #else
        fatalError("jira-tools-feature terminated with code \(code).")
        #endif
    }
}
