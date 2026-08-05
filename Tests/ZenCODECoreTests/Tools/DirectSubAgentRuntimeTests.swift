//
//  DirectSubAgentRuntimeTests.swift
//  ZenCODE
//
//  Created by ZenCODE on 02/07/26.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

private func builtInDirectSubAgentProfileResolver(
    _ payload: DirectSubAgentRuntime.RequestedAgentPayload
) -> AgentProfile? {
    DirectSubAgentRuntime.agentProfile(
        matching: payload,
        in: AgentProfileStore.defaultProfiles()
    )
}

@Suite
struct DirectSubAgentRuntimeTests {
    private static let catalogProviderID = UUID(
        uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    )!

    private static func catalogSnapshot(
        _ modelIDs: [String]
    ) -> AgentDelegationCatalogSnapshot {
        .available(
            models: modelIDs.map { modelID in
                AgentSettingsModelManifestFactory.remoteAPIModel(
                    title: nil,
                    modelID: modelID,
                    providerID: catalogProviderID,
                    providerName: "Test Provider",
                    baseURL: "https://tests.example.com/v1",
                    chatEndpoint: .chatCompletions,
                    configuredContextWindowLimit: nil,
                    generationParameterOverrides: nil,
                    thinkingSupport: .effort()
                )
            }
        )
    }

