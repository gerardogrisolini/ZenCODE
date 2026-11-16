//
//  MCPLocalTransportWriterTests+Bridge.swift
//  ZenCODE
//
//  Tests of the local MCP transport that run a fixture bridge process:
//  cancelled requests that never reach the bridge, disconnect with requests
//  in flight, and reconnect after a spontaneous bridge exit.
//

@testable import FeatureMCPBridgeKit
import Dispatch
import Foundation
import Testing

#if os(macOS)
import Darwin

extension MCPLocalTransportWriterTests {
    @Test
    func aCancelledLocalRequestIsNotSentToTheBridge() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-cancel-write-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("mcp-fixture")
        let receivedURL = rootURL.appendingPathComponent("received.log")
        // The fixture answers initialize, then records every later request so the
        // test can assert that a cancelled tools/call never reaches the bridge.
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
            *)
              printf '%s\n' "$line" >> "\(receivedURL.path)"
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

            let call = Task {
                try await client.callTool(named: "slow", arguments: [:])
            }
            call.cancel()
            do {
                _ = try await call.value
                Issue.record("Expected the cancelled tool call to throw.")
            } catch {
                // Expected: cancellation, not a bridge response.
            }

            // Give a regressed implementation time to deliver the write.
            try await Task.sleep(nanoseconds: 300_000_000)
            let received = (try? String(contentsOf: receivedURL, encoding: .utf8)) ?? ""
            #expect(!received.contains("tools/call"))
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()

        // Teardown must leave no live bridge behind.
        #expect(await client.process == nil)
        #expect(await client.inputHandle == nil)
    }

    @Test
    func disconnectConcludesInFlightRequestsAndClearsTheWriter() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-disconnect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("mcp-fixture")
        // Answers initialize, then never replies again: the pending request can
        // only be concluded by disconnect().
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
        try await client.connect()

        let pending = Task {
            try await client.callTool(named: "never-answered", arguments: [:])
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        await client.disconnect()

        do {
            _ = try await pending.value
            Issue.record("Expected the pending request to fail on disconnect.")
        } catch {
            // Expected: connectionClosed.
        }

        #expect(await client.process == nil)
        #expect(await client.writer == nil)
        #expect(await client.inputHandle == nil)
        #expect(await client.outputHandle == nil)
        #expect(await client.errorHandle == nil)
    }

    @Test
    func aSpontaneousBridgeExitClearsTheWriterAndAllowsAWorkingReconnect() async throws {
        // Regression: the termination handler closed stdin while the previous
        // generation's writer was still alive and still published on the actor.
        // A later connect() could inherit it, so writes went to a closed — and
        // possibly recycled — descriptor instead of the new bridge's stdin.
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-exit-reconnect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let executableURL = rootURL.appendingPathComponent("mcp-fixture")
        let receivedURL = rootURL.appendingPathComponent("received.log")
        // Answers initialize, exits abruptly on `exit-now`, and records every
        // other request so the post-reconnect write can be observed on the wire.
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
            *exit-now*)
              exit 3
              ;;
            *)
              printf '%s\n' "$line" >> "\(receivedURL.path)"
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
        try await client.connect()

        // Provoke the spontaneous exit: the request can only fail.
        do {
            _ = try await client.callTool(named: "exit-now", arguments: [:])
            Issue.record("Expected the request to fail when the bridge exits.")
        } catch {
            // Expected: the exit is classified as a terminal bridge error.
        }

        // The termination handler runs asynchronously; wait for it to settle.
        var settled = false
        for _ in 0..<200 where !settled {
            if await client.process == nil, await client.writer == nil {
                settled = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(settled)
        // The writer must be gone, not merely unused: a surviving writer is what
        // a reconnect would inherit.
        #expect(await client.writer == nil)
        #expect(await client.inputHandle == nil)
        #expect(await client.outputHandle == nil)
        #expect(await client.errorHandle == nil)

        // A terminal error is sticky, so clear it the way a caller would, then
        // reconnect the SAME client: this is the path that used to inherit the
        // previous generation's writer.
        await client.disconnect()
        try await client.connect()
        #expect(await client.writer != nil)

        // Prove the fresh writer targets the LIVE bridge's stdin: the fixture
        // records this request but never answers it.
        let afterReconnect = Task {
            try await client.callTool(named: "after-reconnect", arguments: [:])
        }
        var observedOnTheWire = false
        for _ in 0..<200 where !observedOnTheWire {
            let received = (try? String(contentsOf: receivedURL, encoding: .utf8)) ?? ""
            if received.contains("after-reconnect") {
                observedOnTheWire = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(observedOnTheWire)

        afterReconnect.cancel()
        _ = try? await afterReconnect.value
        await client.disconnect()
        #expect(await client.process == nil)
        #expect(await client.writer == nil)
    }
}
#endif
