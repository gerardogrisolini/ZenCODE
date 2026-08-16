//
//  AgentDelegationCatalog.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

/// One authoritative snapshot of the model catalog used by a delegation batch.
///
/// `available` is authoritative even when its manifest contains no models.
/// `unavailable` is fail-closed: bindings cannot be advertised or routed when
/// settings are missing or invalid.
public enum AgentDelegationCatalogSnapshot: Sendable {
    case available(AgentSettingsManifest)
    /// Explicit dependency-injection form for catalog-only resolution. It is
    /// used by setup reconciliation and deterministic tests, where credentials
    /// are intentionally outside the question being answered.
    case catalogOnly(AgentSettingsManifest)
    case unavailable(String)

    public static func available(
        models: [AgentSettingsModelManifest]
    ) -> AgentDelegationCatalogSnapshot {
        .catalogOnly(AgentSettingsManifest(models: models))
    }

    public var models: [AgentSettingsModelManifest] {
        switch self {
        case let .available(manifest), let .catalogOnly(manifest):
            return manifest.models
        case .unavailable:
            return []
        }
    }

    public var isAvailable: Bool {
        switch self {
        case .available, .catalogOnly:
            return true
        case .unavailable:
            return false
        }
    }

    public var unavailableReason: String? {
        if case let .unavailable(reason) = self {
            return reason
        }
        return nil
    }

    /// Builds the provider selection from this exact snapshot. No later global
    /// model lookup is needed, which keeps the provider identity stable between
    /// validation, task claim and backend creation.
    public func modelSelection(
        for binding: ResolvedAgentModelBinding
    ) -> AgentModelSelection? {
        guard let manifest,
              routingIssue(for: binding) == nil,
              let provider = binding.model.provider,
              let rawModelID = binding.model.modelID.nilIfBlank else {
            return nil
        }
        let model = binding.model

        let resolvedProvider = AgentRemoteProvider(
            id: provider.id,
            name: provider.name,
            baseURL: provider.baseURL,
            modelID: rawModelID,
            chatEndpoint: provider.chatEndpoint,
            providerProfileID: provider.providerProfileID,
            protocolProfileID: provider.protocolProfileID,
            authPolicy: provider.authPolicy
        )
        let apiKey = provider.authPolicy.effectiveAPIKey(
            manifest.remoteAPIKeysByProviderID[
                provider.id.uuidString.lowercased()
            ]
        )
        let configuredContextWindowLimit = resolvedProvider.isChatGPTSubscriptionProvider
            ? CodexAgentModel.contextWindowTokenLimit(forLLMID: model.id)
            : model.configuredContextWindowLimit

        return AgentModelSelection(
            providerKind: model.kind,
            modelID: rawModelID,
            remoteProvider: resolvedProvider,
            apiKey: apiKey,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: model.generationParameterOverrides,
            thinkingSelection: model.thinkingSelection(for: binding.thinkingSelection)
        )
    }

    fileprivate var manifest: AgentSettingsManifest? {
        switch self {
        case let .available(manifest), let .catalogOnly(manifest):
            return manifest
        case .unavailable:
            return nil
        }
    }

    fileprivate func routingIssue(
        for binding: ResolvedAgentModelBinding
    ) -> String? {
        guard let manifest,
              let provider = binding.model.provider else {
            return "the resolved provider configuration is incomplete"
        }
        guard case .available = self else {
            return nil
        }

        let apiKey = provider.authPolicy.effectiveAPIKey(
            manifest.remoteAPIKeysByProviderID[
                provider.id.uuidString.lowercased()
            ]
        )
        if provider.requiresAPIKey, apiKey == nil {
            return "the configured provider has no API key"
        }
        if provider.isChatGPTSubscriptionProvider,
           !Self.hasUsableChatGPTCredentials(
               manifest.chatGPTSubscriptionCredentials
           ) {
            return "the ChatGPT subscription is not authenticated"
        }
        if provider.isAnthropicSubscriptionProvider,
           !Self.hasUsableAnthropicCredentials(
               manifest.anthropicSubscriptionCredentials
           ) {
            return "the Anthropic subscription is not authenticated"
        }
        return nil
    }

