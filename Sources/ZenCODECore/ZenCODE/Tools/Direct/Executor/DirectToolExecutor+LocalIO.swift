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
            let approved = await authorizationHandler(
                AgentToolAuthorizationRequest(
                    sessionID: sessionID,
                    toolCallID: toolCall.id,
                    toolName: "local.exec",
                    title: "Run \(authorizationCommand)",
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
        enum Quote {
            case none
            case single
            case double
        }

        let characters = Array(command)
        var commands: [String] = []
        var current = ""
        var quote = Quote.none
        var isEscaping = false
        var index = 0

        func appendCurrentCommand() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                commands.append(trimmed)
            }
            current = ""
        }

        while index < characters.count {
            let character = characters[index]

            switch quote {
            case .single:
                current.append(character)
                if character == "'" {
                    quote = .none
                }
            case .double:
                current.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    quote = .none
                }
            case .none:
                if isEscaping {
                    current.append(character)
                    isEscaping = false
                } else {
                    switch character {
                    case "\\":
                        current.append(character)
                        isEscaping = true
                    case "'":
                        current.append(character)
                        quote = .single
                    case "\"":
                        current.append(character)
                        quote = .double
                    case "|":
                        appendCurrentCommand()
                        if index + 1 < characters.count,
                           characters[index + 1] == "|" || characters[index + 1] == "&" {
                            index += 1
                        }
                    default:
                        current.append(character)
                    }
                }
            }

            index += 1
        }

        appendCurrentCommand()
        if commands.isEmpty {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return commands
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
                timeout: timeout
            )
            return ProcessResult(
                status: result.exitCode,
                stdout: result.stdout,
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
