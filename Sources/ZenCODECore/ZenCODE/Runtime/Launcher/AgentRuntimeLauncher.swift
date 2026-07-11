//
//  AgentRuntimeLauncher.swift
//  ZenCODE
//

import Foundation

/// Shared entry points for launching ZenCODE terminal and ACP runtimes.
public enum AgentRuntimeLauncher {
    /// Creates the project's default `AGENTS.md` document when it is absent.
    public static func ensureProjectAgentsFileExists(workingDirectory: URL) throws {
        let standardizedWorkingDirectory = workingDirectory.standardizedFileURL
        let agentsFileURL = standardizedWorkingDirectory
            .appendingPathComponent(AgentsContextService.filename)
        guard !FileManager.default.fileExists(atPath: agentsFileURL.path) else {
            return
        }

        do {
            _ = try ProjectContextFileService().createDefaultDocument(
                kind: .agents,
                at: standardizedWorkingDirectory,
                projectName: standardizedWorkingDirectory.lastPathComponent
            )
        } catch {
            throw AgentRuntimeLauncherError.unableToCreateProjectAgents(
                agentsFileURL,
                error
            )
        }
    }

    /// Runs terminal chat, shutting down an explicitly supplied runner when the chat ends or fails.
    public static func runTerminalChat(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil
    ) async throws {
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: stdinIsTerminal,
            sessionRunner: sessionRunner
        )

        guard let sessionRunner else {
            try await terminal.run()
            return
        }

        do {
            try await terminal.run()
            await sessionRunner.shutdown()
        } catch {
            await sessionRunner.shutdown()
            throw error
        }
    }

    /// Reads ACP requests from standard input and shuts down the bridge when input ends.
    public static func runACP(
        configuration: AgentConfiguration,
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) async {
        let writer = ACPWriter()
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: writer,
            backendFactory: backendFactory
        )
        let reader = StdioLineReader()
        let lines = AsyncStream<String> { continuation in
            let task = Task.detached {
                while let line = reader.readLine() {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for await line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else {
                    continue
                }
                group.addTask {
                    await bridge.handleLine(trimmedLine)
                }
            }
        }

        await bridge.shutdown()
    }
}

public enum AgentRuntimeLauncherError: LocalizedError {
    case unableToCreateProjectAgents(URL, Error)

    public var errorDescription: String? {
        switch self {
        case let .unableToCreateProjectAgents(url, error):
            return "Unable to create project AGENTS.md at \(url.path): \(error.localizedDescription)"
        }
    }
}
