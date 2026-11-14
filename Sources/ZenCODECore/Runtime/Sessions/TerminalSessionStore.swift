//
//  TerminalSessionStore.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

public struct TerminalSavedSessionContextWindow: Codable, Equatable, Sendable {
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

public struct TerminalSavedSession: Codable, Equatable, Sendable {
    public static let currentVersion = 5
    /// ``autosaveChannel`` of a session the ACP bridge (`zen --acp`) saved by
    /// itself at the end of a turn.
    public static let acpAutosaveChannel = "acp"

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
    /// Canonical names of the selected prompt skills. Sessions saved before
    /// the name became the only skill identifier carry `selectedSkillIDs`
    /// instead: that key is ignored and they decode with no skill selected.
    public let selectedSkillNames: [String]
    public let thinkingSelection: String?
    public let contextWindow: TerminalSavedSessionContextWindow?
    public let systemPrompt: String?
    /// Mutable context stored separately from the stable system prompt (v5+).
    /// Optional decoding keeps v1–v4 snapshots restorable as legacy prompts.
    public let dynamicContext: String?
    public let history: [AgentRuntimeMessage]
    public let transcriptHistory: [AgentRuntimeMessage]?
    public let activePlan: TerminalSessionPlan?
    /// Plans that follow `activePlan` in a Planner sequence, in order. Sessions
    /// saved without it decode to `nil`; the writer sets it only when the queue
    /// is non-empty, so existing files and sessions without a queue encode
    /// identically (no new key, no version bump).
    public let queuedPlans: [TerminalSessionPlan]?
    public let taskGraph: TaskGraphSnapshot?
    /// Session checkpoint tree (v4+).
    public let checkpointTree: SessionCheckpointTree
    /// The channel that saved the session by itself, without a command
    /// (``acpAutosaveChannel``); `nil` for a session saved with `/sessions`.
    /// Sessions saved without it decode to `nil`, and the writer omits the key
    /// when it is `nil`, so existing files and the sessions saved with a
    /// command encode identically (no new key, no version bump).
    public let autosaveChannel: String?

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
        selectedSkillNames: [String],
        thinkingSelection: String?,
        contextWindow: TerminalSavedSessionContextWindow? = nil,
        systemPrompt: String?,
        dynamicContext: String? = nil,
        history: [AgentRuntimeMessage],
        transcriptHistory: [AgentRuntimeMessage]? = nil,
        activePlan: TerminalSessionPlan? = nil,
        queuedPlans: [TerminalSessionPlan]? = nil,
        taskGraph: TaskGraphSnapshot? = nil,
        checkpointTree: SessionCheckpointTree,
        autosaveChannel: String? = nil
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
        self.selectedSkillNames = selectedSkillNames
        self.thinkingSelection = thinkingSelection?.nilIfBlank
        self.contextWindow = contextWindow
        self.systemPrompt = systemPrompt?.nilIfBlank
        self.dynamicContext = dynamicContext?.nilIfBlank
        self.history = history
        self.transcriptHistory = transcriptHistory
        self.activePlan = activePlan
        self.queuedPlans = queuedPlans
        self.taskGraph = taskGraph
        self.checkpointTree = checkpointTree
        self.autosaveChannel = autosaveChannel?.nilIfBlank
    }

