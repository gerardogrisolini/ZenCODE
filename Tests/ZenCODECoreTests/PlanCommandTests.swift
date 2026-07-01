//
//  PlanCommandTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/07/26.
//
import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct PlanCommandTests {
    @Test
    func planCommandIsVisibleWithStandardCommands() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)

        #expect(commands.contains("/plan"))
    }

    @Test
    func plannerToolAllowlistExcludesMutatingTools() {
        let planner = AgentProfile(
            id: AgentProfileStore.plannerAgentID.uuidString,
            name: AgentProfileStore.plannerAgentName,
            tools: [
                "local.readFile",
                "local.writeFile",
                "local.exec",
                "git.diff",
                "git.add",
                "memory.read",
                "memory.write",
                "task.list",
                "task.update",
                "web.search"
            ]
        )

        let tools = TerminalChat.plannerSubAgentToolNames(for: planner)

        #expect(tools.contains("local.readFile"))
        #expect(tools.contains("git.diff"))
        #expect(tools.contains("memory.read"))
        #expect(tools.contains("task.list"))
        #expect(tools.contains("web.search"))
        #expect(!tools.contains("local.writeFile"))
        #expect(!tools.contains("local.exec"))
        #expect(!tools.contains("git.add"))
        #expect(!tools.contains("memory.write"))
        #expect(!tools.contains("task.update"))
    }

    @Test
    func defaultPlannerToolGroupsResolveToReadOnlySubAgentTools() throws {
        let planner = try #require(
            AgentProfileStore.defaultProfiles().first(where: TerminalChat.isPlannerProfile)
        )

        let tools = TerminalChat.plannerSubAgentToolNames(for: planner)

        #expect(planner.tools == AgentProfileStore.plannerToolNames)
        #expect(!planner.tools.contains("shell"))
        #expect(!planner.tools.contains("local.readFile"))
        #expect(tools.contains("local.readFile"))
        #expect(tools.contains("git.diff"))
        #expect(tools.contains("memory.read"))
        #expect(tools.contains("web.search"))
        #expect(!tools.contains("local.exec"))
        #expect(!tools.contains("local.writeFile"))
        #expect(!tools.contains("git.add"))
        #expect(!tools.contains("memory.write"))
    }

    @Test
    func planDelegationPromptCreatesPlannerSubAgentsForPlanImplementationReviewLoop() {
        let planner = AgentProfile(
            id: AgentProfileStore.plannerAgentID.uuidString,
            name: AgentProfileStore.plannerAgentName,
            tools: []
        )

        let prompt = TerminalChat.planDelegationPrompt(
            goal: "add a Planner command",
            planner: planner
        )

        #expect(prompt.contains("Planning goal requested by the user: add a Planner command"))
        #expect(prompt.contains("agent.create"))
        #expect(prompt.contains("role \"Planner\""))
        #expect(prompt.contains("isolationMode \"report\""))
        #expect(prompt.contains("toolNames:"))
        #expect(prompt.contains("agent.wait"))
        #expect(prompt.contains("/plan -> implementation work -> /review"))
        #expect(prompt.contains("Do not edit any files yourself in this planning turn"))
        #expect(!prompt.contains("local.writeFile"))
        #expect(!prompt.contains("local.exec"))
        #expect(!prompt.contains("git.add"))
        #expect(!prompt.contains("memory.write"))
    }
}
