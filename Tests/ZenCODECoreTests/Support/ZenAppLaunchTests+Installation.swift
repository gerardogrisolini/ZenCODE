//
//  ZenAppLaunchTests+Installation.swift
//  ZenCODECoreTests
//
//  Tests of `zen --ui` that cover the option parsing, the decision to build
//  the app, the build helpers and the installation of the app bundle.
//

#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension ZenAppLaunchTests {
    // MARK: - Parsing

    @Test
    func theOptionIsLookedForOnlyAfterTheExecutable() {
        #expect(ZenAppLaunchCommand.option == "--ui")
        #expect(ZenAppLaunchCommand.isRequested(["zen", "--ui"]))
        #expect(ZenAppLaunchCommand.isRequested(["zen", "--agent", "Developer", "--ui"]))
        #expect(!ZenAppLaunchCommand.isRequested(["zen"]))
        #expect(!ZenAppLaunchCommand.isRequested(["--ui"]))
        #expect(!ZenAppLaunchCommand.isRequested(["zen", "--acp", "-p", "hi"]))
    }

    @Test
    func theForwardedOptionsAreKeptInOrderWithoutTheRepeatedOption() throws {
        let kept = try ZenAppLaunchCommand.forwardedArguments(from: [
            "zen", "--ui",
            "--agent", "Developer",
            "--ui",
            "--model", "openrouter:openrouter/auto",
            "--skills", "all",
            "--working-directory", "/tmp/project",
            "--worktree", "feature",
            "--ui"
        ])
        #expect(kept == [
            "--agent", "Developer",
            "--model", "openrouter:openrouter/auto",
            "--skills", "all",
            "--working-directory", "/tmp/project",
            "--worktree", "feature"
        ])
        #expect(try ZenAppLaunchCommand.forwardedArguments(from: ["zen", "--ui"]).isEmpty)
    }

    @Test
    func theWorktreeIsForwardedAndItsNameValidatedFirst() {
        // Keep in sync with `ZenAppLaunchArguments.forwardedOptions` of the app.
        #expect(ZenAppLaunchCommand.forwardedOptions == [
            "--agent", "--model", "--skills", "--working-directory", "--worktree"
        ])
        #expect(Self.parsingError(["zen", "--ui", "--worktree"]) == "Missing value for --worktree.")
        #expect(Self.parsingError(["zen", "--ui", "--worktree", "a/b"]) == "Invalid value for --worktree: a/b")
    }

    @Test(arguments: [
        "-p", "--prompt", "-f", "--jsonl", "--acp", "--tui", "--telegram", "--max-tool-rounds", "--max-output-tokens"
    ])
    func theOptionsOfTheOtherModesConflict(option: String) {
        let expected = "Options --ui and \(option) cannot be combined."
        #expect(Self.parsingError(["zen", "--ui", option, "value"]) == expected)
        #expect(Self.parsingError(["zen", option, "value", "--ui"]) == expected)
    }

    // MARK: - Decision

    @Test
    func theAppIsBuiltUnlessTheInstalledOneMatchesTheRunningZen() {
        let stamp = Self.stamp()
        #expect(Installation.decision(installedExecutableIsRunnable: true, installedStamp: stamp, currentStamp: stamp) == .launchInstalled)
        #expect(Installation.decision(installedExecutableIsRunnable: false, installedStamp: stamp, currentStamp: stamp) == .build)
        #expect(Installation.decision(installedExecutableIsRunnable: true, installedStamp: nil, currentStamp: stamp) == .build)

        var changes: [Stamp] = []
        var version = stamp; version.zenVersion = "9.9.9"; changes.append(version)
        var path = stamp; path.zenExecutablePath = "/elsewhere/zen"; changes.append(path)
        var date = stamp; date.zenExecutableModificationDate.addTimeInterval(1); changes.append(date)
        var size = stamp; size.zenExecutableSize += 1; changes.append(size)
        var source = stamp; source.sourcePackagePath = "/other/Sources/ZenApp"; changes.append(source)
        for changed in changes {
            #expect(Installation.decision(installedExecutableIsRunnable: true, installedStamp: changed, currentStamp: stamp) == .build)
        }
    }

    @Test
    func theDecisionReadsTheInstalledExecutableAndItsStamp() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let layout = Installation.Layout(supportDirectory: root)
        let stamp = Self.stamp()

        #expect(Installation.decision(layout: layout, currentStamp: stamp) == .build)

        try Self.writeFile("#!/bin/sh\n", to: layout.installedExecutable, permissions: 0o755)
        #expect(Installation.decision(layout: layout, currentStamp: stamp) == .build)

        try Installation.encodedStamp(stamp).write(to: layout.stampFile)
        #expect(Installation.decision(layout: layout, currentStamp: stamp) == .launchInstalled)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: layout.installedExecutable.path)
        #expect(Installation.decision(layout: layout, currentStamp: stamp) == .build)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: layout.installedExecutable.path)
        try Self.writeFile("{ not a stamp", to: layout.stampFile)
        #expect(Installation.readStamp(at: layout.stampFile) == nil)
        #expect(Installation.decision(layout: layout, currentStamp: stamp) == .build)
    }

    @Test
    func theStampDescribesTheRunningZenThroughItsSymbolicLinks() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let zen = root.appendingPathComponent("real/zen")
        try Self.writeFile("zen-binary", to: zen, permissions: 0o755)
        let link = root.appendingPathComponent("zen-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zen)
        let package = root.appendingPathComponent("checkout/Sources/ZenApp", isDirectory: true)

        let stamp = try Stamp.current(zenExecutable: link, sourcePackage: package, zenVersion: "1.2.3")

        let modificationDate = try #require(
            FileManager.default.attributesOfItem(atPath: zen.path)[.modificationDate] as? Date
        )
        #expect(stamp.zenVersion == "1.2.3")
        #expect(stamp.zenExecutablePath == zen.resolvingSymlinksInPath().path)
        #expect(stamp.zenExecutableSize == 10)
        #expect(stamp.zenExecutableModificationDate.timeIntervalSince1970 == modificationDate.timeIntervalSince1970.rounded(.down))
        #expect(stamp.sourcePackagePath == package.standardizedFileURL.path)

        let stampFile = root.appendingPathComponent("build-stamp.json")
        try Installation.encodedStamp(stamp).write(to: stampFile)
        #expect(Installation.readStamp(at: stampFile) == stamp)
        #expect(Installation.readStamp(at: root.appendingPathComponent("missing.json")) == nil)

        #expect(throws: Installation.InstallationError.self) {
            try Stamp.current(zenExecutable: root.appendingPathComponent("missing-zen"), sourcePackage: package)
        }
    }

    // MARK: - Source checkout

    // MARK: - Build helpers

    @Test
    func theAppGetsTheWorkspaceOfZenUnlessAWorkingDirectoryIsForwarded() {
        let workspace = URL(fileURLWithPath: "/Users/me/project", isDirectory: true)
        func appArguments(_ forwarded: [String]) -> [String] {
            ZenAppLaunchCommand.appArguments(forwardedArguments: forwarded, workspace: workspace)
        }
        #expect(appArguments([]) == ["--working-directory", "/Users/me/project"])
        #expect(appArguments(["--agent", "Developer"]) == [
            "--agent", "Developer", "--working-directory", "/Users/me/project"
        ])
        #expect(appArguments(["--working-directory", "/tmp/other", "--agent", "Developer"]) == [
            "--working-directory", "/tmp/other", "--agent", "Developer"
        ])
        // A value that reads like the option is still a value.
        #expect(appArguments(["--model", "--working-directory"]) == [
            "--model", "--working-directory", "--working-directory", "/Users/me/project"
        ])
        // Only the last `--working-directory` is kept, where it is: with
        // `--worktree`, the worktree's, appended after the given one.
        #expect(appArguments([
            "--working-directory", "/tmp/repo",
            "--worktree", "feature",
            "--agent", "Developer",
            "--working-directory", "/tmp/worktrees/feature/repo"
        ]) == [
            "--worktree", "feature",
            "--agent", "Developer",
            "--working-directory", "/tmp/worktrees/feature/repo"
        ])
        #expect(appArguments([
            "--working-directory", "/tmp/a",
            "--working-directory", "/tmp/b",
            "--model", "--working-directory"
        ]) == [
            "--working-directory", "/tmp/b",
            "--model", "--working-directory"
        ])
    }

    // MARK: - Install

    @Test
    func installingReplacesCurrentWithTheExecutableAndEveryBundle() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try Self.makeFakeBuild(in: bin)
        // A bundle that is a symbolic link is installed as a directory.
        let linkedTarget = root.appendingPathComponent("elsewhere/Linked_Resources.bundle", isDirectory: true)
        try Self.writeFile("linked", to: linkedTarget.appendingPathComponent("Contents/Resources/linked.txt"))
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("Linked_Resources.bundle"),
            withDestinationURL: linkedTarget
        )
        let layout = Installation.Layout(supportDirectory: root.appendingPathComponent("support", isDirectory: true))
        try Self.writeFile("old", to: layout.currentDirectory.appendingPathComponent("stale.txt"))
        let stamp = Self.stamp()

        let installed = try Installation.install(binDirectory: bin, stamp: stamp, layout: layout)

        let fileManager = FileManager.default
        #expect(installed == layout.installedExecutable)
        #expect(fileManager.isExecutableFile(atPath: installed.path))
        #expect(try fileManager.contentsOfDirectory(atPath: layout.currentDirectory.path).sorted() == [
            "Linked_Resources.bundle", "ZenApp_ZenCODEApp.bundle", "ZenCODE", "build-stamp.json"
        ])
        let linked = layout.currentDirectory.appendingPathComponent("Linked_Resources.bundle")
        #expect(try fileManager.attributesOfItem(atPath: linked.path)[.type] as? FileAttributeType == .typeDirectory)
        #expect(try String(contentsOf: linked.appendingPathComponent("Contents/Resources/linked.txt"), encoding: .utf8) == "linked")
        #expect(try String(
            contentsOf: layout.currentDirectory.appendingPathComponent("ZenApp_ZenCODEApp.bundle/Contents/Resources/icon.svg"),
            encoding: .utf8
        ) == "<svg/>")
        #expect(Installation.readStamp(at: layout.stampFile) == stamp)
        // Neither the staging directory nor the previous `current` is left.
        #expect(try fileManager.contentsOfDirectory(atPath: layout.appDirectory.path) == ["current"])
    }

    // MARK: - Applications bundle

    @Test
    func theApplicationBundleIsAssembledFromCurrentSignedAndMovedIntoPlace() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let (layout, applications) = try Self.installedApp(in: root)
        let destination = applications.appendingPathComponent("ZenCODE.app", isDirectory: true)
        var signatures: [(bundle: URL, identifier: String?, hasIcon: Bool)] = []

        let result = try await Installation.installApplicationBundle(
            from: layout.currentDirectory,
            to: destination,
            layout: layout,
            version: "6.2.1",
            writeIcon: { icon in try Data("icns".utf8).write(to: icon) },
            sign: { bundle in
                let hasIcon = FileManager.default.fileExists(
                    atPath: bundle.appendingPathComponent("Contents/Resources/ZenCODE.icns").path
                )
                signatures.append((bundle, Installation.bundleIdentifier(ofApplicationAt: bundle), hasIcon))
            }
        )

        #expect(result == Installation.ApplicationBundleInstall(replaced: false, iconFailure: nil))
        // Signed once, complete, before it was moved in.
        #expect(signatures.count == 1)
        #expect(signatures.first?.bundle.lastPathComponent == "ZenCODE.app")
        #expect(signatures.first?.bundle.deletingLastPathComponent().deletingLastPathComponent().path == layout.appDirectory.path)
        #expect(signatures.first?.identifier == "com.zencode.app")
        #expect(signatures.first?.hasIcon == true)

        let fileManager = FileManager.default
        #expect(try fileManager.contentsOfDirectory(atPath: destination.appendingPathComponent("Contents").path).sorted() == [
            "Info.plist", "MacOS", "Resources"
        ])
        #expect(try fileManager.contentsOfDirectory(atPath: destination.appendingPathComponent("Contents/MacOS").path) == [
            "ZenCODE"
        ])
        #expect(fileManager.isExecutableFile(atPath: destination.appendingPathComponent("Contents/MacOS/ZenCODE").path))
        // The resource bundles are where `Bundle.module` looks inside an app.
        #expect(try fileManager.contentsOfDirectory(atPath: destination.appendingPathComponent("Contents/Resources").path).sorted() == [
            "ZenApp_ZenCODEApp.bundle", "ZenCODE.icns"
        ])
        #expect(try String(
            contentsOf: destination.appendingPathComponent("Contents/Resources/ZenApp_ZenCODEApp.bundle/Contents/Resources/icon.svg"),
            encoding: .utf8
        ) == "<svg/>")

        let info = try #require(Self.info(ofBundleAt: destination))
        #expect(info["CFBundleIdentifier"] as? String == "com.zencode.app")
        #expect(info["CFBundleExecutable"] as? String == "ZenCODE")
        #expect(info["CFBundleName"] as? String == "ZenCODE")
        #expect(info["CFBundlePackageType"] as? String == "APPL")
        #expect(info["CFBundleIconFile"] as? String == "ZenCODE")
        #expect(info["CFBundleShortVersionString"] as? String == "6.2.1")
        #expect(info["CFBundleVersion"] as? String == "6.2.1")
        #expect(info["LSMinimumSystemVersion"] as? String == "26.0")
        #expect(info["NSPrincipalClass"] as? String == "NSApplication")
        #expect(info["NSHighResolutionCapable"] as? Bool == true)
        #expect((info["NSMicrophoneUsageDescription"] as? String)?.isEmpty == false)
        #expect((info["NSSpeechRecognitionUsageDescription"] as? String)?.isEmpty == false)
        #expect(Installation.bundleIdentifier(ofApplicationAt: destination) == "com.zencode.app")
        // Nothing is left next to `current`.
        #expect(try fileManager.contentsOfDirectory(atPath: layout.appDirectory.path) == ["current"])
    }

    @Test
    func anEarlierBundleIsReplacedAndAForeignOneOrALinkIsLeftAsItIs() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let (layout, applications) = try Self.installedApp(in: root)
        let destination = applications.appendingPathComponent("ZenCODE.app", isDirectory: true)
        let fileManager = FileManager.default
        func install() async throws -> Installation.ApplicationBundleInstall {
            try await Installation.installApplicationBundle(
                from: layout.currentDirectory,
                to: destination,
                layout: layout,
                version: "6.2.1",
                writeIcon: { icon in try Data("icns".utf8).write(to: icon) },
                sign: { _ in }
            )
        }

        // The bundle of an earlier build, with a file this build does not have.
        try Self.writeBundle(identifier: "com.zencode.app", at: destination)
        try Self.writeFile("stale", to: destination.appendingPathComponent("Contents/Resources/stale.txt"))
        #expect(try await install() == Installation.ApplicationBundleInstall(replaced: true, iconFailure: nil))
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("Contents/Resources/stale.txt").path))
        #expect(fileManager.isExecutableFile(atPath: destination.appendingPathComponent("Contents/MacOS/ZenCODE").path))
        #expect(try fileManager.contentsOfDirectory(atPath: layout.appDirectory.path) == ["current"])

        // Another app with the same name.
        try fileManager.removeItem(at: destination)
        try Self.writeBundle(identifier: "com.example.other", at: destination)
        await #expect(throws: Installation.ApplicationBundleError.foreignBundle(path: destination.path)) {
            try await install()
        }
        #expect(Installation.bundleIdentifier(ofApplicationAt: destination) == "com.example.other")
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("Contents/MacOS/ZenCODE").path))

        // A symbolic link, even to a bundle of zen --ui.
        try fileManager.removeItem(at: destination)
        let elsewhere = root.appendingPathComponent("elsewhere/ZenCODE.app", isDirectory: true)
        try Self.writeBundle(identifier: "com.zencode.app", at: elsewhere)
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: elsewhere)
        await #expect(throws: Installation.ApplicationBundleError.foreignBundle(path: destination.path)) {
            try await install()
        }
        #expect(try fileManager.destinationOfSymbolicLink(atPath: destination.path) == elsewhere.path)
        #expect(try fileManager.contentsOfDirectory(atPath: layout.appDirectory.path) == ["current"])
        #expect(Installation.ApplicationBundleError.foreignBundle(path: destination.path).localizedDescription == """
            ZenCODE.app was not added to \(applications.path): \(destination.path) is not the app that zen --ui \
            installs (bundle identifier com.zencode.app), so it was left as it is.
            """)
    }

    @Test
    func aBundleWithoutIconGetsTheGenericOneAndOneThatCannotBeSignedIsNotAdded() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let (layout, applications) = try Self.installedApp(in: root)
        let destination = applications.appendingPathComponent("ZenCODE.app", isDirectory: true)
        let fileManager = FileManager.default

        // The icon fails after writing part of it: the bundle has no icon.
        let result = try await Installation.installApplicationBundle(
            from: layout.currentDirectory,
            to: destination,
            layout: layout,
            version: "6.2.1",
            writeIcon: { icon in
                try Data("partial".utf8).write(to: icon)
                throw Installation.ApplicationBundleError.commandFailed("ZenCODE --write-app-icon exited with status 1")
            },
            sign: { _ in }
        )
        #expect(result == Installation.ApplicationBundleInstall(
            replaced: false,
            iconFailure: "ZenCODE --write-app-icon exited with status 1"
        ))
        #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("Contents/Resources/ZenCODE.icns").path))
        #expect(Self.info(ofBundleAt: destination)?["CFBundleIconFile"] == nil)
        #expect(Self.info(ofBundleAt: destination)?["CFBundleIdentifier"] as? String == "com.zencode.app")

        // Signing fails: the bundle already there stays as it is.
        try Self.writeFile("kept", to: destination.appendingPathComponent("Contents/Resources/kept.txt"))
        await #expect(throws: Installation.ApplicationBundleError.signingFailed(
            directory: applications.path,
            reason: "codesign exited with status 1"
        )) {
            try await Installation.installApplicationBundle(
                from: layout.currentDirectory,
                to: destination,
                layout: layout,
                version: "6.2.1",
                writeIcon: { _ in },
                sign: { _ in throw Installation.ApplicationBundleError.commandFailed("codesign exited with status 1") }
            )
        }
        #expect(try String(contentsOf: destination.appendingPathComponent("Contents/Resources/kept.txt"), encoding: .utf8) == "kept")
        #expect(try fileManager.contentsOfDirectory(atPath: layout.appDirectory.path) == ["current"])
    }

    @Test
    func theBundleIsAddedOnlyForTheDefaultSupportDirectoryWithTheOptionOfTheApp() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { Self.remove(root) }
        let home = root.appendingPathComponent("home/.zencode", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("support-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)

        #expect(Installation.applicationsDirectory(
            supportDirectory: home,
            defaultSupportDirectory: home,
            applications: applications
        ) == applications)
        #expect(Installation.applicationsDirectory(
            supportDirectory: link,
            defaultSupportDirectory: home,
            applications: applications
        ) == applications)
        #expect(Installation.applicationsDirectory(
            supportDirectory: root.appendingPathComponent("isolated", isDirectory: true),
            defaultSupportDirectory: home,
            applications: applications
        ) == nil)
        #expect(Installation.defaultApplicationsDirectory.path == "/Applications")
        // Keep in sync with `ZenAppIconExport.option` of the app.
        #expect(Installation.writeIconOption == "--write-app-icon")
    }

    /// An app installed in `<root>/support/app/current` from a fake build, and
    /// an empty applications directory.
    private static func installedApp(in root: URL) throws -> (Installation.Layout, URL) {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try makeFakeBuild(in: bin)
        let layout = Installation.Layout(supportDirectory: root.appendingPathComponent("support", isDirectory: true))
        try Installation.install(binDirectory: bin, stamp: stamp(), layout: layout)
        let applications = root.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        return (layout, applications)
    }

    /// A bundle with only an `Info.plist` that has `identifier`.
    private static func writeBundle(identifier: String, at bundle: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": identifier],
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    private static func info(ofBundleAt bundle: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) else {
            return nil
        }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
#endif
