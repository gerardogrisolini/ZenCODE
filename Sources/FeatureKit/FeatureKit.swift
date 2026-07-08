//
//  FeatureKit.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct FeatureContext: Sendable {
    public let workingDirectory: URL
    public let environment: [String: String]

    public init(
        workingDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.environment = environment
    }

    public func resolvePath(_ path: String) -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }
        return workingDirectory
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }
}

public protocol FeatureTool: Sendable {
    associatedtype Input: Decodable & Sendable
    associatedtype Output: Encodable & Sendable

    static var name: String { get }
    static var description: String { get }
    static var inputSchema: String { get }
    static var outputSchema: String? { get }

    func run(_ input: Input, context: FeatureContext) async throws -> Output
}

public extension FeatureTool {
    static var outputSchema: String? {
        nil
    }
}

public struct FeatureToolDescriptor: Codable, Hashable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: String
    public let outputSchema: String?

    public init(
        name: String,
        description: String,
        inputSchema: String,
        outputSchema: String? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

public struct FeatureProcessResult: Sendable {
    public let exitCode: Int32
    public let stdoutData: Data
    public let stderrData: Data
    public let timedOut: Bool
    public let stdoutWasTruncated: Bool

    public init(
        exitCode: Int32,
        stdoutData: Data,
        stderrData: Data,
        timedOut: Bool,
        stdoutWasTruncated: Bool
    ) {
        self.exitCode = exitCode
        self.stdoutData = stdoutData
        self.stderrData = stderrData
        self.timedOut = timedOut
        self.stdoutWasTruncated = stdoutWasTruncated
    }

    public var stdout: String {
        String(decoding: stdoutData, as: UTF8.self)
    }

    public var stderr: String {
        String(decoding: stderrData, as: UTF8.self)
    }

    /// Canonical textual rendering of a finished process: an `exit_code` line,
    /// an optional `timed_out` marker, and non-empty `stdout`/`stderr` sections,
    /// falling back to `<no output>` when only the exit code is present. Shared
    /// so Git, local-exec, and other feature tools present process results
    /// identically instead of each re-deriving this format.
    public var renderedProcessOutput: String {
        FeatureProcessOutputRenderer.render(
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }
}

/// Stateless renderer for process results. Kept separate from
/// `FeatureProcessResult` so callers holding differently-shaped process types
/// (e.g. already-decoded stdout/stderr strings) can reuse the exact same format.
public enum FeatureProcessOutputRenderer {
    public static func render(
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool
    ) -> String {
        var sections = ["exit_code: \(exitCode)"]
        if timedOut {
            sections.append("timed_out: true")
        }
        if !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("stdout:\n\(stdout)")
        }
        if !stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("stderr:\n\(stderr)")
        }
        if sections.count == 1 {
            sections.append("<no output>")
        }
        return sections.joined(separator: "\n")
    }
}

public enum FeatureProcessRunner {
    public static func run(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL? = nil,
        environment: [String: String]? = nil,
        stdinData: Data? = nil,
        timeout: TimeInterval? = nil,
        stdoutLineLimit: Int? = nil
    ) async throws -> FeatureProcessResult {
        #if os(macOS) || os(Linux)
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        if let environment {
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = stdinData.map { _ in Pipe() }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        if let stdinPipe {
            process.standardInput = stdinPipe
        }

        let exitObserver = FeatureProcessExitObserver()
        process.terminationHandler = { _ in
            Task {
                await exitObserver.finish()
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            throw error
        }

        let stdoutReader = Task.detached { () -> (Data, Bool) in
            readStdout(
                from: stdoutPipe,
                process: process,
                lineLimit: stdoutLineLimit
            )
        }
        let stderrReader = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        // Write stdin concurrently with the readers: writing synchronously before
        // draining stdout/stderr can deadlock when the payload exceeds the OS pipe
        // buffer and the child blocks writing output that nobody is reading yet.
        if let stdinData,
           let stdinPipe {
            let writer = stdinPipe.fileHandleForWriting
            Task.detached {
                try? writer.write(contentsOf: stdinData)
                try? writer.close()
            }
        }

        let timedOut = await withTaskCancellationHandler {
            await waitForProcessExit(
                process,
                exitObserver: exitObserver,
                timeout: timeout
            )
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }

        process.terminationHandler = nil
        let stdoutResult = await stdoutReader.value
        let stderrData = await stderrReader.value

        try Task.checkCancellation()

        return FeatureProcessResult(
            exitCode: process.terminationStatus,
            stdoutData: stdoutResult.0,
            stderrData: stderrData,
            timedOut: timedOut,
            stdoutWasTruncated: stdoutResult.1
        )
        #else
        _ = executableURL
        _ = arguments
        _ = workingDirectory
        _ = environment
        _ = stdinData
        _ = timeout
        _ = stdoutLineLimit
        throw FeatureProcessRunnerError.unsupportedPlatform
        #endif
    }

    #if os(macOS) || os(Linux)
    private static func readStdout(
        from pipe: Pipe,
        process: Process,
        lineLimit: Int?
    ) -> (Data, Bool) {
        guard let lineLimit, lineLimit > 0 else {
            return (pipe.fileHandleForReading.readDataToEndOfFile(), false)
        }

        var stdoutData = Data()
        var observedLineCount = 0
        var wasTruncated = false

        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                break
            }

            stdoutData.append(chunk)
            observedLineCount += chunk.reduce(into: 0) { partialResult, byte in
                if byte == UInt8(ascii: "\n") {
                    partialResult += 1
                }
            }

            if observedLineCount >= lineLimit {
                wasTruncated = true
                if process.isRunning {
                    process.terminate()
                }
                break
            }
        }

        return (stdoutData, wasTruncated)
    }

