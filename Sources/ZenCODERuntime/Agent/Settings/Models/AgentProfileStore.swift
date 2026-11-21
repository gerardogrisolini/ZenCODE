//
//  AgentProfileStore.swift
//  ZenCODE
//
//  Agent profile store: the built-in agent names and tool sets, profile
//  lookup by reference, and loading, normalizing and saving the agents
//  manifest.
//

import Foundation
import ToolCore

public enum AgentProfileStore {
    // Display names of the system profiles. They carry no meaning: a
    // profile's kind is its `role`.
    public static let developerAgentName = "Developer"
    public static let reporterAgentName = "Reporter"
    public static let builderAgentName = "Builder"
    public static let reviewerAgentName = "Reviewer"
    public static let plannerAgentName = "Planner"
    public static let organizerAgentName = "Organizer"
    public static let testerAgentName = "Tester"
    public static let manifestFilename = "agents.json"
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

    static func isFeatureManagementToolReference(_ value: String) -> Bool {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedValue.lowercased().hasPrefix("feature.") {
            return true
        }
        let normalizedValue = toolReferenceKey(value)
        return normalizedValue == toolReferenceKey(TerminalToolSelectionCatalog.featureBuilderKey)
            || ["feature-builder", "feature-manager", "feature", "features", "kernel"].contains(normalizedValue)
    }

    static func normalizedExternalToolReference(_ value: String) -> String? {
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