    static func hasUsableChatGPTCredentials(
        _ credentials: CodexAgentCredentials?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let accessToken = environment["CHATGPT_ACCESS_TOKEN"]?.nilIfBlank {
            return environment["CHATGPT_ACCOUNT_ID"]?.nilIfBlank != nil
                || (try? CodexAgentModel.chatGPTAccountID(from: accessToken)) != nil
        }
        guard let credentials else { return false }
        return credentials.accessToken.nilIfBlank != nil
            && credentials.refreshToken.nilIfBlank != nil
            && credentials.accountID.nilIfBlank != nil
    }

    static func hasUsableAnthropicCredentials(
        _ credentials: AnthropicSubscriptionCredentials?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["ANTHROPIC_OAUTH_TOKEN"]?.nilIfBlank != nil
            || environment["ANTHROPIC_ACCESS_TOKEN"]?.nilIfBlank != nil {
            return true
        }
        guard let credentials else { return false }
        return credentials.accessToken.nilIfBlank != nil
            && credentials.refreshToken.nilIfBlank != nil
    }
}

/// A profile model binding intersected with one configured model.
public struct ResolvedAgentModelBinding: Sendable, Hashable {
    public let binding: AgentModelBinding
    public let model: AgentSettingsModelManifest

    public init(
        binding: AgentModelBinding,
        model: AgentSettingsModelManifest
    ) {
        self.binding = binding
        self.model = model
    }

    public var bindingID: String {
        binding.id
    }

    /// The only reference advertised to the model. A dedicated namespace keeps
    /// a binding id from colliding with another binding's model id.
    public var selectionReference: String {
        "binding:\(bindingID)"
    }

    /// Canonical provider-qualified identity retained until backend creation.
    public var canonicalModelID: String {
        model.id
    }

    /// Raw provider model name, used only after the provider is already fixed by
    /// the resolved snapshot.
    public var providerModelID: String {
        model.modelID
    }

    public var providerID: UUID? {
        model.provider?.id ?? model.providerID
    }

    public var providerTitle: String? {
        AgentModelCatalogPresentation.providerGroupTitle(for: model).nilIfBlank
            ?? binding.modelProvider?.nilIfBlank
    }

    public var modelTitle: String {
        AgentModelCatalogPresentation.modelTitle(for: model)
    }

    public var capability: Int? {
        binding.capability
    }

    public var thinkingSelection: AgentThinkingSelection? {
        model.thinkingSelection(for: binding.thinkingSelection)
    }

    public var routingBinding: AgentModelBinding {
        AgentModelBinding(
            id: binding.id,
            modelID: canonicalModelID,
            modelProvider: providerTitle ?? binding.modelProvider,
            thinkingSelection: thinkingSelection,
            capability: binding.capability
        )
    }
}

/// A profile binding that cannot be routed against the authoritative snapshot.
public struct UnresolvedAgentModelBinding: Sendable, Hashable {
    public enum Reason: Error, Sendable, Hashable {
        case catalogUnavailable(String)
        case modelNotConfigured
        case ambiguousModelReference([String])
        case duplicateCanonicalModel(String, bindingIDs: [String])
        case providerAuthenticationUnavailable(String)
    }

    public let binding: AgentModelBinding
    public let reason: Reason

    public init(binding: AgentModelBinding, reason: Reason) {
        self.binding = binding
        self.reason = reason
    }

    public var diagnostic: String {
        switch reason {
        case let .catalogUnavailable(reason):
            return "the configured model catalog is unavailable: \(reason)"
        case .modelNotConfigured:
            let provider = binding.modelProvider?.nilIfBlank.map { " (provider \($0))" } ?? ""
            return "model '\(binding.modelID)'\(provider) is no longer configured in the model catalog"
        case let .ambiguousModelReference(candidates):
            return "model reference '\(binding.modelID)' matches several configured models "
                + "(\(candidates.joined(separator: ", "))) and does not identify one provider"
        case let .duplicateCanonicalModel(modelID, bindingIDs):
            return "several bindings (\(bindingIDs.joined(separator: ", "))) resolve to canonical "
                + "model '\(modelID)'"
        case let .providerAuthenticationUnavailable(reason):
            return reason
        }
    }
}

public enum AgentDelegationBindingSelection: Sendable {
    case unconstrained
    case selected(ResolvedAgentModelBinding)
    case unavailable(UnresolvedAgentModelBinding)
    case notAuthorized
    case ambiguous([String])
}

