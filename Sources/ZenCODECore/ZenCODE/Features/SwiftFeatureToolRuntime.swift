//
//  SwiftFeatureToolRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import FeatureKit
import Foundation
import ToolCore

public actor SwiftFeatureRuntime {
    public static let featurePackageToolsAllowedName = "feature.tools"
    public static let generatedSwiftToolsVersion = "6.3"

    public static func isFeatureManagementToolName(_ toolName: String) -> Bool {
        switch toolName {
        case "feature.list",
             "feature.enable",
             "feature.disable",
             "feature.delete",
             "feature.edit",
             "feature.update",
             "feature.reload",
             "feature.validate",
             "feature.build",
             "feature.scaffold",
             "feature.promote",
             "feature.install":
            return true
        default:
            return false
        }
    }

    let explicitFeatures: [SwiftFeatureBundle]?
    let featureSearchRoots: [URL]?
    let fileManager: FileManager
    var features: [SwiftFeatureBundle]
    var runtimeDiscoveredToolsByFeatureID: [String: [ToolDescriptor]] = [:]
    /// Child processes are owned by this actor, so a runtime injected into a
    /// sub-agent retains the same feature connection for the entire root
    /// session. Only bundles that explicitly opt in create an entry here.
    var persistentProcessesByFeatureID: [String: FeaturePersistentProcess] = [:]
    /// Actor methods are reentrant while a child shuts down. Gate process
    /// creation so a concurrent invocation cannot resurrect a session during
    /// reload or after terminal runtime shutdown.
    var acceptsPersistentProcessRequests = true
    var persistentProcessesWereShutDown = false
    var persistentProcessReloadCount = 0
    /// Feature IDs whose installation is currently in progress. Because actor
    /// methods are reentrant at suspension points, two concurrent calls for the
    /// same feature ID could race on staging directories and publication. The
    /// second concurrent call is rejected with a clear error instead.
    var inProgressInstallations: Set<String> = []

    public init(
        features explicitFeatures: [SwiftFeatureBundle]? = nil,
        featureSearchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        self.explicitFeatures = explicitFeatures
        self.featureSearchRoots = featureSearchRoots
        self.fileManager = fileManager
        if let explicitFeatures {
            self.features = explicitFeatures
        } else {
            self.features = Self.defaultFeatureBundles(
                searchRoots: featureSearchRoots,
                fileManager: fileManager
            )
        }
    }

    deinit {
        let processes = Array(persistentProcessesByFeatureID.values)
        Task(name: "Swift feature runtime deinit shutdown") {
            for process in processes {
                await process.shutdown()
            }
        }
    }

    /// Releases all opt-in feature processes owned by this runtime. Hosts that
    /// manage their own session lifecycle may call this explicitly; deinit also
    /// performs a best-effort shutdown when the shared runtime is released.
    public func shutdown() async {
        persistentProcessesWereShutDown = true
        acceptsPersistentProcessRequests = false
        let processes = Array(persistentProcessesByFeatureID.values)
        persistentProcessesByFeatureID.removeAll()
        for process in processes {
            await process.shutdown()
        }
    }

    func persistentProcess(for feature: SwiftFeatureBundle) throws -> FeaturePersistentProcess {
        guard acceptsPersistentProcessRequests else {
            throw FeaturePersistentProcessError(
                kind: .closed,
                message: "Swift feature runtime is not accepting persistent requests."
            )
        }
        if let existing = persistentProcessesByFeatureID[feature.id] {
            return existing
        }
        let process = FeaturePersistentProcess(
            executableURL: feature.executableURL,
            workingDirectory: feature.executableURL.deletingLastPathComponent(),
            environment: DeveloperToolEnvironment.processEnvironment()
        )
        persistentProcessesByFeatureID[feature.id] = process
        return process
    }

    func persistentResponse(
        for feature: SwiftFeatureBundle,
        request: FeaturePersistentRequest,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        try await persistentProcess(for: feature).response(to: request, timeout: timeout)
    }
}
