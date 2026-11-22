//
//  SwiftFeatureSessionExposure.swift
//  ZenCODE
//
//  Session exposure of the Swift features a Builder sub-agent built.
//

import Foundation
import ToolCore

/// A feature exposed to a delegating session because one of its Builder
/// sub-agents built it successfully and it is loaded now.
public struct SwiftFeatureSessionExposure: Sendable, Equatable {
    public let featureID: String
    /// The feature's known tool names (declared, or the cached runtime
    /// discovery) that the feature owns, sorted, without kernel or core
    /// catalog names.
    public let toolNames: [String]
    /// The feature's tool name prefixes that the feature owns, sorted,
    /// without kernel or core catalog names.
    public let toolNamePrefixes: [String]

    public init(featureID: String, toolNames: [String], toolNamePrefixes: [String]) {
        self.featureID = featureID
        self.toolNames = toolNames
        self.toolNamePrefixes = toolNamePrefixes
    }
}

/// What a feature-management command did, for the Builder exposure registry.
enum SwiftFeatureBuilderOutcome: Sendable, Equatable {
    /// The command built the feature whose manifest is `manifestURL`, and
    /// the build produced `executableURL`.
    case built(featureID: String, manifestURL: URL, executableURL: URL)
    /// The command removed the feature.
    case deleted(featureID: String)
}

extension SwiftFeatureRuntime {
    // MARK: - Reads

    /// The IDs of the features exposed to `sessionID`: those with a loaded
    /// bundle that ``isExposed(_:sessionID:)`` accepts. Empty without a
    /// session ID.
    public func exposedFeatureIDs(sessionID: String?) -> Set<String> {
        Set(features.filter { isExposed($0, sessionID: sessionID) }.map(\.id))
    }

    /// Whether `feature`, a loaded bundle, is exposed to `sessionID`: its ID
    /// was built successfully by a Builder sub-agent that session delegated,
    /// and the bundle is a generated feature that runs the executable that
    /// build produced. Another loaded bundle with the same ID that runs a
    /// different executable is not exposed. The single decision of every
    /// place that lists, admits, publishes, or revokes an exposure.
    func isExposed(_ feature: SwiftFeatureBundle, sessionID: String?) -> Bool {
        guard let sessionID = sessionID?.nilIfBlank,
              let executablePath = builderBuiltExecutablePathsBySessionID[sessionID]?[feature.id] else {
            return false
        }
        return feature.source == .generated
            && feature.executableURL.standardizedFileURL.path == executablePath
    }

    /// The features exposed to `sessionID`, in load order, with the tool
    /// names and prefixes each one owns: a name another feature loaded
    /// earlier answers for is left out, as in
    /// ``descriptors(allowedToolNames:excludingFeatureIDs:sessionID:)``.
    public func exposures(sessionID: String?) -> [SwiftFeatureSessionExposure] {
        var seenFeatureIDs = Set<String>()
        return features.compactMap { feature in
            guard isExposed(feature, sessionID: sessionID),
                  seenFeatureIDs.insert(feature.id).inserted else {
                return nil
            }
            return SwiftFeatureSessionExposure(
                featureID: feature.id,
                toolNames: publishedNames(
                    knownTools(for: feature).map(\.name),
                    of: feature
                ),
                toolNamePrefixes: publishedNames(feature.toolNamePrefixes, of: feature)
            )
        }
    }

    /// `names` that an exposure of `feature` publishes, sorted and unique:
    /// exposable names that `feature` owns (``owns(_:toolName:)``).
    private func publishedNames(
        _ names: [String],
        of feature: SwiftFeatureBundle
    ) -> [String] {
        Array(Set(names.filter {
            Self.isExposableToolName($0) && owns(feature, toolName: $0)
        })).sorted()
    }

    /// The exposures of `sessionID` not announced yet, which are marked
    /// announced: a later call returns only exposures that became available
    /// since. A built feature that is not loaded yet is not returned, and is
    /// returned once it is loaded.
    public func takeUnannouncedExposures(sessionID: String?) -> [SwiftFeatureSessionExposure] {
        guard let sessionID = sessionID?.nilIfBlank else {
            return []
        }
        let announced = announcedExposedFeatureIDsBySessionID[sessionID] ?? []
        let unannounced = exposures(sessionID: sessionID).filter {
            !announced.contains($0.featureID)
        }
        guard !unannounced.isEmpty else {
            return []
        }
        announcedExposedFeatureIDsBySessionID[sessionID, default: []]
            .formUnion(unannounced.map(\.featureID))
        return unannounced
    }

