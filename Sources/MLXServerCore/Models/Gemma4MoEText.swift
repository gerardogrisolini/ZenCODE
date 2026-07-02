//
//  Gemma4MoEText.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// MARK: - Registration

public enum ServerGemma4ModelRegistration {
    /// Replaces the default dense-only `gemma4`/`gemma4_text` creators on
    /// `LLMTypeRegistry.shared` with this MoE-capable implementation. Idempotent.
    public static func registerIfNeeded() async {
        await LLMTypeRegistry.shared.registerModelType("gemma4") { data in
            let configuration = try JSONDecoder.json5().decode(
                ServerGemma4Configuration.self, from: data)
            return ServerGemma4Model(configuration)
        }
        await LLMTypeRegistry.shared.registerModelType("gemma4_text") { data in
            let configuration = try JSONDecoder.json5().decode(
                ServerGemma4TextConfiguration.self, from: data)
            return ServerGemma4TextModel(configuration)
        }
    }
}
