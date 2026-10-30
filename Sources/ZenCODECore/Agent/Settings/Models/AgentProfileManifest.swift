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
        self.skills = try container.decodeIfPresent([AgentProfileSkill].self, forKey: .skills) ?? []

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
        promptSection(memoryToolEnabled: true)
    }

    public func promptSection(memoryToolEnabled: Bool) -> String? {
        var lines = ["Selected agent: \(displayName)"]
        if let resolvedInstructions = resolvedInstructions(memoryToolEnabled: memoryToolEnabled).nilIfBlank {
            lines += ["Agent instructions:", resolvedInstructions]
        }
        return lines.joined(separator: "\n").nilIfBlank
    }

    private func resolvedInstructions(memoryToolEnabled: Bool) -> String {
        guard let instructions else {
            return ""
        }
        guard [true, false].contains(where: {
            instructions == SystemPromptBuilder.defaultAgentInstructions(memoryToolEnabled: $0)
        }) else {
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

    public func selectedSkillIDs(availableSkills: [PromptSkill]) -> Set<String> {
        Set(skills.compactMap { $0.matchingSkillID(in: availableSkills) })
    }
}

public enum AgentProfileStore {
    // Display names of the system profiles. They carry no meaning: a
    // profile's kind is its `role`.
    public static let developerAgentName = "Developer"
    public static let reporterAgentName = "Reporter"
    public static let builderAgentName = "Builder"
    public static let reviewerAgentName = "Reviewer"
    public static let plannerAgentName = "Planner"
    public static let organizerAgentName = "Organizer"
    public static let promoterAgentName = "Promoter"
    public static let testerAgentName = "Tester"
    public static let manifestFilename = "agents.json"
    public static let minimalToolNames: [String] = [
        "shell",
        "files",
        "text"
    ]
    public static let codingToolNames: [String] = [
        "shell",
        "files",
        "search",
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
    public static let reviewerToolNames: [String] = codingToolNames.filter { $0 != "shell" }
    public static let testerToolNames: [String] = codingToolNames.filter { $0 != "memory" }
    public static let reporterToolNames: [String] = [
        "files",
        "search",
        "text",
        TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools")
    ]
    public static let plannerToolNames: [String] = [
        "files",
        "search",
        "text",
        TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools"),
        "memory",
        TerminalToolSelectionCatalog.featurePackageKey(id: "web-tools")
    ]
    public static let organizerToolNames: [String] = [
        TerminalToolSelectionCatalog.featurePackageKey(id: "macOS"),
        "memory",
        "sub-agents"
    ]
    public static let promoterToolNames: [String] = [
        "memory",
        TerminalToolSelectionCatalog.featurePackageKey(id: "browser-tools")
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
        let matches = agents.filter {
            profileReferenceKey($0.id) == key || profileReferenceKey($0.name) == key
        }
        return matches.count == 1 ? matches[0] : nil
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
        return indicesByReference.filter { $0.value.count > 1 }.keys.sorted()
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

    public static func isBuilderAgent(_ agent: AgentProfile?) -> Bool {
        agent?.role == .builder
    }

    public static func isPlannerAgent(_ agent: AgentProfile?) -> Bool {
        agent?.role == .planner
    }

    public static func isReviewerAgent(_ agent: AgentProfile?) -> Bool {
        agent?.role == .reviewer
    }

    public static func normalizedAgentsForSave(_ agents: [AgentProfile]) -> [AgentProfile] {
        agents.map(normalizedAgentForSave)
    }

    public static func normalizedAgentForSave(_ agent: AgentProfile) -> AgentProfile {
        AgentProfile(
            id: agent.id,
            name: agent.name,
            instructions: agent.instructions,
            symbolName: agent.symbolName,
            readOnly: agent.readOnly,
            role: agent.role,
            tools: normalizedToolReferencesForSave(agent.tools),
            skills: agent.skills,
            modelBindings: agent.modelBindings,
            defaultModelBindingID: agent.defaultModelBindingID
        )
    }

    /// The default agent: the system developer profile when present,
    /// otherwise the first profile with the developer role in manifest order.
    public static func developerProfile(in agents: [AgentProfile]) throws -> AgentProfile {
        guard let agent = preferredDeveloper(in: agents) else {
            throw AgentProfileStoreError.developerAgentMissing(agentsManifestURL())
        }
        return agent
    }

    /// The preferred developer among `agents`: the system developer profile
    /// when present, otherwise the first profile with the developer role in
    /// the given order. `nil` when none has the developer role.
    static func preferredDeveloper(in agents: [AgentProfile]) -> AgentProfile? {
        let developers = roleProfiles(.developer, in: agents)
        return developers.first(where: \.isSystemProfile) ?? developers.first
    }

    public static func agentsManifestURL(fileManager: FileManager = .default) -> URL {
        AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(manifestFilename)
            .standardizedFileURL
    }

    /// Tool references as persisted by a save: blanks and feature-management
    /// references are dropped, a reference to a retired optional feature
    /// package (`feature:search-tools`, `search-tools`) becomes the key of the
    /// core group that replaced it, and duplicates are removed keeping the
    /// first occurrence. Loading never rewrites references; only saving does.
    private static func normalizedToolReferencesForSave(_ tools: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for rawTool in tools {
            guard let referencedTool = rawTool.nilIfBlank,
                  !isFeatureManagementToolReference(referencedTool) else {
                continue
            }
            let tool = retiredFeatureReplacementToolReference(referencedTool) ?? referencedTool
            let key = toolReferenceKey(tool)
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(tool)
        }
        return result
    }

    /// The core `/tools` group key that replaced the retired optional feature
    /// package named by `value` (as `feature:<id>` or `<id>`), if any.
    private static func retiredFeatureReplacementToolReference(_ value: String) -> String? {
        let key = toolReferenceKey(value)
        return SwiftBundledFeatureCatalog.retiredFeatureCoreGroupKeys
            .first { featureID, _ in
                key == toolReferenceKey(featureID)
                    || key == toolReferenceKey(TerminalToolSelectionCatalog.featurePackageKey(id: featureID))
            }?
            .value
    }

    fileprivate static func isFeatureManagementToolReference(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.lowercased().hasPrefix("feature.") {
            return true
        }
        let normalizedValue = toolReferenceKey(value)
        return normalizedValue == toolReferenceKey(TerminalToolSelectionCatalog.featureBuilderKey)
            || ["feature-builder", "feature-manager", "feature", "features", "kernel"].contains(normalizedValue)
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