    /// Decodes exactly what the synthesized conformance would, except that
    /// `selectedSkillNames` may be absent (a session saved while skills were
    /// identified by id) and then decodes as empty.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(Int.self, forKey: .version)
        self.name = try container.decode(String.self, forKey: .name)
        self.sessionID = try container.decode(String.self, forKey: .sessionID)
        self.cacheKey = try container.decodeIfPresent(String.self, forKey: .cacheKey)
        self.workingDirectoryPath = try container.decode(String.self, forKey: .workingDirectoryPath)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.savedAt = try container.decode(Date.self, forKey: .savedAt)
        self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        self.agentID = try container.decodeIfPresent(String.self, forKey: .agentID)
        self.agentName = try container.decodeIfPresent(String.self, forKey: .agentName)
        self.selectedTools = try container.decode([String].self, forKey: .selectedTools)
        self.selectedSkillNames = try container.decodeIfPresent([String].self, forKey: .selectedSkillNames) ?? []
        self.thinkingSelection = try container.decodeIfPresent(String.self, forKey: .thinkingSelection)
        self.contextWindow = try container.decodeIfPresent(
            TerminalSavedSessionContextWindow.self,
            forKey: .contextWindow
        )
        self.systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt)
        self.dynamicContext = try container.decodeIfPresent(String.self, forKey: .dynamicContext)
        self.history = try container.decode([AgentRuntimeMessage].self, forKey: .history)
        self.transcriptHistory = try container.decodeIfPresent(
            [AgentRuntimeMessage].self,
            forKey: .transcriptHistory
        )
        self.activePlan = try container.decodeIfPresent(TerminalSessionPlan.self, forKey: .activePlan)
        self.queuedPlans = try container.decodeIfPresent([TerminalSessionPlan].self, forKey: .queuedPlans)
        self.taskGraph = try container.decodeIfPresent(TaskGraphSnapshot.self, forKey: .taskGraph)
        self.checkpointTree = try container.decode(SessionCheckpointTree.self, forKey: .checkpointTree)
        self.autosaveChannel = try container.decodeIfPresent(String.self, forKey: .autosaveChannel)
    }

    public var displayHistory: [AgentRuntimeMessage] {
        transcriptHistory ?? history
    }

    public var messageCount: Int {
        displayHistory.filter { $0.role != .system }.count
    }
}

public enum TerminalSessionStore {
    public static let fileExtension = "session"
    /// Extension of the optional engine checkpoint (DS4 KV cache) stored next
    /// to a `.session` file. It is written only by an explicit session save
    /// (`TerminalChat.saveCurrentSession`) and removed together with the session.
    public static let engineCheckpointFileExtension = "ds4kv"