/// A profile with all uniquely resolved bindings and the subset eligible for
/// model-driven delegation.
public struct ResolvedAgentProfileBindings: Sendable {
    public let profile: AgentProfile
    public let bindings: [ResolvedAgentModelBinding]
    public let staleBindings: [UnresolvedAgentModelBinding]
    public let isCatalogAvailable: Bool

    public init(
        profile: AgentProfile,
        bindings: [ResolvedAgentModelBinding],
        staleBindings: [UnresolvedAgentModelBinding],
        isCatalogAvailable: Bool
    ) {
        self.profile = profile
        self.bindings = bindings
        self.staleBindings = staleBindings
        self.isCatalogAvailable = isCatalogAvailable
    }

    public var hasDeclaredBindings: Bool {
        !profile.modelBindings.isEmpty
    }

    /// Prompt and runtime consume this exact list. Bindings without a capability
    /// remain valid for direct profile use but are not eligible for delegation.
    public var delegatableBindings: [ResolvedAgentModelBinding] {
        bindings.filter { $0.capability != nil }
    }

    public func isDefault(_ binding: ResolvedAgentModelBinding) -> Bool {
        guard let defaultModelBindingID = profile.defaultModelBindingID else {
            return false
        }
        return AgentDelegationCatalog.lookupKey(binding.bindingID)
            == AgentDelegationCatalog.lookupKey(defaultModelBindingID)
    }

    /// Resolves the explicit model reference accepted by `agent.create`.
    ///
    /// The model-visible `binding:<id>` namespace is deterministic. Unprefixed
    /// references remain accepted for wire compatibility, but every namespace is
    /// considered together and collisions are rejected rather than selecting the
    /// first match.
    public func selection(for reference: String?) -> AgentDelegationBindingSelection {
        guard hasDeclaredBindings else {
            return .unconstrained
        }
        guard let reference = reference?.nilIfBlank else {
            return .notAuthorized
        }

        let bindingPrefix = "binding:"
        let normalizedReference = AgentDelegationCatalog.lookupKey(reference)
        if normalizedReference.hasPrefix(bindingPrefix) {
            let bindingKey = String(normalizedReference.dropFirst(bindingPrefix.count))
            let liveMatches = delegatableBindings.filter {
                AgentDelegationCatalog.lookupKey($0.bindingID) == bindingKey
            }
            let staleMatches = staleBindings.filter {
                AgentDelegationCatalog.lookupKey($0.binding.id) == bindingKey
            }
            return resolvedSelection(
                liveMatches: liveMatches,
                staleMatches: staleMatches
            )
        }

        let liveMatches = delegatableBindings.filter { binding in
            let keys = [
                binding.bindingID,
                binding.binding.modelID,
                binding.canonicalModelID,
                binding.providerModelID,
            ].map(AgentDelegationCatalog.lookupKey)
            return keys.contains(normalizedReference)
        }
        let staleMatches = staleBindings.filter { stale in
            [stale.binding.id, stale.binding.modelID]
                .map(AgentDelegationCatalog.lookupKey)
                .contains(normalizedReference)
        }
        return resolvedSelection(
            liveMatches: liveMatches,
            staleMatches: staleMatches
        )
    }

    private func resolvedSelection(
        liveMatches: [ResolvedAgentModelBinding],
        staleMatches: [UnresolvedAgentModelBinding]
    ) -> AgentDelegationBindingSelection {
        let uniqueLive = Dictionary(
            grouping: liveMatches,
            by: { AgentDelegationCatalog.lookupKey($0.bindingID) }
        ).values.compactMap(\.first)

        if uniqueLive.count == 1, staleMatches.isEmpty, let binding = uniqueLive.first {
            return .selected(binding)
        }
        if uniqueLive.isEmpty, staleMatches.count == 1, let stale = staleMatches.first {
            return .unavailable(stale)
        }
        let candidates = Set(
            uniqueLive.map(\.selectionReference)
                + staleMatches.map { "binding:\($0.binding.id)" }
        ).sorted()
        if candidates.count > 1 || (!uniqueLive.isEmpty && !staleMatches.isEmpty) {
            return .ambiguous(candidates)
        }
        return .notAuthorized
    }
}

