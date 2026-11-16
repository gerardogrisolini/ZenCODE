//
//  ZenCODECommandLineRunnerTests+ZenExecutable.swift
//  ZenCODE
//
//  Tests that launch the built zen executable: setup gate, mode options, meta
//  commands and early JSONL errors, with the process helpers they use.
//

import Foundation
@testable import ZenCODECore
import Synchronization
import Testing
import ToolCore

extension ZenCODECommandLineRunnerTests {
    /// `ZENCODE_AGENT_MODE` is no longer read: whatever its value, it selects no
    /// mode and is never an error, so the error of an invalid `--max-tool-rounds`
    /// is the only one.
    @Test(arguments: ["chat", "acp", "not-a-mode"])
    func zenExecutableIgnoresTheRemovedAgentModeVariable(agentMode: String) throws {
        let result = try runZen(
            zenExecutableURL(),
            arguments: ["--max-tool-rounds", "abc"],
            environment: makeEnvironment(agentMode: agentMode)
        )
        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(
            String(decoding: result.stderr, as: UTF8.self)
                == "ZenCODE: Invalid value for --max-tool-rounds: abc\n"
        )
    }

    @Test
    func zenExecutableStopsEveryModeButACPAtTheSetupGate() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-setup-gate-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        let invocations: [(arguments: [String], agentMode: String?)] = [
            (arguments: [], agentMode: nil),
            (arguments: ["--tui"], agentMode: nil),
            (arguments: ["-p", "hello"], agentMode: nil),
            (arguments: ["-f", "/tmp/zencode-setup-gate-prompt.md"], agentMode: nil),
            (arguments: ["--telegram"], agentMode: nil),
            // The removed variable selects no mode: ACP is only `--acp`, so the
            // gate stops these launches like the terminal chat.
            (arguments: [], agentMode: "acp"),
            (arguments: ["--tui"], agentMode: "acp"),
            (arguments: ["-p", "hello"], agentMode: "acp"),
        ]
        for invocation in invocations {
            var environment = makeEnvironment(agentMode: invocation.agentMode)
            environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

            // No terminal input: the gate stops each mode before it could wait for any.
            let result = try runZen(
                zenExecutableURL(),
                arguments: invocation.arguments,
                environment: environment,
                standardInput: FileHandle.nullDevice
            )

            #expect(result.exitCode == 1, "\(invocation)")
            #expect(result.stdout.isEmpty, "\(invocation)")
            #expect(
                String(decoding: result.stderr, as: UTF8.self)
                    == "ZenCODE is not configured. Run `zen --setup` to configure it, then start zen again.\n",
                "\(invocation)"
            )
        }
    }

    @Test
    func zenExecutableFramesTheSetupGateErrorWithJSONL() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-setup-gate-jsonl-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        var environment = makeEnvironment(agentMode: nil)
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

        let result = try runZen(
            zenExecutableURL(),
            arguments: ["--jsonl", "-p", "hello"],
            environment: environment,
            standardInput: FileHandle.nullDevice
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.last == 0x0A)
        #expect(result.stdout.filter { $0 == 0x0A }.count == 1)
        let record = try JSONDecoder().decode(JSONValue.self, from: result.stdout)
        #expect(record.objectValue?["type"]?.stringValue == "error")
        #expect(record.objectValue?["category"]?.stringValue == "configuration")
        #expect(record.objectValue?["message"]?.stringValue == ZenCODESetupRequirement.notConfiguredMessage)
    }

    /// Only the refusals: a valid `zen --setup` would open the setup on the
    /// controlling terminal of the test run, if any.
    @Test
    func zenExecutableRefusesSetupWithAnyOtherOptionAsText() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-setup-conflict-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        var environment = makeEnvironment(agentMode: nil)
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

        let invocations: [(arguments: [String], conflicting: String)] = [
            (arguments: ["--setup", "--tui"], conflicting: "--tui"),
            (arguments: ["--acp", "--setup"], conflicting: "--acp"),
            (arguments: ["--setup", "-p", "hello"], conflicting: "-p"),
            // Always textual, even with `--jsonl`.
            (arguments: ["--jsonl", "--setup"], conflicting: "--jsonl"),
            (arguments: ["--setup", "--model", "provider:model"], conflicting: "--model"),
        ]
        for invocation in invocations {
            let result = try runZen(
                zenExecutableURL(),
                arguments: invocation.arguments,
                environment: environment,
                standardInput: FileHandle.nullDevice
            )
            #expect(result.exitCode == 1, "\(invocation.arguments)")
            #expect(result.stdout.isEmpty, "\(invocation.arguments)")
            #expect(
                String(decoding: result.stderr, as: UTF8.self)
                    == "ZenCODE: Options --setup and \(invocation.conflicting) cannot be combined.\n",
                "\(invocation.arguments)"
            )
        }
        // Refused before the setup and the migration: nothing was written.
        #expect(!FileManager.default.fileExists(atPath: supportURL.path))
    }

    #if os(macOS)
    @Test
    func zenExecutableRefusesAnOptionOfAnotherModeWithTheAppBeforeSetup() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ui-conflict-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

        let result = try runZen(zenExecutableURL(), arguments: ["--ui", "-p", "x"], environment: environment)

        #expect(result.exitCode == 1)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "ZenCODE: Options --ui and -p cannot be combined.\n")
        #expect(result.stdout.isEmpty)
        // Refused before the setup gate: nothing was written for setup or the app.
        #expect(!FileManager.default.fileExists(atPath: supportURL.path))
    }

    @Test
    func zenExecutableDoesNotOpenTheAppWithoutConfiguration() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ui-unconfigured-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        var environment = makeEnvironment(agentMode: nil)
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

        let result = try runZen(
            zenExecutableURL(),
            arguments: ["--ui", "--agent", "Developer"],
            environment: environment,
            standardInput: FileHandle.nullDevice
        )

        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(
            String(decoding: result.stderr, as: UTF8.self)
                == "ZenCODE is not configured. Run `zen --setup` to configure it, then start zen again.\n"
        )
        // Stopped at the gate: the app was neither built nor installed.
        #expect(!FileManager.default.fileExists(
            atPath: ZenAppInstallation.Layout(supportDirectory: supportURL).logFile.path
        ))
    }
    #else
    @Test
    func zenExecutableTreatsTheAppOptionAsUnknownOutsideMacOS() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ui-unknown-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

        let result = try runZen(zenExecutableURL(), arguments: ["--ui"], environment: environment)

        #expect(result.exitCode == 1)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "ZenCODE: Unknown argument: --ui\n")
        #expect(result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: supportURL.path))
    }
    #endif

    @Test
    func jsonlIsIgnoredForEveryTextualMetaCommand() throws {
        let conflictingFlags = ["--acp", "-p", "ignored"]
        for option in ["--help", "-h", "--version", "--doctor", "--install-features", "--install-features=git-tools"] {
            #expect(!ZenCODECommandLineRunner.jsonlIsActive(
                arguments: ["zen", "--jsonl", option] + conflictingFlags
            ))
        }
        #expect(ZenCODECommandLineRunner.jsonlIsActive(arguments: ["zen", "--jsonl", "-p", "hello"]))

        let help = try AgentConfiguration(arguments: ["zen", "--jsonl", "--help"])
        let version = try AgentConfiguration(arguments: ["zen", "--jsonl", "--version"])
        let doctor = try AgentConfiguration(arguments: ["zen", "--jsonl", "--doctor"])
        #expect(help.printHelp)
        #expect(version.printVersion)
        #expect(doctor.printDoctor)
    }

    @Test
    func zenExecutableMetaCommandsKeepTextOutputAndExitSemanticsWithJSONL() throws {
        let executable = try zenExecutableURL()
        let invocations = [
            ["--help", "--acp", "-p", "ignored"],
            ["--version", "--acp", "-p", "ignored"],
            ["--doctor", "--acp", "-p", "ignored"],
            ["--install-features", "--no-features", "--acp", "-p", "ignored"]
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("zencode-meta-command-test-\(UUID().uuidString)", isDirectory: true)
            .path

        for arguments in invocations {
            let ordinary = try runZen(executable, arguments: arguments, environment: environment)
            let withJSONL = try runZen(executable, arguments: ["--jsonl"] + arguments, environment: environment)
            #expect(withJSONL.exitCode == ordinary.exitCode)
            #expect(withJSONL.stdout == ordinary.stdout)
            #expect(withJSONL.stderr == ordinary.stderr)
        }
    }

    /// `ZenCODEStandaloneHelp` builds the executable's help with exact string
    /// replacements over `AgentConfiguration.helpText`, which change nothing
    /// when the text drifts: only the real output shows that they matched.
    @Test
    func zenExecutableHelpListsSetupAfterDoctorAndNoSlashSetup() throws {
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("zencode-help-test-\(UUID().uuidString)", isDirectory: true)
            .path

        let result = try runZen(zenExecutableURL(), arguments: ["--help"], environment: environment)

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let help = String(decoding: result.stdout, as: UTF8.self)
        #expect(help.contains("zen [--doctor] [--setup] [--install-features"))

        let lines = help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let doctorIndex = try #require(lines.firstIndex { $0.hasPrefix("  --doctor ") })
        #expect(lines.indices.contains(doctorIndex + 1))
        #expect(lines[doctorIndex + 1].hasPrefix("  --setup "))
        #expect(lines.filter { $0.hasPrefix("  --setup ") }.count == 1)
        let telegramLine = try #require(lines.first { $0.hasPrefix("  --telegram ") })
        #expect(telegramLine.hasSuffix("paired with zen --setup)."))
        #expect(!help.contains("/setup"))
    }

    @Test
    func zenExecutableEarlyJSONLErrorOwnsStdoutAndExitOne() throws {
        let result = try runZen(zenExecutableURL(), arguments: ["--jsonl"])
        #expect(result.exitCode == 1)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.last == 0x0A)
        #expect(result.stdout.filter { $0 == 0x0A }.count == 1)

        let record = try JSONDecoder().decode(JSONValue.self, from: result.stdout)
        #expect(record.objectValue?["type"]?.stringValue == "error")
        #expect(record.objectValue?["category"]?.stringValue == "configuration")
        #expect(record.objectValue?["message"]?.stringValue == "No prompt provided. Pass text after -p/--prompt.")
    }

    private func zenExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let arguments = CommandLine.arguments
        var executableURLs: [URL] = []

        func appendExecutableURL(from path: String) {
            guard !path.isEmpty else { return }
            executableURLs.append(
                URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
            )
        }

        // SwiftPM's test runner supplies the test bundle path. Derive the
        // product directory from that current test invocation rather than
        // guessing a `.build` path or accepting an unrelated `zen` binary.
        for (index, argument) in arguments.enumerated() {
            if argument == "--test-bundle-path",
               arguments.indices.contains(index + 1) {
                appendExecutableURL(from: arguments[index + 1])
            } else if argument.hasPrefix("--test-bundle-path=") {
                appendExecutableURL(from: String(argument.dropFirst("--test-bundle-path=".count)))
            } else if argument.contains(".xctest") {
                appendExecutableURL(from: argument)
            }
        }
        if let executableURL = Bundle.main.executableURL {
            executableURLs.append(executableURL.standardizedFileURL)
        }

        var searchedDirectories: [URL] = []

        func appendSearchDirectory(_ directory: URL) {
            let standardized = directory.standardizedFileURL
            guard !searchedDirectories.contains(where: { $0.path == standardized.path }) else {
                return
            }
            searchedDirectories.append(standardized)
        }

        for executableURL in executableURLs {
            appendSearchDirectory(productDirectory(for: executableURL))
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            appendSearchDirectory(productDirectory(for: bundle.bundleURL))
            if let executableURL = bundle.executableURL {
                appendSearchDirectory(productDirectory(for: executableURL))
            }
        }
        for key in ["BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR", "__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
            guard let value = ProcessInfo.processInfo.environment[key] else { continue }
            for path in value.split(separator: ":") where !path.isEmpty {
                appendSearchDirectory(URL(fileURLWithPath: String(path)))
            }
        }

        for productDirectory in searchedDirectories {
            let candidate = productDirectory.appendingPathComponent("zen")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw ZenExecutableTestError.notFound
    }

    private func productDirectory(for executableURL: URL) -> URL {
        let path = executableURL.standardizedFileURL.path
        let components = path.split(separator: "/")
        if let bundleIndex = components.firstIndex(where: { $0.hasSuffix(".xctest") }) {
            let bundlePath = "/" + components[...bundleIndex].joined(separator: "/")
            return URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        }
        return executableURL.deletingLastPathComponent()
    }

    private func runZen(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: FileHandle? = nil
    ) throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let standardInput {
            process.standardInput = standardInput
        }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }

    /// The environment of this process with `ZENCODE_AGENT_MODE` set to
    /// `agentMode`, or removed when it is `nil`. zen ignores that variable: it
    /// is set to prove that. The process itself is never modified: other suites
    /// run in parallel and read the same environment.
    private func makeEnvironment(agentMode: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ZENCODE_AGENT_MODE"] = agentMode
        return environment
    }
}

private enum ZenExecutableTestError: Error {
    case notFound
}