    /// At most this many tool names and prefixes are announced per feature;
    /// the rest are counted.
    static let announcedEntryLimitPerFeature = 20

    /// The model-facing note announcing `exposures`, or `nil` when there is
    /// nothing to announce. Only feature IDs, names, and prefixes that match
    /// `^[A-Za-z0-9._-]{1,64}$` are listed: a feature whose ID does not is
    /// left out, and at most ``announcedEntryLimitPerFeature`` names and
    /// prefixes are listed per feature followed by `and N more`.
    public static func featureExposureAnnouncement(
        for exposures: [SwiftFeatureSessionExposure]
    ) -> String? {
        let exposures = exposures.filter { isAnnounceableName($0.featureID) }
        guard !exposures.isEmpty else {
            return nil
        }
        let entries = exposures.map { exposure in
            let parts = exposure.toolNames.filter(isAnnounceableName)
                + exposure.toolNamePrefixes
                    .filter(isAnnounceableName)
                    .map { "tools with prefix `\($0)`" }
            guard !parts.isEmpty else {
                return exposure.featureID
            }
            var listed = Array(parts.prefix(announcedEntryLimitPerFeature))
            if parts.count > announcedEntryLimitPerFeature {
                listed.append("and \(parts.count - announcedEntryLimitPerFeature) more")
            }
            return "\(exposure.featureID) (\(listed.joined(separator: ", ")))"
        }
        return "Feature tools now available in this session, built by your Builder sub-agent: "
            + entries.joined(separator: "; ")
            + ". Call them directly."
    }

