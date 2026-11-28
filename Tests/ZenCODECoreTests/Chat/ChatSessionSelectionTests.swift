//
//  ChatSessionSelectionTests.swift
//  ZenCODE
//
//  The selection commands of the shared controller (`/models`, `/think`,
//  `/agents`, `/tools`, `/skills`) against a scripted runtime, host, and
//  presenter. Every test runs in a support directory and a working directory
//  named by UUIDs, so nothing touches the real application state.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("Chat session selections")
struct ChatSessionSelectionTests {
    typealias Fixtures = ChatTestFixtures

    // MARK: - Tools

    @Test
    func aToolChangeThatAltersTheAllowlistRebuildsTheSessionAndReappliesTheSkills() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let skill = try harness.installSkills("release-review")[0]
            controller.selection.skillNames = [skill.canonicalName]
            controller.selection.toolKeys = ["shell", "files"]
            try await harness.startSession(conversation: Fixtures.conversation)
            let sessionID = controller.sessionID
            let initial = try #require(await harness.runtime.configuration(for: sessionID))
            let initialAllowed = try #require(initial.allowedToolNames)
            #expect(initialAllowed.contains("local.exec"))
            // The runtime session holds the skills from its creation on.
            #expect(await harness.runtime.promptSkills(for: sessionID).map(\.canonicalName) == [skill.canonicalName])

            let outcome = await controller.selectTools(keys: ["files"])

            #expect(outcome.change == .sessionRecreated)
            guard case let .activeTools(summary) = try #require(outcome.notices.first),
                  outcome.notices.count == 1 else {
                Issue.record("The closing notice reports the active tools")
                return
            }
            #expect(summary.groups.map(\.title).contains("Files"))
            #expect(!summary.groups.map(\.title).contains("Shell"))

