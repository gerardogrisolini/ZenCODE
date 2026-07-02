//
//  MLXServerModelSetupRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Foundation
import HuggingFace
import ZenCODECore
import MLXServerCore

public enum MLXServerModelSetupRunner {
    static let recommendedContextWindow = 65_536

    @MainActor
    public static func runQuickSetup() async throws -> MLXServerQuickModelSetupResult {
        guard supportsInteractiveInput() else {
            throw MLXServerModelSetupError.nonInteractiveTerminal
        }

        let modelsURL = MLXServerModelsManifestStore.modelsURL()
                AgentOutput.standardError.writeString(
            """
            Local MLX model quick setup
            Search Hugging Face for a local MLX model. Good starting searches: qwen3.6 or gemma-4.

            """
        )

        try await MLXServerHuggingFaceCachePermissionRequester.ensureAccessIfNeeded()

        var manifest = try loadExistingModelsManifestForQuickSetup(from: modelsURL)
        let importedCachedModelCount = try importCachedModelsIfRequested(into: &manifest)
        if !manifest.models.isEmpty {
            try MLXServerModelsManifestStore.save(manifest, to: modelsURL)
            if importedCachedModelCount > 0 {
                AgentOutput.standardError.writeString(
                    "Imported downloaded local MLX models. Skipping model download.\n"
                )
            } else {
                AgentOutput.standardError.writeString(
                    "Local MLX model already configured. Skipping model download.\n"
                )
            }
            return MLXServerQuickModelSetupResult(
                downloadedModelID: nil,
                configuredModelCount: manifest.models.count
            )
        }

        guard let configuredModel = try await configureRemoteModel() else {
            if !manifest.models.isEmpty {
                try MLXServerModelsManifestStore.save(manifest, to: modelsURL)
            }
                        AgentOutput.standardError.writeString("Local model download skipped. You can add one later from zen --setup.\n")
            return MLXServerQuickModelSetupResult(
                downloadedModelID: nil,
                configuredModelCount: manifest.models.count
            )
        }

        upsert(record: configuredModel.record, in: &manifest)
        try updateDefaultModel(afterAdding: configuredModel.record, in: &manifest)
                try MLXServerModelsManifestStore.save(manifest, to: modelsURL)
        AgentOutput.standardError.writeString("Updated: models.json\n")
        return MLXServerQuickModelSetupResult(
            downloadedModelID: configuredModel.record.id,
            configuredModelCount: manifest.models.count
        )
    }

        static func loadExistingModelsManifestForQuickSetup(
        from modelsURL: URL
    ) throws -> MLXServerModelsManifest {
        guard FileManager.default.fileExists(atPath: modelsURL.path) else {
            return MLXServerModelsManifest()
        }
        let resolution = try SetupConfigurationResolver.resolve {
            var manifest = try MLXServerModelsManifestStore.loadRequired(from: modelsURL)
            refreshExistingModelRuntimeKinds(in: &manifest)
            return manifest
        } confirmOverwrite: { _ in
            try promptYesNo(
                "models.json exists but is invalid. Rewrite it?",
                defaultValue: true
            )
        }
        switch resolution {
        case let .loaded(manifest):
            return manifest
        case .overwrite:
            return MLXServerModelsManifest()
        }
    }

    @MainActor
    public static func run(arguments: [String]) async throws {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerModelSetupError.nonInteractiveTerminal
        }

        let modelsURL = MLXServerModelsManifestStore.modelsURL()
                AgentOutput.standardError.writeString(
            """
            ZenCODE MLX models setup
            Configuring models.json at:
            \(modelsURL.path)

            """
        )

        try await MLXServerHuggingFaceCachePermissionRequester.ensureAccessIfNeeded()

                var manifest = MLXServerModelsManifest()
        let modelsFileExists = FileManager.default.fileExists(atPath: modelsURL.path)
        if modelsFileExists {
            let resolution = try SetupConfigurationResolver.resolve {
                var loadedManifest = try MLXServerModelsManifestStore.loadRequired(from: modelsURL)
                refreshExistingModelRuntimeKinds(in: &loadedManifest)
                return loadedManifest
            } confirmOverwrite: { _ in
                try promptYesNo(
                    "models.json exists but is invalid. Rewrite it?",
                    defaultValue: true
                )
            }
            if case let .loaded(loadedManifest) = resolution {
                manifest = loadedManifest
                printExistingModels(manifest)
            }
        }

        try importCachedModelsIfRequested(into: &manifest)

        let shouldConfigureRemoteModel = try promptYesNo(
            "Search and download more models from Hugging Face?",
            defaultValue: manifest.models.isEmpty
        )
        if shouldConfigureRemoteModel {
            while true {
                guard let configuredModel = try await configureRemoteModel() else {
                    break
                }
                upsert(record: configuredModel.record, in: &manifest)
                try updateDefaultModel(
                    afterAdding: configuredModel.record,
                    in: &manifest
                )
                guard try promptYesNo("Add another model?", defaultValue: false) else {
                    break
                }
            }
        }

                                try reconfigureExistingModelsIfRequested(in: &manifest)
        try selectDefaultModelIfRequested(in: &manifest)
        try removeConfiguredModelsIfRequested(in: &manifest)
        try MLXServerModelsManifestStore.save(manifest, to: modelsURL)

                AgentOutput.standardError.writeString("Updated: models.json\n")
        AgentOutput.standardError.writeString("\nModels setup completed.\n\n")
    }

}
