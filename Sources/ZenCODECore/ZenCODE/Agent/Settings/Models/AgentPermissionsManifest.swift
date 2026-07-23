//
//  AgentPermissionsManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation

public struct AgentPermissionsManifest: Codable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case version
        case localExecAllowedCommands
    }

    public static let currentVersion = 1
    public static let minimumSupportedVersion = 1

    public let version: Int
    public let localExecAllowedCommands: [String]

    public init(
        version: Int = Self.currentVersion,
        localExecAllowedCommands: [String] = []
    ) {
        self.version = version
        self.localExecAllowedCommands = Self.deduplicatedCommandIdentities(
            localExecAllowedCommands.flatMap {
                LocalExecPermissionAuthorizer
                    .persistedCommandPermissionIdentities(for: $0)
            }
        )
    }

    private init(
        version: Int,
        normalizedLocalExecAllowedCommandIdentities: [String]
    ) {
        self.version = version
        self.localExecAllowedCommands = Self.deduplicatedCommandIdentities(
            normalizedLocalExecAllowedCommandIdentities
        )
    }

    public func containsLocalExecAllowedCommand(_ commandIdentity: String) -> Bool {
        localExecAllowedCommands.contains {
            $0.caseInsensitiveCompare(commandIdentity) == .orderedSame
        }
    }

    public func appendingLocalExecAllowedCommand(
        _ commandIdentity: String
    ) -> AgentPermissionsManifest {
        appendingLocalExecAllowedCommandIdentities([commandIdentity])
    }

    func appendingLocalExecAllowedCommandIdentities(
        _ commandIdentities: [String]
    ) -> AgentPermissionsManifest {
        let updatedIdentities = Self.deduplicatedCommandIdentities(
            localExecAllowedCommands + commandIdentities
        )
        guard updatedIdentities != localExecAllowedCommands else {
            return self
        }
        return AgentPermissionsManifest(
            version: version,
            normalizedLocalExecAllowedCommandIdentities: updatedIdentities
        )
    }

    private static func deduplicatedCommandIdentities(_ identities: [String]) -> [String] {
        var seen = Set<String>()
        return identities.compactMap { identity in
            let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty,
                  !LocalExecCommandParser.isNonPersistableIdentity(normalized) else {
                return nil
            }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else {
                return nil
            }
            return normalized
        }
    }
}

public enum AgentPermissionsManifestStore {
    public static let permissionsFilename = "permissions.json"

    public static func load() -> AgentPermissionsManifest? {
        try? loadRequired()
    }

    public static func loadRequired() throws -> AgentPermissionsManifest {
        try loadRequired(from: permissionsURL())
    }

    public static func loadRequired(
        from url: URL
    ) throws -> AgentPermissionsManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentPermissionsManifestStoreError.missingFile(url)
        }

        let data: Data
        do {
            try SensitiveFilePermissions.hardenExistingFile(at: url)
            data = try Data(contentsOf: url)
        } catch {
            throw AgentPermissionsManifestStoreError.unreadableFile(url, error)
        }

        let manifest: AgentPermissionsManifest
        do {
            manifest = try JSONDecoder().decode(AgentPermissionsManifest.self, from: data)
        } catch {
            throw AgentPermissionsManifestStoreError.invalidFile(url, error)
        }

        guard manifest.version >= AgentPermissionsManifest.minimumSupportedVersion,
              manifest.version <= AgentPermissionsManifest.currentVersion else {
            throw AgentPermissionsManifestStoreError.unsupportedVersion(
                url,
                manifest.version,
                AgentPermissionsManifest.currentVersion
            )
        }
        return manifest
    }

    public static func save(
        _ manifest: AgentPermissionsManifest,
        to url: URL = permissionsURL()
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(manifest)
        try SensitiveFilePermissions.write(data, to: url)
    }

    public static func permissionsURL(fileManager: FileManager = .default) -> URL {
        AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(permissionsFilename)
            .standardizedFileURL
    }
}

public enum AgentPermissionsManifestStoreError: LocalizedError {
    case missingFile(URL)
    case unreadableFile(URL, Error)
    case invalidFile(URL, Error)
    case unsupportedVersion(URL, Int, Int)

    public var errorDescription: String? {
        switch self {
        case let .missingFile(url):
            return "Missing ZenCODE permissions file: \(url.path)"
        case let .unreadableFile(url, error):
            return "Unable to read ZenCODE permissions file \(url.path): \(error.localizedDescription)"
        case let .invalidFile(url, error):
            return "Invalid ZenCODE permissions file \(url.path): \(error.localizedDescription)"
        case let .unsupportedVersion(url, found, expected):
            return "Unsupported ZenCODE permissions file \(url.path): version \(found), expected \(expected)"
        }
    }
}
