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

@Suite(.timeLimit(.minutes(1)))
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
        #expect(session.allowedToolNames == [
            "local.readFile", "local.writeFile", "skills.list", "skills.read",
            "agent.list", "agent.get", "agent.message"
        ])
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
        #expect(session.allowedToolNames == [
            "skills.list", "skills.read", "agent.list", "agent.get", "agent.message"
        ])
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
            "skills.list", "skills.read", "agent.list", "agent.get", "agent.message"
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
            .subtracting(["agent.message"])

        #expect(allowedToolNames.isDisjoint(with: mutatingCoreNames))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("tasks.list"))
        #expect(allowedToolNames.contains("tasks.get"))
        #expect(allowedToolNames.contains("tasks.update"))
        #expect(allowedToolNames.contains("agent.list"))
        #expect(allowedToolNames.contains("agent.get"))
        #expect(allowedToolNames.contains("agent.message"))
        #expect(!allowedToolNames.contains("agent.create"))
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
        await backend.waitUntilSentPromptCount(1)

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
        await backend.waitUntilSentPromptCount(1)

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
    func delegatedToolLifecycleForwardsLosslessEventsOnly() async throws {
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        let recorder = DirectSubAgentToolEventRecorder()
        await runtime.updateSubAgentToolEventHandler { event in
            await recorder.record(event)
        }

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("tool-worker"),
                "profile": .string("Developer"),
                "prompt": .string("Inspect the implementation")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tool-events"),
            parentAllowedToolNames: nil
        )
        let agentID = try #require(await runtime.snapshots().first?.id)
        await backend.waitUntilSentPromptCount(1)
        #expect(await backend.hasSubAgentToolEventHandler())

        await runtime.recordEvent(.thought("private reasoning"), agentID: agentID)
        let toolCall = presentedToolCall(
            id: "edit-call",
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/Example.swift",
                "old": "old",
                "new": "new"
            ],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "Updated", summary: "Updated")
        await runtime.recordEvent(.toolCallStarted(toolCall), agentID: agentID)
        await runtime.recordEvent(
            .toolCallCompleted(toolCall, result),
            agentID: agentID
        )

        let events = await recorder.snapshot()
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.agentID == agentID })
        #expect(events.allSatisfy { $0.agentName == "tool-worker" })
        #expect(events.allSatisfy { $0.toolCall.id == toolCall.id })
        if events.count == 2 {
            if case .started = events[0].lifecycle {
                // Expected lifecycle.
            } else {
                Issue.record("First delegated tool event was not started")
            }
            if case let .completed(completedResult) = events[1].lifecycle {
                #expect(completedResult.summary == result.summary)
                #expect(completedResult.output == result.output)
            } else {
                Issue.record("Second delegated tool event was not completed")
            }
        }

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
        #expect(descriptor.description.contains("taskID is never a root argument"))
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
            await runtime.waitForDirectSubAgentTestWorkLoops()
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
        let firstOverviewIsCurrentWave = !firstOverview.contains {
            !$0.isInCurrentOverviewWave
        }
        #expect(Set(firstOverview.map(\.name)) == ["first-a", "first-b"])
        #expect(firstOverviewIsCurrentWave)
        #expect(Set(firstOverview.compactMap(\.overviewBatchID)).count == 1)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("second"), "profile": .string("Developer")],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil
        )

        let currentOverview = await executor.subAgentSnapshots()
        let allSnapshots = await runtime.snapshots()
        let listedAgents = await runtime.listAgents(arguments: [:])
        let currentOverviewIsCurrentWave = !currentOverview.contains {
            !$0.isInCurrentOverviewWave
        }
        let previousSnapshotsAreNotCurrentWave = !allSnapshots
            .filter { $0.name != "second" }
            .contains { $0.isInCurrentOverviewWave }

        #expect(currentOverview.map(\.name) == ["second"])
        #expect(currentOverviewIsCurrentWave)
        #expect(currentOverview.first?.overviewBatchID != nil)
        #expect(previousSnapshotsAreNotCurrentWave)
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
        await runtime.waitForDirectSubAgentTestWorkLoops()

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
        await runtime.waitForDirectSubAgentTestWorkLoops()

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
        await runtime.waitForDirectSubAgentTestWorkLoops(agentID: firstAgent.id)
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
        await runtime.waitForDirectSubAgentTestWorkLoops()
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
        await runtime.waitForDirectSubAgentTestWorkLoops()

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
    func closeCleansUpWhenTaskAttemptCancellationThrows() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "root-graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "close-task", title: "Close")]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
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
        let agent = try #require(await runtime.snapshots().first)
        let agentSessionID = "\(agent.id)_session"

        // Redirect the root execution session to an incompatible task graph.
        // This makes close's cancelAttempt throw taskNotFound while leaving the
        // child scope in place, so the remainder of the close cleanup is observable.
        _ = try await orchestrator.createGraph(
            sessionID: "parent",
            id: "parent-graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "parent-task", title: "Parent")]
        )
        let parentReceipt = try #require(try await orchestrator.claimTasks(
            sessionID: "parent",
            claims: [TaskClaim(taskID: "parent-task", agentID: "parent-agent")]
        ).first)
        try await orchestrator.registerExecutionScope(
            executionSessionID: "root",
            scope: TaskExecutionScope(
                rootSessionID: "parent",
                graphID: parentReceipt.graphID,
                taskID: parentReceipt.taskID,
                attemptID: parentReceipt.attemptID
            )
        )

        do {
            _ = try await runtime.closeAgent(arguments: ["id": .string(agent.id)])
            Issue.record("Closing must propagate a task-attempt cancellation failure.")
        } catch let error as SessionTaskOrchestratorError {
            #expect(error == .taskNotFound("close-task"))
        }

        let closedAgent = try #require(await runtime.snapshots().first)
        #expect(closedAgent.status == .closed)
        #expect(closedAgent.pending == false)
        #expect(closedAgent.latestError?.contains("unable to cancel task attempt") == true)
        #expect(await orchestrator.executionScope(for: agentSessionID) == nil)

        let participants = await runtime.sharedChat.participants(
            roomID: "root",
            includingInactive: true
        )
        #expect(participants.first(where: { $0.name == "closer" }) == nil)
        #expect(await backend.shutdownCount() == 1)
        await #expect(throws: DirectSubAgentBackendFactoryError.self) {
            _ = try await backend.executeBorrowedSubAgentTool(
                AgentBorrowedToolCall(
                    id: "after-close",
                    name: "agent.list",
                    argumentsJSON: "{}"
                )
            )
        }

        // This scope exists only to force the cancellation error above. Removing
        // it lets the original task state be checked from its root session.
        await orchestrator.unregisterExecutionScope(executionSessionID: "root")
        let unmodifiedTask = try await orchestrator.task(
            sessionID: "root",
            taskID: "close-task"
        ).task
        #expect(unmodifiedTask.status == .inProgress)
        #expect(unmodifiedTask.activeAttemptID == agent.taskAttemptID)
        await runtime.shutdown()
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

    @Test
    func sharedChatBroadcastDeliversToCoordinatorAndEveryOtherActiveAgent() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")
        _ = try await chat.registerAgent(id: "alpha-id", name: "alpha", roomID: "root")
        _ = try await chat.registerAgent(id: "beta-id", name: "beta", roomID: "root")

        let delivery = try await chat.send(
            roomID: "root",
            senderID: "alpha-id",
            destination: .all,
            text: "Please compare findings"
        )

        // The broadcast reaches the coordinator, every other active agent,
        // and the terminal operator (the implicit owner). The operator has no
        // mailbox, so only the coordinator and the other agent are drainable.
        #expect(Set(delivery.recipients.map(\.id)) == [
            AgentSharedChat.operatorID(for: "root"),
            AgentSharedChat.coordinatorID(for: "root"), "beta-id"
        ])
        #expect(await chat.drain(
            roomID: "root",
            participantID: AgentSharedChat.coordinatorID(for: "root")
        ).map(\.text) == ["Please compare findings"])
        #expect(await chat.drain(roomID: "root", participantID: "beta-id").map(\.sender.name) == ["alpha"])
        #expect(await chat.drain(roomID: "root", participantID: "alpha-id").isEmpty)
    }

    @Test
    func operatorBroadcastIncludesCoordinatorWithoutBecomingAParticipant() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")
        _ = try await chat.registerAgent(id: "worker-id", name: "worker", roomID: "root")

        let delivery = try await chat.sendFromOperator(
            roomID: "root",
            destination: .all,
            text: "Please report live status"
        )

        #expect(delivery.message.sender.id == AgentSharedChat.operatorID(for: "root"))
        #expect(delivery.message.sender.name == "operator")
        #expect(delivery.message.sender.kind == .operator)
        #expect(Set(delivery.recipients.map(\.id)) == [
            AgentSharedChat.coordinatorID(for: "root"), "worker-id",
        ])
        // The operator is the implicit owner of the room: it appears in the
        // roster, yet it is not a registered participant — it holds no mailbox
        // and consumes no bounded slot, so capacity stays reserved for work.
        #expect(await chat.participants(roomID: "root").map(\.id) == [
            AgentSharedChat.operatorID(for: "root"),
            AgentSharedChat.coordinatorID(for: "root"), "worker-id",
        ])
        // The implicit owner has no mailbox: it consumes messages through the
        // observation stream, so draining it yields nothing.
        #expect(await chat.drain(
            roomID: "root",
            participantID: AgentSharedChat.operatorID(for: "root")
        ).isEmpty)
        #expect(await chat.drain(
            roomID: "root",
            participantID: AgentSharedChat.coordinatorID(for: "root")
        ).map(\.sender.id) == [AgentSharedChat.operatorID(for: "root")])
        #expect(await chat.drain(roomID: "root", participantID: "worker-id").map(\.text)
            == ["Please report live status"])
    }

    @Test
    func agentReplyToOperatorDoesNotEnterCoordinatorMailbox() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")
        _ = try await chat.registerAgent(id: "worker-id", name: "worker", roomID: "root")

        let delivery = try await chat.send(
            roomID: "root",
            senderID: "worker-id",
            destination: .operator,
            text: "Risposta per te"
        )

        #expect(delivery.recipients.map(\.id) == [AgentSharedChat.operatorID(for: "root")])
        #expect(delivery.message.recipientIDs == [AgentSharedChat.operatorID(for: "root")])
        #expect(await chat.drain(
            roomID: "root",
            participantID: AgentSharedChat.coordinatorID(for: "root")
        ).isEmpty)
    }

    @Test
    func agentMessageAcceptsExplicitOperatorDestination() async throws {
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )

        let destination = try await runtime.sharedChatDestination(
            arguments: ["to": .string("operator")],
            senderIDOverride: "worker-id"
        )

        #expect(destination == .operator)
        await runtime.shutdown()
    }

    @Test
    func terminalSharedChatBridgeUsesTrustedOperatorForCoordinatorMessages() async throws {
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        let notifiedRooms = Mutex<[String]>([])
        await runtime.updateSharedChatMessageAvailableHandler { roomID in
            notifiedRooms.withLock { $0.append(roomID) }
        }
        let delivery = try await runtime.sendSharedChatMessage(
            text: "Review the live status",
            destination: .coordinator,
            rootSessionID: "root"
        )

        #expect(delivery.message.sender.id == AgentSharedChat.operatorID(for: "root"))
        #expect(delivery.message.sender.kind == .operator)
        #expect(delivery.recipients.map(\.id) == [AgentSharedChat.coordinatorID(for: "root")])
        #expect(notifiedRooms.withLock { $0 } == ["root"])
        #expect(await runtime.drainCoordinatorSharedChatMessages(rootSessionID: "root")
            .map(\.text) == ["Review the live status"])
        await runtime.shutdown()
    }

    /// The coordinator addressing the terminal operator directly (by id) must
    /// deliver through the shared-chat transcript without attempting to route
    /// the operator through the sub-agent work loop, which would fail because
    /// the operator is not a delegated agent.
    @Test
    func coordinatorDirectMessageToOperatorIsDeliveredViaTranscript() async throws {
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        let operatorID = AgentSharedChat.operatorID(for: "root")

        let result = try await runtime.messageSharedChat(
            arguments: [
                "id": .string(operatorID),
                "message": .string("Ciao, tutto ok?")
            ],
            rootSessionID: "root",
            parentAllowedToolNames: nil
        )

        // The operator has no mailbox or prompt queue: delivery is reported
        // purely from the bus transcript identity, not the sub-agent roster.
        #expect(result.contains("Delivered live message to Operator"))
        let messages = await runtime.sharedChatTranscriptMessages(rootSessionID: "root")
        #expect(messages.count == 1)
        #expect(messages.first?.text == "Ciao, tutto ok?")
        #expect(messages.first?.recipientIDs == [operatorID])
        #expect(messages.first?.sender.kind == .coordinator)
        await runtime.shutdown()
    }

    /// `coordinator:<room>` and `operator:<room>` are minted only by the actor.
    /// A delegated agent must never be able to take one of those identities,
    /// in any room and in any near-miss spelling.
    @Test
    func sharedChatReservesCoordinatorAndOperatorIdentifiers() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")

        for reserved in [
            AgentSharedChat.coordinatorID(for: "root"),
            AgentSharedChat.operatorID(for: "root"),
            "coordinator:another-room",
            "OPERATOR:root",
            "  operator:root  ",
        ] {
            #expect(AgentSharedChat.isReservedParticipantIdentifier(reserved))
            await #expect(throws: AgentSharedChat.Error.reservedParticipantIdentifier(reserved)) {
                _ = try await chat.registerAgent(
                    id: reserved,
                    name: "impostor",
                    roomID: "root"
                )
            }
        }

        // Identifiers that could forge a prompt header or a card route are
        // rejected outright rather than sanitised into a different identity.
        for invalid in ["", "   ", "agent\nid", "agent\u{1B}id", String(repeating: "a", count: 129)] {
            await #expect(throws: AgentSharedChat.Error.invalidParticipantIdentifier(invalid)) {
                _ = try await chat.registerAgent(id: invalid, name: "worker", roomID: "root")
            }
        }

        // The reserved slot is still the coordinator's, with its own mailbox.
        // The operator surfaces as the implicit owner of the room, but it is
        // never a registered participant and holds no slot or mailbox.
        #expect(await chat.participants(roomID: "root").map(\.id)
            == [AgentSharedChat.operatorID(for: "root"), AgentSharedChat.coordinatorID(for: "root")])
        #expect(await chat.participants(roomID: "root").map(\.kind) == [.operator, .coordinator])
    }

    /// A live identifier cannot change role: re-registering it with another
    /// kind is rejected instead of silently re-typing an active mailbox.
    @Test
    func sharedChatRejectsReuseOfAnIdentifierWithADifferentKind() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")
        _ = try await chat.registerAgent(id: "worker-id", name: "worker", roomID: "root")

        for impostorKind in [AgentSharedChat.ParticipantKind.coordinator, .operator] {
            await #expect(throws: AgentSharedChat.Error.participantIdentifierConflict("worker-id")) {
                _ = try await chat.register(
                    AgentSharedChat.Participant(
                        id: "worker-id",
                        name: "worker",
                        kind: impostorKind
                    ),
                    roomID: "root",
                    onMessageAvailable: nil
                )
            }
        }
        // Re-registering the same kind still reconnects the live mailbox.
        let rejoined = try await chat.registerAgent(
            id: "worker-id",
            name: "worker",
            roomID: "root"
        )
        #expect(rejoined.kind == .agent)
        #expect(await chat.participants(roomID: "root").count == 3)
    }

    /// Names are display values, not identities: they are neutralised at
    /// registration and cannot smuggle a line break, a control sequence or a
    /// forged operator header into prompts and cards.
    @Test
    func sharedChatSanitizesParticipantNamesAndRejectsAmbiguousNameRouting() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")

        let hostile = try await chat.registerAgent(
            id: "agent-x",
            name: "worker\r\nfake\u{1B}[31m",
            roomID: "root"
        )
        #expect(hostile.name == "worker fake[31m")
        #expect(AgentSharedChat.transcriptIdentity(for: hostile)
            == "Agent (id: agent-x, name: worker fake[31m)")

        let overLongName = try await chat.registerAgent(
            id: "agent-y",
            name: String(repeating: "n", count: 200),
            roomID: "root"
        )
        #expect(overLongName.name.count == AgentSharedChat.maximumParticipantNameLength)
        let blankName = try await chat.registerAgent(
            id: "agent-z",
            name: "\u{1B}\u{7F}",
            roomID: "root"
        )
        #expect(blankName.name == "agent-z")

        // Two instances may share a display name, so name-based routing is
        // ambiguous and must not resolve to an arbitrary one.
        _ = try await chat.registerAgent(id: "twin-1", name: "twin", roomID: "root")
        _ = try await chat.registerAgent(id: "twin-2", name: "twin", roomID: "root")
        await #expect(throws: AgentSharedChat.Error.unknownParticipant("twin")) {
            _ = try await chat.send(
                roomID: "root",
                senderID: AgentSharedChat.coordinatorID(for: "root"),
                destination: .direct(["twin"]),
                text: "which one?"
            )
        }
        let routed = try await chat.send(
            roomID: "root",
            senderID: AgentSharedChat.coordinatorID(for: "root"),
            destination: .direct(["twin-1"]),
            text: "explicit id"
        )
        #expect(routed.recipients.map(\.id) == ["twin-1"])
    }

    @Test
    func sharedChatBoundsParticipantsAndEachRecipientMailbox() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "bounded")
        for index in 0..<(AgentSharedChat.maximumParticipantsPerRoom - 1) {
            _ = try await chat.registerAgent(
                id: "agent-\(index)",
                name: "agent-\(index)",
                roomID: "bounded"
            )
        }
        await #expect(throws: AgentSharedChat.Error.self) {
            _ = try await chat.registerAgent(
                id: "overflow",
                name: "overflow",
                roomID: "bounded"
            )
        }

        for index in 0...AgentSharedChat.maximumMailboxMessages {
            _ = try await chat.send(
                roomID: "bounded",
                senderID: AgentSharedChat.coordinatorID(for: "bounded"),
                destination: .direct(["agent-0"]),
                text: "message \(index)"
            )
        }
        let mailbox = await chat.drain(roomID: "bounded", participantID: "agent-0")
        #expect(mailbox.count == AgentSharedChat.maximumMailboxMessages)
        #expect(mailbox.first?.text == "message 1")
        #expect(mailbox.last?.text == "message \(AgentSharedChat.maximumMailboxMessages)")
    }

    @Test
    func sharedChatCloseAndShutdownReleaseSlotsWhileKeepingTranscriptSnapshots() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        let chat = await runtime.sharedChat
        let rootSessionID = "reusable-room"

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("first"),
                "profile": .string("Developer"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: rootSessionID
        )
        let firstID = try #require(await runtime.snapshots().first(where: { $0.status != .closed })?.id)
        _ = try await chat.send(
            roomID: rootSessionID,
            senderID: firstID,
            destination: .coordinator,
            text: "keep this historical sender"
        )
        #expect(await runtime.closeAgent(id: firstID))

        // One coordinator slot is permanent for the room, so 63 close cycles
        // must not accumulate stale participant entries and exhaust the limit.
        for index in 0..<(AgentSharedChat.maximumParticipantsPerRoom - 2) {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("cycle-\(index)"),
                    "profile": .string("Developer"),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: rootSessionID
            )
            let agentID = try #require(
                await runtime.snapshots().first(where: { $0.status != .closed })?.id
            )
            #expect(await runtime.closeAgent(id: agentID))
        }

        let transcript = await chat.messages(roomID: rootSessionID)
        #expect(transcript.map(\.text) == ["keep this historical sender"])
        #expect(transcript.first?.sender.id == firstID)
        #expect(
            await chat.participants(roomID: rootSessionID, includingInactive: true).map(\.id)
                == [AgentSharedChat.operatorID(for: rootSessionID), AgentSharedChat.coordinatorID(for: rootSessionID)]
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("after-63-closes"),
                "profile": .string("Developer"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: rootSessionID
        )
        #expect(await chat.participants(roomID: rootSessionID).count == 3)

        await runtime.shutdown()
        #expect(
            await chat.participants(roomID: rootSessionID, includingInactive: true).map(\.id)
                == [AgentSharedChat.operatorID(for: rootSessionID), AgentSharedChat.coordinatorID(for: rootSessionID)]
        )
        #expect(await chat.messages(roomID: rootSessionID).map(\.text) == ["keep this historical sender"])
    }

    @Test
    func sharedChatLimitFailureAfterRecordInsertionRollsBackWithoutZombie() async throws {
        let regularBackend = CapturingSubAgentRuntimeBackend()
        let rejectedBackend = CapturingSubAgentRuntimeBackend()
        let invocationCount = Mutex(0)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in
                let invocation = invocationCount.withLock { count in
                    defer { count += 1 }
                    return count
                }
                return invocation == AgentSharedChat.maximumParticipantsPerRoom - 1
                    ? rejectedBackend
                    : regularBackend
            },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        let rootSessionID = "full-room"
        let chat = await runtime.sharedChat

        for index in 0..<(AgentSharedChat.maximumParticipantsPerRoom - 1) {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("resident-\(index)"),
                    "profile": .string("Developer"),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: rootSessionID
            )
        }
        let residentIDs = Set(await runtime.snapshots().map(\.id))
        #expect(await chat.participants(roomID: rootSessionID).count == AgentSharedChat.maximumParticipantsPerRoom + 1)

        // A taskless attempt reserves a lease before inserting its AgentRecord.
        // The registration error must clean all of it, even though this record
        // was added after the room reached its exact limit.
        let orchestrator = SessionTaskOrchestrator()
        await runtime.installTaskOrchestrator(orchestrator)
        await #expect(throws: AgentSharedChat.Error.self) {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("overflow"),
                    "profile": .string("Developer"),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: rootSessionID
            )
        }

        #expect(Set(await runtime.snapshots().map(\.id)) == residentIDs)
        #expect(await chat.participants(roomID: rootSessionID).count == AgentSharedChat.maximumParticipantsPerRoom + 1)
        #expect((await chat.participants(roomID: rootSessionID, includingInactive: true)).contains { $0.name == "overflow" } == false)
        #expect(await rejectedBackend.createdSessions().count == 1)
        #expect(await rejectedBackend.shutdownCount() == 1)

        // Creating an active graph is permitted only after the failed attempt's
        // taskless reservation has been released.
        _ = try await orchestrator.createGraph(
            sessionID: rootSessionID,
            id: "post-rollback-graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "follow-up", title: "Follow up")]
        )
        await runtime.shutdown()
    }

    @Test
    func sharedChatIdentityIsIncludedInEveryChildBackendContext() async throws {
        let recorder = SubAgentFactoryRecorder()
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        let agentID = try #require(await runtime.snapshots().first?.id)
        let context = try #require(recorder.contexts.first)
        #expect(context.sharedChat != nil)
        #expect(context.sharedChatSenderID == agentID)
        #expect(context.sharedChatRoomID == "root")
        await runtime.shutdown()
    }

    @Test
    func childBorrowedAgentToolsUseParentGraphAndCapturedChatIdentity() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        let listOutput = try await backend.executeBorrowedSubAgentTool(
            AgentBorrowedToolCall(
                id: "list-call",
                name: "agent.list",
                argumentsJSON: "{}"
            )
        )
        #expect(listOutput.contains("worker"))

        _ = try await backend.executeBorrowedSubAgentTool(
            AgentBorrowedToolCall(
                id: "message-call",
                name: "agent.message",
                argumentsJSON: #"{"to":"coordinator","message":"Live finding"}"#
            )
        )
        let messages = await runtime.drainCoordinatorSharedChatMessages(rootSessionID: "root")
        #expect(messages.map(\.sender.name) == ["worker"])
        #expect(messages.map(\.text) == ["Live finding"])
        await runtime.shutdown()
    }

    @Test
    func sharedChatMessageWakesAnIdleAgentWithoutBlockingTheSender() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        let agentID = try #require(await runtime.snapshots().first?.id)

        let delivery = try await runtime.sendSharedChatMessage(
            text: "Inspect the changed API now",
            destination: .direct([agentID]),
            rootSessionID: "root"
        )
        #expect(delivery.recipients.map(\.name) == ["worker"])

        // The actor callback only schedules the drain; it must not make the
        // sender await model work. Once scheduled, the existing work loop starts
        // the idle agent immediately.
        await backend.waitUntilSentPromptCount(1)
        #expect(await backend.sentPromptCount() == 1)
        await runtime.shutdown()
    }

    @Test
    func operatorMessageReceivesFinalOutputWhenAgentDoesNotCallMessageTool() async throws {
        let backend = CapturingSubAgentRuntimeBackend(responseText: "Direct fallback reply")
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        let agentID = try #require(await runtime.snapshots().first?.id)

        _ = try await runtime.sendSharedChatMessage(
            text: "Reply directly to me",
            destination: .direct([agentID]),
            rootSessionID: "root"
        )
        await backend.waitUntilSentPromptCount(1)

        var reply: AgentSharedChat.Message?
        while reply == nil {
            reply = await runtime.sharedChatTranscriptMessages(rootSessionID: "root")
                .first { $0.text == "Direct fallback reply" }
            if reply == nil { await Task.yield() }
        }
        let deliveredReply = try #require(reply)
        #expect(deliveredReply.sender.id == agentID)
        #expect(deliveredReply.recipientIDs == [AgentSharedChat.operatorID(for: "root")])
        #expect(await runtime.drainCoordinatorSharedChatMessages(rootSessionID: "root").isEmpty)
        await runtime.shutdown()
    }

    @Test
    func explicitOperatorReplySuppressesFinalOutputFallback() async throws {
        let backend = CapturingSubAgentRuntimeBackend(
            responseText: "ordinary final output",
            borrowedToolCallOnPrompt: AgentBorrowedToolCall(
                id: "reply-call",
                name: "agent.message",
                argumentsJSON: #"{"to":"operator","message":"explicit reply"}"#
            )
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        let agentID = try #require(await runtime.snapshots().first?.id)

        _ = try await runtime.sendSharedChatMessage(
            text: "Reply directly to me",
            destination: .direct([agentID]),
            rootSessionID: "root"
        )
        await backend.waitUntilSentPromptCount(1)

        while await runtime.sharedChatTranscriptMessages(rootSessionID: "root")
            .contains(where: { $0.text == "explicit reply" }) == false {
            await Task.yield()
        }
        // Let recordCompletion run after the borrowed tool returns.
        while await runtime.snapshots().first?.latestOutput != "ordinary final output" {
            await Task.yield()
        }
        let agentMessages = await runtime.sharedChatTranscriptMessages(rootSessionID: "root")
            .filter { $0.sender.id == agentID }
        #expect(agentMessages.map(\.text) == ["explicit reply"])
        #expect(agentMessages.first?.recipientIDs == [AgentSharedChat.operatorID(for: "root")])
        await runtime.shutdown()
    }

    @Test
    func childDirectToolExecutorBorrowsOnlyAgentToolsAndKeepsTaskAndTodoRuntimesLocal() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let unavailableFactory: DirectSubAgentContextualBackendFactory = { _ in
            throw DirectSubAgentBackendFactoryError.unavailable
        }
        let rootExecutor = DirectToolExecutor(
            subAgentContextualBackendFactory: unavailableFactory
        )
        await rootExecutor.installTaskOrchestrator(orchestrator)
        _ = try await rootExecutor.executeThrowing(
            sessionID: "root",
            toolCall: directToolCall(
                name: "tasks.create",
                arguments: [
                    "graphID": "graph",
                    "tasks": [["id": "report", "title": "Report findings"]],
                ]
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            allowedToolNames: ["tasks.create"]
        )

        let backend = CapturingSubAgentRuntimeBackend()
        let parentRuntime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await parentRuntime.installTaskOrchestrator(orchestrator)
        _ = try await parentRuntime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "taskID": .string("report"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: ["tasks.create"],
            rootSessionID: "root"
        )
        let child = try #require(await parentRuntime.snapshots().first)
        let childSessionID = "\(child.id)_session"
        let childExecutor = DirectToolExecutor(
            borrowedSubAgentToolExecutor: { toolCall in
                try await parentRuntime.executeBorrowedSubAgentTool(
                    senderID: child.id,
                    rootSessionID: "root",
                    toolCall: toolCall
                )
            },
            subAgentContextualBackendFactory: unavailableFactory
        )
        await childExecutor.installTaskOrchestrator(orchestrator)
        let allowedToolNames: Set<String> = [
            "agent.list", "agent.get", "agent.message",
            "tasks.list", "tasks.get", "tasks.update",
            "todo.read", "todo.write",
        ]
        let workingDirectory = URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests")

        let taskList = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(name: "tasks.list", arguments: [:]),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        let taskDetails = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(name: "tasks.get", arguments: ["id": "report"]),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        let taskUpdate = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(
                name: "tasks.update",
                arguments: ["id": "report", "progress": "reported from child"]
            ),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        let todoWrite = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(
                name: "todo.write",
                arguments: [
                    "todos": [["id": "handoff", "content": "Review the report"]],
                ]
            ),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        let todoRead = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(name: "todo.read", arguments: [:]),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )

        let agentList = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(name: "agent.list", arguments: [:]),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        let agentDetails = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(name: "agent.get", arguments: ["id": child.id]),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        _ = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(
                name: "agent.message",
                arguments: ["to": "coordinator", "message": "Report is ready"]
            ),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )

        #expect(taskList.contains("report"))
        #expect(taskDetails.contains("Report findings"))
        #expect(taskUpdate.contains("reported from child"))
        #expect(todoWrite.contains("Review the report"))
        #expect(todoRead.contains("Review the report"))
        #expect(agentList.contains("worker"))
        #expect(agentDetails.contains("worker"))
        let coordinatorMessages = await parentRuntime.drainCoordinatorSharedChatMessages(
            rootSessionID: "root"
        )
        #expect(coordinatorMessages.map(\.sender.id) == [child.id])
        #expect(coordinatorMessages.map(\.text) == ["Report is ready"])

        await childExecutor.shutdown()
        await rootExecutor.shutdown()
        await parentRuntime.shutdown()
    }

    @Test
    func failedAgentBatchRemovesEveryPreviouslyRegisteredChatParticipant() async throws {
        let backendFactory = FailAfterFirstSubAgentBackendFactory(
            backend: CapturingSubAgentRuntimeBackend()
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in try backendFactory.makeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )

        await #expect(throws: DirectSubAgentBackendFactoryError.self) {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("first"), "profile": .string("Developer")]),
                        .object(["name": .string("second"), "profile": .string("Developer")]),
                    ]),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
        }

        #expect(await runtime.snapshots().isEmpty)
        let participants = await runtime.sharedChat.participants(
            roomID: "root",
            includingInactive: true
        )
        #expect(participants.first(where: { $0.name == "first" }) == nil)
        #expect(participants.first(where: { $0.name == "second" }) == nil)
        await runtime.shutdown()
    }

    @Test
    func coordinatorSharedChatDrainInjectsAtMostFiveMessagesPerPrompt() async throws {
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: DirectSubAgentRuntime.unavailableContextualBackendFactory,
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        // `sharedChat` is actor-isolated state of the runtime, so the handle
        // must be read with an actor hop before the room is prepared.
        let chat = await runtime.sharedChat
        _ = try await chat.registerCoordinator(roomID: "root")
        _ = try await chat.registerAgent(id: "worker", name: "worker", roomID: "root")
        for index in 1...6 {
            _ = try await chat.send(
                roomID: "root",
                senderID: "worker",
                destination: .coordinator,
                text: "message \(index)"
            )
        }

        let firstBatch = await runtime.drainCoordinatorSharedChatMessages(rootSessionID: "root")
        let remaining = await chat.drain(
            roomID: "root",
            participantID: AgentSharedChat.coordinatorID(for: "root")
        )
        #expect(firstBatch.map(\.text) == [
            "message 1", "message 2", "message 3", "message 4", "message 5",
        ])
        #expect(remaining.map(\.text) == ["message 6"])
        await runtime.shutdown()
    }

    // MARK: - Standby lifecycle

    @Test
    func taskBoundAgentEntersStandbyAfterCompletingItsAttempt() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "task-a",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the work"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()

        let agent = try #require(await runtime.snapshots().first)
        let task = try await orchestrator.task(sessionID: "root", taskID: "task-a").task

        // The attempt completed; the task is awaiting validation.
        #expect(task.status == .awaitingValidation)
        #expect(task.activeAttemptID == nil)
        // The agent entered standby, not closed or idle.
        #expect(agent.status == .standby)
        // Standby agents are NOT pending: agent.wait must not block on them.
        #expect(agent.pending == false)

        await runtime.shutdown()
    }

    @Test
    func standbyAgentAcceptsMessagesWhileItsGraphIsActive() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "task-a",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the work"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()
        let agent = try #require(await runtime.snapshots().first)
        #expect(agent.status == .standby)
        #expect(await backend.sentPromptCount() == 1)

        // Sending a message should succeed and trigger a second turn.
        _ = try await runtime.messageAgents(
            arguments: [
                "id": .string(agent.id),
                "message": .string("Can you summarize?"),
            ]
        )
        await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agent.id)

        #expect(await backend.sentPromptCount() == 2)

        await runtime.shutdown()
    }

    @Test
    func completedTaskAgentEntersStandbyInManualGraph() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "manual-graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "task-a",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                ),
                TaskDefinition(
                    id: "task-b",
                    title: "Later work"
                )
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the work"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()

        let agent = try #require(await runtime.snapshots().first)
        let task = try await orchestrator.task(sessionID: "root", taskID: "task-a").task

        // The attempt completed; the task is .completed (manual graph, no validation).
        #expect(task.status == .completed)
        #expect(task.activeAttemptID == nil)
        // The graph is still active because task-b is pending.
        let graph = try #require(await orchestrator.graphSnapshot(sessionID: "root", graphID: "manual-graph"))
        #expect(graph.state == .active)
        // The agent entered standby despite its task being .completed, because
        // the graph is still active and the task is not failed/cancelled.
        #expect(agent.status == .standby)
        #expect(agent.pending == false)

        await runtime.shutdown()
    }

    @Test
    func completedTaskAgentAcceptsMessagesWhileGraphIsActive() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "manual-graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "task-a",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                ),
                TaskDefinition(
                    id: "task-b",
                    title: "Later work"
                )
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the work"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()
        let agent = try #require(await runtime.snapshots().first)
        #expect(agent.status == .standby)
        #expect(await backend.sentPromptCount() == 1)

        // Sending a message should succeed and trigger a second turn even
        // though the agent's task is already .completed.
        _ = try await runtime.messageAgents(
            arguments: [
                "id": .string(agent.id),
                "message": .string("Can you summarize?"),
            ]
        )
        await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agent.id)

        #expect(await backend.sentPromptCount() == 2)

        await runtime.shutdown()
    }

    @Test
    func standbyTurnDoesNotMutateTheTaskGraph() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "task-a",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "response")
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the work"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()
        let agent = try #require(await runtime.snapshots().first)

        let taskBeforeStandbyTurn = try await orchestrator.task(
            sessionID: "root",
            taskID: "task-a"
        ).task
        let attemptsBefore = taskBeforeStandbyTurn.attempts.count

        // Trigger a standby turn.
        _ = try await runtime.messageAgents(
            arguments: [
                "id": .string(agent.id),
                "message": .string("Follow-up question"),
            ]
        )
        await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agent.id)

        let taskAfterStandbyTurn = try await orchestrator.task(
            sessionID: "root",
            taskID: "task-a"
        ).task
        #expect(taskAfterStandbyTurn.attempts.count == attemptsBefore)
        #expect(taskAfterStandbyTurn.status == .awaitingValidation)
        #expect(taskAfterStandbyTurn.activeAttemptID == nil)

        await runtime.shutdown()
    }

    @Test
    func standbyAgentIsReleasedWhenGraphCompletes() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "task-a",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the work"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()
        let agent = try #require(await runtime.snapshots().first)
        #expect(agent.status == .standby)

        // Validate positively → task completes → graph completes → standby released.
        _ = try await orchestrator.validateTaskResult(
            sessionID: "root",
            taskID: "task-a",
            succeeded: true
        )
        let graph = try #require(try await orchestrator.graphSnapshot(
            sessionID: "root",
            graphID: "workflow"
        ))
        #expect(graph.state == .completed)

        // Backend shutdown is emitted only after the graph observer has released
        // the resident. It is the lifecycle edge under test, unlike a snapshot
        // poll that may run before the observer is scheduled.
        await backend.waitUntilShutdownCount(1)
        #expect(await runtime.snapshots().first { $0.id == agent.id }?.status == .closed)

        await runtime.shutdown()
    }

    @Test
    func standbyAgentIsSupersededByRetry() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "task-a",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker-1"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the work"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()
        let firstAgent = try #require(await runtime.snapshots().first)
        #expect(firstAgent.status == .standby)

        // Fail validation, then retry.
        _ = try await orchestrator.validateTaskResult(
            sessionID: "root",
            taskID: "task-a",
            succeeded: false,
            failureReason: "validation failed"
        )
        _ = try await orchestrator.retryTask(
            sessionID: "root",
            taskID: "task-a"
        )

        // Create a new agent for the retried task.
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker-2"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()

        let agents = await runtime.snapshots()
        let firstAgentAfter = agents.first { $0.id == firstAgent.id }
        // The first agent was superseded by the retried attempt: a `.standby`
        // resident is closed immediately when a newer attempt claims its task
        // (the release path). Assert the exact terminal status, not just that it
        // left `.standby`.
        #expect(firstAgentAfter?.status == .closed)

        await runtime.shutdown()
    }

    @Test
    func expireStandbyAgentsClosesAgentPastIdleTimeout() async throws {
        let (_, runtime, backend, agent) = try await standbyScenario()
        #expect(agent.status == .standby)

        // The reaper enforces `standbyIdleTimeout` (15 minutes in production).
        // Drive one expiration sweep with a clock past the timeout: the resident
        // is older than the limit, so it is closed and its backend is shut down
        // (no leak).
        let pastTimeout = Date().addingTimeInterval(
            DirectSubAgentRuntime.standbyIdleTimeout + 60
        )
        await runtime.expireStandbyAgents(now: pastTimeout)

        let snapshot = try #require(await runtime.snapshots().first { $0.id == agent.id })
        #expect(snapshot.status == .closed)
        #expect(snapshot.latestError == DirectSubAgentRuntime.standbyIdleTimeoutReason)
        #expect(await backend.shutdownCount() == 1)

        await runtime.shutdown()
    }

    @Test
    func standbyBudgetExhaustionClosesAgentWithoutLeakingBackend() async throws {
        let (_, runtime, backend, agent) = try await standbyScenario()
        #expect(agent.status == .standby)
        let budget = DirectSubAgentRuntime.maximumStandbyTurnsPerAgent

        // The turn budget is enforced at turn completion: each standby turn
        // bumps the counter, and the turn that reaches the limit releases the
        // agent (the same close path the reaper's `expireStandbyAgents` budget
        // branch uses — that branch is an unreachable backstop because the limit
        // is always enforced here first). The first `budget - 1` turns leave it
        // standing by.
        for _ in 0..<(budget - 1) {
            await runtime.recordStandbyTurnCompletion(agentID: agent.id)
        }
        let stillStandby = try #require(await runtime.snapshots().first { $0.id == agent.id })
        #expect(stillStandby.status == .standby)

        await runtime.recordStandbyTurnCompletion(agentID: agent.id)
        let closed = try #require(await runtime.snapshots().first { $0.id == agent.id })
        #expect(closed.status == .closed)
        #expect(closed.latestError == DirectSubAgentRuntime.standbyBudgetExhaustedReason)
        // Backend shut down exactly once: no leaked backend process.
        #expect(await backend.shutdownCount() == 1)

        await runtime.shutdown()
    }

    @Test
    func budgetExhaustedAgentIsClosedNotIdleAndRejectsStaleMessages() async throws {
        let (_, runtime, _, agent) = try await standbyScenario()
        #expect(agent.status == .standby)

        await exhaustStandbyBudget(agentID: agent.id, in: runtime)
        let closed = try #require(await runtime.snapshots().first { $0.id == agent.id })
        // Closed (and shut down) rather than left lingering in `.idle` after the
        // budget-exhausting turn is denied/finished.
        #expect(closed.status == .closed)
        #expect(closed.status != .idle)

        // A stale message to the now-closed agent is rejected instead of
        // reviving it (the authorization path keeps it finished).
        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await runtime.messageAgents(
                arguments: [
                    "id": .string(agent.id),
                    "message": .string("Another follow-up"),
                ]
            )
        }

        await runtime.shutdown()
    }

    @Test
    func releaseDuringInFlightStandbyTurnClosesAgentAtTurnEnd() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "task-a",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        let backend = BlockingSubAgentRuntimeBackend(responseText: "follow-up done")
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the work"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()
        let agent = try #require(await runtime.snapshots().first)
        #expect(agent.status == .standby)

        // Drive the release deterministically: stop the async graph observer so
        // only the explicit call below releases the resident.
        await runtime.removeGraphObserver(rootSessionID: "root")

        // Queue a follow-up whose backend turn blocks, so the resident is
        // `.running` while the graph becomes terminal.
        await backend.blockNextPrompt()
        _ = try await runtime.messageAgents(
            arguments: [
                "id": .string(agent.id),
                "message": .string("Summarize the work"),
            ]
        )
        await backend.waitUntilBlocked()

        // The graph completes while the standby turn is in flight.
        _ = try await orchestrator.validateTaskResult(
            sessionID: "root",
            taskID: "task-a",
            succeeded: true
        )
        let graph = try #require(try await orchestrator.graphSnapshot(
            sessionID: "root",
            graphID: "workflow"
        ))
        #expect(graph.state == .completed)

        // Releasing terminated graphs flags the in-flight resident for release
        // (it is NOT closed mid-response). A resident remains, so this returns
        // false.
        let noMoreResidents = await runtime.releaseTerminatedStandbyGraphs(rootSessionID: "root")
        #expect(noMoreResidents == false)
        let inFlight = try #require(await runtime.snapshots().first { $0.id == agent.id })
        #expect(inFlight.status == .running)

        // When the in-flight turn lands, the flagged release is completed and the
        // agent is closed — it never returns to `.standby`.
        await backend.release()
        await backend.waitUntilShutdown()
        #expect(await runtime.snapshots().first { $0.id == agent.id }?.status == .closed)
        #expect(await backend.shutdownCount() == 1)

        await runtime.shutdown()
    }

    @Test
    func interruptAgentsClosesStandbyResidentsAndStopsObserver() async throws {
        let (_, runtime, backend, agent) = try await standbyScenario()
        #expect(agent.status == .standby)
        // Entering standby started both the graph-completion observer and the
        // periodic reaper for this root session.
        #expect(await runtime.graphObserverTasks["root"] != nil)
        #expect(await runtime.standbyReaperTask != nil)

        // Interrupting the root session tears down its standby lifecycle: the
        // observer/reaper are stopped and the standby resident is released.
        let interrupted = await runtime.interruptAgents(rootSessionID: "root")
        #expect(interrupted == 1)

        let snapshot = try #require(await runtime.snapshots().first { $0.id == agent.id })
        #expect(snapshot.status == .closed)
        #expect(await backend.shutdownCount() == 1)
        #expect(await runtime.graphObserverTasks["root"] == nil)
        #expect(await runtime.standbyReaperTask == nil)

        await runtime.shutdown()
    }

    // Note on the git-status refresh behaviour (review #13, last bullet): that
    // predicate lives in the TerminalChat/TUI layer and is not reachable from a
    // `DirectSubAgentRuntime` unit test without driving a real TerminalChat. It
    // is intentionally not covered here to avoid a brittle, host-dependent TUI
    // test; the standby lifecycle the refresh depends on is covered above.
}

