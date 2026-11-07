//
//  SetupEscapeMenuLoopTests.swift
//  ZenCODECoreTests
//
//  The terminal menus of setup answer Esc, Ctrl-C, `q` and the end of input
//  alike with `nil`. These tests drive the menu loops of setup with a
//  scripted selector, a list of answers followed by `nil` forever, and check
//  that each loop ends on that `nil` instead of presenting a menu again, with
//  the state Esc promises: the Agents menu, the bindings of one agent, Memory
//  embeddings, Provider family, Clean memory and the Linux Voice mode menu.
//

import Foundation
@testable import ZenCODECore
import Testing

/// Answers a menu with each scripted value in turn, then with `nil` forever,
/// like a terminal menu whose input has ended, and records every
/// presentation. Past `limit` presentations it records an issue and answers
/// `bailout`, so a loop that presents its menu again after a cancel fails
/// instead of hanging the test run whenever `bailout` ends that loop.
private final class ScriptedMenu<Value> {
    private var answers: [Value?]
    private let limit: Int
    private let bailout: Value?
    private(set) var titles: [String] = []
    private(set) var preselections: [Value] = []

    init(_ answers: [Value?] = [], limit: Int = 20, bailout: Value? = nil) {
        self.answers = answers
        self.limit = limit
        self.bailout = bailout
    }

    var presentations: Int { titles.count }

