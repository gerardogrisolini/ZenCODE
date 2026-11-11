//
//  AgentProfileManifest+Support.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// A prompt skill a profile declares in `agents.json`, as `{"name": "…"}`.
///
/// The skill's canonical name (the `name:` of its `SKILL.md`) is its only
/// identifier: it is compared case-insensitively with the installed skills'
/// names. `title`, `summary`, and `symbolName` are optional descriptive
/// metadata that never take part in the comparison. A `name` that is missing,
/// blank, or not a string makes decoding fail with
/// ``AgentProfileSkillDecodingError``; any other key (such as the former `id`)
/// is ignored.
public struct AgentProfileSkill: Codable, Hashable, Sendable {
    public let name: String
    public let title: String?
    public let summary: String?
    public let symbolName: String?

    public init(
        name: String,
        title: String? = nil,
        summary: String? = nil,
        symbolName: String? = nil
    ) {
        self.name = name.nilIfBlank ?? ""
        self.title = title?.nilIfBlank
        self.summary = summary?.nilIfBlank
        self.symbolName = symbolName?.nilIfBlank
    }

    /// Strict decoding of the required `name`: a missing, blank, `null`, or
    /// non-string value throws ``AgentProfileSkillDecodingError`` (a legacy
    /// `{"id": "<hash>"}` entry has none). ``AgentProfile`` adds the profile
    /// to the error it reports.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName: String?
        do {
            decodedName = try container.decodeIfPresent(String.self, forKey: .name)?.nilIfBlank
        } catch {
            decodedName = nil
        }
        guard let decodedName else {
            throw AgentProfileSkillDecodingError.missingName(profile: nil)
        }
        self.name = decodedName
        self.title = try container.decodeIfPresent(String.self, forKey: .title)?.nilIfBlank
        self.summary = try container.decodeIfPresent(String.self, forKey: .summary)?.nilIfBlank
        self.symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)?.nilIfBlank
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case title
        case summary
        case symbolName
    }

    /// The canonical name of the installed skill this entry names, compared
    /// case-insensitively, or `nil` when no installed skill has that name.
    public func matchingSkillName(in availableSkills: [PromptSkill]) -> String? {
        guard let nameKey = name.selectionKey.nilIfBlank else {
            return nil
        }
        return availableSkills.first { $0.canonicalName.selectionKey == nameKey }?.canonicalName
    }
}

/// Decoding failure of a profile's skill: the required `name` is missing,
/// blank, or not a string (as in the legacy `{"id": "<hash>"}` entries). The
/// manifest that contains it is invalid.
public enum AgentProfileSkillDecodingError: LocalizedError, Equatable {
    /// `profile` is the name of the profile that declares the skill, `nil`
    /// when the skill was decoded on its own.
    case missingName(profile: String?)

    public var errorDescription: String? {
        switch self {
        case let .missingName(profile):
            let subject = profile.map { "profile '\($0)' has a skill without" } ?? "a skill is missing"
            return "\(subject) the required \"name\" field "
                + "(skills are identified by name, as {\"name\": \"<skill name>\"})."
        }
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
            return "The ZenCODE agents file \(url.path) does not contain an agent with the developer role."
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