private actor DirectSubAgentToolEventRecorder {
    private var events: [DirectSubAgentToolEvent] = []

    func record(_ event: DirectSubAgentToolEvent) {
        events.append(event)
    }

    func snapshot() -> [DirectSubAgentToolEvent] {
        events
    }
}

private func directToolCall(
    name: String,
    arguments: [String: Any]
) -> DirectAgentToolCall {
    let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
    return DirectAgentToolCall(
        id: UUID().uuidString,
        name: name,
        argumentsObject: arguments,
        argumentsJSON: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    )
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

private final class FailAfterFirstSubAgentBackendFactory: @unchecked Sendable {
    private let backend: any AgentRuntimeBackend
    private let invocationCount = Mutex(0)

    init(backend: any AgentRuntimeBackend) {
        self.backend = backend
    }

    func makeBackend() throws -> any AgentRuntimeBackend {
        let invocation = invocationCount.withLock { count in
            defer { count += 1 }
            return count
        }
        guard invocation == 0 else {
            throw DirectSubAgentBackendFactoryError.unavailable
        }
        return backend
    }
}

private extension DirectSubAgentRuntime {
    /// `createAgents`, `agent.message`, and shared-chat wake-ups install a
    /// single `runTask` synchronously. Await the captured tasks themselves so
    /// tests observe a completed turn rather than an arbitrary `agent.wait`
    /// polling deadline.
    func waitForDirectSubAgentTestWorkLoops(agentID: String? = nil) async {
        let tasks: [Task<Void, Never>]
        if let agentID, let task = agents[agentID]?.runTask {
            tasks = [task]
        } else if agentID != nil {
            tasks = []
        } else {
            tasks = agents.values.compactMap(\.runTask)
        }
        for task in tasks {
            await task.value
        }
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
    private let borrowedToolCallOnPrompt: AgentBorrowedToolCall?
    private var sentPrompts: [String] = []
    private var sentPromptCountWaiters: [SentPromptCountWaiter] = []
    // A shared fixture may serve multiple roots. Keep blocked turns keyed by
    // their backend session so cancellation of one runtime cannot release the
    // other runtime's prompt.
    private var blockedPromptContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var blockedPromptCancellationRequests: Set<String> = []
    private var shutdownCalls = 0
    private var shutdownCountWaiters: [ShutdownCountWaiter] = []
    private var installedTaskOrchestrator = false
    private var borrowedSubAgentToolExecutor: AgentBorrowedToolExecutor?
    private var subAgentToolEventHandler: DirectSubAgentToolEventHandler?
    private(set) var toolProviderUpdates: [(providers: [AgentToolProvider], sessionID: String?)] = []

    private struct SentPromptCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct ShutdownCountWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    init(
        responseText: String = "done",
        blocksPrompts: Bool = false,
        borrowedToolCallOnPrompt: AgentBorrowedToolCall? = nil
    ) {
        self.responseText = responseText
        self.blocksPrompts = blocksPrompts
        self.borrowedToolCallOnPrompt = borrowedToolCallOnPrompt
    }

    func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        installedTaskOrchestrator = true
    }

    func updateBorrowedSubAgentToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {
        borrowedSubAgentToolExecutor = executor
    }

    func updateSubAgentToolEventHandler(
        _ handler: DirectSubAgentToolEventHandler?
    ) async {
        subAgentToolEventHandler = handler
    }

    func executeBorrowedSubAgentTool(_ toolCall: AgentBorrowedToolCall) async throws -> String {
        guard let borrowedSubAgentToolExecutor else {
            throw DirectSubAgentBackendFactoryError.unavailable
        }
        return try await borrowedSubAgentToolExecutor(toolCall)
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

    func shutdown() {
        shutdownCalls += 1
        resumeShutdownCountWaiters()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        sentPrompts.append(prompt)
        resumeSentPromptCountWaiters()
        if let borrowedToolCallOnPrompt, let borrowedSubAgentToolExecutor {
            _ = try await borrowedSubAgentToolExecutor(borrowedToolCallOnPrompt)
        }
        if blocksPrompts {
            // `AgentRuntimeBackend.shutdown()` has no session/root argument.
            // Let cancellation of the owning work loop release this turn
            // instead of making shutdown resume every shared-fixture waiter.
            await withTaskCancellationHandler {
                await waitForBlockedPromptRelease(sessionID: sessionID)
            } onCancel: {
                Task {
                    await self.cancelBlockedPrompt(sessionID: sessionID)
                }
            }
            try Task.checkCancellation()
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

    func hasSubAgentToolEventHandler() -> Bool {
        subAgentToolEventHandler != nil
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

    func waitUntilSentPromptCount(_ count: Int) async {
        guard sentPrompts.count < count else { return }
        await withCheckedContinuation { continuation in
            sentPromptCountWaiters.append(
                SentPromptCountWaiter(count: count, continuation: continuation)
            )
        }
    }

    func shutdownCount() -> Int {
        shutdownCalls
    }

    func waitUntilShutdownCount(_ count: Int) async {
        guard shutdownCalls < count else { return }
        await withCheckedContinuation { continuation in
            shutdownCountWaiters.append(
                ShutdownCountWaiter(count: count, continuation: continuation)
            )
        }
    }

    private func resumeSentPromptCountWaiters() {
        let ready = sentPromptCountWaiters.filter { sentPrompts.count >= $0.count }
        sentPromptCountWaiters.removeAll { sentPrompts.count >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    private func waitForBlockedPromptRelease(sessionID: String) async {
        if blockedPromptCancellationRequests.remove(sessionID) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            if blockedPromptCancellationRequests.remove(sessionID) != nil {
                continuation.resume()
            } else {
                blockedPromptContinuations[sessionID] = continuation
            }
        }
    }

    private func cancelBlockedPrompt(sessionID: String) {
        if let continuation = blockedPromptContinuations.removeValue(forKey: sessionID) {
            continuation.resume()
        } else {
            blockedPromptCancellationRequests.insert(sessionID)
        }
    }

    private func resumeShutdownCountWaiters() {
        let ready = shutdownCountWaiters.filter { shutdownCalls >= $0.count }
        shutdownCountWaiters.removeAll { shutdownCalls >= $0.count }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private enum StandbyFixtureError: Error { case agentNotReady }

/// Builds an active single-task graph and one task-bound agent that has finished
/// its attempt and entered `.standby`. Shared setup for the standby lifecycle
/// tests above.
private func standbyScenario(
    responseText: String = "done",
    rootSessionID: String = "root",
    graphID: String = "workflow",
    taskID: String = "task-a"
) async throws -> (
    SessionTaskOrchestrator,
    DirectSubAgentRuntime,
    CapturingSubAgentRuntimeBackend,
    DirectSubAgentRuntime.AgentSnapshot
) {
    let orchestrator = SessionTaskOrchestrator()
    _ = try await orchestrator.createGraph(
        sessionID: rootSessionID,
        id: graphID,
        source: .workflow,
        state: .active,
        tasks: [
            TaskDefinition(
                id: taskID,
                title: "Implement",
                execution: TaskExecutionSpec(executor: .subAgent)
            )
        ]
    )
    let backend = CapturingSubAgentRuntimeBackend(responseText: responseText)
    let runtime = DirectSubAgentRuntime(
        contextualBackendFactory: { _ in backend },
        profileResolver: builtInDirectSubAgentProfileResolver
    )
    await runtime.installTaskOrchestrator(orchestrator)
    _ = try await runtime.createAgents(
        arguments: [
            "name": .string("worker"),
            "profile": .string("Developer"),
            "taskID": .string(taskID),
            "prompt": .string("Do the work"),
        ],
        workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
        parentAllowedToolNames: nil,
        rootSessionID: rootSessionID
    )
    await runtime.waitForDirectSubAgentTestWorkLoops()
    guard let agent = await runtime.snapshots().first,
          agent.status == .standby else {
        throw StandbyFixtureError.agentNotReady
    }
    return (orchestrator, runtime, backend, agent)
}

/// Drives an agent's standby turn counter to the limit, which closes it on the
/// turn that exhausts the budget. Used by the budget/denial tests.
private func exhaustStandbyBudget(
    agentID: String,
    in runtime: DirectSubAgentRuntime
) async {
    for _ in 0..<DirectSubAgentRuntime.maximumStandbyTurnsPerAgent {
        await runtime.recordStandbyTurnCompletion(agentID: agentID)
    }
}

/// A controllable `AgentRuntimeBackend` whose `sendPrompt` suspends until
/// `release()` is called, so a standby follow-up turn can be held in flight
/// while a test mutates the task graph. The first turn (the task attempt)
/// completes normally because the gate is armed only after standby is reached.
private actor BlockingSubAgentRuntimeBackend: AgentRuntimeBackend {
    private let responseText: String
    private var shutdownCalls = 0
    private var sentPrompts = 0
    private var shouldBlock = false
    private var released = false
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    init(responseText: String = "done") {
        self.responseText = responseText
    }

    func blockNextPrompt() {
        shouldBlock = true
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func shutdownCount() -> Int {
        shutdownCalls
    }

    func waitUntilShutdown() async {
        guard shutdownCalls == 0 else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    func sentPromptCount() -> Int {
        sentPrompts
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        sentPrompts += 1
        if shouldBlock {
            shouldBlock = false
            // `released` guards against a `release()` that arrived before this
            // turn suspended: if so, skip the gate entirely (no deadlock).
            if !released {
                blocked = true
                let waiters = blockedWaiters
                blockedWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.continuation = continuation
                }
                blocked = false
            }
            released = false
        }
        return DirectAgentResponse(
            text: responseText,
            stopReason: "stop",
            modelID: "test-model"
        )
    }

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) async {}

    func shutdown() async {
        shutdownCalls += 1
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }
}
