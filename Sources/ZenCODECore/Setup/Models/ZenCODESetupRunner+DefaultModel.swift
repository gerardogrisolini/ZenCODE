//
//  ZenCODESetupRunner+DefaultModel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import ZenCODERuntime

extension ZenCODESetupRunner {
    static func setupDefaultThinkingSelection(
        for model: AgentSettingsModelManifest?,
        existingSelection: AgentThinkingSelection?
    ) -> AgentThinkingSelection? {
        model?.thinkingSelection(for: existingSelection)
    }
}
