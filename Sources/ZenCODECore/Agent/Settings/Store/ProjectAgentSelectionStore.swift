//
//  ProjectAgentSelectionStore.swift
//  ZenCODE
//
//  Per-project association between a workspace and the agent profiles the
//  `sub-agents` tool is allowed to delegate to.
//

import Foundation
import ToolCore

/// Persists, per workspace, which agent profiles are associated with the
/// project and therefore visible to the `sub-agents` tool.
///
/// The selection lives in the support directory, never in the working tree:
/// `<support>/projects/<sha256 of the standardized workspace path>/agents.json`.
/// The digest is the same one the workspace memory graph uses, so a project is
/// identified by its folder path alone.
///
/// Semantics:
/// - No saved file (or an unreadable one) means the project has not been
///   configured: only the system profiles (``AgentProfile/isSystemProfile``)
///   are visible to it.
/// - A saved file is literal. An empty selection means no profile is
///   delegatable, and profiles created after the file was saved are not added
///   to it implicitly.
/// - Profiles are stored by identifier (falling back to the name only when the
///   identifier is blank) so renaming a profile keeps its association.
public enum ProjectAgentSelectionStore {
    public static let currentVersion = 1
    public static let directoryName = "projects"
    public static let manifestFilename = "agents.json"

    /// On-disk representation of a project's selection.
    struct Manifest: Codable, Equatable, Sendable {
        var version: Int
        var workspacePath: String
        var agentIDs: [String]
    }

    // MARK: - Location

    /// Standardized path that identifies the project; also persisted in the
    /// manifest as a human-readable hint for the digest directory.
    public static func workspacePath(workspaceRootURL: URL) -> String {
        workspaceRootURL.standardizedFileURL.path
    }

    public static func manifestURL(
        workspaceRootURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(
                Data(workspacePath(workspaceRootURL: workspaceRootURL).utf8).sha256Hex(),
                isDirectory: true
            )
            .appendingPathComponent(manifestFilename, isDirectory: false)
            .standardizedFileURL
    }

    // MARK: - Persistence

    /// Returns the normalized profile keys saved for the project, or `nil`
    /// when the project has no saved selection. A missing, unreadable, or
    /// corrupt file is treated as "no selection saved", so the project sees
    /// the system profiles.
    public static func load(
        workspaceRootURL: URL,
        fileManager: FileManager = .default
    ) -> Set<String>? {
        let url = manifestURL(workspaceRootURL: workspaceRootURL, fileManager: fileManager)
        guard let data = fileManager.contents(atPath: url.path),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == currentVersion else {
            return nil
        }
        return Set(manifest.agentIDs.map(AgentProfileStore.profileReferenceKey).filter { !$0.isEmpty })
    }

    /// Saves the project's selection. Identifiers are de-duplicated by their
    /// normalized key and written in a stable order; blank identifiers are
    /// dropped. An empty collection is a valid, literal selection.
    public static func save<IDs: Sequence>(
        agentIDs: IDs,
        workspaceRootURL: URL,
        fileManager: FileManager = .default
    ) throws where IDs.Element == String {
        var identifiersByKey: [String: String] = [:]
        for agentID in agentIDs {
            guard let identifier = agentID.nilIfBlank else { continue }
            let key = AgentProfileStore.profileReferenceKey(identifier)
            guard !key.isEmpty, identifiersByKey[key] == nil else { continue }
            identifiersByKey[key] = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let manifest = Manifest(
            version: currentVersion,
            workspacePath: workspacePath(workspaceRootURL: workspaceRootURL),
            agentIDs: identifiersByKey.sorted { $0.key < $1.key }.map(\.value)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)

        let url = manifestURL(workspaceRootURL: workspaceRootURL, fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Profile identity

    /// The persisted identifier for a profile: its ID, or its name when the
    /// ID is blank (a manifest decoded without a usable identifier).
    public static func selectionIdentifier(for profile: AgentProfile) -> String {
        profile.id.nilIfBlank ?? profile.name
    }

    /// Case- and diacritic-insensitive key used to compare a profile with a
    /// saved selection, shared with every other profile reference lookup.
    public static func selectionKey(for profile: AgentProfile) -> String {
        AgentProfileStore.profileReferenceKey(selectionIdentifier(for: profile))
    }

    // MARK: - Filtering

    /// Pure filter: `nil` (no saved selection) returns only the system
    /// profiles; otherwise only the associated profiles, in their order.
    public static func filter(
        _ profiles: [AgentProfile],
        selection: Set<String>?
    ) -> [AgentProfile] {
        guard let selection else { return profiles.filter(\.isSystemProfile) }
        let keys = normalizedKeys(selection)
        return profiles.filter { keys.contains(selectionKey(for: $0)) }
    }

    public static func filter(
        _ profiles: [AgentProfile],
        workspaceRootURL: URL,
        fileManager: FileManager = .default
    ) -> [AgentProfile] {
        filter(
            profiles,
            selection: load(workspaceRootURL: workspaceRootURL, fileManager: fileManager)
        )
    }

    /// Whether `profile` is visible to the project: with no saved selection
    /// only a system profile is; otherwise exactly the saved profiles are.
    public static func isAssociated(
        _ profile: AgentProfile,
        selection: Set<String>?
    ) -> Bool {
        guard let selection else { return profile.isSystemProfile }
        return normalizedKeys(selection).contains(selectionKey(for: profile))
    }

    public static func isAssociated(
        _ profile: AgentProfile,
        workspaceRootURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        isAssociated(
            profile,
            selection: load(workspaceRootURL: workspaceRootURL, fileManager: fileManager)
        )
    }

    private static func normalizedKeys(_ selection: Set<String>) -> Set<String> {
        Set(selection.map(AgentProfileStore.profileReferenceKey))
    }
}
