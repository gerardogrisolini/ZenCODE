//
//  MLXServerModelSetupRunner+ModelRecord.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import HuggingFace
import ZenCODECore
import MLXServerCore

extension MLXServerModelSetupRunner {
    static func configureCachedModel(
        _ candidate: MLXServerCachedModelCandidate,
        promptForParameters: Bool = true
    ) throws -> ConfiguredModelRecord {
        try configureModelRecord(
            repositoryID: candidate.repositoryID,
            revision: candidate.revision,
            snapshotURL: candidate.snapshotURL,
            defaultRuntimeKind: inferredRuntimeKind(from: candidate),
            promptForParameters: promptForParameters
        )
    }

    static func reconfigureExistingModel(
        _ model: MLXServerModelRecord,
        cachedCandidate: MLXServerCachedModelCandidate?
    ) throws -> MLXServerModelRecord {
        let importedDefaults = cachedCandidate.map {
            MLXServerModelParameterImporter.importDefaults(from: $0.snapshotURL)
        } ?? .init()
        let modelContextLimit = importedDefaults.contextWindow
        let fallbackDefaults = setupDefaults(
            from: importedDefaults,
            modelContextLimit: modelContextLimit
        )
        let effectiveDefaults = generationDefaults(
            model.generationDefaults,
            fallingBackTo: fallbackDefaults
        )
        let detectedThinking = cachedCandidate.map {
            MLXServerModelParameterImporter.importThinking(
                from: $0.snapshotURL,
                repositoryID: model.repositoryID
            )
        }?.validated() ?? model.thinking.validated()
        let runtimeKind = cachedCandidate.map { inferredRuntimeKind(from: $0) } ?? model.runtimeKind
        let thinkingLabel = cachedCandidate == nil ? "Current thinking" : "Detected thinking"

        AgentOutput.standardError.writeString(
            """

            Configured model: \(model.id)
            Repository: \(model.repositoryID)
            Model context limit: \(contextLimitSummary(modelContextLimit))
            Current parameters: \(generationDefaultsSummary(effectiveDefaults))
            \(thinkingLabel): \(thinkingSummary(detectedThinking))

            """
        )

        guard try promptYesNo(
            "Edit parameters for \(model.id)?",
            defaultValue: false
        ) else {
            return model
        }

        let id = try promptString(
            "Model ID exposed by the server",
            defaultValue: model.id,
            allowEmpty: false
        )
        let generationDefaults = try configureGenerationDefaults(
            effectiveDefaults,
            modelContextLimit: modelContextLimit
        )

        return try MLXServerModelRecord(
            id: id,
            displayName: repositoryDisplayName(model.repositoryID),
            repositoryID: model.repositoryID,
            revision: model.revision,
            runtimeKind: runtimeKind,
            enabled: model.enabled,
            generationDefaults: generationDefaults,
            thinking: detectedThinking
        ).validated()
    }

    static func configureModelRecord(
        repositoryID: String,
        revision: String,
        snapshotURL: URL,
        defaultRuntimeKind: MLXServerModelRuntimeKind,
        promptForParameters: Bool = true
    ) throws -> ConfiguredModelRecord {
        let importedDefaults = MLXServerModelParameterImporter.importDefaults(from: snapshotURL)
        let modelContextLimit = importedDefaults.contextWindow
        let proposedDefaults = setupDefaults(
            from: importedDefaults,
            modelContextLimit: modelContextLimit
        )
        let importedThinking = MLXServerModelParameterImporter.importThinking(
            from: snapshotURL,
            repositoryID: repositoryID
        ).validated()

        AgentOutput.standardError.writeString(
            """

            Model: \(repositoryID)
            Model context limit: \(contextLimitSummary(modelContextLimit))
            Proposed parameters: \(generationDefaultsSummary(proposedDefaults))
            Detected thinking: \(thinkingSummary(importedThinking))

            """
        )

        let shouldConfigureParameters = promptForParameters
            ? try promptYesNo(
                "Edit parameters for \(repositoryID)?",
                defaultValue: false
            )
            : false

        let id: String
        let generationDefaults: MLXServerModelGenerationDefaults
        if shouldConfigureParameters {
            id = try promptString(
                "Model ID exposed by the server",
                defaultValue: repositoryID,
                allowEmpty: false
            )
            generationDefaults = try configureGenerationDefaults(
                proposedDefaults,
                modelContextLimit: modelContextLimit
            )
        } else {
            id = repositoryID
            generationDefaults = proposedDefaults.validated()
        }

        let record = try MLXServerModelRecord(
            id: id,
            displayName: repositoryDisplayName(repositoryID),
            repositoryID: repositoryID,
            revision: revision,
            runtimeKind: defaultRuntimeKind,
            enabled: true,
            generationDefaults: generationDefaults,
            thinking: importedThinking
        ).validated()

        return ConfiguredModelRecord(
            record: record
        )
    }

}
