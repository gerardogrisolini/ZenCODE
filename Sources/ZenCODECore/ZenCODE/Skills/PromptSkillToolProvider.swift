//
//  PromptSkillToolProvider.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 24/07/26.
//

import Foundation
import ToolCore

/// Session-scoped prompt-skill tools: `skills.list` and `skills.read`.
///
/// Both tools are intrinsic and always advertised from session creation, even
/// with no skills selected, so the tool schema and system prompt never change
/// when the user adds or removes a skill. Only the per-session selection
/// state (owned by `PromptSkillSessionProvider`) is mutable; that keeps the
/// remote continuation and KV-cache prefix stable across selection changes.
///
/// `skills.read` deliberately accepts an identifier rather than a file path, so
/// a model cannot use it to read arbitrary installed skill files.
public enum PromptSkillToolProvider {
    public static let listToolName = "skills.list"
    public static let toolName = "skills.read"
    public static let toolNames: Set<String> = [listToolName, toolName]
    public static let defaultPageCharacterLimit = 6_000
    public static let maximumPageCharacterLimit = 8_000

    public static let listToolDescriptor = DirectToolDescriptor(
        name: listToolName,
        description: "Lists the prompt skills currently selected for this session, returning only their id, name, and description. Prompt skills may be added or removed during the session, so call this to discover the current selection before reading guidance.",
        inputSchema: #"{"type":"object","properties":{}}"#
    )

    public static let readToolDescriptor = DirectToolDescriptor(
        name: toolName,
        description: "Loads one page of complete guidance for a selected prompt skill. Use the id or canonical name returned by skills.list. The tool can read only skills selected for the current session; request the next page with its nextOffset when supplied.",
        inputSchema: #"{"type":"object","properties":{"identifier":{"type":"string","description":"Selected skill id or canonical name from skills.list."},"offset":{"type":"integer","minimum":0,"description":"Zero-based character offset in the skill guidance body. Defaults to 0."},"limit":{"type":"integer","minimum":1,"maximum":8000,"description":"Maximum body characters to return. Defaults to 6000."}},"required":["identifier"],"additionalProperties":false}"#
    )

    /// Intrinsic skill-tool descriptors in stable order (`skills.list` first).
    public static let descriptors: [DirectToolDescriptor] = [
        listToolDescriptor,
        readToolDescriptor
    ]

    /// Returns the skills sorted deterministically (canonical name, then id) so
    /// `skills.list` output and listing comparisons are stable.
    public static func sortedForListing(_ skills: [PromptSkill]) -> [PromptSkill] {
        skills.sorted { lhs, rhs in
            if lhs.canonicalName != rhs.canonicalName {
                return lhs.canonicalName < rhs.canonicalName
            }
            return lhs.id < rhs.id
        }
    }

