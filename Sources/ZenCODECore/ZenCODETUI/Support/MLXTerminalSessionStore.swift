//
//  MLXTerminalSessionStore.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Crypto
import Foundation

public struct MLXTerminalSavedSessionContextWindow: Codable, Equatable, Sendable {
    public let usedTokens: Int?
    public let maxTokens: Int?
    public let modelID: String
    public let isApproximate: Bool

    public init(
        usedTokens: Int?,
        maxTokens: Int?,
        modelID: String,
        isApproximate: Bool
    ) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.isApproximate = isApproximate
    }

    public init(_ status: DirectAgentContextWindowStatus) {
        self.init(
            usedTokens: status.usedTokens,
            maxTokens: status.maxTokens,
            modelID: status.modelID,
            isApproximate: status.isApproximate
        )
    }

    public var runtimeStatus: DirectAgentContextWindowStatus? {
        guard !modelID.isEmpty else {
            return nil
        }
        return DirectAgentContextWindowStatus(
            usedTokens: usedTokens,
            maxTokens: maxTokens,
            modelID: modelID,
            isApproximate: isApproximate
        )
    }
}

public struct MLXTerminalSavedSession: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public let version: Int
    public let name: String
    public let sessionID: String
    public let cacheKey: String?
    public let workingDirectoryPath: String
    public let createdAt: Date
    public let savedAt: Date
    public let modelID: String?
    public let agentID: String?
    public let agentName: String?
    public let selectedTools: [String]
    public let selectedSkillIDs: [String]
    public let thinkingSelection: String?
    public let contextWindow: MLXTerminalSavedSessionContextWindow?
    public let systemPrompt: String?
    public let history: [AgentRuntimeMessage]
    public let transcriptHistory: [AgentRuntimeMessage]?

    public init(
        version: Int = Self.currentVersion,
        name: String,
        sessionID: String,
        cacheKey: String?,
        workingDirectoryPath: String,
        createdAt: Date,
        savedAt: Date,
        modelID: String?,
        agentID: String?,
        agentName: String?,
        selectedTools: [String],
        selectedSkillIDs: [String],
        thinkingSelection: String?,
        contextWindow: MLXTerminalSavedSessionContextWindow? = nil,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        transcriptHistory: [AgentRuntimeMessage]? = nil
    ) {
        self.version = version
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cacheKey = cacheKey?.nilIfBlank
        self.workingDirectoryPath = URL(fileURLWithPath: workingDirectoryPath)
            .standardizedFileURL
            .path
        self.createdAt = createdAt
        self.savedAt = savedAt
        self.modelID = modelID?.nilIfBlank
        self.agentID = agentID?.nilIfBlank
        self.agentName = agentName?.nilIfBlank
        self.selectedTools = selectedTools
        self.selectedSkillIDs = selectedSkillIDs
        self.thinkingSelection = thinkingSelection?.nilIfBlank
        self.contextWindow = contextWindow
        self.systemPrompt = systemPrompt?.nilIfBlank
        self.history = history
        self.transcriptHistory = transcriptHistory
    }

    public var displayHistory: [AgentRuntimeMessage] {
        transcriptHistory ?? history
    }

    public var messageCount: Int {
        displayHistory.filter { $0.role != .system }.count
    }
}

public enum MLXTerminalSessionStore {
    public static let fileExtension = "mlxsession"

    public static func save(
        _ session: MLXTerminalSavedSession,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) throws -> URL {
        try validate(session)
        let directoryURL = sessionsDirectoryURL(
            for: URL(fileURLWithPath: session.workingDirectoryPath),
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = sessionFileURL(
            name: session.name,
            workingDirectory: URL(fileURLWithPath: session.workingDirectoryPath),
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    public static func load(
        name: String,
        workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) throws -> MLXTerminalSavedSession {
        try load(
            from: sessionFileURL(
                name: name,
                workingDirectory: workingDirectory,
                fileManager: fileManager,
                supportDirectoryURL: supportDirectoryURL
            )
        )
    }

    public static func load(
        from fileURL: URL
    ) throws -> MLXTerminalSavedSession {
        let data = try Data(contentsOf: fileURL)
        let session = try PropertyListDecoder().decode(
            MLXTerminalSavedSession.self,
            from: data
        )
        try validate(session)
        return session
    }

    public static func savedSessions(
        for workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) throws -> [MLXTerminalSavedSession] {
        let directoryURL = sessionsDirectoryURL(
            for: workingDirectory,
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        let workingDirectoryPath = normalizedWorkingDirectoryPath(workingDirectory)
        return fileURLs
            .filter { $0.pathExtension == fileExtension }
            .compactMap { try? load(from: $0) }
            .filter { $0.workingDirectoryPath == workingDirectoryPath }
            .sorted {
                if $0.savedAt == $1.savedAt {
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                return $0.savedAt > $1.savedAt
            }
    }

    @discardableResult
    public static func delete(
        name: String,
        workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) throws -> Bool {
        let fileURL = sessionFileURL(
            name: name,
            workingDirectory: workingDirectory,
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return false
        }
        try fileManager.removeItem(at: fileURL)
        return true
    }

    public static func sessionFileURL(
        name: String,
        workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) -> URL {
        sessionsDirectoryURL(
            for: workingDirectory,
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        .appendingPathComponent(filename(for: name))
    }

    public static func sessionsDirectoryURL(
        for workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) -> URL {
        (supportDirectoryURL?.standardizedFileURL
            ?? MLXAppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager))
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(projectKey(for: workingDirectory), isDirectory: true)
    }

    public static func filename(for name: String) -> String {
        "\(filenameStem(for: name)).\(fileExtension)"
    }

    public static func filenameStem(for name: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var output = ""
        var lastWasSeparator = false
        for scalar in trimmedName.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-"
                || scalar == "_"
                || scalar == "."
            if isAllowed {
                output.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                output.append("_")
                lastWasSeparator = true
            }
        }
        let sanitized = output
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
            .nilIfBlank
        return sanitized ?? "session"
    }

    public static func projectKey(for workingDirectory: URL) -> String {
        let path = normalizedWorkingDirectoryPath(workingDirectory)
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func normalizedWorkingDirectoryPath(_ workingDirectory: URL) -> String {
        workingDirectory.standardizedFileURL.path
    }

    private static func validate(_ session: MLXTerminalSavedSession) throws {
        guard session.version == MLXTerminalSavedSession.currentVersion else {
            throw MLXTerminalSessionStoreError.unsupportedVersion(session.version)
        }
        guard session.name.nilIfBlank != nil else {
            throw MLXTerminalSessionStoreError.emptyName
        }
        guard session.sessionID.nilIfBlank != nil else {
            throw MLXTerminalSessionStoreError.emptySessionID
        }
        guard session.workingDirectoryPath.nilIfBlank != nil else {
            throw MLXTerminalSessionStoreError.emptyWorkingDirectory
        }
    }
}

public enum MLXTerminalSessionStoreError: LocalizedError, Equatable {
    case emptyName
    case emptySessionID
    case emptyWorkingDirectory
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Session name cannot be empty."
        case .emptySessionID:
            return "Session snapshot is missing a session id."
        case .emptyWorkingDirectory:
            return "Session snapshot is missing a working directory."
        case let .unsupportedVersion(version):
            return "Unsupported session file version: \(version)."
        }
    }
}