public struct AgentDelegationLiveConfiguration: Sendable {
    public let profiles: [AgentProfile]
    public let catalog: AgentDelegationCatalogSnapshot

    public init(
        profiles: [AgentProfile],
        catalog: AgentDelegationCatalogSnapshot
    ) {
        self.profiles = profiles
        self.catalog = catalog
    }
}

/// The single provider-safe view shared by prompt, parser/runtime and setup.
public enum AgentDelegationCatalog {
    private static let identifierLocale = Locale(identifier: "en_US_POSIX")

    public static func liveSnapshot(
        fileManager: FileManager = .default
    ) -> AgentDelegationCatalogSnapshot {
        let url = AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else {
            return .unavailable("settings.json is not configured")
        }
        do {
            return .available(try AgentSettingsManifestStore.loadRequired(from: url))
        } catch {
            return .unavailable("settings.json could not be loaded: \(error.localizedDescription)")
        }
    }

    public static func liveConfiguration(
        fileManager: FileManager = .default
    ) -> AgentDelegationLiveConfiguration {
        do {
            return try SensitiveManifestCoordination.withExclusiveLock(
                fileManager: fileManager
            ) {
                let profiles = try AgentProfileStore.loadRequired(
                    fileManager: fileManager
                )
                return AgentDelegationLiveConfiguration(
                    profiles: profiles,
                    catalog: liveSnapshotUnlocked(fileManager: fileManager)
                )
            }
        } catch {
            return AgentDelegationLiveConfiguration(
                profiles: [],
                catalog: .unavailable(
                    "delegation manifests could not be loaded: \(error.localizedDescription)"
                )
            )
        }
    }

    static func liveSnapshotUnlocked(
        fileManager: FileManager
    ) -> AgentDelegationCatalogSnapshot {
        let url = AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else {
            return .unavailable("settings.json is not configured")
        }
        do {
            return .available(
                try AgentSettingsManifestStore.loadRequiredUnlocked(from: url)
            )
        } catch {
            return .unavailable(
                "settings.json could not be loaded: \(error.localizedDescription)"
            )
        }
    }

    /// Compatibility accessor for non-routing UI code. Routing must consume the
    /// full snapshot so an empty catalog is not confused with an unavailable one.
    public static func liveModels() -> [AgentSettingsModelManifest] {
        liveSnapshot().models
    }

    public static func roster(
        agents: [AgentProfile],
        snapshot: AgentDelegationCatalogSnapshot
    ) -> [ResolvedAgentProfileBindings] {
        AgentProfileStore.unambiguousAgents(in: agents).map {
            resolvedBindings(for: $0, snapshot: snapshot)
        }
    }

    public static func roster(
        agents: [AgentProfile],
        models: [AgentSettingsModelManifest]
    ) -> [ResolvedAgentProfileBindings] {
        roster(agents: agents, snapshot: .available(models: models))
    }

    public static func resolvedBindings(
        for profile: AgentProfile,
        models: [AgentSettingsModelManifest]
    ) -> ResolvedAgentProfileBindings {
        resolvedBindings(for: profile, snapshot: .available(models: models))
    }

