//
//  ChatSessionStartingAgentTests.swift
//  ZenCODE
//
//  The agent a new session starts with, as a launch in the session's folder
//  would select it (``ChatSessionEnvironment/startingAgent(forWorkingDirectory:)``):
//  the launch agent in the launch folder, without reading anything; the
//  default developer of another folder's project, in the controller and in
//  the reducer the host seeds; the requested agent in every folder; no agent
//  for a launch without one; the configured profiles read from the support
//  directory, and the launch agent when they cannot be read. Every test runs
//  in directories named by UUIDs with a task-local support directory, so
//  nothing touches the real application state and no provider is contacted.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

/// The profiles of the tests: the system developer, a custom developer that
/// a project can make its default, and a custom reviewer a launch requests.
private enum StartingAgentProfiles {
    static let developer = AgentProfile(id: "developer", name: "Developer", role: .developer)
    static let projectDeveloper = AgentProfile(id: "project-developer", name: "Project Developer", role: .developer)
    static let reviewer = AgentProfile(id: "custom-reviewer", name: "Custom Reviewer", role: .reviewer)
    static var all: [AgentProfile] { [developer, projectDeveloper, reviewer] }
}

@ChatSessionActor
@Suite("Chat session starting agent", .serialized, .timeLimit(.minutes(2)))
struct ChatSessionStartingAgentTests {
    private typealias Profiles = StartingAgentProfiles

    struct Environment {
        let root: URL
        let support: URL
        /// The folder the launch resolved.
        let launchFolder: URL
        /// Another folder, whose project a test can give its own default.
        let otherFolder: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-starting-agent-\(UUID().uuidString)", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            launchFolder = root.appendingPathComponent("launch-\(UUID().uuidString)", isDirectory: true)
            otherFolder = root.appendingPathComponent("other-\(UUID().uuidString)", isDirectory: true)
            for directory in [support, launchFolder, otherFolder] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        /// A hosted launch in ``launchFolder``, asking for `agentName` when given.
        func hostedConfiguration(agentName: String? = nil) throws -> AgentConfiguration {
            try AgentConfiguration(
                hostedModelID: "test-model",
                agentName: agentName,
                availableAgents: Profiles.all,
                availableModels: [
                    AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
                ],
                workingDirectory: launchFolder
            )
        }

        /// Makes ``StartingAgentProfiles/projectDeveloper`` the default agent
        /// of the project of `folder`, the system developer not visible to it.
        func makeProjectDeveloperTheDefault(of folder: URL) throws {
            try ProjectAgentSelectionStore.save(
                agentIDs: [Profiles.projectDeveloper.id, Profiles.reviewer.id],
                workspaceRootURL: folder
            )
        }

        @ChatSessionActor
        func makeHost(_ configuration: AgentConfiguration) -> ChatSessionHost {
            ChatSessionHost(
                runner: AgentCoreSessionRunner(
                    taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
                ),
                environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
                sleepAssertionReason: "ZenCODE chat starting agent test"
            )
        }

        /// A slot of `workingDirectory` that publishes state.
        @ChatSessionActor
        func descriptor(_ name: String, workingDirectory: URL) -> ChatSlotDescriptor {
            ChatSlotDescriptor(
                identity: .window(name),
                workingDirectory: workingDirectory,
                presenter: RecordingChatPresenter(),
                interaction: .pendingRequests(capabilities: [.textInput]),
                authorizer: ChatToolConsentAuthorizer(
                    host: ScriptedChatInteractionHost(capabilities: [], decisions: [])
                ),
                defaultOrigin: .app,
                publishesState: true
            )
        }
    }

    /// Runs `body` on the chat actor with a private support directory (never
    /// the real `~/.zencode`) and UUID-named temporary folders.
    nonisolated func withEnvironment(
        _ body: @escaping @Sendable @ChatSessionActor (Environment) async throws -> Void
    ) async throws {
        let environment = try Environment()
        defer { environment.remove() }
        try await AppStorageDirectory.withSupportDirectoryURL(environment.support) {
            try await Task(name: "ZenCODE.Tests.chat-starting-agent") { @ChatSessionActor in
                try await body(environment)
            }.value
        }
    }

