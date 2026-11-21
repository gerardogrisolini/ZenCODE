//
//  AgentPermissionsManifestTestSupport.swift
//  ZenCODE
//
//  Fixture the tests use to seed a permissions manifest: production only
//  writes it through `AgentPermissionsManifestStore.appendingLocalExecAllowedCommandIdentities(_:to:)`.
//

import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime

extension AgentPermissionsManifestStore {
    /// Writes `manifest` to `url` as it is, under the same lock and with the
    /// same file permissions production uses.
    static func save(
        _ manifest: AgentPermissionsManifest,
        to url: URL = permissionsURL()
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(manifest)
        try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: url.deletingLastPathComponent()
        ) {
            try SensitiveFilePermissions.write(data, to: url)
        }
    }
}
