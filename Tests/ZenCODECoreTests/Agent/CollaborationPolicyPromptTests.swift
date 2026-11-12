import Testing

@testable import ZenCODECore

@Suite("Collaboration policy prompt")
struct CollaborationPolicyPromptTests {
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

    @Test
    func policyKeepsTheClosedAttemptRuleWithoutRepeatingTheRetryMechanics() {
        let policy = TaskRecord.collaborationPolicy
        #expect(policy.contains("including standby ones"))
        #expect(policy.contains("a closed attempt cannot resume implementation"))
        // The retry mechanics are stated by tasks.retry and the task workflow
        // policy; the chat policy no longer repeats them.
        #expect(!policy.contains("needs tasks.retry and a new agent.create item"))
    }
}