            let calls = await harness.runtime.calls
            #expect(calls.map(\.name) == ["rebuildSession", "createSession", "updatePromptSkillSelection"])
            #expect(calls[0] == .rebuildSession(sessionID))
            let created = try #require(calls[1].digest)
            let allowed = try #require(created.allowedToolNames)
            #expect(allowed.contains("local.read"))
            #expect(!allowed.contains("local.exec"))
            // The model is told what changed, after the conversation it kept.
            let message = ChatSessionController.toolSelectionChangedMessage(
                previousAllowedToolNames: initialAllowed,
                currentAllowedToolNames: allowed
            )
            #expect(created.historyContents == Fixtures.conversation.map(\.content) + [message.content])
            #expect(controller.history.last?.content == message.content)
            #expect(message.role == .system)
            #expect(message.content.hasPrefix("Tool selection changed during this session.\n"))
            #expect(message.content.contains("Removed tool names:"))
            #expect(message.content.contains("local.exec"))
            // The rebuild dropped the skills; they are handed over again.
            #expect(calls[2] == .updatePromptSkillSelection(skillNames: [skill.canonicalName], sessionID: sessionID))
            #expect(await harness.runtime.promptSkills(for: sessionID).map(\.canonicalName) == [skill.canonicalName])
        }
    }

    @Test
    func aToolChangeThatKeepsTheAllowlistOnlyUpdatesTheOptions() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["shell", "files"]
            try await harness.startSession(conversation: Fixtures.conversation)

            let outcome = await controller.selectTools(keys: ["shell", "files"])

            #expect(outcome.change == .sessionUpdated)
            #expect(await harness.callNames() == ["updateSessionOptions"])
            // No rebuild, so no message is added to the conversation.
            #expect(controller.history.map(\.content) == Fixtures.conversation.map(\.content))
        }
    }

    @Test
    func aToolSelectionIsParsedFromTheCommandArguments() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller

            let files = try await controller.selectTools(rawSelection: "files")
            #expect(files.change == .sessionUpdated)
            #expect(controller.selection.toolKeys == ["files"])

            _ = try await controller.selectTools(rawSelection: "none")
            #expect(controller.selection.toolKeys.isEmpty)

            _ = try await controller.selectTools(rawSelection: "all")
            let items = await controller.toolSelectionItems()
            #expect(controller.selection.toolKeys == Set(items.map(\.key)))

            await harness.clearRecords()
            let error = await capturedError { try await controller.selectTools(rawSelection: "bogus") }
            #expect(error is TerminalToolSelectionError)
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func theToolMenuListsTheGroupsAndAppliesTheAnswer() async throws {
        try await withChatHarness(hostCapabilities: [.multipleChoice]) { harness in
            let controller = harness.controller
            controller.selection.toolKeys = ["shell"]
            await harness.host.answerChooseMany(["files", "sub-agents"])

            let outcome = await controller.chooseTools()

            #expect(outcome.change == .sessionUpdated)
            #expect(controller.selection.toolKeys == ["files", "sub-agents"])
            guard case let .chooseMany(title, items, selectedIDs) = try #require(
                await harness.host.interactions.first
            ) else {
                Issue.record("The host was asked for the tool groups")
                return
            }
            #expect(title == "Tools")
            #expect(items.map(\.id).prefix(2) == ["shell", "files"])
            #expect(items.first?.title == "Shell")
            #expect(items.first?.group == "Core")
            #expect(selectedIDs == ["shell"])
        }
    }

    // MARK: - Tools exposed by a Builder

    private static let builtFeatureID = "built-fixture"
    private static let builtFeatureKey = TerminalToolSelectionCatalog.featurePackageKey(id: builtFeatureID)
    private static let builtToolDescriptor = DirectToolDescriptor(
        name: "built.run",
        description: "Runs the built fixture",
        inputSchema: #"{"type":"object","properties":{}}"#
    )

    /// Runs `body` with a harness whose environment carries a feature runtime
    /// that holds one loaded feature, `built-fixture`, backed by a real
    /// executable in a UUID-named directory. Nothing is exposed yet: a test
    /// registers the Builder outcome for the controller's session itself.
    private func withBuiltFeature(
        hostCapabilities: ChatChannelCapabilities = [],
        _ body: @escaping @Sendable @ChatSessionActor (ChatManagementHarness, SwiftFeatureRuntime) async throws -> Void
    ) async throws {
        let root = try SwiftFeatureSessionExposureTests.temporaryDirectory("tools-selection-exposure")
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appendingPathComponent("feature")
        try SwiftFeatureSessionExposureTests.writeExecutable(at: executableURL)
        let featureRuntime = SwiftFeatureRuntime(features: [
            SwiftFeatureBundle(
                id: Self.builtFeatureID,
                executableURL: executableURL,
                tools: [
                    ToolDescriptor(
                        name: "built.run",
                        description: "Runs the built fixture",
                        inputSchema: #"{"type":"object","properties":{}}"#
                    ),
                ],
                toolNamePrefixes: ["built."]
            ),
        ])
        try await withChatHarness(
            hostCapabilities: hostCapabilities,
            featureRuntime: featureRuntime
        ) { harness in
            try await body(harness, featureRuntime)
        }
    }

    @Test
    func theToolMenuTicksAFeatureExposedToTheSession() async throws {
        try await withBuiltFeature(hostCapabilities: [.multipleChoice]) { harness, featureRuntime in
            let controller = harness.controller
            let key = Self.builtFeatureKey
            controller.selection.toolKeys = ["shell"]

            // The loaded feature is listed, but nothing exposes it yet.
            let before = await controller.toolChoices()
            #expect(before.items.map(\.id).contains(key))
            #expect(before.selectedIDs == ["shell"])

            await featureRuntime.exposeForTesting(
                Self.builtFeatureID,
                sessionID: controller.sessionID
            )
            let exposed = await controller.toolChoices()

            #expect(exposed.items == before.items)
            #expect(exposed.selectedIDs == ["shell", key])
            // The menu only reads: neither the selection nor the exposure changed.
            #expect(controller.selection.toolKeys == ["shell"])
            #expect(await featureRuntime.exposedFeatureIDs(sessionID: controller.sessionID)
                == [Self.builtFeatureID])

            // `/tools` hands the host the same ticks.
            await harness.host.answerChooseMany(nil)
            _ = await controller.chooseTools()
            guard case let .chooseMany(_, _, selectedIDs) = try #require(
                await harness.host.interactions.first
            ) else {
                Issue.record("The host was asked for the tool groups")
                return
            }
            #expect(selectedIDs == ["shell", key])
        }
    }

    @Test
    func aCancelledToolMenuKeepsTheExposure() async throws {
        try await withBuiltFeature(hostCapabilities: [.multipleChoice]) { harness, featureRuntime in
            let controller = harness.controller
            await featureRuntime.exposeForTesting(
                Self.builtFeatureID,
                sessionID: controller.sessionID
            )
            await harness.host.answerChooseMany(nil)

            let outcome = await controller.chooseTools()

            #expect(outcome.change == nil)
            #expect(controller.selection.toolKeys.isEmpty)
            #expect(await featureRuntime.exposedFeatureIDs(sessionID: controller.sessionID)
                == [Self.builtFeatureID])
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func confirmingTheToolMenuWithTheExposedFeatureTickedSelectsItAndRevokesTheExposure() async throws {
        try await withBuiltFeature(hostCapabilities: [.multipleChoice]) { harness, featureRuntime in
            let controller = harness.controller
            let key = Self.builtFeatureKey
            await featureRuntime.exposeForTesting(
                Self.builtFeatureID,
                sessionID: controller.sessionID
            )
            // The menu showed the feature ticked, so the answer keeps it.
            await harness.host.answerChooseMany([key])
            await harness.host.answerWorkspaceAccess(true)

            let outcome = await controller.chooseTools()

            #expect(controller.selection.toolKeys == [key])
            #expect(await featureRuntime.exposedFeatureIDs(sessionID: controller.sessionID).isEmpty)
            #expect(outcome.change == .sessionUpdated)
            #expect(await harness.callNames() == ["updateSessionOptions"])
            let digest = try #require(await harness.runtime.calls.first?.digest)
            #expect(try #require(digest.allowedToolNames).contains("built.run"))
            // The feature stays ticked in the menu, now through the selection.
            let choices = await controller.toolChoices()
            #expect(choices.selectedIDs == [key])
            let title = try #require(choices.items.first { $0.id == key }?.title)
            guard case let .activeTools(summary) = try #require(outcome.notices.first),
                  outcome.notices.count == 1 else {
                Issue.record("The closing notice reports the active tools")
                return
            }
            // Besides the always-present prompt-skill tools, only the feature is listed.
            #expect(summary.groups.filter { $0.title != "Skills" } == [.init(title: title, toolCount: 1)])
        }
    }

    @Test
    func confirmingTheToolMenuWithoutTheExposedFeatureDropsItFromTheSelectionAndTheExposure() async throws {
        try await withBuiltFeature(hostCapabilities: [.multipleChoice]) { harness, featureRuntime in
            let controller = harness.controller
            let key = Self.builtFeatureKey
            await featureRuntime.exposeForTesting(
                Self.builtFeatureID,
                sessionID: controller.sessionID
            )
            // The user unticks the feature and keeps Files.
            await harness.host.answerChooseMany(["files"])

            let outcome = await controller.chooseTools()

            #expect(controller.selection.toolKeys == ["files"])
            #expect(!controller.selection.toolKeys.contains(key))
            #expect(await featureRuntime.exposedFeatureIDs(sessionID: controller.sessionID).isEmpty)
            let digest = try #require(await harness.runtime.calls.first?.digest)
            let allowed = try #require(digest.allowedToolNames)
            #expect(allowed.contains("local.read"))
            #expect(!allowed.contains("built.run"))
            // The menu no longer ticks it.
            #expect(await controller.toolChoices().selectedIDs == ["files"])
            guard case let .activeTools(summary) = try #require(outcome.notices.first) else {
                Issue.record("The closing notice reports the active tools")
                return
            }
            #expect(summary.groups.map(\.title).filter { $0 != "Skills" } == ["Files"])
        }
    }

    @Test
    func aSelectionGivenAsCommandArgumentsIsAuthoritativeToo() async throws {
        try await withBuiltFeature { harness, featureRuntime in
            let controller = harness.controller
            await featureRuntime.exposeForTesting(
                Self.builtFeatureID,
                sessionID: controller.sessionID
            )

            _ = try await controller.selectTools(rawSelection: "none")

            #expect(controller.selection.toolKeys.isEmpty)
            #expect(await featureRuntime.exposedFeatureIDs(sessionID: controller.sessionID).isEmpty)
            #expect(await controller.toolChoices().selectedIDs.isEmpty)
        }
    }

    @Test
    func theActiveToolsSummaryListsAnExposedFeatureAmongTheSelectedGroups() async throws {
        try await withBuiltFeature { harness, featureRuntime in
            let controller = harness.controller
            let key = Self.builtFeatureKey
            // The backend resolves the feature's tools for the session.
            await harness.runtime.setActiveToolDescriptors([Self.builtToolDescriptor])

            // Not exposed, not selected: its tools are active, but no group names them.
            let before = await controller.activeToolsSummary()
            #expect(before.groups.isEmpty)

            await featureRuntime.exposeForTesting(
                Self.builtFeatureID,
                sessionID: controller.sessionID
            )
            let exposed = await controller.activeToolsSummary()

            // The exposure counts as a selection: the feature's group is listed.
            let title = try #require(
                await controller.toolChoices().items.first { $0.id == key }?.title
            )
            #expect(exposed.groups == [.init(title: title, toolCount: 1)])
            // The summary only reads: neither the selection nor the exposure changed.
            #expect(controller.selection.toolKeys.isEmpty)
            #expect(await featureRuntime.exposedFeatureIDs(sessionID: controller.sessionID)
                == [Self.builtFeatureID])

            // Once revoked, the group is gone again.
            await featureRuntime.revokeExposures(sessionID: controller.sessionID)
            #expect(await controller.activeToolsSummary().groups.isEmpty)
        }
    }

    @Test
    func withoutAnExposureForThisSessionTheToolSelectionIsUnchanged() async throws {
        try await withBuiltFeature(hostCapabilities: [.multipleChoice]) { harness, featureRuntime in
            let controller = harness.controller
            let otherSessionID = "other-session-\(UUID().uuidString.lowercased())"
            controller.selection.toolKeys = ["shell"]
            let choicesBefore = await controller.toolChoices()
            let summaryBefore = await controller.activeToolsSummary()
            #expect(choicesBefore.selectedIDs == ["shell"])
            #expect(summaryBefore.groups.map(\.title).filter { $0 != "Skills" } == ["Shell"])

            // A feature built for another session is not exposed to this one.
            await featureRuntime.exposeForTesting(
                Self.builtFeatureID,
                sessionID: otherSessionID
            )

            #expect(await controller.toolChoices() == choicesBefore)
            #expect(await controller.activeToolsSummary() == summaryBefore)

            // Confirming selects exactly what the menu returns, and revokes
            // only this session's exposures.
            await harness.host.answerChooseMany(["shell", "files"])
            _ = await controller.chooseTools()

            #expect(controller.selection.toolKeys == ["shell", "files"])
            #expect(await featureRuntime.exposedFeatureIDs(sessionID: otherSessionID)
                == [Self.builtFeatureID])
            #expect(await featureRuntime.exposedFeatureIDs(sessionID: controller.sessionID).isEmpty)
        }
    }

    // MARK: - Skills

    @Test
    func selectingSkillsOnlyUpdatesThePromptSkillSelection() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let skills = try harness.installSkills("alpha-skill", "beta-skill")
            let alpha = skills[0]
            let beta = skills[1]
            try await harness.startSession(conversation: Fixtures.conversation)
            let sessionID = controller.sessionID

            let outcome = await controller.selectSkills(names: [alpha.canonicalName])

            #expect(outcome == ChatSelectionOutcome(change: .sessionUpdated, notices: [.selectedSkills([alpha])]))
            // The prompt, the allowlist, and the history are not touched.
            #expect(await harness.runtime.calls == [
                .updatePromptSkillSelection(skillNames: [alpha.canonicalName], sessionID: sessionID),
            ])
            #expect(controller.selection.skillNames == [alpha.canonicalName])
            #expect(await harness.presenter.states.last?.selection.skillNames == [alpha.canonicalName])

            // The same selection, spelled in the command arguments.
            let all = try await controller.selectSkills(rawSelection: "all")
            #expect(all.notices == [.selectedSkills([alpha, beta])])
            let byName = try await controller.selectSkills(rawSelection: "beta-skill")
            #expect(byName.notices == [.selectedSkills([beta])])
            let none = try await controller.selectSkills(rawSelection: "none")
            #expect(none.notices == [.selectedSkills([])])
            #expect(controller.selection.skillNames.isEmpty)

            let error = await capturedError { try await controller.selectSkills(rawSelection: "zzz") }
            #expect(error is TerminalSkillSelectionError)
        }
    }

    @Test
    func theSkillMenuListsTheInstalledSkillsAndAppliesTheAnswer() async throws {
        try await withChatHarness(hostCapabilities: [.multipleChoice]) { harness in
            let controller = harness.controller

            // Nothing installed: no menu, the selection is reported.
            let empty = await controller.chooseSkills()
            #expect(empty == ChatSelectionOutcome(notices: [.noPromptSkillsInstalled, .selectedSkills([])]))
            #expect(await harness.host.interactions.isEmpty)

            let skills = try harness.installSkills("alpha-skill", "beta-skill")
            await harness.host.answerChooseMany([skills[1].canonicalName])
            let applied = await controller.chooseSkills()
            #expect(applied == ChatSelectionOutcome(
                change: .sessionUpdated,
                notices: [.selectedSkills([skills[1]])]
            ))
            guard case let .chooseMany(title, items, selectedIDs) = try #require(
                await harness.host.interactions.first
            ) else {
                Issue.record("The host was asked for the prompt skills")
                return
            }
            #expect(title == "Prompt skills")
            #expect(items.map(\.id) == skills.map(\.canonicalName))
            #expect(selectedIDs.isEmpty)

            // A cancelled menu keeps the selection and reports it.
            let cancelled = await controller.chooseSkills()
            #expect(cancelled == ChatSelectionOutcome(notices: [.selectedSkills([skills[1]])]))
        }
    }

    @Test
    func installingFromALocalPathCopiesSelectsAndHandsTheSkillToTheSession() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await harness.startSession()
            let sessionID = controller.sessionID
            let source = harness.workspace.appendingPathComponent("vendor", isDirectory: true)
            try Fixtures.writeSkill(named: "release-review", in: source)

            // A relative path resolves against the working directory.
            let outcome = await controller.installSkill(source: "./vendor/release-review")

            #expect(await harness.presenter.notices == [
                .skillInstallStarted(
                    source: harness.workspace
                        .appendingPathComponent("vendor/release-review", isDirectory: true)
                        .standardizedFileURL.path
                ),
            ])
            guard case let .skillInstalled(skill) = try #require(outcome.notices.first),
                  outcome.notices.count == 1 else {
                Issue.record("The closing notice reports the installed skill")
                return
            }
            #expect(outcome.change == .sessionUpdated)
            #expect(skill.canonicalName == "release-review")
            #expect(FileManager.default.fileExists(
                atPath: harness.skillsRoot.appendingPathComponent("release-review/SKILL.md").path
            ))
            #expect(controller.selection.skillNames == [skill.canonicalName])
            #expect(controller.availableSkills().map(\.canonicalName) == [skill.canonicalName])
            #expect(await harness.runtime.calls == [
                .updatePromptSkillSelection(skillNames: [skill.canonicalName], sessionID: sessionID),
            ])
            #expect(await harness.presenter.states.last?.selection.skillNames == [skill.canonicalName])
        }
    }

    @Test
    func uninstallingRemovesTheSkillDeselectsItAndUpdatesTheSession() async throws {
        try await withChatHarness(hostCapabilities: [.multipleChoice]) { harness in
            let controller = harness.controller
            let skills = try harness.installSkills("alpha-skill", "beta-skill")
            let alpha = skills[0]
            let beta = skills[1]
            controller.selection.skillNames = [alpha.canonicalName, beta.canonicalName]
            await harness.host.answerChooseMany([alpha.canonicalName])

            let outcome = await controller.chooseSkillsToUninstall()

            #expect(outcome == ChatSelectionOutcome(
                change: .sessionUpdated,
                notices: [.skillsUninstalled([alpha])]
            ))
            guard case let .chooseMany(title, items, selectedIDs) = try #require(
                await harness.host.interactions.first
            ) else {
                Issue.record("The host was asked which skills to uninstall")
                return
            }
            #expect(title == "Uninstall prompt skills")
            #expect(items.map(\.id) == [alpha.canonicalName, beta.canonicalName])
            #expect(selectedIDs.isEmpty)
            #expect(!FileManager.default.fileExists(
                atPath: harness.skillsRoot.appendingPathComponent("alpha-skill").path
            ))
            #expect(FileManager.default.fileExists(
                atPath: harness.skillsRoot.appendingPathComponent("beta-skill").path
            ))
            #expect(controller.selection.skillNames == [beta.canonicalName])
            #expect(controller.availableSkills().map(\.canonicalName) == [beta.canonicalName])
            #expect(await harness.runtime.calls == [
                .updatePromptSkillSelection(skillNames: [beta.canonicalName], sessionID: controller.sessionID),
            ])
        }
    }
}
