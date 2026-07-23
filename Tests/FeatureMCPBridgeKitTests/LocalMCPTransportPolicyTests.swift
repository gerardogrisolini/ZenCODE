@testable import FeatureMCPBridgeKit
import Foundation
import Testing

#if os(macOS)
import Darwin
#endif

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

    @Test
    func staleReaderGenerationCannotMutateTheCurrentConnection() async {
        let client = MCPClient(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/false",
                arguments: [],
                environment: [:]
            ),
            localTransportPolicy: LocalMCPTransportPolicy(
                errorClassifier: { event in
                    switch event.kind {
                    case .diagnostic:
                        .authorizationRequired(service: "fixture", message: event.message)
                    default:
                        nil
                    }
                }
            )
        )
        let currentConnectionID = UUID()
        let staleConnectionID = UUID()
        await client.setActiveConnectionIDForTesting(currentConnectionID)
        await client.setDiagnosticMonitorConnectionIDForTesting(currentConnectionID)

        await client.handleStdoutChunk(
            Data("stale stdout".utf8),
            connectionID: staleConnectionID
        )
        await client.handleStderrChunk(
            Data("stale stderr".utf8),
            connectionID: staleConnectionID
        )
        await client.handleDiagnosticLine("stale diagnostic", connectionID: staleConnectionID)

        #expect(await client.buffer.isEmpty)
        #expect(await client.stderrBuffer.isEmpty)
        #expect(await client.terminalBridgeError == nil)
        #expect(await client.shouldStopReaderAfterProcessTermination(
            connectionID: staleConnectionID
        ))
        #expect(!(await client.shouldStopReaderAfterProcessTermination(
            connectionID: currentConnectionID
        )))
    }

    @Test
    func bridgeExitAfterFinalResponseReleasesLocalReaders() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-reader-exit-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("mcp-fixture")
        let descendantPIDURL = rootURL.appendingPathComponent("descendant.pid")
        defer {
            terminateFixtureProcess(recordedAt: descendantPIDURL)
        }
        try """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p')
          case "$line" in
            *notifications/initialized*)
              ;;
            *initialize*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
            *tools*list*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":[]}}'
              /usr/bin/yes &
              printf '%s\n' "$!" > "\(descendantPIDURL.path)"
              exit 0
              ;;
          esac
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let client = MCPClient(
            configuration: MCPServerConfiguration(
                executablePath: executableURL.path,
                arguments: [],
                environment: [:]
            )
        )
        do {
            try await client.connect()
            _ = try await client.listTools()

            #expect(await waitForLocalBridgeTermination(client))
            #expect(await client.process == nil)
            #expect(await client.inputHandle == nil)
            #expect(await client.outputHandle == nil)
            #expect(await client.errorHandle == nil)
            #expect(await client.readLoopTask == nil)
            #expect(await client.errorLoopTask == nil)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    @Test
    func classifiedBridgeErrorReleasesLocalReaders() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-reader-policy-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("mcp-fixture")
        let descendantPIDURL = rootURL.appendingPathComponent("descendant.pid")
        defer {
            terminateFixtureProcess(recordedAt: descendantPIDURL)
        }
        try """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p')
          case "$line" in
            *notifications/initialized*)
              ;;
            *initialize*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
            *tools*list*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"error":{"code":-32000,"message":"fixture policy failure"}}'
              /bin/sleep 30 &
              printf '%s\n' "$!" > "\(descendantPIDURL.path)"
              exit 0
              ;;
          esac
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let policy = LocalMCPTransportPolicy(
            errorClassifier: { event in
                switch event.kind {
                case .serverError where event.message == "fixture policy failure":
                    .authorizationRequired(service: "fixture", message: event.message)
                default:
                    nil
                }
            }
        )
        let client = MCPClient(
            configuration: MCPServerConfiguration(
                executablePath: executableURL.path,
                arguments: [],
                environment: [:]
            ),
            localTransportPolicy: policy
        )
        do {
            try await client.connect()
            do {
                _ = try await client.listTools()
                Issue.record("Expected the classified MCP error to fail tools/list.")
            } catch let error as MCPClientError {
                guard case let .authorizationRequired(service, message) = error else {
                    Issue.record("Unexpected classified MCP error: \(error.localizedDescription)")
                    await client.disconnect()
                    return
                }
                #expect(service == "fixture")
                #expect(message == "fixture policy failure")
            }

            #expect(await waitForLocalBridgeTermination(client))
            #expect(await client.process == nil)
            #expect(await client.inputHandle == nil)
            #expect(await client.outputHandle == nil)
            #expect(await client.errorHandle == nil)
            #expect(await client.readLoopTask == nil)
            #expect(await client.errorLoopTask == nil)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }
    #endif
}

#if os(macOS)
private extension MCPClient {
    func setActiveConnectionIDForTesting(_ connectionID: UUID) {
        activeConnectionID = connectionID
    }

    func setDiagnosticMonitorConnectionIDForTesting(_ connectionID: UUID) {
        diagnosticMonitorConnectionID = connectionID
    }
}

private func waitForLocalBridgeTermination(_ client: MCPClient) async -> Bool {
    for _ in 0..<100 {
        if await client.process == nil {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

private func terminateFixtureProcess(recordedAt pidURL: URL) {
    guard let rawPID = try? String(contentsOf: pidURL, encoding: .utf8),
          let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        return
    }
    _ = Darwin.kill(pid, SIGTERM)
}
#endif
