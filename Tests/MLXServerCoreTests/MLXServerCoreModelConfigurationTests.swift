//
//  MLXServerCoreTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Testing
@testable import MLXServerCore
import Foundation
import MLXLMCommon
import os

@Test
func chatSessionAdditionalContextSignatureIsStableAcrossDictionaryOrder() {
    let first: [String: any Sendable] = [
        "b": 2,
        "a": true
    ]
    let second: [String: any Sendable] = [
        "a": true,
        "b": 2
    ]

    #expect(
        MLXServerChatSessionRequestSignature.additionalContext(first)
            == MLXServerChatSessionRequestSignature.additionalContext(second)
    )
}

@Test
func savesAndLoadsModelsJSON() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-models-\(UUID().uuidString)", isDirectory: true)
    let modelsURL = directory.appendingPathComponent("models.json")
    defer {
        try? FileManager.default.removeItem(at: directory)
    }

    let manifest = MLXServerModelsManifest(
        defaultModelID: "mlx-community/test-model",
        models: [
            MLXServerModelRecord(
                id: "mlx-community/test-model",
                displayName: "Test Model",
                repositoryID: "mlx-community/test-model",
                revision: "main",
                runtimeKind: .llm,
                generationDefaults: MLXServerModelGenerationDefaults(
                    contextWindow: 262_144,
                    maxOutputTokens: 4_096,
                    temperature: 0.2,
                    topP: 0.9,
                    topK: 40,
                    repetitionPenalty: 1.1,
                    presencePenalty: 0.1,
                    frequencyPenalty: 0.2
                ),
                thinking: .effort(
                    levels: [.low, .medium, .high],
                    supportsPreserveThinking: true
                )
            )
        ]
    )

    try MLXServerModelsManifestStore.save(manifest, to: modelsURL)
    let loaded = try MLXServerModelsManifestStore.loadRequired(from: modelsURL)
    let catalog = try loaded.catalog
    let model = try catalog.resolve(id: nil)

    #expect(catalog.defaultModelID == "mlx-community/test-model")
    #expect(model.id == "mlx-community/test-model")
    #expect(model.displayName == "Test Model")
    #expect(model.configuration.name == "mlx-community/test-model")
    #expect(model.generationDefaults.contextWindow == 262_144)
    #expect(model.generationDefaults.maxOutputTokens == 4_096)
    #expect(model.generationDefaults.temperature == 0.2)
    #expect(model.generationDefaults.topP == 0.9)
    #expect(model.generationDefaults.topK == 40)
    #expect(model.generationDefaults.repetitionPenalty == 1.1)
    #expect(model.generationDefaults.presencePenalty == 0.1)
    #expect(model.generationDefaults.frequencyPenalty == 0.2)
    #expect(model.thinking.supportsThinking)
    #expect(model.thinking.supportsReasoningEffort)
    #expect(model.thinking.supportsPreserveThinking)
    #expect(model.thinking.availableSelections == [.off, .low, .medium, .high])
    #expect(model.thinking.defaultSelection == .medium)
}

@Test
func missingModelsReportsSetupInstruction() {
    let modelsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString)")
        .appendingPathComponent("models.json")

    #expect(throws: MLXServerModelsManifestError.missingModels(modelsURL)) {
        try MLXServerModelsManifestStore.loadRequired(from: modelsURL)
    }
}

@Test
func rejectsUnconfiguredModelID() throws {
    let catalog = try MLXServerModelCatalog(
        manifest: MLXServerModelsManifest(
            models: [
                MLXServerModelRecord(
                    id: "mlx-community/test-model",
                    displayName: "Test Model",
                    repositoryID: "mlx-community/test-model"
                )
            ]
        )
    )

    #expect(throws: MLXServerModelsManifestError.modelNotConfigured("other-model")) {
        try catalog.resolve(id: "other-model")
    }
}

@Test
func buildsGenerationRequestWithConfiguredModel() {
    let request = MLXServerGenerationRequest(
        model: testModel(),
        messages: [
            .system("You are concise."),
            .user("ciao")
        ]
    )

    #expect(request.model.id == "mlx-community/test-model")
    #expect(request.messages.count == 2)
    #expect(request.runtimeKind == .llm)
}

@Test
func appliesModelGenerationDefaults() {
    let defaults = MLXServerModelGenerationDefaults(
        maxOutputTokens: 1_024,
        temperature: 0.3,
        topP: 0.8,
        topK: 20,
        repetitionPenalty: 1.1,
        presencePenalty: 0.4,
        frequencyPenalty: 0.5
    )
    let parameters = defaults.generateParameters()

    #expect(parameters.maxTokens == 1_024)
    #expect(parameters.temperature == 0.3)
    #expect(parameters.topP == 0.8)
    #expect(parameters.topK == 20)
    #expect(parameters.repetitionPenalty == 1.1)
    #expect(parameters.presencePenalty == 0.4)
    #expect(parameters.frequencyPenalty == 0.5)
}

@Test
func maxTokensCanOverrideModelDefaultOutputLimit() {
    let defaults = MLXServerModelGenerationDefaults(
        maxOutputTokens: 1_024,
        temperature: 0.3,
        topP: 0.8,
        topK: 20,
        repetitionPenalty: 1.1,
        presencePenalty: 0.4,
        frequencyPenalty: 0.5
    )
    let parameters = defaults.generateParameters(
        maxTokens: 128
    )

    #expect(parameters.maxTokens == 128)
    #expect(parameters.temperature == 0.3)
    #expect(parameters.topP == 0.8)
    #expect(parameters.topK == 20)
    #expect(parameters.repetitionPenalty == 1.1)
    #expect(parameters.presencePenalty == 0.4)
    #expect(parameters.frequencyPenalty == 0.5)
}

@Test
func modelThinkingConfigurationNormalizesEffortLevels() {
    let configuration = MLXServerModelThinkingConfiguration(
        supportsThinking: true,
        supportsReasoningEffort: true,
        supportsPreserveThinking: false,
        availableSelections: [.off, .high, .low, .enabled],
        defaultSelection: .xhigh
    )
    .validated()

    #expect(configuration.availableSelections == [.off, .low, .high])
    #expect(configuration.defaultSelection == .low)
    #expect(configuration.selection(for: "high") == .high)
    #expect(configuration.selection(for: "none") == .off)
}

@Test
func modelThinkingConfigurationFallsBackToGenericEnable() {
    let configuration = MLXServerModelThinkingConfiguration.generic

    #expect(configuration.selection(for: "high") == .enabled)
    #expect(configuration.selection(for: nil) == .off)
    #expect(configuration.additionalContext(for: .enabled)["enable_thinking"] as? Bool == true)
}

@Test
func selectsVLMRuntimeWhenMediaIsAttached() throws {
    let imageURL = try #require(URL(string: "https://example.com/image.png"))
    let request = MLXServerGenerationRequest(
        model: testModel(),
        messages: [
            .user("Describe this image.", imageURLs: [imageURL])
        ]
    )

    #expect(request.requiresVisionRuntime)
    #expect(request.runtimeKind == .vlm)
}

