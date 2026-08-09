//
//  ZenCODEACPBridge.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import FeatureMCPBridgeKit
import Foundation
import ToolCore

/// Thrown by `ensureNotShutDown()` once `shutdown()` latched.
///
/// It is deliberately *not* an `ACPError`: the transport is closing, so the
/// request is abandoned without writing a JSON-RPC response. Wire format for
/// every non-shutdown outcome is unchanged.
struct ACPShutdownFenceError: Error {}

public actor ZenCODEACPBridge {
    public enum SessionOperationState: Sendable, Equatable {
        case idle
        case prompting(UUID)
        case reconfiguring(UUID)
    }

    public struct SessionState {
        public let id: String
        public let cwd: String
        public let allowedToolNames: Set<String>?
        public let configuration: AgentCoreSessionConfiguration
        /// Identifies this incarnation of the session. `session/close` and
        /// `shutdown` drop it, so work started under an older epoch can never
        /// write state back into a newer session with the same id.
        public let epoch: UInt64
        public var selectedAgent: AgentProfile?
        /// Reserved synchronously by `session/prompt` before its first `await`,
        /// making one prompt per session atomically exclusive even when several
        /// requests are dispatched concurrently.
        public var activePromptID: UUID?
        public var activePromptTask: Task<PromptCompletion, Error>?
        /// Reserved synchronously before an operation's first suspension. This
        /// prevents a prompt and a configuration change (or two configuration
        /// changes) from both observing the session as idle.
        public var operationState: SessionOperationState
    }

    public struct PromptCompletion: Sendable {
        public let text: String
        public let stopReason: String
    }

    /// One ACP session's shared-chat renderer.
    ///
    /// It is held outside `SessionState` on purpose: that value is rebuilt from
    /// scratch by a snapshot refresh, by `@agent` routing and by every
    /// reconfiguration commit, so a handle stored inside it would be dropped —
    /// leaking the observer and silently ending the rendering — by paths that
    /// have no reason to know about shared chat.
    struct SharedChatForwarder {
        /// Incarnation this renderer belongs to. A reservation whose epoch no
        /// longer matches is stale and is never published or reused.
        let epoch: UInt64
        /// `nil` while the attach is still suspended. The reservation is
        /// published before that suspension, which is what makes a second
        /// `start` for the same session a no-op instead of a second observer.
        /// The task owns completion of the attach and detaches the observation
        /// itself if teardown removed this reservation while it was suspended.
        let attachTask: Task<Void, Never>
        /// The published value also carries the room this renderer observes.
        var observation: AgentSharedChatCoordinator.Observation?
        var task: Task<Void, Never>?
    }

    /// Identifies the session incarnation a lifecycle operation acts on, so a
    /// `session/close` can invalidate that operation without touching lifecycle
    /// work belonging to other sessions or to a newer incarnation.
    struct SessionBinding: Hashable {
        let sessionID: String
        let epoch: UInt64
    }

    public let configuration: AgentConfiguration
    public let writer: ACPWriter
    public let permissionBroker: ACPPermissionBroker
    public let sessionRunner: AgentCoreSessionRunner
    public let verboseLogFile: ACPVerboseLogFile?
    public var sessions: [String: SessionState] = [:]
    /// Shared-chat renderers by session id, one per live incarnation. Keyed
    /// separately from `sessions` so no session rebuild can drop a live
    /// observer; the epoch inside each entry is what binds it to its session.
    var sharedChatForwarders: [String: SharedChatForwarder] = [:]
    /// Test seam that can park an attach after its reservation was published.
    /// It is intentionally internal: production leaves it `nil`.
    var sharedChatAttachBarrier: (@Sendable () async -> Void)?
    private var sessionSleepAssertion: ZenSleepAssertion?
    private var nextSessionEpochValue: UInt64 = 1
    /// Latches on `shutdown()` so late prompt completions and new requests
    /// cannot repopulate session state after the transport closed.
    private var didShutDown = false
    /// Tokens of lifecycle operations (`session/new`, `load`, `resume`,
    /// `set_model`, `set_config_option`) that are currently suspended. Cleared
    /// wholesale by `shutdown()`, which turns every later re-check into a
    /// `ACPShutdownFenceError`.
    private var lifecycleOperations: Set<UInt64> = []
    /// Session incarnation a lifecycle operation acts on, for the handlers that
    /// mutate an existing session. `session/close` invalidates exactly the
    /// operations bound to the incarnation it closes, and nothing else.
    private var lifecycleOperationBindings: [UInt64: SessionBinding] = [:]
    private var nextLifecycleOperationToken: UInt64 = 1

    public init(
        configuration: AgentConfiguration,
        writer: ACPWriter,
        backendFactory: AgentRuntimeBackendFactory? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime()
    ) {
        self.configuration = configuration
        self.writer = writer
        let verboseLogFile = configuration.verboseLogging ? ACPVerboseLogFile.open() : nil
        self.verboseLogFile = verboseLogFile
        let permissionBroker = ACPPermissionBroker(writer: writer)
        self.permissionBroker = permissionBroker
        self.sessionRunner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await permissionBroker.authorize(request)
            },
            mcpRuntime: mcpRuntime,
            backendFactory: backendFactory
        )
    }

    public func shutdown() async {
        guard !didShutDown else {
            return
        }
        // Fence first, without suspending: every prompt still winding down is
        // now cancelled and forbidden from writing session state back.
        didShutDown = true
        // Every lifecycle handler suspended right now is fenced: its next
        // re-check fails, so it cannot create a session, build a backend, or
        // answer on the closing transport.
        lifecycleOperations.removeAll()
        lifecycleOperationBindings.removeAll()
        let sessionIDs = Array(sessions.keys)
        for sessionID in sessionIDs {
            sessions[sessionID]?.activePromptTask?.cancel()
            sessions[sessionID]?.activePromptTask = nil
            sessions[sessionID]?.activePromptID = nil
        }
        // Take the renderers and cancel them synchronously too. Awaiting their
        // quiescence here would suspend *before* the writer fence below, which
        // is exactly the window in which a late request still observes live
        // sessions; the wait therefore happens after the transport is closed.
        let forwarders = Array(sharedChatForwarders.values)
        sharedChatForwarders.removeAll()
        for forwarder in forwarders {
            forwarder.task?.cancel()
        }
        // No snapshot refresh here: the fence above already makes every
        // `refreshSessionStateIfAvailable` a no-op, and `sessions` is dropped
        // immediately below, so awaiting the runner would only widen the
        // window in which late requests still observe live session entries.
        sessions.removeAll()
        updateSessionSleepAssertion()
        // Close the transport before the first suspension. Everything the
        // bridge can still emit (a prompt that is unwinding, its buffered
        // updates, its final result, a late error response) goes through this
        // writer, so latching it here is what makes "nothing is written after
        // shutdown" true regardless of where in-flight work was parked.
        await writer.close()
        // Only now wait for the renderers to stop and release their observers.
        // Every write they could still attempt is already fenced by the closed
        // writer, so this await cannot widen the shutdown window.
        for forwarder in forwarders {
            await finishSharedChatForwarding(forwarder)
        }
        await sessionRunner.shutdown()
    }

    /// `true` once `shutdown()` ran; used to fence late session mutations.
    var isShutDown: Bool {
        didShutDown
    }

    /// Re-checkable fence for lifecycle handlers.
    ///
    /// `newSession` and `restoreSession` suspend several times (MCP server
    /// registration, external-tool discovery, verbose logging) before they
    /// mutate `sessions`, call the runner, or write to the transport. Calling
    /// this after every such suspension guarantees a request that was already
    /// in flight when `shutdown()` latched can no longer create a session, spin
    /// up a backend, or emit a response on a closing transport.
    func ensureNotShutDown() throws {
        guard !didShutDown else {
            throw ACPShutdownFenceError()
        }
    }

    /// Registers a lifecycle operation and returns its cancellation token.
    ///
    /// `shutdown()` cancels every registered operation, so a handler blocked in
    /// a long `await` (an unreachable MCP server, a slow runner) is unblocked
    /// instead of completing its work against a dead transport.
    func registerLifecycleOperation() throws -> UInt64 {
        try ensureNotShutDown()
        let token = nextLifecycleOperationToken
        nextLifecycleOperationToken &+= 1
        lifecycleOperations.insert(token)
        return token
    }

    /// Binds an already-registered operation to one session incarnation.
    ///
    /// Handlers that mutate an existing session (`set_model`,
    /// `set_config_option`, the restore fast path) claim their token before the
    /// first `await`, but only learn which session they act on afterwards.
    /// Binding makes `session/close` on that session invalidate them, so a set
    /// or restore that was suspended in the runner cannot report success for a
    /// session that no longer exists.
    func bindLifecycleOperation(_ token: UInt64, sessionID: String, epoch: UInt64) {
        guard lifecycleOperations.contains(token) else {
            return
        }
        lifecycleOperationBindings[token] = SessionBinding(
            sessionID: sessionID,
            epoch: epoch
        )
    }

    /// Invalidates every lifecycle operation bound to this exact incarnation.
    /// Used by `session/close`, which must not disturb other sessions.
    func invalidateLifecycleOperations(sessionID: String, epoch: UInt64) {
        let binding = SessionBinding(sessionID: sessionID, epoch: epoch)
        let staleTokens = lifecycleOperationBindings
            .filter { $0.value == binding }
            .map(\.key)
        for token in staleTokens {
            lifecycleOperations.remove(token)
            lifecycleOperationBindings.removeValue(forKey: token)
        }
    }

    func finishLifecycleOperation(_ token: UInt64) {
        lifecycleOperations.remove(token)
        lifecycleOperationBindings.removeValue(forKey: token)
    }

    /// `true` while the operation is still registered, i.e. not fenced by a
    /// `shutdown()` or by a `session/close` of the incarnation it is bound to.
    func isLifecycleOperationLive(_ token: UInt64) -> Bool {
        guard !didShutDown, lifecycleOperations.contains(token) else {
            return false
        }
        guard let binding = lifecycleOperationBindings[token] else {
            return true
        }
        // Bound operations additionally require their incarnation to still be
        // the live one: a close followed by a new session with the same id must
        // not let stale work write into the newcomer.
        return sessions[binding.sessionID]?.epoch == binding.epoch
    }

    /// Combined re-check for a lifecycle operation after a suspension point.
    func ensureLifecycleOperationLive(_ token: UInt64) throws {
        guard isLifecycleOperationLive(token) else {
            throw ACPShutdownFenceError()
        }
    }

    func makeSessionEpoch() -> UInt64 {
        let epoch = nextSessionEpochValue
        nextSessionEpochValue &+= 1
        return epoch
    }

    /// Returns the session only when it is still the same incarnation, so a
    /// caller that suspended cannot resurrect a closed or replaced session.
    func liveSession(id sessionID: String, epoch: UInt64) -> SessionState? {
        guard !didShutDown,
              let session = sessions[sessionID],
              session.epoch == epoch else {
            return nil
        }
        return session
    }

    /// Writes the session back only when the epoch still matches.
    @discardableResult
    func updateLiveSession(
        id sessionID: String,
        epoch: UInt64,
        _ mutate: (inout SessionState) -> Void
    ) -> Bool {
        guard var session = liveSession(id: sessionID, epoch: epoch) else {
            return false
        }
        mutate(&session)
        sessions[sessionID] = session
        return true
    }

    /// Removes the session only when it is still the incarnation the caller
    /// created, so a rollback never deletes a newer session with the same id.
    func discardSessionIfCurrent(id sessionID: String, epoch: UInt64) {
        guard sessions[sessionID]?.epoch == epoch else {
            return
        }
        sessions.removeValue(forKey: sessionID)
        updateSessionSleepAssertion()
    }

    public func holdSessionSleepAssertionIfNeeded() {
        guard sessionSleepAssertion == nil else {
            return
        }
        sessionSleepAssertion = ZenSleepAssertion(
            reason: "ZenCODE ACP session active"
        )
    }

    public func updateSessionSleepAssertion() {
        if sessions.isEmpty {
            sessionSleepAssertion?.invalidate()
            sessionSleepAssertion = nil
        } else {
            holdSessionSleepAssertionIfNeeded()
        }
    }

    public func verboseACPLog(_ message: @autoclosure () -> String) async {
        guard configuration.verboseLogging else {
            return
        }
        let message = message()
        await verboseLogFile?.write("[ZenCODE][ACP] \(message)")
    }

    public func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            await writer.sendError(id: .null, code: -32700, message: "Input is not valid UTF-8.")
            return
        }

        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let object = value.objectValue else {
                await writer.sendError(id: .null, code: -32600, message: "JSON-RPC message must be an object.")
                return
            }
            await handleJSONMessage(object)
        } catch {
            await writer.sendError(id: .null, code: -32700, message: "Invalid JSON.")
        }
    }

    public func handleMessage(_ message: [String: Any]) async {
        await handleJSONMessage(message.mapValues { JSONValue(jsonObject: $0) })
    }

    private func handleJSONMessage(_ message: [String: JSONValue]) async {
        let id = JSONValue.acpRequestID(from: message)
        if message["jsonrpc"]?.stringValue == "2.0",
           message["method"] == nil,
           id != nil {
            await permissionBroker.handleResponse(.object(message))
            return
        }
        guard message["jsonrpc"]?.stringValue == "2.0",
              let method = message["method"]?.stringValue else {
            await writer.sendErrorIfRequest(
                id: id,
                code: -32600,
                message: "Invalid JSON-RPC request."
            )
            return
        }

        do {
            let params = jsonObjectParams(from: message).mapValues(\.jsonObject)
            switch method {
            case "initialize":
                try await initialize(id: id, params: params)
            case "authenticate":
                await writer.sendResultIfRequest(id: id, result: .object([:]))
            case "_zencode/model/preload":
                try await preloadModel(id: id, params: params)
            case "session/new":
                try await newSession(id: id, params: params)
            case "session/set_mode":
                try await setMode(id: id, params: params)
            case "_zencode/session/set_model":
                try await setModel(id: id, params: params)
            case "session/set_config_option":
                try await setConfigOption(id: id, params: params)
            case "session/prompt":
                try await prompt(id: id, params: params)
            case "session/cancel":
                try await cancel(id: id, params: params)
            case "session/close":
                try await close(id: id, params: params)
            case "session/load":
                try await loadSession(id: id, params: params)
            case "session/resume":
                try await resumeSession(id: id, params: params)
            default:
                await writer.sendErrorIfRequest(
                    id: id,
                    code: -32601,
                    message: "Method not found: \(method)"
                )
            }
        } catch let error as ACPError {
            await writer.sendErrorIfRequest(
                id: id,
                code: error.code,
                message: error.message
            )
        } catch is ACPShutdownFenceError {
            // The transport is closing: deliberately send nothing. `shutdown()`
            // already failed every pending host request, and writing a late
            // response here is exactly the leak this fence prevents.
            await verboseACPLog("request abandoned: agent is shutting down")
        } catch is CancellationError {
            await writer.sendResultIfRequest(
                id: id,
                result: JSONValue.acpValue(from: ["stopReason": "cancelled"])
            )
        } catch {
            await writer.sendErrorIfRequest(
                id: id,
                code: -32603,
                message: error.localizedDescription
            )
        }
    }

    public func objectParams(from message: [String: Any]) throws -> [String: Any] {
        guard let params = message["params"] as? [String: Any] else {
            return [:]
        }
        return params
    }

    private func jsonObjectParams(from message: [String: JSONValue]) -> [String: JSONValue] {
        message["params"]?.objectValue ?? [:]
    }
}
