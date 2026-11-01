//
//  ChatSessionRuntimeFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// The public construction point of the session runtime behind a chat
/// session.
///
/// The backend is chosen in one place of Core,
/// ``productionBackendFactory``. The composition roots (the `zen` executable
/// and a host app) inject it; no other layer of Core chooses a backend. The
/// terminal chat, the headless runner, and the command-line runner build their
/// ``AgentCoreSessionRunner`` with ``makeSessionRunner(toolAuthorizationHandler:featureRuntime:mcpRuntime:backendFactory:)``,
/// so every channel composes the runtime the same way.
///
/// The compatibility fallback of a runner created with a nil factory is
/// unchanged: it still builds the remote backend itself.
public enum ChatSessionRuntimeFactory {
    /// The production backend: the remote generation client of the selected
    /// provider. Building it opens no connection.
    public static let productionBackendFactory: AgentRuntimeBackendFactory = { configuration, mcpRuntime in
        try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: mcpRuntime
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
    ///     controller's ``ChatSessionEnvironment``. It must not be recreated
    ///     while a backend is live.
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