    // MARK: - Starting agent

    @Test
    nonisolated func theLaunchFolderStartsWithTheLaunchAgentWithoutReadingItsProjectAgain() async throws {
        try await withEnvironment { environment in
            let launch = ChatSessionEnvironment(
                configuration: try environment.hostedConfiguration(),
                featureRuntime: nil
            )
            #expect(launch.launchAgent == Profiles.developer)
            #expect(launch.requestedAgentName == nil)
            #expect(launch.launchWorkingDirectory == environment.launchFolder)

            // The launch folder's project changes its default after the
            // launch: its sessions keep the agent the launch selected, as
            // the terminal and Telegram do.
            try environment.makeProjectDeveloperTheDefault(of: environment.launchFolder)
            #expect(launch.startingAgent(forWorkingDirectory: environment.launchFolder) == Profiles.developer)
            let spelledDifferently = URL(
                fileURLWithPath: environment.launchFolder.path + "/./",
                isDirectory: true
            )
            #expect(launch.startingAgent(forWorkingDirectory: spelledDifferently) == Profiles.developer)
        }
    }

    @Test
    nonisolated func anotherFolderStartsWithTheDefaultDeveloperOfItsProject() async throws {
        try await withEnvironment { environment in
            try environment.makeProjectDeveloperTheDefault(of: environment.otherFolder)
            let launch = ChatSessionEnvironment(
                configuration: try environment.hostedConfiguration(),
                featureRuntime: nil
            )
            #expect(launch.launchAgent == Profiles.developer)
            #expect(launch.startingAgent(forWorkingDirectory: environment.otherFolder) == Profiles.projectDeveloper)
            // A folder whose project saved no selection: the system developer.
            let unconfigured = environment.root.appendingPathComponent("plain-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: unconfigured, withIntermediateDirectories: true)
            #expect(launch.startingAgent(forWorkingDirectory: unconfigured) == Profiles.developer)
            // The selection follows: the agent and the launch's explicit model.
            let selection = ChatSessionController.initialSelection(
                for: launch,
                workingDirectory: environment.otherFolder
            )
            #expect(selection.agent == Profiles.projectDeveloper)
            #expect(selection.modelIDOverride == launch.explicitModelID)
        }
    }

    @Test
    nonisolated func aRequestedAgentStartsInEveryFolder() async throws {
        try await withEnvironment { environment in
            try environment.makeProjectDeveloperTheDefault(of: environment.otherFolder)
            let launch = ChatSessionEnvironment(
                configuration: try environment.hostedConfiguration(agentName: " Custom Reviewer "),
                featureRuntime: nil
            )
            #expect(launch.requestedAgentName == "Custom Reviewer")
            #expect(launch.launchAgent == Profiles.reviewer)
            #expect(launch.startingAgent(forWorkingDirectory: environment.launchFolder) == Profiles.reviewer)
            #expect(launch.startingAgent(forWorkingDirectory: environment.otherFolder) == Profiles.reviewer)
        }
    }

    @Test
    nonisolated func aLaunchWithoutAgentStartsEveryFolderWithoutOne() async throws {
        try await withEnvironment { environment in
            try environment.makeProjectDeveloperTheDefault(of: environment.otherFolder)
            // `--agent` and `--model` are passed empty, so an ambient
            // `ZENCODE_AGENT` or `ZENCODE_AGENT_MODEL` cannot stand in.
            let configuration = try AgentConfiguration.withoutPersistedConfiguration(
                arguments: [
                    "zen",
                    "--agent", "",
                    "--model", "",
                    "--working-directory", environment.launchFolder.path,
                ]
            )
            let launch = ChatSessionEnvironment(configuration: configuration, featureRuntime: nil)
            #expect(launch.launchAgent == nil)
            #expect(launch.requestedAgentName == nil)
            #expect(launch.startingAgent(forWorkingDirectory: environment.otherFolder) == nil)
        }
    }

    @Test
    nonisolated func theConfiguredProfilesAreReadAndAFailureFallsBackToTheLaunchAgent() async throws {
        try await withEnvironment { environment in
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(
                    models: [
                        AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
                    ],
                    selectedModelID: "test-model"
                )
            )
            try AgentProfileStore.save(Profiles.all)
            try environment.makeProjectDeveloperTheDefault(of: environment.otherFolder)
            let configuration = try AgentConfiguration(
                arguments: [
                    "zen",
                    "--agent", "",
                    "--model", "",
                    "--working-directory", environment.launchFolder.path,
                ]
            )
            let launch = ChatSessionEnvironment(configuration: configuration, featureRuntime: nil)
            #expect(launch.hostedAgentProfiles == nil)
            #expect(launch.requestedAgentName == nil)
            #expect(launch.launchAgent?.id == Profiles.developer.id)
            #expect(launch.startingAgent(forWorkingDirectory: environment.otherFolder)?.id == Profiles.projectDeveloper.id)

            // The profiles can no longer be read: the launch agent.
            try FileManager.default.removeItem(at: AgentProfileStore.agentsManifestURL())
            #expect(launch.startingAgent(forWorkingDirectory: environment.otherFolder)?.id == Profiles.developer.id)
        }
    }

