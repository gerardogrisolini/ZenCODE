//
//  MLXServerModelSetupRunner+ConfiguredModels.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//
import Foundation
import HuggingFace
import ZenCODECore
import MLXServerCore

extension MLXServerModelSetupRunner {
    static func reconfigureExistingModelsIfRequested(
        in manifest: inout MLXServerModelsManifest
    ) throws {
        guard !manifest.models.isEmpty else {
            return
        }
        guard try promptYesNo(
            "Reconfigure parameters for already configured models?",
            defaultValue: false
        ) else {
            return
        }

        let candidates = MLXServerCachedModelScanner.candidates(
            cache: MLXServerHuggingFaceCacheAccessStore.cache
        )
        let existingModels = manifest.models
        for model in existingModels {
            let updatedModel = try reconfigureExistingModel(
                model,
                cachedCandidate: cachedCandidate(for: model, in: candidates)
            )
            replaceExistingModel(
                oldID: model.id,
                with: updatedModel,
                in: &manifest
            )
        }
    }

    static func removeConfiguredModelsIfRequested(
        in manifest: inout MLXServerModelsManifest
    ) throws {
        guard !manifest.models.isEmpty else {
            return
        }
        guard try promptYesNo(
            "Remove configured models from models.json?",
            defaultValue: false
        ) else {
            return
        }

                while !manifest.models.isEmpty {
            let stopValue = manifest.models.count
            let items = manifest.models.enumerated().map { index, model in
                TerminalCheckboxMenuItem(
                    value: index,
                    title: model.id,
                    detail: model.repositoryID
                )
            } + [
                TerminalCheckboxMenuItem(
                    value: stopValue,
                    title: "Done",
                    detail: "stop removing models",
                    groupTitle: " "
                )
            ]
            let selectedIndex = TerminalCheckboxMenu.selectOne(
                title: "Model to remove",
                items: items,
                selected: stopValue
            ) ?? stopValue
            guard manifest.models.indices.contains(selectedIndex) else {
                return
            }

            let model = manifest.models[selectedIndex]

            guard try promptYesNo(
                "Remove \(model.id) from models.json and delete cached files?",
                defaultValue: false
            ) else {
                continue
            }

                        try removeCachedModelFiles(for: model)
            manifest.models.remove(at: selectedIndex)
            refreshDefaultModel(in: &manifest)
            AgentOutput.standardError.writeString("Removed: \(model.id)\n")

            guard !manifest.models.isEmpty else {
                AgentOutput.standardError.writeString("No configured models remain.\n\n")
                return
            }
            guard try promptYesNo("Remove another model?", defaultValue: false) else {
                AgentOutput.standardError.writeString("\n")
                return
            }
        }
    }

    static func removeCachedModelFiles(
        for model: MLXServerModelRecord,
        cache: HubCache = MLXServerHuggingFaceCacheAccessStore.cache,
        fileManager: FileManager = .default
    ) throws {
        try removeCachedRepository(
            repositoryID: model.repositoryID,
            cache: cache,
            fileManager: fileManager
        )
    }

    static func removeCachedRepository(
        repositoryID: String,
        cache: HubCache = MLXServerHuggingFaceCacheAccessStore.cache,
        fileManager: FileManager = .default
    ) throws {
        let removalResult = try MLXServerHuggingFaceCacheRemoval.remove(
            repositoryID: repositoryID,
            cache: cache,
            fileManager: fileManager
        )

        switch removalResult {
        case .invalidRepositoryID:
            AgentOutput.standardError.writeString(
                "Skipped cache removal for invalid repository id: \(repositoryID)\n"
            )
        case .removed:
            AgentOutput.standardError.writeString("Removed cached files for \(repositoryID)\n")
        case .notFound:
            AgentOutput.standardError.writeString("No cached files found for \(repositoryID)\n")
        }
    }

    static func upsert(
        record: MLXServerModelRecord,
        in manifest: inout MLXServerModelsManifest
    ) {
        if let index = manifest.models.firstIndex(where: { $0.id == record.id }) {
            manifest.models[index] = record
        } else {
            manifest.models.append(record)
        }
    }

