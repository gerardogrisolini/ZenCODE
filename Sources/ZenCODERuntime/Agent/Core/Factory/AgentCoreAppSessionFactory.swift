//
//  AgentCoreAppSessionFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import ToolCore

public enum AgentCoreAppSessionFactory {
    public static func resolvedPromptSections(
        providedSystemPrompt: String?,
        cwd: String,
        selectedAgent: AgentProfile?,
        allowedToolNames: Set<String>?
    ) -> SystemPromptSections {
        if let providedSystemPrompt = providedSystemPrompt?.nilIfBlank {
            return AgentSessionComposition.appProvidedPromptSections(
                providedSystemPrompt,
                cwd: cwd,
                allowedToolNames: allowedToolNames,
                selectedAgent: selectedAgent
            )
        }

        return AgentSessionComposition.standardPromptSections(
            cwd: cwd,
            allowedToolNames: allowedToolNames,
            selectedAgent: selectedAgent
        )
    }
}
