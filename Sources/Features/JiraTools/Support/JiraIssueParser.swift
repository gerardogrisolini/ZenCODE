//
//  JiraIssueParser.swift
//  ZenCODE
//

import Foundation
import ToolCore

enum JiraIssueParser {
    static func issueSummaries(
        fromPickerResult result: JSONValue,
        siteURL: URL
    ) -> [JiraIssueSummary] {
        let sections = result["sections"]?.arrayValue
            ?? result["issueSections"]?.arrayValue
            ?? []
        var summaries: [JiraIssueSummary] = []

        for section in sections {
            for issue in section["issues"]?.arrayValue ?? [] {
                guard let key = issue["key"]?.stringValue?.trimmedNonEmpty else {
                    continue
                }
                let summary = [
                    issue["summaryText"]?.stringValue,
                    issue["summary"]?.flattenedText()
                ].compactMap { $0?.trimmedNonEmpty }.first ?? key
                summaries.append(
                    JiraIssueSummary(
                        key: key,
                        summary: summary,
                        status: issue["status"]?.flattenedText().trimmedNonEmpty,
                        issueType: issue["issuetype"]?.flattenedText().trimmedNonEmpty,
                        assignee: issue["assignee"]?.flattenedText().trimmedNonEmpty,
                        url: browseURL(siteURL: siteURL, key: key)
                    )
                )
            }
        }

        return summaries
    }

    static func issueDetail(from result: JSONValue, siteURL: URL) -> JiraIssueDetail? {
        guard let key = result["key"]?.stringValue?.trimmedNonEmpty,
              let fields = result["fields"]?.objectValue else {
            return nil
        }

        let names = result["names"]?.objectValue ?? [:]
        let summary = fields["summary"]?.stringValue?.trimmedNonEmpty ?? key
        let fieldTexts = fields.compactMap { fieldKey, fieldValue -> (name: String, value: String)? in
            let name = names[fieldKey]?.stringValue?.trimmedNonEmpty ?? fieldKey
            guard let value = fieldValue.flattenedText().trimmedNonEmpty else {
                return nil
            }
            return (name, value)
        }

        let acceptanceCriteria = fieldTexts
            .filter { fieldNameMatches($0.name, tokens: ["acceptance", "criteri", "definition of done"]) }
            .flatMap { splitListItems($0.value) }
            .deduplicated()

        let designURLs = fieldTexts
            .filter { fieldNameMatches($0.name, tokens: ["figma", "design", "dettagli fondamentali", "fundamental details"]) }
            .flatMap { URLs(in: $0.value) }
            .filter { $0.localizedCaseInsensitiveContains("figma") || $0.localizedCaseInsensitiveContains("design") }
            .deduplicated()

        let referenceURLs = fieldTexts
            .flatMap { URLs(in: $0.value) }
            .filter { !$0.localizedCaseInsensitiveContains(siteURL.host ?? "") }
            .deduplicated()

        let notableFields = fieldTexts
            .filter { field in
                fieldNameMatches(
                    field.name,
                    tokens: ["epic", "sprint", "component", "label", "fix version", "story points", "priority"]
                )
            }
            .prefix(12)
            .map { ($0.name, $0.value) }

        return JiraIssueDetail(
            key: key,
            summary: summary,
            status: fields["status"]?["name"]?.stringValue?.trimmedNonEmpty,
            issueType: fields["issuetype"]?["name"]?.stringValue?.trimmedNonEmpty,
            assignee: fields["assignee"]?["displayName"]?.stringValue?.trimmedNonEmpty,
            priority: fields["priority"]?["name"]?.stringValue?.trimmedNonEmpty,
            url: browseURL(siteURL: siteURL, key: key),
            description: fields["description"]?.flattenedText().trimmedNonEmpty,
            acceptanceCriteria: acceptanceCriteria,
            designURLs: designURLs,
            referenceURLs: referenceURLs,
            notableFields: notableFields,
            rawPayload: result
        )
    }

    static func summary(from detail: JiraIssueDetail) -> JiraIssueSummary {
        JiraIssueSummary(
            key: detail.key,
            summary: detail.summary,
            status: detail.status,
            issueType: detail.issueType,
            assignee: detail.assignee,
            url: detail.url
        )
    }

    private static func fieldNameMatches(_ name: String, tokens: [String]) -> Bool {
        let normalized = name.lowercased()
        return tokens.contains { normalized.contains($0.lowercased()) }
    }

    private static func splitListItems(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .flatMap { line -> [String] in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = trimmed
                    .replacingOccurrences(of: #"^\s*[-*•]\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s*\d+[.)]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? [] : [cleaned]
            }
    }

    private static func URLs(in text: String) -> [String] {
        let pattern = #"https?://[^\s<>)"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else {
                return nil
            }
            return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        }
    }

    private static func browseURL(siteURL: URL, key: String) -> URL {
        guard var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false) else {
            return siteURL
        }
        components.path = "/browse/\(key)"
        return components.url ?? siteURL
    }
}

enum JiraIssueKeyExtractor {
    static func issueKey(in value: String) -> String? {
        let pattern = #"\b([A-Z][A-Z0-9]+-\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              match.numberOfRanges > 1,
              let keyRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[keyRange]).uppercased()
    }
}
