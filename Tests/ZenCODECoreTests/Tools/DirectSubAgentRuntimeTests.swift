//
//  DirectSubAgentRuntimeTests.swift
//  ZenCODE
//
//  Created by ZenCODE on 02/07/26.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct DirectSubAgentRuntimeTests {
    @Test
    func agentWithoutResolvedProfileInheritsParentGrant() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in nil }
        )

        _ = try await runtime.execute(
            rootSessionID: "root",
            toolCall: DirectAgentToolCall(
                id: "create-worker",
                name: "agent.create",
                argumentsObject: [
                    "name": "worker-1",
                    "role": "worker",
                    "prompt": "Do the delegated work"
                ],
                argumentsJSON: #"{"name":"worker-1","role":"worker","prompt":"Do the delegated work"}"#
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-inheritance-tests"),
            allowedToolNames: nil
        )
        let unrestrictedSession = try #require(await backend.createdSessions().first)
        #expect(unrestrictedSession.allowedToolNames == nil)

        _ = try await runtime.execute(
            rootSessionID: "root",
            toolCall: DirectAgentToolCall(
                id: "create-worker-2",
                name: "agent.create",
                argumentsObject: [
                    "name": "worker-2",
                    "role": "worker",
                    "prompt": "Do more delegated work"
                ],
                argumentsJSON: #"{"name":"worker-2","role":"worker","prompt":"Do more delegated work"}"#
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-inheritance-tests"),
            allowedToolNames: ["local.readFile", "local.writeFile"]
        )
        let restrictedSession = try #require(await backend.createdSessions().last)
        #expect(restrictedSession.allowedToolNames == ["local.readFile", "local.writeFile"])

        _ = try await runtime.execute(
            rootSessionID: "root",
            toolCall: DirectAgentToolCall(
                id: "create-worker-3",
                name: "agent.create",
                argumentsObject: [
                    "name": "worker-3",
                    "role": "worker",
                    "toolNames": ["local.readFile", "git.status"]
                ],
                argumentsJSON: #"{"name":"worker-3","role":"worker","toolNames":["local.readFile","git.status"]}"#
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-inheritance-tests"),
            allowedToolNames: ["local.readFile", "local.writeFile"]
        )
        let narrowedSession = try #require(await backend.createdSessions().last)
        #expect(narrowedSession.allowedToolNames == ["local.readFile"])
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
        #expect(session.allowedToolNames == ["local.readFile", "local.writeFile"])
        await runtime.shutdown()
    }

    @Test
    func explicitToolsOnlyNarrowResolvedProfileGrant() async throws {
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
                "profile": .string("Developer"),
                "toolNames": .array([
                    .string("local.writeFile"),
                    .string("git.status")
                ])
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-profile-tool-tests"),
            parentAllowedToolNames: ["git.status"]
        )

        let session = try #require(await backend.createdSessions().first)
        #expect(session.allowedToolNames == ["local.writeFile"])
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
        #expect(session.allowedToolNames == [])
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
            "local.readFile", "tasks.list", "tasks.get", "tasks.update"
        ])
        await runtime.shutdown()
    }

    @Test
    func thoughtDeltasKeepOneStableThinkingPresentation() async throws {
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend }
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("thinking-worker"),
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
        #expect(firstSnapshot.currentActivity == "🤔 Thinking…")
        #expect(firstSnapshot.currentActivity?.contains("Considering") == false)

        await runtime.recordEvent(.thought("available evidence"), agentID: agentID)
        await runtime.recordEvent(
            .thought(String(repeating: "x", count: 200)),
            agentID: agentID
        )
        await runtime.recordEvent(.thought("additional delta"), agentID: agentID)
        let latestSnapshot = try #require(await runtime.snapshots().first)

        #expect(latestSnapshot.currentActivity == "🤔 Thinking…")
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
            contextualBackendFactory: { _ in backend }
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("tool-worker"),
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
        #expect(streamingSnapshot.currentActivity == "🤔 Thinking…")
        #expect(
            TerminalChat.subAgentOverviewSignature([streamingSnapshot])
                == thinkingSignature
        )

        let toolCall = DirectAgentToolCall(
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
            subAgentBackendFactory: { backend }
        )
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-output-tests",
            isDirectory: true
        )

        let createResult = await executor.execute(
            sessionID: "root",
            toolCall: DirectAgentToolCall(
                id: "create-planner",
                name: "agent.create",
                argumentsObject: [
                    "name": "plan-author",
                    "prompt": "Write the complete plan"
                ],
                argumentsJSON: #"{"name":"plan-author","prompt":"Write the complete plan"}"#
            ),
            workingDirectory: workingDirectory
        )
        #expect(createResult.status == DirectAgentToolResult.Status.completed)

        let waitResult = await executor.execute(
            sessionID: "root",
            toolCall: DirectAgentToolCall(
                id: "wait-planner",
                name: "agent.wait",
                argumentsObject: ["name": "plan-author"],
                argumentsJSON: #"{"name":"plan-author"}"#
            ),
            workingDirectory: workingDirectory
        )
        let getResult = await executor.execute(
            sessionID: "root",
            toolCall: DirectAgentToolCall(
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
    func createAgentsUsesMatchedProfileModelFromRole() async throws {
        let planner = AgentProfile(
            id: "planner-profile",
            name: "Planner",
            tools: [],
            modelID: "planner-model",
            thinkingSelection: .high
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
            }
        )

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("planning-pass"),
                "role": .string("Planner")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let context = try #require(recorder.contexts.first)
        #expect(context.profile == planner)
        #expect(context.modelID == "planner-model")
        #expect(context.thinkingSelection == .high)
        #expect(await backend.createdThinkingSelection() == .high)

        let snapshot = try #require(await runtime.snapshots().first)
        #expect(snapshot.profileID == planner.id)
        #expect(snapshot.profileName == planner.name)
        #expect(snapshot.modelID == "planner-model")
        #expect(output.contains("model=planner-model"))
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
        #expect(context.modelID == "deep-model")
        #expect(context.thinkingSelection == .high)
        #expect(context.capability == 9)
        #expect(await backend.createdThinkingSelection() == .high)
        #expect(output.contains("model=deep-model"))
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
    func createAgentsRejectsExplicitModelWithoutProfile() async throws {
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
        } catch DirectSubAgentRuntimeError.explicitModelRequiresProfile(let modelID) {
            #expect(modelID == "other-model")
        }
    }

    @Test
    func createAgentsWarnsWhenRequestedProfileDoesNotMatch() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in nil }
        )

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("review-pass"),
                "profile": .string("Rewiever")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        #expect(output.contains("Warning: requested profile \"Rewiever\""))
        #expect(output.contains("inherits the parent session's model"))
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
                "profile": .string("Minimal"),
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

        #expect(output.contains("model \"power-model\" at capability 8/10"))
        #expect(output.contains("capability gap of 1"))
        #expect(!output.contains("capability gap of 6"))
    }

    @Test
    func agentCreateDescriptorUsesCanonicalEnglishSelectionPolicy() throws {
        let descriptor = try #require(
            DirectToolCatalog.subAgentDescriptors.first { $0.name == "agent.create" }
        )

        #expect(descriptor.description.contains(TaskRecord.agentSelectionPolicy))
        #expect(descriptor.description.contains("Give each sub-agent an explicit role and scope"))
        #expect(descriptor.description.contains(
            "A resolved profile grants its configured tools to the sub-agent"
        ))
        #expect(descriptor.description.contains(
            "Only when no profile resolves does the sub-agent inherit the parent session's enabled tools"
        ))
        #expect(descriptor.description.contains("authorized bindings"))
        #expect(descriptor.inputSchema.contains("\"modelID\""))
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
                "role": .string("Minimal")
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
    func applyingSubAgentBackendContextSwapsModelWhenProfileHasModel() {
        let parentConfig = AgentRuntimeConfiguration(
            modelID: "parent-model",
            bearerToken: nil,
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
            profile: profile
        )
        let result = parentConfig.applyingSubAgentBackendContext(context)
        #expect(result.modelID == "builder-model")
    }

    @Test
    func applyingSubAgentBackendContextPreservesModelWhenProfileHasNoModel() {
        let parentConfig = AgentRuntimeConfiguration(
            modelID: "parent-model",
            bearerToken: nil,
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
            modelID: "local-mlx-model",
            bearerToken: nil,
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
        #expect(result.modelID == "local-mlx-model")
    }

    @Test
    func createAgentsUseUniqueEphemeralSessionsWithoutCacheKeys() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend }
        )

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object([
                        "name": .string("planner-one"),
                        "prompt": .string("Plan one")
                    ]),
                    .object([
                        "name": .string("planner-two"),
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
    func overviewSnapshotsShowOnlyMostRecentCreateBatchWithoutPruningRegistry() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory: { _ in backend }
        )
        let runtime = await executor.subAgentRuntime
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests",
            isDirectory: true
        )

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first-a")]),
                    .object(["name": .string("first-b")])
                ])
            ],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil
        )

        let firstOverview = await executor.subAgentSnapshots()
        #expect(Set(firstOverview.map(\.name)) == ["first-a", "first-b"])

        _ = try await runtime.createAgents(
            arguments: ["name": .string("second")],
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
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend })
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("reporter"),
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
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend })
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker-1"),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("focused-lookup")],
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("focused-lookup")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        do {
            _ = try await runtime.createAgents(
                arguments: ["name": .string("second-lookup")],
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("lookup"),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first")]),
                    .object(["name": .string("second")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("first")]),
                        .object(["name": .string("second")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("tracked"), "taskID": .string("tracked")]),
                        .object(["name": .string("untracked")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("plan-author")],
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
            }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("first"),
                "prompt": .string("Investigate the first concern")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        do {
            _ = try await runtime.createAgents(
                arguments: ["name": .string("second")],
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first"), "taskID": .string("first")]),
                    .object(["name": .string("second"), "task_id": .string("second")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first")]),
                    .object(["name": .string("second")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("first")]),
                        .object(["name": .string("second")]),
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
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend })
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("a"), "taskID": .string("task-a")]),
                        .object(["name": .string("b"), "taskID": .string("task-b")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)
        let arguments: [String: JSONValue] = ["taskID": .string("task-a")]
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)
        _ = try await runtime.createAgents(
            arguments: ["name": .string("closer"), "taskID": .string("close-task")],
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
            arguments: ["name": .string("shutdown"), "taskID": .string("shutdown-task")],
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
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
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend })
        await runtime.installTaskOrchestrator(orchestrator)
        for sessionID in ["root-a", "root-b"] {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string(sessionID),
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

private final class SubAgentFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedContexts: [DirectSubAgentRuntime.BackendContext] = []

    var contexts: [DirectSubAgentRuntime.BackendContext] {
        lock.lock()
        defer { lock.unlock() }
        return recordedContexts
    }

    func append(_ context: DirectSubAgentRuntime.BackendContext) {
        lock.lock()
        recordedContexts.append(context)
        lock.unlock()
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

    init(responseText: String = "done", blocksPrompts: Bool = false) {
        self.responseText = responseText
        self.blocksPrompts = blocksPrompts
    }

    func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        installedTaskOrchestrator = true
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
