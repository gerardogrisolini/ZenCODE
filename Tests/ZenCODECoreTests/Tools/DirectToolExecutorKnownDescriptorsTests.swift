//
//  DirectToolExecutorKnownDescriptorsTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/11/26.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// The descriptors read without discovery
/// (`DirectToolExecutor.descriptors(discoversFeatureTools: false)`, behind
/// `AgentRuntimeBackend.knownToolDescriptors(sessionID:)` and so behind a
/// sub-agent transcript) never start a feature's tool discovery: no
/// `--list-tools` process, and so no consent it could ask for, even after a
/// reload of the feature bundles cleared the discovered tools.
@Suite
struct DirectToolExecutorKnownDescriptorsTests {
    @Test
    func knownDescriptorsNeverStartAFeatureToolDiscovery() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("known-descriptors-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        // Every `--list-tools` run appends one `x` to the marker.
        let markerURL = rootURL.appendingPathComponent("list-tools-marker")
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(markerURL.path)"
          printf '{"tools":[{"name":"dynamic.discovered","description":"Discovered tool","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"unused"}\\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "dynamic-fixture",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "dynamic.declared",
                            description: "Declared tool",
                            inputSchema: #"{"type":"object","properties":{}}"#
                        )
                    ],
                    toolNamePrefixes: ["dynamic."],
                    discoversToolsAtRuntime: true
                )
            ]
        )
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: runtime,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        func featureToolNames(discoversFeatureTools: Bool) async -> [String] {
            await executor.descriptors(discoversFeatureTools: discoversFeatureTools)
                .map(\.name)
                .filter { $0.hasPrefix("dynamic.") }
                .sorted()
        }
        func listToolsRuns() -> Int {
            (try? String(contentsOf: markerURL, encoding: .utf8))?.count ?? 0
        }

        // Never discovered: only the declared tools are known.
        #expect(await featureToolNames(discoversFeatureTools: false) == ["dynamic.declared"])
        #expect(listToolsRuns() == 0)

        // The default read discovers the feature once.
        #expect(await featureToolNames(discoversFeatureTools: true) == [
            "dynamic.declared",
            "dynamic.discovered",
        ])
        #expect(listToolsRuns() == 1)

        // Discovered: the known tools include the cached discovery.
        #expect(await featureToolNames(discoversFeatureTools: false) == [
            "dynamic.declared",
            "dynamic.discovered",
        ])
        #expect(listToolsRuns() == 1)

        // A reload clears the discovery: the known tools fall back to the
        // declared ones, and still nothing is discovered.
        await runtime.reloadFeatureBundles()
        #expect(await featureToolNames(discoversFeatureTools: false) == ["dynamic.declared"])
        #expect(listToolsRuns() == 1)
    }
}
