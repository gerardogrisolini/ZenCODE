//
//  XcodeToolExecutor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import FeatureKit
public import FeatureMCPBridgeKit
import ToolCore

public actor XcodeToolExecutor {
    private let client: MCPClient
    /// Project roots per Xcode tab, resolved once through `XcodeListWindows`.
    /// A failed lookup is cached as empty so it never repeats per call.
    private var workspaceRootsByTabIdentifier: [String: [URL]] = [:]

    public init(configuration: MCPServerConfiguration) {
        self.client = MCPClient(
            configuration: configuration,
            localTransportPolicy: XcodeMCPTransportPolicy.make()
        )
    }

    public func loadTools() async throws -> [ToolDescriptor] {
        try await client.connect()
        let toolList = try await client.listTools()
        return toolList.tools.map(ToolDescriptor.init(remoteTool:))
    }

    public func execute(_ request: ToolRequest) async throws -> ToolExecutionOutput {
        let result = try await executeRequestRetryingIndentationMismatchIfNeeded(request)
        let renderedResult = MCPToolResultRenderer.stringify(result)

        return ToolExecutionOutput(
            text: renderedResult,
            rawResult: result
        )
    }

    /// Executes a request and, for tools that change files, samples the local
    /// filesystem around the call to report what changed on disk.
    func executeCapturingFileChanges(
        _ request: ToolRequest,
        workingDirectoryPath: String?
    ) async throws -> (output: ToolExecutionOutput, fileChanges: [FeatureInvocationFileChange]) {
        guard XcodeFileChangeCapture.tracksChanges(toolName: request.name) else {
            return (try await execute(request), [])
        }
        let roots = await evidenceRoots(
            tabIdentifier: request.arguments["tabIdentifier"]?.stringValue,
            workingDirectoryPath: workingDirectoryPath
        )
        let capture = XcodeFileChangeCapture(request: request, roots: roots)
        let output = try await execute(request)
        let fileChanges = capture?.finish(
            succeeded: !Self.isErrorResult(output.rawResult)
        ) ?? []
        return (output, fileChanges)
    }

    private func evidenceRoots(
        tabIdentifier: String?,
        workingDirectoryPath: String?
    ) async -> [URL] {
        var roots: [URL] = []
        if let tabIdentifier = tabIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tabIdentifier.isEmpty {
            roots += await workspaceRoots(tabIdentifier: tabIdentifier)
        }
        if let workingDirectoryPath = workingDirectoryPath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           workingDirectoryPath.hasPrefix("/") {
            roots.append(URL(fileURLWithPath: workingDirectoryPath).standardizedFileURL)
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.path).inserted }
    }

    private func workspaceRoots(tabIdentifier: String) async -> [URL] {
        if let cached = workspaceRootsByTabIdentifier[tabIdentifier] {
            return cached
        }
        var roots: [URL] = []
        do {
            let result = try await client.callTool(named: "XcodeListWindows", arguments: [:])
            roots = XcodeWorkspaceContext.contexts(fromListWindowsResult: result)
                .filter { $0.defaultTabIdentifier == tabIdentifier }
                .compactMap(\.normalizedWorkspaceRootPath)
                .filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: $0).standardizedFileURL }
        } catch is CancellationError {
            // A cancelled lookup is not a failed one: leave it uncached so the
            // next call can resolve the roots.
            return []
        } catch {
            // Evidence is best effort; the tool call itself surfaces the error.
        }
        workspaceRootsByTabIdentifier[tabIdentifier] = roots
        return roots
    }

    /// Mirrors the renderer's "Tool error" detection so file-change evidence
    /// is suppressed for every failure shape the bridge produces.
    static func isErrorResult(_ result: JSONValue?) -> Bool {
        guard case let .object(object) = result else {
            return false
        }
        if object["isError"]?.boolValue == true {
            return true
        }
        let structured = object["structuredContent"]?.objectValue
        return structured?["isError"]?.boolValue == true
            || structured?["success"]?.boolValue == false
            || object["success"]?.boolValue == false
    }

    private func executeRequestRetryingIndentationMismatchIfNeeded(
        _ request: ToolRequest
    ) async throws -> JSONValue {
        let initialResult = try await client.callTool(
            named: request.name,
            arguments: request.arguments
        )

        guard request.name == "XcodeUpdate",
              let retryRequest = retriedXcodeUpdateRequestForIndentationMismatch(
                  originalRequest: request,
                  failureResult: initialResult
              ) else {
            return initialResult
        }

        // A cancelled caller must not trigger a second mutation.
        try Task.checkCancellation()
        return try await client.callTool(
            named: retryRequest.name,
            arguments: retryRequest.arguments
        )
    }

    public func disconnect() async {
        await client.disconnect()
    }

}
