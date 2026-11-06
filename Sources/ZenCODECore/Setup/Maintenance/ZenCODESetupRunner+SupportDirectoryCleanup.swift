//
//  ZenCODESetupRunner+SupportDirectoryCleanup.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/11/26.
//
//  Setup › Data management › Clean support directory: free disk space in the
//  support directory by deleting only data that is regenerated when needed
//  (the browser's on-device AI model and caches, the dependency downloads and
//  intermediate build files of the installed features, and the build
//  directories of the macOS app and of ZenCRON), after an explicit
//  confirmation.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The support directory cleanup flow of the data management submenu.
///
/// Every path is derived from the support directory passed in, never from the
/// environment, so tests run on a temporary directory. The inventory, the menu
/// builder, the renderers and ``applySupportDirectoryCleanup(_:supportDirectoryURL:fileManager:)``
/// are pure of terminal I/O; the interactive flow only wires them to prompts.
/// Only the exact listed paths are removed: a candidate is skipped when it is
/// not a strict descendant of the support directory or when it, or any
/// directory between it and the support directory, is a symbolic link.
extension ZenCODESetupRunner {
    /// One kind of regenerable data, in menu order.
    enum SupportCleanupGroup: Int, CaseIterable, Hashable, Sendable {
        case browserModel
        case browserCaches
        case featureDependencies
        case featureIntermediates
        case appBuild
        case zencronBuild

        var title: String {
            switch self {
            case .browserModel: "Browser on-device AI model"
            case .browserCaches: "Browser caches"
            case .featureDependencies: "Feature dependency downloads"
            case .featureIntermediates: "Feature intermediate build files"
            case .appBuild: "App build directory"
            case .zencronBuild: "ZenCRON build directory"
            }
        }

        var detail: String {
            switch self {
            case .browserModel:
                "Chrome downloads it again when needed (Gemini Nano, ~4 GB)"
            case .browserCaches:
                "HTTP, code, GPU and shader caches of the browser profile; cookies, logins and settings are kept"
            case .featureDependencies:
                "package repositories and checkouts of the installed features; downloaded again on the next feature update"
            case .featureIntermediates:
                "intermediate build files of the installed features; the built executables are kept"
            case .appBuild:
                "app/build, the macOS app build cache; the installed app (app/current) is kept"
            case .zencronBuild:
                "zencron/package/.build; the installed bin/ZenCRON is kept"
            }
        }

        /// Groups inside the Chrome profile, skipped while Chrome uses it.
        var usesBrowserProfile: Bool {
            self == .browserModel || self == .browserCaches
        }
    }

    /// One path to delete and the bytes it occupies.
    struct SupportCleanupItem: Hashable, Sendable {
        let url: URL
        let bytes: Int64
    }

    /// The paths of one group found under the support directory.
    struct SupportCleanupGroupInventory: Hashable, Sendable {
        let group: SupportCleanupGroup
        let items: [SupportCleanupItem]
        /// Why the group is not offered although it has paths to delete.
        let skipReason: String?

        var totalBytes: Int64 {
            items.reduce(0) { $0 + $1.bytes }
        }
    }

    /// What ``applySupportDirectoryCleanup(_:supportDirectoryURL:fileManager:)`` did.
    struct SupportCleanupResult: Equatable, Sendable {
        struct Skip: Hashable, Sendable {
            let group: SupportCleanupGroup
            let reason: String
        }

        struct Failure: Hashable, Sendable {
            let url: URL
            let reason: String
        }

        var deleted: [SupportCleanupItem] = []
        var skipped: [Skip] = []
        var failures: [Failure] = []

        /// Bytes measured by the inventory for the deleted paths.
        var freedBytes: Int64 {
            deleted.reduce(0) { $0 + $1.bytes }
        }
    }

    /// Whether a candidate can be deleted.
    enum SupportCleanupPathCheck: Equatable, Sendable {
        case safe
        case missing
        case unsafe(String)
    }

    static let supportCleanupBrowserDirectoryName = "browser"
    /// Matches `SwiftFeatureRegistry.appFeatureRootURL`.
    static let supportCleanupFeaturesDirectoryName = "features"
    static let chromeProfileLockName = "SingletonLock"