    private static let announceableNameScalars = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-".unicodeScalars
    )

    /// Whether `name` matches `^[A-Za-z0-9._-]{1,64}$`, so it can be quoted in
    /// the announcement as is.
    static func isAnnounceableName(_ name: String) -> Bool {
        let scalars = name.unicodeScalars
        return (1...64).contains(scalars.count)
            && scalars.allSatisfy(announceableNameScalars.contains)
    }

    // MARK: - Revocation

    /// Revokes the exposures of `sessionID`: all of them, or only those of
    /// `featureIDs`. A revoked feature built again is exposed and announced
    /// again.
    public func revokeExposures(sessionID: String, featureIDs: Set<String>? = nil) {
        guard let featureIDs else {
            builderBuiltExecutablePathsBySessionID.removeValue(forKey: sessionID)
            announcedExposedFeatureIDsBySessionID.removeValue(forKey: sessionID)
            return
        }
        if var builtExecutablePaths = builderBuiltExecutablePathsBySessionID[sessionID] {
            for featureID in featureIDs {
                builtExecutablePaths.removeValue(forKey: featureID)
            }
            builderBuiltExecutablePathsBySessionID[sessionID] = builtExecutablePaths.isEmpty
                ? nil
                : builtExecutablePaths
        }
        if var announced = announcedExposedFeatureIDsBySessionID[sessionID] {
            announced.subtract(featureIDs)
            announcedExposedFeatureIDsBySessionID[sessionID] = announced.isEmpty ? nil : announced
        }
    }

    // MARK: - Registration

    /// Records `outcome` of a feature-management command.
    ///
    /// A successful build is registered for `delegatingSessionID`, the
    /// session that delegated the Builder sub-agent, only when all of these
    /// hold; otherwise nothing is registered:
    /// - there is a delegating session;
    /// - the feature ID is not a catalog ID (no bundled or optional feature,
    ///   nor a local copy of one that keeps its ID);
    /// - the built manifest is under the generated features root
    ///   (``featureRootURL()``), with the criterion of `feature.scaffold`;
    /// - the calling task is not cancelled.
    /// The registration keeps the standardized path of the executable the
    /// build produced, which ``isExposed(_:sessionID:)`` requires the loaded
    /// bundle to run. A deletion removes the feature from every
    /// session.
    ///
    /// The single registration seam of `executeManagementTool`.
    func recordBuilderOutcome(
        _ outcome: SwiftFeatureBuilderOutcome?,
        delegatingSessionID: String?
    ) {
        switch outcome {
        case let .built(featureID, manifestURL, executableURL)?:
            guard let sessionID = delegatingSessionID?.nilIfBlank,
                  let featureID = featureID.nilIfBlank,
                  Self.bundledFeatureDefinition(id: featureID) == nil,
                  Self.path(manifestURL, isDescendantOf: featureRootURL()),
                  !Task.isCancelled else {
                return
            }
            registerBuilderExposure(
                featureID: featureID,
                executableURL: executableURL,
                sessionID: sessionID
            )
        case let .deleted(featureID)?:
            revokeExposuresInEverySession(featureIDs: [featureID])
        case nil:
            return
        }
    }

    /// Revokes the exposures of `featureIDs` in every session.
    private func revokeExposuresInEverySession(featureIDs: Set<String>) {
        let sessionIDs = Set(builderBuiltExecutablePathsBySessionID.keys)
            .union(announcedExposedFeatureIDsBySessionID.keys)
        for sessionID in sessionIDs {
            revokeExposures(sessionID: sessionID, featureIDs: featureIDs)
        }
    }

    /// Revokes, from each session, the exposure of each registered feature
    /// whose bundle exposed to that session (``isExposed(_:sessionID:)``) no
    /// longer passes the delegated namespace check, with its known tools,
    /// aliases, declared prefixes, and the prefixes derived from its tool
    /// names: an exposure does not survive a routing changed after the build.
    /// A feature without such a bundle (not loaded, or loaded with another
    /// executable) is left registered and checked once it has one. A revoked
    /// feature is exposed again only by a new delegated build that passes the
    /// check. Called by ``reloadFeatureBundles()`` after every reload.
    func revokeExposuresOutsideTheirNamespace() {
        for sessionID in Array(builderBuiltExecutablePathsBySessionID.keys) {
            let refusedFeatureIDs = Set(features.filter { feature in
                isExposed(feature, sessionID: sessionID)
                    && delegatedNamespaceRefusal(
                        featureID: feature.id,
                        action: "exposed",
                        toolNames: knownTools(for: feature).map(\.name),
                        toolNameAliases: feature.toolNameAliases,
                        toolNamePrefixes: feature.toolNamePrefixes
                    ) != nil
            }.map(\.id))
            guard !refusedFeatureIDs.isEmpty else {
                continue
            }
            revokeExposures(sessionID: sessionID, featureIDs: refusedFeatureIDs)
        }
    }

    /// Stores the exposure of `featureID`, built into `executableURL`, for
    /// `sessionID`, with no check: ``recordBuilderOutcome(_:delegatingSessionID:)``
    /// decides whether a build is registered.
    func registerBuilderExposure(
        featureID: String,
        executableURL: URL,
        sessionID: String
    ) {
        builderBuiltExecutablePathsBySessionID[sessionID, default: [:]][featureID] =
            executableURL.standardizedFileURL.path
    }

    static func builderOutcome(
        build report: SwiftFeatureBuildReport,
        manifestURL: URL
    ) -> SwiftFeatureBuilderOutcome? {
        guard report.ok else {
            return nil
        }
        return .built(
            featureID: report.id,
            manifestURL: manifestURL,
            executableURL: URL(fileURLWithPath: report.executablePath)
        )
    }

    static func builderOutcome(scaffold report: SwiftFeatureScaffoldReport) -> SwiftFeatureBuilderOutcome? {
        guard report.built == true, let build = report.build, build.ok else {
            return nil
        }
        return .built(
            featureID: report.id,
            manifestURL: URL(fileURLWithPath: report.manifestPath),
            executableURL: URL(fileURLWithPath: build.executablePath)
        )
    }

    static func builderOutcome(install report: SwiftFeatureInstallReport) -> SwiftFeatureBuilderOutcome? {
        guard report.ok, report.built, let build = report.build, build.ok else {
            return nil
        }
        return .built(
            featureID: report.id,
            manifestURL: URL(fileURLWithPath: report.manifestPath),
            executableURL: URL(fileURLWithPath: build.executablePath)
        )
    }

    static func builderOutcome(delete report: SwiftFeatureDeleteReport) -> SwiftFeatureBuilderOutcome? {
        report.removed ? .deleted(featureID: report.id) : nil
    }

    // MARK: - Name policy

    /// Core catalog names (kernel feature management included), which an
    /// exposure never grants.
    static let exposureReservedToolNames: Set<String> = Set(
        DirectToolCatalog.baseDescriptors.map(\.name)
    )

    /// ``exposureReservedToolNames``, sorted, so a refusal names the same
    /// core tool every time.
    private static let sortedExposureReservedToolNames = exposureReservedToolNames.sorted()

    /// The namespaces of the core catalog tools: each name of
    /// ``exposureReservedToolNames`` up to and including its first dot (the
    /// name followed by `.` when it has none), sorted. The single source of
    /// the delegated namespace check and of the list in the delegated
    /// Builder's prompt (`DirectSubAgentRuntime.coreToolNamespaceList`).
    static let coreToolNamespaces: [String] = Set(
        exposureReservedToolNames.map { toolName in
            toolName.firstIndex(of: ".").map { String(toolName[...$0]) } ?? "\(toolName)."
        }
    ).sorted()

    /// Whether an exposure may publish or grant `entry`, a tool name or an
    /// allowlist entry: never a kernel feature-management name or the
    /// reserved `feature.` namespace, and never an entry that the allowlist
    /// matching (exact name, or an entry ending in `.` as a prefix) would
    /// resolve to a core catalog tool.
    static func isExposableToolName(_ entry: String) -> Bool {
        !entry.isEmpty && coreCatalogOverlap(of: entry) == nil
    }

    /// How `entry` overlaps the core catalog, for a refusal, or `nil` when it
    /// does not: the allowlist matching would resolve it to a core catalog
    /// tool, or it is a kernel feature-management name or in the reserved
    /// `feature.` namespace. The rule of ``isExposableToolName(_:)``.
    private static func coreCatalogOverlap(of entry: String) -> String? {
        if let coreToolName = sortedExposureReservedToolNames.first(where: {
            DirectToolExecutor.isAllowed($0, allowedToolNames: [entry])
        }) {
            return "overlaps the core tool '\(coreToolName)'"
        }
        if entry.hasPrefix("feature.") || isFeatureManagementToolName(entry) {
            return "overlaps the 'feature.' namespace of kernel feature management"
        }
        return nil
    }

    // MARK: - Delegated namespace

    /// One name a feature routes, as the delegated namespace check sees it.
    private struct DelegatedNamespaceEntry {
        let value: String
        /// How the entry is named in a refusal.
        let label: String
        /// Whether the entry routes every name it prefixes.
        let isPrefix: Bool
    }

    /// Refuses a feature that a delegated Builder builds, scaffolds, or
    /// installs when one of its tool names, aliases, or declared tool name
    /// prefixes, or the prefix derived from one of its tool names
    /// (``toolNamePrefix(from:)``), takes a namespace it does not own:
    /// - the core catalog: the entry is not exposable
    ///   (``isExposableToolName(_:)``), starts with the namespace of a core
    ///   tool (``coreToolNamespaces``: `local.read.pdf`, `skills.list.x`),
    ///   or, as a prefix, covers a core tool name;
    /// - a name of another loaded feature (one with a different ID): the entry
    ///   is one of its tools or aliases, falls under one of its prefixes, or,
    ///   as a prefix, covers one of its tools, aliases, or prefixes, or
    ///   extends one of its tools or aliases (`foo.bar.` against the tool
    ///   `foo.bar`).
    /// Called only for a delegated Builder, before anything is written or
    /// built; every other caller keeps the general validation alone.
    func ensureDelegatedFeatureNamespace(
        featureID: String,
        toolNames: [String],
        toolNameAliases: [String],
        toolNamePrefixes: [String]
    ) throws {
        if let refusal = delegatedNamespaceRefusal(
            featureID: featureID,
            action: "built",
            toolNames: toolNames,
            toolNameAliases: toolNameAliases,
            toolNamePrefixes: toolNamePrefixes
        ) {
            throw DirectToolError.permissionDenied(refusal)
        }
    }

    /// Refuses a delegated Builder's `feature.enable` of `featureID` when the
    /// manifest that `setFeature(id:enabled:)` would enable fails the check
    /// of ``ensureDelegatedFeatureNamespace(featureID:toolNames:toolNameAliases:toolNamePrefixes:)``
    /// with its tool names, aliases, and prefixes. Without such a manifest (a
    /// catalog feature that is not installed, an unknown ID, an explicitly
    /// constructed runtime) there is nothing to check, and the enable reports
    /// as it always did.
    func ensureDelegatedFeatureNamespace(enabling featureID: String) throws {
        guard explicitFeatures == nil,
              let record = SwiftFeatureRegistry
                  .discoverFeatureRecords(searchRoots: featureSearchRoots, fileManager: fileManager)
                  .first(where: { $0.id == featureID }) else {
            return
        }
        if let refusal = delegatedNamespaceRefusal(
            featureID: record.id,
            action: "enabled",
            toolNames: record.tools.map(\.name),
            toolNameAliases: record.toolNameAliases,
            toolNamePrefixes: record.toolNamePrefixes
        ) {
            throw DirectToolError.permissionDenied(refusal)
        }
    }

    /// The refusal of the delegated namespace check, or `nil` when the
    /// feature passes it; `action` names what the refused call does.
    private func delegatedNamespaceRefusal(
        featureID: String,
        action: String,
        toolNames: [String],
        toolNameAliases: [String],
        toolNamePrefixes: [String]
    ) -> String? {
        let entries = toolNames.map {
            DelegatedNamespaceEntry(value: $0, label: "its tool '\($0)'", isPrefix: false)
        } + toolNameAliases.map {
            DelegatedNamespaceEntry(value: $0, label: "its alias '\($0)'", isPrefix: false)
        } + toolNamePrefixes.map {
            DelegatedNamespaceEntry(value: $0, label: "its tool prefix '\($0)'", isPrefix: true)
        } + toolNames.map { toolName in
            let prefix = Self.toolNamePrefix(from: toolName)
            return DelegatedNamespaceEntry(
                value: prefix,
                label: "the namespace '\(prefix)' of its tool '\(toolName)'",
                isPrefix: true
            )
        }
        let refusal = "Feature '\(featureID)' cannot be \(action) by a delegated Builder"
        let remedy = "Give the feature a namespace of its own."
        for entry in entries {
            if let coreOwner = Self.coreNamespaceOwner(of: entry) {
                return "\(refusal): \(entry.label) \(coreOwner). \(remedy)"
            }
            for feature in features where feature.id != featureID {
                if let collision = namespaceCollision(of: entry, with: feature) {
                    return "\(refusal): \(entry.label) \(collision) of the loaded feature '\(feature.id)'. \(remedy)"
                }
            }
        }
        return nil
    }

    /// How `entry` collides with the core catalog, for a refusal, or `nil`
    /// when it does not: it is not exposable (``isExposableToolName(_:)``),
    /// it starts with a core namespace (``coreToolNamespaces``), which a
    /// session allowing a core tool would find relevant
    /// (`SwiftFeatureBundle.isRelevant(allowedToolNames:)`), or, as a
    /// prefix, it covers a core tool name (a declared prefix that does not
    /// end in `.` routes every name it starts).
    private static func coreNamespaceOwner(of entry: DelegatedNamespaceEntry) -> String? {
        guard isExposableToolName(entry.value) else {
            return coreCatalogOverlap(of: entry.value) ?? "overlaps the core tools"
        }
        if let namespace = coreToolNamespaces.first(where: { entry.value.hasPrefix($0) }) {
            return "falls in the namespace '\(namespace)' of the core tools"
        }
        if entry.isPrefix,
           let coreToolName = sortedExposureReservedToolNames.first(where: { $0.hasPrefix(entry.value) }) {
            return "covers the core tool '\(coreToolName)'"
        }
        return nil
    }

    /// How `entry` collides with `feature`, or `nil` when it does not. A
    /// prefix that extends one of its tools or aliases (`foo.bar.` against
    /// `foo.bar`) collides because a session allowing that name would find
    /// the prefix relevant (`SwiftFeatureBundle.isRelevant(allowedToolNames:)`).
    private func namespaceCollision(
        of entry: DelegatedNamespaceEntry,
        with feature: SwiftFeatureBundle
    ) -> String? {
        let names = knownTools(for: feature).map { ("tool", $0.name) }
            + feature.toolNameAliases.map { ("alias", $0) }
        if let (kind, name) = names.first(where: { $0.1 == entry.value }) {
            return "is also the \(kind) '\(name)'"
        }
        if let prefix = feature.toolNamePrefixes.first(where: { entry.value.hasPrefix($0) }) {
            return "falls under the tool prefix '\(prefix)'"
        }
        guard entry.isPrefix else {
            return nil
        }
        if let (kind, name) = (names + feature.toolNamePrefixes.map { ("tool prefix", $0) })
            .first(where: { $0.1.hasPrefix(entry.value) }) {
            return "covers the \(kind) '\(name)'"
        }
        if let (kind, name) = names.first(where: { !$0.1.isEmpty && entry.value.hasPrefix($0.1) }) {
            return "extends the \(kind) '\(name)'"
        }
        return nil
    }
}
