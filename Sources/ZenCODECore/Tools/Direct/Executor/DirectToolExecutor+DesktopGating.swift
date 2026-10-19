//
//  DirectToolExecutor+DesktopGating.swift
//  ZenCODE
//
//  Authorization gate for `desktop.run` actions that can run code or end
//  processes: opening documents/non-web URLs, launching applications by path,
//  terminating applications, and typing text that presses Return (gated as a
//  `local.exec` command). It mirrors the argument semantics of the
//  optional `desktop-tools` feature and fails closed: only provably benign
//  shapes are left ungated.
//

import FeatureKit
import Foundation
import ToolCore
#if canImport(Darwin)
import Darwin
#endif

extension DirectToolExecutor {
    /// Builds the authorization request for a `desktop.run` call, or nil when
    /// the selected action is not one that runs code or ends processes.
    static func desktopAuthorizationRequest(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        delegatedIdentity: AgentToolAuthorizationRequest.DelegatedIdentity? = nil
    ) -> AgentToolAuthorizationRequest? {
        let arguments = toolCall.argumentsObject
        guard let action = (arguments["action"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }

        func isPathLike(_ name: String) -> Bool {
            name.contains("/") || name.hasPrefix("~")
        }

        func makeRequest(title: String, kind: String, command: String) -> AgentToolAuthorizationRequest {
            AgentToolAuthorizationRequest(
                sessionID: sessionID,
                toolCallID: toolCall.id,
                toolName: "desktop.run",
                title: title,
                kind: kind,
                command: command,
                workingDirectory: workingDirectory.path,
                delegatedIdentity: delegatedIdentity
            )
        }

        let context = FeatureContext(workingDirectory: workingDirectory)

        var selector: [String] = []
        var selectorFlag: String?
        var selectorValue: String?
        if let bundleID = (arguments["bundle_id"] as? String)?.nilIfBlank {
            selectorFlag = "-b"
            selectorValue = bundleID
            selector = ["-b", shellQuoted(bundleID)]
        } else if let name = (arguments["app_name"] as? String)?.nilIfBlank {
            selectorFlag = "-a"
            selectorValue = name
            selector = ["-a", shellQuoted(name)]
        }
        let pathLikeAppName: String? = {
            if selectorFlag == "-a", let value = selectorValue, isPathLike(value) {
                return value
            }
            return nil
        }()

        func launchRequest() -> AgentToolAuthorizationRequest? {
            if let appPath = (arguments["app_path"] as? String)?.nilIfBlank {
                let rendered = context.resolvePath(appPath).path
                return makeRequest(
                    title: "Launch \(rendered)",
                    kind: "execute",
                    command: "open \(shellQuoted(rendered))"
                )
            }
            if let name = pathLikeAppName {
                return makeRequest(
                    title: "Launch \(name)",
                    kind: "execute",
                    command: "open -a \(shellQuoted(name))"
                )
            }
            return nil
        }

        switch action {
        case "open":
            guard let raw = arguments["target"] as? String, raw.nilIfBlank != nil else {
                return nil
            }
            let url = URL(string: raw)
            let scheme = url?.scheme?.lowercased()
            if let scheme, scheme == "http" || scheme == "https", pathLikeAppName == nil {
                return nil
            }
            let rendered: String
            if let url, let scheme, !scheme.isEmpty {
                rendered = url.isFileURL ? url.standardizedFileURL.path : raw
            } else {
                rendered = context.resolvePath(raw).path
            }
            let command = (["open"] + selector + [shellQuoted(rendered)]).joined(separator: " ")
            return makeRequest(title: "Open \(rendered)", kind: "execute", command: command)
        case "launch_app":
            return launchRequest()
        case "activate_app":
            guard arguments.bool("launch_if_needed") == true else {
                return nil
            }
            return launchRequest()
        case "terminate_app":
            let force = arguments.bool("force") == true
            var parts = ["terminate_app"]
            if force {
                parts.append("--force")
            }
            var target = "application"
            var comment = ""
            // JSON null decodes as an absent pid in the feature, which then
            // selects by bundle_id/app_name; render the selector it will use.
            if let rawPID = arguments["pid"], !(rawPID is NSNull) {
                let pid = arguments.int("pid")
                if let pid {
                    parts.append(contentsOf: ["--pid", String(pid)])
                    target = "pid \(pid)"
                    #if canImport(Darwin)
                    if let pidValue = pid_t(exactly: pid) {
                        var buffer = [CChar](repeating: 0, count: 256)
                        let length = proc_name(pidValue, &buffer, UInt32(buffer.count))
                        if length > 0 {
                            let name = String(
                                decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                as: UTF8.self
                            )
                            comment = " # \(name)"
                        } else {
                            comment = " # no such process"
                        }
                    } else {
                        comment = " # no such process"
                    }
                    #endif
                } else {
                    let text = String(describing: rawPID)
                    parts.append(contentsOf: ["--pid", shellQuoted(text)])
                    target = "pid \(text)"
                }
            } else if let bundleID = (arguments["bundle_id"] as? String)?.nilIfBlank {
                parts.append(contentsOf: ["-b", shellQuoted(bundleID)])
                target = bundleID
            } else if let name = (arguments["app_name"] as? String)?.nilIfBlank {
                parts.append(contentsOf: ["-a", shellQuoted(name)])
                target = name
            }
            return makeRequest(
                title: force ? "Force-terminate \(target)" : "Terminate \(target)",
                kind: "destructive",
                command: parts.joined(separator: " ") + comment
            )
        case "type_text":
            // Typing a line break presses Return, which submits the line to a
            // focused shell. Treat such text exactly like a `local.exec`
            // command; text without a line break only edits the input.
            guard let text = arguments["text"] as? String,
                  text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                return nil
            }
            let command = text
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return localExecAuthorizationRequest(
                sessionID: sessionID,
                toolCallID: toolCall.id,
                command: command,
                cwd: workingDirectory,
                delegatedIdentity: delegatedIdentity
            )
        default:
            return nil
        }
    }
}
