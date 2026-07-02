//
//  MLXServerRuntime+ModelContainers.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

extension MLXServerRuntime {
    public func preloadModel(
        model: MLXServerModelDescriptor,
        runtimeKind: MLXServerModelRuntimeKind? = nil,
        parameters: GenerateParameters,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
        let generationLease = try await generationGates.acquire(modelID: model.id)
        do {
            _ = try await container(
                for: model,
                runtimeKind: runtimeKind ?? model.runtimeKind,
                parameters: parameters,
                progressHandler: progressHandler
            )
            await generationLease.release()
        } catch {
            await generationLease.release()
            throw error
        }
    }

    public func unloadAll() async {
        guard let generationLeases = try? await generationGates.acquireAll() else {
            return
        }
        let unloadedModelIDs = Set(containers.keys.map(\.modelID)).sorted()
        for loadingTask in loadingTasks.values {
            loadingTask.task.cancel()
        }
        containers.removeAll(keepingCapacity: true)
        loadingTasks.removeAll(keepingCapacity: true)
        chatSessions.removeAll(keepingCapacity: true)
        logUnloadedModels(unloadedModelIDs)
        await generationLeases.releaseAll()
    }

    // MARK: - Model containers

    func container(
        for model: MLXServerModelDescriptor,
        runtimeKind: MLXServerModelRuntimeKind,
        parameters: GenerateParameters,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> ModelContainer {
        let key = LoadedModelKey(modelID: model.id, runtimeKind: runtimeKind)
        if let container = containers[key] {
            return container
        }

        if let loadingTask = loadingTasks[key] {
            let container = try await loadingTask.task.value
            guard containers[key] != nil || loadingTasks[key]?.id == loadingTask.id else {
                throw CancellationError()
            }
            return container
        }

        unloadOtherModelsBeforeLoading(key)

        let task = Task {
            try await MLXServerModelLoading.loadContainer(
                configuration: model.configuration,
                runtimeKind: runtimeKind,
                progressHandler: progressHandler
            )
        }
        let loadingTask = ModelLoadingTask(id: UUID(), task: task)
        loadingTasks[key] = loadingTask

        do {
            let container = try await task.value
            guard loadingTasks[key]?.id == loadingTask.id else {
                throw CancellationError()
            }
            loadingTasks[key] = nil
            containers[key] = container
            modelLoadLogger?(
                MLXServerModelLoadEvent(
                    model: model,
                    runtimeKind: runtimeKind,
                    parameters: parameters
                )
            )
            return container
        } catch {
            if loadingTasks[key]?.id == loadingTask.id {
                loadingTasks[key] = nil
            }
            throw error
        }
    }

    func unloadOtherModelsBeforeLoading(_ key: LoadedModelKey) {
        let unloadedModelIDs = Set(containers.keys.filter { $0 != key }.map(\.modelID)).sorted()
        containers = containers.filter { $0.key == key }
        chatSessions = chatSessions.filter { $0.key.modelID == key.modelID }
        for (loadingKey, loadingTask) in loadingTasks where loadingKey != key {
            loadingTask.task.cancel()
        }
        loadingTasks = loadingTasks.filter { $0.key == key }
        logUnloadedModels(unloadedModelIDs)
    }

    func logUnloadedModels(_ modelIDs: [String]) {
        for modelID in modelIDs {
            modelUnloadLogger?(MLXServerModelUnloadEvent(modelID: modelID))
        }
    }
}
