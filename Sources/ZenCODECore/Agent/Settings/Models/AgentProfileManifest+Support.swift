//
//  AgentProfileManifest+Support.swift
//  ZenCODE
//

import Foundation
import ToolCore

public struct AgentProfileSkill: Codable, Hashable, Sendable {
    public let id: String
    public let canonicalName: String?
    public let title: String?
    public let summary: String?
    public let symbolName: String?

    public init(
        id: String,
        canonicalName: String? = nil,
        title: String? = nil,
        summary: String? = nil,
        symbolName: String? = nil
    ) {
        self.id = id.nilIfBlank ?? ""
        self.canonicalName = canonicalName?.nilIfBlank
        self.title = title?.nilIfBlank
        self.summary = summary?.nilIfBlank
        self.symbolName = symbolName?.nilIfBlank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)?.nilIfBlank ?? ""
        self.canonicalName = try container.decodeIfPresent(String.self, forKey: .canonicalName)?.nilIfBlank
        self.title = try container.decodeIfPresent(String.self, forKey: .title)?.nilIfBlank
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)?.nilIfBlank
        self.symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)?.nilIfBlank
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case canonicalName
        case title
        case summary
        case symbolName
    }

    public func matchingSkillID(in availableSkills: [PromptSkill]) -> String? {
        let idKey = id.selectionKey.nilIfBlank
        let canonicalNameKey = canonicalName?.selectionKey.nilIfBlank
        let titleKey = title?.selectionKey.nilIfBlank
        let summaryKey = summary?.selectionKey.nilIfBlank

        if let idKey,
           let skill = availableSkills.first(where: { $0.id.selectionKey == idKey }) {
            return skill.id
        }
        if let canonicalNameKey,
           let skill = availableSkills.first(where: { $0.canonicalName.selectionKey == canonicalNameKey }) {
            return skill.id
        }
        if let titleKey, let summaryKey,
           let skill = availableSkills.first(where: {
               $0.title.selectionKey == titleKey && $0.summary.selectionKey == summaryKey
           }) {
            return skill.id
        }
        if let titleKey {
            let matches = availableSkills.filter { $0.title.selectionKey == titleKey }
            if matches.count == 1 { return matches[0].id }
        }
        return nil
    }
}

public enum AgentProfileStoreError: LocalizedError {
    case missingFile(URL)
    case unreadableFile(URL, Error)
    case invalidFile(URL, Error)
    case unsupportedVersion(URL, Int, Int)
    case noAgents(URL)
    case developerAgentMissing(URL)
    case ambiguousProfileReferences(URL, [String])

    public var errorDescription: String? {
        switch self {
        case let .missingFile(url):
            return "Missing ZenCODE agents file: \(url.path)"
        case let .unreadableFile(url, error):
            return "Unable to read ZenCODE agents file \(url.path): \(error.localizedDescription)"
        case let .invalidFile(url, error):
            return "Invalid ZenCODE agents file \(url.path): \(error.localizedDescription)"
        case let .unsupportedVersion(url, found, expected):
            return "Unsupported ZenCODE agents file \(url.path): version \(found), expected \(expected)"
        case let .noAgents(url):
            return "The ZenCODE agents file \(url.path) does not contain any agents."
        case let .developerAgentMissing(url):
            return "The ZenCODE agents file \(url.path) does not contain the Developer agent."
        case let .ambiguousProfileReferences(url, references):
            return "The ZenCODE agents file \(url.path) contains ambiguous profile references: "
                + references.joined(separator: ", ")
        }
    }
}

extension String {
    var selectionKey: String {
        AgentProfileStore.profileReferenceKey(self)
    }
}
