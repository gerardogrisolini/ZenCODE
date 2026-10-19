import Foundation
import ToolCore

enum JiraToolRenderer {
    static func renderSearchResults(_ issues: [JiraIssueSummary], query: String) -> String {
        var lines = ["Jira search: \(query)", ""]
        for issue in issues {
            var details: [String] = []
            if let issueType = issue.issueType {
                details.append(issueType)
            }
            if let status = issue.status {
                details.append(status)
            }
            if let assignee = issue.assignee {
                details.append("assignee: \(assignee)")
            }
            let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            lines.append("- \(issue.key): \(issue.summary)\(suffix)")
            lines.append("  \(issue.url.absoluteString)")
        }
        return lines.joined(separator: "\n")
    }

    static func renderTaskContext(_ detail: JiraIssueDetail, includeRaw: Bool) -> String {
        var sections: [String] = []
        var header = [
            "Task context imported from Jira:",
            "",
            "Issue: \(detail.key)",
            "Title: \(detail.summary)",
            "URL: \(detail.url.absoluteString)"
        ]
        appendOptional("Type", detail.issueType, to: &header)
        appendOptional("Status", detail.status, to: &header)
        appendOptional("Assignee", detail.assignee, to: &header)
        appendOptional("Priority", detail.priority, to: &header)
        sections.append(header.joined(separator: "\n"))

        if let description = detail.description {
            sections.append("Description:\n\(description)")
        }
        if !detail.acceptanceCriteria.isEmpty {
            sections.append(
                "Acceptance criteria:\n"
                + detail.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        if !detail.designURLs.isEmpty {
            sections.append("Design links:\n" + detail.designURLs.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !detail.referenceURLs.isEmpty {
            sections.append("Reference links:\n" + detail.referenceURLs.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !detail.notableFields.isEmpty {
            sections.append(
                "Additional fields:\n"
                + detail.notableFields.map { "- \($0.name): \($0.value)" }.joined(separator: "\n")
            )
        }
        if includeRaw {
            sections.append("Raw Jira payload:\n\(detail.rawPayload.prettyPrinted())")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func appendOptional(_ label: String, _ value: String?, to lines: inout [String]) {
        guard let value else { return }
        lines.append("\(label): \(value)")
    }
}
