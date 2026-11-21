//
//  ChatSessionTestSupport+Harness.swift
//  ZenCODE
//
//  Shared chat test fixtures, the recording channel hooks, the management
//  harness and the debounce gate used by the chat session tests.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

// MARK: - Fixtures

/// Models, agents, and files the Chat-layer suites share.
enum ChatTestFixtures {
    /// Offers no configurable thinking.
    static let alpha = AgentSettingsModelManifest(
        id: "alpha-model",
        kind: .remoteAPI,
        title: "Alpha Model",
        modelID: "test/alpha"
    )

    /// Offers `.low` (default) and `.high`.
    static let beta = AgentSettingsModelManifest(
        id: "beta-model",
        kind: .remoteAPI,
        title: "Beta Model",
        modelID: "test/beta",
        thinkingOptions: [.low, .high],
        defaultThinkingSelection: .low
    )

    /// The two hosted models above, the first one at launch.
    static let hostedModels = [alpha, beta]

    /// A model of the user's configured catalog. A configured remote model
    /// needs a provider, otherwise `settings.json` drops it.
    static func configuredModel(
        _ id: String,
        title: String,
        thinkingOptions: [AgentThinkingSelection] = [],
        defaultThinkingSelection: AgentThinkingSelection? = nil
    ) -> AgentSettingsModelManifest {
        let modelID = "local/\(id)"
        return AgentSettingsModelManifest(
            id: id,
            kind: .remoteAPI,
            title: title,
            modelID: modelID,
            provider: AgentRemoteProvider(
                name: "remote-server",
                baseURL: "http://127.0.0.1",
                modelID: modelID
            ),
            thinkingOptions: thinkingOptions.isEmpty ? nil : thinkingOptions,
            defaultThinkingSelection: defaultThinkingSelection
        )
    }

    static let configuredAlpha = configuredModel("configured-alpha", title: "Configured Alpha")
    static let configuredBeta = configuredModel(
        "configured-beta",
        title: "Configured Beta",
        thinkingOptions: [.low, .high],
        defaultThinkingSelection: .low
    )

    static let developer = ProjectAgentSelectionTestSupport.developer
    static let reviewer = ProjectAgentSelectionTestSupport.reviewer
    static let reporter = ProjectAgentSelectionTestSupport.reporter

    static func message(_ role: AgentRuntimeMessage.Role, _ content: String) -> AgentRuntimeMessage {
        AgentRuntimeMessage(role: role, content: content)
    }

    /// A two-message conversation.
    static let conversation = [
        AgentRuntimeMessage(role: .user, content: "Where is the bug?"),
        AgentRuntimeMessage(role: .assistant, content: "In the parser."),
    ]

    /// A four-message conversation.
    static let longConversation = conversation + [
        AgentRuntimeMessage(role: .user, content: "Can you fix it?"),
        AgentRuntimeMessage(role: .assistant, content: "Fixed."),
    ]

