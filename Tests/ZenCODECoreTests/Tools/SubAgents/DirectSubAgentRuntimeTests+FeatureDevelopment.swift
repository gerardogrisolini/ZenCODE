import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// The feature workflow of a delegated Builder: a sub-agent with the `builder`
/// role whose grant admits `feature.scaffold` receives the "Delegated feature
/// development" section right before its profile section; no other sub-agent
/// does.
extension DirectSubAgentRuntimeTests {
    private static let featureDevelopmentHeading = "Delegated feature development:"

    private static func featureProfile(
        role: AgentProfileRole,
        tools: [String] = []
    ) -> AgentProfile {
        AgentProfile(
            id: "feature-\(role.rawValue)",
            name: "Feature \(role.title)",
            instructions: "Hand every feature step to the operator.",
            role: role,
            tools: tools
        )
    }

    private static func prompt(
        profile: AgentProfile?,
        allowedToolNames: Set<String>?
    ) -> String {
        DirectSubAgentRuntime.systemPrompt(
            name: "worker",
            allowedToolNames: allowedToolNames,
            selectedProfile: profile
        )
    }

    @Test
    func builderWithFeatureScaffoldGetsTheWorkflowRightBeforeItsProfileSection() throws {
        let builder = Self.featureProfile(role: .builder)
        let profileSection = try #require(builder.promptSection)
        let section = DirectSubAgentRuntime.delegatedFeatureDevelopmentSection

        // `nil` is unrestricted; an exact name and a `feature.` prefix grant it.
        for allowedToolNames: Set<String>? in [
            nil,
            ["feature.scaffold", "local.readFile"],
            ["feature.", "agent.message"]
        ] {
            let prompt = Self.prompt(profile: builder, allowedToolNames: allowedToolNames)
            #expect(prompt.contains(section + "\n" + profileSection))
            #expect(prompt.components(separatedBy: Self.featureDevelopmentHeading).count == 2)
        }
        #expect(section.hasPrefix(Self.featureDevelopmentHeading))
        #expect(section.contains("takes precedence over any profile instruction"))
        #expect(section.contains("1. Call feature.list first."))
        // Reuse rebuilds, since only a feature built in this delegation is
        // exposed; a catalog feature is left to the operator.
        #expect(section.contains(
            "reuse it instead of creating a duplicate: change it with feature.edit if needed, "
                + "then run feature.validate and feature.build on it and make sure it is enabled, "
                + "because only a feature you built in this delegation is exposed."
        ))
        #expect(section.contains(
            "A bundled or optional catalog feature is never exposed this way: when one of them provides "
                + "the capability, do not rebuild it and report that the operator has to select it with /tools."
        ))
        // How feature.list marks a catalog feature, with its real fields.
        #expect(section.contains(
            "do not rebuild it and report that the operator has to select it with /tools. "
                + "feature.list marks a catalog feature with `source` set to `bundled` or, "
                + "once installed or copied locally, with an `adoptedFrom` value.\n2. "
        ))
        #expect(section.contains("`id`, `displayName`, `description`, and `toolName`"))
        // The namespace rule lists the real core namespaces, those the
        // delegated namespace check enforces.
        #expect(section.contains(
            "Give the tool a namespace of its own: `toolName` must not start with a namespace of the core tools "
                + "(\(DirectSubAgentRuntime.coreToolNamespaceList)), and the part of it up to its last dot must "
                + "not be a namespace of another feature that feature.list reports; a scaffold or build that "
                + "breaks this rule is refused."
        ))
        #expect(DirectSubAgentRuntime.coreToolNamespaceList
            == SwiftFeatureRuntime.coreToolNamespaces.map { "`\($0)`" }.joined(separator: ", "))
        for namespace in ["`local.`", "`tasks.`", "`todo.`", "`memory.`", "`agent.`", "`feature.`", "`skills.`"] {
            #expect(DirectSubAgentRuntime.coreToolNamespaceList.contains(namespace), "\(namespace)")
        }
        #expect(section.contains("and only on macOS, the only platform where that template is available"))
        #expect(section.contains("Keep Swift tools 6.4 and the feature id."))
        #expect(section.contains("Only after both succeed, call feature.enable."))
        #expect(section.contains(
            "5. A feature you built and enabled is exposed automatically to the session that delegated you, "
                + "so for it do not tell anyone to use /tools or /feature."
        ))
    }

    @Test
    func builderWithoutFeatureScaffoldInItsGrantGetsNoWorkflow() throws {
        let builder = Self.featureProfile(role: .builder)
        let profileSection = try #require(builder.promptSection)

        for allowedToolNames: Set<String> in [
            ["local.readFile", "feature.build", "feature.enable"],
            ["agent.message"],
            []
        ] {
            let prompt = Self.prompt(profile: builder, allowedToolNames: allowedToolNames)
            #expect(!prompt.contains(Self.featureDevelopmentHeading))
            #expect(prompt.contains(profileSection))
        }
    }

    @Test
    func subAgentsWithAnotherRoleOrNoProfileGetNoWorkflow() {
        let everyGrant: [Set<String>?] = [nil, ["feature.scaffold"], ["feature."]]
        for role in AgentProfileRole.allCases where role != .builder {
            let profile = Self.featureProfile(role: role)
            for allowedToolNames in everyGrant {
                let prompt = Self.prompt(profile: profile, allowedToolNames: allowedToolNames)
                #expect(!prompt.contains(Self.featureDevelopmentHeading))
            }
        }
        for allowedToolNames in everyGrant {
            let prompt = Self.prompt(profile: nil, allowedToolNames: allowedToolNames)
            #expect(!prompt.contains(Self.featureDevelopmentHeading))
        }
    }

    /// A Builder created under another profile has its own grant, which always
    /// holds the feature-management tools; one created under the Builder
    /// profile itself inherits the coordinator's session grant, which may not.
    @Test
    func createdBuilderReceivesTheWorkflowOnlyWhenItsGrantHoldsFeatureScaffold() async throws {
        try await ProjectAgentSelectionTestSupport.withTemporaryProjectAsync { _, workspace in
            let builder = Self.featureProfile(role: .builder, tools: ["local.readFile"])
            try ProjectAgentSelectionStore.save(
                agentIDs: [builder.id],
                workspaceRootURL: workspace
            )
            for (coordinatorIsBuilder, expectsWorkflow) in [(false, true), (true, false)] {
                let backend = CapturingSubAgentRuntimeBackend()
                let runtime = DirectSubAgentRuntime(
                    contextualBackendFactory: { _ in backend },
                    profileResolver: { _ in builder },
                    parentProfileID: coordinatorIsBuilder ? builder.id : nil,
                    parentProfileName: coordinatorIsBuilder ? builder.name : nil
                )

                _ = try await runtime.createAgents(
                    arguments: [
                        "name": .string("tool-builder"),
                        "profile": .string(builder.name)
                    ],
                    workingDirectory: workspace,
                    parentAllowedToolNames: ["local.readFile"]
                )

                let session = try #require(await backend.createdSessions().first)
                let grant = try #require(session.allowedToolNames)
                #expect(grant.contains("feature.scaffold") == expectsWorkflow)
                let prompt = try #require(session.systemPrompt)
                #expect(prompt.contains(Self.featureDevelopmentHeading) == expectsWorkflow)
                if expectsWorkflow {
                    let workflow = try #require(prompt.range(of: Self.featureDevelopmentHeading))
                    let profile = try #require(prompt.range(of: "Selected agent: \(builder.name)"))
                    #expect(workflow.lowerBound < profile.lowerBound)
                }
                await runtime.shutdown()
            }
        }
    }
}
