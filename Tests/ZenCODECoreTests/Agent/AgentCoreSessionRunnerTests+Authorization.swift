//
//  AgentCoreSessionRunnerTests+Authorization.swift
//  ZenCODE
//
//  Tests for how AgentCoreSessionRunner routes tool authorization requests:
//  access modes, delegated requests and the lifecycle of the authorization
//  route.
//

import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing

extension AgentCoreSessionRunnerTests {
    @Test
    func localExecAccessModeRoutesDefaultAndPerPromptAuthorization() async throws {
        let defaultAuthorizer = AuthorizationRecorder(decision: false)
        let promptAuthorizer = AuthorizationRecorder(decision: false)
        let approvingPromptAuthorizer = AuthorizationRecorder(decision: true)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await defaultAuthorizer.authorize(request)
            },
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec", "local.read"]
        )

        try await runner.createSession(configuration: configuration)
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "default",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [false])
        #expect(await defaultAuthorizer.toolNames() == ["local.exec"])

        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "full access local exec",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [true])
        #expect(await defaultAuthorizer.toolNames() == ["local.exec"])

        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.read")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "full access other tool",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [false])
        #expect(await defaultAuthorizer.toolNames() == ["local.exec", "local.read"])

        #expect(await runner.toggleLocalExecAccessMode() == .standard)
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "default restored",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [false])
        #expect(await defaultAuthorizer.toolNames() == ["local.exec", "local.read", "local.exec"])

        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "default per-prompt",
            attachments: [],
            authorizeTool: { request in
                await approvingPromptAuthorizer.authorize(request)
            },
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [true])
        #expect(await approvingPromptAuthorizer.toolNames() == ["local.exec"])
        #expect(await defaultAuthorizer.toolNames() == ["local.exec", "local.read", "local.exec"])

        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec.foo"),
            Self.authorizationRequest(sessionID: sessionID, toolName: " local.exec"),
            Self.authorizationRequest(sessionID: sessionID, toolName: "LOCAL.EXEC")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "near-canonical names",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [false, false, false])
        #expect(
            await defaultAuthorizer.toolNames().suffix(3)
                == ["local.exec.foo", " local.exec", "LOCAL.EXEC"]
        )

        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec"),
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.read")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "per-prompt",
            attachments: [],
            authorizeTool: { request in
                await promptAuthorizer.authorize(request)
            },
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [true, false])
        #expect(await promptAuthorizer.toolNames() == ["local.read"])
    }

    @Test
    func fullAccessDoesNotOverrideDirectToolAllowlist() async throws {
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-full-access-allowlist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let markerURL = rootURL.appendingPathComponent("should-not-exist")
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: rootURL,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "initialize backend",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        let authorizationHandler = try #require(backendBox.authorizationHandler())
        let executor = DirectToolExecutor(
            authorizationHandler: authorizationHandler,
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentContextualBackendFactory: { _ in CapturingAgentRuntimeBackend() }
        )
        let command = "touch '\(markerURL.path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let toolCall = DirectAgentToolCall(
            id: "blocked-local-exec",
            name: "local.exec",
            argumentsObject: ["command": command],
            argumentsJSON: #"{"command":"blocked"}"#
        )

        let result = await executor.execute(
            sessionID: sessionID,
            toolCall: toolCall,
            workingDirectory: rootURL,
            allowedToolNames: ["local.read"]
        )

        #expect(result.status == .permissionDenied)
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
    }

    @Test
    func localExecAccessModeSurvivesOptionUpdateAndSessionRebuild() async throws {
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let baseConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )
        let updatedConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: "updated",
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec", "local.read"]
        )

        try await runner.createSession(configuration: baseConfiguration)
        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)
        try await runner.updateSessionOptions(configuration: updatedConfiguration)
        #expect(await runner.localExecAccessMode() == .fullAccess)

        await runner.rebuildSession(id: sessionID)
        #expect(await runner.localExecAccessMode() == .fullAccess)
        try await runner.createSession(configuration: updatedConfiguration)
        #expect(await runner.localExecAccessMode() == .fullAccess)
    }

    @Test
    func delegatedRequestReachesOperatorEvenWithoutLiveTurn() async throws {
        // The case the fix targets: a delegated sub-agent outlives the turn that
        // spawned it, so its consent request must still reach the operator even
        // when no turn is in flight, and the operator's decision must be honoured
        // both on approval and on denial.
        let approvingOperator = AuthorizationRecorder(decision: true)
        let denyingOperator = AuthorizationRecorder(decision: false)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)
        // Warm-up turn with no requests: it only creates the backend and
        // registers an approving operator handler for the session.
        backendBox.setAuthorizationRequests([])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "warm up",
            attachments: [],
            authorizeTool: { request in await approvingOperator.authorize(request) },
            onEvent: { _ in }
        )

        // `authorizationHandler()` is the runner's stable authorizeTool closure,
        // independent of any single turn. Capturing it and driving it directly
        // is exactly what a delegated sub-agent's executor does — and, crucially,
        // it runs *after* sendPrompt returned, so the per-turn handler entry has
        // already been removed by the `defer`. This is the most faithful way to
        // model "no turn in flight" with this backend: by the time `await
        // sendPrompt` resolves the turn has fully completed, so no sleep is
        // needed and the assertion is deterministic.
        let authorize = try #require(backendBox.authorizationHandler())

        // The request's own session is a bogus sub-agent session and carries no
        // turn id, so the turn-scoped path could never match it. Routing must
        // succeed purely on the runtime-minted delegation identity.
        let approved = await authorize(
            Self.authorizationRequest(
                sessionID: "sub-agent-private-session",
                toolName: "local.exec",
                delegatedIdentity: .init(agentID: "delegated-approver", rootSessionID: sessionID)
            )
        )
        #expect(approved == true)
        #expect(await approvingOperator.toolNames() == ["local.exec"])

        // A second turn swaps in a denying operator; the captured closure is the
        // same object, proving the request is answered by the session-scoped
        // handler that survives across turns — not by a per-turn entry.
        backendBox.setAuthorizationRequests([])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "deny handler",
            attachments: [],
            authorizeTool: { request in await denyingOperator.authorize(request) },
            onEvent: { _ in }
        )
        let denied = await authorize(
            Self.authorizationRequest(
                sessionID: "sub-agent-private-session",
                toolName: "local.delete",
                delegatedIdentity: .init(agentID: "delegated-denyer", rootSessionID: sessionID)
            )
        )
        #expect(denied == false)
        #expect(await denyingOperator.toolNames() == ["local.delete"])
    }

    @Test
    func delegatedRequestWithUnknownRootSessionIsDeniedAndUnseen() async throws {
        // An unknown root session names no operator this runner owns, so the
        // request must fail closed — even when a default authorizer would have
        // approved it. Neither the per-session handler nor the default is ever
        // consulted.
        let defaultAuthorizer = AuthorizationRecorder(decision: true)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await defaultAuthorizer.authorize(request)
            },
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)
        backendBox.setAuthorizationRequests([])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "warm up",
            attachments: [],
            onEvent: { _ in }
        )
        let authorize = try #require(backendBox.authorizationHandler())

        let result = await authorize(
            Self.authorizationRequest(
                sessionID: "sub-agent-private-session",
                toolName: "local.exec",
                delegatedIdentity: .init(agentID: "stranger", rootSessionID: "session-unknown-to-runner")
            )
        )
        #expect(result == false)
        #expect(await defaultAuthorizer.toolNames() == [])
    }

    @Test
    func nonDelegatedRequestRoutingIsUnchanged() async throws {
        // Regression guard for the original turn-scoped path: a plain request
        // (no delegation identity) is approved when its session matches the live
        // turn, and denied — without consulting the handler — when the session
        // is foreign to that turn.
        let authorizer = AuthorizationRecorder(decision: true)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await authorizer.authorize(request)
            },
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)

        // Matching session + live turn: reaches the handler, approved.
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: sessionID, toolName: "local.exec")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "match",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [true])
        #expect(await authorizer.toolNames() == ["local.exec"])

        // Foreign session while the turn is live: denied, handler untouched.
        backendBox.setAuthorizationRequests([
            Self.authorizationRequest(sessionID: "session-not-this-turn", toolName: "local.delete")
        ])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "mismatch",
            attachments: [],
            onEvent: { _ in }
        )
        #expect(backendBox.lastAuthorizationResults() == [false])
        #expect(await authorizer.toolNames() == ["local.exec"])
    }

    @Test
    func fullAccessShortCircuitsDelegatedRequestsForGatedTools() async throws {
        // The full-access bypass must cover delegated requests on gated tools
        // too, so a sub-agent never blocks on a dialog the operator has already
        // globally waived.
        let operatorHandler = AuthorizationRecorder(decision: false)
        let backendBox = AuthorizationBackendBox()
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await operatorHandler.authorize(request)
            },
            backendFactory: { configuration, _ in
                backendBox.makeBackend(handler: configuration.toolAuthorizationHandler)
            }
        )
        let sessionID = "session-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: ["local.exec"]
        )

        try await runner.createSession(configuration: configuration)
        backendBox.setAuthorizationRequests([])
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "warm up",
            attachments: [],
            onEvent: { _ in }
        )
        let authorize = try #require(backendBox.authorizationHandler())

        #expect(await runner.toggleLocalExecAccessMode() == .fullAccess)

        let result = await authorize(
            Self.authorizationRequest(
                sessionID: "sub-agent-private-session",
                toolName: "local.exec",
                delegatedIdentity: .init(agentID: "delegated-runner", rootSessionID: sessionID)
            )
        )
        // Auto-approved by full access; the operator would have denied, proving
        // the short-circuit fired before the delegated branch could ask.
        #expect(result == true)
        #expect(await operatorHandler.toolNames() == [])
    }

    @Test
    func sessionLifecycleReleasesPromptSkillProviderAndAuthorizationRoute() async throws {
        let backend = CapturingAgentRuntimeBackend()
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let sessionID = "session-lifecycle-\(UUID().uuidString)"
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: "stable-cache-key",
            history: [],
            allowedToolNames: []
        )

        try await runner.createSession(configuration: configuration)
        _ = try await runner.sendPrompt(
            configuration: configuration,
            prompt: "register authorization",
            attachments: [],
            authorizeTool: { _ in true },
            onEvent: { _ in }
        )
        #expect(
            await runner.lifecycleResourceCounts()
                == .init(promptSkillProviders: 1, authorizationSessions: 1)
        )

        await runner.rebuildSession(id: sessionID)
        #expect(
            await runner.lifecycleResourceCounts()
                == .init(promptSkillProviders: 0, authorizationSessions: 0)
        )

        try await runner.createSession(configuration: configuration)
        await runner.closeSession(id: sessionID)
        #expect(
            await runner.lifecycleResourceCounts()
                == .init(promptSkillProviders: 0, authorizationSessions: 0)
        )
    }

    private static func authorizationRequest(
        sessionID: String,
        toolName: String,
        delegatedIdentity: AgentToolAuthorizationRequest.DelegatedIdentity? = nil
    ) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            sessionID: sessionID,
            toolCallID: UUID().uuidString,
            toolName: toolName,
            title: toolName,
            kind: "execute",
            command: "echo test",
            workingDirectory: "/tmp",
            delegatedIdentity: delegatedIdentity
        )
    }
}
