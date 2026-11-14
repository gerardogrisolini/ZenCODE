//
//  AgentConfigurationTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

extension AgentConfigurationTests {
    @Test
    func taskWorkflowPolicyIsConditionalOnTheRequiredTaskTools() throws {
        let taskTools: Set<String> = [
            "tasks.create",
            "tasks.list",
            "tasks.update",
            "agent.create",
        ]
        let policy = try #require(
            SystemPromptBuilder.taskOrchestrationSection(allowedToolNames: taskTools)
        )

        #expect(policy.contains("Task workflow policy:"))
        #expect(policy.contains("Before launching multiple delegated agents"))
        #expect(policy.contains("tasks.create"))
        #expect(policy.contains("tasks.list with runnableOnly=true"))
        #expect(policy.contains("maximizes safe, useful parallelism"))
        #expect(policy.contains("Never serialize tasks merely because"))
        #expect(policy.contains("Give independent tasks empty dependencies"))
        #expect(policy.contains("Keep work sequential when concurrency offers no"))
        #expect(policy.contains("In `/goal`, execute graph work directly or delegate when useful; delegation is optional"))
        #expect(policy.contains("For other task graphs, prefer delegation for non-trivial work"))
        #expect(policy.contains("execution.executor as coordinator"))
        #expect(policy.contains("prefer a single delegation without manufacturing a task graph"))
        #expect(!policy.contains("you remain free to execute tasks directly"))
        #expect(policy.contains("canonical tasks.create `tasks` array"))
        #expect(policy.contains("do not mix root-level single-task fields"))
        #expect(policy.contains("agent.create `agents` item as `taskID`"))
        #expect(policy.contains("never pass taskID as a root argument"))
        #expect(policy.contains("every delegated agent must use `agents[].taskID`"))
        #expect(policy.contains("A `/goal` graph remains persistent even for entirely direct work"))
        #expect(policy.contains("normal tool grant remains unchanged"))
        #expect(policy.contains("single self-contained delegation"))
        #expect(policy.contains("Determine the task type and required tools"))
        #expect(policy.contains(
            "lowest-capability binding that is greater than or equal to task complexity"
        ))
        #expect(policy.contains("Never select a profile or model binding by capability alone"))
        #expect(policy.contains("Select the agent profile and binding from the delegatable roster by the agent selection policy above"))
        #expect(!policy.contains("Select the most suitable agent profile"))
        #expect(policy.contains("For a profile without bindings, omit model in agent.create"))
        #expect(policy.contains("do not invent a binding or capability rating"))
        #expect(policy.contains(TaskRecord.delegationCostPolicy))
        #expect(policy.contains("Configured bindings are also a cost ladder"))
        #expect(policy.contains("delegate the task to the cheapest sufficient binding even when direct execution would be faster"))
        #expect(policy.contains("Only complexity-1 work whose context is already in hand stays direct"))
        #expect(policy.contains("When no compatible profile has bindings, delegation saves nothing"))
        #expect(policy.contains("Use tasks.retry for failed or blocked work before starting a new attempt"))
        #expect(policy.contains("record the task as failed and call tasks.retry before starting a new attempt"))
        #expect(!policy.contains("then claim the new attempt with tasks.update in_progress"))
        #expect(SystemPromptBuilder.taskWorkflowToolsAreAvailable(taskTools))
        #expect(SystemPromptBuilder.taskOrchestrationSection(
            allowedToolNames: ["tasks.create", "tasks.list"]
        ) == nil)
        let namespaceTools: Set<String> = ["tasks.", "agent."]
        #expect(SystemPromptBuilder.taskWorkflowToolsAreAvailable(namespaceTools))
        #expect(SystemPromptBuilder.taskOrchestrationSection(
            allowedToolNames: namespaceTools
        )?.contains("agent.create `agents` item as `taskID`") == true)

        let coordinatorOnlyTools: Set<String> = [
            "tasks.create",
            "tasks.list",
            "tasks.update",
        ]
        let coordinatorOnlyPolicy = try #require(
            SystemPromptBuilder.taskOrchestrationSection(
                allowedToolNames: coordinatorOnlyTools
            )
        )
        #expect(coordinatorOnlyPolicy.contains(
            "execute runnable graph work directly, including in `/goal`"
        ))
        #expect(coordinatorOnlyPolicy.contains(
            "do not request unavailable tools or bypass the current permission boundary"
        ))
        #expect(!coordinatorOnlyPolicy.contains(
            "Execute runnable graph work directly and record its lifecycle"
        ))
        #expect(!coordinatorOnlyPolicy.contains(TaskRecord.delegationCostPolicy))

        // A role-delegating coordinator keeps the agent selection policy it
        // used to read in the task tool schemas, next to its role guidance.
        let rolePolicy = try #require(
            SystemPromptBuilder.taskOrchestrationSection(
                allowedToolNames: taskTools,
                delegatesByRole: true
            )
        )
        #expect(rolePolicy.contains("Delegate by role: in each item set `profileRole`"))
        #expect(rolePolicy.contains(
            "The runtime uses each task's complexity to select the model binding of the delegated role."
        ))
        #expect(rolePolicy.contains("Agent selection policy: \(TaskRecord.agentSelectionPolicy)"))
        #expect(!rolePolicy.contains(TaskRecord.delegationCostPolicy))
        #expect(!rolePolicy.contains("Select the agent profile and binding from the delegatable roster"))

        let singularTaskTools: Set<String> = [
            "task.create",
            "task.list",
            "task.update",
        ]
        #expect(!SystemPromptBuilder.taskWorkflowToolsAreAvailable(singularTaskTools))
        #expect(!SystemPromptBuilder.taskWorkflowToolsAreAvailable(["task."]))
        #expect(!SystemPromptBuilder.taskWorkflowToolsAreAvailable([
            "feature.task.create",
            "feature.task.list",
            "feature.task.update",
        ]))

        let standalonePrompt = SystemPromptBuilder.standalonePrompt(
            cwd: "/tmp/project",
            agentsSection: nil,
            memorySection: nil,
            memoryToolEnabled: false,
            allowedToolNames: taskTools
        )
        #expect(standalonePrompt.contains("Task workflow policy:"))

        let providedPrompt = AgentCoreAppSessionFactory.resolvedSystemPrompt(
            providedSystemPrompt: "Client instructions.",
            cwd: "/tmp/project",
            selectedAgent: nil,
            allowedToolNames: taskTools
        )
        #expect(providedPrompt.contains("Task workflow policy:"))

        let restoredPrompt = try #require(
            SystemPromptBuilder.appendingTaskOrchestrationSection(
                to: "Saved instructions.",
                allowedToolNames: taskTools
            )
        )
        #expect(restoredPrompt.contains("Saved instructions."))
        #expect(restoredPrompt.contains("Task workflow policy:"))
        #expect(SystemPromptBuilder.appendingTaskOrchestrationSection(
            to: restoredPrompt,
            allowedToolNames: taskTools
        ) == restoredPrompt)
    }

    @Test
    func removedDefaultProfileNameIsRejected() {
        #expect(throws: AgentConfigurationError.self) {
            _ = try AgentConfiguration(
                hostedModelID: "remote-community/test",
                agentName: "Default",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
            )
        }
    }

    @Test
    @ChatSessionActor
    func hostedEffectiveModelUsesHostedManifestInsteadOfCoderSettings() {
        let provider = AgentRemoteProvider(
            name: "remote-server",
            baseURL: "http://127.0.0.1",
            modelID: "remote-community/server-model"
        )
        let hostedManifest = AgentSettingsManifest(
            models: [
                AgentSettingsModelManifest(
                    kind: .remoteAPI,
                    modelID: "remote-community/server-model",
                    provider: provider
                )
            ],
            selectedModelID: "remote-community/server-model"
        )
        let agent = AgentProfile(
            id: UUID().uuidString,
            name: "Remote default",
            role: .developer,
            tools: [],
            modelID: "remoteapi:provider:remote-community/server-model"
        )

        let effectiveModelID = ChatSessionController.effectiveModelID(
            selectedAgent: agent,
            manualModelIDOverride: nil,
            manifest: hostedManifest
        )

        #expect(effectiveModelID == "remote-community/server-model")
    }

    @Test
    func agentThinkingOverridesSettingsSelection() {
        let manifest = thinkingSelectionManifest(selectedThinkingSelection: .high)

        let chatThinkingSelection = ChatSessionController.effectiveThinkingSelection(
            manualThinkingSelectionOverride: nil,
            hostedModel: nil,
            explicitModelID: nil,
            agentModelID: "remote-community/qwen3",
            agentThinkingSelection: .low,
            manifest: manifest
        )
        let appSessionThinkingSelection = AgentCoreAppSessionFactory.resolvedThinkingSelection(
            nil,
            explicitModelID: nil,
            agentModelID: "remote-community/qwen3",
            agentThinkingSelection: .low,
            manifest: manifest
        )

        #expect(chatThinkingSelection == .low)
        #expect(appSessionThinkingSelection == .low)
    }

    @Test
    @ChatSessionActor
    func terminalSessionConfigurationPreservesLoadedCacheKey() throws {
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-cache-project",
            isDirectory: true
        )
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: workingDirectory
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false
        )
        terminal.chatSession.cacheKey = "terminal:/tmp/ZenCODE-cache-project:session:plan"

        let sessionConfiguration = terminal.currentSessionConfiguration(
            allowedToolNames: []
        )

        #expect(
            sessionConfiguration.cacheKey
                == "terminal:/tmp/ZenCODE-cache-project:session:plan"
        )
    }
}