    public static func save(
        _ session: TerminalSavedSession,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) throws -> URL {
        try validate(session)
        let fileURL = sessionFileURL(
            name: session.name,
            workingDirectory: URL(fileURLWithPath: session.workingDirectoryPath),
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(session)
        try SensitiveFilePermissions.write(data, to: fileURL, fileManager: fileManager)
        return fileURL
    }

    public static func load(
        name: String,
        workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) throws -> TerminalSavedSession {
        let directoryURL = sessionsDirectoryURL(
            for: workingDirectory,
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        try migrateNonCurrentSessionFiles(
            in: directoryURL,
            fileManager: fileManager
        )
        return try load(
            from: directoryURL.appendingPathComponent(filename(for: name))
        )
    }

    public static func load(
        from fileURL: URL
    ) throws -> TerminalSavedSession {
        try SensitiveFilePermissions.hardenExistingFile(at: fileURL)
        let data = try Data(contentsOf: fileURL)
        let session = try PropertyListDecoder().decode(
            TerminalSavedSession.self,
            from: data
        )
        try validate(session)
        return session
    }

    /// The saved sessions of the project of `workingDirectory`, most recently
    /// saved first. With `migrating` (the default) the session files of the
    /// directory that do not have their current name are renamed first;
    /// `false` only lists, moving nothing, for a reader that runs beside the
    /// saves (the shell snapshot of ``ChatSessionHost``).
    public static func savedSessions(
        for workingDirectory: URL,
        migrating: Bool = true,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) throws -> [TerminalSavedSession] {
        let directoryURL = sessionsDirectoryURL(
            for: workingDirectory,
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        var migratedSessions: [String: TerminalSavedSession] = [:]
        if migrating {
            migratedSessions = try migrateNonCurrentSessionFiles(
                in: directoryURL,
                fileManager: fileManager
            )
        }
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        // The directory is keyed by project name: every session saved from a
        // folder with this name belongs to the project, whatever its path.
        let projectName = ProjectStorageKey.projectName(for: workingDirectory)
        return fileURLs
            .filter { $0.pathExtension == fileExtension }
            .compactMap { url in
                if let session = migratedSessions[url.lastPathComponent] {
                    return session
                }
                do {
                    return try load(from: url)
                } catch {
                    ZenLogger.warning(
                        .sessionService,
                        "Failed to load saved session \(url.lastPathComponent): \(error.localizedDescription)"
                    )
                    return nil
                }
            }
            .filter {
                ProjectStorageKey.projectName(forPath: $0.workingDirectoryPath) == projectName
            }
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
        // The engine checkpoint lives and dies with its session (best effort:
        // an orphan checkpoint is removed even when the `.session` is gone).
        deleteEngineCheckpoint(
            name: name,
            workingDirectory: workingDirectory,
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
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

    /// URL of the engine checkpoint of the saved session `name`: the session
    /// file URL with the `ds4kv` extension (same directory, same stem).
    public static func engineCheckpointURL(
        name: String,
        workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) -> URL {
        sessionFileURL(
            name: name,
            workingDirectory: workingDirectory,
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        .deletingPathExtension()
        .appendingPathExtension(engineCheckpointFileExtension)
    }

    /// Removes the engine checkpoint of the saved session `name`, if any.
    /// Best effort: a missing file is not an error and a failure is logged.
    /// Returns whether a file was removed.
    @discardableResult
    public static func deleteEngineCheckpoint(
        name: String,
        workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) -> Bool {
        let checkpointURL = engineCheckpointURL(
            name: name,
            workingDirectory: workingDirectory,
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        return removeEngineCheckpoint(at: checkpointURL, fileManager: fileManager)
    }

    /// Removes the engine checkpoint at `checkpointURL`, if any, as
    /// ``deleteEngineCheckpoint(name:workingDirectory:fileManager:supportDirectoryURL:)``
    /// does.
    @discardableResult
    private static func removeEngineCheckpoint(
        at checkpointURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: checkpointURL.path) else {
            return false
        }
        do {
            try fileManager.removeItem(at: checkpointURL)
            return true
        } catch {
            ZenLogger.warning(
                .sessionService,
                "Failed to remove engine checkpoint \(checkpointURL.lastPathComponent): \(error.localizedDescription)"
            )
            return false
        }
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
        sessionsRootDirectoryURL(
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        .appendingPathComponent(projectKey(for: workingDirectory), isDirectory: true)
    }

    /// The `sessions` directory of the support directory, which holds one
    /// directory per project key.
    static func sessionsRootDirectoryURL(
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) -> URL {
        (supportDirectoryURL?.standardizedFileURL
            ?? AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager))
            .appendingPathComponent("sessions", isDirectory: true)
    }

    public static func filename(for name: String) -> String {
        "\(filenameStem(for: name))-\(filenameHash(for: name)).\(fileExtension)"
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

    /// Keeps the readable stem while disambiguating distinct names that share a
    /// sanitized spelling (for example, `review/a` and `review:a`).
    public static func filenameHash(for name: String) -> String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(Data(normalizedName.utf8).sha256Hex().prefix(24))
    }

    /// Name-based key of the project (see ``ProjectStorageKey``): the saved
    /// sessions, the task graphs and the saved-plan library of a project
    /// follow its folder when it is moved.
    public static func projectKey(for workingDirectory: URL) -> String {
        ProjectStorageKey.key(for: workingDirectory)
    }

    public static func normalizedWorkingDirectoryPath(_ workingDirectory: URL) -> String {
        workingDirectory.standardizedFileURL.path
    }

    /// Returns the sessions it decoded, keyed by the file name each file has after
    /// the migration (the name the listing sees), so `savedSessions` does not
    /// decode them again: its list reflects what this same call read.
    @discardableResult
    private static func migrateNonCurrentSessionFiles(
        in directoryURL: URL,
        fileManager: FileManager
    ) throws -> [String: TerminalSavedSession] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return [:]
        }
        var decodedSessions: [String: TerminalSavedSession] = [:]

        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        for sourceURL in fileURLs {
            // Engine checkpoints (and their temporary files, `<name>.ds4kv.tmp.*`)
            // are not sessions and can weigh gigabytes: never read them here.
            guard !isEngineCheckpointArtifact(sourceURL) else {
                continue
            }
            // A save in progress, of this process or another one, writes
            // `.<name>.<UUID>.tmp` before it renames it: moving it would make
            // that rename fail.
            guard !isHiddenOrTemporaryFile(sourceURL) else {
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: sourceURL.path,
                isDirectory: &isDirectory
            ), !isDirectory.boolValue,
            let session = try? load(from: sourceURL) else {
                continue
            }

            let destinationURL = directoryURL.appendingPathComponent(
                filename(for: session.name)
            )
            guard sourceURL.standardizedFileURL != destinationURL.standardizedFileURL,
                  !fileManager.fileExists(atPath: destinationURL.path) else {
                decodedSessions[sourceURL.lastPathComponent] = session
                continue
            }
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                decodedSessions[destinationURL.lastPathComponent] = session
            } catch {
                ZenLogger.warning(
                    .sessionService,
                    "Failed to import session \(sourceURL.lastPathComponent): \(error.localizedDescription)"
                )
                decodedSessions[sourceURL.lastPathComponent] = session
            }
        }
        return decodedSessions
    }

    private static func isEngineCheckpointArtifact(_ url: URL) -> Bool {
        url.lastPathComponent.contains(".\(engineCheckpointFileExtension)")
    }

    /// A hidden file or a `*.tmp`: never a session to migrate.
    private static func isHiddenOrTemporaryFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(".") || url.pathExtension == "tmp"
    }

    private static func validate(_ session: TerminalSavedSession) throws {
        guard session.version == TerminalSavedSession.currentVersion else {
            throw TerminalSessionStoreError.unsupportedVersion(session.version)
        }
        guard session.name.nilIfBlank != nil else {
            throw TerminalSessionStoreError.emptyName
        }
        guard session.sessionID.nilIfBlank != nil else {
            throw TerminalSessionStoreError.emptySessionID
        }
        guard session.workingDirectoryPath.nilIfBlank != nil else {
            throw TerminalSessionStoreError.emptyWorkingDirectory
        }
    }
}

// MARK: - Lookup by session id

/// What a saved session file says about itself before its conversation: which
/// session it is, where and when it was saved, and whether a channel saved it
/// by itself (``TerminalSavedSession/autosaveChannel``). Decoded without the
/// history, the transcript, the plans, the task graph, or the checkpoint tree.
struct TerminalSavedSessionHeader: Decodable, Equatable, Sendable {
    let version: Int
    let name: String
    let sessionID: String
    let workingDirectoryPath: String
    let createdAt: Date
    let savedAt: Date
    let autosaveChannel: String?
}

/// A saved session file and its header.
struct TerminalSavedSessionFile: Equatable, Sendable {
    let url: URL
    let header: TerminalSavedSessionHeader
}

/// The saved sessions are indexed by name; a channel that knows a session
/// only by its id (an ACP client) finds and lists them here. These reads
/// decode only the header of every file (``TerminalSavedSessionHeader``),
/// rename, migrate, and harden nothing, and skip the files a listing would not
/// read as sessions (hidden and temporary files, DS4 checkpoints and their
/// temporary files, directories) and every file that cannot be read as a
/// session of the current version, without failing.
extension TerminalSessionStore {
    /// The saved session files of `directoryURL`, one project's directory,
    /// with their headers, in no particular order; empty when the directory
    /// does not exist or cannot be listed.
    static func savedSessionFiles(
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) -> [TerminalSavedSessionFile] {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        let decoder = PropertyListDecoder()
        return fileURLs.compactMap { url in
            guard !isEngineCheckpointArtifact(url), !isHiddenOrTemporaryFile(url) else {
                return nil
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  // Mapped, not copied: only the header of every file is read.
                  let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let header = try? decoder.decode(TerminalSavedSessionHeader.self, from: data),
                  header.version == TerminalSavedSession.currentVersion,
                  header.name.nilIfBlank != nil,
                  header.sessionID.nilIfBlank != nil,
                  header.workingDirectoryPath.nilIfBlank != nil else {
                return nil
            }
            return TerminalSavedSessionFile(url: url, header: header)
        }
    }

    /// The saved session of the session `sessionID` that a channel restoring
    /// it starts from, in the project of `workingDirectory` and among the
    /// sessions a listing of that project shows: the one saved by
    /// `preferredAutosaveChannel` when there is one, else the most recently
    /// saved, loaded in full. A file that cannot be loaded gives way to the
    /// next one; `nil` when none is left.
    static func savedSession(
        sessionID rawSessionID: String,
        workingDirectory: URL,
        preferringAutosaveChannel preferredAutosaveChannel: String,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) -> TerminalSavedSession? {
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let projectName = ProjectStorageKey.projectName(for: workingDirectory)
        let candidates = savedSessionFiles(
            in: sessionsDirectoryURL(
                for: workingDirectory,
                fileManager: fileManager,
                supportDirectoryURL: supportDirectoryURL
            ),
            fileManager: fileManager
        )
        .filter {
            $0.header.sessionID == sessionID
                && ProjectStorageKey.projectName(forPath: $0.header.workingDirectoryPath) == projectName
        }
        .sorted { lhs, rhs in
            let lhsPreferred = lhs.header.autosaveChannel == preferredAutosaveChannel
            let rhsPreferred = rhs.header.autosaveChannel == preferredAutosaveChannel
            if lhsPreferred != rhsPreferred {
                return lhsPreferred
            }
            if lhs.header.savedAt != rhs.header.savedAt {
                return lhs.header.savedAt > rhs.header.savedAt
            }
            return lhs.header.name.localizedStandardCompare(rhs.header.name) == .orderedAscending
        }
        for candidate in candidates {
            do {
                let session = try load(from: candidate.url)
                if session.sessionID == sessionID {
                    return session
                }
            } catch {
                ZenLogger.warning(
                    .sessionService,
                    "Failed to load saved session \(candidate.url.lastPathComponent): \(error.localizedDescription)"
                )
            }
        }
        return nil
    }

    /// The saved session files of the session `sessionID` that
    /// `autosaveChannel` saved by itself, in every project.
    static func autosavedSessionFiles(
        sessionID rawSessionID: String,
        autosaveChannel: String,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) -> [TerminalSavedSessionFile] {
        let sessionID = rawSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return projectDirectoryURLs(fileManager: fileManager, supportDirectoryURL: supportDirectoryURL)
            .flatMap { savedSessionFiles(in: $0, fileManager: fileManager) }
            .filter {
                $0.header.sessionID == sessionID && $0.header.autosaveChannel == autosaveChannel
            }
    }

    /// The saved session files that `autosaveChannel` saved by itself, in no
    /// particular order. With `workingDirectory`, only those of its project
    /// saved in exactly that working directory: the standardized paths are
    /// compared, so another folder with the same name, whose sessions share
    /// the project's directory, is not included. With `nil`, those of every
    /// project, each one only in the directory of its own project, where a
    /// lookup of its working directory finds it.
    static func autosavedSessionFiles(
        autosaveChannel: String,
        workingDirectory: URL?,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) -> [TerminalSavedSessionFile] {
        guard let workingDirectory else {
            return projectDirectoryURLs(fileManager: fileManager, supportDirectoryURL: supportDirectoryURL)
                .flatMap { directoryURL in
                    savedSessionFiles(in: directoryURL, fileManager: fileManager).filter {
                        $0.header.autosaveChannel == autosaveChannel
                            && projectKey(for: URL(fileURLWithPath: $0.header.workingDirectoryPath))
                                == directoryURL.lastPathComponent
                    }
                }
        }
        let workingDirectoryPath = normalizedWorkingDirectoryPath(workingDirectory)
        return savedSessionFiles(
            in: sessionsDirectoryURL(
                for: workingDirectory,
                fileManager: fileManager,
                supportDirectoryURL: supportDirectoryURL
            ),
            fileManager: fileManager
        )
        .filter {
            $0.header.autosaveChannel == autosaveChannel
                && normalizedWorkingDirectoryPath(URL(fileURLWithPath: $0.header.workingDirectoryPath))
                    == workingDirectoryPath
        }
    }

    /// The directory of every project under ``sessionsRootDirectoryURL(fileManager:supportDirectoryURL:)``,
    /// sorted by name, without hidden entries and files; empty when the
    /// `sessions` directory does not exist or cannot be listed.
    private static func projectDirectoryURLs(
        fileManager: FileManager,
        supportDirectoryURL: URL?
    ) -> [URL] {
        let rootURL = sessionsRootDirectoryURL(
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        guard let projectURLs = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return projectURLs
            .filter { url in
                var isDirectory: ObjCBool = false
                return !url.lastPathComponent.hasPrefix(".")
                    && fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Deletes the saved session `file` with its engine checkpoint, as
    /// ``delete(name:workingDirectory:fileManager:supportDirectoryURL:)``
    /// does: the checkpoint first, best effort, then the session file, whose
    /// removal throws. Returns whether the session file was there.
    @discardableResult
    static func deleteSavedSessionFile(
        _ file: TerminalSavedSessionFile,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let checkpointURL = file.url
            .deletingLastPathComponent()
            .appendingPathComponent(filename(for: file.header.name))
            .deletingPathExtension()
            .appendingPathExtension(engineCheckpointFileExtension)
        removeEngineCheckpoint(at: checkpointURL, fileManager: fileManager)
        guard fileManager.fileExists(atPath: file.url.path) else {
            return false
        }
        try fileManager.removeItem(at: file.url)
        return true
    }
}

public enum TerminalSessionStoreError: LocalizedError, Equatable {
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