    static let browserModelEntryNames = [
        "OptGuideOnDeviceModel",
        "OptGuideOnDeviceClassifierModel",
        "OptGuidePredictionModels",
        "optimization_guide_model_store"
    ]
    static let browserDefaultProfileCacheNames = ["Cache", "Code Cache", "GPUCache"]
    static let browserServiceWorkerCacheNames = ["CacheStorage", "ScriptCache"]
    static let browserSharedCacheNames = [
        "GrShaderCache",
        "GraphiteDawnCache",
        "ShaderCache",
        "GPUPersistentCache"
    ]

    // MARK: - Inventory

    /// The groups that have something to delete under `supportDirectoryURL`,
    /// in menu order, with the size of every path. The browser groups carry a
    /// ``SupportCleanupGroupInventory/skipReason`` while a live process holds
    /// the Chrome profile lock. Walks the listed directories, so it can take a
    /// few seconds.
    static func supportCleanupInventory(
        supportDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> [SupportCleanupGroupInventory] {
        let rootURL = supportDirectoryURL.standardizedFileURL
        let browserSkipReason = browserProfileSkipReason(
            supportDirectoryURL: rootURL,
            fileManager: fileManager
        )
        return SupportCleanupGroup.allCases.compactMap { group in
            let items = supportCleanupCandidateURLs(
                for: group,
                supportDirectoryURL: rootURL,
                fileManager: fileManager
            )
            .filter {
                supportCleanupPathCheck($0, supportDirectoryURL: rootURL, fileManager: fileManager) == .safe
            }
            .map {
                SupportCleanupItem(
                    url: $0,
                    bytes: supportCleanupAllocatedBytes(at: $0, fileManager: fileManager)
                )
            }
            guard !items.isEmpty else {
                return nil
            }
            return SupportCleanupGroupInventory(
                group: group,
                items: items,
                skipReason: group.usesBrowserProfile ? browserSkipReason : nil
            )
        }
    }

    /// The paths a group would delete, before the existence and symbolic-link
    /// checks.
    static func supportCleanupCandidateURLs(
        for group: SupportCleanupGroup,
        supportDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        let rootURL = supportDirectoryURL.standardizedFileURL
        let browserURL = rootURL.appendingPathComponent(
            supportCleanupBrowserDirectoryName,
            isDirectory: true
        )
        switch group {
        case .browserModel:
            return browserModelEntryNames.map {
                browserURL.appendingPathComponent($0, isDirectory: true)
            }
        case .browserCaches:
            let defaultURL = browserURL.appendingPathComponent("Default", isDirectory: true)
            let serviceWorkerURL = defaultURL.appendingPathComponent("Service Worker", isDirectory: true)
            return browserDefaultProfileCacheNames.map {
                defaultURL.appendingPathComponent($0, isDirectory: true)
            }
                + browserServiceWorkerCacheNames.map {
                    serviceWorkerURL.appendingPathComponent($0, isDirectory: true)
                }
                + browserSharedCacheNames.map {
                    browserURL.appendingPathComponent($0, isDirectory: true)
                }
        case .featureDependencies:
            return supportCleanupFeatureDirectories(
                supportDirectoryURL: rootURL,
                fileManager: fileManager
            ).flatMap { featureURL in
                let buildURL = featureURL.appendingPathComponent(".build", isDirectory: true)
                return [
                    buildURL.appendingPathComponent("repositories", isDirectory: true),
                    buildURL.appendingPathComponent("checkouts", isDirectory: true)
                ]
            }
        case .featureIntermediates:
            // Only the Swift Build layout keeps the products in `out/Products`
            // (where `.build/release` points); elsewhere nothing is removed.
            return supportCleanupFeatureDirectories(
                supportDirectoryURL: rootURL,
                fileManager: fileManager
            ).flatMap { featureURL -> [URL] in
                let outURL = featureURL
                    .appendingPathComponent(".build", isDirectory: true)
                    .appendingPathComponent("out", isDirectory: true)
                let productsURL = outURL.appendingPathComponent("Products", isDirectory: true)
                guard supportCleanupItemType(productsURL, fileManager: fileManager) == .typeDirectory,
                      let names = try? fileManager.contentsOfDirectory(atPath: outURL.path) else {
                    return []
                }
                return names
                    .filter { $0 != "Products" }
                    .sorted()
                    .map { outURL.appendingPathComponent($0, isDirectory: false) }
            }
        case .appBuild:
            #if os(macOS)
            return [ZenAppInstallation.Layout(supportDirectory: rootURL).buildDirectory]
            #else
            return []
            #endif
        case .zencronBuild:
            return [
                ZenCRONInstallation.workingCopyURL(supportDirectory: rootURL)
                    .appendingPathComponent(".build", isDirectory: true)
            ]
        }
    }

    /// The installed features: every real (not linked) directory under
    /// `<support>/features` whose name does not start with `.`, which
    /// excludes the install, staging and backup directories.
    private static func supportCleanupFeatureDirectories(
        supportDirectoryURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        let featuresURL = supportDirectoryURL.appendingPathComponent(
            supportCleanupFeaturesDirectoryName,
            isDirectory: true
        )
        guard let names = try? fileManager.contentsOfDirectory(atPath: featuresURL.path) else {
            return []
        }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { featuresURL.appendingPathComponent($0, isDirectory: true) }
            .filter { supportCleanupItemType($0, fileManager: fileManager) == .typeDirectory }
    }

    // MARK: - Path safety and sizes

    /// `.safe` when `url` is a strict descendant of `supportDirectoryURL`
    /// that exists and is reached without any symbolic link: neither the
    /// path itself nor a directory between it and the support directory is a
    /// link. Nothing is resolved.
    static func supportCleanupPathCheck(
        _ url: URL,
        supportDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> SupportCleanupPathCheck {
        let rootPath = supportDirectoryURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix), path.count > prefix.count else {
            return .unsafe("outside the support directory \(rootPath)")
        }
        var currentPath = String(prefix.dropLast())
        for component in path.dropFirst(prefix.count).split(separator: "/") {
            currentPath += "/" + component
            guard let attributes = try? fileManager.attributesOfItem(atPath: currentPath),
                  let type = attributes[.type] as? FileAttributeType else {
                return .missing
            }
            if type == .typeSymbolicLink {
                return .unsafe("\(currentPath) is a symbolic link; left in place")
            }
        }
        return .safe
    }

    /// The type of the item itself, without following a final link.
    private static func supportCleanupItemType(
        _ url: URL,
        fileManager: FileManager
    ) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// Disk bytes of the regular files at or under `url`, without following
    /// symbolic links: the allocated size when the file system reports it,
    /// otherwise the logical size.
    static func supportCleanupAllocatedBytes(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        func bytes(_ values: URLResourceValues?) -> Int64 {
            guard let values, values.isSymbolicLink != true, values.isRegularFile == true else {
                return 0
            }
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        let rootValues = try? url.resourceValues(forKeys: keys)
        guard rootValues?.isSymbolicLink != true else {
            return 0
        }
        guard rootValues?.isDirectory == true else {
            return bytes(rootValues)
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }
        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            total += bytes(try? fileURL.resourceValues(forKeys: keys))
        }
        return total
    }

    static func supportCleanupByteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Chrome profile lock

    /// The live process that owns `<profile>/SingletonLock`, if any. Chrome
    /// stores the owner as the `hostname-pid` target of that symbolic link.
    static func chromeProfileLockOwnerPID(
        profileDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> Int32? {
        let lockPath = profileDirectoryURL
            .appendingPathComponent(chromeProfileLockName, isDirectory: false)
            .path
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: lockPath) else {
            return nil
        }
        return chromeProfileLockOwnerPID(lockTarget: target) { pid in
            kill(pid, 0) == 0 || errno == EPERM
        }
    }

    /// The pid after the last `-` of a lock target when it is positive and
    /// `isAlive` accepts it.
    static func chromeProfileLockOwnerPID(
        lockTarget: String,
        isAlive: (Int32) -> Bool
    ) -> Int32? {
        guard let separator = lockTarget.lastIndex(of: "-"),
              let pid = Int32(lockTarget[lockTarget.index(after: separator)...]),
              pid > 0,
              isAlive(pid) else {
            return nil
        }
        return pid
    }

    private static func browserProfileSkipReason(
        supportDirectoryURL: URL,
        fileManager: FileManager
    ) -> String? {
        let profileURL = supportDirectoryURL.appendingPathComponent(
            supportCleanupBrowserDirectoryName,
            isDirectory: true
        )
        guard let pid = chromeProfileLockOwnerPID(
            profileDirectoryURL: profileURL,
            fileManager: fileManager
        ) else {
            return nil
        }
        return "Chrome (pid \(pid)) is using the browser profile \(profileURL.path); close it and run the cleanup again."
    }

    // MARK: - App install lock

    #if os(macOS)
    enum SupportCleanupLockAttempt: Equatable {
        case acquired(Int32)
        case busy
        case failed(String)
    }

    /// Takes the `zen --ui` install lock without waiting. Release an
    /// acquired descriptor with `ZenAppInstallation.releaseInstallLock`.
    static func tryAcquireAppInstallLock(
        layout: ZenAppInstallation.Layout
    ) -> SupportCleanupLockAttempt {
        let descriptor = open(
            layout.installLockFile.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            return .failed(String(cString: strerror(errno)))
        }
        var status: Int32 = 0
        repeat {
            status = flock(descriptor, LOCK_EX | LOCK_NB) == 0 ? 0 : errno
        } while status == EINTR
        guard status == 0 else {
            _ = close(descriptor)
            return status == EWOULDBLOCK ? .busy : .failed(String(cString: strerror(status)))
        }
        return .acquired(descriptor)
    }
    #endif

    // MARK: - Apply

    /// Deletes the paths of `groups`. The browser groups are skipped when a
    /// live process holds the Chrome profile lock now, and the app build
    /// directory while a `zen --ui` holds its install lock (held here for
    /// the whole deletion). A path that is gone is ignored; one that became
    /// unsafe or cannot be removed is reported without stopping the others.
    static func applySupportDirectoryCleanup(
        _ groups: [SupportCleanupGroupInventory],
        supportDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> SupportCleanupResult {
        let rootURL = supportDirectoryURL.standardizedFileURL
        var result = SupportCleanupResult()
        for inventory in groups {
            if inventory.group.usesBrowserProfile,
               let reason = browserProfileSkipReason(supportDirectoryURL: rootURL, fileManager: fileManager) {
                result.skipped.append(.init(group: inventory.group, reason: reason))
                continue
            }
            #if os(macOS)
            if inventory.group == .appBuild {
                let layout = ZenAppInstallation.Layout(supportDirectory: rootURL)
                switch tryAcquireAppInstallLock(layout: layout) {
                case let .acquired(descriptor):
                    removeSupportCleanupItems(
                        inventory.items,
                        supportDirectoryURL: rootURL,
                        fileManager: fileManager,
                        into: &result
                    )
                    ZenAppInstallation.releaseInstallLock(descriptor)
                case .busy:
                    result.skipped.append(
                        .init(
                            group: inventory.group,
                            reason: "a zen --ui is installing the app (\(layout.installLockFile.path) is locked); run the cleanup again when it finishes."
                        )
                    )
                case let .failed(reason):
                    result.skipped.append(
                        .init(
                            group: inventory.group,
                            reason: "the install lock \(layout.installLockFile.path) cannot be taken: \(reason)."
                        )
                    )
                }
                continue
            }
            #endif
            removeSupportCleanupItems(
                inventory.items,
                supportDirectoryURL: rootURL,
                fileManager: fileManager,
                into: &result
            )
        }
        return result
    }

    private static func removeSupportCleanupItems(
        _ items: [SupportCleanupItem],
        supportDirectoryURL: URL,
        fileManager: FileManager,
        into result: inout SupportCleanupResult
    ) {
        for item in items {
            switch supportCleanupPathCheck(item.url, supportDirectoryURL: supportDirectoryURL, fileManager: fileManager) {
            case .missing:
                continue
            case let .unsafe(reason):
                result.failures.append(.init(url: item.url, reason: reason))
                continue
            case .safe:
                break
            }
            do {
                try fileManager.removeItem(at: item.url)
                result.deleted.append(item)
            } catch {
                result.failures.append(.init(url: item.url, reason: error.localizedDescription))
            }
        }
    }

    // MARK: - Menu and report

    /// One preselectable item per group that has something to delete and is
    /// not skipped.
    static func supportCleanupMenuItems(
        _ inventory: [SupportCleanupGroupInventory]
    ) -> [TerminalCheckboxMenuItem<SupportCleanupGroup>] {
        inventory
            .filter { $0.skipReason == nil && !$0.items.isEmpty }
            .map { group in
                TerminalCheckboxMenuItem(
                    value: group.group,
                    title: group.group.title,
                    detail: "\(supportCleanupByteString(group.totalBytes)), \(group.group.detail)"
                )
            }
    }

    /// One line per group of the inventory that is not offered, or `nil`.
    static func renderSupportCleanupSkippedGroups(
        _ inventory: [SupportCleanupGroupInventory]
    ) -> String? {
        let lines = inventory.compactMap { group in
            group.skipReason.map {
                "Skipped \(group.group.title) (\(supportCleanupByteString(group.totalBytes))): \($0)"
            }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The exact paths and sizes of the chosen groups and their total,
    /// without a trailing newline.
    static func renderSupportCleanupReport(
        _ groups: [SupportCleanupGroupInventory],
        supportDirectoryURL: URL
    ) -> String {
        var lines = ["Support directory: \(supportDirectoryURL.standardizedFileURL.path)"]
        for group in groups {
            lines.append("")
            lines.append("\(group.group.title): \(supportCleanupByteString(group.totalBytes))")
            lines += group.items.map {
                "- \($0.url.path) (\(supportCleanupByteString($0.bytes)))"
            }
        }
        lines.append("")
        lines.append("Total: \(supportCleanupByteString(groups.reduce(0) { $0 + $1.totalBytes }))")
        return lines.joined(separator: "\n")
    }

    /// Freed bytes, skipped groups and failures, without a trailing newline.
    static func renderSupportCleanupSummary(_ result: SupportCleanupResult) -> String {
        let count = result.deleted.count
        var lines = [
            "Freed \(supportCleanupByteString(result.freedBytes)) (\(count) \(count == 1 ? "path" : "paths") deleted)."
        ]
        lines += result.skipped.map { "Skipped \($0.group.title): \($0.reason)" }
        if !result.failures.isEmpty {
            lines.append("Not deleted:")
            lines += result.failures.map { "- \($0.url.path): \($0.reason)" }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Interactive flow

    /// Measures, lets the operator choose the groups, shows the exact paths
    /// and deletes them after a confirmation (default No). Cancelling any
    /// prompt leaves every file in place. No copy is kept.
    static func runSupportDirectoryCleanup(
        fileManager: FileManager = .default
    ) throws {
        let supportDirectoryURL = ZenFileService.supportDirectoryURL(fileManager: fileManager)
        AgentOutput.standardError.writeString(
            "Measuring the regenerable data under \(supportDirectoryURL.path)…\n"
        )
        let inventory = supportCleanupInventory(
            supportDirectoryURL: supportDirectoryURL,
            fileManager: fileManager
        )
        if let skipped = renderSupportCleanupSkippedGroups(inventory) {
            AgentOutput.standardError.writeString(skipped + "\n")
        }
        let items = supportCleanupMenuItems(inventory)
        guard !items.isEmpty else {
            AgentOutput.standardError.writeString(
                "Nothing to clean under \(supportDirectoryURL.path).\n\n"
            )
            return
        }

        guard let choice = TerminalCheckboxMenu.selectWithFocus(
            title: "Clean support directory",
            items: items,
            selected: Set(items.map(\.value)),
            focused: nil
        ) else {
            return
        }
        let selectedGroups = inventory.filter {
            $0.skipReason == nil && choice.selected.contains($0.group)
        }
        guard !selectedGroups.isEmpty else {
            AgentOutput.standardError.writeString("No group selected.\n\n")
            return
        }

        AgentOutput.standardError.writeString(
            "\n"
                + renderSupportCleanupReport(selectedGroups, supportDirectoryURL: supportDirectoryURL)
                + "\n\n"
        )
        let confirmed: Bool
        do {
            confirmed = try promptYesNo(
                "Delete these files?",
                defaultValue: false,
                help: "No copy is kept. Everything listed is regenerated: Chrome downloads its on-device model again and rebuilds its caches, and the features, the app and ZenCRON rebuild from scratch on their next update."
            )
        } catch ZenCODESetupError.cancelled {
            confirmed = false
        }
        guard confirmed else {
            AgentOutput.standardError.writeString("Cleanup cancelled.\n\n")
            return
        }

        let result = applySupportDirectoryCleanup(
            selectedGroups,
            supportDirectoryURL: supportDirectoryURL,
            fileManager: fileManager
        )
        AgentOutput.standardError.writeString(renderSupportCleanupSummary(result) + "\n\n")
    }
}
