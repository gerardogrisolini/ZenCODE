//
//  MLXServerModelSetupRunner+CachedModels.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import HuggingFace
import ZenCODECore
import MLXServerCore

extension MLXServerModelSetupRunner {
    @discardableResult
    static func importCachedModelsIfRequested(into manifest: inout MLXServerModelsManifest) throws -> Int {
        let candidates = MLXServerCachedModelScanner.candidates(
            cache: MLXServerHuggingFaceCacheAccessStore.cache
        )
        guard !candidates.isEmpty else {
            return 0
        }
        let importableCandidates = importableCachedCandidates(
            from: candidates,
            excludingConfiguredModels: manifest.models
        )
        guard !importableCandidates.isEmpty else {
            AgentOutput.standardError.writeString(
                "Downloaded models are already configured in models.json.\n\n"
            )
            return 0
        }

        AgentOutput.standardError.writeString(
            """
            Found downloaded models in the Hugging Face cache that are not configured yet:

            """
        )
        for (index, candidate) in importableCandidates.enumerated() {
            AgentOutput.standardError.writeString(
                "\(index + 1). \(candidate.repositoryID) [\(candidate.revision)]\n"
            )
        }
        AgentOutput.standardError.writeString("\n")

        guard try promptYesNo(
            "Import them into models.json?",
            defaultValue: true
        ) else {
            return 0
        }

        return try importCachedModels(importableCandidates, into: &manifest)
    }

    static func importCachedModels(
        _ candidates: [MLXServerCachedModelCandidate],
        into manifest: inout MLXServerModelsManifest
    ) throws -> Int {
        var importedCount = 0
        for candidate in candidates {
            let configuredModel = try configureCachedModel(
                candidate,
                promptForParameters: false
            )
            upsert(record: configuredModel.record, in: &manifest)
            try updateDefaultModel(
                afterAdding: configuredModel.record,
                in: &manifest
            )
            importedCount += 1
        }
        return importedCount
    }

    static func importableCachedCandidates(
        from candidates: [MLXServerCachedModelCandidate],
        excludingConfiguredModels configuredModels: [MLXServerModelRecord]
    ) -> [MLXServerCachedModelCandidate] {
        candidates.filter { candidate in
            !configuredModels.contains { model in
                model.repositoryID == candidate.repositoryID
                    && model.revision == candidate.revision
            }
        }
    }

    static func cachedCandidate(
        forRepositoryID repositoryID: String,
        revision: String,
        in candidates: [MLXServerCachedModelCandidate]
    ) -> MLXServerCachedModelCandidate? {
        candidates.first {
            $0.repositoryID == repositoryID && $0.revision == revision
        } ?? candidates.first {
            $0.repositoryID == repositoryID
        }
    }

    static func deleteRejectedCachedModelIfRequested(
        _ candidate: MLXServerCachedModelCandidate
    ) throws {
        guard try promptYesNo(
            "Delete \(candidate.repositoryID) [\(candidate.revision)] from the Hugging Face cache?",
            defaultValue: false
        ) else {
            return
        }

        try removeCachedRepository(repositoryID: candidate.repositoryID)
    }

    static func deleteRejectedCachedModelsIfRequested(
        _ candidates: [MLXServerCachedModelCandidate]
    ) throws {
        for candidate in candidates {
            try deleteRejectedCachedModelIfRequested(candidate)
        }
    }

    static func refreshExistingModelRuntimeKinds(in manifest: inout MLXServerModelsManifest) {
        let candidates = MLXServerCachedModelScanner.candidates(
            cache: MLXServerHuggingFaceCacheAccessStore.cache
        )
        for modelIndex in manifest.models.indices {
            let repositoryID = manifest.models[modelIndex].repositoryID
            let revision = manifest.models[modelIndex].revision
            guard let candidate = candidates.first(where: {
                $0.repositoryID == repositoryID && $0.revision == revision
            }) else {
                continue
            }
            manifest.models[modelIndex].runtimeKind = inferredRuntimeKind(from: candidate)
        }
    }

    static func inferredRuntimeKind(from candidate: MLXServerCachedModelCandidate) -> MLXServerModelRuntimeKind {
        inferredRuntimeKind(
            fromSnapshot: candidate.snapshotURL,
            fallback: inferredRuntimeKind(fromRepositoryID: candidate.repositoryID)
        )
    }

    static func cachedCandidate(
        for model: MLXServerModelRecord,
        in candidates: [MLXServerCachedModelCandidate]
    ) -> MLXServerCachedModelCandidate? {
        candidates.first {
            $0.repositoryID == model.repositoryID && $0.revision == model.revision
        } ?? candidates.first {
            $0.repositoryID == model.repositoryID
        }
    }

    static func hasVisionProcessorFiles(in snapshotURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: snapshotURL.appendingPathComponent("preprocessor_config.json").path
        )
            || FileManager.default.fileExists(
                atPath: snapshotURL.appendingPathComponent("image_processor_config.json").path
            )
            || FileManager.default.fileExists(
                atPath: snapshotURL.appendingPathComponent("processor_config.json").path
            )
    }
}
