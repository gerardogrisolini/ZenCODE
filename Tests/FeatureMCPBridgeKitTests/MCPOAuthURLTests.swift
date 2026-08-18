@testable import FeatureMCPBridgeKit
import Foundation
import Testing

#if os(macOS)
@Suite
struct MCPOAuthURLTests {
    @Test
    func defaultMetadataURLPreservesOriginAndUsesWellKnownPath() throws {
        let endpoint = try #require(URL(string: "https://mcp.example:8443/rpc"))
        let metadataURL = try MCPHTTPTransportClient.defaultOAuthMetadataURL(for: endpoint)
        #expect(metadataURL.absoluteString == "https://mcp.example:8443/.well-known/oauth-authorization-server")
    }

    @Test
    func invalidEndpointFailsClosedWithTypedAuthenticationError() throws {
        let endpoint = try #require(URL(string: "relative-endpoint"))
        do {
            _ = try MCPHTTPTransportClient.defaultOAuthMetadataURL(for: endpoint)
            Issue.record("Expected invalid OAuth endpoint URL to fail closed")
        } catch let error as MCPClientError {
            guard case .browserAuthenticationFailed = error else {
                Issue.record("Unexpected MCP error: \(error)")
                return
            }
        }
    }
}
#endif
