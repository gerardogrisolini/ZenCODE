//
//  SetupEscapeBehaviourTests.swift
//  ZenCODECoreTests
//
//  Esc in `zen` setup and `/setup` returns to the menu that opened the step,
//  discarding that step and keeping what other sections staged; only Esc on
//  the first menu leaves setup. These tests drive the terminal-free seams of
//  that rule: the shared helper, a main-menu section (and the sections that
//  act immediately), quick setup, the agent prompts, the action menu of a
//  model binding, the multi-selects and the messages, also once the task is
//  cancelled. The menu loops are in SetupEscapeMenuLoopTests.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct SetupEscapeBehaviourTests {
    private struct FixtureError: LocalizedError {
        var errorDescription: String? { "the server did not answer" }
    }

    private static func remoteManifest(
        modelID: String = "test-model",
        responseLanguage: String? = nil
    ) -> AgentSettingsManifest {
        let provider = AgentRemoteProvider(
            id: "custom",
            name: "Test provider",
            baseURL: "https://example.invalid/v1",
            modelID: modelID
        )
        return AgentSettingsManifest(
            models: [
                AgentSettingsModelManifest(
                    id: "remote:\(modelID)",
                    kind: .remoteAPI,
                    modelID: modelID,
                    providerID: "custom",
                    provider: provider
                )
            ],
            localExecAllowedCommands: ["ls"],
            responseLanguage: responseLanguage
        )
    }

    private static let agent = AgentProfile(
        id: "developer",
        name: "Developer",
        role: .developer,
        tools: ["shell"]
    )

    // MARK: - Shared helper

    @Test
    func helperTurnsEscIntoNilWithItsMessageAndPassesValuesThrough() throws {
        var written: [String] = []
        let cancelled: Int? = try ZenCODESetupRunner.returningToMenuOnCancel(
            "Step cancelled.",
            write: { written.append($0) }
        ) {
            throw ZenCODESetupError.cancelled
        }
        #expect(cancelled == nil)
        #expect(written == ["Step cancelled.\n\n"])

        written = []
        let silent: Int? = try ZenCODESetupRunner.returningToMenuOnCancel(
            nil,
            write: { written.append($0) }
        ) {
            throw ZenCODESetupError.cancelled
        }
        #expect(silent == nil)
        #expect(written.isEmpty)

        let value = try ZenCODESetupRunner.returningToMenuOnCancel(
            "Step cancelled.",
            write: { written.append($0) }
        ) {
            7
        }
        #expect(value == 7)
        #expect(written.isEmpty)
    }

    // MARK: - A section of the main menu

    @Test
    func escInASectionLeavesTheSessionUnchangedAndSaysSo() async throws {
        let original = Self.remoteManifest()
        var session = SetupSession(originalManifest: original)
        var written: [String] = []

        try await ZenCODESetupRunner.runSetupSection(
            .telegram,
            session: &session,
            write: { written.append($0) },
            configure: { _, _, _ in throw ZenCODESetupError.cancelled }
        )

        #expect(session.manifest == original)
        #expect(session.agentProfiles == nil)
        #expect(!session.shouldWriteSettings)
        #expect(written == ["\nTelegram remote control cancelled; changes not saved.\n\n"])
    }

    @Test
    func failedSectionLeavesTheSessionUnchangedAndReportsTheError() async throws {
        let original = Self.remoteManifest()
        var session = SetupSession(originalManifest: original)
        // A change staged by an earlier section survives the failure.
        let staged = Self.remoteManifest(responseLanguage: "it")
        session.apply(SetupSectionConfigurationResult(manifest: staged))
        var written: [String] = []

        try await ZenCODESetupRunner.runSetupSection(
            .providersAndModels,
            session: &session,
            write: { written.append($0) },
            configure: { _, manifest, _ in
                #expect(manifest == staged)
                throw FixtureError()
            }
        )

        #expect(session.manifest == staged)
        #expect(written == [
            "\nProviders and models failed: the server did not answer\nChanges not saved.\n\n"
        ])
    }

    @Test
    func completedSectionIsApplied() async throws {
        var session = SetupSession(originalManifest: Self.remoteManifest())
        let configured = Self.remoteManifest(responseLanguage: "fr")
        var written: [String] = []

        try await ZenCODESetupRunner.runSetupSection(
            .agents,
            session: &session,
            write: { written.append($0) },
            configure: { section, manifest, profiles in
                #expect(section == .agents)
                #expect(profiles == nil)
                return SetupSectionConfigurationResult(
                    manifest: configured,
                    agentProfiles: [Self.agent]
                )
            }
        )

        #expect(session.manifest == configured)
        #expect(session.agentProfiles == [Self.agent])
        #expect(session.shouldWriteSettings)
        #expect(written.isEmpty)
    }

    @Test
    func taskCancellationInASectionPropagates() async {
        var session = SetupSession(originalManifest: Self.remoteManifest())
        await #expect(throws: CancellationError.self) {
            try await ZenCODESetupRunner.runSetupSection(
                .memoryEmbedding,
                session: &session,
                write: { _ in Issue.record("A task cancellation is not reported") },
                configure: { _, _, _ in throw CancellationError() }
            )
        }
    }

    // MARK: - Quick setup

    @Test
    func escAfterProvidersKeepsThemAndOpensTheMainMenu() async throws {
        var session = SetupSession(originalManifest: nil)
        let providers = Self.remoteManifest()
        var written: [String] = []

        let outcome = try await ZenCODESetupRunner.runQuickSetup(
            session: &session,
            write: { written.append($0) },
            configureProviders: { _ in providers },
            configureLanguage: { _ in throw ZenCODESetupError.cancelled },
            configureAgents: {
                Issue.record("Esc in Response language must stop quick setup")
                return []
            }
        )

        #expect(outcome == .incomplete)
        #expect(session.manifest == providers)
        #expect(session.agentProfiles == nil)
        #expect(session.outcome == .write(manifest: providers, settingsWillBeWritten: true))
        #expect(written.contains("\nResponse language cancelled; changes not saved.\n\n"))
        #expect(written.last == ZenCODESetupRunner.quickSetupIncompleteNotice)
    }

    @Test
    func escInAgentsKeepsProvidersAndTheConfirmedLanguage() async throws {
        var session = SetupSession(originalManifest: nil)
        let providers = Self.remoteManifest()
        let withLanguage = Self.remoteManifest(responseLanguage: "it")
        var written: [String] = []

        let outcome = try await ZenCODESetupRunner.runQuickSetup(
            session: &session,
            write: { written.append($0) },
            configureProviders: { _ in providers },
            configureLanguage: { manifest in
                #expect(manifest == providers)
                return withLanguage
            },
            configureAgents: { throw ZenCODESetupError.cancelled }
        )

        #expect(outcome == .incomplete)
        #expect(session.manifest == withLanguage)
        #expect(session.agentProfiles == nil)
        #expect(written.contains("\nAgents cancelled; changes not saved.\n\n"))
    }

    @Test
    func completedQuickSetupStagesEveryStep() async throws {
        var session = SetupSession(originalManifest: nil)
        let withLanguage = Self.remoteManifest(responseLanguage: "it")

        let outcome = try await ZenCODESetupRunner.runQuickSetup(
            session: &session,
            write: { _ in },
            configureProviders: { _ in Self.remoteManifest() },
            configureLanguage: { _ in withLanguage },
            configureAgents: { [Self.agent] }
        )

        #expect(outcome == .completed)
        #expect(session.manifest == withLanguage)
        #expect(session.agentProfiles == [Self.agent])
        #expect(session.outcome == .write(manifest: withLanguage, settingsWillBeWritten: true))
    }

    // MARK: - Multi-selects

    @Test
    func escOnANothingCheckedMultiSelectCancelsInsteadOfSelectingNone() throws {
        let items = [
            TerminalCheckboxMenuItem(value: 0, title: "First", detail: nil),
            TerminalCheckboxMenuItem(value: 1, title: "Second", detail: nil)
        ]
        let error = #expect(throws: ZenCODESetupError.self) {
            _ = try ZenCODESetupRunner.promptSelectionIndexes(
                title: "Delete configured providers",
                items: items,
                select: { _, _, selected in
                    #expect(selected.isEmpty)
                    return nil
                }
            )
        }
        if case .cancelled? = error {} else {
            Issue.record("Expected cancelled, got \(String(describing: error))")
        }
        // Enter with nothing checked still means "none".
        let none = try ZenCODESetupRunner.promptSelectionIndexes(
            title: "Delete configured providers",
            items: items,
            select: { _, _, _ in [] }
        )
        #expect(none.isEmpty)
        let chosen = try ZenCODESetupRunner.promptSelectionIndexes(
            title: "Delete configured providers",
            items: items,
            select: { _, _, _ in [1] }
        )
        #expect(chosen == [1])
    }

    // MARK: - Agent prompts

    @Test
    func agentPromptsTreatEscAsACancelLikeEverySetupPrompt() {
        func expectCancelled(_ label: String, _ body: () throws -> Void) {
            do {
                try body()
                Issue.record("\(label): Esc must throw")
            } catch ZenCODESetupError.cancelled {
                // Expected: the step goes back to the menu that opened it.
            } catch {
                Issue.record("\(label): unexpected error \(error)")
            }
        }

        expectCancelled("promptString") {
            _ = try ZenCODEAgentProfileSetupRunner.promptString(
                "Agent name",
                defaultValue: "Developer",
                allowEmpty: false,
                promptLine: { _, _, _ in nil }
            )
        }
        expectCancelled("promptYesNo") {
            _ = try ZenCODEAgentProfileSetupRunner.promptYesNo(
                "agents.json exists but is invalid. Rewrite it?",
                defaultValue: true,
                selectOne: { _, _, _ in nil }
            )
        }
        expectCancelled("promptRole") {
            _ = try ZenCODEAgentProfileSetupRunner.promptRole(
                defaultValue: .developer,
                selectOne: { _, _, _ in nil }
            )
        }
        expectCancelled("promptInstructions") {
            _ = try ZenCODEAgentProfileSetupRunner.promptInstructions(
                defaultValue: "Be concise.",
                write: { _ in },
                selectChoice: { _, _, _ in nil }
            )
        }
    }

    // MARK: - The action menu of a model binding

    private static let bindingAgent = AgentProfile(
        id: "developer",
        name: "Developer",
        role: .developer,
        tools: ["shell"],
        modelBindings: [
            AgentModelBinding(id: "fast", modelID: "fast-model", capability: 4),
            AgentModelBinding(id: "deep", modelID: "deep-model", thinkingSelection: .high, capability: 8)
        ],
        defaultModelBindingID: "fast"
    )

    @Test
    func noDedicatedModelStillRemovesTheEditedBindingAndOtherActionsApply() throws {
        let agent = Self.bindingAgent
        let fast = try #require(agent.modelBindings.first { $0.id == "fast" })
        let deep = try #require(agent.modelBindings.first { $0.id == "deep" })
        let removed = try #require(try ZenCODEAgentProfileSetupRunner.editModelBinding(
            fast,
            for: agent,
            models: [],
            selectAction: { _, _, _ in .edit },
            promptBinding: { _, _, _ in nil }
        ))
        #expect(removed.modelBindings.map(\.id) == ["deep"])
        // The removed default falls back to the remaining binding.
        #expect(removed.defaultModelBindingID == "deep")

        let madeDefault = try #require(try ZenCODEAgentProfileSetupRunner.editModelBinding(
            deep,
            for: agent,
            models: [],
            selectAction: { _, _, _ in .makeDefault },
            promptBinding: { _, _, _ in
                Issue.record("Make default does not edit the binding")
                return nil
            }
        ))
        #expect(madeDefault.modelBindings == agent.modelBindings)
        #expect(madeDefault.defaultModelBindingID == "deep")
    }

    // MARK: - Messages

    @Test
    func everyErrorOfACancelledTaskIsRethrownUnreported() async {
        // Each error, Esc included, raised once the surrounding task has been
        // cancelled: setup must stop instead of reporting it and going on.
        let errors: [any Error] = [FixtureError(), ZenCODESetupError.cancelled]
        for error in errors {
            let outcome = await Task { () -> (rethrown: Bool, written: [String]) in
                withUnsafeCurrentTask { $0?.cancel() }
                var written: [String] = []
                do {
                    try ZenCODESetupRunner.reportInterruptedSetupStep(
                        error,
                        title: "Telegram remote control",
                        write: { written.append($0) }
                    )
                    return (false, written)
                } catch {
                    return (true, written)
                }
            }.value
            #expect(outcome.rethrown, "\(error)")
            #expect(outcome.written.isEmpty, "\(error)")
        }
    }
}
