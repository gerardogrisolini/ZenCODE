//
//  ZenCODEAgentProfileSetupRunner+Support.swift
//  ZenCODE
//

import Foundation
import ZenCODECore

extension ZenCODEAgentProfileSetupRunner {
    static func printAgents(_ agents: [AgentProfile]) {
        for (index, agent) in agents.enumerated() {
                    AgentOutput.standardError.writeString(
                "  \(index + 1). \(agent.displayName) [\(agentSummary(agent))]\n"
            )
        }
    }

    static func agentSummary(_ agent: AgentProfile) -> String {
        let tools = agent.tools.isEmpty ? "no tools" : agent.tools.joined(separator: ", ")
        let skills = agent.skills.isEmpty ? "" : " | skills: \(skillList(agent.skills))"
        let model = agent.modelID.map { " | model: \($0)" } ?? ""
        let thinking = agent.thinkingSelection.map { " | thinking: \($0.displayTitle)" } ?? ""
        return "\(tools)\(skills)\(model)\(thinking)"
    }


    static func uniqueAgents(_ agents: [AgentProfile]) -> [AgentProfile] {
        var seen = Set<String>()
        var result: [AgentProfile] = []
        for agent in agents {
            let key = agentSetupNameKey(agent.name)
            guard seen.insert(key).inserted else {
                continue
            }
            result.append(agent)
        }
        return result
    }

        static func ensureRequiredDefaultAgents(in agents: [AgentProfile]) -> [AgentProfile] {
        var result = agents
        let defaults = AgentProfileStore.defaultProfiles()
        for defaultAgent in defaults where requiredDefaultAgentNames.contains(agentSetupNameKey(defaultAgent.name)) {
            guard !containsAgent(named: defaultAgent.name, in: result) else {
                continue
            }
            result.insert(defaultAgent, at: requiredDefaultAgentInsertIndex(for: defaultAgent, in: result))
        }
        return result
    }

    static var requiredDefaultAgentNames: Set<String> {
                Set([
            AgentProfileStore.defaultAgentName,
            AgentProfileStore.builderAgentName,
            "Minimal",
            AgentProfileStore.xcodeAgentName,
            AgentProfileStore.reviewerAgentName,
            AgentProfileStore.plannerAgentName
        ].map(agentSetupNameKey))
    }

    static func requiredDefaultAgentInsertIndex(
        for defaultAgent: AgentProfile,
        in agents: [AgentProfile]
    ) -> Int {
        let preferredOrder = AgentProfileStore.defaultProfiles().map { agentSetupNameKey($0.name) }
        let defaultAgentOrder = preferredOrder.firstIndex(of: agentSetupNameKey(defaultAgent.name)) ?? 0
        return agents.firstIndex { agent in
            let agentOrder = preferredOrder.firstIndex(of: agentSetupNameKey(agent.name)) ?? Int.max
            return agentOrder > defaultAgentOrder
        } ?? agents.count
    }

    static func containsAgent(named name: String, in agents: [AgentProfile]) -> Bool {
        let expectedKey = agentSetupNameKey(name)
        return agents.contains { agentSetupNameKey($0.name) == expectedKey }
    }

    static func agentSetupNameKey(_ name: String) -> String {
        name.agentSetupKey
    }

    static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool
    ) throws -> String {
        guard let value = TerminalCheckboxMenu.promptLine(
            title: "ZenCODE agents setup",
            prompt: prompt,
            defaultValue: defaultValue,
            allowEmpty: allowEmpty
        ) else {
            throw ZenCODEAgentProfileSetupError.inputClosed
        }
        return value
    }

    static func promptYesNo(
        _ prompt: String,
        defaultValue: Bool
    ) throws -> Bool {
        let items = [
            TerminalCheckboxMenuItem(value: true, title: "Yes", detail: nil),
            TerminalCheckboxMenuItem(value: false, title: "No", detail: nil)
        ]
        return TerminalCheckboxMenu.selectOne(
            title: prompt,
            items: items,
            selected: defaultValue
        ) ?? defaultValue
    }


    static func skillList(_ skills: [AgentProfileSkill]) -> String {
        skills.map(\.id).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func truncatedInline(_ value: String, limit: Int) -> String {
        let inline = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inline.count > limit else {
            return inline
        }
        return String(inline.prefix(max(0, limit - 3))) + "..."
    }
}


enum ZenCODEAgentProfileSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed
    case unableToCreateGlobalAgents(URL)
    case instructionEditorLaunchFailed(String, String)
    case instructionEditorFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "ZenCODE agents setup requires an interactive terminal."
        case .inputClosed:
            return "Input closed during ZenCODE agents setup."
        case let .unableToCreateGlobalAgents(url):
            return "Unable to create global AGENTS.md at \(url.path)."
        case let .instructionEditorLaunchFailed(editor, reason):
            return "Unable to launch text editor '\(editor)': \(reason)"
        case let .instructionEditorFailed(editor, status):
            return "Text editor '\(editor)' exited with status \(status)."
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var agentSetupKey: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

private extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}
