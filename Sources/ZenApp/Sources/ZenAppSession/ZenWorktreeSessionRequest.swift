//
//  ZenWorktreeSessionRequest.swift
//  ZenApp
//
//  Validates and prepares a worktree before any new session is opened.
//

import Foundation
import Observation
import ZenCODECore

@MainActor
@Observable
public final class ZenWorktreeSessionRequest {
    public var name = ""
    public private(set) var isPreparing = false
    public private(set) var errorMessage: String?

    @ObservationIgnored private let prepare: @Sendable (String, URL) async throws -> URL

    public init(
        prepare: @escaping @Sendable (String, URL) async throws -> URL = {
            try await AgentWorktreeManager.prepare(name: $0, launchDirectory: $1)
        }
    ) {
        self.prepare = prepare
    }

    /// Blank names do nothing. Invalid names and Git failures remain in the
    /// prompt; no session is opened unless this returns a directory.
    public func confirm(in workspace: URL) async -> URL? {
        guard !isPreparing, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let requestedName = name
        isPreparing = true
        errorMessage = nil
        defer { isPreparing = false }
        do {
            return try await prepare(requestedName, workspace)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
