import Testing

@testable import ZenCODECore

@Suite("Collaboration policy prompt")
struct CollaborationPolicyPromptTests {
    @Test
    func coordinatorPolicyRequiresDelegationAndMessagingTools() {
        let section = SystemPromptBuilder.collaborationSection(
            allowedToolNames: ["agent.create", "agent.message"]
        )
        #expect(section?.contains("Collaboration policy:") == true)
        #expect(section?.contains("new agent.create item with `taskID`") == true)
        #expect(SystemPromptBuilder.collaborationSection(allowedToolNames: ["agent.create"]) == nil)
        #expect(SystemPromptBuilder.collaborationSection(allowedToolNames: ["agent.message"]) == nil)
        #expect(SystemPromptBuilder.collaborationSection(allowedToolNames: nil) != nil)
    }

    @Test
    func standalonePromptIncludesPolicyOutsideTaskGraphs() {
        let sections = SystemPromptBuilder.standalonePromptSections(
            cwd: "/tmp/one",
            agentsSection: nil,
            memorySection: nil,
            memoryToolEnabled: false,
            allowedToolNames: ["agent.create", "agent.message"]
        )
        #expect(sections.dynamicContext.contains("Collaboration policy:"))
    }

    @Test
    func sessionCompositionIncludesPolicyOnEveryPromptPath() {
        let tools: Set<String> = ["agent.create", "agent.message"]
        let standard = AgentSessionComposition.standardPromptSections(
            cwd: "/tmp/one",
            allowedToolNames: tools,
            selectedAgent: nil
        )
        #expect(standard.combinedPrompt.contains("Collaboration policy:"))

        let appProvidedWithCwd = AgentSessionComposition.appProvidedPromptSections(
            "App instructions",
            cwd: "/tmp/one",
            allowedToolNames: tools,
            selectedAgent: nil
        )
        #expect(appProvidedWithCwd.dynamicContext.contains("Collaboration policy:"))

        let appProvidedWithoutCwd = AgentSessionComposition.appProvidedPromptSections(
            "App instructions",
            allowedToolNames: tools,
            selectedAgent: nil
        )
        #expect(appProvidedWithoutCwd.dynamicContext.contains("Collaboration policy:"))

        let withoutMessaging = AgentSessionComposition.appProvidedPromptSections(
            "App instructions",
            allowedToolNames: ["agent.create"],
            selectedAgent: nil
        )
        #expect(!withoutMessaging.combinedPrompt.contains("Collaboration policy:"))
    }
}
