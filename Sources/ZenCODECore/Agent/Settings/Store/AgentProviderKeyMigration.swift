//
//  AgentProviderKeyMigration.swift
//  ZenCODE
//

import Foundation

/// Settings v14 -> v15 migration: providers are identified by stable string
/// keys instead of UUIDs.
///
/// It owns the only legacy-UUID -> key map, so `settings.json` and the model
/// references in `agents.json` are rewritten together, in one journaled
/// transaction under the shared manifest lock (`ZenFileService.commitManifests`,
/// atomic `0600` writes). It runs at composition start (`zen` main) and after a
/// backup import, before anything else loads or saves the manifests.
///
/// - Provider ids: the former fixed UUIDs and the subscription protocols map
///   to `chatgpt` / `claude`; the former DS4 UUID or a DS4 runtime maps to
///   `ds4` (a `custom` provider profile becomes `ds4`); every other provider
///   receives ``AgentRemoteProvider/providerKey(providerProfileID:protocolProfileID:)``.
/// - Model ids `remoteapi:<uuid>:<model>` (and their `llmID`) become
///   `<key>:<model>`; the selected model, the API-key map keys and
///   `memoryEmbedding.providerID` follow. Subscription and DS4 model ids are
///   unchanged.
/// - Two legacy providers mapping to one key: the first in persisted order is
///   kept; the later one is dropped with its models and API key, and a warning
///   names it.
/// - `agents.json`: binding `id`/`modelID`, `defaultModelBindingID` and the
///   legacy profile-level `modelID`/`defaultModelID` that use a legacy remote
///   id are rewritten at JSON level, so profiles that fail strict decoding are
///   preserved too.
///
/// Idempotent: a file at the current version whose provider ids are all known
/// keys is never touched (and neither is `agents.json`).
public enum AgentProviderKeyMigration {
    /// Former fixed provider UUIDs (pre-v15), lowercased like decoded ids.
    static let legacyChatGPTSubscriptionProviderID = "00000000-0000-0000-0000-000000000003"
    static let legacyAnthropicSubscriptionProviderID = "00000000-0000-0000-0000-000000000004"
    static let legacyDS4ProviderID = "00000000-0000-0000-0000-000000000005"

    private static let legacyRemoteAPIModelPrefix = "remoteapi:"

    /// The former fixed UUIDs and the keys they identify. Their providers may
    /// carry no profiles at all (the UUID alone selected the subscription), so
    /// they are rewritten to their keys before decoding: the key then drives
    /// the same profile inference the UUID used to.
    static let legacyFixedProviderIDs: [String: String] = [
        legacyChatGPTSubscriptionProviderID: AgentRemoteProvider.chatGPTSubscriptionProviderID,
        legacyAnthropicSubscriptionProviderID: AgentRemoteProvider.anthropicSubscriptionProviderID,
        legacyDS4ProviderID: AgentRemoteProvider.ds4ProviderID
    ]

    /// What a migration run changed.
    public struct Report: Equatable, Sendable {
        /// Filenames rewritten (`settings.json`, optionally `agents.json`).
        public let migratedFilenames: [String]
        /// Human-readable warnings, such as dropped duplicate providers.
        public let warnings: [String]

        public var didMigrate: Bool { !migratedFilenames.isEmpty }

        static let unchanged = Report(migratedFilenames: [], warnings: [])
    }

    /// The pure result of migrating the two manifests.
    struct Result: Equatable {
        let settingsData: Data
        /// `nil` when `agents.json` must stay untouched.
        let agentsData: Data?
        let warnings: [String]
        /// Legacy provider id -> stable key, including dropped duplicates.
        let providerIDs: [String: String]
    }

