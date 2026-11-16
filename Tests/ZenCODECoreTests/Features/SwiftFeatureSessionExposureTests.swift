//
//  SwiftFeatureSessionExposureTests.swift
//  ZenCODE
//
//  The session exposure of the Swift features a Builder sub-agent built, at
//  the level of `SwiftFeatureRuntime`: the registration seam fed by the typed
//  management reports and its conditions (no catalog ID, a manifest under
//  the generated features root, the built executable, a live caller), the
//  "loaded" condition evaluated on read, revocation, deletion, the one-time
//  announcement and its sanitizing, the delegated namespace check, and the
//  invariance of the reads without a session ID or with an empty allowlist.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension SwiftFeatureRuntime {
    /// Registers `featureID` as built by a Builder that `sessionID`
    /// delegated, into `executableURL` or the executable of the bundle loaded
    /// with that ID, without the checks of `recordBuilderOutcome`, which have
    /// tests of their own. For tests of what an exposure grants.
    func exposeForTesting(
        _ featureID: String,
        sessionID: String,
        executableURL: URL? = nil
    ) {
        let executableURL = executableURL
            ?? features.first(where: { $0.id == featureID })?.executableURL
            ?? URL(fileURLWithPath: "/nonexistent/not-loaded/\(featureID)")
        registerBuilderExposure(
            featureID: featureID,
            executableURL: executableURL,
            sessionID: sessionID
        )
    }
}

@Suite
struct SwiftFeatureSessionExposureTests {
    // MARK: - Typed reports