    func answer(_ title: String, _ preselection: Value) -> Value? {
        titles.append(title)
        preselections.append(preselection)
        guard presentations <= limit else {
            Issue.record("\(title) presented \(presentations) times: the loop does not end")
            return bailout
        }
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

@Suite
struct SetupEscapeMenuLoopTests {
    private static func expectCancelled(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            Issue.record("Esc must throw ZenCODESetupError.cancelled", sourceLocation: sourceLocation)
        } catch ZenCODESetupError.cancelled {
            // Expected: the menu above handles the cancel.
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    private static func expectCancelled(
        sourceLocation: SourceLocation = #_sourceLocation,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("Esc must throw ZenCODESetupError.cancelled", sourceLocation: sourceLocation)
        } catch ZenCODESetupError.cancelled {
            // Expected: the menu above handles the cancel.
        } catch {
            Issue.record("Unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - Agents

    private static let developer = AgentProfile(
        id: "developer",
        name: "Developer",
        role: .developer,
        tools: ["shell"]
    )
    private static let reviewer = AgentProfile(
        id: "reviewer",
        name: "Reviewer",
        role: .reviewer,
        tools: ["shell"]
    )
    private static let planner = AgentProfile(
        id: "planner",
        name: "Planner",
        role: .planner,
        tools: ["shell"]
    )

    @Test
    func escOnTheAgentsMenuDiscardsTheAgentsAddedAndDeletedInTheVisit() {
        // Add agent, then Delete configured agents, then Esc.
        let menu = ScriptedMenu<Int>([1, 2], bailout: 0)
        var offeredForDeletion: [[String]] = []
        Self.expectCancelled {
            _ = try ZenCODEAgentProfileSetupRunner.editAgents(
                [Self.developer, Self.reviewer],
                write: { _ in },
                selectChoice: { title, _, selected in menu.answer(title, selected) },
                readAgent: { defaultAgent in
                    #expect(defaultAgent == nil)
                    return Self.planner
                },
                promptDeletion: { agents in
                    offeredForDeletion.append(agents.map(\.id))
                    return [1]
                }
            )
        }
        // The deletion saw the agent added in this visit; Esc then threw
        // instead of returning the edited list.
        #expect(offeredForDeletion == [["developer", "reviewer", "planner"]])
        #expect(menu.presentations == 3)
    }

    // MARK: - Model bindings for one agent

    private typealias BindingAction = ZenCODEAgentProfileSetupRunner.AgentModelBindingMenuAction

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

    private static let addedBinding = AgentModelBinding(id: "extra", modelID: "extra-model", capability: 6)

    @Test
    func escOnTheBindingsOfAnAgentDiscardsAnAddAndAnEditOfTheVisit() throws {
        // Add model binding, then the action menu of "deep", then Esc.
        let menu = ScriptedMenu<BindingAction>([.add, .edit("deep")], bailout: .done)
        var editedBindings: [Set<String>] = []
        let agent = try ZenCODEAgentProfileSetupRunner.configureModelBindingsForAgent(
            Self.bindingAgent,
            models: [],
            write: { _ in },
            selectAction: { title, _, selected in menu.answer(title, selected) },
            promptBinding: { agent, _ in
                #expect(agent == Self.bindingAgent)
                return Self.addedBinding
            },
            editBinding: { binding, agent, _ in
                #expect(binding.id == "deep")
                editedBindings.append(Set(agent.modelBindings.map(\.id)))
                return ZenCODEAgentProfileSetupRunner.profile(
                    basedOn: agent,
                    modelBindings: agent.modelBindings.filter { $0.id != "deep" },
                    defaultModelBindingID: agent.defaultModelBindingID
                )
            }
        )

        // The edit saw the binding added in this visit; Esc dropped both.
        #expect(editedBindings == [["fast", "deep", "extra"]])
        #expect(agent == Self.bindingAgent)
        #expect(menu.presentations == 3)
    }

    @Test
    func escInsideAddOrEditReturnsToTheBindingsAndDoneKeepsTheVisit() throws {
        // Add and Edit are cancelled, then Add succeeds and Done keeps it.
        let menu = ScriptedMenu<BindingAction>([.add, .edit("fast"), .add, .done], bailout: .done)
        var written: [String] = []
        var adds = 0
        let agent = try ZenCODEAgentProfileSetupRunner.configureModelBindingsForAgent(
            Self.bindingAgent,
            models: [],
            write: { written.append($0) },
            selectAction: { title, _, selected in menu.answer(title, selected) },
            promptBinding: { _, _ in
                adds += 1
                if adds == 1 {
                    throw ZenCODESetupError.cancelled
                }
                return Self.addedBinding
            },
            editBinding: { _, _, _ in throw ZenCODESetupError.cancelled }
        )

        #expect(Set(agent.modelBindings.map(\.id)) == ["fast", "deep", "extra"])
        #expect(agent.defaultModelBindingID == "fast")
        #expect(menu.presentations == 4)
        #expect(written == ["Add model binding cancelled.\n\n", "Edit binding cancelled.\n\n"])
    }

    // MARK: - Memory embeddings

    private typealias EmbeddingChoice = ZenCODESetupRunner.MemoryEmbeddingSetupChoice

    private static let openRouterProposal = ZenCODESetupRunner.MemoryEmbeddingOpenRouterProposal(
        endpoint: AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsEndpoint,
        model: AgentMemoryEmbeddingSettingsManifest.openRouterEmbeddingsModel,
        providerID: "openrouter"
    )

    @Test
    func escOnMemoryEmbeddingsEndsTheLoopWithCancelled() async {
        let menu = ScriptedMenu<EmbeddingChoice>(bailout: .bm25Only)
        await Self.expectCancelled {
            _ = try await ZenCODESetupRunner.promptMemoryEmbeddingSettings(
                existingSettings: nil,
                openRouterProposal: Self.openRouterProposal,
                selectChoice: { title, _, selected in menu.answer(title, selected) },
                followUp: { _ in
                    Issue.record("Esc on the menu must not open its follow-up prompts")
                    return ZenCODESetupRunner.MemoryEmbeddingSetupSelection(endpoint: nil)
                }
            )
        }
        #expect(menu.titles == ["Memory embeddings"])
    }

    // MARK: - Provider family

    @Test
    func escOnProviderFamilyEndsTheLoopWithCancelled() {
        let menu = ScriptedMenu<SetupProviderFamily>(bailout: .openAI)
        Self.expectCancelled {
            _ = try ZenCODESetupRunner.promptProviderKind(
                selectFamily: { title, _, selected in menu.answer(title, selected) },
                promptKind: { _ in
                    Issue.record("Esc on Provider family must not open a family submenu")
                    return .chatGPTSubscription
                }
            )
        }
        #expect(menu.titles == ["Provider family"])
    }

    // MARK: - Clean memory

    private typealias GraphItem = ZenCODESetupRunner.MemoryGraphInventoryItem
    private typealias CleanupAction = ZenCODESetupRunner.MemoryCleanupAction

    /// Runs `body` with a temporary support directory holding the memory
    /// graph of another project, passing it the URL of the graph file.
    private static func withProjectMemoryGraph(
        _ body: (URL) async throws -> Void
    ) async throws {
        let fileManager = FileManager.default
        let supportURL = fileManager.temporaryDirectory
            .appendingPathComponent("ZenCODE-setup-esc-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: supportURL) }
        let graphDirectoryURL = supportURL
            .appendingPathComponent(MemoryGraphLocation.directoryName, isDirectory: true)
            .appendingPathComponent("other-project", isDirectory: true)
        try fileManager.createDirectory(at: graphDirectoryURL, withIntermediateDirectories: true)
        let graphURL = graphDirectoryURL.appendingPathComponent(MemoryGraphLocation.graphFilename)
        try Data("{}".utf8).write(to: graphURL)
        try await AppStorageDirectory.withSupportDirectoryURL(supportURL) {
            try await body(graphURL)
        }
    }

    @Test
    func escOnTheGraphListEndsCleanMemory() async throws {
        try await Self.withProjectMemoryGraph { _ in
            let graphs = ScriptedMenu<GraphItem>()
            let actions = ScriptedMenu<CleanupAction>()
            var written: [String] = []
            try await ZenCODESetupRunner.runMemoryCleanupMenu(
                write: { written.append($0) },
                selectGraph: { title, _, selected in graphs.answer(title, selected) },
                selectAction: { title, _, selected in actions.answer(title, selected) },
                runAction: { _, _ in
                    Issue.record("Esc on the graph list must not run an action")
                }
            )

            #expect(graphs.titles == ["Clean memory: graph"])
            #expect(graphs.preselections.map(\.directoryName) == ["other-project"])
            #expect(actions.presentations == 0)
            #expect(written.isEmpty)
        }
    }

    // MARK: - Voice mode (the sherpa-onnx files of Linux)

    private typealias VoiceAction = ZenCODESetupRunner.VoiceModeAction

    private static let voiceManifest = AgentSettingsManifest(
        models: [],
        localExecAllowedCommands: ["ls"],
        responseLanguage: "it"
    )

    private struct VoiceModeVisit {
        let manifest: AgentSettingsManifest?
        let titles: [String]
        let preselections: [VoiceAction]
        let removalConfirmations: Int
        let downloadConfirmations: Int
    }

    /// One visit of the Voice mode menu, in an empty temporary installation,
    /// that answers the menu with `answers` and then with Esc.
    private static func visitVoiceMode(
        answering answers: [VoiceAction?],
        sendMode: (AgentSettingsManifest?) -> AgentSettingsManifest? = { _ in
            Issue.record("Send mode was not chosen")
            return nil
        }
    ) async throws -> VoiceModeVisit {
        let installation = SherpaOnnxVoiceInstallation(
            directoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("ZenCODE-setup-esc-voice-\(UUID().uuidString)/voice", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: installation.directoryURL.deletingLastPathComponent()) }
        let menu = ScriptedMenu<VoiceAction>(answers, bailout: .back)
        var removals = 0
        var downloads = 0
        let manifest = try await ZenCODESetupRunner.configureVoiceMode(
            manifest: voiceManifest,
            installation: installation,
            selectAction: { title, _, selected in menu.answer(title, selected) },
            configureSendMode: sendMode,
            confirmRemoval: { _ in
                // Esc on "Remove the voice mode files?".
                removals += 1
                throw ZenCODESetupError.cancelled
            },
            installVoice: { _, _ in
                // Esc on "Download … for voice mode?".
                downloads += 1
                throw ZenCODESetupError.cancelled
            }
        )
        #expect(!installation.hasInstalledFiles)
        return VoiceModeVisit(
            manifest: manifest,
            titles: menu.titles,
            preselections: menu.preselections,
            removalConfirmations: removals,
            downloadConfirmations: downloads
        )
    }

    @Test
    func escOnVoiceModeEndsTheLoopWithTheManifestItOpenedWith() async throws {
        let visit = try await Self.visitVoiceMode(answering: [])

        #expect(visit.manifest == Self.voiceManifest)
        #expect(visit.titles.count == 1)
        #expect(visit.titles.first?.hasPrefix("Voice mode (it)") == true)
        #expect(visit.removalConfirmations == 0)
        #expect(visit.downloadConfirmations == 0)
    }
}
