//
//  ZenAppApplicationBundle.swift
//  ZenCODE
//

#if os(macOS)
import Darwin
import Foundation

/// The `ZenCODE.app` bundle that `zen --ui` adds to `/Applications`, so that
/// the app also opens from the Finder, Launchpad, Spotlight and the Dock.
///
/// It is a self-contained copy of the installed app (`<support>/app/current`),
/// assembled after every build (first use and after each ZenCODE update), so
/// that it never opens an older app than `zen --ui` does:
///
/// - `Contents/MacOS/ZenCODE`: the installed executable;
/// - `Contents/Resources/*.bundle`: its resource bundles, where the
///   `Bundle.module` accessors of SwiftPM look first inside an app;
/// - `Contents/Resources/ZenCODE.icns`: the icon, written by the app itself
///   (`writeIconOption`) from the drawing of its Dock icon;
/// - `Contents/Info.plist` (`applicationBundleInfo`).
///
/// The bundle is signed ad hoc (`codesign --force --sign -`): the linker
/// signature of the executable does not cover a bundle, which would otherwise
/// be invalid. It is assembled in a `.staging-` directory of `<support>/app`
/// (removed by `removeInstallLeftovers` if an install is interrupted), then
/// moved into place; a bundle already there is replaced only when it has the
/// identifier of this one. Opened from the bundle, the app has no working
/// directory, so it asks for the workspace folder (see
/// `ZenAppLaunchArguments.asksForWorkspace` of the app package).
extension ZenAppInstallation {
    /// The name of the bundle in the applications directory.
    static let applicationBundleName = "ZenCODE.app"
    /// `CFBundleIdentifier` of the bundle: a bundle with another identifier is
    /// never replaced.
    static let applicationBundleIdentifier = "com.zencode.app"
    /// `CFBundleIconFile` of the bundle, and the name of its icon file.
    static let applicationIconName = "ZenCODE"
    static let applicationIconFileName = "ZenCODE.icns"
    /// The option that makes the app executable write the icon of the bundle
    /// to the path that follows it, then exit. Keep in sync with
    /// `ZenAppIconExport.option` of the app package
    /// (`Sources/ZenApp/Sources/ZenCODEApp/ZenAppIconExport.swift`).
    static let writeIconOption = "--write-app-icon"
    /// `LSMinimumSystemVersion`: the platform of the app package.
    static let applicationMinimumSystemVersion = "26.0"
    /// Where the bundle is added.
    static let defaultApplicationsDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)
    static let codesignExecutablePath = "/usr/bin/codesign"
    /// How long writing the icon and signing the bundle may take.
    static let applicationIconTimeout: TimeInterval = 60
    static let applicationSigningTimeout: TimeInterval = 120

    /// Why the bundle was not added to the applications directory. `zen --ui`
    /// reports it as a warning and starts the installed app all the same.
    enum ApplicationBundleError: LocalizedError, Equatable {
        case foreignBundle(path: String)
        case assemblyFailed(directory: String, reason: String)
        case signingFailed(directory: String, reason: String)
        case placementFailed(path: String, reason: String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case let .foreignBundle(path):
                return "ZenCODE.app was not added to \(Self.parent(of: path)): \(path) is not the app that "
                    + "zen --ui installs (bundle identifier \(applicationBundleIdentifier)), so it was left as it is."
            case let .assemblyFailed(directory, reason):
                return "ZenCODE.app was not added to \(directory): it could not be assembled (\(reason))."
            case let .signingFailed(directory, reason):
                return "ZenCODE.app was not added to \(directory): it could not be signed (\(reason))."
            case let .placementFailed(path, reason):
                return "ZenCODE.app was not added to \(Self.parent(of: path)): it could not be moved to \(path) (\(reason))."
            case let .commandFailed(detail):
                return detail
            }
        }

        private static func parent(of path: String) -> String {
            URL(fileURLWithPath: path).deletingLastPathComponent().path
        }
    }

    /// What `installApplicationBundle` did.
    struct ApplicationBundleInstall: Equatable, Sendable {
        /// Whether a bundle of an earlier build was replaced.
        var replaced: Bool
        /// Why the icon could not be written, if it could not: the bundle then
        /// has the generic icon.
        var iconFailure: String?
    }

    /// The applications directory the bundle is added to: `applications` when
    /// `supportDirectory` is the default `~/.zencode`, `nil` otherwise. The
    /// Finder starts the bundle without `ZENCODE_SUPPORT_DIRECTORY`, so it
    /// reads `~/.zencode`: a `zen --ui` that works on another support
    /// directory does not replace it.
    static func applicationsDirectory(
        supportDirectory: URL,
        defaultSupportDirectory: URL,
        applications: URL = defaultApplicationsDirectory
    ) -> URL? {
        func resolved(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        return resolved(supportDirectory) == resolved(defaultSupportDirectory) ? applications : nil
    }

    /// The `Info.plist` of the bundle, for the ZenCODE `version`; with
    /// `hasIcon`, it names the icon file.
    ///
    /// The usage descriptions are those of voice mode, which records the
    /// microphone and transcribes it: opened from the bundle, the app is the
    /// process that macOS asks the permissions for (started by `zen --ui`,
    /// the terminal is), and macOS stops an app that asks for them without
    /// describing their use.
    static func applicationBundleInfo(version: String, hasIcon: Bool) -> [String: Any] {
        var info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": "ZenCODE",
            "CFBundleExecutable": productName,
            "CFBundleIdentifier": applicationBundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "ZenCODE",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "LSApplicationCategoryType": "public.app-category.developer-tools",
            "LSMinimumSystemVersion": applicationMinimumSystemVersion,
            "NSHighResolutionCapable": true,
            "NSMicrophoneUsageDescription": "ZenCODE listens to the microphone in voice mode.",
            "NSPrincipalClass": "NSApplication",
            "NSSpeechRecognitionUsageDescription": "ZenCODE turns what you say into text in voice mode."
        ]
        if hasIcon {
            info["CFBundleIconFile"] = applicationIconName
        }
        return info
    }

    /// The `CFBundleIdentifier` of the bundle at `bundle`; `nil` when it has
    /// no readable `Contents/Info.plist` or no identifier.
    static func bundleIdentifier(ofApplicationAt bundle: URL) -> String? {
        let infoFile = bundle.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoFile),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return info["CFBundleIdentifier"] as? String
    }

    /// Assembles the bundle from the installed app in `current`, signs it and
    /// moves it to `destination` (`<applications>/ZenCODE.app`), replacing
    /// the bundle of an earlier build.
    ///
    /// `writeIcon` writes the icon file it is given; when it fails, the bundle
    /// is installed without an icon and the failure is returned. `sign` signs
    /// the bundle it is given, in place.
    ///
    /// - Throws: `ApplicationBundleError.foreignBundle` when `destination` is
    ///   not a bundle with ``applicationBundleIdentifier`` (a symbolic link
    ///   included), and the other `ApplicationBundleError`s when the bundle
    ///   cannot be assembled, signed or moved. Nothing is left in the staging
    ///   directory, and a replaced bundle is put back when the new one cannot
    ///   be moved in.
    @discardableResult
    static func installApplicationBundle(
        from current: URL,
        to destination: URL,
        layout: Layout,
        version: String,
        writeIcon: (_ icon: URL) async throws -> Void,
        sign: (_ bundle: URL) async throws -> Void,
        fileManager: FileManager = .default
    ) async throws -> ApplicationBundleInstall {
        let applications = destination.deletingLastPathComponent().path
        // `attributesOfItem` does not follow a final symbolic link: a link is
        // not a directory, so it is never replaced.
        let existing = try? fileManager.attributesOfItem(atPath: destination.path)
        if let existing {
            guard existing[.type] as? FileAttributeType == .typeDirectory,
                  bundleIdentifier(ofApplicationAt: destination) == applicationBundleIdentifier else {
                throw ApplicationBundleError.foreignBundle(path: destination.path)
            }
        }

        let staging = layout.appDirectory.appendingPathComponent(
            "\(stagingDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        let bundle = staging.appendingPathComponent(applicationBundleName, isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let executables = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)

        do {
            try fileManager.createDirectory(at: executables, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
            try fileManager.copyItem(
                at: current.appendingPathComponent(productName, isDirectory: false).resolvingSymlinksInPath(),
                to: executables.appendingPathComponent(productName, isDirectory: false)
            )
            let bundleNames = try fileManager
                .contentsOfDirectory(atPath: current.path)
                .filter { $0.hasSuffix(".bundle") }
                .sorted()
            for name in bundleNames {
                try fileManager.copyItem(
                    at: current.appendingPathComponent(name).resolvingSymlinksInPath(),
                    to: resources.appendingPathComponent(name)
                )
            }
        } catch {
            throw ApplicationBundleError.assemblyFailed(directory: applications, reason: error.localizedDescription)
        }

        let icon = resources.appendingPathComponent(applicationIconFileName, isDirectory: false)
        var iconFailure: String?
        do {
            try await writeIcon(icon)
            if !fileManager.fileExists(atPath: icon.path) {
                iconFailure = "no icon was written"
            }
        } catch {
            iconFailure = error.localizedDescription
        }
        if iconFailure != nil {
            try? fileManager.removeItem(at: icon)
        }

        do {
            let info = applicationBundleInfo(version: version, hasIcon: iconFailure == nil)
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist", isDirectory: false), options: .atomic)
        } catch {
            throw ApplicationBundleError.assemblyFailed(directory: applications, reason: error.localizedDescription)
        }

        do {
            try await sign(bundle)
        } catch {
            throw ApplicationBundleError.signingFailed(directory: applications, reason: error.localizedDescription)
        }

        let previous = layout.appDirectory.appendingPathComponent(
            "\(previousDirectoryPrefix)\(UUID().uuidString)",
            isDirectory: true
        )
        let replaced = existing != nil
        if replaced {
            do {
                try fileManager.moveItem(at: destination, to: previous)
            } catch {
                throw ApplicationBundleError.placementFailed(path: destination.path, reason: error.localizedDescription)
            }
        }
        do {
            try fileManager.moveItem(at: bundle, to: destination)
        } catch {
            if replaced {
                try? fileManager.moveItem(at: previous, to: destination)
            }
            throw ApplicationBundleError.placementFailed(path: destination.path, reason: error.localizedDescription)
        }
        if replaced {
            try? fileManager.removeItem(at: previous)
        }
        return ApplicationBundleInstall(replaced: replaced, iconFailure: iconFailure)
    }

    // MARK: - Commands

    /// Runs the installed app `executable` with `--write-app-icon <icon>`.
    static func writeApplicationIcon(executable: URL, icon: URL) async throws {
        let result = try await AsyncProcessRunner.run(
            executableURL: executable,
            arguments: [writeIconOption, icon.path],
            timeout: applicationIconTimeout
        )
        try checkCommand(
            "\(executable.lastPathComponent) \(writeIconOption)",
            result: result,
            timeout: applicationIconTimeout
        )
    }

    /// Signs `bundle` ad hoc with `codesign --force --sign -`.
    static func signApplicationBundle(_ bundle: URL) async throws {
        let result = try await AsyncProcessRunner.run(
            executableURL: URL(fileURLWithPath: codesignExecutablePath, isDirectory: false),
            arguments: ["--force", "--sign", "-", bundle.path],
            timeout: applicationSigningTimeout
        )
        try checkCommand("codesign", result: result, timeout: applicationSigningTimeout)
    }

    private static func checkCommand(
        _ command: String,
        result: AsyncProcessResult,
        timeout: TimeInterval
    ) throws {
        if result.timedOut {
            throw ApplicationBundleError.commandFailed("\(command) did not finish within \(Int(timeout)) seconds")
        }
        guard result.exitCode == 0 else {
            let output = usefulOutput(
                SwiftRunResult(exitCode: result.exitCode, timedOut: false, stdout: result.stdout, stderr: result.stderr),
                lineLimit: 5
            )
            let summary = "\(command) exited with status \(result.exitCode)"
            throw ApplicationBundleError.commandFailed(output.isEmpty ? summary : "\(summary): \(output)")
        }
    }
}
#endif
