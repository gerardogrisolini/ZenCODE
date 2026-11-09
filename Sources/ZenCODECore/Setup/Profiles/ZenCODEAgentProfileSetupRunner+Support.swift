//
//  ZenCODEAgentProfileSetupRunner+Support.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

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
        let bindings = agent.modelBindings.isEmpty ? "" : " | \(agentModelSummary(agent))"
        return "\(tools)\(skills)\(bindings)"
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

    /// Adds the system developer profile only when no profile has the
    /// developer role.
    static func ensureDeveloperAgent(in agents: [AgentProfile]) -> [AgentProfile] {
        guard !containsDeveloperAgent(in: agents),
              let developer = AgentProfileStore.defaultProfiles().first(where: {
                  $0.role == .developer && $0.isSystemProfile
              })
        else {
            return agents
        }
        return [developer] + agents
    }

    /// Whether `agent` is the default developer of `agents` (see
    /// ``AgentProfileStore/developerProfile(in:)``), which cannot be deleted.
    static func isRequiredDeveloperAgent(_ agent: AgentProfile, in agents: [AgentProfile]) -> Bool {
        (try? AgentProfileStore.developerProfile(in: agents)) == agent
    }

    static func containsDeveloperAgent(in agents: [AgentProfile]) -> Bool {
        agents.contains { $0.role == .developer }
    }

    static func agentSetupNameKey(_ name: String) -> String {
        name.agentSetupKey
    }

    /// Text prompt of the agents setup. Esc, Ctrl-C or the end of input throws
    /// `ZenCODESetupError.cancelled`, like every setup prompt, so the step
    /// that asked goes back to the menu that opened it. `promptLine` replaces
    /// the terminal in tests.
    static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        promptLine: (String, String?, Bool) -> String? = {
            TerminalCheckboxMenu.promptLine(
                title: "ZenCODE agents setup",
                prompt: $0,
                defaultValue: $1,
                allowEmpty: $2
            )
        }
    ) throws -> String {
        guard let value = promptLine(prompt, defaultValue, allowEmpty) else {
            throw ZenCODESetupError.cancelled
        }
        return value
    }

    static func promptYesNo(
        _ prompt: String,
        defaultValue: Bool,
        selectOne: (String, [TerminalCheckboxMenuItem<Bool>], Bool) -> Bool? = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        }
    ) throws -> Bool {
        let items = [
            TerminalCheckboxMenuItem(value: true, title: "Yes", detail: nil),
            TerminalCheckboxMenuItem(value: false, title: "No", detail: nil)
        ]
        // Esc/EOF must never be silently folded into the highlighted default:
        // the "Rewrite it?" prompt used default == true, so cancelling would
        // confirm a destructive overwrite. Treat it as a cancel instead.
        guard let value = selectOne(prompt, items, defaultValue) else {
            throw ZenCODESetupError.cancelled
        }
        return value
    }

    /// Required single choice of the profile's role among every role. The
    /// highlighted default is only a preselection the operator confirms; as
    /// in ``promptYesNo(_:defaultValue:selectOne:)``, Esc is a cancel.
    static func promptRole(
        defaultValue: AgentProfileRole,
        selectOne: (
            String,
            [TerminalCheckboxMenuItem<AgentProfileRole>],
            AgentProfileRole
        ) -> AgentProfileRole? = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        }
    ) throws -> AgentProfileRole {
        guard let value = selectOne("Role", roleSelectionItems(), defaultValue) else {
            throw ZenCODESetupError.cancelled
        }
        return value
    }

    static func roleSelectionItems() -> [TerminalCheckboxMenuItem<AgentProfileRole>] {
        AgentProfileRole.allCases.map { role in
            TerminalCheckboxMenuItem(
                value: role,
                title: role.title,
                detail: role.summary
            )
        }
    }

    static func skillList(_ skills: [AgentProfileSkill]) -> String {
        skills.map(\.id).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Compiled once: `truncatedInline` runs for every menu row detail.
    private static let whitespaceRunExpression = try! NSRegularExpression(pattern: #"\s+"#)

    static func truncatedInline(_ value: String, limit: Int) -> String {
        let newlineFree = value.replacingOccurrences(of: "\n", with: " ")
        let inline = whitespaceRunExpression
            .stringByReplacingMatches(
                in: newlineFree,
                range: NSRange(newlineFree.startIndex..., in: newlineFree),
                withTemplate: " "
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inline.count > limit else {
            return inline
        }
        return String(inline.prefix(max(0, limit - 3))) + "..."
    }
}


enum ZenCODEAgentProfileSetupError: LocalizedError {
    case nonInteractiveTerminal
    case unableToCreateGlobalAgents(URL)
    case instructionEditorLaunchFailed(String, String)
    case instructionEditorFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "ZenCODE agents setup requires an interactive terminal."
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
    var agentSetupKey: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
