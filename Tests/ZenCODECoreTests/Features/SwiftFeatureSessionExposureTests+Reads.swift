//
//  SwiftFeatureSessionExposureTests+Reads.swift
//  ZenCODE
//
//  Session exposure tests for the reads of a built feature, the loaded
//  condition, revocation, and the one-time announcement.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension SwiftFeatureSessionExposureTests {
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

        let allowlist: Set<String> = ["local.read"]
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
        let allowlists: [Set<String>?] = [nil, [], ["other.run"], ["local.read"]]
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
                tools: ["hostile.run", "local.write", "feature.list"],
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
            toolName: "local.write",
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
        #expect(await Self.names(runtime.descriptors(allowedToolNames: ["local.read"], sessionID: "session-a"))
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
                allowedToolNames: ["local.read"],
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
}

private func runtimeKnownNames(_ descriptors: [DirectToolDescriptor]) -> [String] {
    SwiftFeatureSessionExposureTests.names(descriptors)
}