    /// Renders the `skills.list` payload as deterministic JSON containing only
    /// each selected skill's id, canonical `name`, and `description`.
    public static func renderSkillList(skills: [PromptSkill]) -> String {
        let ordered = sortedForListing(skills)
        let skillObjects: [[String: Any]] = ordered.map { skill in
            [
                "id": skill.id,
                "name": skill.canonicalName,
                "description": skill.summary
            ]
        }
        let payload: [String: Any] = ["skills": skillObjects]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys]
        ),
        let json = String(data: data, encoding: .utf8) else {
            return "{\"skills\":[]}"
        }
        return json
    }

    public static func renderedGuidance(for skill: PromptSkill) -> String {
        // Kept for callers that need a full local rendering outside the model
        // tool channel. Tool calls use the paginated overload below.
        renderedSkillHeader(for: skill) + "\n" + skill.promptBody
    }

    public static func renderedGuidance(
        for skill: PromptSkill,
        offset: Int,
        limit: Int
    ) throws -> String {
        guard offset >= 0 else {
            throw PromptSkillToolProviderError.invalidOffset(offset)
        }
        guard limit > 0 else {
            throw PromptSkillToolProviderError.invalidLimit(limit)
        }

        let bodyCharacters = Array(skill.promptBody)
        guard offset < bodyCharacters.count || (offset == 0 && bodyCharacters.isEmpty) else {
            throw PromptSkillToolProviderError.offsetOutOfRange(
                offset: offset,
                totalCharacters: bodyCharacters.count
            )
        }

        let effectiveLimit = min(limit, maximumPageCharacterLimit)
        let endOffset = min(offset + effectiveLimit, bodyCharacters.count)
        let pageBody = String(bodyCharacters[offset..<endOffset])
        let nextOffset = endOffset < bodyCharacters.count ? endOffset : nil
        let pageMetadata: String
        if let nextOffset {
            pageMetadata = "Skill guidance characters \(offset)..<\(endOffset) of \(bodyCharacters.count). Continue with `skills.read` using identifier `\(skill.id)` and offset \(nextOffset)."
        } else {
            pageMetadata = "Skill guidance characters \(offset)..<\(endOffset) of \(bodyCharacters.count). This is the final page."
        }

        return """
        \(renderedSkillHeader(for: skill))
        \(pageMetadata)
        \(pageBody)
        """
    }

    public static func selectedSkill(
        matching identifier: String,
        in selectedSkills: [PromptSkill]
    ) throws -> PromptSkill {
        if let exactID = selectedSkills.first(where: { $0.id == identifier }) {
            return exactID
        }

        if let skill = try uniqueSkill(
            selectedSkills.filter { $0.canonicalName == identifier },
            identifier: identifier
        ) {
            return skill
        }

        if let skill = try uniqueSkill(
            selectedSkills.filter { $0.title == identifier },
            identifier: identifier
        ) {
            return skill
        }

        let normalizedIdentifier = normalizedKey(identifier)
        let normalizedMatches = selectedSkills.filter { skill in
            normalizedKey(skill.canonicalName) == normalizedIdentifier
                || normalizedKey(skill.title) == normalizedIdentifier
        }
        if let skill = try uniqueSkill(normalizedMatches, identifier: identifier) {
            return skill
        }

        throw PromptSkillToolProviderError.skillNotSelected(identifier)
    }

    private static func renderedSkillHeader(for skill: PromptSkill) -> String {
        guard let sourceDirectoryPath = skill.sourceDirectoryPath?.nilIfBlank else {
            return "Skill: \(skill.title)"
        }

        return """
        Skill: \(skill.title)
        Skill root path: \(sourceDirectoryPath)
        Any relative file paths mentioned in this skill are relative to the skill root above, not to the task working directory. If you need to open one of those files with a local tool, keep the `references/...` or similar subpath under that skill root, or pass the absolute skill file path directly.
        """
    }

    fileprivate static func request(from argumentsJSON: String) throws -> Request {
        guard let data = argumentsJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let arguments = object as? [String: Any] else {
            throw PromptSkillToolProviderError.invalidArguments
        }

        guard let identifier = (arguments["identifier"] as? String)?.nilIfBlank else {
            throw PromptSkillToolProviderError.missingIdentifier
        }
        let offset = try integer(named: "offset", in: arguments) ?? 0
        let requestedLimit = try integer(named: "limit", in: arguments)
            ?? defaultPageCharacterLimit
        guard offset >= 0 else {
            throw PromptSkillToolProviderError.invalidOffset(offset)
        }
        guard requestedLimit > 0 else {
            throw PromptSkillToolProviderError.invalidLimit(requestedLimit)
        }
        return Request(
            identifier: identifier,
            offset: offset,
            limit: min(requestedLimit, maximumPageCharacterLimit)
        )
    }

    private static func integer(
        named name: String,
        in arguments: [String: Any]
    ) throws -> Int? {
        guard let value = arguments[name] else {
            return nil
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber,
           CFNumberIsFloatType(value) == false {
            return value.intValue
        }
        throw PromptSkillToolProviderError.invalidIntegerArgument(name)
    }

    private static func uniqueSkill(
        _ candidates: [PromptSkill],
        identifier: String
    ) throws -> PromptSkill? {
        let skillsByID = Dictionary(
            candidates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        switch skillsByID.values.count {
        case 0:
            return nil
        case 1:
            return skillsByID.values.first
        default:
            throw PromptSkillToolProviderError.ambiguousIdentifier(
                identifier,
                matches: skillsByID.values.map(\.id).sorted()
            )
        }
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }

    fileprivate struct Request {
        let identifier: String
        let offset: Int
        let limit: Int
    }
}

/// Mutable, session-scoped owner of the currently selected prompt skills.
///
/// Both skill tools are intrinsic and always advertised, so this actor holds
/// the only piece of state that changes when skills are selected or revoked:
/// the snapshot itself. Updating it never touches the system prompt, allowlist,
/// cache key, or remote session identity, which preserves the remote
/// continuation and KV-cache prefix.
public actor PromptSkillSessionProvider: Sendable {
    private var skills: [PromptSkill]

    public init(skills: [PromptSkill] = []) {
        self.skills = PromptSkillToolProvider.sortedForListing(skills)
    }

    public func update(_ skills: [PromptSkill]) {
        self.skills = PromptSkillToolProvider.sortedForListing(skills)
    }

    public func currentSkills() -> [PromptSkill] {
        skills
    }

    /// Wraps this mutable, session-scoped provider as an `AgentToolProvider`
    /// whose descriptors are the stable intrinsic skill tools. The same actor
    /// instance is reused across turns, so updating the selection mutates the
    /// snapshot in place without changing the advertised tool schema.
    nonisolated public func asToolProvider() -> AgentToolProvider {
        let provider = self
        return AgentToolProvider(
            tools: PromptSkillToolProvider.descriptors.map(\.toolDescriptor),
            executor: { toolCall in
                try await provider.execute(toolCall: toolCall)
            }
        )
    }

    public func execute(toolCall: AgentToolCall) async throws -> String {
        switch toolCall.name {
        case PromptSkillToolProvider.listToolName:
            return PromptSkillToolProvider.renderSkillList(skills: skills)
        case PromptSkillToolProvider.toolName:
            let request = try PromptSkillToolProvider.request(from: toolCall.argumentsJSON)
            let skill = try PromptSkillToolProvider.selectedSkill(
                matching: request.identifier,
                in: skills
            )
            return try PromptSkillToolProvider.renderedGuidance(
                for: skill,
                offset: request.offset,
                limit: request.limit
            )
        default:
            throw DirectToolError.unknownTool(toolCall.name)
        }
    }
}

public enum PromptSkillToolProviderError: LocalizedError, Sendable {
    case invalidArguments
    case missingIdentifier
    case invalidIntegerArgument(String)
    case invalidOffset(Int)
    case invalidLimit(Int)
    case offsetOutOfRange(offset: Int, totalCharacters: Int)
    case skillNotSelected(String)
    case ambiguousIdentifier(String, matches: [String])

    public var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "skills.read requires a JSON object containing a selected skill identifier."
        case .missingIdentifier:
            return "skills.read requires identifier."
        case let .invalidIntegerArgument(name):
            return "skills.read requires \(name) to be an integer."
        case let .invalidOffset(offset):
            return "skills.read requires offset to be zero or greater, not \(offset)."
        case let .invalidLimit(limit):
            return "skills.read requires limit to be greater than zero, not \(limit)."
        case let .offsetOutOfRange(offset, totalCharacters):
            return "skills.read offset \(offset) is outside the skill body of \(totalCharacters) characters."
        case let .skillNotSelected(identifier):
            return "The skill '\(identifier)' is not selected for this session."
        case let .ambiguousIdentifier(identifier, matches):
            return "The skill identifier '\(identifier)' is ambiguous. Use one of these skill ids instead: \(matches.joined(separator: ", "))."
        }
    }
}
