//
//  ZenAppInstallation.swift
//  ZenCODE
//

#if os(macOS)
import Darwin
import Foundation
import ZenPackageMetadata

/// Where the ZenCODE macOS app lives and how `zen --ui` builds and installs it.
///
/// The app is the standalone SwiftPM package `Sources/ZenApp` of the source
/// checkout. Core knows it only by its package path, its product name and its
/// install location, as it knows ZenCRON: the root graph has no build
/// dependency on it. Under the support directory:
///
/// - `app/build`: the SwiftPM scratch path, kept so that rebuilds are
///   incremental;
/// - `app/current`: the installed `ZenCODE` executable, every `*.bundle` of the
///   build directory (the resource bundles it loads from next to itself), and
///   `build-stamp.json`;
/// - `app/ZenCODE.log`: the standard output and error of the last started app;
/// - `app/.install.lock`: the lock a `zen --ui` holds while it decides, builds
///   and installs, so that two runs started together build once.
///
/// The app is rebuilt when the installed executable or its stamp is missing,
/// or when the stamp differs from the running `zen` (`decision`): first use,
/// and after every ZenCODE update.
enum ZenAppInstallation {
    /// Package directory relative to the root of the ZenCODE source checkout.
    static let packageRelativePath = "Sources/ZenApp"

    /// The SwiftPM product, and the file name of the installed executable.
    static let productName = "ZenCODE"

    /// Directory of the support directory that holds everything of the app.
    static let appDirectoryName = "app"
    static let buildDirectoryName = "build"
    static let currentDirectoryName = "current"
    static let stampFileName = "build-stamp.json"
    static let logFileName = "ZenCODE.log"
    static let installLockFileName = ".install.lock"
    /// Prefixes of the directories `install` creates next to `current`.
    static let stagingDirectoryPrefix = ".staging-"
    static let previousDirectoryPrefix = ".previous-"

    /// How long the release build may take.
    static let defaultBuildTimeout: TimeInterval = 30 * 60
    /// How long `swift build --show-bin-path` may take.
    static let binPathTimeout: TimeInterval = 5 * 60
    /// Seconds between two "Still building" lines.
    static let buildProgressIntervalSeconds = 15
    /// Lines of build output shown when the build fails.
    static let buildOutputLineLimit = 40

    // MARK: - Layout

    /// The locations of the app under one support directory.
    struct Layout: Equatable, Sendable {
        /// `<support>/app`.
        let appDirectory: URL

        init(supportDirectory: URL = AppStorageDirectory.appSupportDirectoryURL()) {
            appDirectory = supportDirectory
                .appendingPathComponent(ZenAppInstallation.appDirectoryName, isDirectory: true)
        }

        /// `<support>/app/build`, the SwiftPM scratch path.
        var buildDirectory: URL {
            appDirectory.appendingPathComponent(ZenAppInstallation.buildDirectoryName, isDirectory: true)
        }

        /// `<support>/app/current`, the installed app.
        var currentDirectory: URL {
            appDirectory.appendingPathComponent(ZenAppInstallation.currentDirectoryName, isDirectory: true)
        }

        /// `<support>/app/current/ZenCODE`.
        var installedExecutable: URL {
            currentDirectory.appendingPathComponent(ZenAppInstallation.productName, isDirectory: false)
        }

        /// `<support>/app/current/build-stamp.json`.
        var stampFile: URL {
            currentDirectory.appendingPathComponent(ZenAppInstallation.stampFileName, isDirectory: false)
        }

        /// `<support>/app/ZenCODE.log`.
        var logFile: URL {
            appDirectory.appendingPathComponent(ZenAppInstallation.logFileName, isDirectory: false)
        }

        /// `<support>/app/.install.lock`.
        var installLockFile: URL {
            appDirectory.appendingPathComponent(ZenAppInstallation.installLockFileName, isDirectory: false)
        }
    }

    // MARK: - Errors

