import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// The delegated-agent tool-grant table: every row fixes the grant a child
/// receives for one combination of coordinator identity, coordinator grant,
/// child profile, and task binding. The same rows characterize
/// `agent.create` end to end and the grant resolution on its own.
enum SubAgentToolGrantTable {
    struct Case: Sendable, CustomTestStringConvertible {
        let label: String
        let parentProfileID: String?
        let parentProfileName: String?
        let profile: AgentProfile
        let parentAllowedToolNames: Set<String>?
        let isTaskBound: Bool
        /// `nil` means unrestricted.
        let expectedToolNames: Set<String>?

        var testDescription: String { label }
    }

    static let skillTools: Set<String> = ["skills.list", "skills.read"]
    static let collaborationTools: Set<String> = ["agent.list", "agent.get", "agent.message"]
    static let taskReportingTools: Set<String> = ["tasks.list", "tasks.get", "tasks.update"]

    /// A coordinator session grant with a session-local addition
    /// (`external.sessionAddition`) and a removal (`local.writeFile`, which
    /// the Developer profile grants).
    static let sessionGrant: Set<String> = ["local.readFile", "external.sessionAddition"]
    /// A coordinator session grant that includes a mutating core tool.
    static let writeSessionGrant: Set<String> = [
        "local.readFile", "local.writeFile", "external.sessionAddition"
    ]