    @Test
    func agentWithoutProfileIsRejectedInsteadOfInheritingParentGrant() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in nil }
        )

        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await runtime.execute(
                rootSessionID: "root",
                toolCall: presentedToolCall(
                    id: "create-worker",
                    name: "agent.create",
                    argumentsObject: [
                        "name": "worker",
                        "role": "worker",
                        "prompt": "Do the delegated work"
                    ],
                    argumentsJSON: #"{"name":"worker","role":"worker","prompt":"Do the delegated work"}"#
                ),
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
                allowedToolNames: ["local.readFile", "local.writeFile"]
            )
        }
        #expect(await backend.createdSessions().isEmpty)
        await runtime.shutdown()
    }

    @Test
    func agentWithResolvedProfileUsesProfileGrantInsteadOfParentGrant() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: ["local.readFile", "local.writeFile"]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in developer }
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("implementation-worker"),
                "profile": .string("Developer")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["git.status"]
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == ["local.readFile", "local.writeFile", "skills.list", "skills.read"])
        await runtime.shutdown()
    }

    @Test
    func agentCreateRejectsToolOverrides() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: ["local.readFile", "local.writeFile"]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in developer }
        )

        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("implementation-worker"),
                    "profile": .string("Developer"),
                    "toolNames": .array([.string("local.writeFile")])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
                parentAllowedToolNames: ["git.status"]
            )
        }

        #expect(await backend.createdSessions().isEmpty)
        await runtime.shutdown()
    }

    @Test
    func emptyResolvedProfileGrantDoesNotFallBackToParentTools() async throws {
        let minimal = AgentProfile(
            id: "minimal-profile",
            name: "Minimal",
            tools: []
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in minimal }
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("minimal-worker"),
                "profile": .string("Minimal")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["local.readFile", "local.writeFile"]
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == ["skills.list", "skills.read"])
        await runtime.shutdown()
    }

    @Test
    func taskBoundAgentKeepsIntrinsicReportingToolsAlongsideProfileGrant() async throws {
        let reporter = AgentProfile(
            id: "reporter-profile",
            name: "Reporter",
            tools: ["local.readFile"]
        )
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "report", title: "Report findings")]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in reporter }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("reporter"),
                "profile": .string("Reporter"),
                "taskID": .string("report")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["git.status"],
            rootSessionID: "root"
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == [
            "local.readFile", "tasks.list", "tasks.get", "tasks.update",
            "skills.list", "skills.read"
        ])
        await runtime.shutdown()
    }

    @Test
    func readOnlyTaskBoundAgentGrantRetainsTaskUpdateAndExcludesOtherMutableCoreTools() async throws {
        let rawCompatibilityAlias = "agent.spawn"
        let reviewer = AgentProfile(
            id: "reviewer-profile",
            name: "Reviewer",
            readOnly: true,
            tools: ["files", "memory", "sub-agents", rawCompatibilityAlias]
        )
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "review", title: "Review findings")]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in reviewer }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("reviewer"),
                "profile": .string("Reviewer"),
                "taskID": .string("review")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["local.writeFile"],
            rootSessionID: "root"
        )

        let session = try #require(await backend.createdSessions().first)
        let allowedToolNames = try #require(session.allowedToolNames)
        let mutatingCoreNames = Set(DirectToolCatalog.coreMutatingDescriptors.map(\.name))

        #expect(allowedToolNames.isDisjoint(with: mutatingCoreNames))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("tasks.list"))
        #expect(allowedToolNames.contains("tasks.get"))
        #expect(allowedToolNames.contains("tasks.update"))
        #expect(allowedToolNames.contains(rawCompatibilityAlias))
        #expect(
            !DirectToolExecutor.isCoreCoordinationToolAllowed(
                rawCompatibilityAlias,
                allowedToolNames: allowedToolNames
            )
        )
        await runtime.shutdown()
    }

    @Test
    func skillToolsAreAlwaysOnAndProviderPropagatesToSubAgentBackend() async throws {
        let skillProvider = PromptSkillSessionProvider(
            skills: [
                PromptSkill(
                    canonicalName: "release-review",
                    title: "Release Review",
                    summary: "Review release changes before publishing.",
                    promptBody: "Review the release carefully.",
                    sourceDirectoryPath: "/tmp/skills/release-review",
                    sourceHash: "release-review-hash"
                )
            ]
        ).asToolProvider()

        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in AgentProfile(id: "worker", name: "Worker", tools: []) }
        )
        await runtime.installPromptSkillToolProvider(skillProvider)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "role": .string("worker"),
                "profile": .string("Worker")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-skill-propagation-tests"),
            parentAllowedToolNames: ["local.readFile", "local.writeFile"]
        )

        // The intrinsic prompt-skill tools must be present in every
        // sub-agent allowlist, regardless of the profile grant.
        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames?.isSuperset(of: PromptSkillToolProvider.toolNames) == true)

        // The parent session's skill provider must be registered on the
        // sub-agent backend so skills.list / skills.read can execute.
        let updates = await backend.toolProviderUpdates
        #expect(updates.count == 1)
        let propagated = try #require(updates.first)
        #expect(propagated.providers.count == 1)
        #expect(propagated.sessionID == session.id)
        let propagatedToolNames = Set(propagated.providers.flatMap(\.tools).map(\.name))
        #expect(propagatedToolNames == PromptSkillToolProvider.toolNames)

        await runtime.shutdown()
    }

    @Test
    func skillProviderNotRegisteredWhenAbsent() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in AgentProfile(id: "worker", name: "Worker", tools: []) }
        )
        // No promptSkillToolProvider installed.

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "role": .string("worker"),
                "profile": .string("Worker")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-skill-absent-tests"),
            parentAllowedToolNames: ["local.readFile"]
        )

        let session = try #require(await backend.createdSessions().first)
        // Skill tools are still in the allowlist (always-on), but no
        // provider update is sent because there is no skill provider.
        #expect(session.allowedToolNames?.isSuperset(of: PromptSkillToolProvider.toolNames) == true)
        let updates = await backend.toolProviderUpdates
        #expect(updates.isEmpty)

        await runtime.shutdown()
    }

    @Test
    func thoughtDeltasKeepOneStableThinkingPresentation() async throws {
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("thinking-worker"),
                "profile": .string("Developer"),
                "prompt": .string("Investigate the issue")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-thinking-tests"),
            parentAllowedToolNames: nil
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        while await backend.sentPromptCount() == 0 {
            await Task.yield()
        }

        await runtime.recordEvent(.thought("Considering the "), agentID: agentID)
        let firstSnapshot = try #require(await runtime.snapshots().first)
        let firstSignature = TerminalChat.subAgentOverviewSignature([firstSnapshot])
        #expect(firstSnapshot.currentActivity == "🤔 thinking…")
        #expect(firstSnapshot.currentActivity?.contains("Considering") == false)

        await runtime.recordEvent(.thought("available evidence"), agentID: agentID)
        await runtime.recordEvent(
            .thought(String(repeating: "x", count: 200)),
            agentID: agentID
        )
        await runtime.recordEvent(.thought("additional delta"), agentID: agentID)
        let latestSnapshot = try #require(await runtime.snapshots().first)

        #expect(latestSnapshot.currentActivity == "🤔 thinking…")
        #expect(
            TerminalChat.subAgentOverviewSignature([latestSnapshot])
                == firstSignature
        )

        await runtime.shutdown()
    }

    @Test
    func contentDeltasPublishOnceAtTheToolBoundaryUsingCompactTarget() async throws {
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("tool-worker"),
                "profile": .string("Developer"),
                "prompt": .string("Investigate the issue")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-content-tests"),
            parentAllowedToolNames: nil
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        while await backend.sentPromptCount() == 0 {
            await Task.yield()
        }

        await runtime.recordEvent(.thought("private reasoning"), agentID: agentID)
        let thinkingSnapshot = try #require(await runtime.snapshots().first)
        let thinkingSignature = TerminalChat.subAgentOverviewSignature([thinkingSnapshot])

        await runtime.recordEvent(.content("I’ll inspect "), agentID: agentID)
        await runtime.recordEvent(.content("the matching files."), agentID: agentID)
        let streamingSnapshot = try #require(await runtime.snapshots().first)
        #expect(streamingSnapshot.currentActivity == "🤔 thinking…")
        #expect(
            TerminalChat.subAgentOverviewSignature([streamingSnapshot])
                == thinkingSignature
        )

        let toolCall = presentedToolCall(
            id: "grep-call",
            name: "search.grep",
            argumentsObject: ["pattern": "needle"],
            argumentsJSON: #"{"pattern":"needle"}"#
        )
        await runtime.recordEvent(.toolCallStarted(toolCall), agentID: agentID)
        let startedSnapshot = try #require(await runtime.snapshots().first)
        let startedSignature = TerminalChat.subAgentOverviewSignature([startedSnapshot])

        #expect(startedSnapshot.currentActivity == "I’ll inspect the matching files.")
        #expect(startedSnapshot.currentToolName == "search.grep")
        #expect(startedSnapshot.currentToolTarget == "needle")
        #expect(startedSignature != thinkingSignature)

        await runtime.recordEvent(
            .toolCallCompleted(
                toolCall,
                DirectAgentToolResult(output: "match", summary: "1 match")
            ),
            agentID: agentID
        )
        let completedSnapshot = try #require(await runtime.snapshots().first)
        #expect(
            TerminalChat.subAgentOverviewSignature([completedSnapshot])
                == startedSignature
        )

        await runtime.recordEvent(.thought("more private reasoning"), agentID: agentID)
        await runtime.recordEvent(.content("Final "), agentID: agentID)
        await runtime.recordEvent(.content("answer."), agentID: agentID)
        await runtime.recordCompletion(
            DirectAgentResponse(
                text: "I’ll inspect the matching files. Final answer.",
                stopReason: "stop",
                modelID: "test-model"
            ),
            agentID: agentID
        )
        let finalSnapshot = try #require(await runtime.snapshots().first)
        #expect(finalSnapshot.latestContentPreview == "Final answer.")
        #expect(finalSnapshot.latestOutput == "I’ll inspect the matching files. Final answer.")
        #expect(finalSnapshot.latestOutputRevision == 1)
        #expect(finalSnapshot.currentActivity == nil)
        #expect(finalSnapshot.currentToolName == nil)

        await runtime.shutdown()
    }

    @Test
    func getAndWaitReturnCompleteLongOutputToTheModel() async throws {
        let endMarker = "PLANNER_OUTPUT_END"
        let plannerOutput = String(
            repeating: "p",
            count: DirectToolExecutor.defaultModelOutputLimit + 500
        ) + endMarker
        let backend = CapturingSubAgentRuntimeBackend(responseText: plannerOutput)
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentContextualBackendFactory: { _ in backend },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-output-tests",
            isDirectory: true
        )

        let createResult = await executor.execute(
            sessionID: "root",
            toolCall: presentedToolCall(
                id: "create-planner",
                name: "agent.create",
                argumentsObject: [
                    "name": "plan-author",
                    "profile": "Developer",
                    "prompt": "Write the complete plan"
                ],
                argumentsJSON: #"{"name":"plan-author","profile":"Developer","prompt":"Write the complete plan"}"#
            ),
            workingDirectory: workingDirectory
        )
        #expect(createResult.status == DirectAgentToolResult.Status.completed)

        let waitResult = await executor.execute(
            sessionID: "root",
            toolCall: presentedToolCall(
                id: "wait-planner",
                name: "agent.wait",
                argumentsObject: ["name": "plan-author"],
                argumentsJSON: #"{"name":"plan-author"}"#
            ),
            workingDirectory: workingDirectory
        )
        let getResult = await executor.execute(
            sessionID: "root",
            toolCall: presentedToolCall(
                id: "get-planner",
                name: "agent.get",
                argumentsObject: ["name": "plan-author"],
                argumentsJSON: #"{"name":"plan-author"}"#
            ),
            workingDirectory: workingDirectory
        )

        #expect(waitResult.modelOutput.contains(endMarker))
        #expect(getResult.modelOutput.contains(endMarker))
        #expect(!waitResult.modelOutput.contains("... truncated ..."))
        #expect(!waitResult.modelOutput.contains("truncated for model context"))
        #expect(!getResult.modelOutput.contains("... truncated ..."))
        #expect(!getResult.modelOutput.contains("truncated for model context"))

        await executor.subAgentRuntime.shutdown()
    }

    @Test
    func createAgentsUsesExplicitProfileModel() async throws {
        let planner = AgentProfile(
            id: "planner-profile",
            name: "Planner",
            tools: [],
            modelID: "planner-model",
            thinkingSelection: .high,
            capability: 7
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let recorder = SubAgentFactoryRecorder()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(
                    matching: payload,
                    in: [planner]
                )
            },
            modelCatalogProvider: { Self.catalogSnapshot(["planner-model"]) }
        )

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("planning-pass"),
                "role": .string("Planner"),
                "profile": .string("Planner"),
                "model": .string("planner-model")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let context = try #require(recorder.contexts.first)
        #expect(context.profile == planner)
        #expect(context.modelID?.hasSuffix(":planner-model") == true)
        #expect(context.thinkingSelection == .high)
        #expect(await backend.createdThinkingSelection() == .high)

        let snapshot = try #require(await runtime.snapshots().first)
        #expect(snapshot.profileID == planner.id)
        #expect(snapshot.profileName == planner.name)
        #expect(snapshot.modelID?.hasSuffix(":planner-model") == true)
        #expect(output.contains("planner-model"))
    }

    @Test
    func legacyCustomResolverMayReadSettingsWithoutReentrantFileLock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-legacy-resolver-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = AgentProfile(id: "custom", name: "Custom")
        let backend = CapturingSubAgentRuntimeBackend()

        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: [])
            )
            let runtime = DirectSubAgentRuntime(
                contextualBackendFactory: { _ in backend },
                profileResolver: { _ in
                    _ = AgentSettingsManifestStore.load()
                    return profile
                }
            )

            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object([
                            "profile": .string("Custom"),
                            "name": .string("child"),
                            "role": .string("role"),
                            "prompt": .string("work"),
                        ])
                    ])
                ],
                workingDirectory: directory,
                parentAllowedToolNames: nil
            )
            #expect(await backend.createdSessions().count == 1)
            await runtime.shutdown()
        }
    }

    @Test
    func createAgentsUsesExplicitModelBindingAuthorizedByProfile() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: [],
            modelBindings: [
                AgentModelBinding(
                    id: "balanced",
                    modelID: "balanced-model",
                    thinkingSelection: .low,
                    capability: 5
                ),
                AgentModelBinding(
                    id: "deep",
                    modelID: "deep-model",
                    thinkingSelection: .high,
                    capability: 9
                )
            ],
            defaultModelBindingID: "balanced"
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let recorder = SubAgentFactoryRecorder()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [developer])
            },
            modelCatalogProvider: {
                Self.catalogSnapshot(["balanced-model", "deep-model"])
            }
        )

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("architecture-pass"),
                "profile": .string("Developer"),
                "model": .string("deep")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let context = try #require(recorder.contexts.first)
        #expect(context.modelBinding?.id == "deep")
        #expect(context.modelID?.hasSuffix(":deep-model") == true)
        #expect(context.thinkingSelection == .high)
        #expect(context.capability == 9)
        #expect(await backend.createdThinkingSelection() == .high)
        #expect(output.contains("deep-model"))
    }

    @Test
    func createAgentsRejectsModelOutsideProfileBindings() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: [],
            modelBindings: [
                AgentModelBinding(modelID: "allowed-model", capability: 5)
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [developer])
            }
        )

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("unauthorized"),
                    "profile": .string("Developer"),
                    "modelID": .string("other-model")
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
                parentAllowedToolNames: nil
            )
            Issue.record("Expected an unauthorized model binding to be rejected.")
        } catch DirectSubAgentRuntimeError.modelNotAllowedForProfile(let modelID, let profile) {
            #expect(modelID == "other-model")
            #expect(profile == "Developer")
        }
    }

    @Test
    func createAgentsRejectsMissingProfileEvenWithExplicitModel() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in nil }
        )

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("unbound"),
                    "model": .string("other-model")
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
                parentAllowedToolNames: nil
            )
            Issue.record("Expected an explicit model without a profile to be rejected.")
        } catch DirectSubAgentRuntimeError.missingArgument(let argument) {
            #expect(argument == "profile or agent")
        }
    }

    @Test
    func createAgentsRejectsUnknownProfile() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in nil }
        )

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("review-pass"),
                    "profile": .string("Rewiever")
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
                parentAllowedToolNames: nil
            )
            Issue.record("Expected an unknown profile to be rejected.")
        } catch DirectSubAgentRuntimeError.agentProfileNotFound(let profile) {
            #expect(profile == "Rewiever")
        }
    }

    @Test
    func createAgentsWarnsWhenTaskComplexityExceedsProfileCapability() async throws {
        let minimal = AgentProfile(
            id: "minimal-profile",
            name: "Minimal",
            tools: [],
            modelID: "minimal-model",
            capability: 5
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [minimal])
            },
            modelCatalogProvider: { Self.catalogSnapshot(["minimal-model"]) }
        )
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "default", id: "graph", source: .manual, state: .active,
            tasks: [TaskDefinition(id: "hard-task", title: "Hard work", complexity: 9)]
        )
        await runtime.installTaskOrchestrator(orchestrator)

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Minimal"),
                "model": .string("minimal-model"),
                "taskID": .string("hard-task")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        #expect(output.contains("Warning: task \"hard-task\" has complexity 9"))
        #expect(output.contains("capability 5/10"))
        #expect(output.contains("capability gap of 4"))
        #expect(output.contains("role-compatible profile"))
    }

    @Test
    func capabilityAdvisoryUsesTheSelectedBinding() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: [],
            modelBindings: [
                AgentModelBinding(id: "light", modelID: "light-model", capability: 3),
                AgentModelBinding(id: "power", modelID: "power-model", capability: 8)
            ],
            defaultModelBindingID: "light"
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [developer])
            },
            modelCatalogProvider: {
                Self.catalogSnapshot(["light-model", "power-model"])
            }
        )
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "default", id: "graph", source: .manual, state: .active,
            tasks: [TaskDefinition(id: "hard-task", title: "Hard work", complexity: 9)]
        )
        await runtime.installTaskOrchestrator(orchestrator)

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "model": .string("power"),
                "taskID": .string("hard-task")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        #expect(output.contains("power-model"))
        #expect(output.contains("at capability 8/10"))
        #expect(output.contains("capability gap of 1"))
        #expect(!output.contains("capability gap of 6"))
    }

    @Test
    func agentCreateDescriptorUsesOneCanonicalBatchContract() throws {
        let descriptor = try #require(
            DirectToolCatalog.subAgentDescriptors.first { $0.name == "agent.create" }
        )

        #expect(descriptor.description.contains("canonical agents array"))
        #expect(descriptor.description.contains("each item requires profile and model"))
        #expect(descriptor.description.contains("exact profile and binding references"))
        #expect(!descriptor.description.contains(TaskRecord.agentSelectionPolicy))
        #expect(!descriptor.inputSchema.contains("\"modelID\""))
        #expect(!descriptor.inputSchema.contains("toolNames"))
        #expect(!descriptor.inputSchema.contains("oneOf"))
        #expect(!descriptor.inputSchema.contains("not"))
    }

    @Test
    func agentCreateDescriptorAdvertisesProviderNeutralBatchSchema() throws {
        let descriptor = try #require(
            DirectToolCatalog.subAgentDescriptors.first { $0.name == "agent.create" }
        )
        let schema = try #require(descriptor.schemaObject as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])

        #expect(Set(properties.keys) == ["agents"])
        #expect(schema["required"] as? [String] == ["agents"])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["oneOf"] == nil)
        #expect(schema["not"] == nil)

        let agents = try #require(properties["agents"] as? [String: Any])
        #expect(agents["type"] as? String == "array")
        #expect((agents["minItems"] as? NSNumber)?.intValue == 1)
        #expect((agents["maxItems"] as? NSNumber)?.intValue == 8)

        let item = try #require(agents["items"] as? [String: Any])
        let itemProperties = try #require(item["properties"] as? [String: Any])
        #expect(Set(itemProperties.keys) == ["profile", "model", "taskID", "prompt", "name", "role"])
        #expect(item["required"] as? [String] == ["profile", "model"])
        #expect(item["additionalProperties"] as? Bool == false)

        for legacyKey in [
            "agent", "agentName", "agent_name", "agentID", "agent_id",
            "profileName", "profile_name", "modelID", "model_id", "task_id",
            "message", "initialPrompt", "initial_prompt", "title", "items",
        ] {
            #expect(properties[legacyKey] == nil)
            #expect(itemProperties[legacyKey] == nil)
        }

        let wireCatalog = RemoteToolWireCatalog(descriptors: [descriptor])
        let responsesPayload = try #require(wireCatalog.responsesToolPayloads.first)
        let responsesParameters = try #require(
            responsesPayload["parameters"] as? [String: Any]
        )
        let chatPayload = try #require(wireCatalog.chatCompletionToolPayloads.first)
        let function = try #require(chatPayload["function"] as? [String: Any])
        let chatParameters = try #require(function["parameters"] as? [String: Any])
        for parameters in [responsesParameters, chatParameters] {
            #expect(parameters["required"] as? [String] == ["agents"])
            #expect(parameters["oneOf"] == nil)
            let wireProperties = try #require(parameters["properties"] as? [String: Any])
            let wireAgents = try #require(wireProperties["agents"] as? [String: Any])
            let wireItem = try #require(wireAgents["items"] as? [String: Any])
            #expect(wireItem["required"] as? [String] == ["profile", "model"])
        }
    }

    @Test
    func agentCreateParserSupportsCanonicalRootAndBatchForms() throws {
        let root = try DirectSubAgentRuntime.requestedAgentPayloads(
            from: [
                "name": .string("root-worker"),
                "profile": .string("Developer"),
                "model": .string("balanced"),
            ]
        )
        #expect(root.count == 1)
        #expect(root[0].name == "root-worker")
        #expect(root[0].profileReference == "Developer")

        let batch = try DirectSubAgentRuntime.requestedAgentPayloads(
            from: [
                "agents": .array([
                    .object([
                        "name": .string("first"),
                        "profile": .string("Developer"),
                        "model": .string("balanced"),
                    ]),
                    .object([
                        "name": .string("second"),
                        "profile": .string("Reviewer"),
                        "model": .string("fast"),
                    ]),
                ]),
            ]
        )
        #expect(batch.map(\.name) == ["first", "second"])
        #expect(batch.map(\.profileReference) == ["Developer", "Reviewer"])

        let legacyObjectBatch = try DirectSubAgentRuntime.requestedAgentPayloads(
            from: [
                "items": .object([
                    "title": .string("legacy-batch-worker"),
                    "agent": .string("Developer"),
                    "modelID": .string("balanced"),
                ]),
            ]
        )
        #expect(legacyObjectBatch.count == 1)
        #expect(legacyObjectBatch[0].name == "legacy-batch-worker")
        #expect(legacyObjectBatch[0].profileReference == "Developer")
        #expect(legacyObjectBatch[0].requestedModelID == "balanced")

        let matchingCanonicalAndLegacyBatches = try DirectSubAgentRuntime.requestedAgentPayloads(
            from: [
                "agents": .array([
                    .object([
                        "name": .string("equivalent"),
                        "profile": .string("Developer"),
                        "model": .string("balanced"),
                    ]),
                ]),
                "items": .array([
                    .object([
                        "title": .string("equivalent"),
                        "agent": .string("developer"),
                        "modelID": .string("BALANCED"),
                    ]),
                ]),
            ]
        )
        #expect(matchingCanonicalAndLegacyBatches.count == 1)
        #expect(matchingCanonicalAndLegacyBatches[0].name == "equivalent")

        do {
            _ = try DirectSubAgentRuntime.requestedAgentPayloads(
                from: [
                    "profile": .string("Developer"),
                    "agents": .array([
                        .object(["profile": .string("Reviewer")]),
                    ]),
                ]
            )
            Issue.record("Expected mixed root and batch forms to be rejected.")
        } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
            #expect(message.contains("root agent fields"))
        }
    }

    @Test
    func agentCreateParserIgnoresBlankAliasesAndAcceptsEquivalentLegacyValues() throws {
        let payload = try DirectSubAgentRuntime.requestedAgentPayload(
            from: .object([
                "name": .string("   "),
                "title": .string("legacy-worker"),
                "profile": .string("  "),
                "agent": .string("Developer"),
                "agentName": .string("developer"),
                "model": .string("  "),
                "modelID": .string("Deep"),
                "model_id": .string("deep"),
                "taskID": .string("\n"),
                "task_id": .string("task-1"),
                "prompt": .string("\t"),
                "message": .string("Inspect the parser"),
            ]),
            fallbackIndex: 0
        )

        #expect(payload.name == "legacy-worker")
        #expect(payload.profileReference == "Developer")
        #expect(payload.requestedModelID == "Deep")
        #expect(payload.taskID == "task-1")
        #expect(payload.prompt == "Inspect the parser")
    }

    @Test
    func agentCreateParserRejectsConflictingAliasesAndBatches() throws {
        do {
            _ = try DirectSubAgentRuntime.requestedAgentPayload(
                from: .object([
                    "profile": .string("Developer"),
                    "agent": .string("Reviewer"),
                ]),
                fallbackIndex: 0
            )
            Issue.record("Expected conflicting profile aliases to be rejected.")
        } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
            #expect(message.contains("profile aliases"))
            #expect(message.contains("profile, agent"))
        }

        do {
            _ = try DirectSubAgentRuntime.requestedAgentPayloads(
                from: [
                    "agents": .array([.object(["profile": .string("Developer")])]),
                    "items": .array([.object(["profile": .string("Reviewer")])]),
                ]
            )
            Issue.record("Expected conflicting batch aliases to be rejected.")
        } catch DirectSubAgentRuntimeError.invalidArgument(let message) {
            #expect(message.contains("batch aliases"))
            #expect(message.contains("agents, items"))
        }
    }

    @Test
    func agentCreateParserRejectsMalformedAliasesAndBatchRootOverrides() throws {
        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.requestedAgentPayloads(
                from: [
                    "agents": .string("not-a-batch"),
                    "items": .array([
                        .object([
                            "profile": .string("Developer"),
                            "model": .string("binding:developer"),
                        ]),
                    ]),
                ]
            )
        }

        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.requestedAgentPayloads(
                from: [
                    "agents": .array([.string("not-an-object")]),
                ]
            )
        }

        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.requestedAgentPayloads(
                from: [
                    "agents": .array([
                        .object([
                            "profile": .string("Developer"),
                            "model": .string("binding:developer"),
                        ]),
                    ]),
                    "tools": .array([.string("local.exec")]),
                ]
            )
        }

        #expect(throws: DirectSubAgentRuntimeError.self) {
            try DirectSubAgentRuntime.requestedAgentPayload(
                from: .object([
                    "profile": .string("Developer"),
                    "model": .object(["unexpected": .bool(true)]),
                ]),
                fallbackIndex: 0
            )
        }
    }

    @Test
    func agentCreateRequiresModelWhenTheProfileHasBindings() async throws {
        let developer = AgentProfile(
            id: "developer-profile",
            name: "Developer",
            tools: [],
            modelBindings: [AgentModelBinding(modelID: "balanced-model")]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(matching: payload, in: [developer])
            }
        )

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("worker"),
                    "profile": .string("Developer"),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
                parentAllowedToolNames: nil
            )
            Issue.record("Expected a profile with bindings to require model.")
        } catch DirectSubAgentRuntimeError.missingArgument(let argument) {
            #expect(argument == "model")
        }

        #expect(await backend.createdSessions().isEmpty)
        await runtime.shutdown()
    }

    @Test
    func createAgentWithoutModelProfileInheritsParentConfiguration() async throws {
        let minimal = AgentProfile(
            id: "minimal-profile",
            name: "Minimal",
            tools: []
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let recorder = SubAgentFactoryRecorder()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(
                    matching: payload,
                    in: [minimal]
                )
            }
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("quick-task"),
                "role": .string("Minimal"),
                "profile": .string("Minimal")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let context = try #require(recorder.contexts.first)
        #expect(context.profile == minimal)
        #expect(context.modelID == nil)
        #expect(context.thinkingSelection == nil)
    }

    @Test
    func applyingSubAgentBackendContextUsesOnlyAnExplicitlyResolvedBinding() {
        let parentConfig = AgentRuntimeConfiguration(
            modelID: "parent-model",
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            maxToolRounds: 4,
            verboseLogging: false,
            toolAuthorizationHandler: nil
        )
        let profile = AgentProfile(
            id: "builder",
            name: "Builder",
            modelID: "builder-model"
        )
        let context = DirectSubAgentRuntime.BackendContext(
            requestedName: "Builder",
            requestedRole: "worker",
            profile: profile,
            modelBinding: AgentModelBinding(
                id: "builder-model",
                modelID: "builder-model",
                capability: 5
            ),
            modelID: "binding:builder-model"
        )
        let result = parentConfig.applyingSubAgentBackendContext(context)
        #expect(result.modelID == "builder-model")
    }

    @Test
    func applyingSubAgentBackendContextPreservesModelWhenProfileHasNoModel() {
        let parentConfig = AgentRuntimeConfiguration(
            modelID: "parent-model",
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            maxToolRounds: 4,
            verboseLogging: false,
            toolAuthorizationHandler: nil
        )
        let profile = AgentProfile(
            id: "minimal",
            name: "Minimal"
        )
        let context = DirectSubAgentRuntime.BackendContext(
            requestedName: "Minimal",
            requestedRole: "worker",
            profile: profile
        )
        let result = parentConfig.applyingSubAgentBackendContext(context)
        #expect(result.modelID == "parent-model")
    }

    @Test
    func applyingSubAgentBackendContextPreservesModelWhenLockedToSession() {
        let parentConfig = AgentRuntimeConfiguration(
            modelID: "local-model",
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            maxToolRounds: 4,
            verboseLogging: false,
            locksModelToSession: true,
            toolAuthorizationHandler: nil
        )
        let profile = AgentProfile(
            id: "builder",
            name: "Builder",
            modelID: "some-other-model"
        )
        let context = DirectSubAgentRuntime.BackendContext(
            requestedName: "Builder",
            requestedRole: "worker",
            profile: profile
        )
        let result = parentConfig.applyingSubAgentBackendContext(context)
        #expect(result.modelID == "local-model")
    }

    @Test
    func createAgentsUseUniqueEphemeralSessionsWithoutCacheKeys() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object([
                        "name": .string("planner-one"),
                        "profile": .string("Developer"),
                        "prompt": .string("Plan one")
                    ]),
                    .object([
                        "name": .string("planner-two"),
                        "profile": .string("Developer"),
                        "prompt": .string("Plan two")
                    ])
                ])
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let createdSessions = await backend.createdSessions()
        let sessionIDs = createdSessions.map(\.id)

        #expect(createdSessions.count == 2)
        #expect(Set(sessionIDs).count == 2)
        #expect(sessionIDs.allSatisfy { $0.hasPrefix("agent_") && $0.hasSuffix("_session") })
        #expect(createdSessions.allSatisfy { $0.cacheKey == nil })
        #expect(createdSessions.allSatisfy { $0.historyCount == 0 })
    }

    @Test
    func overviewKeepsSequentiallyCreatedSubAgentsWhileEarlierOnesStillWork() async throws {
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory: { _ in backend },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
        let runtime = await executor.subAgentRuntime
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests",
            isDirectory: true
        )

        for name in ["first", "second", "third"] {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string(name),
                    "profile": .string("Developer"),
                    "prompt": .string("Work on \(name)")
                ],
                workingDirectory: workingDirectory,
                parentAllowedToolNames: nil
            )
        }

        // One `agent.create` per call must be presented exactly like a single
        // parallel batch: every sub-agent that is still working stays visible.
        let overview = await executor.subAgentSnapshots()
        #expect(Set(overview.map(\.name)) == ["first", "second", "third"])
        #expect(Set(overview.filter(\.pending).map(\.name)) == ["first", "second", "third"])

        await runtime.shutdown()
    }

    @Test
    func overviewShowsMessagedSubAgentThatResumesWorkAfterALaterBatch() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory: { _ in backend },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
        let runtime = await executor.subAgentRuntime
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests",
            isDirectory: true
        )

        for name in ["first", "second"] {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string(name),
                    "profile": .string("Developer"),
                    "prompt": .string("Work on \(name)")
                ],
                workingDirectory: workingDirectory,
                parentAllowedToolNames: nil
            )
            _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])
        }

        #expect(await executor.subAgentSnapshots().map(\.name) == ["second"])

        let firstID = try #require(
            await runtime.snapshots().first { $0.name == "first" }?.id
        )
        _ = try await runtime.messageAgents(
            arguments: [
                "id": .string(firstID),
                "message": .string("Follow up on the earlier finding")
            ]
        )

        // A follow-up message restarts that sub-agent, so the overview has to
        // present it instead of the finished agents of the previous batch.
        #expect(await executor.subAgentSnapshots().map(\.name) == ["first"])

        await runtime.shutdown()
    }

    @Test
    func overviewSnapshotsStartAFreshBatchWhenNoSubAgentIsWorking() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory: { _ in backend },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
        let runtime = await executor.subAgentRuntime
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests",
            isDirectory: true
        )

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first-a"), "profile": .string("Developer")]),
                    .object(["name": .string("first-b"), "profile": .string("Developer")])
                ])
            ],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil
        )

        let firstOverview = await executor.subAgentSnapshots()
        #expect(Set(firstOverview.map(\.name)) == ["first-a", "first-b"])

        _ = try await runtime.createAgents(
            arguments: ["name": .string("second"), "profile": .string("Developer")],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil
        )

        let currentOverview = await executor.subAgentSnapshots()
        let allSnapshots = await runtime.snapshots()
        let listedAgents = await runtime.listAgents(arguments: [:])

        #expect(currentOverview.map(\.name) == ["second"])
        #expect(Set(allSnapshots.map(\.name)) == ["first-a", "first-b", "second"])
        #expect(listedAgents.contains("first-a"))
        #expect(listedAgents.contains("first-b"))
        #expect(listedAgents.contains("second"))
    }
    @Test
    func taskClaimAndReportCompletionUpdateTaskAutomatically() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "Report")]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "report complete")
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend }, profileResolver: builtInDirectSubAgentProfileResolver)
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("reporter"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the report"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])

        let task = try await orchestrator.task(sessionID: "root", taskID: "task-a")
        let agent = try #require(await runtime.snapshots().first)
        #expect(task.task.status == .completed)
        #expect(task.task.attempts.count == 1)
        #expect(task.task.attempts[0].agentID == agent.id)
        #expect(task.task.attempts[0].output == "report complete")
        #expect(agent.rootSessionID == "root")
        #expect(agent.taskID == "task-a")
        #expect(agent.taskAttemptID == task.task.attempts[0].id)
        #expect(agent.taskAttemptOrdinal == 1)
        #expect(await backend.didInstallTaskOrchestrator())
    }

    @Test
    func workflowAttemptIsFencedAfterValidationFailureUntilRetryCreatesANewAgent() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "implementation",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "implementation complete")
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend }, profileResolver: builtInDirectSubAgentProfileResolver)
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker-1"),
                "profile": .string("Developer"),
                "taskID": .string("implementation"),
                "prompt": .string("Implement the change"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])

        let firstAgent = try #require(await runtime.snapshots().first)
        let completed = try await orchestrator.task(
            sessionID: "root",
            taskID: "implementation"
        ).task
        let firstAttemptID = try #require(completed.attempts.first?.id)
        #expect(completed.status == .awaitingValidation)
        #expect(completed.activeAttemptID == nil)
        #expect(await backend.sentPromptCount() == 1)

        let failedValidation = try await orchestrator.validateTaskResult(
            sessionID: "root",
            taskID: "implementation",
            succeeded: false,
            failureReason: "focused validation failed"
        )
        #expect(failedValidation.task.status == .failed)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await runtime.messageAgents(
                arguments: [
                    "id": .string(firstAgent.id),
                    "message": .string("Try a correction"),
                ]
            )
        }

        try await runtime.queuePrompt("stale correction", for: firstAgent.id)
        _ = await runtime.waitForAgents(arguments: [
            "id": .string(firstAgent.id),
            "timeoutSeconds": .number(5),
        ])
        #expect(await backend.sentPromptCount() == 1)
        #expect(await runtime.snapshots().first?.pending == false)

        _ = try await orchestrator.retryTask(sessionID: "root", taskID: "implementation")
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker-2"),
                "profile": .string("Developer"),
                "taskID": .string("implementation"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        let agentsAfterRetry = await runtime.snapshots()
        let secondAgent = try #require(agentsAfterRetry.first { $0.id != firstAgent.id })
        let retried = try await orchestrator.task(
            sessionID: "root",
            taskID: "implementation"
        ).task
        #expect(retried.status == .inProgress)
        #expect(retried.attempts.count == 2)
        #expect(retried.activeAttemptID == secondAgent.taskAttemptID)
        #expect(secondAgent.taskAttemptID != firstAttemptID)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await runtime.messageAgents(
                arguments: [
                    "id": .string(firstAgent.id),
                    "message": .string("Reuse the old attempt"),
                ]
            )
        }

        #expect(await runtime.closeAgent(id: firstAgent.id))
        let afterClosingOldAgent = try await orchestrator.task(
            sessionID: "root",
            taskID: "implementation"
        ).task
        #expect(afterClosingOldAgent.status == .inProgress)
        #expect(afterClosingOldAgent.activeAttemptID == secondAgent.taskAttemptID)
        await runtime.shutdown()
    }

    @Test
    func singleTasklessDelegationRemainsAllowedOutsideAWorkflow() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("focused-lookup"), "profile": .string("Developer")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        #expect(await runtime.snapshots().map(\.name) == ["focused-lookup"])
    }

    @Test
    func tasklessSubAgentPromptReceivesWorkflowPolicyWhenItCanCoordinate() {
        let taskTools: Set<String> = [
            "tasks.create",
            "tasks.list",
            "tasks.update",
            "agent.create",
        ]
        let tasklessPrompt = DirectSubAgentRuntime.systemPrompt(
            name: "coordinator",
            role: "Coordinator",
            allowedToolNames: taskTools
        )
        let taskBoundPrompt = DirectSubAgentRuntime.systemPrompt(
            name: "worker",
            role: "Worker",
            taskID: "task-1",
            allowedToolNames: taskTools
        )

        #expect(tasklessPrompt.contains("Task workflow policy:"))
        #expect(taskBoundPrompt.contains("must not change dependencies"))
        #expect(!taskBoundPrompt.contains("Task workflow policy:"))
    }

    @Test
    func idleTasklessDelegationBlocksAnotherWorkflowAndGraphActivationUntilClosed() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("focused-lookup"), "profile": .string("Developer")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        do {
            _ = try await runtime.createAgents(
                arguments: ["name": .string("second-lookup"), "profile": .string("Developer")],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
            Issue.record("A second idle taskless delegation should require a task graph")
        } catch let error as DirectSubAgentRuntimeError {
            guard case .taskGraphRequiredForCoordinatedDelegation = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        }

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await orchestrator.createGraph(
                sessionID: "root",
                id: "graph",
                source: .manual,
                state: .active,
                tasks: [TaskDefinition(id: "tracked", title: "Tracked")]
            )
        }

        let agentID = try #require(await runtime.snapshots().first?.id)
        _ = try await runtime.closeAgent(arguments: ["id": .string(agentID)])
        let graph = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "tracked", title: "Tracked")]
        )
        #expect(graph.state == .active)
    }

    @Test
    func tasklessAgentCannotBeResumedAfterAGraphBecomesActive() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("lookup"),
                "profile": .string("Developer"),
                "prompt": .string("Inspect the current concern")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])
        let agentID = try #require(await runtime.snapshots().first?.id)

        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "tracked", title: "Tracked")]
        )

        do {
            _ = try await runtime.messageAgents(
                arguments: [
                    "id": .string(agentID),
                    "message": .string("Continue the lookup")
                ],
                parentAllowedToolNames: nil
            )
            Issue.record("An active graph should reject resuming a taskless agent")
        } catch let error as DirectSubAgentRuntimeError {
            guard case let .taskIDRequiredForActiveTaskGraph(graphID) = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
            #expect(graphID == "graph")
        }
    }

    @Test
    func tasklessIdleAgentsCannotBeStartedTogetherThroughAgentMessage() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first"), "profile": .string("Developer")]),
                    .object(["name": .string("second"), "profile": .string("Developer")]),
                ])
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: ["agent.create"],
            rootSessionID: "root"
        )
        let agentIDs = await runtime.snapshots().map(\.id)

        do {
            _ = try await runtime.messageAgents(
                arguments: [
                    "ids": .array(agentIDs.map { .string($0) }),
                    "message": .string("Start the lookup")
                ],
                parentAllowedToolNames: nil
            )
            Issue.record("Starting multiple taskless idle agents should require a task graph")
        } catch let error as DirectSubAgentRuntimeError {
            guard case .taskGraphRequiredForCoordinatedDelegation = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        }
    }

    @Test
    func parallelTasklessDelegationRequiresTaskGraphBeforeCreatingAgents() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("first"), "profile": .string("Developer")]),
                        .object(["name": .string("second"), "profile": .string("Developer")]),
                    ])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
            Issue.record("Parallel taskless delegation should require a task graph")
        } catch let error as DirectSubAgentRuntimeError {
            guard case .taskGraphRequiredForCoordinatedDelegation = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        }

        #expect(await runtime.snapshots().isEmpty)
        #expect(try await orchestrator.graphSnapshot(sessionID: "root") == nil)
    }

    @Test
    func activeTaskGraphRequiresTaskIDBeforeAnyClaimIsCreated() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "tracked", title: "Tracked work"),
                TaskDefinition(id: "other", title: "Other work"),
            ]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object([
                            "name": .string("tracked"),
                            "profile": .string("Developer"),
                            "taskID": .string("tracked"),
                        ]),
                        .object(["name": .string("untracked"), "profile": .string("Developer")]),
                    ])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
            Issue.record("An active graph should require taskID for every delegated agent")
        } catch let error as DirectSubAgentRuntimeError {
            guard case let .taskIDRequiredForActiveTaskGraph(graphID) = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
            #expect(graphID == "graph")
        }

        #expect(await runtime.snapshots().isEmpty)
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "tracked"
        ).task.attempts.isEmpty)
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "other"
        ).task.attempts.isEmpty)
    }

    @Test
    func draftTaskGraphDoesNotRequireTaskIDForAStandalonePlannerDelegation() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "plan-draft",
            source: .plan(planID: "plan-draft"),
            state: .draft,
            tasks: [TaskDefinition(id: "plan-draft-1", title: "Draft task")]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("plan-author"), "profile": .string("Planner")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        #expect(await runtime.snapshots().map(\.name) == ["plan-author"])
    }

    @Test
    func secondConcurrentTasklessDelegationRequiresTaskGraph() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in
                CapturingSubAgentRuntimeBackend(blocksPrompts: true)
            },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("first"),
                "profile": .string("Developer"),
                "prompt": .string("Investigate the first concern")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        do {
            _ = try await runtime.createAgents(
                arguments: ["name": .string("second"), "profile": .string("Developer")],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
            Issue.record("A concurrent taskless delegation should require a task graph")
        } catch let error as DirectSubAgentRuntimeError {
            guard case .taskGraphRequiredForCoordinatedDelegation = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        }

        #expect(await runtime.snapshots().map(\.name) == ["first"])
        await runtime.shutdown()
    }

    @Test
    func taskBoundParallelDelegationClaimsIndependentTasks() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "first", title: "First"),
                TaskDefinition(id: "second", title: "Second"),
            ]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object([
                        "name": .string("first"),
                        "profile": .string("Developer"),
                        "taskID": .string("first"),
                    ]),
                    .object([
                        "name": .string("second"),
                        "profile": .string("Developer"),
                        "task_id": .string("second"),
                    ]),
                ])
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        #expect(await runtime.snapshots().count == 2)
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "first"
        ).task.status == .inProgress)
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "second"
        ).task.status == .inProgress)
    }

    @Test
    func parallelDelegationRemainsAvailableWhenTaskWorkflowToolsAreUnavailable() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first"), "profile": .string("Developer")]),
                    .object(["name": .string("second"), "profile": .string("Developer")]),
                ])
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: ["agent.create"],
            rootSessionID: "root"
        )

        #expect(await runtime.snapshots().count == 2)
    }

    @Test
    func tasksNamespacePrefixEnforcesTheCoordinatedDelegationGuard() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("first"), "profile": .string("Developer")]),
                        .object(["name": .string("second"), "profile": .string("Developer")]),
                    ])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: ["agent.", "tasks."],
                rootSessionID: "root"
            )
            Issue.record("The task namespace prefix should require a task graph")
        } catch let error as DirectSubAgentRuntimeError {
            guard case .taskGraphRequiredForCoordinatedDelegation = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        }
    }

    @Test
    func delegatedTaskCompletionCompletesTask() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "Implement")]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "implementation complete")
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend }, profileResolver: builtInDirectSubAgentProfileResolver)
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Implement"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])

        let task = try await orchestrator.task(sessionID: "root", taskID: "task-a")
        #expect(task.task.status == .completed)
        #expect(task.task.result?.output == "implementation complete")
        await runtime.shutdown()
    }

    @Test
    func taskClaimBatchIsAtomicWhenOneTaskIsNotRunnable() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "task-a", title: "A"),
                TaskDefinition(id: "task-b", title: "B", dependsOn: ["task-a"]),
            ]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object([
                            "name": .string("a"),
                            "profile": .string("Developer"),
                            "taskID": .string("task-a"),
                        ]),
                        .object([
                            "name": .string("b"),
                            "profile": .string("Developer"),
                            "taskID": .string("task-b"),
                        ]),
                    ])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
        }

        #expect(await runtime.snapshots().isEmpty)
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "task-a"
        ).task.attempts.isEmpty)
    }

    @Test
    func duplicateTaskClaimIsRejected() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "A")]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)
        let arguments: [String: JSONValue] = [
            "profile": .string("Developer"),
            "taskID": .string("task-a"),
        ]
        _ = try await runtime.createAgents(
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await runtime.createAgents(
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
        }
        #expect(await runtime.snapshots().count == 1)
    }

    @Test
    func closeCancelsTaskAndShutdownInterruptsTask() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "close-task", title: "Close"),
                TaskDefinition(id: "shutdown-task", title: "Shutdown"),
            ]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("closer"),
                "profile": .string("Developer"),
                "taskID": .string("close-task"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        let closeAgent = try #require(await runtime.snapshots().first)
        _ = try await runtime.closeAgent(arguments: ["id": .string(closeAgent.id)])
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "close-task"
        ).task.status == .cancelled)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("shutdown"),
                "profile": .string("Developer"),
                "taskID": .string("shutdown-task"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.shutdown()
        let interrupted = try await orchestrator.task(
            sessionID: "root", taskID: "shutdown-task"
        ).task
        #expect(interrupted.status == .blocked)
        #expect(interrupted.attempts.last?.status == .interrupted)
    }

    @Test
    func createRejectsOversizedBatches() async throws {
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        let oversized = (0...DirectSubAgentRuntime.maximumAgentsPerCreate).map { index in
            JSONValue.object(["name": .string("report-\(index)")])
        }

        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await runtime.createAgents(
                arguments: ["agents": .array(oversized)],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil
            )
        }
        #expect(await runtime.snapshots().isEmpty)
    }

    @Test
    func taskCancellationClosesOnlyTheAssignedAgentInTheSameRootSession() async throws {
        let orchestrator = SessionTaskOrchestrator()
        for sessionID in ["root-a", "root-b"] {
            _ = try await orchestrator.createGraph(
                sessionID: sessionID,
                id: "graph",
                source: .manual,
                state: .active,
                tasks: [TaskDefinition(id: "shared-task", title: sessionID)]
            )
        }
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend }, profileResolver: builtInDirectSubAgentProfileResolver)
        await runtime.installTaskOrchestrator(orchestrator)
        for sessionID in ["root-a", "root-b"] {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string(sessionID),
                    "profile": .string("Developer"),
                    "taskID": .string("shared-task"),
                    "prompt": .string("Wait"),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: sessionID
            )
        }

        #expect(await runtime.closeAgentAssigned(
            to: "shared-task",
            rootSessionID: "root-b"
        ))
        let snapshots = await runtime.snapshots()
        #expect(snapshots.first(where: { $0.rootSessionID == "root-b" })?.status == .closed)
        #expect(snapshots.first(where: { $0.rootSessionID == "root-a" })?.status != .closed)
        #expect(try await orchestrator.task(
            sessionID: "root-b", taskID: "shared-task"
        ).task.status == .cancelled)
        #expect(try await orchestrator.task(
            sessionID: "root-a", taskID: "shared-task"
        ).task.status == .inProgress)

        #expect(await runtime.interruptAgents(rootSessionID: "root-a") == 1)
        let interrupted = try await orchestrator.task(
            sessionID: "root-a", taskID: "shared-task"
        ).task
        #expect(interrupted.status == .blocked)
        #expect(interrupted.attempts.last?.status == .interrupted)
        await runtime.shutdown()
    }
}