    public static func resolvedBindings(
        for profile: AgentProfile,
        snapshot: AgentDelegationCatalogSnapshot
    ) -> ResolvedAgentProfileBindings {
        guard let manifest = snapshot.manifest else {
            let reason = snapshot.unavailableReason ?? "unknown catalog error"
            return ResolvedAgentProfileBindings(
                profile: profile,
                bindings: [],
                staleBindings: profile.modelBindings.map {
                    UnresolvedAgentModelBinding(
                        binding: $0,
                        reason: .catalogUnavailable(reason)
                    )
                },
                isCatalogAvailable: false
            )
        }

        var resolved: [ResolvedAgentModelBinding] = []
        var stale: [UnresolvedAgentModelBinding] = []
        for binding in profile.modelBindings {
            switch catalogModel(for: binding, in: manifest.models) {
            case let .success(model):
                let resolvedBinding = ResolvedAgentModelBinding(binding: binding, model: model)
                if let issue = snapshot.routingIssue(for: resolvedBinding) {
                    stale.append(
                        UnresolvedAgentModelBinding(
                            binding: binding,
                            reason: .providerAuthenticationUnavailable(issue)
                        )
                    )
                } else {
                    resolved.append(resolvedBinding)
                }
            case let .failure(reason):
                stale.append(UnresolvedAgentModelBinding(binding: binding, reason: reason))
            }
        }

        let duplicateGroups = Dictionary(
            grouping: resolved,
            by: { lookupKey($0.canonicalModelID) }
        ).values.filter { $0.count > 1 }
        let duplicateBindingKeys = Set(
            duplicateGroups.flatMap { $0.map { lookupKey($0.bindingID) } }
        )
        for group in duplicateGroups {
            let canonicalModelID = group[0].canonicalModelID
            let bindingIDs = group.map(\.bindingID).sorted()
            stale.append(contentsOf: group.map {
                UnresolvedAgentModelBinding(
                    binding: $0.binding,
                    reason: .duplicateCanonicalModel(
                        canonicalModelID,
                        bindingIDs: bindingIDs
                    )
                )
            })
        }
        resolved.removeAll { duplicateBindingKeys.contains(lookupKey($0.bindingID)) }

        return ResolvedAgentProfileBindings(
            profile: profile,
            bindings: sorted(resolved),
            staleBindings: stale.sorted {
                lookupKey($0.binding.id) < lookupKey($1.binding.id)
            },
            isCatalogAvailable: true
        )
    }

    /// Resolves all identifier namespaces as a set. No namespace is allowed to
    /// choose the first catalog entry when another entry carries the same key.
    public static func catalogModel(
        for binding: AgentModelBinding,
        in models: [AgentSettingsModelManifest]
    ) -> Result<AgentSettingsModelManifest, UnresolvedAgentModelBinding.Reason> {
        let key = lookupKey(binding.modelID)
        guard !key.isEmpty else {
            return .failure(.modelNotConfigured)
        }

        var candidatesByID: [String: AgentSettingsModelManifest] = [:]
        for model in models {
            let referenceKeys = [model.id, model.llmID ?? "", model.modelID]
                .map(lookupKey)
            if referenceKeys.contains(key) {
                candidatesByID[lookupKey(model.id)] = model
            }
        }
        var candidates = Array(candidatesByID.values)
        guard !candidates.isEmpty else {
            return .failure(.modelNotConfigured)
        }
        if candidates.count == 1, let model = candidates.first {
            return .success(model)
        }

        if let providerHint = binding.modelProvider?.nilIfBlank {
            let hintKey = lookupKey(providerHint)
            candidates = candidates.filter { model in
                lookupKey(AgentModelCatalogPresentation.providerGroupTitle(for: model)) == hintKey
                    || lookupKey(model.provider?.displayTitle ?? "") == hintKey
                    || lookupKey(model.provider?.id.uuidString ?? "") == hintKey
                    || lookupKey(model.providerID?.uuidString ?? "") == hintKey
            }
            if candidates.count == 1, let model = candidates.first {
                return .success(model)
            }
        }

        return .failure(.ambiguousModelReference(candidates.map(\.id).sorted()))
    }

    public static func canonicalModelID(
        forReference reference: String?,
        providerHint: String? = nil,
        models: [AgentSettingsModelManifest]
    ) -> String? {
        guard let reference = reference?.nilIfBlank else {
            return nil
        }
        let probe = AgentModelBinding(
            id: reference,
            modelID: reference,
            modelProvider: providerHint
        )
        switch catalogModel(for: probe, in: models) {
        case let .success(model):
            return model.id.nilIfBlank
        case .failure:
            return nil
        }
    }

    static func lookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: identifierLocale
            )
            .lowercased(with: identifierLocale)
    }

    private static func sorted(
        _ bindings: [ResolvedAgentModelBinding]
    ) -> [ResolvedAgentModelBinding] {
        bindings.sorted { lhs, rhs in
            let lhsCapability = lhs.capability ?? Int.max
            let rhsCapability = rhs.capability ?? Int.max
            if lhsCapability != rhsCapability {
                return lhsCapability < rhsCapability
            }
            let lhsModel = lookupKey(lhs.canonicalModelID)
            let rhsModel = lookupKey(rhs.canonicalModelID)
            if lhsModel != rhsModel {
                return lhsModel < rhsModel
            }
            return lookupKey(lhs.bindingID) < lookupKey(rhs.bindingID)
        }
    }
}
