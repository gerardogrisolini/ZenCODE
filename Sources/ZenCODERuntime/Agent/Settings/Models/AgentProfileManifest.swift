//
//  AgentProfileManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public struct AgentProfileManifest: Codable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let agents: [AgentProfile]

    public init(
        version: Int = Self.currentVersion,
        agents: [AgentProfile]
    ) {
        self.version = version
        self.agents = agents
    }
}

/// A dedicated model configuration available to an agent profile.
///
/// The identifier is stable so a profile can retain an explicit default even
/// when bindings are reordered. Bindings without a usable model identifier are
/// ignored when a profile is normalized for persistence.
public struct AgentModelBinding: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let modelID: String
    public let modelProvider: String?
    public let thinkingSelection: AgentThinkingSelection?
    public let capability: Int?

    public init(
        id: String? = nil,
        modelID: String,
        modelProvider: String? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        capability: Int? = nil
    ) {
        let normalizedModelID = modelID.nilIfBlank ?? ""
        self.id = id?.nilIfBlank ?? normalizedModelID
        self.modelID = normalizedModelID
        self.modelProvider = modelProvider?.nilIfBlank
        self.thinkingSelection = thinkingSelection
        self.capability = capability.map { min(max($0, 1), 10) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            modelID: try container.decodeIfPresent(String.self, forKey: .modelID) ?? "",
            modelProvider: try container.decodeIfPresent(String.self, forKey: .modelProvider),
            thinkingSelection: try container.decodeIfPresent(
                AgentThinkingSelection.self,
                forKey: .thinkingSelection
            ),
            capability: try container.decodeIfPresent(Int.self, forKey: .capability)
        )
    }

    public var isValid: Bool {
        modelID.nilIfBlank != nil && id.nilIfBlank != nil
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case modelID
        case modelProvider
        case thinkingSelection
        case capability
    }
}

