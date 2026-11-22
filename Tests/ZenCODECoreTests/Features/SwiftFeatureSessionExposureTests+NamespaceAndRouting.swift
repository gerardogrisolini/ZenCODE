//
//  SwiftFeatureSessionExposureTests+NamespaceAndRouting.swift
//  ZenCODE
//
//  Session exposure tests for the delegated namespace check, routing changes
//  after a build, catalog marking in feature.list, and two bundles sharing
//  one ID.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension SwiftFeatureSessionExposureTests {
    // MARK: - Delegated namespace

    @Test
    func aDelegatedFeatureMayNotTakeACoreNamespace() async throws {
        let runtime = SwiftFeatureRuntime(features: [])
        let refused: [(tools: [String], aliases: [String], prefixes: [String], entry: String)] = [
            (["local.read"], [], [], "its tool 'local.read'"),
            (["tasks.exportCSV"], [], [], "its tool 'tasks.exportCSV' falls in the namespace 'tasks.' of the core tools"),
            (["memoryless", "memory.export"], [], [], "its tool 'memory.export' falls in the namespace 'memory.'"),
            (["memory"], [], [], "the namespace 'memory.' of its tool 'memory'"),
            (["fine.run"], ["agent.create"], [], "its alias 'agent.create'"),
            (["fine.run"], [], ["todo."], "its tool prefix 'todo.'"),
            (["fine.run"], [], ["tas"], "its tool prefix 'tas'"),
            (["fine.run"], [], ["feature.x."], "its tool prefix 'feature.x.'"),
            // A name under a core namespace, which a session allowing the core
            // tool would find relevant through the derived prefix.
            (["local.read.pdf"], [], [], "its tool 'local.read.pdf' falls in the namespace 'local.' of the core tools"),
            (["skills.list.x"], [], [], "its tool 'skills.list.x' falls in the namespace 'skills.' of the core tools"),
            (["fine.run"], ["skills.list.x"], [], "its alias 'skills.list.x' falls in the namespace 'skills.'"),
            (["fine.run"], [], ["local.read."], "its tool prefix 'local.read.' falls in the namespace 'local.'"),
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
                manifest["toolNamePrefixes"] = ["local.read."]
            }
            // An unrelated reload, by a caller without any delegating session.
            _ = try await runtime.executeManagementTool(toolCall: Self.managementCall("feature.reload", [:]))

            // Still loaded, with the new routing, but no longer exposed.
            #expect(await runtime.features.first { $0.id == "rerouted-fixture" }?.toolNamePrefixes
                == ["local.read."])
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
        let rerouted = Self.bundle(id: "twin", tools: ["local.read.extra"])
        let runtime = SwiftFeatureRuntime(features: [clean, rerouted])
        await runtime.exposeForTesting("twin", sessionID: "session-a", executableURL: clean.executableURL)
        await runtime.exposeForTesting("twin", sessionID: "session-b", executableURL: rerouted.executableURL)

        await runtime.reloadFeatureBundles()

        #expect(await runtime.exposedFeatureIDs(sessionID: "session-a") == ["twin"])
        #expect(await runtime.exposedFeatureIDs(sessionID: "session-b").isEmpty)
        #expect(await runtime.builderBuiltExecutablePathsBySessionID.keys.sorted() == ["session-a"])
    }
}
