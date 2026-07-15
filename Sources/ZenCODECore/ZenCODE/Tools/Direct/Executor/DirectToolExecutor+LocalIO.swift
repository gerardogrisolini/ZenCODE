//
//  DirectToolExecutor+LocalIO.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import FeatureKit

extension DirectToolExecutor {
    public func deniedLocalExecOutputIfNeeded(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        command: String,
        cwd: URL
    ) async -> String? {
        guard let authorizationHandler else {
            return nil
        }

        for authorizationCommand in Self.localExecAuthorizationCommands(in: command) {
            let displayIdentity = Self.localExecAuthorizationDisplayIdentity(
                in: authorizationCommand
            )
            let approved = await authorizationHandler(
                AgentToolAuthorizationRequest(
                    sessionID: sessionID,
                    toolCallID: toolCall.id,
                    toolName: "local.exec",
                    title: "Run \(displayIdentity)",
                    kind: "execute",
                    command: authorizationCommand,
                    workingDirectory: cwd.path
                )
            )
            guard approved else {
                return deniedLocalExecOutput(command: command, cwd: cwd)
            }
        }

        return nil
    }

    static func localExecAuthorizationCommands(in command: String) -> [String] {
        let segments = LocalExecCommandParser.commandSegments(in: command)
        guard !segments.isEmpty else {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }

        // Keep only segments whose executable identity is worth prompting for,
        // skipping harmless built-ins/keywords. Deduplicate by identity so that
        // repeated executables in the same pipeline (e.g. two `grep`) produce a
        // single authorization request.
        var seenIdentities = Set<String>()
        var commands: [String] = []
        for segment in segments {
            switch LocalExecCommandParser.executableIdentity(for: segment) {
            case .skip:
                continue
            case .executable(let name):
                guard seenIdentities.insert(name).inserted else {
                    continue
                }
                commands.append(segment)
            case .unresolved(let raw):
                guard seenIdentities.insert(raw).inserted else {
                    continue
                }
                commands.append(segment)
            }
        }

        return commands
    }

    /// Returns the clean executable identity (for display titles) of the first
    /// authorizable segment in `command`, falling back to the trimmed command.
    static func localExecAuthorizationDisplayIdentity(in command: String) -> String {
        let segments = LocalExecCommandParser.commandSegments(in: command)
        for segment in segments {
            switch LocalExecCommandParser.executableIdentity(for: segment) {
            case .skip:
                continue
            case .executable(let name):
                return name
            case .unresolved(let raw):
                return raw
            }
        }
        return command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func deniedLocalExecOutput(command: String, cwd: URL) -> String {
        return """
        Command execution cancelled.
        The user did not approve this `local.exec` request, so no shell command was run.

        Working directory:
        \(cwd.path)

        Command:
        \(command)
        """
    }

    public func resolvePath(_ path: String, cwd: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return cwd.appendingPathComponent(expanded).standardizedFileURL
    }

#if canImport(Darwin) || canImport(Glibc)
    /// Generous anti-runaway guard: legitimate commands rarely exceed this many
    /// stdout lines, while an unbounded producer (`yes`, busy log loops) would
    /// otherwise grow process memory without limit before output truncation.
    public static let processStdoutLineLimit = 100_000

    public func runProcess(
        executable: String,
        arguments: [String],
        cwd: URL,
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async -> ProcessResult {
        do {
            let result = try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                workingDirectory: cwd,
                environment: environment,
                timeout: timeout,
                stdoutLineLimit: Self.processStdoutLineLimit
            )
            let stdout = result.stdoutWasTruncated
                ? result.stdout + "\n[stdout truncated after \(Self.processStdoutLineLimit) lines; the command was terminated. Narrow its output or redirect it to a file.]"
                : result.stdout
            return ProcessResult(
                status: result.exitCode,
                stdout: stdout,
                stderr: result.stderr,
                timedOut: result.timedOut
            )
        } catch {
            return ProcessResult(
                status: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            )
        }
    }
#endif

    public func renderProcessResult(_ result: ProcessResult) -> String {
        FeatureProcessOutputRenderer.render(
            exitCode: result.status,
            stdout: result.stdout,
            stderr: result.stderr,
            timedOut: result.timedOut
        )
    }

    public static func toolArguments(from argumentsJSON: String) -> [String: JSONValue] {
        let trimmedJSON = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJSON.isEmpty,
              let data = trimmedJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return [:]
        }
        return arguments
    }

    public func truncated(_ text: String) -> String {
        guard text.count > outputLimit else {
            return text
        }
        return String(text.prefix(outputLimit)) + "\n... truncated to \(outputLimit) characters ..."
    }

    public func modelOutput(
        from output: String,
        toolName: String? = nil
    ) -> String {
        let canonicalToolName = toolName.flatMap {
            DirectSubAgentRuntime.canonicalSubAgentToolName(for: $0)
        }
        // Delegated reports are already curated model output. Keep them intact up
        // to the executor's absolute safety limit so coordinators can consume a
        // complete plan or review instead of an unrecoverable prefix.
        let preservesDelegatedOutput = canonicalToolName == "agent.get"
            || canonicalToolName == "agent.wait"
        let limit = preservesDelegatedOutput
            ? outputLimit
            : min(outputLimit, Self.defaultModelOutputLimit)
        guard output.count > limit else {
            return output
        }
        let footer = """

        ... truncated for model context to \(limit) characters ...
        Re-run the tool with a narrower query, offset/limit, or more focused command if more output is needed.
        """
        let prefixLimit = max(limit - footer.count, 1)
        return """
        \(String(output.prefix(prefixLimit)))\(footer)
        """
    }

    public func summary(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "<no output>"
        }
        return String(trimmed.components(separatedBy: .newlines).first?.prefix(160) ?? "")
    }

    public static func canonicalized(
        _ descriptors: [DirectToolDescriptor]
    ) -> [DirectToolDescriptor] {
        var seen = Set<String>()
        return descriptors.filter { descriptor in
            seen.insert(descriptor.name).inserted
        }
    }
}