public struct AgentProfile: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let instructions: String?
    public let symbolName: String?
    /// Limits configured core tools to their non-mutating descriptors.
    ///
    /// Missing values in persisted manifests decode as `false` for backwards
    /// compatibility with profiles saved before this setting existed.
    public let readOnly: Bool
    /// The profile's role: the only property that determines which kind of
    /// agent it is. Required in `agents.json`; a missing or unknown value makes
    /// the manifest invalid.
    public let role: AgentProfileRole
    public let tools: [String]
    public let skills: [AgentProfileSkill]
    public let modelBindings: [AgentModelBinding]
    public let defaultModelBindingID: String?

    /// Whether this is the system profile of its role: its ID is the role
    /// itself. Custom profiles have any other ID.
    public var isSystemProfile: Bool {
        AgentProfileStore.profileReferenceKey(id)
            == AgentProfileStore.profileReferenceKey(role.rawValue)
    }

    /// The binding used by default for this profile.
    ///
    /// An invalid or absent persisted default falls back to the first
    /// normalized binding, whose ordering is stable across saves.
    public var defaultModelBinding: AgentModelBinding? {
        guard let defaultModelBindingID else { return modelBindings.first }
        let key = Self.modelBindingKey(defaultModelBindingID)
        return modelBindings.first { Self.modelBindingKey($0.id) == key } ?? modelBindings.first
    }

    /// Returns one of this profile's explicitly authorized model bindings.
    /// Both the stable binding identifier and the configured model identifier
    /// are accepted so callers can persist the former while tool payloads can
    /// use the latter.
    public func modelBinding(matching reference: String?) -> AgentModelBinding? {
        guard let reference = reference?.nilIfBlank else {
            return defaultModelBinding
        }
        let key = Self.modelBindingKey(reference)
        return modelBindings.first { Self.modelBindingKey($0.id) == key }
            ?? modelBindings.first { Self.modelBindingKey($0.modelID) == key }
    }

    // Compatibility accessors for the previous single-model profile shape.
    // New persistence is always expressed through `modelBindings`.
    public var modelID: String? {
        defaultModelBinding?.modelID
    }

    public var thinkingSelection: AgentThinkingSelection? {
        defaultModelBinding?.thinkingSelection
    }

    public init(
        id: String,
        name: String,
        instructions: String? = nil,
        symbolName: String? = nil,
        readOnly: Bool = false,
        role: AgentProfileRole,
        tools: [String] = [],
        skills: [AgentProfileSkill] = [],
        modelID: String? = nil,
        modelProvider: String? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        capability: Int? = nil,
        modelBindings: [AgentModelBinding] = [],
        defaultModelBindingID: String? = nil,
        defaultModelID: String? = nil
    ) {
        self.id = id.nilIfBlank ?? UUID().uuidString
        self.name = name.nilIfBlank ?? AgentProfileStore.developerAgentName
        self.instructions = instructions?.nilIfBlank
        self.symbolName = symbolName?.nilIfBlank
        self.readOnly = readOnly
        self.role = role
        self.tools = tools
        self.skills = skills

        (self.modelBindings, self.defaultModelBindingID) = Self.resolvedBindings(
            modelBindings.isEmpty ? nil : modelBindings,
            legacyModelID: modelID,
            legacyModelProvider: modelProvider,
            legacyThinkingSelection: thinkingSelection,
            legacyCapability: capability,
            preferredBindingID: defaultModelBindingID,
            preferredModelID: defaultModelID
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.instructions = try container.decodeIfPresent(String.self, forKey: .instructions)?.nilIfBlank
        self.symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName)?.nilIfBlank
        self.readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        self.role = try Self.decodeRole(from: container, profileName: name)
        self.tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        self.skills = try Self.decodeSkills(from: container, profileName: name)

        let legacyModelID = try container.decodeIfPresent(String.self, forKey: .modelID)?.nilIfBlank
        (self.modelBindings, self.defaultModelBindingID) = Self.resolvedBindings(
            try container.decodeIfPresent([AgentModelBinding].self, forKey: .modelBindings),
            legacyModelID: legacyModelID,
            legacyModelProvider: try container.decodeIfPresent(String.self, forKey: .modelProvider)?.nilIfBlank,
            legacyThinkingSelection: try container.decodeIfPresent(
                AgentThinkingSelection.self,
                forKey: .thinkingSelection
            ),
            legacyCapability: try container.decodeIfPresent(Int.self, forKey: .capability),
            preferredBindingID: try container.decodeIfPresent(String.self, forKey: .defaultModelBindingID),
            preferredModelID: try container.decodeIfPresent(String.self, forKey: .defaultModelID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(instructions, forKey: .instructions)
        try container.encodeIfPresent(symbolName, forKey: .symbolName)
        try container.encode(readOnly, forKey: .readOnly)
        try container.encode(role, forKey: .role)
        try container.encode(tools, forKey: .tools)
        try container.encode(skills, forKey: .skills)
        if !modelBindings.isEmpty {
            try container.encode(modelBindings, forKey: .modelBindings)
        }
        try container.encodeIfPresent(defaultModelBindingID, forKey: .defaultModelBindingID)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case instructions
        case symbolName
        case readOnly
        case role
        case tools
        case skills
        case modelID
        case modelProvider
        case thinkingSelection
        case capability
        case modelBindings
        case defaultModelBindingID
        case defaultModelID
    }

    /// Strict decoding of the required role: a missing, non-string, or unknown
    /// value fails with an error that names the profile and the valid roles.
    private static func decodeRole(
        from container: KeyedDecodingContainer<CodingKeys>,
        profileName: String
    ) throws -> AgentProfileRole {
        guard container.contains(.role) else {
            throw AgentProfileRoleDecodingError.missing(profile: profileName)
        }
        let rawValue: String
        do {
            rawValue = try container.decode(String.self, forKey: .role)
        } catch {
            throw AgentProfileRoleDecodingError.invalid(profile: profileName, value: nil)
        }
        guard let role = AgentProfileRole(rawValue: rawValue) else {
            throw AgentProfileRoleDecodingError.invalid(profile: profileName, value: rawValue)
        }
        return role
    }

    /// Strict decoding of the profile's skills: every entry needs a usable
    /// `name`. An entry without one (such as the legacy `{"id": "<hash>"}`)
    /// fails with an error that names the profile; there is no migration.
    private static func decodeSkills(
        from container: KeyedDecodingContainer<CodingKeys>,
        profileName: String
    ) throws -> [AgentProfileSkill] {
        guard container.contains(.skills),
              try !container.decodeNil(forKey: .skills) else {
            return []
        }
        var entries = try container.nestedUnkeyedContainer(forKey: .skills)
        var skills: [AgentProfileSkill] = []
        while !entries.isAtEnd {
            do {
                skills.append(try entries.decode(AgentProfileSkill.self))
            } catch AgentProfileSkillDecodingError.missingName {
                throw AgentProfileSkillDecodingError.missingName(profile: profileName)
            }
        }
        return skills
    }

    private static func resolvedBindings(
        _ bindings: [AgentModelBinding]?,
        legacyModelID: String?,
        legacyModelProvider: String?,
        legacyThinkingSelection: AgentThinkingSelection?,
        legacyCapability: Int?,
        preferredBindingID: String?,
        preferredModelID: String?
    ) -> ([AgentModelBinding], String?) {
        var source = bindings ?? []
        if bindings == nil, let legacyModelID = legacyModelID?.nilIfBlank {
            source = [AgentModelBinding(
                id: legacyModelID,
                modelID: legacyModelID,
                modelProvider: legacyModelProvider,
                thinkingSelection: legacyThinkingSelection,
                capability: legacyCapability
            )]
        }
        let normalized = normalizedModelBindings(source)
        return (normalized, resolvedDefaultModelBindingID(
            in: normalized,
            preferredBindingID: preferredBindingID,
            preferredModelID: preferredModelID
        ))
    }

    private static func normalizedModelBindings(
        _ bindings: [AgentModelBinding]
    ) -> [AgentModelBinding] {
        let sortedBindings = bindings
            .filter(\.isValid)
            .sorted { lhs, rhs in
                (modelBindingKey(lhs.id), modelBindingKey(lhs.modelID), lhs.modelProvider ?? "")
                    < (modelBindingKey(rhs.id), modelBindingKey(rhs.modelID), rhs.modelProvider ?? "")
            }

        var seenBindingIDs = Set<String>()
        var seenModelIDs = Set<String>()
        return sortedBindings.filter { binding in
            let bindingID = modelBindingKey(binding.id)
            let modelID = modelBindingKey(binding.modelID)
            return seenBindingIDs.insert(bindingID).inserted
                && seenModelIDs.insert(modelID).inserted
        }
    }

    private static func resolvedDefaultModelBindingID(
        in bindings: [AgentModelBinding],
        preferredBindingID: String?,
        preferredModelID: String?
    ) -> String? {
        if let preferredBindingID,
           let binding = bindings.first(where: { modelBindingKey($0.id) == modelBindingKey(preferredBindingID) }) {
            return binding.id
        }
        if let preferredModelID,
           let binding = bindings.first(where: { modelBindingKey($0.modelID) == modelBindingKey(preferredModelID) }) {
            return binding.id
        }
        return bindings.first?.id
    }

    private static func modelBindingKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var displayName: String {
        name.nilIfBlank ?? "Unnamed Agent"
    }

    public var promptSection: String? {
        var lines = ["Selected agent: \(displayName)"]
        if let resolvedInstructions = resolvedInstructions().nilIfBlank {
            lines += ["Agent instructions:", resolvedInstructions]
        }
        return lines.joined(separator: "\n").nilIfBlank
    }

    private func resolvedInstructions() -> String {
        guard let instructions else {
            return ""
        }
        guard instructions == SystemPromptBuilder.defaultAgentInstructions() else {
            return instructions
        }
        // Legacy Developer profiles persisted the complete standalone prompt as
        // their instructions. Its common policy is already composed by the
        // session, so retaining it here would duplicate that prompt in dynamic
        // context.
        return ""
    }

    public func allowedToolNames() -> Set<String> {
        allowedToolNames(
            featureStatuses: SwiftFeatureRuntime.defaultFeatureStatuses()
        )
    }

    func allowedToolNames(
        featureStatuses: [SwiftFeatureStatus]
    ) -> Set<String> {
        let items = TerminalToolSelectionCatalog.items(featureStatuses: featureStatuses)
        var selectedKeys = Set<String>()
        var allowedToolNames = Set<String>()
        for tool in tools {
            let matchingKeys = TerminalToolSelectionCatalog.selectionKeys(for: tool, items: items)
            if !matchingKeys.isEmpty {
                selectedKeys.formUnion(matchingKeys)
            } else if let normalizedName = tool.nilIfBlank,
                      !AgentProfileStore.isFeatureManagementToolReference(normalizedName) {
                allowedToolNames.insert(
                    AgentProfileStore.normalizedExternalToolReference(normalizedName) ?? normalizedName
                )
            }
        }
        allowedToolNames.formUnion(
            TerminalToolSelectionCatalog.allowedToolNames(for: selectedKeys, items: items)
        )
        if AgentProfileStore.isBuilderAgent(self) {
            allowedToolNames.formUnion(AgentProfileStore.featureManagementToolNames)
        }
        return resolvedAllowedToolNames(allowedToolNames)
    }

    /// Applies this profile's core-tool policy to an already-resolved grant.
    ///
    /// A read-only profile can retain every grant that does not cover a core
    /// descriptor. When a grant is an exact core name or a prefix that covers
    /// core descriptors, it is replaced by the exact read-only core descriptors
    /// it permits. This prevents broad grants such as `local.` from restoring
    /// mutable core tools while leaving optional feature, MCP, and external
    /// tool grants unchanged.
    public func resolvedAllowedToolNames(
        _ allowedToolNames: Set<String>
    ) -> Set<String> {
        let enforcesReadOnlyCoreGrant = readOnly || AgentProfileStore.isPlannerAgent(self)
        guard enforcesReadOnlyCoreGrant, !allowedToolNames.isEmpty else {
            return allowedToolNames
        }

        let coreDescriptors = DirectToolCatalog.coreDescriptors
        let coreReadDescriptors = DirectToolCatalog.coreReadDescriptors
        let coreGrantNames = Set(allowedToolNames.filter { allowedToolName in
            let grant = Set([allowedToolName])
            return coreDescriptors.contains { DirectToolExecutor.isAllowed($0.name, allowedToolNames: grant) }
        })

        guard !coreGrantNames.isEmpty else {
            return allowedToolNames
        }

        let readOnlyCoreToolNames = Set(coreReadDescriptors.map(\.name).filter {
            DirectToolExecutor.isAllowed($0, allowedToolNames: allowedToolNames)
        })
        return allowedToolNames
            .subtracting(coreGrantNames)
            .union(readOnlyCoreToolNames)
    }

    /// The canonical names of the installed skills among `availableSkills`
    /// that this profile's skills name (compared case-insensitively).
    public func selectedSkillNames(availableSkills: [PromptSkill]) -> Set<String> {
        Set(skills.compactMap { $0.matchingSkillName(in: availableSkills) })
    }
}