    /// Why the app could not be found, built or installed.
    enum InstallationError: LocalizedError, Equatable {
        case sourceNotFound(searchedCheckouts: [String])
        case zenExecutableUnreadable(String)
        case swiftUnavailable(String)
        case buildTimedOut(seconds: Int, output: String)
        case buildFailed(status: Int32, output: String)
        case binPathUnavailable(String)
        case productMissing(path: String)
        case installFailed(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case let .sourceNotFound(checkouts):
                return "The ZenCODE app cannot be built: no ZenCODE source checkout with "
                    + "\(packageRelativePath)/Package.swift was found (searched: "
                    + "\(checkouts.joined(separator: ", "))). Reinstall ZenCODE with Scripts/install.sh, "
                    + "or run a zen built from a ZenCODE checkout."
            case let .zenExecutableUnreadable(reason):
                return "The ZenCODE app cannot be prepared: the running zen executable cannot be read (\(reason))."
            case let .swiftUnavailable(reason):
                return "The ZenCODE app cannot be built: swift could not be run (\(reason)). "
                    + "Building it needs the Swift toolchain."
            case let .buildTimedOut(seconds, output):
                return Self.withOutput(
                    "The ZenCODE app could not be built: swift build did not finish within \(seconds) seconds.",
                    output
                )
            case let .buildFailed(status, output):
                return Self.withOutput(
                    "The ZenCODE app could not be built: swift build exited with status \(status).",
                    output
                )
            case let .binPathUnavailable(detail):
                return "The ZenCODE app was built, but swift build --show-bin-path did not report "
                    + "the build directory: \(detail)"
            case let .productMissing(path):
                return "The ZenCODE app was built, but the executable \(path) was not produced."
            case let .installFailed(path, reason):
                return "Could not install the ZenCODE app in \(path): \(reason)"
            }
        }

