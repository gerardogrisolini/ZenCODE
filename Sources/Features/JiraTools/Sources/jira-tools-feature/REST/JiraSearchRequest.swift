import Foundation
import ToolCore

/// The Jira lookup behind `jira.search`: a direct issue read for an issue key
/// or URL, otherwise a JQL search through `/rest/api/3/search/jql`.
enum JiraSearchRequest: Equatable, Sendable {
    case issueKey(String)
    case jql(String)

    /// Resolves the `jira.search` arguments. `jql` is sent as is; `query` is
    /// an issue key, an issue URL, or free text searched across every text
    /// field. Exactly one of the two must be provided.
    static func resolve(query: String?, jql: String?) throws -> JiraSearchRequest {
        switch (query?.nilIfBlank, jql?.nilIfBlank) {
        case let (nil, jql?):
            return .jql(jql)
        case let (query?, nil):
            if let issueKey = JiraIssueKeyExtractor.issueKey(in: query) {
                return .issueKey(issueKey)
            }
            return .jql(JiraJQL.textSearch(query))
        case (nil, nil):
            throw JiraToolsError.missingArgument("query or jql")
        case (_?, _?):
            throw JiraToolsError.requestFailed(
                "Pass either query or jql to jira.search, not both. To combine free text with other conditions, add a text ~ \"...\" clause to jql."
            )
        }
    }
}

enum JiraJQL {
    /// Full-text search across summary, description, comments and text custom
    /// fields, most recently updated issues first. Only the JQL string literal
    /// is escaped, so Jira text-search syntax inside the query (quoted
    /// phrases, `*` wildcards, `AND`/`OR`/`NOT`) keeps working.
    static func textSearch(_ text: String) -> String {
        "text ~ \(stringLiteral(text)) ORDER BY updated DESC"
    }

    /// Double-quoted JQL string literal. Backslashes and double quotes are
    /// escaped; line breaks and tabs become spaces so the clause stays on a
    /// single line.
    static func stringLiteral(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\":
                escaped += "\\\\"
            case "\"":
                escaped += "\\\""
            case _ where character.isNewline || character == "\t":
                escaped += " "
            default:
                escaped.append(character)
            }
        }
        return "\"\(escaped)\""
    }
}