    private static func waitForProcessExit(
        _ process: Process,
        exitObserver: FeatureProcessExitObserver,
        timeout: TimeInterval?
    ) async -> Bool {
        guard let timeout else {
            await exitObserver.wait()
            return false
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await exitObserver.wait()
                return false
            }

            group.addTask {
                let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard await !exitObserver.hasFinished else {
                    return false
                }

                process.terminate()
                if await waitForExitAfterTermination(exitObserver: exitObserver) {
                    return true
                }

                kill(process.processIdentifier, SIGKILL)
                await exitObserver.wait()
                return true
            }

            let timedOut = await group.next() ?? false
            group.cancelAll()
            return timedOut
        }
    }

    private static func waitForExitAfterTermination(
        exitObserver: FeatureProcessExitObserver
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await exitObserver.wait()
                return true
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }

            let exited = await group.next() ?? false
            group.cancelAll()
            return exited
        }
    }
    #endif
}

#if os(macOS) || os(Linux)
private actor FeatureProcessExitObserver {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var hasFinished = false

    func wait() async {
        guard !hasFinished else {
            return
        }

        await withCheckedContinuation { continuation in
            if hasFinished {
                continuation.resume()
            } else {
                continuations.append(continuation)
            }
        }
    }

    func finish() {
        guard !hasFinished else {
            return
        }

        hasFinished = true
        let continuations = continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
#endif

public enum FeatureProcessRunnerError: LocalizedError, Sendable {
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Local process execution is unavailable on this platform."
        }
    }
}

public struct AnyFeatureTool: Sendable {
    public let descriptor: FeatureToolDescriptor
    private let invokeBody: @Sendable (Data, FeatureContext) async throws -> Data

    public init<T: FeatureTool>(_ tool: T) {
        self.descriptor = FeatureToolDescriptor(
            name: T.name,
            description: T.description,
            inputSchema: T.inputSchema,
            outputSchema: T.outputSchema
        )
        self.invokeBody = { inputData, context in
            let normalizedInputData = inputData.isEmpty ? Data("{}".utf8) : inputData
            let input = try JSONDecoder().decode(T.Input.self, from: normalizedInputData)
            let output = try await tool.run(input, context: context)
            return try JSONEncoder().encode(output)
        }
    }

    public func invoke(
        inputData: Data,
        context: FeatureContext
    ) async throws -> Data {
        try await invokeBody(inputData, context)
    }
}

public enum FeatureRunner {
    public static func run(
        _ tools: [AnyFeatureTool],
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        let parsed = ParsedArguments(arguments: Array(arguments.dropFirst()))
        do {
            switch parsed.command {
            case .listTools:
                try emitJSON(ListToolsResponse(tools: tools.map(\.descriptor)))
            case let .invoke(toolName, workingDirectory):
                guard let tool = tools.first(where: { $0.descriptor.name == toolName }) else {
                    throw FeatureRunnerError.unknownTool(toolName)
                }
                let inputData = FileHandle.standardInput.readDataToEndOfFile()
                let context = FeatureContext(
                    workingDirectory: workingDirectory
                        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                    environment: environment
                )
                let outputData = try await tool.invoke(
                    inputData: inputData,
                    context: context
                )
                try emitSuccess(outputData: outputData)
            case .usage:
                try emitJSON(ErrorResponse(ok: false, error: usageText))
                terminate(code: 64)
            }
        } catch {
            try? emitJSON(ErrorResponse(ok: false, error: error.localizedDescription))
            terminate(code: 1)
        }
    }

    private static func emitJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func emitSuccess(outputData: Data) throws {
        FileHandle.standardOutput.write(Data(#"{"ok":true,"output":"#.utf8))
        FileHandle.standardOutput.write(outputData)
        FileHandle.standardOutput.write(Data("}\n".utf8))
    }

    private static func terminate(code: Int32) -> Never {
        #if canImport(Darwin) || canImport(Glibc)
        exit(code)
        #else
        fatalError("FeatureRunner terminated with code \(code).")
        #endif
    }

    private static let usageText = """
    Usage:
      feature-binary --list-tools
      feature-binary --invoke <tool-name> [--working-directory <path>]
    """
}

private struct ListToolsResponse: Codable {
    let tools: [FeatureToolDescriptor]
}

private struct ErrorResponse: Codable {
    let ok: Bool
    let error: String
}

private enum RunnerCommand {
    case listTools
    case invoke(String, URL?)
    case usage
}

private struct ParsedArguments {
    let command: RunnerCommand

    init(arguments: [String]) {
        guard let first = arguments.first else {
            command = .usage
            return
        }

        switch first {
        case "--list-tools":
            command = .listTools
        case "--invoke":
            guard arguments.count >= 2 else {
                command = .usage
                return
            }
            let workingDirectory = Self.optionValue(
                "--working-directory",
                in: arguments
            ).map {
                URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
            }
            command = .invoke(arguments[1], workingDirectory)
        default:
            command = .usage
        }
    }

    private static func optionValue(
        _ option: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private enum FeatureRunnerError: LocalizedError {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case let .unknownTool(toolName):
            return "Unknown feature tool: \(toolName)"
        }
    }
}
