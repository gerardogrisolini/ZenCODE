//
//  SupportDirectoryCleanupSetupTests.swift
//  ZenCODECoreTests
//
//  Data management › Clean support directory: inventory, path safety, Chrome
//  profile and app install locks, deletion, menu items and report rendering,
//  and the interactive step shared with Export backup, always on a temporary
//  support directory.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct SupportDirectoryCleanupSetupTests {
    private typealias Runner = ZenCODESetupRunner
    private typealias Group = ZenCODESetupRunner.SupportCleanupGroup

    private struct Fixture {
        let rootURL: URL
        let supportURL: URL
        /// A directory next to the support directory, the target of links.
        let outsideURL: URL

        init() throws {
            rootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-support-cleanup-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL
            supportURL = rootURL.appendingPathComponent("support", isDirectory: true)
            outsideURL = rootURL.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: rootURL)
        }

        func url(_ relativePath: String) -> URL {
            supportURL.appendingPathComponent(relativePath)
        }

        func path(_ relativePath: String) -> String {
            url(relativePath).path
        }

        func exists(_ relativePath: String) -> Bool {
            FileManager.default.fileExists(atPath: path(relativePath))
        }

        func isLink(_ relativePath: String) -> Bool {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path(relativePath))) != nil
        }

        @discardableResult
        func file(_ relativePath: String, bytes: Int = 4_096) throws -> URL {
            let fileURL = url(relativePath)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: fileURL)
            return fileURL
        }

        func directory(_ relativePath: String) throws {
            try FileManager.default.createDirectory(at: url(relativePath), withIntermediateDirectories: true)
        }

        func link(_ relativePath: String, to destination: String) throws {
            let linkURL = url(relativePath)
            try FileManager.default.createDirectory(
                at: linkURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: destination)
        }

        func inventory() -> [ZenCODESetupRunner.SupportCleanupGroupInventory] {
            ZenCODESetupRunner.supportCleanupInventory(supportDirectoryURL: supportURL)
        }

        /// A full support directory: every regenerable path plus the files
        /// the cleanup must keep.
        func populate() throws {
            // Group 1: the on-device model.
            try file("browser/OptGuideOnDeviceModel/2025.1/weights.bin", bytes: 8_192)
            try file("browser/OptGuideOnDeviceClassifierModel/model.tflite")
            try file("browser/OptGuidePredictionModels/model.pb")
            try file("browser/optimization_guide_model_store/store.db")
            // Group 2: the caches.
            try file("browser/Default/Cache/Cache_Data/data_0", bytes: 4_096)
            try file("browser/Default/Code Cache/js/index")
            try file("browser/Default/GPUCache/data_1")
            try file("browser/Default/Service Worker/CacheStorage/cache")
            try file("browser/Default/Service Worker/ScriptCache/script")
            try file("browser/GrShaderCache/data_0")
            try file("browser/GraphiteDawnCache/data_0")
            try file("browser/ShaderCache/data_0")
            try file("browser/GPUPersistentCache/data_0")
            // Profile data that must survive.
            try file("browser/Default/Cookies")
            try file("browser/Default/Login Data")
            try file("browser/Default/Service Worker/Database/LOG")
            try file("browser/Local State")
            try file("browser/snapshot-authorizations.json")
            try file("browser/viewport-presets.json")

            // Feature with the Swift Build layout.
            try file("features/alpha/feature.json")
            try file("features/alpha/.build/repositories/dep-1234/HEAD")
            try file("features/alpha/.build/checkouts/dep/Package.swift")
            try file("features/alpha/.build/out/Products/Release/alpha-exe", bytes: 2_048)
            try file("features/alpha/.build/out/build.db")
            try file("features/alpha/.build/out/Intermediates.noindex/alpha.build/main.o", bytes: 4_096)
            try link("features/alpha/.build/release", to: "out/Products/Release")
            try file("features/alpha/.build/artifacts/binary.artifactbundle/info.json")
            try file("features/alpha/.build/workspace-state.json")
            // Feature with the native layout: no out/Products, no checkouts.
            try file("features/beta/feature.json")
            try file("features/beta/.build/repositories/dep-5678/HEAD")
            try file("features/beta/.build/release/beta-exe")
            try file("features/beta/.build/out/stray")
            // Hidden install, staging and backup directories are never touched.
            for name in [
                ".zencode-feature-install-1",
                ".zencode-feature-staging-2",
                ".zencode-feature-backup-3"
            ] {
                try file("features/\(name)/.build/repositories/dep/HEAD")
                try file("features/\(name)/.build/checkouts/dep/Package.swift")
                try file("features/\(name)/.build/out/Products/Release/exe")
                try file("features/\(name)/.build/out/build.db")
            }

            // App and ZenCRON.
            try file("app/build/arm64-apple-macosx/release/ZenCODE", bytes: 4_096)
            try file("app/current/ZenCODE")
            try file("zencron/package/Package.swift")
            try file("zencron/package/.build/release/ZenCRON", bytes: 4_096)
            try file("bin/ZenCRON")

            // Other support data.
            try file("settings.json")
            try file("memory/global/memory.graph.json")
        }

        /// Paths of the full fixture by group, in inventory order.
        func expectedPaths() -> [Group: [String]] {
            var expected: [Group: [String]] = [
                .browserModel: [
                    "browser/OptGuideOnDeviceModel",
                    "browser/OptGuideOnDeviceClassifierModel",
                    "browser/OptGuidePredictionModels",
                    "browser/optimization_guide_model_store"
                ].map(path),
                .browserCaches: [
                    "browser/Default/Cache",
                    "browser/Default/Code Cache",
                    "browser/Default/GPUCache",
                    "browser/Default/Service Worker/CacheStorage",
                    "browser/Default/Service Worker/ScriptCache",
                    "browser/GrShaderCache",
                    "browser/GraphiteDawnCache",
                    "browser/ShaderCache",
                    "browser/GPUPersistentCache"
                ].map(path),
                .featureDependencies: [
                    "features/alpha/.build/repositories",
                    "features/alpha/.build/checkouts",
                    "features/beta/.build/repositories"
                ].map(path),
                .featureIntermediates: [
                    "features/alpha/.build/out/Intermediates.noindex",
                    "features/alpha/.build/out/build.db"
                ].map(path),
                .zencronBuild: [path("zencron/package/.build")]
            ]
            #if os(macOS)
            expected[.appBuild] = [path("app/build")]
            #endif
            return expected
        }

        /// Everything the cleanup must keep in the full fixture.
        static let protectedPaths = [
            "browser/Default/Cookies",
            "browser/Default/Login Data",
            "browser/Default/Service Worker/Database/LOG",
            "browser/Local State",
            "browser/snapshot-authorizations.json",
            "browser/viewport-presets.json",
            "features/alpha/feature.json",
            "features/alpha/.build/out/Products/Release/alpha-exe",
            "features/alpha/.build/artifacts/binary.artifactbundle/info.json",
            "features/alpha/.build/workspace-state.json",
            "features/beta/feature.json",
            "features/beta/.build/release/beta-exe",
            "features/beta/.build/out/stray",
            "features/.zencode-feature-install-1/.build/repositories/dep/HEAD",
            "features/.zencode-feature-staging-2/.build/checkouts/dep/Package.swift",
            "features/.zencode-feature-backup-3/.build/out/build.db",
            "app/current/ZenCODE",
            "zencron/package/Package.swift",
            "bin/ZenCRON",
            "settings.json",
            "memory/global/memory.graph.json"
        ]
    }

    private static func pathsByGroup(
        _ inventory: [ZenCODESetupRunner.SupportCleanupGroupInventory]
    ) -> [Group: [String]] {
        Dictionary(uniqueKeysWithValues: inventory.map { ($0.group, $0.items.map(\.url.path)) })
    }

    // MARK: - Inventory

    @Test
    func inventoryFindsExactlyTheRegenerablePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()

        let inventory = fixture.inventory()

        var expectedOrder: [Group] = [.browserModel, .browserCaches, .featureDependencies, .featureIntermediates]
        #if os(macOS)
        expectedOrder.append(.appBuild)
        #endif
        expectedOrder.append(.zencronBuild)
        #expect(inventory.map(\.group) == expectedOrder)
        #expect(Self.pathsByGroup(inventory) == fixture.expectedPaths())
        #expect(inventory.allSatisfy { $0.skipReason == nil })
        #expect(inventory.allSatisfy { group in group.items.allSatisfy { $0.bytes > 0 } })

        let listed = Set(inventory.flatMap { $0.items.map(\.url.path) })
        for protected in Fixture.protectedPaths.map(fixture.path) {
            #expect(!listed.contains { protected == $0 || protected.hasPrefix($0 + "/") }, "\(protected)")
        }
        #expect(!listed.contains(fixture.path("features/alpha/.build/release")))
        #expect(!listed.contains(fixture.path("features/alpha/.build/out/Products")))
        #expect(!listed.contains(fixture.path("features/alpha/.build/artifacts")))
        #expect(!listed.contains(fixture.path("bin/ZenCRON")))
        #expect(!listed.contains(fixture.path("app/current")))
        #expect(!listed.contains { $0.contains("/.zencode-feature-") })
    }

    @Test
    func emptySupportDirectoryHasNothingToClean() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("settings.json")
        try fixture.file("browser/Local State")
        try fixture.file("zencron/package/Package.swift")

        #expect(fixture.inventory().isEmpty)
        #expect(Runner.supportCleanupMenuItems(fixture.inventory()).isEmpty)
        #expect(Runner.renderSupportCleanupSkippedGroups(fixture.inventory()) == nil)
    }

    @Test
    func intermediateBuildFilesNeedTheSwiftBuildProductsDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("features/native/.build/out/build.db")
        try fixture.file("features/native/.build/out/Intermediates.noindex/main.o")
        try fixture.file("features/native/.build/release/native-exe")

        #expect(!fixture.inventory().map(\.group).contains(.featureIntermediates))

        // A linked Products directory is not the Swift Build layout either.
        try fixture.directory("features/linked/.build/out/Release")
        try fixture.file("features/linked/.build/out/build.db")
        try fixture.link("features/linked/.build/out/Products", to: "Release")
        #expect(!fixture.inventory().map(\.group).contains(.featureIntermediates))

        try fixture.directory("features/native/.build/out/Products")
        let paths = Self.pathsByGroup(fixture.inventory())[.featureIntermediates]
        #expect(paths == [
            fixture.path("features/native/.build/out/Intermediates.noindex"),
            fixture.path("features/native/.build/out/build.db")
        ])
    }

    @Test
    func inventorySkipsLinkedCandidatesAndLinkedFeatureDirectories() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outsideCache = fixture.outsideURL.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideCache, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outsideCache.appendingPathComponent("data"))
        let outsideFeature = fixture.outsideURL.appendingPathComponent("feature", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outsideFeature.appendingPathComponent(".build/repositories", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fixture.link("browser/Default/Cache", to: outsideCache.path)
        try fixture.link("browser/ShaderCache", to: outsideCache.path)
        try fixture.link("features/linked", to: outsideFeature.path)
        try fixture.file("browser/GPUPersistentCache/data")

        let inventory = fixture.inventory()

        #expect(Self.pathsByGroup(inventory) == [.browserCaches: [fixture.path("browser/GPUPersistentCache")]])
        let result = Runner.applySupportDirectoryCleanup(inventory, supportDirectoryURL: fixture.supportURL)
        #expect(result.failures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outsideCache.appendingPathComponent("data").path))
        #expect(fixture.isLink("browser/Default/Cache"))
        #expect(FileManager.default.fileExists(
            atPath: outsideFeature.appendingPathComponent(".build/repositories").path
        ))
    }

    @Test
    func pathCheckAcceptsOnlyUnlinkedDescendants() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("browser/GPUCache/data")
        try fixture.link("browser/Default", to: fixture.outsideURL.path)
        try FileManager.default.createDirectory(
            at: fixture.outsideURL.appendingPathComponent("Cache", isDirectory: true),
            withIntermediateDirectories: true
        )
        func check(_ url: URL) -> Runner.SupportCleanupPathCheck {
            Runner.supportCleanupPathCheck(url, supportDirectoryURL: fixture.supportURL)
        }

        #expect(check(fixture.url("browser/GPUCache")) == .safe)
        #expect(check(fixture.url("browser/Missing")) == .missing)
        #expect(check(fixture.supportURL) != .safe)
        #expect(check(fixture.outsideURL) != .safe)
        #expect(check(fixture.url("../outside/Cache")) != .safe)
        #expect(check(fixture.rootURL.appendingPathComponent("support-other/x")) != .safe)
        // Through a linked directory, and the link itself.
        #expect(check(fixture.url("browser/Default/Cache")) != .safe)
        #expect(check(fixture.url("browser/Default")) != .safe)
    }

    @Test
    func allocatedBytesCountFilesWithoutFollowingLinks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("browser/ShaderCache/a", bytes: 10_000)
        try fixture.file("browser/ShaderCache/nested/b", bytes: 5_000)
        let large = fixture.outsideURL.appendingPathComponent("large")
        try Data(repeating: 0, count: 2_000_000).write(to: large)
        try fixture.link("browser/ShaderCache/link", to: large.path)

        let bytes = Runner.supportCleanupAllocatedBytes(at: fixture.url("browser/ShaderCache"))

        #expect(bytes >= 15_000)
        #expect(bytes < 2_000_000)
        #expect(Runner.supportCleanupAllocatedBytes(at: fixture.url("browser/ShaderCache/a")) >= 10_000)
        #expect(Runner.supportCleanupAllocatedBytes(at: fixture.url("browser/ShaderCache/link")) == 0)
        #expect(Runner.supportCleanupAllocatedBytes(at: fixture.url("browser/Missing")) == 0)
    }

    // MARK: - Chrome profile lock

    @Test
    func chromeLockTargetNeedsAWellFormedLivePid() {
        #expect(Runner.chromeProfileLockOwnerPID(lockTarget: "my-mac.local-4242") { $0 == 4242 } == 4242)
        #expect(Runner.chromeProfileLockOwnerPID(lockTarget: "my-mac.local-4242") { _ in false } == nil)
        #expect(Runner.chromeProfileLockOwnerPID(lockTarget: "host-notapid") { _ in true } == nil)
        #expect(Runner.chromeProfileLockOwnerPID(lockTarget: "host-0") { _ in true } == nil)
        #expect(Runner.chromeProfileLockOwnerPID(lockTarget: "host-") { _ in true } == nil)
        #expect(Runner.chromeProfileLockOwnerPID(lockTarget: "nodash") { _ in true } == nil)
    }

    @Test
    func browserGroupsAreBlockedWhileALiveProcessHoldsTheProfile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let pid = ProcessInfo.processInfo.processIdentifier
        try fixture.link("browser/SingletonLock", to: "my-host-\(pid)")

        let inventory = fixture.inventory()

        let browser = inventory.filter(\.group.usesBrowserProfile)
        #expect(browser.map(\.group) == [.browserModel, .browserCaches])
        #expect(browser.allSatisfy { $0.skipReason?.contains("Chrome (pid \(pid))") == true })
        #expect(inventory.filter { !$0.group.usesBrowserProfile }.allSatisfy { $0.skipReason == nil })
        let menuGroups = Runner.supportCleanupMenuItems(inventory).map(\.value)
        #expect(!menuGroups.contains(.browserModel))
        #expect(!menuGroups.contains(.browserCaches))
        #expect(menuGroups.contains(.featureDependencies))
        let skipped = try #require(Runner.renderSupportCleanupSkippedGroups(inventory))
        #expect(skipped.contains("Skipped Browser on-device AI model"))
        #expect(skipped.contains("Skipped Browser caches"))
        #expect(skipped.contains(fixture.path("browser")))
    }

    @Test
    func browserGroupsAreOfferedWithADeadOrGarbageLock() throws {
        for target in ["my-host-2147483646", "garbage", "host-0"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.file("browser/ShaderCache/data")
            try fixture.file("browser/OptGuideOnDeviceModel/weights.bin")
            try fixture.link("browser/SingletonLock", to: target)

            let inventory = fixture.inventory()

            #expect(inventory.map(\.group) == [.browserModel, .browserCaches], "\(target)")
            #expect(inventory.allSatisfy { $0.skipReason == nil }, "\(target)")
            #expect(Runner.supportCleanupMenuItems(inventory).map(\.value) == [.browserModel, .browserCaches])
        }
    }

    @Test
    func applyRechecksTheChromeLockBeforeDeleting() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let inventory = fixture.inventory()
        #expect(inventory.allSatisfy { $0.skipReason == nil })
        // Chrome starts between the inventory and the confirmation.
        try fixture.link("browser/SingletonLock", to: "my-host-\(ProcessInfo.processInfo.processIdentifier)")

        let result = Runner.applySupportDirectoryCleanup(inventory, supportDirectoryURL: fixture.supportURL)

        #expect(result.skipped.map(\.group) == [.browserModel, .browserCaches])
        #expect(result.skipped.allSatisfy { $0.reason.contains("Chrome (pid") })
        #expect(result.failures.isEmpty)
        for path in fixture.expectedPaths()[.browserModel]! + fixture.expectedPaths()[.browserCaches]! {
            #expect(FileManager.default.fileExists(atPath: path), "\(path)")
        }
        #expect(!fixture.exists("features/alpha/.build/repositories"))
        #expect(!fixture.exists("zencron/package/.build"))
    }

    // MARK: - Apply

    @Test
    func applyDeletesOnlyTheSelectedGroupsAndKeepsProtectedFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let inventory = fixture.inventory()
        let selected = inventory.filter { $0.group != .browserModel }

        let result = Runner.applySupportDirectoryCleanup(selected, supportDirectoryURL: fixture.supportURL)

        #expect(result.failures.isEmpty)
        #expect(result.skipped.isEmpty)
        #expect(Set(result.deleted) == Set(selected.flatMap(\.items)))
        #expect(result.freedBytes == selected.reduce(0) { $0 + $1.totalBytes })
        #expect(result.freedBytes > 0)
        let expected = fixture.expectedPaths()
        for path in expected[.browserModel]! {
            #expect(FileManager.default.fileExists(atPath: path), "\(path)")
        }
        for group in selected.map(\.group) {
            for path in expected[group]! {
                #expect(!FileManager.default.fileExists(atPath: path), "\(path)")
            }
        }
        for protected in Fixture.protectedPaths {
            #expect(fixture.exists(protected), "\(protected)")
        }
        // The feature still runs from `.build/release`.
        #expect(fixture.isLink("features/alpha/.build/release"))
        #expect(fixture.exists("features/alpha/.build/release/alpha-exe"))
        #expect(fixture.exists("features/alpha/.build/out/Products/Release/alpha-exe"))
        // Nothing left to clean but the unselected group.
        #expect(fixture.inventory().map(\.group) == [.browserModel])
    }

    @Test
    func applyReportsAFailureAndContinuesWithTheOtherPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("features/alpha/.build/repositories/dep/HEAD")
        try fixture.file("features/alpha/.build/checkouts/dep/Package.swift")
        try fixture.file("features/beta/.build/repositories/dep/HEAD")
        let inventory = fixture.inventory()
        // A candidate replaced by a link after the inventory, and one outside
        // the support directory, are left in place.
        try FileManager.default.removeItem(at: fixture.url("features/alpha/.build/checkouts"))
        try fixture.link("features/alpha/.build/checkouts", to: fixture.outsideURL.path)
        try Data("keep".utf8).write(to: fixture.outsideURL.appendingPathComponent("keep"))
        let outsideItem = Runner.SupportCleanupItem(url: fixture.outsideURL, bytes: 4)
        let forged = Runner.SupportCleanupGroupInventory(
            group: .zencronBuild,
            items: [outsideItem],
            skipReason: nil
        )
        // A path already gone is ignored.
        try FileManager.default.removeItem(at: fixture.url("features/beta/.build/repositories"))

        let result = Runner.applySupportDirectoryCleanup(
            inventory + [forged],
            supportDirectoryURL: fixture.supportURL
        )

        #expect(result.deleted.map(\.url.path) == [fixture.path("features/alpha/.build/repositories")])
        #expect(result.failures.map(\.url.path) == [
            fixture.path("features/alpha/.build/checkouts"),
            fixture.outsideURL.path
        ])
        #expect(result.failures[0].reason.contains("symbolic link"))
        #expect(result.failures[1].reason.contains("outside the support directory"))
        #expect(fixture.isLink("features/alpha/.build/checkouts"))
        #expect(FileManager.default.fileExists(atPath: fixture.outsideURL.appendingPathComponent("keep").path))
        let summary = Runner.renderSupportCleanupSummary(result)
        #expect(summary.contains("Not deleted:"))
        #expect(summary.contains("- \(fixture.outsideURL.path): outside the support directory"))
    }

    #if os(macOS)
    @Test
    func appBuildIsSkippedWhileTheInstallLockIsHeld() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("app/build/release/ZenCODE")
        try fixture.file("app/current/ZenCODE")
        let layout = ZenAppInstallation.Layout(supportDirectory: fixture.supportURL)
        let inventory = fixture.inventory()
        #expect(inventory.map(\.group) == [.appBuild])

        // A `zen --ui` holds the lock.
        let descriptor = open(layout.installLockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        #expect(descriptor >= 0)
        #expect(flock(descriptor, LOCK_EX) == 0)
        let blocked = Runner.applySupportDirectoryCleanup(inventory, supportDirectoryURL: fixture.supportURL)
        ZenAppInstallation.releaseInstallLock(descriptor)

        #expect(blocked.deleted.isEmpty)
        #expect(blocked.skipped.map(\.group) == [.appBuild])
        #expect(blocked.skipped.first?.reason.contains("zen --ui is installing") == true)
        #expect(fixture.exists("app/build/release/ZenCODE"))

        let applied = Runner.applySupportDirectoryCleanup(inventory, supportDirectoryURL: fixture.supportURL)

        #expect(applied.skipped.isEmpty)
        #expect(applied.failures.isEmpty)
        #expect(!fixture.exists("app/build"))
        #expect(fixture.exists("app/current/ZenCODE"))
        // The lock was released: it can be taken again without waiting.
        guard case let .acquired(again) = Runner.tryAcquireAppInstallLock(layout: layout) else {
            Issue.record("the install lock is still held")
            return
        }
        ZenAppInstallation.releaseInstallLock(again)
    }
    #endif

    // MARK: - Menu and report

    @Test
    func menuItemsListEveryOfferedGroupWithItsSize() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        let inventory = fixture.inventory()

        let items = Runner.supportCleanupMenuItems(inventory)

        #expect(items.map(\.value) == inventory.map(\.group))
        #expect(items.map(\.title) == inventory.map(\.group.title))
        for (item, group) in zip(items, inventory) {
            #expect(item.detail == "\(Runner.supportCleanupByteString(group.totalBytes)), \(group.group.detail)")
        }
        #expect(Group.browserModel.title == "Browser on-device AI model")
        #expect(Group.browserModel.detail.contains("Gemini Nano, ~4 GB"))
        #expect(Group.browserModel.detail.contains("downloads it again"))
        #expect(Group.allCases.map(\.title) == [
            "Browser on-device AI model",
            "Browser caches",
            "Feature dependency downloads",
            "Feature intermediate build files",
            "App build directory",
            "ZenCRON build directory"
        ])
    }

    @Test
    func reportListsTheExactPathsSizesAndTotal() {
        let support = URL(fileURLWithPath: "/tmp/zen-support", isDirectory: true)
        let groups = [
            Runner.SupportCleanupGroupInventory(
                group: .browserCaches,
                items: [
                    .init(url: support.appendingPathComponent("browser/ShaderCache"), bytes: 2_000_000),
                    .init(url: support.appendingPathComponent("browser/Default/Cache"), bytes: 1_000_000)
                ],
                skipReason: nil
            ),
            Runner.SupportCleanupGroupInventory(
                group: .zencronBuild,
                items: [.init(url: support.appendingPathComponent("zencron/package/.build"), bytes: 500)],
                skipReason: nil
            )
        ]
        func size(_ bytes: Int64) -> String { Runner.supportCleanupByteString(bytes) }

        let report = Runner.renderSupportCleanupReport(groups, supportDirectoryURL: support)

        #expect(report == """
            Support directory: /tmp/zen-support

            Browser caches: \(size(3_000_000))
            - /tmp/zen-support/browser/ShaderCache (\(size(2_000_000)))
            - /tmp/zen-support/browser/Default/Cache (\(size(1_000_000)))

            ZenCRON build directory: \(size(500))
            - /tmp/zen-support/zencron/package/.build (\(size(500)))

            Total: \(size(3_000_500))
            """)
    }

    @Test
    func summaryReportsFreedBytesSkipsAndFailures() {
        let support = URL(fileURLWithPath: "/tmp/zen-support", isDirectory: true)
        var result = Runner.SupportCleanupResult()
        #expect(Runner.renderSupportCleanupSummary(result) == "Freed \(Runner.supportCleanupByteString(0)) (0 paths deleted).")

        result.deleted = [.init(url: support.appendingPathComponent("zencron/package/.build"), bytes: 4_096)]
        result.skipped = [.init(group: .appBuild, reason: "busy.")]
        result.failures = [.init(url: support.appendingPathComponent("browser/ShaderCache"), reason: "denied")]

        #expect(Runner.renderSupportCleanupSummary(result) == """
            Freed \(Runner.supportCleanupByteString(4_096)) (1 path deleted).
            Skipped App build directory: busy.
            Not deleted:
            - /tmp/zen-support/browser/ShaderCache: denied
            """)
    }

    // MARK: - Interactive step

    private struct Boom: Error {}

    private static func isCancelled(_ error: ZenCODESetupError?) -> Bool {
        if case .cancelled? = error {
            return true
        }
        return false
    }

    /// The paths of the full fixture, regenerable and protected, that are gone.
    private static func missingPopulatedPaths(_ fixture: Fixture) -> [String] {
        let paths = fixture.expectedPaths().values.flatMap { $0 } + Fixture.protectedPaths.map(fixture.path)
        return paths.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    private static func measuringLine(_ fixture: Fixture) -> String {
        "Measuring the regenerable data under \(fixture.supportURL.path)…\n"
    }

    @Test
    func cleanupStepReportsHowItEnded() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        func step(
            select: Set<Group>?,
            confirm: () throws -> Bool
        ) throws -> Runner.SupportCleanupStepOutcome {
            try Runner.runSupportDirectoryCleanupStep(
                supportDirectoryURL: fixture.supportURL,
                write: { _ in },
                selectGroups: { _ in select },
                confirmDeletion: confirm
            )
        }

        #expect(try step(select: nil, confirm: { true }) == .menuCancelled)
        #expect(try step(select: [], confirm: { true }) == .noGroupSelected)
        #expect(try step(select: [.zencronBuild], confirm: { false }) == .declined)
        #expect(try step(select: [.zencronBuild], confirm: { throw ZenCODESetupError.cancelled }) == .confirmationCancelled)
        // Another error of the confirmation propagates.
        #expect(throws: Boom.self) {
            _ = try step(select: [.zencronBuild], confirm: { throw Boom() })
        }
        #expect(Self.missingPopulatedPaths(fixture).isEmpty)

        let applied = try step(select: [.zencronBuild], confirm: { true })

        guard case let .applied(result) = applied else {
            Issue.record("Expected applied, got \(applied)")
            return
        }
        #expect(result.deleted.map(\.url.path) == [fixture.path("zencron/package/.build")])
        #expect(result.failures.isEmpty)
        #expect(!fixture.exists("zencron/package/.build"))
        #expect(fixture.exists("zencron/package/Package.swift"))

        let empty = try Fixture()
        defer { empty.remove() }
        try empty.file("settings.json")
        let nothing = try Runner.runSupportDirectoryCleanupStep(
            supportDirectoryURL: empty.supportURL,
            write: { _ in },
            selectGroups: { _ in nil },
            confirmDeletion: { true }
        )
        #expect(nothing == .nothingToClean)
    }

    @Test
    func standaloneCleanupKeepsItsMessages() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        func run(select: Set<Group>?, confirm: () throws -> Bool) throws -> String {
            var output = ""
            try Runner.runSupportDirectoryCleanup(
                supportDirectoryURL: fixture.supportURL,
                write: { output += $0 },
                selectGroups: { _ in select },
                confirmDeletion: confirm
            )
            return output
        }
        let measuring = Self.measuringLine(fixture)
        let report = Runner.renderSupportCleanupReport(
            fixture.inventory().filter { $0.group == .zencronBuild },
            supportDirectoryURL: fixture.supportURL
        )

        // Esc on the group menu returns silently.
        #expect(try run(select: nil, confirm: { true }) == measuring)
        #expect(try run(select: [], confirm: { true }) == measuring + "No group selected.\n\n")
        // No and Esc on the confirmation both cancel the cleanup.
        let cancelled = measuring + "\n" + report + "\n\nCleanup cancelled.\n\n"
        #expect(try run(select: [.zencronBuild], confirm: { false }) == cancelled)
        #expect(try run(select: [.zencronBuild], confirm: { throw ZenCODESetupError.cancelled }) == cancelled)
        #expect(Self.missingPopulatedPaths(fixture).isEmpty)

        let applied = try run(select: [.zencronBuild], confirm: { true })

        #expect(applied.hasPrefix(measuring + "\n" + report + "\n\nFreed "))
        #expect(!applied.contains("Cleanup cancelled"))
        #expect(!fixture.exists("zencron/package/.build"))
    }

    @Test
    func exportStepEscOnTheGroupMenuCancelsTheExport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        var output = ""
        var offered: [Group] = []
        var confirmations = 0

        let error = #expect(throws: ZenCODESetupError.self) {
            try Runner.runDataExportCleanupStep(
                supportDirectoryURL: fixture.supportURL,
                write: { output += $0 },
                selectGroups: { items in
                    offered = items.map(\.value)
                    return nil
                },
                confirmDeletion: {
                    confirmations += 1
                    return true
                }
            )
        }

        #expect(Self.isCancelled(error))
        #expect(offered == fixture.inventory().map(\.group))
        #expect(confirmations == 0)
        #expect(Self.missingPopulatedPaths(fixture).isEmpty)
        #expect(output == Self.measuringLine(fixture))
    }

    @Test
    func exportStepEscOnTheConfirmationCancelsTheExport() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        var output = ""
        var confirmations = 0

        let error = #expect(throws: ZenCODESetupError.self) {
            try Runner.runDataExportCleanupStep(
                supportDirectoryURL: fixture.supportURL,
                write: { output += $0 },
                selectGroups: { Set($0.map(\.value)) },
                confirmDeletion: {
                    confirmations += 1
                    throw ZenCODESetupError.cancelled
                }
            )
        }

        #expect(Self.isCancelled(error))
        #expect(confirmations == 1)
        #expect(Self.missingPopulatedPaths(fixture).isEmpty)
        #expect(output.contains("Total: "))
        #expect(!output.contains("Freed "))
        #expect(!output.contains("Cleanup cancelled"))
        #expect(!output.contains("Cleanup skipped"))
    }

    @Test
    func exportStepNoSkipsTheCleanupAndContinues() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        var output = ""

        try Runner.runDataExportCleanupStep(
            supportDirectoryURL: fixture.supportURL,
            write: { output += $0 },
            selectGroups: { Set($0.map(\.value)) },
            confirmDeletion: { false }
        )

        #expect(Self.missingPopulatedPaths(fixture).isEmpty)
        #expect(output.contains("Total: "))
        #expect(output.hasSuffix("\n\nCleanup skipped: nothing was deleted.\n\n"))
        #expect(!output.contains("Cleanup cancelled"))
        #expect(!output.contains("Freed "))
    }

    @Test
    func exportStepYesDeletesTheSelectedGroupsAndContinues() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        var output = ""
        var confirmations = 0

        try Runner.runDataExportCleanupStep(
            supportDirectoryURL: fixture.supportURL,
            write: { output += $0 },
            selectGroups: { Set($0.map(\.value)).subtracting([.browserModel]) },
            confirmDeletion: {
                confirmations += 1
                return true
            }
        )

        #expect(confirmations == 1)
        let expected = fixture.expectedPaths()
        for path in expected[.browserModel]! {
            #expect(FileManager.default.fileExists(atPath: path), "\(path)")
        }
        for (group, paths) in expected where group != .browserModel {
            for path in paths {
                #expect(!FileManager.default.fileExists(atPath: path), "\(path)")
            }
        }
        for protected in Fixture.protectedPaths {
            #expect(fixture.exists(protected), "\(protected)")
        }
        #expect(fixture.inventory().map(\.group) == [.browserModel])
        #expect(output.contains("Freed "))
        #expect(!output.contains("Not deleted:"))
        #expect(!output.contains("Cleanup skipped"))
        #expect(!output.contains("Cleanup cancelled"))
    }

    @Test
    func exportStepShowsTheFailuresAndContinues() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("features/alpha/.build/repositories/dep/HEAD")
        try fixture.file("features/alpha/.build/checkouts/dep/Package.swift")
        var output = ""

        try Runner.runDataExportCleanupStep(
            supportDirectoryURL: fixture.supportURL,
            write: { output += $0 },
            selectGroups: { Set($0.map(\.value)) },
            confirmDeletion: {
                // A candidate becomes a link after the inventory.
                try FileManager.default.removeItem(at: fixture.url("features/alpha/.build/checkouts"))
                try fixture.link("features/alpha/.build/checkouts", to: fixture.outsideURL.path)
                return true
            }
        )

        #expect(!fixture.exists("features/alpha/.build/repositories"))
        #expect(fixture.isLink("features/alpha/.build/checkouts"))
        #expect(output.contains("Freed "))
        #expect(output.contains("Not deleted:\n- \(fixture.path("features/alpha/.build/checkouts")): "))
    }

    @Test
    func exportStepContinuesWithoutTheBrowserGroupsWhileChromeRuns() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        try fixture.link("browser/SingletonLock", to: "my-host-\(ProcessInfo.processInfo.processIdentifier)")
        var output = ""
        var offered: [Group] = []

        try Runner.runDataExportCleanupStep(
            supportDirectoryURL: fixture.supportURL,
            write: { output += $0 },
            selectGroups: { items in
                offered = items.map(\.value)
                return Set(offered)
            },
            confirmDeletion: { true }
        )

        #expect(!offered.contains(.browserModel))
        #expect(!offered.contains(.browserCaches))
        #expect(offered.contains(.featureDependencies))
        #expect(output.contains("Skipped Browser on-device AI model"))
        #expect(output.contains("Skipped Browser caches"))
        #expect(output.contains("Freed "))
        let expected = fixture.expectedPaths()
        for path in expected[.browserModel]! + expected[.browserCaches]! {
            #expect(FileManager.default.fileExists(atPath: path), "\(path)")
        }
        #expect(!fixture.exists("features/alpha/.build/repositories"))
    }

    @Test
    func exportStepWithNothingToCleanContinuesWithoutTheMenu() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.file("settings.json")
        var output = ""
        var menus = 0
        var confirmations = 0

        try Runner.runDataExportCleanupStep(
            supportDirectoryURL: fixture.supportURL,
            write: { output += $0 },
            selectGroups: { _ in
                menus += 1
                return nil
            },
            confirmDeletion: {
                confirmations += 1
                return true
            }
        )

        #expect(menus == 0)
        #expect(confirmations == 0)
        #expect(fixture.exists("settings.json"))
        #expect(output == Self.measuringLine(fixture) + "Nothing to clean under \(fixture.supportURL.path).\n\n")
    }

    @Test
    func exportStepWithNoGroupSelectedContinuesAndDeletesNothing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.populate()
        var output = ""
        var confirmations = 0

        try Runner.runDataExportCleanupStep(
            supportDirectoryURL: fixture.supportURL,
            write: { output += $0 },
            selectGroups: { _ in [] },
            confirmDeletion: {
                confirmations += 1
                return true
            }
        )

        #expect(confirmations == 0)
        #expect(Self.missingPopulatedPaths(fixture).isEmpty)
        #expect(output == Self.measuringLine(fixture) + "No group selected.\n\n")
    }
}
