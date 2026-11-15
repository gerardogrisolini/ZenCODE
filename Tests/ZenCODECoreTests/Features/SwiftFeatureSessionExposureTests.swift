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

    // MARK: - Reads

    @Test
    func aSuccessfulBuildIsExposedOnlyToTheDelegatingSession() async {
        let runtime = SwiftFeatureRuntime(features: [
            Self.bundle(id: "fx", tools: ["fx.run"], prefixes: ["fx."]),
            Self.bundle(id: "other", tools: ["other.run"]),
        ])

        await runtime.exposeForTesting("fx", sessionID: "session-a")

        #expect(await runtime.exposedFeatureIDs(sessionID: "session-a") == ["fx"])
        #expect(await runtime.exposedFeatureIDs(sessionID: "session-b").isEmpty)
        #expect(await runtime.exposedFeatureIDs(sessionID: nil).isEmpty)
        #expect(await runtime.exposures(sessionID: "session-a") == [
            SwiftFeatureSessionExposure(featureID: "fx", toolNames: ["fx.run"], toolNamePrefixes: ["fx."])
        ])

        let allowlist: Set<String> = ["local.readFile"]
        #expect(await Self.names(runtime.descriptors(allowedToolNames: allowlist, sessionID: "session-a"))
            == ["fx.run"])
        #expect(runtimeKnownNames(await runtime.knownDescriptors(allowedToolNames: allowlist, sessionID: "session-a"))
            == ["fx.run"])
        #expect(await Self.names(runtime.descriptors(allowedToolNames: allowlist, sessionID: "session-b")).isEmpty)
        #expect(await runtime.featureToolIsAllowed(toolName: "fx.run", allowedToolNames: allowlist, sessionID: "session-a"))
        #expect(await runtime.featureToolIsAllowed(toolName: "fx.dynamic", allowedToolNames: allowlist, sessionID: "session-a"))
        #expect(!(await runtime.featureToolIsAllowed(toolName: "fx.run", allowedToolNames: allowlist, sessionID: "session-b")))
        #expect(!(await runtime.featureToolIsAllowed(toolName: "fx.run", allowedToolNames: allowlist)))
        #expect(!(await runtime.featureToolIsAllowed(toolName: "other.run", allowedToolNames: allowlist, sessionID: "session-a")))
        // The relevance alone: the exposure is not part of it.
        #expect(await runtime.featureIDs(relevantTo: allowlist).isEmpty)
    }

    @Test
    func withoutASessionOrWithANilAllowlistTheReadsAreUnchanged() async {
        let runtime = SwiftFeatureRuntime(features: [
            Self.bundle(id: "fx", tools: ["fx.run"]),
            Self.bundle(id: "other", tools: ["other.run"]),
        ])
        let allowlists: [Set<String>?] = [nil, [], ["other.run"], ["local.readFile"]]
        var baseline: [[String]] = []
        for allowlist in allowlists {
            baseline.append(await Self.names(runtime.descriptors(allowedToolNames: allowlist)))
        }

        await runtime.exposeForTesting("fx", sessionID: "session-a")

        for (allowlist, expected) in zip(allowlists, baseline) {
            #expect(await Self.names(runtime.descriptors(allowedToolNames: allowlist)) == expected)
            #expect(runtimeKnownNames(await runtime.knownDescriptors(allowedToolNames: allowlist)) == expected)
            #expect(await Self.names(runtime.descriptors(allowedToolNames: allowlist, sessionID: nil)) == expected)
            #expect(await runtime.featureToolIsAllowed(toolName: "fx.run", allowedToolNames: allowlist)
                == (allowlist == nil))
        }
        // A nil allowlist already lists every feature: the exposure adds nothing.
        #expect(await Self.names(runtime.descriptors(allowedToolNames: nil, sessionID: "session-a"))
            == baseline[0])
    }

    /// An empty allowlist grants nothing, the exposure included, as
    /// `DirectToolExecutor.descriptors` returns no descriptor for it.
    @Test
    func anEmptyAllowlistGrantsNothingThroughTheExposure() async {
        let runtime = SwiftFeatureRuntime(features: [
            Self.bundle(id: "fx", tools: ["fx.run"], prefixes: ["fx."]),
        ])
        await runtime.exposeForTesting("fx", sessionID: "session-a")

        #expect(!(await runtime.featureToolIsAllowed(toolName: "fx.run", allowedToolNames: [], sessionID: "session-a")))
        #expect(await Self.names(runtime.descriptors(allowedToolNames: [], sessionID: "session-a")).isEmpty)
        #expect(runtimeKnownNames(await runtime.knownDescriptors(allowedToolNames: [], sessionID: "session-a")).isEmpty)
        // A restricted, non-empty allowlist still receives it.
        #expect(await runtime.featureToolIsAllowed(toolName: "fx.run", allowedToolNames: ["x.y"], sessionID: "session-a"))
    }

    @Test
    func anExposureNeverGrantsKernelOrCoreCatalogNames() async {
        let runtime = SwiftFeatureRuntime(features: [
            Self.bundle(
                id: "hostile",
                tools: ["hostile.run", "local.writeFile", "feature.list"],
                prefixes: ["hostile.", "local.", "feature.", "agent."]
            )
        ])

        await runtime.exposeForTesting("hostile", sessionID: "session-a")

        #expect(await runtime.exposures(sessionID: "session-a") == [
            SwiftFeatureSessionExposure(featureID: "hostile", toolNames: ["hostile.run"], toolNamePrefixes: ["hostile."])
        ])
        let names = await Self.names(
            runtime.descriptors(allowedToolNames: ["skills.list"], sessionID: "session-a")
        )
        #expect(names == ["hostile.run"])
        #expect(!(await runtime.featureToolIsAllowed(
            toolName: "local.writeFile",
            allowedToolNames: ["skills.list"],
            sessionID: "session-a"
        )))
        #expect(!(await runtime.featureToolIsAllowed(
            toolName: "feature.list",
            allowedToolNames: ["skills.list"],
            sessionID: "session-a"
        )))
    }

    /// The exposure lists only names the feature executes: a feature loaded
    /// earlier answers for `shared.*`, so neither `shared.run` nor `shared.`
    /// is announced as the exposed feature's.
    @Test
    func exposuresListOnlyTheNamesTheFeatureOwns() async {
        let runtime = SwiftFeatureRuntime(features: [
            Self.bundle(id: "earlier", tools: [], prefixes: ["shared."]),
            Self.bundle(id: "exposed", tools: ["shared.run", "exposed.run"], prefixes: ["shared.", "exposed."]),
        ])
        await runtime.exposeForTesting("exposed", sessionID: "session-a")

        #expect(await runtime.exposures(sessionID: "session-a") == [
            SwiftFeatureSessionExposure(featureID: "exposed", toolNames: ["exposed.run"], toolNamePrefixes: ["exposed."])
        ])
        // Consistent with what the session can list and call.
        #expect(await Self.names(runtime.descriptors(allowedToolNames: ["local.readFile"], sessionID: "session-a"))
            == ["exposed.run"])
    }

    // MARK: - Loaded condition

    @Test
    func aBuiltFeatureIsExposedOnlyWhileLoadedAndOnceEnabledWithoutRebuilding() async throws {
        let rootURL = try Self.temporaryDirectory("exposure-loaded")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await AppStorageDirectory.withSupportDirectoryURL(rootURL.appendingPathComponent("support")) {
            let featuresURL = rootURL.appendingPathComponent("features", isDirectory: true)
            let runtime = SwiftFeatureRuntime(featureSearchRoots: [featuresURL])
            _ = try await runtime.executeManagementTool(
                toolCall: Self.managementCall(
                    "feature.scaffold",
                    ["id": "exposure-fixture", "toolName": "exposure.echo"]
                )
            )
            let record = try #require(SwiftFeatureRegistry.featureRecord(
                id: "exposure-fixture",
                searchRoots: [featuresURL],
                fileManager: .default
            ))
            let manifestURL = try #require(record.manifestURL)
            try Self.writeExecutable(at: record.executableURL)

            // Built, but the scaffold manifest is disabled: not loaded, not exposed.
            await runtime.recordBuilderOutcome(
                .built(
                    featureID: "exposure-fixture",
                    manifestURL: manifestURL,
                    executableURL: record.executableURL
                ),
                delegatingSessionID: "session-a"
            )
            #expect(!(await runtime.builderBuiltExecutablePathsBySessionID.isEmpty))
            #expect(await runtime.exposedFeatureIDs(sessionID: "session-a").isEmpty)
            #expect(await runtime.takeUnannouncedExposures(sessionID: "session-a").isEmpty)

            // Enabling it loads it: exposed with no further build.
            _ = try await runtime.executeManagementTool(
                toolCall: Self.managementCall("feature.enable", ["id": "exposure-fixture"])
            )
            #expect(await runtime.exposedFeatureIDs(sessionID: "session-a") == ["exposure-fixture"])
            #expect(await Self.names(runtime.descriptors(
                allowedToolNames: ["local.readFile"],
                sessionID: "session-a"
            )) == ["exposure.echo"])

            // Disabled again: not exposed.
            _ = try await runtime.executeManagementTool(
                toolCall: Self.managementCall("feature.disable", ["id": "exposure-fixture"])
            )
            #expect(await runtime.exposedFeatureIDs(sessionID: "session-a").isEmpty)

            // Enabled without an executable: still not loaded, not exposed.
            try FileManager.default.removeItem(at: record.executableURL)
            _ = try await runtime.executeManagementTool(
                toolCall: Self.managementCall("feature.enable", ["id": "exposure-fixture"])
            )
            #expect(await runtime.exposedFeatureIDs(sessionID: "session-a").isEmpty)

            // The executable is back: exposed after the next reload.
            try Self.writeExecutable(at: record.executableURL)
            await runtime.reloadFeatureBundles()
            #expect(await runtime.exposedFeatureIDs(sessionID: "session-a") == ["exposure-fixture"])
        }
    }

    @Test
    func featureDeleteRemovesTheFeatureFromEverySession() async throws {
        let rootURL = try Self.temporaryDirectory("exposure-delete")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await AppStorageDirectory.withSupportDirectoryURL(rootURL.appendingPathComponent("support")) {
            let featuresURL = rootURL.appendingPathComponent("features", isDirectory: true)
            let runtime = SwiftFeatureRuntime(featureSearchRoots: [featuresURL])
            _ = try await runtime.executeManagementTool(
                toolCall: Self.managementCall(
                    "feature.scaffold",
                    ["id": "doomed-fixture", "toolName": "doomed.echo"]
                )
            )
            let keptURL = URL(fileURLWithPath: "/nonexistent/kept")
            await runtime.exposeForTesting("doomed-fixture", sessionID: "session-a")
            await runtime.exposeForTesting("doomed-fixture", sessionID: "session-b")
            await runtime.exposeForTesting("kept", sessionID: "session-b", executableURL: keptURL)

            // Deleted by a caller without any delegating session.
            _ = try await runtime.executeManagementTool(
                toolCall: Self.managementCall("feature.delete", ["id": "doomed-fixture"])
            )

            #expect(await runtime.builderBuiltExecutablePathsBySessionID
                == ["session-b": ["kept": keptURL.path]])
        }
    }

    // MARK: - Revocation and announcement

    @Test
    func revocationRemovesAllOrASubsetAndReannouncesARebuild() async {
        let runtime = SwiftFeatureRuntime(features: [
            Self.bundle(id: "fx", tools: ["fx.run"]),
            Self.bundle(id: "gx", tools: [], prefixes: ["gx."]),
        ])
        await runtime.exposeForTesting("fx", sessionID: "session-a")
        await runtime.exposeForTesting("gx", sessionID: "session-a")
        await runtime.exposeForTesting("fx", sessionID: "session-b")
        _ = await runtime.takeUnannouncedExposures(sessionID: "session-a")

        await runtime.revokeExposures(sessionID: "session-a", featureIDs: ["fx"])
        #expect(await runtime.exposedFeatureIDs(sessionID: "session-a") == ["gx"])
        #expect(await runtime.exposedFeatureIDs(sessionID: "session-b") == ["fx"])

        // Built again after the revocation: exposed and announced again.
        await runtime.exposeForTesting("fx", sessionID: "session-a")
        #expect(await runtime.takeUnannouncedExposures(sessionID: "session-a").map(\.featureID) == ["fx"])

        await runtime.revokeExposures(sessionID: "session-a")
        #expect(await runtime.exposedFeatureIDs(sessionID: "session-a").isEmpty)
        #expect(await runtime.exposedFeatureIDs(sessionID: "session-b") == ["fx"])
        #expect(await runtime.announcedExposedFeatureIDsBySessionID["session-a"] == nil)
    }

    @Test
    func unannouncedExposuresAreTakenOnceAndRenderTheAnnouncement() async {
        let runtime = SwiftFeatureRuntime(features: [
            Self.bundle(id: "fx", tools: ["fx.run", "fx.list"]),
            Self.bundle(id: "gx", tools: [], prefixes: ["gx."]),
        ])
        await runtime.exposeForTesting("fx", sessionID: "session-a")

        let first = await runtime.takeUnannouncedExposures(sessionID: "session-a")
        #expect(SwiftFeatureRuntime.featureExposureAnnouncement(for: first)
            == "Feature tools now available in this session, built by your Builder sub-agent: "
            + "fx (fx.list, fx.run). Call them directly.")
        #expect(await runtime.takeUnannouncedExposures(sessionID: "session-a").isEmpty)

        await runtime.exposeForTesting("gx", sessionID: "session-a")
        let second = await runtime.takeUnannouncedExposures(sessionID: "session-a")
        #expect(SwiftFeatureRuntime.featureExposureAnnouncement(for: second)
            == "Feature tools now available in this session, built by your Builder sub-agent: "
            + "gx (tools with prefix `gx.`). Call them directly.")
        #expect(SwiftFeatureRuntime.featureExposureAnnouncement(for: []) == nil)
        #expect(await runtime.takeUnannouncedExposures(sessionID: nil).isEmpty)
    }

    @Test
    func theAnnouncementQuotesOnlyCleanNamesAndAtMostTwentyPerFeature() throws {
        let clean = (1...24).map { String(format: "many.tool%02d", $0) }
        let unclean = [
            "many.with space",
            "many.`injected`",
            "many.line\nbreak",
            "many." + String(repeating: "x", count: 60),
            "many.é",
            "",
        ]
        let announcement = try #require(SwiftFeatureRuntime.featureExposureAnnouncement(for: [
            SwiftFeatureSessionExposure(
                featureID: "many",
                toolNames: clean + unclean,
                toolNamePrefixes: ["many.", "bad prefix."]
            ),
            SwiftFeatureSessionExposure(
                featureID: "few",
                toolNames: ["few.run", "few.`x`"],
                toolNamePrefixes: []
            ),
            // An ID the filter rejects: the feature is not named at all.
            SwiftFeatureSessionExposure(
                featureID: "hidden`id",
                toolNames: ["hidden.run"],
                toolNamePrefixes: ["hidden."]
            ),
            SwiftFeatureSessionExposure(
                featureID: String(repeating: "h", count: 65),
                toolNames: ["hidden.long"],
                toolNamePrefixes: []
            ),
        ]))

        let listed = clean.prefix(20).joined(separator: ", ")
        #expect(announcement == "Feature tools now available in this session, built by your Builder sub-agent: "
            + "many (\(listed), and 5 more); few (few.run). Call them directly.")
        for name in unclean where !name.isEmpty {
            #expect(!announcement.contains(name))
        }
        #expect(!announcement.contains("bad prefix"))
        #expect(!announcement.contains("hidden"))
        #expect(!announcement.contains(String(repeating: "h", count: 65)))
        // Only features with a rejected ID: nothing to announce.
        #expect(SwiftFeatureRuntime.featureExposureAnnouncement(for: [
            SwiftFeatureSessionExposure(featureID: "hidden id", toolNames: ["hidden.run"], toolNamePrefixes: []),
        ]) == nil)
        #expect(SwiftFeatureRuntime.isAnnounceableName(String(repeating: "a", count: 64)))
        #expect(!SwiftFeatureRuntime.isAnnounceableName(String(repeating: "a", count: 65)))
    }

    // MARK: - Delegated namespace

    @Test
    func aDelegatedFeatureMayNotTakeACoreNamespace() async throws {
        let runtime = SwiftFeatureRuntime(features: [])
        let refused: [(tools: [String], aliases: [String], prefixes: [String], entry: String)] = [
            (["local.readFile"], [], [], "its tool 'local.readFile'"),
            (["tasks.exportCSV"], [], [], "its tool 'tasks.exportCSV' falls in the namespace 'tasks.' of the core tools"),
            (["memoryless", "memory.export"], [], [], "its tool 'memory.export' falls in the namespace 'memory.'"),
            (["memory"], [], [], "the namespace 'memory.' of its tool 'memory'"),
            (["fine.run"], ["agent.create"], [], "its alias 'agent.create'"),
            (["fine.run"], [], ["todo."], "its tool prefix 'todo.'"),
            (["fine.run"], [], ["tas"], "its tool prefix 'tas'"),
            (["fine.run"], [], ["feature.x."], "its tool prefix 'feature.x.'"),
            // A name under a core namespace, which a session allowing the core
            // tool would find relevant through the derived prefix.
            (["local.readFile.pdf"], [], [], "its tool 'local.readFile.pdf' falls in the namespace 'local.' of the core tools"),
            (["skills.list.x"], [], [], "its tool 'skills.list.x' falls in the namespace 'skills.' of the core tools"),
            (["fine.run"], ["skills.list.x"], [], "its alias 'skills.list.x' falls in the namespace 'skills.'"),
            (["fine.run"], [], ["local.readFile."], "its tool prefix 'local.readFile.' falls in the namespace 'local.'"),
        ]
        for refusal in refused {
            let error = try await #require(throws: DirectToolError.self) {
                try await runtime.ensureDelegatedFeatureNamespace(
                    featureID: "intruder",
                    toolNames: refusal.tools,
                    toolNameAliases: refusal.aliases,
                    toolNamePrefixes: refusal.prefixes
                )
            }
            let message = error.localizedDescription
            #expect(message.contains("Feature 'intruder' cannot be built by a delegated Builder"), "\(message)")
            #expect(message.contains(refusal.entry), "\(message)")
            #expect(message.contains("core") || message.contains("kernel feature management"), "\(message)")
            #expect(message.contains("Give the feature a namespace of its own."), "\(message)")
        }

        try await runtime.ensureDelegatedFeatureNamespace(
            featureID: "changelog",
            toolNames: ["changelog.build"],
            toolNameAliases: ["changelog_build"],
            toolNamePrefixes: ["changelog."]
        )
        // A name that only starts like a core namespace is its own.
        try await runtime.ensureDelegatedFeatureNamespace(
            featureID: "localizer",
            toolNames: ["localizer.run", "skillset.list"],
            toolNameAliases: [],
            toolNamePrefixes: ["localizer."]
        )

        // The namespaces come from the core catalog, up to the first dot.
        for namespace in ["local.", "skills.", "tasks.", "memory.", "agent.", "feature."] {
            #expect(SwiftFeatureRuntime.coreToolNamespaces.contains(namespace), "\(namespace)")
        }
        for namespace in SwiftFeatureRuntime.coreToolNamespaces {
            #expect(namespace.hasSuffix(".") && namespace.dropLast().allSatisfy { $0 != "." }, "\(namespace)")
        }
        for toolName in SwiftFeatureRuntime.exposureReservedToolNames {
            #expect(SwiftFeatureRuntime.coreToolNamespaces.contains { toolName.hasPrefix($0) }, "\(toolName)")
        }
    }

    @Test
    func aDelegatedFeatureMayNotTakeANameOfAnotherLoadedFeature() async throws {
        let runtime = SwiftFeatureRuntime(features: [
            Self.bundle(id: "owner", tools: ["owned.run"], prefixes: ["owned."], aliases: ["ownedalias"]),
            // Tools and an alias without a covering prefix.
            Self.bundle(id: "plain", tools: ["foo.bar"], aliases: ["fooalias"]),
        ])
        let refused: [(tools: [String], aliases: [String], prefixes: [String], fragment: String, owner: String)] = [
            (["owned.run"], [], [], "its tool 'owned.run' is also the tool 'owned.run'", "owner"),
            (["owned.extra"], [], [], "its tool 'owned.extra' falls under the tool prefix 'owned.'", "owner"),
            (["mine.run"], ["ownedalias"], [], "its alias 'ownedalias' is also the alias 'ownedalias'", "owner"),
            (["mine.run"], [], ["own"], "its tool prefix 'own' covers the tool 'owned.run'", "owner"),
            (["mine.run"], [], ["owned.sub."], "its tool prefix 'owned.sub.' falls under the tool prefix 'owned.'", "owner"),
            // A prefix that extends a tool or an alias, which a session
            // allowing that name would find relevant.
            (["mine.run"], [], ["foo.bar."], "its tool prefix 'foo.bar.' extends the tool 'foo.bar'", "plain"),
            (["mine.run"], [], ["fooalias."], "its tool prefix 'fooalias.' extends the alias 'fooalias'", "plain"),
            (["foo.bar.pdf"], [], [], "the namespace 'foo.bar.' of its tool 'foo.bar.pdf' extends the tool 'foo.bar'", "plain"),
        ]
        for refusal in refused {
            let error = try await #require(throws: DirectToolError.self) {
                try await runtime.ensureDelegatedFeatureNamespace(
                    featureID: "intruder",
                    toolNames: refusal.tools,
                    toolNameAliases: refusal.aliases,
                    toolNamePrefixes: refusal.prefixes
                )
            }
            let message = error.localizedDescription
            #expect(message.contains(refusal.fragment), "\(message)")
            #expect(message.contains("of the loaded feature '\(refusal.owner)'"), "\(message)")
            #expect(message.contains("Give the feature a namespace of its own."), "\(message)")
        }

        // The feature itself (a rebuild) and a namespace of its own pass.
        try await runtime.ensureDelegatedFeatureNamespace(
            featureID: "owner",
            toolNames: ["owned.run", "owned.extra"],
            toolNameAliases: ["ownedalias"],
            toolNamePrefixes: ["owned."]
        )
        try await runtime.ensureDelegatedFeatureNamespace(
            featureID: "intruder",
            toolNames: ["mine.run"],
            toolNameAliases: [],
            toolNamePrefixes: ["mine."]
        )
    }

    // MARK: - Routing changed after the build

    /// A registered feature whose manifest is rewritten after the build to
    /// take a core namespace loses its exposure on the next reload, whoever
    /// reloads, is not announced, and is not exposed again when the routing
    /// is restored without a new delegated build.
    @Test
    func aReloadRevokesTheExposureOfAFeatureWhoseRoutingTakesANamespaceItDoesNotOwn() async throws {
        let rootURL = try Self.temporaryDirectory("exposure-rerouted")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await AppStorageDirectory.withSupportDirectoryURL(rootURL.appendingPathComponent("support")) {
            let featuresURL = rootURL.appendingPathComponent("features", isDirectory: true)
            let runtime = SwiftFeatureRuntime(featureSearchRoots: [featuresURL])
            let kept = try await Self.loadedScaffold("kept-fixture", toolName: "kept.run", in: runtime, featuresURL: featuresURL)
            let rerouted = try await Self.loadedScaffold("rerouted-fixture", toolName: "rerouted.run", in: runtime, featuresURL: featuresURL)
            for record in [kept, rerouted] {
                for sessionID in ["session-a", "session-b"] {
                    await runtime.recordBuilderOutcome(
                        .built(
                            featureID: record.id,
                            manifestURL: try #require(record.manifestURL),
                            executableURL: record.executableURL
                        ),
                        delegatingSessionID: sessionID
                    )
                }
            }
            // Announced in session-a only.
            #expect(await runtime.takeUnannouncedExposures(sessionID: "session-a").count == 2)
            #expect(await runtime.exposedFeatureIDs(sessionID: "session-b") == ["kept-fixture", "rerouted-fixture"])

            let manifestURL = try #require(rerouted.manifestURL)
            let original = try String(contentsOf: manifestURL, encoding: .utf8)
            try Self.rewriteManifest(at: manifestURL) { manifest in
                manifest["toolNamePrefixes"] = ["local.readFile."]
            }
            // An unrelated reload, by a caller without any delegating session.
            _ = try await runtime.executeManagementTool(toolCall: Self.managementCall("feature.reload", [:]))

            // Still loaded, with the new routing, but no longer exposed.
            #expect(await runtime.features.first { $0.id == "rerouted-fixture" }?.toolNamePrefixes
                == ["local.readFile."])
            for sessionID in ["session-a", "session-b"] {
                #expect(await runtime.exposedFeatureIDs(sessionID: sessionID) == ["kept-fixture"])
                #expect(await runtime.builderBuiltExecutablePathsBySessionID[sessionID]?.keys.sorted()
                    == ["kept-fixture"])
                #expect(await Self.names(runtime.descriptors(
                    allowedToolNames: ["agent.message"],
                    sessionID: sessionID
                )) == ["kept.run"])
            }
            #expect(await runtime.announcedExposedFeatureIDsBySessionID["session-a"] == ["kept-fixture"])
            #expect(await runtime.announcedExposedFeatureIDsBySessionID["session-b"] == nil)
            let announced = await runtime.takeUnannouncedExposures(sessionID: "session-b")
            #expect(announced.map(\.featureID) == ["kept-fixture"])

            // The routing restored: not exposed again without a new build.
            try original.write(to: manifestURL, atomically: true, encoding: .utf8)
            await runtime.reloadFeatureBundles()
            #expect(await runtime.exposedFeatureIDs(sessionID: "session-a") == ["kept-fixture"])
        }
    }

    /// A rewrite that takes a name of another loaded feature is revoked the
    /// same way; a feature that is not loaded keeps its registration until it
    /// is loaded.
    @Test
    func aReloadRevokesAnExposureWhoseRoutingTakesANameOfAnotherLoadedFeature() async throws {
        let rootURL = try Self.temporaryDirectory("exposure-rerouted-feature")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await AppStorageDirectory.withSupportDirectoryURL(rootURL.appendingPathComponent("support")) {
            let featuresURL = rootURL.appendingPathComponent("features", isDirectory: true)
            let runtime = SwiftFeatureRuntime(featureSearchRoots: [featuresURL])
            _ = try await Self.loadedScaffold("owner-fixture", toolName: "owned.run", in: runtime, featuresURL: featuresURL)
            let built = try await Self.loadedScaffold("built-fixture", toolName: "built.run", in: runtime, featuresURL: featuresURL)
            let manifestURL = try #require(built.manifestURL)
            await runtime.recordBuilderOutcome(
                .built(featureID: built.id, manifestURL: manifestURL, executableURL: built.executableURL),
                delegatingSessionID: "session-a"
            )

            // Disabled and rewritten: not loaded, so still registered.
            _ = try await runtime.executeManagementTool(
                toolCall: Self.managementCall("feature.disable", ["id": built.id])
            )
            try Self.rewriteManifest(at: manifestURL) { manifest in
                manifest["toolNamePrefixes"] = ["built.", "owned.run."]
            }
            await runtime.reloadFeatureBundles()
            #expect(await runtime.builderBuiltExecutablePathsBySessionID["session-a"]?.keys.sorted()
                == ["built-fixture"])

            // Enabled again by the operator: loaded with the new routing, revoked.
            _ = try await runtime.executeManagementTool(
                toolCall: Self.managementCall("feature.enable", ["id": built.id])
            )
            #expect(await runtime.features.contains { $0.id == built.id })
            #expect(await runtime.exposedFeatureIDs(sessionID: "session-a").isEmpty)
            #expect(await runtime.builderBuiltExecutablePathsBySessionID.isEmpty)
            #expect(await runtime.takeUnannouncedExposures(sessionID: "session-a").isEmpty)
        }
    }

    // MARK: - Catalog marking in feature.list

    /// The criterion step 1 of the delegated Builder's prompt gives: in the
    /// `feature.list` output a catalog feature has `source` `bundled` or,
    /// once installed, an `adoptedFrom` value, which the manifest the runtime
    /// writes for an installed optional feature or a local copy carries; a
    /// scaffolded feature has `source` `generated` and no `adoptedFrom`.
    @Test
    func featureListMarksACatalogFeatureWithItsSourceOrAdoptedFrom() async throws {
        struct Listed: Decodable {
            let features: [SwiftFeatureStatus]
        }
        let rootURL = try Self.temporaryDirectory("exposure-catalog-marking")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try await AppStorageDirectory.withSupportDirectoryURL(rootURL.appendingPathComponent("support")) {
            let featuresURL = rootURL.appendingPathComponent("features", isDirectory: true)
            let catalog = SwiftFeatureRuntime.bundledFeatureDefinitions().filter { !$0.isCore }
            let installed = try #require(catalog.first)
            try Self.writeFile(
                at: featuresURL
                    .appendingPathComponent(installed.id, isDirectory: true)
                    .appendingPathComponent(SwiftFeatureRegistry.manifestFilename),
                contents: SwiftFeatureRuntime.adoptedFeatureManifestContents(
                    definition: installed,
                    displayName: "Installed",
                    enabled: false
                )
            )
            let runtime = SwiftFeatureRuntime(featureSearchRoots: [featuresURL])
            _ = try await runtime.executeManagementTool(
                toolCall: Self.managementCall("feature.scaffold", ["id": "plain-generated", "toolName": "plaingen.run"])
            )

            let output = try await runtime.executeManagementTool(toolCall: Self.managementCall("feature.list", [:]))
            let statuses = try JSONDecoder().decode(Listed.self, from: Data(output.utf8)).features
            let installedStatus = try #require(statuses.first { $0.id == installed.id })
            #expect(installedStatus.source == .generated)
            #expect(installedStatus.adoptedFrom == installed.id)
            for definition in catalog.dropFirst() {
                let status = try #require(statuses.first { $0.id == definition.id })
                #expect(status.source == .bundled, "\(definition.id)")
            }
            let generated = try #require(statuses.first { $0.id == "plain-generated" })
            #expect(generated.source == .generated)
            #expect(generated.adoptedFrom == nil)
            #expect(output.contains("\"adoptedFrom\" : \"\(installed.id)\""), "\(output)")
            #expect(output.contains("\"source\" : \"bundled\""), "\(output)")
        }
    }

    // MARK: - Two bundles with one ID

    /// With two loaded bundles that share an ID, the exposure is decided per
    /// bundle: only the one that runs the executable registered for the
    /// session is listed, allowed, and published.
    @Test
    func twoLoadedBundlesWithOneIDAreExposedByTheRegisteredExecutable() async {
        let first = Self.bundle(id: "twin", tools: ["twin.first"])
        let second = Self.bundle(id: "twin", tools: ["twin.second"])
        let runtime = SwiftFeatureRuntime(features: [first, second])
        await runtime.exposeForTesting("twin", sessionID: "session-a", executableURL: first.executableURL)
        await runtime.exposeForTesting("twin", sessionID: "session-b", executableURL: second.executableURL)

        #expect(await runtime.builderBuiltExecutablePathsBySessionID == [
            "session-a": ["twin": first.executableURL.standardizedFileURL.path],
            "session-b": ["twin": second.executableURL.standardizedFileURL.path],
        ])
        for (sessionID, exposed, other) in [
            ("session-a", "twin.first", "twin.second"),
            ("session-b", "twin.second", "twin.first"),
        ] {
            #expect(await runtime.exposedFeatureIDs(sessionID: sessionID) == ["twin"], "\(sessionID)")
            #expect(await runtime.exposures(sessionID: sessionID) == [
                SwiftFeatureSessionExposure(featureID: "twin", toolNames: [exposed], toolNamePrefixes: []),
            ], "\(sessionID)")
            #expect(await Self.names(runtime.descriptors(
                allowedToolNames: ["agent.message"],
                sessionID: sessionID
            )) == [exposed], "\(sessionID)")
            #expect(await Self.names(runtime.knownDescriptors(
                allowedToolNames: ["agent.message"],
                sessionID: sessionID
            )) == [exposed], "\(sessionID)")
            #expect(await runtime.featureToolIsAllowed(
                toolName: exposed,
                allowedToolNames: ["agent.message"],
                sessionID: sessionID
            ), "\(sessionID)")
            #expect(!(await runtime.featureToolIsAllowed(
                toolName: other,
                allowedToolNames: ["agent.message"],
                sessionID: sessionID
            )), "\(sessionID)")
        }
        // A session without a registration is granted neither bundle.
        #expect(await Self.names(runtime.descriptors(
            allowedToolNames: ["agent.message"],
            sessionID: "session-c"
        )).isEmpty)
        #expect(!(await runtime.featureToolIsAllowed(
            toolName: "twin.first",
            allowedToolNames: ["agent.message"],
            sessionID: "session-c"
        )))
    }

    /// The reload check looks at the bundle each session is exposed to, not at
    /// the first one loaded with the ID: the rerouted bundle is the second.
    @Test
    func aReloadChecksTheExposedBundleOfTwoLoadedWithOneID() async {
        let clean = Self.bundle(id: "twin", tools: ["twin.first"])
        let rerouted = Self.bundle(id: "twin", tools: ["local.readFile.extra"])
        let runtime = SwiftFeatureRuntime(features: [clean, rerouted])
        await runtime.exposeForTesting("twin", sessionID: "session-a", executableURL: clean.executableURL)
        await runtime.exposeForTesting("twin", sessionID: "session-b", executableURL: rerouted.executableURL)

        await runtime.reloadFeatureBundles()

        #expect(await runtime.exposedFeatureIDs(sessionID: "session-a") == ["twin"])
        #expect(await runtime.exposedFeatureIDs(sessionID: "session-b").isEmpty)
        #expect(await runtime.builderBuiltExecutablePathsBySessionID.keys.sorted() == ["session-a"])
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

private func runtimeKnownNames(_ descriptors: [DirectToolDescriptor]) -> [String] {
    SwiftFeatureSessionExposureTests.names(descriptors)
}
