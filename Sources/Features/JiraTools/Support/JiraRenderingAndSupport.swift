//
//  JiraRenderingAndSupport.swift
//  ZenCODE
//

import Foundation
#if os(macOS)
import Security
#endif
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
            sections.append(
                "Design links:\n"
                + detail.designURLs.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        if !detail.referenceURLs.isEmpty {
            sections.append(
                "Reference links:\n"
                + detail.referenceURLs.map { "- \($0)" }.joined(separator: "\n")
            )
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
        guard let value else {
            return
        }
        lines.append("\(label): \(value)")
    }
}

enum JiraToolsError: LocalizedError {
    case missingArgument(String)
    case notConfigured
    case invalidConfiguration(String)
    case missingCredentials
    case authenticationFailed(statusCode: Int, message: String)
    case browserSetupFailed(String)
    case browserSetupTimedOut
    case requestFailed(String)
    case issueNotFound(String)
    case keychain(Int32)

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
        case let .issueNotFound(issueKey):
            return "Unable to load Jira issue \(issueKey) from the REST API."
        case let .keychain(status):
            return "Unable to access the Jira API token in Keychain (\(status))."
        }
    }
}

#if os(macOS)
enum JiraCredentialStore {
    private static let service = "ZenCODE.JiraAPIToken"

    static func load(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw JiraToolsError.missingCredentials
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)?.trimmedNonEmpty else {
            throw JiraToolsError.keychain(status)
        }
        return token
    }

    static func save(_ apiToken: String, account: String) throws {
        let data = Data(apiToken.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw JiraToolsError.keychain(updateStatus)
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw JiraToolsError.keychain(addStatus)
        }
    }

    static func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw JiraToolsError.keychain(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
#else
enum JiraCredentialStore {
    static func load(account _: String) throws -> String {
        throw JiraToolsError.invalidConfiguration("Jira credential storage is only available on macOS.")
    }

    static func save(_: String, account _: String) throws {
        throw JiraToolsError.invalidConfiguration("Jira credential storage is only available on macOS.")
    }

    static func remove(account _: String) throws {}
}
#endif

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    func flattenedText() -> String {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return String(format: "%g", value)
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return ""
        case let .array(values):
            return values
                .map { $0.flattenedText() }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case let .object(object):
            if let text = object["text"]?.stringValue {
                return text
            }
            if object["type"]?.stringValue == "hardBreak" {
                return "\n"
            }
            if let content = object["content"]?.arrayValue {
                let separator = blockSeparatingTypes.contains(object["type"]?.stringValue ?? "") ? "\n" : " "
                return content
                    .map { $0.flattenedText() }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: separator)
            }
            if let name = object["name"]?.stringValue {
                return name
            }
            if let displayName = object["displayName"]?.stringValue {
                return displayName
            }
            if let value = object["value"]?.stringValue {
                return value
            }
            if let url = object["url"]?.stringValue {
                return url
            }
            return object
                .sorted { $0.key < $1.key }
                .map { $0.value.flattenedText() }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private var blockSeparatingTypes: Set<String> {
        [
            "paragraph",
            "bulletList",
            "orderedList",
            "listItem",
            "blockquote",
            "heading",
            "panel"
        ]
    }
}

extension Array where Element == String {
    func deduplicated() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in self {
            guard let normalized = value.trimmedNonEmpty else {
                continue
            }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                result.append(normalized)
            }
        }
        return result
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

func write(_ string: String, stderr: Bool = false) {
    let data = Data(string.utf8)
    if stderr {
        FileHandle.standardError.write(data)
    } else {
        FileHandle.standardOutput.write(data)
    }
}

func writeLine(_ string: String, stderr: Bool = false) {
    write(string + "\n", stderr: stderr)
}