    /// Writes `<root>/<name>/SKILL.md` and returns the skill folder.
    @discardableResult
    static func writeSkill(
        named name: String,
        in root: URL,
        description: String? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(description ?? "The \(name) test skill.")
        ---

        # \(name)

        Follow the \(name) instructions.
        """
        .write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    /// A task graph with one coordinator task.
    static func taskGraph(id: String) -> TaskGraphSnapshot {
        let date = Date(timeIntervalSince1970: 1_000)
        return TaskGraphSnapshot(
            id: id,
            source: .plan(planID: "plan-\(id)"),
            state: .active,
            revision: 1,
            tasks: [
                TaskRecord(
                    id: "\(id)-1",
                    title: "Read the parser",
                    order: 1,
                    createdAt: date,
                    updatedAt: date
                ),
            ],
            createdAt: date,
            updatedAt: date
        )
    }
}

// MARK: - Recording channel hooks

/// Channel hooks that record every command step the controller asks of the
/// channel, in order, each with the runtime operations the controller had
/// asked for when it ran: a test reads where a step falls among the runtime
/// steps, and that it precedes the closing notices the command returns.
@ChatSessionActor
final class RecordingChannelHooks: ChatSessionChannelHooks {
    private let runtime: ScriptedChatRuntime
    /// The steps so far: the hook, then the runtime operations at that point.
    private(set) var steps: [String] = []
    /// What ``commandContextWindow()`` answers.
    var contextWindow: DirectAgentContextWindowStatus?

    init(runtime: ScriptedChatRuntime) {
        self.runtime = runtime
    }

    private func record(_ step: String) async {
        let calls = await runtime.calls.map(\.name)
        steps.append("\(step) after \(calls)")
    }

    func selectionDidApply(_ change: ChatSelectionChange, command: ChatSelectionCommand) async {
        await record("selectionDidApply(\(change), \(command))")
    }

    func commandContextWindow() async -> DirectAgentContextWindowStatus? {
        await record("commandContextWindow")
        return contextWindow
    }

    func incarnationDidChange(reason: ChatIncarnationChange) async {
        switch reason {
        case .newSessionWillStart:
            await record("newSessionWillStart")
        case .newSessionDidStart:
            await record("newSessionDidStart")
        case .savedSessionWillLoad, .savedSessionWillRestore, .savedSessionDidRestore:
            // Not command steps: the saved-session load is recorded elsewhere.
            break
        case let .sessionDidCompact(contextWindow):
            let tokens = contextWindow.usedTokens.map(String.init) ?? "-"
            let maximum = contextWindow.maxTokens.map(String.init) ?? "-"
            await record("sessionDidCompact(\(tokens)/\(maximum))")
        }
    }

    func sessionWillCreate(reason: ChatSessionRecreationReason) async {
        await record("sessionWillCreate(\(reason))")
    }

    func sessionDidCreate(reason: ChatSessionRecreationReason) async {
        await record("sessionDidCreate(\(reason))")
    }
}

// MARK: - Harness

/// How the harness's environment resolves its models.
enum ChatTestCatalog: Sendable {
    /// The host process supplies the models and the agents: nothing is ever
    /// written to the user's settings.
    case hosted(
        models: [AgentSettingsModelManifest] = ChatTestFixtures.hostedModels,
        agents: [AgentProfile] = [ChatTestFixtures.developer, ChatTestFixtures.reviewer]
    )
    /// The models are the user's configured catalog, read from (and written
    /// to) `settings.json` in the support directory.
    case configured(
        models: [AgentSettingsModelManifest],
        selectedModelID: String? = nil
    )
}

/// A `ChatSessionController` over a scripted runtime, host, and presenter,
/// inside a support directory and a working directory named by UUIDs.
struct ChatManagementHarness: Sendable {
    let support: URL
    let workspace: URL
    let runtime: ScriptedChatRuntime
    let host: ScriptedChatInteractionHost
    let presenter: RecordingChatPresenter
    let controller: ChatSessionController

    var settingsURL: URL {
        support.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
    }

    var skillsRoot: URL {
        support.appendingPathComponent("skills", isDirectory: true)
    }

    /// Forgets everything recorded so far, so a test asserts only on what its
    /// operation did.
    func clearRecords() async {
        await runtime.clearCalls()
        await presenter.clear()
        await host.clearInteractions()
    }

    /// Creates the runtime session for the controller's current selection
    /// with `conversation` as its history, then clears the records.
    @ChatSessionActor
    func startSession(
        conversation: [AgentRuntimeMessage] = [],
        transcript: [AgentRuntimeMessage]? = nil
    ) async throws {
        controller.history = conversation
        controller.transcript = transcript ?? conversation
        try await controller.createSessionWithSelectedSkills(discoverExternalTools: false)
        await clearRecords()
    }
}

extension ChatManagementHarness {
    /// The names of the operations the runtime was asked for, in order.
    func callNames() async -> [String] {
        await runtime.calls.map(\.name)
    }

    /// Installs the skills `names` in the support directory, as the app
    /// catalog holds them, and returns them as the controller discovers them.
    @ChatSessionActor
    func installSkills(_ names: String...) throws -> [PromptSkill] {
        for name in names {
            try ChatTestFixtures.writeSkill(named: name, in: skillsRoot)
        }
        controller.availableSkillsCache = nil
        let skills = controller.availableSkills()
        return try names.map { name in
            try #require(skills.first { $0.canonicalName == name })
        }
    }
}

/// Runs `body` with a throwaway support directory and working directory (both
/// named by a UUID) and a task-local support-directory override, so no test
/// reads or writes the real application state. `persistsTaskGraphs` gives the
/// runtime a task-graph store in that support directory, which the saved-plan
/// library needs. `userHomeDirectoryURL` is the home the environment hands
/// the controller (none by default). `featureRuntime` is the feature runtime
/// the environment hands the controller (none by default).
func withChatHarness(
    catalog: ChatTestCatalog = .hosted(),
    hostCapabilities: ChatChannelCapabilities = [],
    hostDecisions: [ChatConsentDecision?] = [],
    retainsTranscript: Bool = true,
    persistsTaskGraphs: Bool = false,
    userHomeDirectoryURL: URL? = nil,
    featureRuntime: SwiftFeatureRuntime? = nil,
    _ body: @escaping @Sendable @ChatSessionActor (ChatManagementHarness) async throws -> Void
) async throws {
    let temporary = FileManager.default.temporaryDirectory
    let support = temporary.appendingPathComponent(
        "zencode-chat-support-\(UUID().uuidString)",
        isDirectory: true
    )
    let workspace = temporary.appendingPathComponent(
        "zencode-chat-workspace-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: support)
        try? FileManager.default.removeItem(at: workspace)
    }

    try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable @ChatSessionActor in
        // Everything the layer reads or writes goes to the UUID-named directory.
        #expect(
            AppStorageDirectory.appSupportDirectoryURL().standardizedFileURL.path
                == support.standardizedFileURL.path
        )
        let configuration: AgentConfiguration
        switch catalog {
        case let .hosted(models, agents):
            configuration = try AgentConfiguration(
                hostedModelID: models.first?.id ?? "scripted-model",
                availableAgents: agents,
                availableModels: models,
                workingDirectory: workspace
            )
            #expect(configuration.hostedModels != nil)
        case let .configured(models, selectedModelID):
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: models, selectedModelID: selectedModelID),
                to: support.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
            )
            // `--model` is always passed, so an ambient `ZENCODE_AGENT_MODEL`
            // cannot stand in for the explicit model (an empty value means none).
            configuration = try AgentConfiguration.withoutPersistedConfiguration(
                arguments: [
                    "zen",
                    "--model", "",
                    "--working-directory", workspace.path,
                ]
            )
            #expect(configuration.hostedModels == nil)
        }

        let host = ScriptedChatInteractionHost(
            capabilities: hostCapabilities,
            decisions: hostDecisions
        )
        let runtime = ScriptedChatRuntime(
            taskGraphStore: persistsTaskGraphs
                ? SessionTaskGraphStore(supportDirectoryURL: support)
                : nil
        )
        let presenter = RecordingChatPresenter()
        let controller = ChatSessionController(
            sessionID: "chat-session-\(UUID().uuidString.lowercased())",
            managementRuntime: runtime,
            environment: ChatSessionEnvironment(
                configuration: configuration,
                featureRuntime: featureRuntime,
                userHomeDirectoryURL: userHomeDirectoryURL
            ),
            workingDirectory: configuration.workingDirectory,
            presenter: presenter,
            host: host,
            authorizer: ChatToolConsentAuthorizer(host: host),
            retainsTranscript: retainsTranscript
        )
        try await body(
            ChatManagementHarness(
                support: support,
                workspace: configuration.workingDirectory,
                runtime: runtime,
                host: host,
                presenter: presenter,
                controller: controller
            )
        )
    }
}


/// The error `operation` throws, or `nil` when it completes.
@ChatSessionActor
func capturedError<T>(_ operation: () async throws -> T) async -> Error? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}

// MARK: - Sleep gate

/// A `sleep` seam under the test's control (the task-graph observer's
/// debounce, the interval of the sub-agent overview refresh): a wait lasts
/// until the test opens the gate, and a cancelled wait ends at once by
/// throwing, as `Task.sleep` does.
actor DebounceGate {
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledBeforeWaiting: Set<UUID> = []
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// The duration of every wait started so far, in order.
    private(set) var durations: [Duration] = []

    /// The `sleep` the seam runs.
    nonisolated func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await wait(id: id, duration: duration)
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    /// Returns once `count` waits have started.
    func waitForEntries(_ count: Int) async {
        guard durations.count < count else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append((count, continuation))
        }
    }

    /// Ends every wait in progress.
    func open() {
        let continuations = Array(waiting.values)
        waiting.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func wait(id: UUID, duration: Duration) async throws {
        durations.append(duration)
        let entered = durations.count
        let ready = entryWaiters.filter { $0.count <= entered }
        entryWaiters.removeAll { $0.count <= entered }
        for waiter in ready {
            waiter.continuation.resume()
        }
        if cancelledBeforeWaiting.remove(id) != nil || Task.isCancelled {
            throw CancellationError()
        }
        try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
        }
    }

    private func cancel(id: UUID) {
        if let continuation = waiting.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledBeforeWaiting.insert(id)
        }
    }
}