    @Test
    func typedReportsMapToBuilderOutcomes() {
        let manifestURL = URL(fileURLWithPath: "/tmp/fx/zencode-feature.json")
        let built = SwiftFeatureBuilderOutcome.built(
            featureID: "fx",
            manifestURL: manifestURL,
            executableURL: URL(fileURLWithPath: "/tmp/fx/.build/release/fx")
        )
        #expect(SwiftFeatureRuntime.builderOutcome(
            build: Self.buildReport(id: "fx", ok: true),
            manifestURL: manifestURL
        ) == built)
        #expect(SwiftFeatureRuntime.builderOutcome(
            build: Self.buildReport(id: "fx", ok: false),
            manifestURL: manifestURL
        ) == nil)

        #expect(SwiftFeatureRuntime.builderOutcome(scaffold: Self.scaffoldReport(id: "fx", built: true)) == built)
        #expect(SwiftFeatureRuntime.builderOutcome(scaffold: Self.scaffoldReport(id: "fx", built: false)) == nil)
        #expect(SwiftFeatureRuntime.builderOutcome(scaffold: Self.scaffoldReport(id: "fx", built: nil)) == nil)

        #expect(SwiftFeatureRuntime.builderOutcome(install: Self.installReport(id: "fx", ok: true, built: true)) == built)
        #expect(SwiftFeatureRuntime.builderOutcome(install: Self.installReport(id: "fx", ok: true, built: false)) == nil)
        #expect(SwiftFeatureRuntime.builderOutcome(install: Self.installReport(id: "fx", ok: false, built: true)) == nil)

        #expect(SwiftFeatureRuntime.builderOutcome(delete: Self.deleteReport(id: "fx", removed: true))
            == .deleted(featureID: "fx"))
        #expect(SwiftFeatureRuntime.builderOutcome(delete: Self.deleteReport(id: "fx", removed: false)) == nil)
    }

    // MARK: - Registration conditions

    @Test
    func aGeneratedFeatureBuiltUnderTheFeatureRootIsRegisteredWithItsExecutable() async throws {
        let fixture = try RootFixture(featureID: "fx-generated")
        defer { fixture.remove() }

        await fixture.runtime.recordBuilderOutcome(fixture.built(), delegatingSessionID: "session-a")

        #expect(await fixture.runtime.builderBuiltExecutablePathsBySessionID
            == ["session-a": ["fx-generated": fixture.executableURL.standardizedFileURL.path]])
        #expect(await fixture.runtime.exposedFeatureIDs(sessionID: "session-a") == ["fx-generated"])
    }

    @Test
    func aBuildWithoutADelegatingSessionRegistersNothing() async throws {
        let fixture = try RootFixture(featureID: "fx-no-session")
        defer { fixture.remove() }

        await fixture.runtime.recordBuilderOutcome(fixture.built(), delegatingSessionID: nil)
        await fixture.runtime.recordBuilderOutcome(fixture.built(), delegatingSessionID: "  ")
        await fixture.runtime.recordBuilderOutcome(nil, delegatingSessionID: "session-a")

        #expect(await fixture.runtime.builderBuiltExecutablePathsBySessionID.isEmpty)
        #expect(await fixture.runtime.exposedFeatureIDs(sessionID: "session-a").isEmpty)
    }

    /// Bundled and optional catalog IDs, and a local copy that keeps one.
    @Test
    func aCatalogFeatureIDIsNeverRegistered() async throws {
        let catalogIDs = SwiftFeatureRuntime.bundledFeatureDefinitions().map(\.id)
        #expect(!catalogIDs.isEmpty)
        for catalogID in catalogIDs {
            let fixture = try RootFixture(featureID: catalogID)
            defer { fixture.remove() }

            await fixture.runtime.recordBuilderOutcome(fixture.built(), delegatingSessionID: "session-a")

            #expect(await fixture.runtime.builderBuiltExecutablePathsBySessionID.isEmpty, "\(catalogID)")
            #expect(await fixture.runtime.exposedFeatureIDs(sessionID: "session-a").isEmpty, "\(catalogID)")
        }
    }

    @Test
    func aManifestOutsideTheFeatureRootIsNotRegistered() async throws {
        let fixture = try RootFixture(featureID: "fx-outside")
        defer { fixture.remove() }
        let outsideURL = try Self.temporaryDirectory("exposure-outside")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let outsideManifestURL = outsideURL
            .appendingPathComponent("fx-outside", isDirectory: true)
            .appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
        try Self.writeFile(at: outsideManifestURL)
        // A path that only looks like it is under the root.
        let escapingManifestURL = fixture.rootURL
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent(outsideURL.lastPathComponent, isDirectory: true)
            .appendingPathComponent("fx-outside", isDirectory: true)
            .appendingPathComponent(SwiftFeatureRegistry.manifestFilename)

        for manifestURL in [outsideManifestURL, escapingManifestURL] {
            await fixture.runtime.recordBuilderOutcome(
                fixture.built(manifestURL: manifestURL),
                delegatingSessionID: "session-a"
            )
        }

        #expect(await fixture.runtime.builderBuiltExecutablePathsBySessionID.isEmpty)
        #expect(await fixture.runtime.exposedFeatureIDs(sessionID: "session-a").isEmpty)
    }

    @Test
    func aLoadedBundleWithAnotherExecutableOrABundledSourceIsNotExposed() async throws {
        let otherExecutable = try RootFixture(
            featureID: "fx-swapped",
            loadedExecutableName: "other-executable"
        )
        defer { otherExecutable.remove() }
        await otherExecutable.runtime.recordBuilderOutcome(
            otherExecutable.built(),
            delegatingSessionID: "session-a"
        )
        // Registered, since the build was legitimate, but the loaded bundle
        // runs another executable.
        #expect(!(await otherExecutable.runtime.builderBuiltExecutablePathsBySessionID.isEmpty))
        #expect(await otherExecutable.runtime.exposedFeatureIDs(sessionID: "session-a").isEmpty)
        #expect(await otherExecutable.runtime.exposures(sessionID: "session-a").isEmpty)
        #expect(!(await otherExecutable.runtime.featureToolIsAllowed(
            toolName: "fx-swapped.run",
            allowedToolNames: ["local.readFile"],
            sessionID: "session-a"
        )))

        let bundledSource = try RootFixture(featureID: "fx-bundled-source", source: .bundled)
        defer { bundledSource.remove() }
        await bundledSource.runtime.recordBuilderOutcome(
            bundledSource.built(),
            delegatingSessionID: "session-a"
        )
        #expect(await bundledSource.runtime.exposedFeatureIDs(sessionID: "session-a").isEmpty)
    }

    @Test
    func aCancelledCallerRegistersNothing() async throws {
        let fixture = try RootFixture(featureID: "fx-cancelled")
        defer { fixture.remove() }
        let runtime = fixture.runtime
        let outcome = fixture.built()

        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await runtime.recordBuilderOutcome(outcome, delegatingSessionID: "session-a")
        }.value

        #expect(await runtime.builderBuiltExecutablePathsBySessionID.isEmpty)
    }

    // MARK: - Fixtures

    /// A generated features root holding the manifest of `featureID`, and a
    /// runtime whose loaded bundle with that ID runs `executableURL` (or
    /// another executable when `loadedExecutableName` is given).
    struct RootFixture {
        let featureID: String
        let rootURL: URL
        let manifestURL: URL
        let executableURL: URL
        let runtime: SwiftFeatureRuntime

        init(
            featureID: String,
            source: SwiftFeatureBundleSource = .generated,
            loadedExecutableName: String? = nil
        ) throws {
            self.featureID = featureID
            rootURL = try SwiftFeatureSessionExposureTests.temporaryDirectory("exposure-root")
            let packageURL = rootURL.appendingPathComponent(featureID, isDirectory: true)
            manifestURL = packageURL.appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
            executableURL = packageURL
                .appendingPathComponent(".build/release", isDirectory: true)
                .appendingPathComponent(featureID)
            try SwiftFeatureSessionExposureTests.writeFile(at: manifestURL)
            let loadedExecutableURL = loadedExecutableName.map {
                packageURL.appendingPathComponent($0)
            } ?? executableURL
            runtime = SwiftFeatureRuntime(
                features: [
                    SwiftFeatureBundle(
                        id: featureID,
                        executableURL: loadedExecutableURL,
                        tools: [
                            ToolDescriptor(
                                name: "\(featureID).run",
                                description: "Fixture tool",
                                inputSchema: #"{"type":"object","properties":{}}"#
                            ),
                        ],
                        source: source
                    ),
                ],
                featureSearchRoots: [rootURL]
            )
        }

        func built(manifestURL: URL? = nil) -> SwiftFeatureBuilderOutcome {
            .built(
                featureID: featureID,
                manifestURL: manifestURL ?? self.manifestURL,
                executableURL: executableURL
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }
    }

    static func bundle(
        id: String,
        tools: [String],
        prefixes: [String] = [],
        aliases: [String] = []
    ) -> SwiftFeatureBundle {
        SwiftFeatureBundle(
            id: id,
            executableURL: URL(fileURLWithPath: "/nonexistent/\(id)-\(UUID().uuidString)"),
            tools: tools.map {
                ToolDescriptor(
                    name: $0,
                    description: "Fixture tool \($0)",
                    inputSchema: #"{"type":"object","properties":{}}"#
                )
            },
            toolNamePrefixes: prefixes,
            toolNameAliases: aliases
        )
    }

    static func names(_ descriptors: [DirectToolDescriptor]) -> [String] {
        descriptors.map(\.name).sorted()
    }

    /// Scaffolds `id` under `featuresURL` as the operator would, gives it an
    /// executable, and enables it, so `runtime` loads it; returns its record.
    static func loadedScaffold(
        _ id: String,
        toolName: String,
        in runtime: SwiftFeatureRuntime,
        featuresURL: URL
    ) async throws -> SwiftFeatureRecord {
        _ = try await runtime.executeManagementTool(
            toolCall: managementCall("feature.scaffold", ["id": id, "toolName": toolName])
        )
        let record = try #require(SwiftFeatureRegistry.featureRecord(
            id: id,
            searchRoots: [featuresURL],
            fileManager: .default
        ))
        try writeExecutable(at: record.executableURL)
        _ = try await runtime.executeManagementTool(
            toolCall: managementCall("feature.enable", ["id": id])
        )
        #expect(await runtime.features.contains { $0.id == id })
        return record
    }

    /// Rewrites the manifest at `url` with `change`, as a Builder with the
    /// file tools could after a build.
    static func rewriteManifest(
        at url: URL,
        _ change: (inout [String: Any]) -> Void
    ) throws {
        var manifest = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        change(&manifest)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeFile(at url: URL, contents: String = "{}") throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"output":"exposure-fixture-output"}\\n'
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func managementCall(_ name: String, _ arguments: [String: String]) -> DirectAgentToolCall {
        let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return DirectAgentToolCall(
            id: "\(name)-\(UUID().uuidString)",
            name: name,
            argumentsObject: arguments,
            argumentsJSON: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        )
    }

    private static func buildReport(id: String, ok: Bool) -> SwiftFeatureBuildReport {
        SwiftFeatureBuildReport(
            ok: ok,
            id: id,
            command: ["swift", "build"],
            workingDirectory: "/tmp/\(id)",
            executablePath: "/tmp/\(id)/.build/release/\(id)",
            exitCode: ok ? 0 : 1,
            timedOut: false,
            stdout: "",
            stderr: ""
        )
    }

    private static func scaffoldReport(id: String, built: Bool?) -> SwiftFeatureScaffoldReport {
        SwiftFeatureScaffoldReport(
            id: id,
            directoryPath: "/tmp/\(id)",
            manifestPath: "/tmp/\(id)/zencode-feature.json",
            packagePath: "/tmp/\(id)/Package.swift",
            sourcePath: "/tmp/\(id)/Sources/main.swift",
            toolName: "\(id).echo",
            built: built,
            build: built.map { buildReport(id: id, ok: $0) }
        )
    }

    private static func installReport(id: String, ok: Bool, built: Bool) -> SwiftFeatureInstallReport {
        SwiftFeatureInstallReport(
            ok: ok,
            id: id,
            sourcePath: "/tmp/source/\(id)",
            destinationPath: "/tmp/\(id)",
            manifestPath: "/tmp/\(id)/zencode-feature.json",
            copied: true,
            built: built,
            enabled: ok,
            validation: SwiftFeatureValidationReport(
                id: id,
                manifestPath: "/tmp/\(id)/zencode-feature.json",
                executablePath: nil,
                errors: [],
                warnings: [],
                tools: []
            ),
            build: buildReport(id: id, ok: built)
        )
    }

    private static func deleteReport(id: String, removed: Bool) -> SwiftFeatureDeleteReport {
        SwiftFeatureDeleteReport(
            ok: removed,
            id: id,
            directoryPath: "/tmp/\(id)",
            manifestPath: "/tmp/\(id)/zencode-feature.json",
            removed: removed,
            wasEnabled: false
        )
    }
}
