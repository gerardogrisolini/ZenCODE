//
//  AgentProfileBindingReconcilerTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

private enum InjectedManifestCommitFailure: Error {
    case stop
}

@Suite(.serialized)
struct AgentProfileBindingReconcilerTests {
    @Test
    func reconciliationRemovesOnlyStaleOrAmbiguousBindingsAndRecalculatesDefault() {
        let alpha = Self.model(providerName: "Alpha", modelID: "alpha-model")
        let beta = Self.model(providerName: "Beta", modelID: "shared-model")
        let gamma = Self.model(providerName: "Gamma", modelID: "shared-model")
        let skill = AgentProfileSkill(id: "swift-review", canonicalName: "swift-review")
        let original = AgentProfile(
            id: "custom-agent",
            name: "Custom",
            instructions: "Keep these instructions.",
            symbolName: "hammer",
            readOnly: true,
            tools: ["files", "text"],
            skills: [skill],
            modelBindings: [
                AgentModelBinding(id: "alpha", modelID: alpha.id, capability: 4),
                AgentModelBinding(id: "beta", modelID: beta.id, capability: 7),
                AgentModelBinding(id: "ambiguous", modelID: "shared-model", capability: 5),
                AgentModelBinding(id: "removed", modelID: "removed-model", capability: 9)
            ],
            defaultModelBindingID: "removed"
        )

        let reconciled = AgentProfileBindingReconciler.reconciledAgents(
            [original],
            models: [alpha, beta, gamma]
        )
        let agent = reconciled[0]

        #expect(agent.id == original.id)
        #expect(agent.name == original.name)
        #expect(agent.instructions == original.instructions)
        #expect(agent.symbolName == original.symbolName)
        #expect(agent.readOnly == original.readOnly)
        #expect(agent.tools == original.tools)
        #expect(agent.skills == original.skills)
        #expect(agent.modelBindings.map(\.id) == ["alpha", "beta"])
        // The persisted default was removed; AgentProfile's normalized order
        // makes the replacement deterministic.
        #expect(agent.defaultModelBindingID == "alpha")
    }

    @Test
    func reconciliationTreatsProviderUUIDReplacementAsAnOrphanedCanonicalBinding() {
        let replacement = Self.model(providerName: "Replacement", modelID: "same-model")
        let oldCanonicalID = "remoteapi:\(UUID().uuidString.lowercased()):same-model"
        let original = AgentProfile(
            id: "custom-agent",
            name: "Custom",
            modelBindings: [
                AgentModelBinding(id: "old", modelID: oldCanonicalID, capability: 8),
                AgentModelBinding(
                    id: "survives",
                    modelID: "same-model",
                    modelProvider: "Replacement",
                    capability: 3
                )
            ],
            defaultModelBindingID: "old"
        )

        let reconciled = AgentProfileBindingReconciler.reconciledAgents(
            [original],
            models: [replacement]
        )

        #expect(reconciled[0].modelBindings.map(\.id) == ["survives"])
        #expect(reconciled[0].modelBindings.first?.modelID == replacement.id)
        #expect(reconciled[0].defaultModelBindingID == "survives")
    }

    @Test
    func authoritativeEmptyCatalogRemovesEveryBinding() {
        let original = AgentProfile(
            id: "custom-agent",
            name: "Custom",
            modelBindings: [
                AgentModelBinding(id: "removed", modelID: "not-currently-configured")
            ],
            defaultModelBindingID: "removed"
        )

        let reconciled = AgentProfileBindingReconciler.reconciledAgents(
            [original],
            models: []
        )
        #expect(reconciled[0].modelBindings.isEmpty)
        #expect(reconciled[0].defaultModelBindingID == nil)
    }