private final class SubAgentFactoryRecorder: Sendable {
    private let recordedContexts = Mutex<[DirectSubAgentRuntime.BackendContext]>([])

    var contexts: [DirectSubAgentRuntime.BackendContext] {
        recordedContexts.withLock { $0 }
    }

    func append(_ context: DirectSubAgentRuntime.BackendContext) {
        recordedContexts.withLock { $0.append(context) }
    }
}

private actor CapturingSubAgentRuntimeBackend: AgentRuntimeBackend {
    struct CreatedSession: Sendable {
        let id: String
        let cacheKey: String?
        let historyCount: Int
        let allowedToolNames: Set<String>?
    }

    private var thinkingSelection: AgentThinkingSelection?
    private var sessions: [CreatedSession] = []
    private let responseText: String
    private let blocksPrompts: Bool
    private var sentPrompts: [String] = []
    private var installedTaskOrchestrator = false
    private(set) var toolProviderUpdates: [(providers: [AgentToolProvider], sessionID: String?)] = []

    init(responseText: String = "done", blocksPrompts: Bool = false) {
        self.responseText = responseText
        self.blocksPrompts = blocksPrompts
    }

    func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        installedTaskOrchestrator = true
    }

    func updateToolProviders(
        _ providers: [AgentToolProvider],
        sessionID: String?
    ) async {
        toolProviderUpdates.append((providers, sessionID))
    }

    func createSession(
        id: String,
        cwd _: String,
        systemPrompt _: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        sessions.append(
            CreatedSession(
                id: id,
                cacheKey: cacheKey,
                historyCount: history.count,
                allowedToolNames: allowedToolNames
            )
        )
        self.thinkingSelection = thinkingSelection
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        sentPrompts.append(prompt)
        if blocksPrompts {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        return DirectAgentResponse(
            text: responseText,
            stopReason: "stop",
            modelID: "test-model"
        )
    }

    func snapshotSession(id _: String) -> AgentRuntimeSessionSnapshot? {
        nil
    }

    func didInstallTaskOrchestrator() -> Bool {
        installedTaskOrchestrator
    }

    func createdThinkingSelection() -> AgentThinkingSelection? {
        thinkingSelection
    }

    func createdSessions() -> [CreatedSession] {
        sessions
    }

    func sentPromptCount() -> Int {
        sentPrompts.count
    }
}
