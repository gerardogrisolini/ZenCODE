//
//  ServerGemma4DecoderLayer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// MARK: - Decoder layer

final class ServerGemma4DecoderLayer: Module {
    let layerType: String
    let enableMoE: Bool

    @ModuleInfo(key: "self_attn") var selfAttention: ServerGemma4Attention
    @ModuleInfo var mlp: ServerGemma4MLP
    @ModuleInfo(key: "input_layernorm") var inputLayerNorm: ServerGemma4RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionLayerNorm: ServerGemma4RMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardLayerNorm: ServerGemma4RMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardLayerNorm: ServerGemma4RMSNorm
    @ModuleInfo(key: "router") var router: ServerGemma4Router?
    @ModuleInfo(key: "experts") var experts: ServerGemma4Experts?
    @ModuleInfo(key: "post_feedforward_layernorm_1") var postFeedforwardLayerNorm1:
        ServerGemma4RMSNorm?
    @ModuleInfo(key: "post_feedforward_layernorm_2") var postFeedforwardLayerNorm2:
        ServerGemma4RMSNorm?
    @ModuleInfo(key: "pre_feedforward_layernorm_2") var preFeedforwardLayerNorm2:
        ServerGemma4RMSNorm?
    @ModuleInfo(key: "per_layer_input_gate") var perLayerInputGate: Linear?
    @ModuleInfo(key: "per_layer_projection") var perLayerProjection: Linear?
    @ModuleInfo(key: "post_per_layer_input_norm") var postPerLayerInputNorm: ServerGemma4RMSNorm?
    @ModuleInfo(key: "layer_scalar") var layerScalar: MLXArray

    init(config: ServerGemma4TextConfiguration, layerIdx: Int) {
        self.layerType = config.layerTypes[layerIdx]
        self.enableMoE = config.enableMoEBlock
        self._selfAttention.wrappedValue = ServerGemma4Attention(
            config: config, layerIdx: layerIdx)
        self._mlp.wrappedValue = ServerGemma4MLP(config: config, layerIdx: layerIdx)
        self._inputLayerNorm.wrappedValue = ServerGemma4RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postAttentionLayerNorm.wrappedValue = ServerGemma4RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._preFeedforwardLayerNorm.wrappedValue = ServerGemma4RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)
        self._postFeedforwardLayerNorm.wrappedValue = ServerGemma4RMSNorm(
            dimensions: config.hiddenSize, eps: config.rmsNormEps)
        if config.enableMoEBlock {
            self._router.wrappedValue = ServerGemma4Router(config: config)
            self._experts.wrappedValue = ServerGemma4Experts(config: config)
            self._postFeedforwardLayerNorm1.wrappedValue = ServerGemma4RMSNorm(
                dimensions: config.hiddenSize, eps: config.rmsNormEps)
            self._postFeedforwardLayerNorm2.wrappedValue = ServerGemma4RMSNorm(
                dimensions: config.hiddenSize, eps: config.rmsNormEps)
            self._preFeedforwardLayerNorm2.wrappedValue = ServerGemma4RMSNorm(
                dimensions: config.hiddenSize, eps: config.rmsNormEps)
        }
        if config.hiddenSizePerLayerInput > 0 {
            self._perLayerInputGate.wrappedValue = Linear(
                config.hiddenSize, config.hiddenSizePerLayerInput, bias: false)
            self._perLayerProjection.wrappedValue = Linear(
                config.hiddenSizePerLayerInput, config.hiddenSize, bias: false)
            self._postPerLayerInputNorm.wrappedValue = ServerGemma4RMSNorm(
                dimensions: config.hiddenSize, eps: config.rmsNormEps)
        }
        self._layerScalar.wrappedValue = MLXArray.ones([1])
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray,
        mask: MLXFast.ScaledDotProductAttentionMaskMode = .none,
        cache: KVCache? = nil,
        perLayerInput: MLXArray? = nil,
        sharedKV: ServerGemma4SharedKVState? = nil,
        offset: Int? = nil
    ) -> (MLXArray, ServerGemma4SharedKVState?, Int) {
        var residual = x
        var h = inputLayerNorm(x)
        let (attentionOutput, kvState, attentionOffset) = selfAttention(
            h, mask: mask, cache: cache, sharedKV: sharedKV, offset: offset)
        h = attentionOutput
        h = postAttentionLayerNorm(h)
        h = residual + h

        residual = h
        if enableMoE,
            let router,
            let experts,
            let postFeedforwardLayerNorm1,
            let postFeedforwardLayerNorm2,
            let preFeedforwardLayerNorm2
        {
            var dense = preFeedforwardLayerNorm(h)
            dense = mlp(dense)
            dense = postFeedforwardLayerNorm1(dense)

            let (topKIndices, topKWeights) = router(h)
            var sparse = preFeedforwardLayerNorm2(h)
            sparse = experts(sparse, topKIndices: topKIndices, topKWeights: topKWeights)
            sparse = postFeedforwardLayerNorm2(sparse)

            h = dense + sparse
        } else {
            h = preFeedforwardLayerNorm(h)
            h = mlp(h)
        }
        h = postFeedforwardLayerNorm(h)
        h = residual + h

        if let perLayerInputGate, let perLayerProjection, let postPerLayerInputNorm,
            let perLayerInput
        {
            residual = h
            var gated = perLayerInputGate(h)
            gated = geluApproximate(gated)
            gated = gated * perLayerInput
            gated = perLayerProjection(gated)
            gated = postPerLayerInputNorm(gated)
            h = residual + gated
        }

        return (h * layerScalar, kvState, attentionOffset)
    }
}