    @Test
    func storedReconciliationUsesIsolatedSupportDirectoryAndAtomicProfileStore() throws {
        try Self.withTemporarySupportDirectory { directory in
            let retained = Self.model(providerName: "Primary", modelID: "retained")
            let original = AgentProfile(
                id: "custom-agent",
                name: "Custom",
                instructions: "Persist me.",
                tools: ["files"],
                skills: [AgentProfileSkill(id: "skill")],
                modelBindings: [
                    AgentModelBinding(id: "gone", modelID: "gone"),
                    AgentModelBinding(id: "kept", modelID: retained.id)
                ],
                defaultModelBindingID: "gone"
            )
            try AgentProfileStore.save([original])

            let result = try ZenFileService.ensureRequiredFiles(
                settingsManifest: AgentSettingsManifest(models: [retained]),
                overwriteSettings: true
            )
            let storedAgents = try AgentProfileStore.loadRequired()
            let stored = try #require(storedAgents.first)

            #expect(result.supportDirectoryURL == directory.standardizedFileURL)
            #expect(stored.instructions == "Persist me.")
            #expect(stored.tools == ["files"])
            #expect(stored.skills == [AgentProfileSkill(id: "skill")])
            #expect(stored.modelBindings.map(\.id) == ["kept"])
            #expect(stored.defaultModelBindingID == "kept")
            #expect(FileManager.default.fileExists(atPath: result.settingsFileURL.path))
        }
    }