    // MARK: - Host slots

    @Test
    nonisolated func aSlotOnAnotherFolderStartsFromThatFolderDefaultsInTheControllerAndTheReducer() async throws {
        try await withEnvironment { environment in
            try environment.makeProjectDeveloperTheDefault(of: environment.otherFolder)
            let host = environment.makeHost(try environment.hostedConfiguration())
            let launchSlot = try host.openSlot(environment.descriptor("launch", workingDirectory: environment.launchFolder))
            let otherSlot = try host.openSlot(environment.descriptor("other", workingDirectory: environment.otherFolder))

            let launch = try await host.newSession(in: launchSlot, sessionID: "launch")
            #expect(launch.controller.selection.agent == host.environment.launchAgent)
            #expect(launch.controller.selection.agent == Profiles.developer)
            #expect(launch.reducer?.snapshot.selection == launch.controller.selection)

            let other = try await host.newSession(in: otherSlot, sessionID: "other")
            #expect(other.controller.selection.agent == Profiles.projectDeveloper)
            #expect(other.reducer?.snapshot.selection.agent == Profiles.projectDeveloper)
            #expect(other.reducer?.snapshot.selection == other.controller.selection)
            #expect(other.controller.selection == ChatSessionController.initialSelection(
                for: host.environment,
                workingDirectory: environment.otherFolder
            ))

            // A later session of the slot starts from the folder's defaults
            // again, not from the selection of the one it replaces.
            other.controller.selection.agent = Profiles.reviewer
            other.controller.selection.toolKeys = ["shell"]
            let next = try await host.newSession(in: otherSlot, sessionID: "other-next")
            #expect(next.controller.selection.agent == Profiles.projectDeveloper)
            #expect(next.controller.selection.toolKeys.isEmpty)
            #expect(next.reducer?.snapshot.selection == next.controller.selection)
            await host.shutdown()
        }
    }

    @Test
    nonisolated func aRequestedAgentStartsTheSlotsOfEveryFolder() async throws {
        try await withEnvironment { environment in
            try environment.makeProjectDeveloperTheDefault(of: environment.otherFolder)
            let host = environment.makeHost(try environment.hostedConfiguration(agentName: "Custom Reviewer"))
            let otherSlot = try host.openSlot(environment.descriptor("other", workingDirectory: environment.otherFolder))

            let other = try await host.newSession(in: otherSlot, sessionID: "other")
            #expect(other.controller.selection.agent == Profiles.reviewer)
            #expect(other.reducer?.snapshot.selection.agent == Profiles.reviewer)
            await host.shutdown()
        }
    }
}
