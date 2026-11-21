//
//  SwiftFeatureManagementTools+Build.swift
//  ZenCODE
//
//  The `swift build` of a feature package for the management tools, with the
//  invocation and the executor seam used in tests.
//

import FeatureKit
import Foundation
import ToolCore

extension SwiftFeatureRuntime {
    func buildFeature(
        arguments: [String: Any]
    ) async throws -> SwiftFeatureBuildReport {
        try await buildFeature(
            manifestURL: featureManifestURL(arguments: arguments),
            arguments: arguments
        )
    }

    /// Builds the feature package of `manifestURL`; `arguments` supplies only
    /// the timeout. The manifest and the package are validated here; the
    /// `swift build` itself runs through ``featureBuildExecutor`` when one is
    /// installed, otherwise for real.
    func buildFeature(
        manifestURL: URL,
        arguments: [String: Any]
    ) async throws -> SwiftFeatureBuildReport {
        guard let record = SwiftFeatureRegistry.featureRecord(
            manifestURL: manifestURL,
            fileManager: fileManager
        ) else {
            throw DirectToolError.permissionDenied(
                "Feature manifest is missing or invalid: \(manifestURL.path)"
            )
        }

        let validationReport = try validateFeature(
            arguments: ["manifestPath": manifestURL.path]
        )
        let blockingErrors = validationReport.errors.filter {
            !$0.hasPrefix("Executable is missing or not executable:")
        }
        guard blockingErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature validation failed before build:\n\(blockingErrors.joined(separator: "\n"))"
            )
        }

        let build = record.build ?? SwiftFeatureBuildManifest(
            product: record.id,
            configuration: "release",
            executablePath: record.executableURL.path
        )
        guard build.system.lowercased() == "swiftpm" else {
            throw DirectToolError.permissionDenied(
                "Unsupported build system '\(build.system)'. Only swiftpm is currently supported."
            )
        }

        let featureDirectoryURL = manifestURL.deletingLastPathComponent()
        let packageDirectoryURL = Self.resolveBuildPackageDirectory(
            build: build,
            featureDirectoryURL: featureDirectoryURL
        )
        let toolsVersionErrors = Self.validatePackageSwiftToolsVersion(
            packageDirectoryURL: packageDirectoryURL
        )
        guard toolsVersionErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                toolsVersionErrors.joined(separator: "\n")
            )
        }

        let configuration = build.configuration ?? "release"
        let product = build.product ?? record.id
        let commandArguments = [
            "build",
            "-c",
            configuration,
            "--product",
            product
        ] + build.arguments
        let timeout = TimeInterval(arguments.int("timeoutSeconds", "timeout") ?? 300)
        let invocation = SwiftFeatureBuildInvocation(
            featureID: record.id,
            packageDirectoryURL: packageDirectoryURL,
            executableURL: record.executableURL,
            configuration: configuration,
            commandArguments: commandArguments,
            timeout: timeout
        )
        if let featureBuildExecutor {
            return try await featureBuildExecutor(invocation)
        }
        return try await runFeatureBuild(invocation)
    }

    /// Installs the build ``buildFeature(manifestURL:arguments:)`` runs once
    /// it has validated a package; `nil` restores the real `swift build`.
    /// Internal seam for tests.
    func setFeatureBuildExecutor(_ executor: SwiftFeatureBuildExecutor?) {
        featureBuildExecutor = executor
    }

    /// The real build of `invocation`: `swift build`, then `strip` for a
    /// release build.
    private func runFeatureBuild(
        _ invocation: SwiftFeatureBuildInvocation
    ) async throws -> SwiftFeatureBuildReport {
        let featureID = invocation.featureID
        let packageDirectoryURL = invocation.packageDirectoryURL
        let executableURL = invocation.executableURL
        let configuration = invocation.configuration
        let commandArguments = invocation.commandArguments
        let timeout = invocation.timeout
        let baseEnvironment = ProcessInfo.processInfo.environment
        let swiftExecutableURL = try Self.swiftExecutableURL(
            fileManager: fileManager,
            environment: baseEnvironment
        )
        var processEnvironment = DeveloperToolEnvironment.processEnvironment(base: baseEnvironment)
        let swiftBinPath = swiftExecutableURL.deletingLastPathComponent().path
        let processSearchPaths = processEnvironment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        if !processSearchPaths.contains(swiftBinPath) {
            processEnvironment["PATH"] = ([swiftBinPath] + processSearchPaths)
                .joined(separator: ":")
        }
        let result: AsyncProcessResult
        do {
            result = try await AsyncProcessRunner.run(
                executableURL: swiftExecutableURL,
                arguments: commandArguments,
                workingDirectory: packageDirectoryURL,
                environment: processEnvironment,
                timeout: timeout
            )
        } catch {
            throw DirectToolError.processFailed(
                "Could not launch Swift at \(swiftExecutableURL.path) to build feature "
                    + "'\(featureID)' in \(packageDirectoryURL.path): \(error.localizedDescription)"
            )
        }
        let executableAvailable = fileManager.isExecutableFile(
            atPath: executableURL.path
        )

        guard result.exitCode == 0,
              executableAvailable,
              configuration.lowercased() == "release" else {
            return SwiftFeatureBuildReport(
                ok: result.exitCode == 0 && executableAvailable,
                id: featureID,
                command: ["swift"] + commandArguments,
                workingDirectory: packageDirectoryURL.path,
                executablePath: executableURL.path,
                exitCode: result.exitCode,
                timedOut: result.timedOut,
                stdout: result.stdout,
                stderr: executableAvailable
                    ? result.stderr
                    : result.stderr + "\nExecutable not found after build: \(executableURL.path)"
            )
        }

        let stripExecutableURL = URL(fileURLWithPath: "/usr/bin/strip")
        guard fileManager.isExecutableFile(atPath: stripExecutableURL.path) else {
            return SwiftFeatureBuildReport(
                ok: false,
                id: featureID,
                command: ["swift"] + commandArguments,
                workingDirectory: packageDirectoryURL.path,
                executablePath: executableURL.path,
                exitCode: 1,
                timedOut: false,
                stdout: result.stdout,
                stderr: result.stderr + "\nRelease builds require strip at \(stripExecutableURL.path)."
            )
        }

        let stripResult: AsyncProcessResult
        do {
            stripResult = try await AsyncProcessRunner.run(
                executableURL: stripExecutableURL,
                arguments: ["-S", executableURL.path],
                workingDirectory: packageDirectoryURL,
                environment: processEnvironment,
                timeout: timeout
            )
        } catch {
            return SwiftFeatureBuildReport(
                ok: false,
                id: featureID,
                command: ["swift"] + commandArguments,
                workingDirectory: packageDirectoryURL.path,
                executablePath: executableURL.path,
                exitCode: 1,
                timedOut: false,
                stdout: result.stdout,
                stderr: result.stderr + "\nCould not launch strip: \(error.localizedDescription)"
            )
        }

        return SwiftFeatureBuildReport(
            ok: stripResult.exitCode == 0 && !stripResult.timedOut,
            id: featureID,
            command: ["swift"] + commandArguments,
            workingDirectory: packageDirectoryURL.path,
            executablePath: executableURL.path,
            exitCode: stripResult.exitCode,
            timedOut: stripResult.timedOut,
            stdout: result.stdout + stripResult.stdout,
            stderr: result.stderr + stripResult.stderr
        )
    }
}

/// One `swift build` of a feature package, as
/// ``SwiftFeatureRuntime/buildFeature(manifestURL:arguments:)`` prepared it
/// after validating the manifest and the package.
struct SwiftFeatureBuildInvocation: Sendable {
    let featureID: String
    let packageDirectoryURL: URL
    /// The executable the build must produce.
    let executableURL: URL
    let configuration: String
    /// The `swift` arguments (`build -c <configuration> --product <product>`
    /// followed by the manifest's build arguments).
    let commandArguments: [String]
    let timeout: TimeInterval
}

/// Runs a ``SwiftFeatureBuildInvocation`` and reports it, in place of the
/// real `swift build`. Internal test seam of ``SwiftFeatureRuntime``.
typealias SwiftFeatureBuildExecutor = @Sendable (
    SwiftFeatureBuildInvocation
) async throws -> SwiftFeatureBuildReport
