import Foundation
@testable import FeatureMCPBridgeKit
@testable import XcodeToolsFeature
import Testing

@Suite(.serialized)
struct XcodeMCPTransportPolicyTests {
    #if os(macOS)
    @Test
    func authorizationFailuresAreDetectedFromBridgeStderr() async {
        let client = makeClient()

        let error = await client.classifiedPolicyError(
            kind: .stderr,
            message: "The operation couldn’t be completed. (com.apple.dt.Xcode.MCPBridge.Authorization error 1.)",
            hasStderrOutput: true
        )

        #expect(error?.localizedDescription == XcodeMCPServerConfiguration.authorizationMessage)
    }

    @Test
    func bridgeListToolsErrorsAreTreatedAsAuthorizationRequired() async {
        let client = makeClient()
        let response = MCPErrorResponse(code: -32000, message: "Internal error")

        let error = await client.serverError(response, requestMethod: "tools/list")

        #expect(error.localizedDescription == XcodeMCPServerConfiguration.authorizationMessage)
    }

    @Test
    func classifiedAuthorizationTerminationStoresError() async throws {
        let client = makeClient()
        let classifiedError = await client.classifiedPolicyError(
            kind: .stdoutClosed,
            hasStderrOutput: false
        )
        let error = try #require(classifiedError)

        await client.applyClassifiedPolicyError(error)

        let storedError = await client.terminalBridgeError
        #expect(storedError?.localizedDescription == XcodeMCPServerConfiguration.authorizationMessage)
    }

    @Test
    func bridgeStdoutPermissionErrorsTerminatePendingBridge() async {
        let client = makeClient()

        await client.append(
            Data("""
            {"jsonrpc":"2.0","id":2,"error":{"code":-32000,"message":"Error Domain=IDEIntelligenceMessaging.BridgeError Code=1"}}
            """.utf8)
        )

        let storedError = await client.terminalBridgeError
        #expect(storedError?.localizedDescription == XcodeMCPServerConfiguration.authorizationMessage)
    }

    @Test
    func bridgeUnroutedErrorsTerminatePendingBridge() async {
        let client = makeClient()
        await client.recordPendingRequestMethodForTesting(id: 2, method: "tools/list")

        await client.append(
            Data("""
            {"jsonrpc":"2.0","id":null,"error":{"code":-32000,"message":"Internal error"}}
            """.utf8)
        )

        let storedError = await client.terminalBridgeError
        #expect(storedError?.localizedDescription == XcodeMCPServerConfiguration.authorizationMessage)
    }

    @Test
    func bridgeDiagnosticPermissionErrorsTerminatePendingBridge() async {
        let client = makeClient()
        await client.recordPendingRequestMethodForTesting(id: 2, method: "tools/list")

        await client.handleDiagnosticLine(
            "mcpbridge[28755] listTools request failed: Error Domain=IDEIntelligenceMessaging.BridgeError Code=1"
        )

        let storedError = await client.terminalBridgeError
        #expect(storedError?.localizedDescription == XcodeMCPServerConfiguration.authorizationMessage)
    }
    #endif

    private func makeClient() -> MCPClient {
        MCPClient(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/xcrun",
                arguments: ["mcpbridge"],
                environment: [:]
            ),
            localTransportPolicy: XcodeMCPTransportPolicy.make()
        )
    }
}