        private static func withOutput(_ summary: String, _ output: String) -> String {
            output.isEmpty ? summary : "\(summary)\n\(output)"
        }
    }

    // MARK: - Source

    /// The checkouts searched for the package, in order: the checkout this
    /// `zen` was built from, then the installer copy (`~/.zencode/source`).
    /// The current directory is deliberately not a candidate.
    static func defaultSourceCheckouts(fileManager: FileManager = .default) -> [URL] {
        [
            SwiftFeatureRuntime.sourcePackageRootURL(fileManager: fileManager),
            SwiftFeatureRuntime.supportSourceCheckoutURL(fileManager: fileManager)
        ].compactMap { $0?.standardizedFileURL }
    }

    /// `<checkout>/Sources/ZenApp` of the first checkout that has
    /// `Sources/ZenApp/Package.swift`.
    static func sourcePackageURL(
        checkouts: [URL],
        fileManager: FileManager = .default
    ) throws -> URL {
        for checkout in checkouts {
            let package = checkout.appendingPathComponent(packageRelativePath, isDirectory: true)
            if fileManager.fileExists(atPath: package.appendingPathComponent("Package.swift").path) {
                return package.standardizedFileURL
            }
        }
        throw InstallationError.sourceNotFound(searchedCheckouts: checkouts.map(\.path))
    }

    // MARK: - Stamp

    /// What the installed app was built for. A different stamp means a new
    /// ZenCODE (or another source checkout), so the app is rebuilt.
    struct BuildStamp: Codable, Equatable, Sendable {
        /// `ZenPackageMetadata.version` of the `zen` that built it.
        var zenVersion: String
        /// The `zen` executable, symlinks resolved.
        var zenExecutablePath: String
        /// Its modification date, in whole seconds.
        var zenExecutableModificationDate: Date
        /// Its size in bytes.
        var zenExecutableSize: UInt64
        /// The package that was built (`<checkout>/Sources/ZenApp`).
        var sourcePackagePath: String

        /// The stamp of `zenExecutable` building `sourcePackage` now.
        static func current(
            zenExecutable: URL,
            sourcePackage: URL,
            zenVersion: String = ZenPackageMetadata.version,
            fileManager: FileManager = .default
        ) throws -> BuildStamp {
            let resolved = zenExecutable.standardizedFileURL.resolvingSymlinksInPath()
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: resolved.path)
            } catch {
                throw InstallationError.zenExecutableUnreadable("\(resolved.path): \(error.localizedDescription)")
            }
            guard let modificationDate = attributes[.modificationDate] as? Date,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else {
                throw InstallationError.zenExecutableUnreadable("\(resolved.path) has no modification date or size")
            }
            return BuildStamp(
                zenVersion: zenVersion,
                zenExecutablePath: resolved.path,
                zenExecutableModificationDate: Date(
                    timeIntervalSince1970: modificationDate.timeIntervalSince1970.rounded(.down)
                ),
                zenExecutableSize: size,
                sourcePackagePath: sourcePackage.standardizedFileURL.path
            )
        }
    }

    /// The running `zen` executable, as the system reports it:
    /// `BuildStamp.current` resolves its symbolic links.
    static func runningZenExecutableURL() throws -> URL {
        guard let executable = Bundle.main.executableURL else {
            throw InstallationError.zenExecutableUnreadable("its path is unknown")
        }
        return executable.standardizedFileURL
    }

    static func encodedStamp(_ stamp: BuildStamp) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(stamp)
    }

    /// The stamp at `url`; `nil` when it is missing or unreadable.
    static func readStamp(at url: URL) -> BuildStamp? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BuildStamp.self, from: data)
    }

    // MARK: - Decision

    /// Whether `zen --ui` builds the app before starting it.
    enum Decision: Equatable, Sendable {
        /// The installed app matches the running `zen`: start it as it is.
        case launchInstalled
        /// Build and install the app first.
        case build
    }

    /// Build when the installed executable is missing or not executable, when
    /// its stamp is missing or unreadable (`nil`), or when the stamp differs
    /// from the current one. Pure, so every case is testable.
    static func decision(
        installedExecutableIsRunnable: Bool,
        installedStamp: BuildStamp?,
        currentStamp: BuildStamp
    ) -> Decision {
        guard installedExecutableIsRunnable, installedStamp == currentStamp else {
            return .build
        }
        return .launchInstalled
    }

    /// The decision for the app installed in `layout`.
    static func decision(
        layout: Layout,
        currentStamp: BuildStamp,
        fileManager: FileManager = .default
    ) -> Decision {
        decision(
            installedExecutableIsRunnable: fileManager.isExecutableFile(atPath: layout.installedExecutable.path),
            installedStamp: readStamp(at: layout.stampFile),
            currentStamp: currentStamp
        )
    }

    // MARK: - Build

    /// The outcome of one `swift` run.
    struct SwiftRunResult: Equatable, Sendable {
        let exitCode: Int32
        let timedOut: Bool
        let stdout: String
        let stderr: String
    }

    /// `swift build -c release --package-path <package> --scratch-path
    /// <support>/app/build --product ZenCODE`.
    static func buildArguments(sourcePackage: URL, layout: Layout) -> [String] {
        [
            "build", "-c", "release",
            "--package-path", sourcePackage.path,
            "--scratch-path", layout.buildDirectory.path,
            "--product", productName
        ]
    }

    /// The same build, asked for its bin directory.
    static func binPathArguments(sourcePackage: URL, layout: Layout) -> [String] {
        [
            "build", "-c", "release",
            "--package-path", sourcePackage.path,
            "--scratch-path", layout.buildDirectory.path,
            "--show-bin-path"
        ]
    }

    /// The last `lineLimit` lines of the standard output and error of a run
    /// (SwiftPM prints the compiler errors on standard output).
    static func usefulOutput(
        _ result: SwiftRunResult,
        lineLimit: Int = buildOutputLineLimit
    ) -> String {
        let text = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return lastLines(of: text, limit: lineLimit)
    }

    /// The last `limit` lines of `text`, without the white space around them.
    static func lastLines(of text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            .components(separatedBy: .newlines)
            .suffix(limit)
            .joined(separator: "\n")
    }

    /// The bin directory printed by `--show-bin-path`: the last non-empty line
    /// of its standard output, when it is an absolute path.
    static func binDirectory(fromShowBinPathOutput output: String) -> URL? {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let path = lines.last, path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    // MARK: - Lock

    /// Takes the exclusive lock of `<support>/app/.install.lock`, waiting for
    /// the `zen --ui` that holds it, and returns its descriptor for
    /// `releaseInstallLock`. The descriptor is close-on-exec, so neither
    /// `swift` nor the app inherits it. The wait runs on a dispatch thread,
    /// off the cooperative pool.
    static func acquireInstallLock(
        layout: Layout,
        fileManager: FileManager = .default
    ) async throws -> Int32 {
        let lockFile = layout.installLockFile
        func failure(_ reason: String) -> InstallationError {
            .installFailed(
                path: layout.currentDirectory.path,
                reason: "the lock \(lockFile.path) cannot be taken: \(reason)"
            )
        }
        do {
            try fileManager.createDirectory(at: layout.appDirectory, withIntermediateDirectories: true)
        } catch {
            throw failure(error.localizedDescription)
        }
        let descriptor = open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw failure(String(cString: strerror(errno)))
        }
        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var status: Int32 = 0
                repeat {
                    status = flock(descriptor, LOCK_EX) == 0 ? 0 : errno
                } while status == EINTR
                continuation.resume(returning: status)
            }
        }
        guard status == 0 else {
            _ = close(descriptor)
            throw failure(String(cString: strerror(status)))
        }
        return descriptor
    }

    /// Releases a lock of `acquireInstallLock`.
    static func releaseInstallLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    /// Removes the staging and previous directories that an interrupted
    /// `install` left in `<support>/app`. Only under the install lock, when
    /// no other install can be using them.
    static func removeInstallLeftovers(layout: Layout, fileManager: FileManager = .default) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: layout.appDirectory.path) else {
            return
        }
        for name in names where name.hasPrefix(stagingDirectoryPrefix) || name.hasPrefix(previousDirectoryPrefix) {
            try? fileManager.removeItem(at: layout.appDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - Install

    /// Installs the build of `binDirectory` as `<support>/app/current` and
    /// returns the installed executable.
    ///
    /// `ZenCODE` and every `*.bundle` of the bin directory are copied (each
    /// item with its symbolic links resolved, directories whole) into a hidden
    /// staging directory next to `current`, with `stamp`; then the staging
    /// directory replaces `current`: the old one is renamed aside, the staging
    /// one renamed in, and the old one removed. The staging directory is
    /// removed on every failure, and the old `current` is put back when the
    /// new one cannot be renamed in.
    @discardableResult
    static func install(
        binDirectory: URL,
        stamp: BuildStamp,
        layout: Layout,
        fileManager: FileManager = .default
    ) throws -> URL {
        let builtExecutable = binDirectory
            .appendingPathComponent(productName, isDirectory: false)
            .resolvingSymlinksInPath()
        guard fileManager.isExecutableFile(atPath: builtExecutable.path) else {
            throw InstallationError.productMissing(
                path: binDirectory.appendingPathComponent(productName, isDirectory: false).path
            )
        }
        let current = layout.currentDirectory
        func failure(_ reason: String) -> InstallationError {
            .installFailed(path: current.path, reason: reason)
        }

        let staging = layout.appDirectory.appendingPathComponent(
            "\(stagingDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        var stagingPublished = false
        defer {
            if !stagingPublished {
                try? fileManager.removeItem(at: staging)
            }
        }

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try fileManager.copyItem(
                at: builtExecutable,
                to: staging.appendingPathComponent(productName, isDirectory: false)
            )
            let bundleNames = try fileManager
                .contentsOfDirectory(atPath: binDirectory.path)
                .filter { $0.hasSuffix(".bundle") }
                .sorted()
            for name in bundleNames {
                try fileManager.copyItem(
                    at: binDirectory.appendingPathComponent(name).resolvingSymlinksInPath(),
                    to: staging.appendingPathComponent(name)
                )
            }
            try encodedStamp(stamp).write(
                to: staging.appendingPathComponent(stampFileName, isDirectory: false),
                options: .atomic
            )
        } catch {
            throw failure(error.localizedDescription)
        }

        // `attributesOfItem` does not follow a final symbolic link, so even a
        // dangling `current` link is moved aside.
        let hadCurrent = (try? fileManager.attributesOfItem(atPath: current.path)) != nil
        let previous = layout.appDirectory.appendingPathComponent(
            "\(previousDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        if hadCurrent {
            guard rename(current.path, previous.path) == 0 else {
                throw failure("\(current.path) cannot be moved aside: \(String(cString: strerror(errno)))")
            }
        }
        guard rename(staging.path, current.path) == 0 else {
            let reason = String(cString: strerror(errno))
            if hadCurrent {
                _ = rename(previous.path, current.path)
            }
            throw failure(reason)
        }
        stagingPublished = true
        if hadCurrent {
            try? fileManager.removeItem(at: previous)
        }

        let installed = layout.installedExecutable
        guard fileManager.isExecutableFile(atPath: installed.path) else {
            throw failure("the installed \(installed.path) is not executable")
        }
        return installed
    }
}
#endif
