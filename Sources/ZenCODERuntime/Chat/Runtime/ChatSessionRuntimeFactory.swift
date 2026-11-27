//
//  ChatSessionRuntimeFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// The public construction point of the session runtime behind a chat
/// session.
///
/// The backend is chosen in one place of the runtime,
/// ``productionBackendFactory``. The composition roots (the `zen` executable
/// and a host app) inject it; no other layer of `ZenCODERuntime` or
/// `ZenCODECore` chooses a backend. The
/// terminal chat, the headless runner, and the command-line runner build their
/// ``AgentCoreSessionRunner`` with ``makeSessionRunner(toolAuthorizationHandler:featureRuntime:mcpRuntime:backendFactory:)``,
/// so every channel composes the runtime the same way.
///
/// The compatibility fallback of a runner created with a nil factory is
/// unchanged: it still builds the remote backend itself.
public enum ChatSessionRuntimeFactory {
    /// The production backend: the remote generation client of the selected
    /// provider. Building it opens no connection.
    ///
    /// The feature runtime of the session travels in
    /// ``AgentRuntimeConfiguration/swiftFeatureRuntime`` and is forwarded to the
    /// remote client, so a backend rebuilt for a model or agent change shares
    /// it instead of creating (and later releasing) a runtime of its own.
    public static let productionBackendFactory: AgentRuntimeBackendFactory = { configuration, mcpRuntime in
        try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: configuration.swiftFeatureRuntime
        )
    }

    /// Builds the session runner of a chat session.
    ///
    /// - Parameters:
    ///   - toolAuthorizationHandler: Default consent of the gated tool calls,
    ///     usually ``ChatToolConsentAuthorizer/authorize(_:)`` of the channel.
    ///     With nil only the handler of each turn decides; a gated call with
    ///     neither fails closed.
    ///   - featureRuntime: Session-scoped feature runtime, shared with the
    ///     controller's ``ChatSessionEnvironment``. The runner also hands it to
    ///     every backend its factory builds (through
    ///     ``AgentRuntimeConfiguration/swiftFeatureRuntime``), so it survives a
    ///     change of model or agent. It must not be recreated while a backend
    ///     is live.
    ///   - mcpRuntime: Runtime of the external MCP tools.
    ///   - backendFactory: Backend of the session; defaults to
    ///     ``productionBackendFactory``.
    public static func makeSessionRunner(
        toolAuthorizationHandler: AgentToolAuthorizationHandler?,
        featureRuntime: SwiftFeatureRuntime = SwiftFeatureRuntime(),
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        backendFactory: AgentRuntimeBackendFactory? = productionBackendFactory
    ) -> AgentCoreSessionRunner {
        AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: toolAuthorizationHandler,
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: featureRuntime,
            backendFactory: backendFactory
        )
    }
}
