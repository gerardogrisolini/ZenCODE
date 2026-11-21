//
//  SetupManifestBaseline.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation

/// Read-only compare-and-swap baseline for the two manifests setup may replace.
/// Unlike the removed rollback snapshot, it is never written back: a mismatch at
/// finalization aborts before mutation instead of overwriting a concurrent edit.
package struct SetupManifestBaseline: Sendable {
    package let settingsData: Data?
    package let agentsData: Data?

    package static func capture(
        fileManager: FileManager = .default
    ) throws -> SetupManifestBaseline {
        try SensitiveManifestCoordination.withExclusiveLock(
            fileManager: fileManager
        ) {
            func dataIfPresent(at url: URL) throws -> Data? {
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            }
            return try SetupManifestBaseline(
                settingsData: dataIfPresent(
                    at: AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
                ),
                agentsData: dataIfPresent(
                    at: AgentProfileStore.agentsManifestURL(fileManager: fileManager)
                )
            )
        }
    }
}
