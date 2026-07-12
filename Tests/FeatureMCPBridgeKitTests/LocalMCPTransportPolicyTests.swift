@testable import FeatureMCPBridgeKit
import Testing

@Suite
struct LocalMCPTransportPolicyTests {
    @Test
    func standardPolicyUsesTheProtocolHandshake() {
        #expect(LocalMCPTransportPolicy.standard.handshake == .standard)
    }

    #if os(macOS)
    @Test
    func standardPolicyLeavesServerErrorsGeneric() async {
        let client = MCPClient(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/false",
                arguments: [],
                environment: [:]
            )
        )
        let response = MCPErrorResponse(code: -32000, message: "Internal error")

        let error = await client.serverError(response, requestMethod: "tools/list")

        guard case let .serverError(code, message) = error else {
            Issue.record("The standard MCP policy unexpectedly classified a server error.")
            return
        }
        #expect(code == -32000)
        #expect(message == "Internal error")
    }
    #endif
}
