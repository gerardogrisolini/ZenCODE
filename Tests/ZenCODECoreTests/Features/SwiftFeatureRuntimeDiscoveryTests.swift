//
//  SwiftFeatureRuntimeTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import FeatureMCPBridgeKit
import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

extension SwiftFeatureRuntimeTests {
    @Test
    func runtimeExecutesFeatureProcess() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-runtime-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"output":"feature-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "fixture",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "feature.fixture.echo",
                            description: "Echo fixture",
                            inputSchema: #"{"type":"object","properties":{}}"#
                        )
                    ]
                )
            ]
        )
        let toolCall = DirectAgentToolCall(
            id: "feature-call-1",
            name: "feature.fixture.echo",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        let output = try await runtime.executeIfAvailable(
            toolCall: toolCall,
            workingDirectory: rootURL
        )

        #expect(output == "feature-output")
    }

    @Test
    func bundledSwiftOutlineReturnsCompactDeclarationMap() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-outline-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        // Optional features are self-contained SwiftPM packages, not products
        // of the root graph. Build the real package in this test's UUID scratch
        // directory, then exercise the exact executable users install.
        let executableURL = try Self.buildOptionalFeatureProduct(
            named: "swift-tools-feature",
            sourceRelativePath: "Sources/Features/SwiftTools",
            scratchPath: rootURL.appendingPathComponent("swift-package-scratch", isDirectory: true)
        )
        let sourceURL = rootURL.appendingPathComponent("Feature.swift")
        try """
        import Foundation

        // MARK: Feature
        struct Feature {
            let title: String

            func render() {}
        }

        extension Feature {
            class func make() -> Feature {
                Feature(title: "demo")
            }
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "swift-tools",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "swift.outline",
                            description: "Returns a compact Swift outline.",
                            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}"#,
                            presentation: .standard(
                                title: "Swift outline",
                                action: "Inspect",
                                kind: .inspect,
                                targetKeyPaths: ["path"],
                                targetFormat: .path
                            )
                        )
                    ]
                )
            ]
        )
        let output = try await runtime.executeIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "swift-outline-call",
                name: "swift.outline",
                argumentsObject: ["path": "Feature.swift"],
                argumentsJSON: #"{"path":"Feature.swift"}"#
            ),
            workingDirectory: rootURL
        )

        let rendered = try #require(output)
        #expect(rendered.contains("File: \(sourceURL.path)"))
        #expect(rendered.contains("read_hint: local.readFile"))
        #expect(rendered.contains("mark\tFeature"))
        #expect(rendered.contains("struct\tFeature"))
        #expect(rendered.contains("let\tFeature.title"))
        #expect(rendered.contains("func\tFeature.render"))
        #expect(rendered.contains("extension\tFeature"))
        #expect(rendered.contains("func\tFeature.make"))
    }

    @Test
    func runtimeDiscoversDynamicFeatureToolsOnlyWhenRelevant() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-dynamic-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let markerURL = rootURL.appendingPathComponent("list-tools-marker")
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(markerURL.path)"
          printf '{"tools":[{"name":"dynamic.echo","description":"Dynamic echo","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"dynamic-output"}\n'
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
                    tools: [],
                    toolNamePrefixes: ["dynamic."],
                    discoversToolsAtRuntime: true
                )
            ]
        )

        // When allowedToolNames is nil, all features are relevant and runtime
        // discovery should occur (consistent with the filtered case).
        let allDescriptors = await runtime.descriptors()
        #expect(allDescriptors.map(\.name) == ["dynamic.echo"])
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        // An unrelated filter must not make the feature relevant — its discovery
        // is skipped entirely. A fresh runtime with a separate marker file is
        // used to avoid any cache interaction and to prove the subprocess was
        // never invoked.
        let unrelatedMarkerURL = rootURL.appendingPathComponent("unrelated-list-tools-marker")
        let unrelatedExecutableURL = rootURL.appendingPathComponent("unrelated-feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(unrelatedMarkerURL.path)"
          printf '{"tools":[{"name":"dynamic.unrelated","description":"Should not run","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"unrelated"}\n'
        """.write(to: unrelatedExecutableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: unrelatedExecutableURL.path
        )
        let unrelatedRuntime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "dynamic-fixture-unrelated",
                    executableURL: unrelatedExecutableURL,
                    tools: [],
                    toolNamePrefixes: ["dynamic."],
                    discoversToolsAtRuntime: true
                )
            ]
        )
        let unrelatedDescriptors = await unrelatedRuntime.descriptors(
            allowedToolNames: ["other."]
        )
        #expect(unrelatedDescriptors.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: unrelatedMarkerURL.path))

        let relatedDescriptors = await runtime.descriptors(
            allowedToolNames: ["dynamic."]
        )
        #expect(relatedDescriptors.map(\.name) == ["dynamic.echo"])

        let output = try await runtime.executeIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "dynamic-call-1",
                name: "dynamic.echo",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: rootURL
        )
        #expect(output == "dynamic-output")
    }

    @Test
    func directMCPRuntimeDoesNotAutodiscoverExternalConnectorsByDefault() async {
        let runtime = DirectMCPToolRuntime()

        let descriptors = await runtime.descriptors(
            allowedToolNames: ["xcode.", "figma."]
        )

        #expect(descriptors.isEmpty)
    }

    @Test
    func uninstalledOptionalFeaturesContributeNoBundlesOrTools() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-empty-root-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        #expect(SwiftFeatureRuntime.defaultFeatureBundles(searchRoots: [rootURL]).isEmpty)
        #expect(SwiftFeatureRuntime.defaultFeatureToolDescriptors(searchRoots: [rootURL]).isEmpty)
    }

    @Test
    func oneShotFailedDiscoveryIsRetriedAndOnlySuccessIsCached() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-retry-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let markerURL = rootURL.appendingPathComponent("list-tools-marker")
        let failURL = rootURL.appendingPathComponent("fail")
        try Data().write(to: failURL)
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        if [ "$1" = "--list-tools" ]; then
          printf x >> "\(markerURL.path)"
          if [ -e "\(failURL.path)" ]; then
            exit 1
          fi
          printf '{"tools":[{"name":"dynamic.echo","description":"Dynamic echo","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
          exit 0
        fi
        cat >/dev/null
        printf '{"ok":true,"output":"dynamic-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "dynamic-retry-fixture",
                    executableURL: executableURL,
                    tools: [],
                    toolNamePrefixes: ["dynamic."],
                    discoversToolsAtRuntime: true
                )
            ]
        )

        // A discovery that exits with a failure status is not cached: the
        // next request runs `--list-tools` again.
        #expect(await runtime.descriptors().isEmpty)
        #expect(try Self.markerCount(at: markerURL) == 1)
        #expect(await runtime.descriptors().isEmpty)
        #expect(try Self.markerCount(at: markerURL) == 2)
        #expect(await runtime.knownDescriptors().isEmpty)

        // The first successful discovery is cached.
        try FileManager.default.removeItem(at: failURL)
        #expect(await runtime.descriptors().map(\.name) == ["dynamic.echo"])
        #expect(try Self.markerCount(at: markerURL) == 3)
        #expect(await runtime.descriptors().map(\.name) == ["dynamic.echo"])
        #expect(try Self.markerCount(at: markerURL) == 3)
        #expect(await runtime.knownDescriptors().map(\.name) == ["dynamic.echo"])
    }

    @Test
    func persistentFailedDiscoveryIsRetriedOnTheNextRequest() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-persistent-retry-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let failURL = rootURL.appendingPathComponent("fail")
        try Data().write(to: failURL)
        let executableURL = rootURL.appendingPathComponent("feature")
        let listResponse = #"{"tools":[{"name":"fixture.echo","description":"Fixture echo","inputSchema":"{}","presentation":{"title":"Echo","action":"Echo","kind":"other","metadata":[],"sections":[]}}]}"#
        try """
        #!/bin/sh
        fail_marker='\(failURL.path)'
        list_response=$(printf '%s' '\(listResponse)' | base64 | tr -d '\\n')
        if [ "$1" = "--serve" ]; then
          while IFS= read -r line; do
            request_id=$(printf '%s' "$line" | sed -n 's/.*"id":"\\([^"\\]*\\)".*/\\1/p')
            case "$line" in
              *'"operation":"listTools"'*)
                if [ -e "$fail_marker" ]; then
                  printf '{"id":"%s","error":"unavailable"}\\n' "$request_id"
                else
                  printf '{"id":"%s","responseData":"%s"}\\n' "$request_id" "$list_response"
                fi
                ;;
              *'"operation":"shutdown"'*)
                printf '{"id":"%s","responseData":""}\\n' "$request_id"
                exit 0
                ;;
            esac
          done
          exit 0
        fi
        exit 1
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "persistent-retry-fixture",
                    executableURL: executableURL,
                    tools: [],
                    toolNamePrefixes: ["fixture."],
                    discoversToolsAtRuntime: true,
                    supportsPersistentSession: true
                )
            ]
        )

        // An error frame is a failed discovery: it is not cached.
        #expect(await runtime.descriptors(allowedToolNames: ["fixture."]).isEmpty)

        try FileManager.default.removeItem(at: failURL)
        #expect(
            await runtime.descriptors(allowedToolNames: ["fixture."]).map(\.name)
                == ["fixture.echo"]
        )
        await runtime.shutdown()
    }

    /// The number of `--list-tools` runs the fixture script recorded: one `x`
    /// per run.
    private static func markerCount(at markerURL: URL) throws -> Int {
        try String(contentsOf: markerURL, encoding: .utf8).count
    }

    /// Builds one self-contained optional feature without using or probing the
    /// root package's build products. The caller owns `scratchPath` and removes
    /// it with its UUID test root.
    static func buildOptionalFeatureProduct(
        named productName: String,
        sourceRelativePath: String,
        scratchPath: URL
    ) throws -> URL {
        let packageRoot = try RepositoryTestSupport.packageRoot(containing: #filePath)
        let featurePackageURL = packageRoot.appendingPathComponent(sourceRelativePath, isDirectory: true)
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = scratchPath
            .appendingPathComponent("support", isDirectory: true)
            .path

        _ = try runFeaturePackageProcess(
            arguments: [
                "swift",
                "build",
                "--scratch-path",
                scratchPath.path,
                "--product",
                productName
            ],
            currentDirectoryURL: featurePackageURL,
            environment: environment
        )
        let binPathData = try runFeaturePackageProcess(
            arguments: [
                "swift",
                "build",
                "--scratch-path",
                scratchPath.path,
                "--show-bin-path"
            ],
            currentDirectoryURL: featurePackageURL,
            environment: environment
        )
        let binPath = String(decoding: binPathData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let executableURL = URL(fileURLWithPath: binPath, isDirectory: true)
            .appendingPathComponent(productName)
            .standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw SwiftFeaturePackageBuildError.missingExecutable(executableURL.path)
        }
        return executableURL
    }

    private static func runFeaturePackageProcess(
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String]
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw SwiftFeaturePackageBuildError.commandFailed(
                arguments: arguments,
                output: String(decoding: outputData, as: UTF8.self)
            )
        }
        return outputData
    }

    private enum SwiftFeaturePackageBuildError: LocalizedError {
        case missingExecutable(String)
        case commandFailed(arguments: [String], output: String)

        var errorDescription: String? {
            switch self {
            case .missingExecutable(let path):
                return "Optional feature build did not produce executable at \(path)."
            case .commandFailed(let arguments, let output):
                return "\(arguments.joined(separator: " ")) failed: \(output)"
            }
        }
    }
}