    static let developer = AgentProfile(
        id: "developer",
        name: "Developer",
        role: .developer,
        tools: ["local.readFile", "local.writeFile"]
    )
    static let reviewer = AgentProfile(
        id: "reviewer",
        name: "Reviewer",
        readOnly: true,
        role: .reviewer,
        tools: ["local.readFile", "local.writeFile"]
    )
    static let planner = AgentProfile(
        id: "planner",
        name: "Planner",
        role: .planner,
        tools: ["local.readFile", "local.writeFile"]
    )
    static let minimal = AgentProfile(
        id: "minimal",
        name: "Minimal",
        role: .minimal,
        tools: []
    )
    static let builder = AgentProfile(
        id: "builder",
        name: "Builder",
        role: .builder,
        tools: ["local.readFile"]
    )
    static let developerWithFeatureReference = AgentProfile(
        id: "developer",
        name: "Developer",
        role: .developer,
        tools: ["local.readFile", "feature.scaffold"]
    )
    static let customChild = AgentProfile(
        id: "child-profile",
        name: "coordinator-profile",
        role: .developer,
        tools: ["local.writeFile"]
    )
    /// The memberwise initializer trims identities; a persisted manifest
    /// decodes them verbatim.
    static let paddedDeveloper: AgentProfile = {
        let json = #"""
        {"id":"  DEVELOPER  ","name":"  Developer  ","role":"developer","tools":["local.readFile","local.writeFile"]}
        """#
        // A fixed literal: decoding it cannot fail.
        return try! JSONDecoder().decode(AgentProfile.self, from: Data(json.utf8))
    }()

    static let developerOwnGrant: Set<String> = ["local.readFile", "local.writeFile"]
    static let readOnlyOwnGrant: Set<String> = ["local.readFile"]

    static func row(
        _ label: String,
        parentID: String?,
        parentName: String?,
        profile: AgentProfile,
        parentGrant: Set<String>?,
        taskBound: Bool,
        expected: Set<String>?
    ) -> Case {
        Case(
            label: label,
            parentProfileID: parentID,
            parentProfileName: parentName,
            profile: profile,
            parentAllowedToolNames: parentGrant,
            isTaskBound: taskBound,
            expectedToolNames: expected
        )
    }

    static let cases: [Case] = [
        // Same profile by ID: the coordinator's effective grant is inherited.
        row(
            "same ID, nil parent grant stays unrestricted",
            parentID: "developer", parentName: "Developer", profile: developer,
            parentGrant: nil, taskBound: false, expected: nil
        ),
        row(
            "same ID, nil parent grant stays unrestricted when task-bound",
            parentID: "developer", parentName: "Developer", profile: developer,
            parentGrant: nil, taskBound: true, expected: nil
        ),
        row(
            "same ID inherits session additions and removals",
            parentID: "developer", parentName: "Developer", profile: developer,
            parentGrant: sessionGrant, taskBound: false,
            expected: sessionGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "same ID inherits session grant and adds task reporting when task-bound",
            parentID: "developer", parentName: "Developer", profile: developer,
            parentGrant: sessionGrant, taskBound: true,
            expected: sessionGrant.union(taskReportingTools).union(skillTools)
                .union(collaborationTools)
        ),
        row(
            "same ID compared case-insensitively against a padded upper-case parent ID",
            parentID: "  DEVELOPER ", parentName: nil, profile: developer,
            parentGrant: sessionGrant, taskBound: false,
            expected: sessionGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "same ID compared after trimming a padded upper-case child ID",
            parentID: "developer", parentName: nil, profile: paddedDeveloper,
            parentGrant: sessionGrant, taskBound: false,
            expected: sessionGrant.union(skillTools).union(collaborationTools)
        ),
        // Name fallback: only when the coordinator has no ID.
        row(
            "same name without parent ID inherits",
            parentID: nil, parentName: "Developer", profile: developer,
            parentGrant: sessionGrant, taskBound: false,
            expected: sessionGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "same name with blank parent ID inherits",
            parentID: "   ", parentName: "Developer", profile: developer,
            parentGrant: sessionGrant, taskBound: false,
            expected: sessionGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "same name compared case-insensitively and trimmed without parent ID",
            parentID: nil, parentName: "  developer  ", profile: developer,
            parentGrant: sessionGrant, taskBound: true,
            expected: sessionGrant.union(taskReportingTools).union(skillTools)
                .union(collaborationTools)
        ),
        row(
            "same name without parent ID keeps a nil parent grant unrestricted",
            parentID: nil, parentName: "Developer", profile: developer,
            parentGrant: nil, taskBound: false, expected: nil
        ),
        // Different identities: the child keeps its own profile grant.
        row(
            "same name with different IDs does not inherit",
            parentID: "developer-profile", parentName: "Developer", profile: developer,
            parentGrant: sessionGrant, taskBound: false,
            expected: developerOwnGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "same name with different IDs does not inherit a nil parent grant",
            parentID: "developer-profile", parentName: "Developer", profile: developer,
            parentGrant: nil, taskBound: false,
            expected: developerOwnGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "parent ID equal to the child name does not inherit",
            parentID: "coordinator-profile", parentName: "Developer", profile: customChild,
            parentGrant: sessionGrant, taskBound: false,
            expected: Set(["local.writeFile"]).union(skillTools).union(collaborationTools)
        ),
        row(
            "no parent identity does not inherit",
            parentID: nil, parentName: nil, profile: developer,
            parentGrant: sessionGrant, taskBound: false,
            expected: developerOwnGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "different profile with nil parent grant is restricted and task-bound",
            parentID: "reviewer", parentName: "Reviewer", profile: developer,
            parentGrant: nil, taskBound: true,
            expected: developerOwnGrant.union(taskReportingTools).union(skillTools)
                .union(collaborationTools)
        ),
        // Read-only profiles.
        row(
            "Reviewer under Developer keeps its own read-only grant",
            parentID: "developer", parentName: "Developer", profile: reviewer,
            parentGrant: writeSessionGrant, taskBound: false,
            expected: readOnlyOwnGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "Reviewer under Developer keeps task reporting when task-bound",
            parentID: "developer", parentName: "Developer", profile: reviewer,
            parentGrant: writeSessionGrant, taskBound: true,
            expected: readOnlyOwnGrant.union(taskReportingTools).union(skillTools)
                .union(collaborationTools)
        ),
        row(
            "Reviewer under Reviewer inherits but the read-only filter drops mutating tools",
            parentID: "reviewer", parentName: "Reviewer", profile: reviewer,
            parentGrant: writeSessionGrant, taskBound: false,
            expected: sessionGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "Reviewer under Reviewer keeps a nil parent grant unrestricted",
            parentID: "reviewer", parentName: "Reviewer", profile: reviewer,
            parentGrant: nil, taskBound: true, expected: nil
        ),
        row(
            "Planner under Developer keeps its own read-only grant",
            parentID: "developer", parentName: "Developer", profile: planner,
            parentGrant: writeSessionGrant, taskBound: false,
            expected: readOnlyOwnGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "Planner under Planner inherits but the read-only filter drops mutating tools",
            parentID: "planner", parentName: "Planner", profile: planner,
            parentGrant: writeSessionGrant, taskBound: true,
            expected: sessionGrant.union(taskReportingTools).union(skillTools)
                .union(collaborationTools)
        ),
        // Minimal.
        row(
            "Minimal under Developer receives only intrinsic tools",
            parentID: "developer", parentName: "Developer", profile: minimal,
            parentGrant: sessionGrant, taskBound: false,
            expected: skillTools.union(collaborationTools)
        ),
        row(
            "Minimal under Developer receives task reporting when task-bound",
            parentID: "developer", parentName: "Developer", profile: minimal,
            parentGrant: nil, taskBound: true,
            expected: taskReportingTools.union(skillTools).union(collaborationTools)
        ),
        row(
            "Minimal under Minimal inherits the parent grant",
            parentID: "minimal", parentName: "Minimal", profile: minimal,
            parentGrant: sessionGrant, taskBound: false,
            expected: sessionGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "Minimal under Minimal with an empty parent grant receives only intrinsic tools",
            parentID: "minimal", parentName: "Minimal", profile: minimal,
            parentGrant: [], taskBound: false,
            expected: skillTools.union(collaborationTools)
        ),
        // Feature tools.
        row(
            "Builder under Developer receives the feature management tools",
            parentID: "developer", parentName: "Developer", profile: builder,
            parentGrant: sessionGrant, taskBound: false,
            expected: Set(["local.readFile"])
                .union(AgentProfileStore.featureManagementToolNames)
                .union(skillTools).union(collaborationTools)
        ),
        row(
            "Builder under Builder inherits the parent grant without feature tools",
            parentID: "builder", parentName: "Builder", profile: builder,
            parentGrant: sessionGrant, taskBound: false,
            expected: sessionGrant.union(skillTools).union(collaborationTools)
        ),
        row(
            "Developer drops a feature management tool reference",
            parentID: nil, parentName: nil, profile: developerWithFeatureReference,
            parentGrant: nil, taskBound: true,
            expected: Set(["local.readFile"]).union(taskReportingTools)
                .union(skillTools).union(collaborationTools)
        ),
    ]
}

extension DirectSubAgentRuntimeTests {
    @Test(arguments: SubAgentToolGrantTable.cases)
    func createdChildReceivesTheTabulatedToolGrant(
        _ grantCase: SubAgentToolGrantTable.Case
    ) async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let profile = grantCase.profile
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in profile },
            parentProfileID: grantCase.parentProfileID,
            parentProfileName: grantCase.parentProfileName
        )
        var item: [String: JSONValue] = [
            "name": .string("grant-table-worker"),
            "profile": .string(profile.name)
        ]
        if grantCase.isTaskBound {
            let orchestrator = SessionTaskOrchestrator()
            _ = try await orchestrator.createGraph(
                sessionID: "root",
                id: "graph",
                source: .manual,
                state: .active,
                tasks: [TaskDefinition(id: "grant-task", title: "Grant table task")]
            )
            await runtime.installTaskOrchestrator(orchestrator)
            item["taskID"] = .string("grant-task")
        }

        let workingDirectory = URL(fileURLWithPath: "/tmp/ZenCODE-tool-grant-table-tests")
        _ = try await Self.withProjectSelection([profile], workingDirectory: workingDirectory) {
            try await runtime.createAgents(
                arguments: ["agents": .array([.object(item)])],
                workingDirectory: workingDirectory,
                parentAllowedToolNames: grantCase.parentAllowedToolNames,
                rootSessionID: "root"
            )
        }

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == grantCase.expectedToolNames)
        await runtime.shutdown()
    }
}
