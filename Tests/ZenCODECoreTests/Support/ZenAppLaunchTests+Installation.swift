//
//  ZenAppLaunchTests+Installation.swift
//  ZenCODECoreTests
//
//  Tests of `zen --ui` that cover the option parsing, the decision to build
//  the app, the build helpers and the installation of the app bundle.
//  Tests of this serialized suite run in file-name order: keep the name.
//

#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

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
}
#endif
