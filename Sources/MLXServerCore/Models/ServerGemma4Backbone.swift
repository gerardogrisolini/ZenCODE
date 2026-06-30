//
//  ServerGemma4Backbone.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// MARK: - Backbone

final class ServerGemma4Backbone: Module {
    let config: ServerGemma4TextConfiguration
    let firstKVSharedLayerIdx: Int
    let layerIdxToCacheIdx: [Int]
    let firstFullCacheIdx: Int
    let firstSlidingCacheIdx: Int
    let embedScale: Float
    let embedTokensPerLayerScale: Float
    let perLayerProjectionScale: Float
    private let _perLayerInputScale: MLXArray

    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "layers") var layers: [ServerGemma4DecoderLayer]
    @ModuleInfo(key: "norm") var norm: ServerGemma4RMSNorm
    @ModuleInfo(key: "embed_tokens_per_layer") var embedTokensPerLayer: Embedding?
    @ModuleInfo(key: "per_layer_model_projection") var perLayerModelProjection: Linear?
    @ModuleInfo(key: "per_layer_projection_norm") var perLayerProjectionNorm: ServerGemma4RMSNorm?

    init(_ config: ServerGemma4TextConfiguration) {
        self.config = config
        self.firstKVSharedLayerIdx = config.hiddenLayers - config.numKVSharedLayers
        self.embedScale = pow(Float(config.hiddenSize), 0.5)
        self.embedTokensPerLayerScale = pow(Float(max(config.hiddenSizePerLayerInput, 1)), 0.5)
        self._perLayerInputScale = rsqrt(MLXArray(2.0))

        let concreteLayers = Array(config.layerTypes.prefix(firstKVSharedLayerIdx))
        let sharedFullIdx = concreteLayers.lastIndex(of: "full_attention") ?? 0
        let sharedSlidingIdx = concreteLayers.lastIndex(of: "sliding_attention") ?? 0

        var cacheMap: [Int] = []
        cacheMap.reserveCapacity(config.hiddenLayers)
        for (idx, layerType) in config.layerTypes.enumerated() {
            if idx < firstKVSharedLayerIdx {
                cacheMap.append(idx)
            } else {
                cacheMap.append(layerType == "full_attention" ? sharedFullIdx : sharedSlidingIdx)
            }
        }
        layerIdxToCacheIdx = cacheMap
        firstFullCacheIdx = concreteLayers.firstIndex(of: "full_attention") ?? 0
        firstSlidingCacheIdx = concreteLayers.firstIndex(of: "sliding_attention") ?? 0

        self._embedTokens.wrappedValue = Embedding(
            embeddingCount: config.vocabularySize, dimensions: config.hiddenSize)
        self._layers.wrappedValue = (0 ..< config.hiddenLayers).map {
            ServerGemma4DecoderLayer(config: config, layerIdx: $0)
        }
        self._norm.wrappedValue = ServerGemma4RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)
        if config.hiddenSizePerLayerInput > 0 {
            self.perLayerProjectionScale = pow(Float(config.hiddenSize), -0.5)
            self._embedTokensPerLayer.wrappedValue = Embedding(
                embeddingCount: config.vocabularySizePerLayerInput,
                dimensions: config.hiddenLayers * config.hiddenSizePerLayerInput
            )
            self._perLayerModelProjection.wrappedValue = Linear(
                config.hiddenSize,
                config.hiddenLayers * config.hiddenSizePerLayerInput,
                bias: false
            )
            self._perLayerProjectionNorm.wrappedValue = ServerGemma4RMSNorm(
                dimensions: config.hiddenSizePerLayerInput, eps: config.rmsNormEps)
        } else {
            self.perLayerProjectionScale = 1.0
        }

        super.init()
    }

    func getPerLayerInputs(_ inputIds: MLXArray) -> MLXArray {
        guard let embedTokensPerLayer else {
            fatalError("Per-layer inputs requested for a model without embed_tokens_per_layer")
        }
        let validMask =
            logicalAnd(
                inputIds .>= 0, inputIds .< config.vocabularySizePerLayerInput)
        let tokens = MLX.where(validMask, inputIds, MLXArray.zeros(like: inputIds))
        var result = embedTokensPerLayer(tokens)
        result = (result * MLXArray(embedTokensPerLayerScale, dtype: .float32)).asType(result.dtype)
        return result.reshaped(
            Array(inputIds.shape) + [config.hiddenLayers, config.hiddenSizePerLayerInput]
        )
    }

    func projectPerLayerInputs(
        _ inputsEmbeds: MLXArray, perLayerInputs: MLXArray?
    ) -> MLXArray? {
        guard let perLayerModelProjection, let perLayerProjectionNorm else {
            return nil
        }

        var perLayerProjection = perLayerModelProjection(inputsEmbeds) * perLayerProjectionScale
        perLayerProjection = perLayerProjection.reshaped(
            Array(inputsEmbeds.shape.dropLast()) + [
                config.hiddenLayers, config.hiddenSizePerLayerInput,
            ]
        )
        perLayerProjection = perLayerProjectionNorm(perLayerProjection)

        guard let perLayerInputs else {
            return perLayerProjection
        }

        return (perLayerProjection + perLayerInputs)
            * _perLayerInputScale.asType(inputsEmbeds.dtype)
    }

    func callAsFunction(
        _ inputs: MLXArray,
        cache: [KVCache]? = nil
    ) -> MLXArray {
        // Tolerate 1D `(L,)` token arrays by expanding to `(B, L)`.
        let inputs = inputs.ndim == 1 ? inputs.expandedDimensions(axis: 0) : inputs

        let embeddings = embedTokens(inputs)
        let h0 = (embeddings * MLXArray(embedScale, dtype: .float32)).asType(embeddings.dtype)

        let processedPerLayerInputs: MLXArray? =
            config.hiddenSizePerLayerInput > 0 ? getPerLayerInputs(inputs) : nil
        let finalPerLayerInputs = projectPerLayerInputs(
            h0, perLayerInputs: processedPerLayerInputs)

        let localCache: [KVCache?] =
            cache.map { $0.map { Optional($0) } }
            ?? Array(repeating: nil as KVCache?, count: max(firstKVSharedLayerIdx, 1))

        let fullMask = createAttentionMask(
            h: h0,
            cache: firstFullCacheIdx < localCache.count ? localCache[firstFullCacheIdx] : nil)
        let slidingMask = createAttentionMask(
            h: h0,
            cache: firstSlidingCacheIdx < localCache.count ? localCache[firstSlidingCacheIdx] : nil,
            windowSize: config.slidingWindow
        )

        var h = h0
        var intermediates = [(kv: ServerGemma4SharedKVState?, offset: Int?)](
            repeating: (nil, nil), count: config.hiddenLayers)
        for (idx, layer) in layers.enumerated() {
            let sourceIdx = layerIdxToCacheIdx[idx]
            let layerCache: KVCache? =
                if idx < firstKVSharedLayerIdx, sourceIdx < localCache.count {
                    localCache[sourceIdx]
                } else {
                    nil
                }
            let layerMask =
                layer.layerType == "full_attention" ? fullMask : slidingMask
            let layerInput: MLXArray? =
                if let finalPerLayerInputs {
                    finalPerLayerInputs[0..., 0..., idx, 0...]
                } else {
                    nil
                }
            let (output, kvState, attentionOffset) = layer(
                h,
                mask: layerMask,
                cache: layerCache,
                perLayerInput: layerInput,
                sharedKV: idx >= firstKVSharedLayerIdx
                    ? intermediates[sourceIdx].kv : nil,
                offset: idx >= firstKVSharedLayerIdx
                    ? intermediates[sourceIdx].offset : nil
            )
            h = output
            intermediates[idx] = (kvState, attentionOffset)
        }
        return norm(h)
    }
}