    static func replaceExistingModel(
        oldID: String,
        with record: MLXServerModelRecord,
        in manifest: inout MLXServerModelsManifest
    ) {
        let wasDefault = manifest.defaultModelID == oldID
        if let replacementIndex = manifest.models.firstIndex(where: { $0.id == oldID }) {
            manifest.models[replacementIndex] = record
            let duplicateIndices = manifest.models.indices.reversed().filter {
                $0 != replacementIndex && manifest.models[$0].id == record.id
            }
            for index in duplicateIndices {
                manifest.models.remove(at: index)
            }
        } else {
            upsert(record: record, in: &manifest)
        }
        if wasDefault {
            manifest.defaultModelID = record.id
        }
    }

    static func refreshDefaultModel(in manifest: inout MLXServerModelsManifest) {
        if let defaultModelID = manifest.defaultModelID,
           manifest.models.contains(where: { $0.id == defaultModelID }) {
            return
        }
        manifest.defaultModelID = preferredDefaultModelID(in: manifest)
    }

    static func preferredDefaultModelID(in manifest: MLXServerModelsManifest) -> String? {
        manifest.models.first(where: \.enabled)?.id
            ?? manifest.models.first?.id
    }

    static func modelIndex(
        matching selection: String,
        in models: [MLXServerModelRecord]
    ) -> Int? {
        if let numericSelection = Int(selection),
           models.indices.contains(numericSelection - 1) {
            return numericSelection - 1
        }
        return models.firstIndex {
            $0.id == selection || $0.repositoryID == selection
        }
    }

    static func updateDefaultModel(
        afterAdding record: MLXServerModelRecord,
        in manifest: inout MLXServerModelsManifest
    ) throws {
        if manifest.defaultModelID == nil || manifest.models.count == 1 {
            manifest.defaultModelID = record.id
        }
    }

    static func selectDefaultModelIfRequested(
        in manifest: inout MLXServerModelsManifest
    ) throws {
        let enabledModels = manifest.models.filter(\.enabled)
        guard !enabledModels.isEmpty else {
            return
        }

        let currentDefaultModel = enabledModels.first { $0.id == manifest.defaultModelID }
            ?? enabledModels[0]
        manifest.defaultModelID = currentDefaultModel.id

        guard enabledModels.count > 1 else {
            return
        }

                guard try promptYesNo(
            "Change default model?",
            defaultValue: false
        ) else {
            return
        }

        let defaultIndex = enabledModels.firstIndex { $0.id == currentDefaultModel.id } ?? 0
        let items = enabledModels.enumerated().map { index, model in
            TerminalCheckboxMenuItem(
                value: index,
                title: model.id,
                detail: model.repositoryID
            )
        }
        let selectedIndex = TerminalCheckboxMenu.selectOne(
            title: "Default model",
            items: items,
            selected: defaultIndex
        ) ?? defaultIndex
        manifest.defaultModelID = enabledModels[selectedIndex].id

    }

    static func printExistingModels(_ manifest: MLXServerModelsManifest) {
        guard !manifest.models.isEmpty else {
            return
        }
        AgentOutput.standardError.writeString("Configured models:\n")
        for model in manifest.models {
            let marker = model.id == manifest.defaultModelID ? "*" : " "
            AgentOutput.standardError.writeString("\(marker) \(model.id) -> \(model.repositoryID)\n")
        }
        AgentOutput.standardError.writeString("\n")
    }

    static func printModelRemovalChoices(_ manifest: MLXServerModelsManifest) {
        AgentOutput.standardError.writeString("\nConfigured models:\n")
        for (index, model) in manifest.models.enumerated() {
            let marker = model.id == manifest.defaultModelID ? " *" : ""
            AgentOutput.standardError.writeString(
                "\(index + 1). \(model.id)\(marker) -> \(model.repositoryID)\n"
            )
        }
        AgentOutput.standardError.writeString("\n")
    }

}
