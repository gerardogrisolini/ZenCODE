//
//  XcodeMCPServerConfiguration.swift
//  ZenCODE
//

import Foundation
import FeatureMCPBridgeKit

/// Xcode-specific construction and identification of the generic MCP server
/// configuration. Keeping this outside FeatureMCPBridgeKit preserves the
/// transport configuration's value identity for connection reuse.
public nonisolated enum XcodeMCPServerConfiguration {
    public static let authorizationMessage =
        "Xcode must authorize MCP for this session before the client can connect. Open Xcode and approve the MCP connection, then retry."

    public static func configuration(
        fromEnvironment environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MCPServerConfiguration? {
        let executablePath: String
        if let explicitExecutablePath = trimmed(environment["XCODE_MCP_EXECUTABLE"]) {
            executablePath = explicitExecutablePath
        } else if let detectedExecutablePath = detectedBridgeExecutablePath() {
            executablePath = detectedExecutablePath
        } else {
            return nil
        }

        let arguments = environment["XCODE_MCP_ARGUMENTS"]?
            .split(separator: "\n")
            .map(String.init) ?? []

        var processEnvironment: [String: String] = [:]
        if let explicitPID = trimmed(environment["MCP_XCODE_PID"]) {
            processEnvironment["MCP_XCODE_PID"] = explicitPID
        } else if let detectedPID = detectedProcessID() {
            processEnvironment["MCP_XCODE_PID"] = detectedPID
        }

        if let sessionID = trimmed(environment["MCP_XCODE_SESSION_ID"]) {
            processEnvironment["MCP_XCODE_SESSION_ID"] = sessionID
        }

        return MCPServerConfiguration(
            executablePath: executablePath,
            arguments: arguments,
            environment: processEnvironment,
            preferredProtocolVersion: "2024-11-05"
        )
    }

    public static func isRunning(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let explicitPID = trimmed(environment["MCP_XCODE_PID"]),
           isUsableProcessID(explicitPID) {
            return true
        }

        if let detectedPID = detectedProcessID() {
            return isUsableProcessID(detectedPID)
        }

        return false
    }

    public static func isBridgeConfiguration(_ configuration: MCPServerConfiguration) -> Bool {
        guard !configuration.usesHTTPTransport else {
            return false
        }

        let executableName = URL(fileURLWithPath: configuration.executablePath)
            .lastPathComponent
            .lowercased()
        if executableName == "xcrun" {
            return configuration.arguments.first?.lowercased() == "mcpbridge"
        }
        return executableName == "mcpbridge"
    }

    public static func environment(
        for configuration: MCPServerConfiguration,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var resolvedEnvironment = configuration.environment
        for key in ["MCP_XCODE_PID", "MCP_XCODE_SESSION_ID"] {
            if let value = trimmed(processEnvironment[key]) {
                resolvedEnvironment[key] = value
            }
        }
        return resolvedEnvironment
    }

    static func authorizationError() -> MCPClientError {
        .authorizationRequired(service: "Xcode", message: authorizationMessage)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func detectedProcessID() -> String? {
        #if os(macOS)
        platformDetectedXcodePID()
        #else
        nil
        #endif
    }

    private static func detectedBridgeExecutablePath() -> String? {
        #if os(macOS)
        platformDetectedXcodeBridgeExecutablePath()
        #else
        nil
        #endif
    }

    private static func isUsableProcessID(_ value: String) -> Bool {
        #if os(macOS)
        platformIsUsableXcodeProcessID(value)
        #else
        _ = value
        return false
        #endif
    }
}
