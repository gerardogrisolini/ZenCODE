//
//  ServerGemma4Models.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// MARK: - Text model

final class ServerGemma4TextModel: Module, LLMModel, KVCacheDimensionProvider {
    let config: ServerGemma4TextConfiguration
    let finalLogitSoftcapping: Float?

    @ModuleInfo(key: "model") var model: ServerGemma4Backbone
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    var vocabularySize: Int { config.vocabularySize }

    var kvHeads: [Int] {
        (0 ..< config.hiddenLayers).map { idx in
            let layerType = config.layerTypes[idx]
            if config.attentionKEqV && layerType == "full_attention" {
                return config.globalKVHeads ?? config.kvHeads
            } else {
                return config.kvHeads
            }
        }
    }

    init(_ config: ServerGemma4TextConfiguration) {
        self.config = config
        self.finalLogitSoftcapping = config.finalLogitSoftcapping
        self._model.wrappedValue = ServerGemma4Backbone(config)
        if !config.tieWordEmbeddings {
            self._lmHead.wrappedValue = Linear(
                config.hiddenSize, config.vocabularySize, bias: false)
        }
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let hidden = model(inputs, cache: cache)
        let logits: MLXArray
        if let lmHead {
            logits = lmHead(hidden)
        } else {
            logits = model.embedTokens.asLinear(hidden)
        }
        if let finalLogitSoftcapping, finalLogitSoftcapping > 0 {
            let scale = MLXArray(finalLogitSoftcapping)
            return tanh(logits / scale) * scale
        }
        return logits
    }

    func newCache(parameters: GenerateParameters?) -> [any KVCache] {
        let slidingWindow = config.slidingWindow > 0 ? config.slidingWindow : 4096
        return config.layerTypes.prefix(config.hiddenLayers - config.numKVSharedLayers).map {
            layerType in
            if layerType == "full_attention" {
                StandardKVCache()
            } else {
                RotatingKVCache(maxSize: slidingWindow, keep: 0)
            }
        }
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        ServerGemma4WeightSanitizer.sanitize(
            weights: weights,
            tieWordEmbeddings: config.tieWordEmbeddings,
            languageModelPrefixed: false
        )
    }

    var loraLayers: [Module] {
        model.layers.map { $0.selfAttention }
    }
}

// MARK: - "gemma4" wrapper model

final class ServerGemma4Model: Module, LLMModel, KVCacheDimensionProvider {
    @ModuleInfo(key: "language_model") var languageModel: ServerGemma4TextModel

    var vocabularySize: Int { languageModel.vocabularySize }
    var kvHeads: [Int] { languageModel.kvHeads }

    init(_ config: ServerGemma4Configuration) {
        self._languageModel.wrappedValue = ServerGemma4TextModel(config.textConfiguration)
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        languageModel(inputs, cache: cache)
    }

    func newCache(parameters: GenerateParameters?) -> [any KVCache] {
        languageModel.newCache(parameters: parameters)
    }

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        ServerGemma4WeightSanitizer.sanitize(
            weights: weights,
            tieWordEmbeddings: languageModel.config.tieWordEmbeddings,
            languageModelPrefixed: true
        )
    }

    var loraLayers: [Module] {
        languageModel.loraLayers
    }
}