    /// Composition-start entry point. It never throws: a failure is reported
    /// on standard error and the files stay as they were (legacy settings
    /// still load), so the migration is simply retried at the next start.
    public static func migrateIfNeededReportingFailures(
        fileManager: FileManager = .default
    ) {
        let warningSink: (String) -> Void = {
            AgentOutput.standardError.writeString("ZenCODE: \($0)\n")
        }
        do {
            try migrateIfNeeded(
                supportDirectoryURL: AppStorageDirectory
                    .appSupportDirectoryURL(fileManager: fileManager)
                    .standardizedFileURL,
                fileManager: fileManager,
                warningSink: warningSink
            )
        } catch {
            warningSink(
                "could not migrate provider keys in settings.json: \(error.localizedDescription) "
                    + "The files were left unchanged; the migration is retried at the next start."
            )
        }
    }

    /// Migrates `settings.json` and `agents.json` in `supportDirectoryURL` when
    /// settings are not current. Warnings are delivered to `warningSink` only
    /// after a successful commit.
    @discardableResult
    static func migrateIfNeeded(
        supportDirectoryURL: URL,
        fileManager: FileManager = .default,
        warningSink: (String) -> Void = { _ in }
    ) throws -> Report {
        let directory = supportDirectoryURL.standardizedFileURL
        let settingsURL = directory.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        let agentsURL = directory.appendingPathComponent(AgentProfileStore.manifestFilename)
        // No settings, nothing to migrate: never create the support directory
        // or the lock file just to find that out.
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return .unchanged
        }
        let report = try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: directory,
            fileManager: fileManager
        ) { () throws -> Report in
            func dataIfPresent(at url: URL) throws -> Data? {
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                try SensitiveFilePermissions.hardenExistingFile(at: url, fileManager: fileManager)
                return try Data(contentsOf: url)
            }
            guard let settingsData = try dataIfPresent(at: settingsURL),
                  let result = try migratedData(
                      settingsData: settingsData,
                      agentsData: try dataIfPresent(at: agentsURL)
                  ) else {
                return .unchanged
            }
            var writes = [
                ZenFileService.CoordinatedManifestWrite(url: settingsURL, data: result.settingsData)
            ]
            if let agentsData = result.agentsData {
                writes.append(ZenFileService.CoordinatedManifestWrite(url: agentsURL, data: agentsData))
            }
            try ZenFileService.commitManifests(
                writes,
                fileManager: fileManager,
                checkpoint: nil,
                transactionCleanup: nil
            )
            return Report(
                migratedFilenames: writes.map(\.url.lastPathComponent),
                warnings: result.warnings
            )
        }
        report.warnings.forEach(warningSink)
        return report
    }

    /// Pure migration of the two manifests. Returns `nil` when `settings.json`
    /// is already current, or is not a supported manifest at all (the regular
    /// loader then reports it unchanged).
    static func migratedData(
        settingsData: Data,
        agentsData: Data?
    ) throws -> Result? {
        guard let rawSettingsObject = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let version = rawSettingsObject["version"] as? Int,
              version >= AgentSettingsManifest.minimumSupportedVersion,
              version <= AgentSettingsManifest.currentVersion else {
            return nil
        }
        let (settingsObject, replacedFixedIDs) = replacingLegacyFixedProviderIDs(in: rawSettingsObject)
        guard let normalizedSettingsData = try? JSONSerialization.data(withJSONObject: settingsObject),
              let manifest = try? JSONDecoder().decode(AgentSettingsManifest.self, from: normalizedSettingsData) else {
            return nil
        }
        let referencedProviderIDs = manifest.providers.map(\.id)
            + manifest.models.compactMap { $0.provider?.id ?? $0.providerID }
        guard version < AgentSettingsManifest.currentVersion
                || replacedFixedIDs
                || referencedProviderIDs.contains(where: { !AgentRemoteProvider.knownProviderIDs.contains($0) }) else {
            return nil
        }

        // Collisions keep the first provider in persisted (array) order; the
        // decoded manifest is sorted by title, so restore the file order.
        let persistedOrder = persistedProviderOrder(settingsObject)
        let orderedProviders = manifest.providers.enumerated().sorted { lhs, rhs in
            let lhsIndex = persistedOrder[lhs.element.id] ?? Int.max
            let rhsIndex = persistedOrder[rhs.element.id] ?? Int.max
            return lhsIndex == rhsIndex ? lhs.offset < rhs.offset : lhsIndex < rhsIndex
        }.map(\.element)

        var providerIDs: [String: String] = legacyFixedProviderIDs
        var keptProviders: [AgentSettingsProviderManifest] = []
        var keptLegacyIDs: Set<String> = []
        var droppedLegacyIDs: Set<String> = []
        var warnings: [String] = []
        for provider in orderedProviders {
            let hasDS4Models = manifest.models.contains { model in
                (model.provider?.id ?? model.providerID) == provider.id && model.ds4Runtime != nil
            }
            let identity = migratedIdentity(of: provider, hasDS4Models: hasDS4Models)
            providerIDs[provider.id] = identity.id
            if keptProviders.contains(where: { $0.id == identity.id }) {
                droppedLegacyIDs.insert(provider.id)
                warnings.append(
                    "settings migration dropped the duplicate provider '\(provider.displayTitle)' "
                        + "together with its models and API key: provider '\(identity.id)' is already configured. "
                        + "Reconfigure the remaining provider in /setup if needed."
                )
                continue
            }
            keptLegacyIDs.insert(provider.id)
            keptProviders.append(
                AgentSettingsProviderManifest(
                    id: identity.id,
                    name: provider.name,
                    baseURL: provider.baseURL,
                    chatEndpoint: provider.chatEndpoint,
                    providerProfileID: identity.providerProfileID,
                    protocolProfileID: provider.protocolProfileID,
                    authPolicy: provider.authPolicy,
                    ds4Runtime: provider.ds4Runtime
                )
            )
        }

        let models = manifest.models.compactMap { model -> AgentSettingsModelManifest? in
            guard let legacyProviderID = model.provider?.id ?? model.providerID else {
                return model
            }
            if droppedLegacyIDs.contains(legacyProviderID) {
                return nil
            }
            guard let providerID = providerIDs[legacyProviderID] else {
                return model
            }
            let identity = keptProviders.first { $0.id == providerID }
            return AgentSettingsModelManifest(
                id: rewrittenModelReference(model.id, providerIDs: providerIDs) ?? model.id,
                kind: model.kind,
                title: model.title,
                llmID: model.llmID.map { rewrittenModelReference($0, providerIDs: providerIDs) ?? $0 },
                modelID: model.modelID,
                providerID: providerID,
                provider: model.provider.map { provider in
                    AgentRemoteProvider(
                        id: providerID,
                        name: provider.name,
                        baseURL: provider.baseURL,
                        modelID: provider.modelID,
                        chatEndpoint: provider.chatEndpoint,
                        providerProfileID: identity?.providerProfileID ?? provider.providerProfileID,
                        protocolProfileID: provider.protocolProfileID,
                        authPolicy: provider.authPolicy,
                        ds4Runtime: provider.ds4Runtime
                    )
                },
                configuredContextWindowLimit: model.configuredContextWindowLimit,
                generationParameterOverrides: model.generationParameterOverrides,
                apiKey: model.apiKey,
                thinkingOptions: model.thinkingOptions,
                defaultThinkingSelection: model.defaultThinkingSelection,
                ds4Runtime: model.ds4Runtime
            )
        }

        var apiKeys: [String: String] = [:]
        for (legacyProviderID, apiKey) in manifest.remoteAPIKeysByProviderID
        where keptLegacyIDs.contains(legacyProviderID) {
            if let providerID = providerIDs[legacyProviderID] {
                apiKeys[providerID] = apiKey
            }
        }

        let memoryEmbedding = manifest.memoryEmbedding.map { settings in
            guard let legacyProviderID = settings.providerID else {
                return settings
            }
            let providerID = providerIDs[legacyProviderID].flatMap { key in
                keptProviders.contains { $0.id == key } ? key : nil
            }
            return AgentMemoryEmbeddingSettingsManifest(
                endpoint: settings.endpoint,
                model: settings.model,
                providerID: providerID
            )
        }

        let migratedManifest = AgentSettingsManifest(
            version: AgentSettingsManifest.currentVersion,
            providers: keptProviders,
            models: models,
            selectedModelID: manifest.selectedModelID.map {
                rewrittenModelReference($0, providerIDs: providerIDs) ?? $0
            },
            selectedThinkingSelection: manifest.selectedThinkingSelection,
            telegram: manifest.telegram,
            voice: manifest.voice,
            remoteAPIKeysByProviderID: apiKeys,
            localExecAllowedCommands: manifest.localExecAllowedCommands,
            chatGPTSubscriptionCredentials: manifest.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: manifest.anthropicSubscriptionCredentials,
            responseLanguage: manifest.responseLanguage,
            memoryEmbedding: memoryEmbedding
        )

        var migratedAgentsData: Data?
        if let agentsData {
            switch migratedAgentsManifest(agentsData, providerIDs: providerIDs) {
            case let .migrated(data):
                migratedAgentsData = data
            case .unchanged:
                migratedAgentsData = nil
            case .unreadable:
                migratedAgentsData = nil
                warnings.append(
                    "agents.json is not a valid JSON object, so its model bindings were not migrated to the new provider keys."
                )
            }
        }

        return Result(
            settingsData: try AgentSettingsManifestStore.encodedData(for: migratedManifest),
            agentsData: migratedAgentsData,
            warnings: warnings,
            providerIDs: providerIDs
        )
    }

    /// The stable key and provider profile of a legacy provider (the fixed
    /// UUIDs are already rewritten to their keys).
    static func migratedIdentity(
        of provider: AgentSettingsProviderManifest,
        hasDS4Models: Bool = false
    ) -> (id: String, providerProfileID: AgentProviderProfileID) {
        let fixedID = legacyFixedProviderIDs[provider.id] ?? provider.id
        if fixedID == AgentRemoteProvider.chatGPTSubscriptionProviderID
            || provider.protocolProfileID == .openAIChatGPTSubscription {
            return (AgentRemoteProvider.chatGPTSubscriptionProviderID, provider.providerProfileID)
        }
        if fixedID == AgentRemoteProvider.anthropicSubscriptionProviderID
            || provider.protocolProfileID == .anthropicClaudeSubscription {
            return (AgentRemoteProvider.anthropicSubscriptionProviderID, provider.providerProfileID)
        }
        if fixedID == AgentRemoteProvider.ds4ProviderID || provider.ds4Runtime != nil || hasDS4Models {
            return (
                AgentRemoteProvider.ds4ProviderID,
                provider.providerProfileID == .custom ? .ds4 : provider.providerProfileID
            )
        }
        return (
            AgentRemoteProvider.providerKey(
                providerProfileID: provider.providerProfileID,
                protocolProfileID: provider.protocolProfileID
            ),
            provider.providerProfileID
        )
    }

    /// Rewrites a legacy `remoteapi:<legacy-provider-id>:<model>` reference to
    /// `<key>:<model>`, or returns `nil` when `value` is not such a reference
    /// or names no legacy provider. A `<legacy-provider-id>:<model>` reference
    /// (an id built on a not-yet-migrated provider id) is rewritten the same
    /// way when the prefix is a legacy id that maps to a different key.
    static func rewrittenModelReference(
        _ value: String,
        providerIDs: [String: String]
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLegacyPrefix = trimmed.lowercased().hasPrefix(legacyRemoteAPIModelPrefix)
        let remainder = hasLegacyPrefix
            ? trimmed.dropFirst(legacyRemoteAPIModelPrefix.count)
            : Substring(trimmed)
        guard let separator = remainder.firstIndex(of: ":") else {
            return nil
        }
        let legacyProviderID = remainder[..<separator].lowercased()
        let modelID = remainder[remainder.index(after: separator)...]
        guard !modelID.isEmpty, let providerID = providerIDs[legacyProviderID] else {
            return nil
        }
        if !hasLegacyPrefix, providerID == legacyProviderID {
            // Already `<key>:<model>`.
            return nil
        }
        return AgentRemoteProvider.modelManifestID(providerID: providerID, modelID: String(modelID))
    }

    /// Rewrites the three former fixed provider UUIDs to their keys wherever a
    /// provider is referenced: provider ids (top level and embedded in
    /// models), model `providerID`, API-key map keys and
    /// `memoryEmbedding.providerID`.
    private static func replacingLegacyFixedProviderIDs(
        in settingsObject: [String: Any]
    ) -> (object: [String: Any], changed: Bool) {
        var changed = false
        func fixed(_ value: Any?) -> String? {
            guard let raw = value as? String,
                  let id = AgentRemoteProvider.normalizedProviderID(raw),
                  let key = legacyFixedProviderIDs[id] else {
                return nil
            }
            changed = true
            return key
        }
        func fixedProvider(_ value: Any) -> Any {
            guard var provider = value as? [String: Any] else { return value }
            if let key = fixed(provider["id"]) {
                provider["id"] = key
            }
            return provider
        }
        var object = settingsObject
        if let providers = object["providers"] as? [Any] {
            object["providers"] = providers.map(fixedProvider)
        }
        if let models = object["models"] as? [Any] {
            object["models"] = models.map { value -> Any in
                guard var model = value as? [String: Any] else { return value }
                if let key = fixed(model["providerID"]) {
                    model["providerID"] = key
                }
                if let provider = model["provider"] {
                    model["provider"] = fixedProvider(provider)
                }
                return model
            }
        }
        if let apiKeys = object["remoteAPIKeysByProviderID"] as? [String: Any] {
            var rewritten: [String: Any] = [:]
            for (key, value) in apiKeys {
                rewritten[fixed(key) ?? key] = value
            }
            object["remoteAPIKeysByProviderID"] = rewritten
        }
        if var memoryEmbedding = object["memoryEmbedding"] as? [String: Any],
           let key = fixed(memoryEmbedding["providerID"]) {
            memoryEmbedding["providerID"] = key
            object["memoryEmbedding"] = memoryEmbedding
        }
        return (object, changed)
    }

    private static func persistedProviderOrder(_ settingsObject: [String: Any]) -> [String: Int] {
        var order: [String: Int] = [:]
        func record(_ value: Any?) {
            guard let rawID = (value as? [String: Any])?["id"] as? String,
                  let id = AgentRemoteProvider.normalizedProviderID(rawID),
                  order[id] == nil else {
                return
            }
            order[id] = order.count
        }
        (settingsObject["providers"] as? [Any])?.forEach(record)
        (settingsObject["models"] as? [Any])?.forEach { record(($0 as? [String: Any])?["provider"]) }
        return order
    }

    private enum AgentsMigration {
        case migrated(Data)
        case unchanged
        case unreadable
    }

    private static let profileModelReferenceKeys = ["modelID", "defaultModelID", "defaultModelBindingID"]
    private static let bindingModelReferenceKeys = ["id", "modelID"]

    private static func migratedAgentsManifest(
        _ data: Data,
        providerIDs: [String: String]
    ) -> AgentsMigration {
        guard var manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unreadable
        }
        guard var agents = manifest["agents"] as? [Any] else {
            return .unchanged
        }
        var changed = false
        func rewrite(_ object: inout [String: Any], keys: [String]) {
            for key in keys {
                guard let value = object[key] as? String,
                      let rewritten = rewrittenModelReference(value, providerIDs: providerIDs) else {
                    continue
                }
                object[key] = rewritten
                changed = true
            }
        }
        for index in agents.indices {
            guard var agent = agents[index] as? [String: Any] else { continue }
            rewrite(&agent, keys: profileModelReferenceKeys)
            if var bindings = agent["modelBindings"] as? [Any] {
                for bindingIndex in bindings.indices {
                    guard var binding = bindings[bindingIndex] as? [String: Any] else { continue }
                    rewrite(&binding, keys: bindingModelReferenceKeys)
                    bindings[bindingIndex] = binding
                }
                agent["modelBindings"] = bindings
            }
            agents[index] = agent
        }
        guard changed else {
            return .unchanged
        }
        manifest["agents"] = agents
        guard let encoded = try? JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return .unreadable
        }
        return .migrated(encoded)
    }
}
