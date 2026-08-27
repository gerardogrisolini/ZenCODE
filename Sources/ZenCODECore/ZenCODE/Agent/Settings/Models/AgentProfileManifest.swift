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
    public let tools: [String]
    public let skills: [AgentProfileSkill]
    public let modelBindings: [AgentModelBinding]
    public let defaultModelBindingID: String?

    /// The binding used by default for this profile.
    ///
    /// An invalid or absent persisted default falls back to the first
    /// normalized binding, whose ordering is stable across saves.
    public var defaultModelBinding: AgentModelBinding? {
        guard let defaultModelBindingID else {
            return modelBindings.first
        }
        return modelBindings.first(where: {
            Self.modelBindingKey($0.id) == Self.modelBindingKey(defaultModelBindingID)
        }) ?? modelBindings.first
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
        if let binding = modelBindings.first(where: {
            Self.modelBindingKey($0.id) == key
        }) {
            return binding
        }
        return modelBindings.first(where: {
            Self.modelBindingKey($0.modelID) == key
        })
    }

    /// Convenience model identifier for the resolved default binding.
    public var defaultModelID: String? {
        defaultModelBinding?.modelID
    }

    // Compatibility accessors for the previous single-model profile shape.
    // New persistence is always expressed through `modelBindings`.
    public var modelID: String? {
        defaultModelBinding?.modelID
    }

    public var modelProvider: String? {
        defaultModelBinding?.modelProvider
    }

    public var thinkingSelection: AgentThinkingSelection? {
        defaultModelBinding?.thinkingSelection
    }

    public var capability: Int? {
        defaultModelBinding?.capability
    }

    public init(
        id: String,
        name: String,
        instructions: String? = nil,
        symbolName: String? = nil,
        readOnly: Bool = false,
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
        self.tools = tools
        self.skills = skills

        let sourceBindings = Self.sourceModelBindings(
            modelBindings.isEmpty ? nil : modelBindings,
            legacyModelID: modelID,
            legacyModelProvider: modelProvider,
            legacyThinkingSelection: thinkingSelection,
            legacyCapability: capability
        )
        let normalizedBindings = Self.normalizedModelBindings(sourceBindings)
        self.modelBindings = normalizedBindings
        self.defaultModelBindingID = Self.resolvedDefaultModelBindingID(
            in: normalizedBindings,
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
        self.tools = try container.decodeIfPresent([String].self, forKey: .tools) ?? []
        self.skills = try container.decodeIfPresent([AgentProfileSkill].self, forKey: .skills) ?? []

        let legacyModelID = try container.decodeIfPresent(String.self, forKey: .modelID)?.nilIfBlank
        let legacyModelProvider = try container.decodeIfPresent(
            String.self,
            forKey: .modelProvider
        )?.nilIfBlank
        let legacyThinkingSelection = try container.decodeIfPresent(
            AgentThinkingSelection.self,
            forKey: .thinkingSelection
        )
        let legacyCapability = try container.decodeIfPresent(Int.self, forKey: .capability)
        let decodedBindings = try container.decodeIfPresent(
            [AgentModelBinding].self,
            forKey: .modelBindings
        )
        let sourceBindings = Self.sourceModelBindings(
            decodedBindings,
            legacyModelID: legacyModelID,
            legacyModelProvider: legacyModelProvider,
            legacyThinkingSelection: legacyThinkingSelection,
            legacyCapability: legacyCapability
        )
        let normalizedBindings = Self.normalizedModelBindings(sourceBindings)
        self.modelBindings = normalizedBindings
        self.defaultModelBindingID = Self.resolvedDefaultModelBindingID(
            in: normalizedBindings,
            preferredBindingID: try container.decodeIfPresent(
                String.self,
                forKey: .defaultModelBindingID
            ),
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

    private static func sourceModelBindings(
        _ bindings: [AgentModelBinding]?,
        legacyModelID: String?,
        legacyModelProvider: String?,
        legacyThinkingSelection: AgentThinkingSelection?,
        legacyCapability: Int?
    ) -> [AgentModelBinding] {
        guard let bindings else {
            guard let legacyModelID = legacyModelID?.nilIfBlank else { return [] }
            return [AgentModelBinding(
                id: legacyModelID,
                modelID: legacyModelID,
                modelProvider: legacyModelProvider,
                thinkingSelection: legacyThinkingSelection,
                capability: legacyCapability
            )]
        }
        return bindings
    }

    private static func normalizedModelBindings(
        _ bindings: [AgentModelBinding]
    ) -> [AgentModelBinding] {
        let sortedBindings = bindings
            .filter(\.isValid)
            .sorted { lhs, rhs in
                let lhsID = modelBindingKey(lhs.id)
                let rhsID = modelBindingKey(rhs.id)
                if lhsID != rhsID {
                    return lhsID < rhsID
                }

                let lhsModelID = modelBindingKey(lhs.modelID)
                let rhsModelID = modelBindingKey(rhs.modelID)
                if lhsModelID != rhsModelID {
                    return lhsModelID < rhsModelID
                }
                return lhs.modelProvider ?? "" < rhs.modelProvider ?? ""
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
           let binding = bindings.first(where: {
               modelBindingKey($0.id) == modelBindingKey(preferredBindingID)
           }) {
            return binding.id
        }

        if let preferredModelID,
           let binding = bindings.first(where: {
               modelBindingKey($0.modelID) == modelBindingKey(preferredModelID)
           }) {
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
        promptSection(memoryToolEnabled: true)
    }

    public func promptSection(memoryToolEnabled: Bool) -> String? {
        var lines = ["Selected agent: \(displayName)"]
        var instructionSections: [String] = []
        if let resolvedInstructions = resolvedInstructions(
            memoryToolEnabled: memoryToolEnabled
        ).nilIfBlank {
            instructionSections.append(resolvedInstructions)
        }
        if AgentProfileStore.isBuilderAgent(self) {
            instructionSections.append(AgentProfileStore.builderWorkflowInstructions)
        }
        if !instructionSections.isEmpty {
            lines.append("Agent instructions:")
            lines.append(instructionSections.joined(separator: "\n\n"))
        }
        return lines.joined(separator: "\n").nilIfBlank
    }

    private func resolvedInstructions(memoryToolEnabled: Bool) -> String {
        guard let instructions else {
            return ""
        }
        let defaultInstructionsWithMemory = SystemPromptBuilder.defaultAgentInstructions(memoryToolEnabled: true)
        let defaultInstructionsWithoutMemory = SystemPromptBuilder.defaultAgentInstructions(memoryToolEnabled: false)
        guard instructions == defaultInstructionsWithMemory || instructions == defaultInstructionsWithoutMemory else {
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
            let matchingKeys = TerminalToolSelectionCatalog.selectionKeys(
                for: tool,
                items: items
            )
            if matchingKeys.isEmpty {
                if let normalizedName = tool.nilIfBlank {
                    guard !AgentProfileStore.isFeatureManagementToolReference(normalizedName) else {
                        continue
                    }
                    if let externalToolName = AgentProfileStore.normalizedExternalToolReference(normalizedName) {
                        allowedToolNames.insert(externalToolName)
                        continue
                    }
                    allowedToolNames.insert(normalizedName)
                }
            } else {
                selectedKeys.formUnion(matchingKeys)
            }
        }
        allowedToolNames.formUnion(
            TerminalToolSelectionCatalog.allowedToolNames(
                for: selectedKeys,
                items: items
            )
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
        guard readOnly, !allowedToolNames.isEmpty else {
            return allowedToolNames
        }

        let coreDescriptors = DirectToolCatalog.coreDescriptors
        let coreReadDescriptors = DirectToolCatalog.coreReadDescriptors
        let coreGrantNames = Set(allowedToolNames.filter { allowedToolName in
            let grant = Set([allowedToolName])
            return coreDescriptors.contains { descriptor in
                DirectToolExecutor.isAllowed(
                    descriptor.name,
                    allowedToolNames: grant
                )
            }
        })

        guard !coreGrantNames.isEmpty else {
            return allowedToolNames
        }

        let readOnlyCoreToolNames = Set(coreReadDescriptors.compactMap { descriptor in
            DirectToolExecutor.isAllowed(
                descriptor.name,
                allowedToolNames: allowedToolNames
            ) ? descriptor.name : nil
        })
        return allowedToolNames
            .subtracting(coreGrantNames)
            .union(readOnlyCoreToolNames)
    }

    public func selectedSkillIDs(availableSkills: [PromptSkill]) -> Set<String> {
        return Set(
            skills.compactMap { skill in
                skill.matchingSkillID(in: availableSkills)
            }
        )
    }

}

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

        if let titleKey,
           let summaryKey,
           let skill = availableSkills.first(where: {
               $0.title.selectionKey == titleKey && $0.summary.selectionKey == summaryKey
           }) {
            return skill.id
        }

        if let titleKey {
            let matches = availableSkills.filter { $0.title.selectionKey == titleKey }
            if matches.count == 1 {
                return matches[0].id
            }
        }

        return nil
    }
}

public enum AgentProfileStore {
    public static let developerAgentName = "Developer"
    public static let developerAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    public static let reporterAgentName = "Reporter"
    public static let reporterAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
    public static let builderAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    public static let minimalAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
    public static let reviewerAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    public static let plannerAgentID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    public static let builderAgentName = "Builder"
    public static let reviewerAgentName = "Reviewer"
    public static let plannerAgentName = "Planner"
    public static let manifestFilename = "agents.json"
    public static let minimalToolNames: [String] = [
        "shell",
        "files",
        "text"
    ]
    public static let codingToolNames: [String] = [
        "shell",
        "files",
        TerminalToolSelectionCatalog.featurePackageKey(id: "search-tools"),
        "text",
        TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools"),
        //TerminalToolSelectionCatalog.featurePackageKey(id: "swift-tools"),
        "memory"
    ]
    public static let developerToolNames: [String] = codingToolNames + [
        TerminalToolSelectionCatalog.featurePackageKey(id: "web-tools"),
        "sub-agents"
    ]
    public static let builderToolNames: [String] = codingToolNames + [
        TerminalToolSelectionCatalog.featurePackageKey(id: "web-tools")
    ]
    static let builderWorkflowInstructions = """
    Builder workflow policy:
    - Use Dynamic Swift Features only for reusable runtime capabilities, not ordinary one-off edits.
    - For a Basic feature, scaffold a disabled draft, implement the real behavior first, then run `feature.validate` followed by `feature.build`. Never enable placeholder, incomplete, invalid, or unbuilt code.
    - For an MCP bridge, collect only non-secret transport configuration. Never embed credentials, API keys, tokens, passwords, or environment values in generated source or endpoint URLs; stdio bridges inherit the ZenCODE process environment.
    - Enable a feature only after validation and build succeed. `/tools` remains the explicit session-level control for exposing its tools.
    - A successful `feature.build` reloads the feature runtime. Use `feature.reload` only after external file changes or when runtime discovery must be refreshed.
    """
    public static let reviewerToolNames: [String] = codingToolNames.filter { $0 != "shell" }
    public static let reporterToolNames: [String] = [
        "files",
        TerminalToolSelectionCatalog.featurePackageKey(id: "search-tools"),
        "text",
        TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools")
    ]
    public static let plannerToolNames: [String] = [
        "files",
        TerminalToolSelectionCatalog.featurePackageKey(id: "search-tools"),
        "text",
        TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools"),
        "memory",
        TerminalToolSelectionCatalog.featurePackageKey(id: "web-tools")
    ]
    public static let featureManagementToolNames = Set(DirectToolCatalog.featureDescriptors.map(\.name))

    private static let identityLocale = Locale(identifier: "en_US_POSIX")

    /// Stable key for persisted profile identity. User locale must never change
    /// which profile (and therefore which tool grant) a reference selects.
    public static func profileReferenceKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: identityLocale
            )
            .lowercased(with: identityLocale)
    }

    public static func agent(
        matching reference: String,
        in agents: [AgentProfile]
    ) -> AgentProfile? {
        let key = profileReferenceKey(reference)
        guard !key.isEmpty else { return nil }
        let matches = agents.enumerated().filter { _, agent in
            profileReferenceKey(agent.id) == key
                || profileReferenceKey(agent.name) == key
        }
        guard matches.count == 1 else { return nil }
        return matches[0].element
    }

    static func roleProfile(
        id: UUID,
        name: String,
        in profiles: [AgentProfile]
    ) -> AgentProfile? {
        profiles.first {
            $0.id.caseInsensitiveCompare(id.uuidString) == .orderedSame
                || $0.name.caseInsensitiveCompare(name) == .orderedSame
        } ?? defaultProfiles().first {
            $0.id.caseInsensitiveCompare(id.uuidString) == .orderedSame
        }
    }

    public static func ambiguousProfileReferences(
        in agents: [AgentProfile]
    ) -> [String] {
        var indicesByReference: [String: Set<Int>] = [:]
        for (index, agent) in agents.enumerated() {
            for reference in [agent.id, agent.name] {
                let key = profileReferenceKey(reference)
                guard !key.isEmpty else { continue }
                indicesByReference[key, default: []].insert(index)
            }
        }
        return indicesByReference.compactMap { key, indices in
            indices.count > 1 ? key : nil
        }.sorted()
    }

    public static func unambiguousAgents(
        in agents: [AgentProfile]
    ) -> [AgentProfile] {
        let ambiguous = Set(ambiguousProfileReferences(in: agents))
        guard !ambiguous.isEmpty else { return agents }
        return agents.filter { agent in
            !ambiguous.contains(profileReferenceKey(agent.id))
                && !ambiguous.contains(profileReferenceKey(agent.name))
        }
    }

    public static func loadRequired(fileManager: FileManager = .default) throws -> [AgentProfile] {
        let url = agentsManifestURL(fileManager: fileManager)
        return try loadRequiredUnlocked(from: url, fileManager: fileManager)
    }

    static func loadRequiredUnlocked(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> [AgentProfile] {
        guard fileManager.fileExists(atPath: url.path) else {
            throw AgentProfileStoreError.missingFile(url)
        }

        let data: Data
        do {
            try SensitiveFilePermissions.hardenExistingFile(
                at: url,
                fileManager: fileManager
            )
            data = try Data(contentsOf: url)
        } catch {
            throw AgentProfileStoreError.unreadableFile(url, error)
        }

        let manifest: AgentProfileManifest
        do {
            manifest = try JSONDecoder().decode(AgentProfileManifest.self, from: data)
        } catch {
            throw AgentProfileStoreError.invalidFile(url, error)
        }

        guard manifest.version == AgentProfileManifest.currentVersion else {
            throw AgentProfileStoreError.unsupportedVersion(
                url,
                manifest.version,
                AgentProfileManifest.currentVersion
            )
        }

        guard !manifest.agents.isEmpty else {
            throw AgentProfileStoreError.noAgents(url)
        }
        let ambiguousReferences = ambiguousProfileReferences(in: manifest.agents)
        guard ambiguousReferences.isEmpty else {
            throw AgentProfileStoreError.ambiguousProfileReferences(
                url,
                ambiguousReferences
            )
        }
        return manifest.agents
    }

    public static func save(
        _ agents: [AgentProfile],
        fileManager: FileManager = .default
    ) throws {
        let url = agentsManifestURL(fileManager: fileManager)
        let data = try encodedData(for: agents, fileManager: fileManager)
        try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: url.deletingLastPathComponent(),
            fileManager: fileManager
        ) {
            try SensitiveFilePermissions.write(data, to: url, fileManager: fileManager)
        }
    }

    static func encodedData(
        for agents: [AgentProfile],
        fileManager: FileManager = .default
    ) throws -> Data {
        let url = agentsManifestURL(fileManager: fileManager)
        let normalizedAgents = normalizedAgentsForSave(agents)
        let ambiguousReferences = ambiguousProfileReferences(in: normalizedAgents)
        guard ambiguousReferences.isEmpty else {
            throw AgentProfileStoreError.ambiguousProfileReferences(
                url,
                ambiguousReferences
            )
        }
        let manifest = AgentProfileManifest(
            agents: normalizedAgents.sorted {
                profileReferenceKey($0.displayName) < profileReferenceKey($1.displayName)
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    @discardableResult
    public static func ensureDefaultManifestExists(
        fileManager: FileManager = .default
    ) throws -> URL {
        let url = agentsManifestURL(fileManager: fileManager)
        guard !fileManager.fileExists(atPath: url.path) else {
            _ = try loadRequired(fileManager: fileManager)
            return url
        }

        try save(defaultProfiles(), fileManager: fileManager)
        return url
    }

    public static func defaultProfiles() -> [AgentProfile] {
        [
            AgentProfile(
                id: developerAgentID.uuidString,
                name: developerAgentName,
                instructions: """
                Developer agent. Implement the user's request with the available tools, keep changes focused, and validate important work before reporting completion.
                """,
                symbolName: "person.crop.circle",
                tools: developerToolNames
            ),
            AgentProfile(
                id: builderAgentID.uuidString,
                name: builderAgentName,
                instructions: """
                Builder agent. Manage Swift feature packages only when reusable runtime capability is requested.
                """,
                symbolName: "hammer",
                tools: builderToolNames
            ),
            AgentProfile(
                id: minimalAgentID.uuidString,
                name: "Minimal",
                instructions: """
                Minimal agent. Use essential tools only, answer briefly, and avoid extra workflow unless asked.
                """,
                symbolName: "circle",
                tools: minimalToolNames
            ),
            AgentProfile(
                id: reviewerAgentID.uuidString,
                name: reviewerAgentName,
                instructions: """
                Reviewer agent. Perform read-only code review on the requested change surface, inspect current source files only as needed for context, then report concrete findings. Do not edit files.

                Report correctness bugs, regressions, security and concurrency issues, missing tests, and style or convention violations. Reference findings with file:line and a severity, and group the summary by severity.
                """,
                symbolName: "magnifyingglass.circle",
                readOnly: true,
                tools: reviewerToolNames
            ),
            AgentProfile(
                id: reporterAgentID.uuidString,
                name: reporterAgentName,
                instructions: """
                Reporter agent. Analyze the requested code surface and produce a structured, evidence-based report.

                Explain architecture, dependencies, control and data flows, APIs, configuration, tests, implementation status, and likely change impact as relevant. Distinguish verified facts from inferences and cite important evidence with file:line references.
                """,
                symbolName: "doc.text.magnifyingglass",
                tools: reporterToolNames
            ),
            AgentProfile(
                id: plannerAgentID.uuidString,
                name: plannerAgentName,
                instructions: """
                Planner agent. Perform read-only planning before implementation. Inspect the request, conversation, and workspace before deciding whether clarification is needed. Do not edit files.

                Ask at most one focused numbered question block per turn, only for material decisions that cannot be resolved from available evidence; include impact and a recommended choice when useful. If the request is already sufficiently defined, skip questions. Continue the same discussion across operator replies and ask another block only if a material decision still remains; then produce `Specifiche concordate` followed by an actionable numbered `Implementation plan` with verified files or symbols, dependencies, edge cases, and validation. Report only fresh output for the current turn.
                """,
                symbolName: "list.bullet.clipboard",
                readOnly: true,
                tools: plannerToolNames
            )
        ]
    }

    public static func isBuilderAgent(_ agent: AgentProfile?) -> Bool {
        guard let agent else {
            return false
        }
        return agent.id.selectionKey == builderAgentID.uuidString.selectionKey
            || agent.name.selectionKey == builderAgentName.selectionKey
    }

    public static func normalizedAgentsForSave(_ agents: [AgentProfile]) -> [AgentProfile] {
        agents.map(normalizedAgentForSave)
    }

    public static func normalizedAgentForSave(_ agent: AgentProfile) -> AgentProfile {
        let tools = normalizedToolReferencesForSave(agent.tools)

        return AgentProfile(
            id: agent.id,
            name: agent.name,
            instructions: agent.instructions,
            symbolName: agent.symbolName,
            readOnly: agent.readOnly,
            tools: tools,
            skills: agent.skills,
            modelBindings: agent.modelBindings,
            defaultModelBindingID: agent.defaultModelBindingID
        )
    }

    public static func developerProfile(in agents: [AgentProfile]) throws -> AgentProfile {
        guard let agent = agent(matching: developerAgentName, in: agents) else {
            throw AgentProfileStoreError.developerAgentMissing(agentsManifestURL())
        }
        return agent
    }

    public static func agentsManifestURL(fileManager: FileManager = .default) -> URL {
        return AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(manifestFilename)
            .standardizedFileURL
    }

    private static func normalizedToolReferencesForSave(_ tools: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawTool in tools {
            guard let tool = rawTool.nilIfBlank,
                  !isFeatureManagementToolReference(tool) else {
                continue
            }
            let key = toolReferenceKey(tool)
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(tool)
        }
        return result
    }

    fileprivate static func isFeatureManagementToolReference(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.lowercased().hasPrefix("feature.") {
            return true
        }
        let normalizedValue = toolReferenceKey(value)
        return normalizedValue == toolReferenceKey(TerminalToolSelectionCatalog.featureBuilderKey)
            || normalizedValue == "feature-builder"
            || normalizedValue == "feature-manager"
            || normalizedValue == "feature"
            || normalizedValue == "features"
            || normalizedValue == "kernel"
    }

    fileprivate static func normalizedExternalToolReference(_ value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedValue = toolReferenceKey(trimmedValue)
        for feature in SwiftBundledFeatureCatalog.definitions() {
            let shortID = feature.id.hasSuffix("-tools")
                ? String(feature.id.dropLast("-tools".count))
                : feature.id
            if normalizedValue == toolReferenceKey(feature.id)
                || normalizedValue == toolReferenceKey(shortID) {
                return feature.toolNamePrefixes.first
            }
            if feature.toolNamePrefixes.contains(where: { trimmedValue.hasPrefix($0) }) {
                return trimmedValue
            }
            if let alias = feature.toolNameAliases.first(where: {
                $0.caseInsensitiveCompare(trimmedValue) == .orderedSame
            }) {
                return alias
            }
        }
        return nil
    }

    private static func toolReferenceKey(_ value: String) -> String {
        let foldedValue = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: identityLocale
        )
        let characters = foldedValue.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(characters)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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
    fileprivate var selectionKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}