    @Test
    func storedReconciliationLeavesMissingProfilesUntouchedAndRejectsInvalidProfiles() throws {
        try Self.withTemporarySupportDirectory { directory in
            let model = Self.model(providerName: "Primary", modelID: "retained")
            let manifest = AgentSettingsManifest(models: [model])

            #expect(
                try AgentProfileBindingReconciler.reconcileStoredAgents(with: manifest) == false
            )

            let agentsURL = directory.appendingPathComponent(AgentProfileStore.manifestFilename)
            let invalidData = Data("not-json".utf8)
            try invalidData.write(to: agentsURL)

            #expect(throws: AgentProfileStoreError.self) {
                try AgentProfileBindingReconciler.reconcileStoredAgents(with: manifest)
            }
            #expect(try Data(contentsOf: agentsURL) == invalidData)
        }
    }

    @Test
    func setupSessionStagesProfilesUntilFinalManifestCommit() throws {
        try Self.withTemporarySupportDirectory { directory in
            let settingsURL = directory.appendingPathComponent(
                AgentSettingsManifestStore.settingsFilename
            )
            let agentsURL = directory.appendingPathComponent(
                AgentProfileStore.manifestFilename
            )
            let originalModel = Self.model(providerName: "Original", modelID: "original")
            let originalManifest = AgentSettingsManifest(models: [originalModel])
            try AgentSettingsManifestStore.save(originalManifest, to: settingsURL)
            try AgentProfileStore.save([
                AgentProfile(id: "original", name: "Original")
            ])
            let originalSettings = try Data(contentsOf: settingsURL)
            let originalAgents = try Data(contentsOf: agentsURL)

            let replacement = Self.model(providerName: "Replacement", modelID: "replacement")
            let replacementManifest = AgentSettingsManifest(models: [replacement])
            let replacementProfiles = [
                AgentProfile(
                    id: "replacement",
                    name: "Replacement",
                    modelBindings: [
                        AgentModelBinding(
                            id: "replacement-binding",
                            modelID: replacement.id,
                            capability: 6
                        )
                    ]
                )
            ]
            var session = SetupSession(originalManifest: originalManifest)
            session.apply(
                SetupSectionConfigurationResult(
                    manifest: replacementManifest,
                    agentProfiles: replacementProfiles
                )
            )

            #expect(session.agentProfiles == replacementProfiles)
            #expect(try Data(contentsOf: settingsURL) == originalSettings)
            #expect(try Data(contentsOf: agentsURL) == originalAgents)

            try ZenFileService.ensureRequiredFiles(
                settingsManifest: replacementManifest,
                overwriteSettings: true,
                stagedAgentProfiles: session.agentProfiles
            )

            #expect(
                try AgentSettingsManifestStore.loadRequired(from: settingsURL)
                    == replacementManifest
            )
            let storedProfiles = try AgentProfileStore.loadRequired()
            #expect(storedProfiles.map(\.id) == ["replacement"])
            #expect(storedProfiles[0].modelBindings[0].modelID == replacement.id)
        }
    }

    @Test
    func abandoningAStagedSetupSessionDoesNotClobberConcurrentWrites() throws {
        try Self.withTemporarySupportDirectory { directory in
            let settingsURL = directory.appendingPathComponent(
                AgentSettingsManifestStore.settingsFilename
            )
            let initialModel = Self.model(providerName: "Initial", modelID: "initial")
            let stagedModel = Self.model(providerName: "Staged", modelID: "staged")
            let concurrentModel = Self.model(providerName: "Concurrent", modelID: "concurrent")
            let initialManifest = AgentSettingsManifest(models: [initialModel])
            try AgentSettingsManifestStore.save(initialManifest, to: settingsURL)
            try AgentProfileStore.save([AgentProfile(id: "initial", name: "Initial")])

            var abandonedSession = SetupSession(originalManifest: initialManifest)
            abandonedSession.apply(
                SetupSectionConfigurationResult(
                    manifest: AgentSettingsManifest(models: [stagedModel]),
                    agentProfiles: [AgentProfile(id: "staged", name: "Staged")]
                )
            )

            let concurrentManifest = AgentSettingsManifest(models: [concurrentModel])
            try AgentSettingsManifestStore.save(concurrentManifest, to: settingsURL)
            try AgentProfileStore.save([
                AgentProfile(id: "concurrent", name: "Concurrent")
            ])
            // Cancelling/abandoning has no persistence action: there is no
            // rollback that could overwrite another process's later write.
            _ = abandonedSession

            #expect(
                try AgentSettingsManifestStore.loadRequired(from: settingsURL)
                    == concurrentManifest
            )
            #expect(try AgentProfileStore.loadRequired().map(\.id) == ["concurrent"])
        }
    }

    @Test
    func coordinatedManifestCommitRollsBackAfterAnInjectedSecondFileFailure() throws {
        try Self.withTemporarySupportDirectory { directory in
            let settingsURL = directory.appendingPathComponent(
                AgentSettingsManifestStore.settingsFilename
            )
            let agentsURL = directory.appendingPathComponent(
                AgentProfileStore.manifestFilename
            )
            let originalModel = Self.model(providerName: "Original", modelID: "original")
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: [originalModel]),
                to: settingsURL
            )
            try AgentProfileStore.save([
                AgentProfile(id: "original", name: "Original")
            ])
            let originalSettings = try Data(contentsOf: settingsURL)
            let originalAgents = try Data(contentsOf: agentsURL)

            let replacement = Self.model(providerName: "Replacement", modelID: "replacement")
            #expect(throws: InjectedManifestCommitFailure.self) {
                try ZenFileService.ensureRequiredFiles(
                    settingsManifest: AgentSettingsManifest(models: [replacement]),
                    overwriteSettings: true,
                    stagedAgentProfiles: [
                        AgentProfile(id: "replacement", name: "Replacement")
                    ],
                    commitCheckpoint: { completedWrites in
                        if completedWrites == 1 {
                            throw InjectedManifestCommitFailure.stop
                        }
                    }
                )
            }

            #expect(try Data(contentsOf: settingsURL) == originalSettings)
            #expect(try Data(contentsOf: agentsURL) == originalAgents)
            #expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(
                        ".manifests.transaction.json"
                    ).path
                )
            )
        }
    }

    @Test
    func cleanupFailureLeavesOnlyRollbackIntentForFutureRecovery() throws {
        try Self.withTemporarySupportDirectory { directory in
            let originalManifest = AgentSettingsManifest(
                models: [Self.model(providerName: "Original", modelID: "original")]
            )
            let originalProfiles = [
                AgentProfile(id: "original", name: "Original")
            ]
            try AgentSettingsManifestStore.save(originalManifest)
            try AgentProfileStore.save(originalProfiles)
            let settingsURL = AgentSettingsManifestStore.settingsURL()
            let agentsURL = AgentProfileStore.agentsManifestURL()
            let originalSettingsData = try Data(contentsOf: settingsURL)
            let originalAgentsData = try Data(contentsOf: agentsURL)

            #expect(throws: InjectedManifestCommitFailure.self) {
                try ZenFileService.ensureRequiredFiles(
                    settingsManifest: AgentSettingsManifest(
                        models: [Self.model(providerName: "Intended", modelID: "intended")]
                    ),
                    overwriteSettings: true,
                    stagedAgentProfiles: [
                        AgentProfile(id: "intended", name: "Intended")
                    ],
                    transactionCleanup: { _, _ in
                        throw InjectedManifestCommitFailure.stop
                    }
                )
            }

            #expect(try Data(contentsOf: settingsURL) == originalSettingsData)
            #expect(try Data(contentsOf: agentsURL) == originalAgentsData)
            #expect(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(
                        ".manifests.transaction.json"
                    ).path
                )
            )

            let recovered = AgentDelegationCatalog.liveConfiguration()
            #expect(recovered.catalog.models.map(\.modelID) == ["original"])
            #expect(recovered.profiles.map(\.id) == ["original"])
            #expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(
                        ".manifests.transaction.json"
                    ).path
                )
            )
        }
    }

    @Test
    func invalidPersistedProfilesAreRejectedBeforeSettingsReplacement() throws {
        try Self.withTemporarySupportDirectory { directory in
            let settingsURL = directory.appendingPathComponent(
                AgentSettingsManifestStore.settingsFilename
            )
            let agentsURL = directory.appendingPathComponent(
                AgentProfileStore.manifestFilename
            )
            let originalModel = Self.model(providerName: "Original", modelID: "original")
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: [originalModel]),
                to: settingsURL
            )
            let originalSettings = try Data(contentsOf: settingsURL)
            try SensitiveFilePermissions.write(Data("invalid".utf8), to: agentsURL)

            let replacement = Self.model(providerName: "Replacement", modelID: "replacement")
            #expect(throws: AgentProfileStoreError.self) {
                try ZenFileService.ensureRequiredFiles(
                    settingsManifest: AgentSettingsManifest(models: [replacement]),
                    overwriteSettings: true
                )
            }

            #expect(try Data(contentsOf: settingsURL) == originalSettings)
            #expect(try Data(contentsOf: agentsURL) == Data("invalid".utf8))
        }
    }

    @Test
    func finalizationRejectsASettingsUpdateCompletedDuringSetup() throws {
        try Self.withTemporarySupportDirectory { directory in
            let settingsURL = directory.appendingPathComponent(
                AgentSettingsManifestStore.settingsFilename
            )
            let initial = AgentSettingsManifest(
                models: [Self.model(providerName: "Initial", modelID: "initial")]
            )
            try AgentSettingsManifestStore.save(initial, to: settingsURL)
            try AgentProfileStore.save([
                AgentProfile(id: "initial", name: "Initial")
            ])
            let baseline = try SetupManifestBaseline.capture()

            let concurrent = AgentSettingsManifest(
                models: [Self.model(providerName: "Concurrent", modelID: "concurrent")]
            )
            try AgentSettingsManifestStore.save(concurrent, to: settingsURL)
            let concurrentData = try Data(contentsOf: settingsURL)

            #expect(throws: ZenCODESupportFileServiceError.self) {
                try ZenFileService.ensureRequiredFiles(
                    settingsManifest: AgentSettingsManifest(
                        models: [Self.model(providerName: "Staged", modelID: "staged")]
                    ),
                    overwriteSettings: true,
                    stagedAgentProfiles: nil,
                    expectedBaseline: baseline
                )
            }

            #expect(try Data(contentsOf: settingsURL) == concurrentData)
            #expect(
                try AgentSettingsManifestStore.loadRequired(from: settingsURL)
                    == concurrent
            )
        }
    }

    @Test
    func finalizationRejectsAProfileUpdateCompletedDuringSetup() throws {
        try Self.withTemporarySupportDirectory { _ in
            let manifest = AgentSettingsManifest(
                models: [Self.model(providerName: "Model", modelID: "model")]
            )
            try AgentSettingsManifestStore.save(manifest)
            try AgentProfileStore.save([
                AgentProfile(id: "initial", name: "Initial")
            ])
            let baseline = try SetupManifestBaseline.capture()

            let concurrentProfiles = [
                AgentProfile(id: "concurrent", name: "Concurrent")
            ]
            try AgentProfileStore.save(concurrentProfiles)

            #expect(throws: ZenCODESupportFileServiceError.self) {
                try ZenFileService.ensureRequiredFiles(
                    settingsManifest: manifest,
                    overwriteSettings: false,
                    stagedAgentProfiles: [
                        AgentProfile(id: "staged", name: "Staged")
                    ],
                    expectedBaseline: baseline
                )
            }

            #expect(try AgentProfileStore.loadRequired() == concurrentProfiles)
        }
    }

    @Test
    func agentOnlyFinalizationRejectsAConcurrentSettingsUpdate() throws {
        try Self.withTemporarySupportDirectory { _ in
            let initialManifest = AgentSettingsManifest(
                models: [Self.model(providerName: "Initial", modelID: "initial")]
            )
            let originalProfiles = [
                AgentProfile(id: "original", name: "Original")
            ]
            try AgentSettingsManifestStore.save(initialManifest)
            try AgentProfileStore.save(originalProfiles)
            let baseline = try SetupManifestBaseline.capture()

            let concurrentManifest = AgentSettingsManifest(
                models: [Self.model(providerName: "Concurrent", modelID: "concurrent")]
            )
            try AgentSettingsManifestStore.save(concurrentManifest)

            #expect(throws: ZenCODESupportFileServiceError.self) {
                try ZenFileService.ensureRequiredFiles(
                    settingsManifest: initialManifest,
                    overwriteSettings: false,
                    stagedAgentProfiles: [
                        AgentProfile(id: "staged", name: "Staged")
                    ],
                    expectedBaseline: baseline
                )
            }

            #expect(try AgentSettingsManifestStore.loadRequired() == concurrentManifest)
            #expect(try AgentProfileStore.loadRequired() == originalProfiles)
        }
    }

    @Test
    func interruptedTwoManifestCommitRollsBackFromItsJournal() throws {
        try Self.withTemporarySupportDirectory { directory in
            let settingsURL = AgentSettingsManifestStore.settingsURL()
            let agentsURL = AgentProfileStore.agentsManifestURL()
            let originalManifest = AgentSettingsManifest(
                models: [Self.model(providerName: "Original", modelID: "original")]
            )
            try AgentSettingsManifestStore.save(originalManifest)
            try AgentProfileStore.save([
                AgentProfile(id: "original", name: "Original")
            ])
            let originalSettings = try Data(contentsOf: settingsURL)
            let originalAgents = try Data(contentsOf: agentsURL)

            let intendedManifest = AgentSettingsManifest(
                models: [Self.model(providerName: "Intended", modelID: "intended")]
            )
            let intendedProfiles = [
                AgentProfile(id: "intended", name: "Intended")
            ]
            let intendedSettings = try AgentSettingsManifestStore.encodedData(
                for: intendedManifest
            )
            let intendedAgents = try AgentProfileStore.encodedData(
                for: intendedProfiles
            )

            try SensitiveManifestCoordination.withExclusiveLock {
                try SensitiveManifestCoordination.beginTransaction(
                    [
                        .init(
                            url: settingsURL,
                            originalData: intendedSettings,
                            intendedData: originalSettings
                        ),
                        .init(
                            url: agentsURL,
                            originalData: intendedAgents,
                            intendedData: originalAgents
                        ),
                    ],
                    supportDirectoryURL: directory
                )
                // Simulate process termination after only the first rename by
                // deliberately returning without rollback or journal cleanup.
                try SensitiveFilePermissions.writeDurably(
                    intendedSettings,
                    to: settingsURL
                )
            }

            let recovered = AgentDelegationCatalog.liveConfiguration()
            #expect(recovered.catalog.models.map(\.modelID) == ["original"])
            #expect(recovered.profiles.map(\.id) == ["original"])
            #expect(try Data(contentsOf: settingsURL) == originalSettings)
            #expect(try Data(contentsOf: agentsURL) == originalAgents)
            #expect(
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(
                        ".manifests.transaction.json"
                    ).path
                )
            )
        }
    }

    private static func model(
        providerName: String,
        modelID: String
    ) -> AgentSettingsModelManifest {
        let providerID = UUID()
        let provider = AgentRemoteProvider(
            id: providerID,
            name: providerName,
            baseURL: "https://\(providerName.lowercased()).example.invalid/v1",
            modelID: modelID
        )
        let id = "remoteapi:\(providerID.uuidString.lowercased()):\(modelID)"
        return AgentSettingsModelManifest(
            id: id,
            kind: .remoteAPI,
            llmID: id,
            modelID: modelID,
            providerID: providerID,
            provider: provider
        )
    }

    private static func withTemporarySupportDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-agent-reconciliation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try AppStorageDirectory.withSupportDirectoryURL(directory) {
            try body(directory)
        }
    }
}
