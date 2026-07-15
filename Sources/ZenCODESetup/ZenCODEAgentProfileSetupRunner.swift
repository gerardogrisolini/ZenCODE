//
//  ZenCODEAgentProfileSetupRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//

import Foundation
import ZenCODECore

public enum ZenCODEAgentProfileSetupRunner {
    struct AgentSetupModelSelection {
        let modelID: String
        let modelProvider: String?
        let thinkingSelection: AgentThinkingSelection?
    }

    enum AgentSetupModelChoice: Hashable {
        case noDedicatedModel
        case configuredModel(String)
    }

    struct AgentInstructionEditorCommand: Equatable {
        let executable: String
        let arguments: [String]

        var displayText: String {
            ([executable] + arguments).joined(separator: " ")
        }
    }

    enum AgentInstructionsEditChoice: Hashable {
        case keep
        case editInEditor
    }

    public static func configureInteractively() throws {
        guard TerminalRawInput.supportsInteractiveInput() else {
            throw ZenCODEAgentProfileSetupError.nonInteractiveTerminal
        }

        let globalAgentsResult = try ensureGlobalAgentsFile()
        let manifestURL = AgentProfileStore.agentsManifestURL()
        AgentOutput.standardError.writeString(
            """
            ZenCODE agents setup
            Global AGENTS.md:
            \(globalAgentsResult.url.path)
            \(globalAgentsResult.created ? "Created" : "Preserved"): AGENTS.md

            Configuring agents.json at:
            \(manifestURL.path)

            """
        )

        let existingAgents = try loadExistingAgentsIfPresent(at: manifestURL)
        var agents = try initialAgents(existingAgents: existingAgents)

        if try promptYesNo("Edit the agent list?", defaultValue: false) {
            agents = try editAgents(agents)
        }

        let normalizedAgents = preparedAgentsForSave(agents)
        try AgentProfileStore.save(normalizedAgents)
        AgentOutput.standardError.writeString(
            "\nUpdated: agents.json (\(normalizedAgents.count) agents)\n\n"
        )
    }

    private static func ensureGlobalAgentsFile() throws -> (url: URL, created: Bool) {
        let service = AgentsContextService()
        let url = service.globalAgentsFileURL()
        let existedBefore = FileManager.default.fileExists(atPath: url.path)
        guard let ensuredURL = service.ensureGlobalAgentsFileExists() else {
            throw ZenCODEAgentProfileSetupError.unableToCreateGlobalAgents(url)
        }
        return (ensuredURL, !existedBefore)
    }

    private static func loadExistingAgentsIfPresent(at url: URL) throws -> [AgentProfile]? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            let agents = try AgentProfileStore.loadRequired()
            AgentOutput.standardError.writeString("Configured agents:\n")
            printAgents(agents)
            AgentOutput.standardError.writeString("\n")
            return agents
        } catch {
            let shouldOverwrite = try promptYesNo(
                "agents.json exists but is invalid. Rewrite it?",
                defaultValue: true
            )
            guard shouldOverwrite else {
                throw error
            }
            return nil
        }
    }

    private static func initialAgents(existingAgents: [AgentProfile]?) throws -> [AgentProfile] {
        if let existingAgents {
            let useRecommended = try promptYesNo(
                "Regenerate the \(recommendedAgentCount) recommended agents?",
                defaultValue: false
            )
            return useRecommended ? AgentProfileStore.defaultProfiles() : existingAgents
        }

        let useRecommended = try promptYesNo(
            "Create the \(recommendedAgentCount) recommended agents?",
            defaultValue: true
        )
        guard !useRecommended else {
            return AgentProfileStore.defaultProfiles()
        }

        return try readCustomAgents()
    }

    static var recommendedAgentCount: Int {
        AgentProfileStore.defaultProfiles().count
    }

    static func preparedAgentsForSave(_ agents: [AgentProfile]) -> [AgentProfile] {
                AgentProfileStore.normalizedAgentsForSave(
            ensureRequiredDefaultAgents(
                in: uniqueAgents(agents)
            )
        )
    }

    private static func readCustomAgents() throws -> [AgentProfile] {
        var agents: [AgentProfile] = []
        repeat {
            agents.append(try readAgent(defaultAgent: nil))
        } while try promptYesNo("Add another agent?", defaultValue: false)
        return agents
    }

    private static func editAgents(_ initialAgents: [AgentProfile]) throws -> [AgentProfile] {
        var agents = initialAgents
        while true {
            var items = [
                TerminalCheckboxMenuItem(
                    value: 0,
                    title: "Done",
                    detail: "save the current agent list"
                ),
                TerminalCheckboxMenuItem(
                    value: 1,
                    title: "Add agent",
                    detail: "create a custom agent"
                )
            ]
            items.append(contentsOf: agents.enumerated().map { index, agent in
                TerminalCheckboxMenuItem(
                    value: index + 2,
                    title: agent.displayName,
                    detail: agentSummary(agent),
                    groupTitle: "Edit"
                )
            })

            let choice = TerminalCheckboxMenu.selectOne(
                title: "Agents",
                items: items,
                selected: 0
            ) ?? 0
            if choice == 0 {
                return agents
            }
            if choice == 1 {
                agents.append(try readAgent(defaultAgent: nil))
                continue
            }
            let index = choice - 2
            guard agents.indices.contains(index) else {
                continue
            }
            agents[index] = try readAgent(defaultAgent: agents[index])
        }
    }


    private static func readAgent(defaultAgent: AgentProfile?) throws -> AgentProfile {
        let name = try promptString(
            "Agent name",
            defaultValue: defaultAgent?.name,
            allowEmpty: false
        )
        let symbolName = try promptString(
            "SF Symbol",
            defaultValue: defaultAgent?.symbolName,
            allowEmpty: true
        ).nilIfBlank
        let tools = promptToolSelection(
            title: "Tools for \(name)",
            defaultTools: defaultAgent?.tools ?? AgentProfileStore.defaultToolNames
        )
        let skills = promptSkillSelection(
            title: "Prompt skills for \(name)",
            defaultSkills: defaultAgent?.skills ?? []
        )
        let instructions = try promptInstructions(defaultValue: defaultAgent?.instructions)

        return AgentProfileStore.normalizedAgentForSave(AgentProfile(
            id: defaultAgent?.id ?? UUID().uuidString,
            name: name,
            instructions: instructions,
            symbolName: symbolName,
            tools: tools,
            skills: skills,
            modelID: defaultAgent?.modelID,
            modelProvider: defaultAgent?.modelProvider,
            thinkingSelection: defaultAgent?.thinkingSelection,
            capability: defaultAgent?.capability
        ))
    }

}
