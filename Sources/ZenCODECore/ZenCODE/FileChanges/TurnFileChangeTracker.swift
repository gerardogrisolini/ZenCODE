//
//  TurnFileChangeTracker.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public actor TurnFileChangeTracker {
    struct Snapshot {
        let absolutePath: String
        let displayPath: String
        let beforeData: Data?
        let existedInitially: Bool
    }

    struct DiffStats {
        let additions: Int
        let deletions: Int
        let isBinary: Bool
    }

    let fileManager = FileManager.default
    let baseDirectoryURL: URL
    let baseDirectoryName: String
    var snapshotsByPath: [String: Snapshot] = [:]
    var cachedSummary: TurnFileChangeSummary?
    var didFinalizeSummary = false
    /// Content of files already dirty (vs. the index/HEAD) when the turn began,
    /// keyed by absolute path. A present key with `nil` value means the path did
    /// not exist on disk at turn start. Used to bound worktree reconciliation to
    /// changes that actually happened during this turn.
    var initialWorktreeDirtyContents: [String: Data?] = [:]
    var didCaptureInitialWorktree = false

    public init(workspacePath: String?) {
        let baseURL: URL
        if let normalizedWorkspaceRoot = XcodeWorkspaceContext.normalizedProjectRootPath(
            explicitPath: nil,
            workspacePath: workspacePath
        ),
           !normalizedWorkspaceRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            baseURL = URL(fileURLWithPath: normalizedWorkspaceRoot).standardizedFileURL
        } else {
            baseURL = Self.platformDefaultBaseDirectoryURL()
        }

        self.baseDirectoryURL = baseURL
        self.baseDirectoryName = baseURL.lastPathComponent
    }

    public init(baseDirectoryURL: URL) {
        let baseURL = baseDirectoryURL.standardizedFileURL
        self.baseDirectoryURL = baseURL
        self.baseDirectoryName = baseURL.lastPathComponent
    }

    public func captureBaselineIfNeeded(for request: ToolRequest) {
        guard !didFinalizeSummary else {
            return
        }

        for rawPath in trackedPathCandidates(for: request) {
            let absolutePath = resolvedAbsolutePath(for: rawPath)
            guard snapshotsByPath[absolutePath] == nil else {
                continue
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: absolutePath, isDirectory: &isDirectory)
            if exists && isDirectory.boolValue {
                continue
            }

            let beforeData: Data?
            if exists {
                beforeData = try? Data(contentsOf: URL(fileURLWithPath: absolutePath))
                if beforeData == nil {
                    continue
                }
            } else {
                beforeData = nil
            }

            snapshotsByPath[absolutePath] = Snapshot(
                absolutePath: absolutePath,
                displayPath: displayPath(for: absolutePath),
                beforeData: beforeData,
                existedInitially: exists
            )
        }
    }

    public func captureBaselineIfNeeded(forAgentToolCall toolCall: DirectAgentToolCall) {
        let request = ToolRequest(
            name: Self.normalizedTrackedToolName(toolCall.name),
            arguments: Self.jsonValueArguments(from: toolCall.argumentsObject)
        )
        captureBaselineIfNeeded(for: request)
    }

    /// Records the set of files already modified relative to `HEAD`/index when
    /// the turn starts, so end-of-turn worktree reconciliation can attribute
    /// only the changes produced during the turn (including those made by tools
    /// whose paths cannot be predicted, such as `local.exec`, sub-agents, and
    /// MCP tools). Must be invoked once at the beginning of a turn to enable
    /// reconciliation.
    public func prepareInitialWorktreeBaselineIfNeeded() async {
        guard !didCaptureInitialWorktree else {
            return
        }
        didCaptureInitialWorktree = true
        #if canImport(Darwin) || canImport(Glibc)
        await captureInitialWorktreeBaseline()
        #endif
    }

    public func makeSummary() async -> TurnFileChangeSummary? {
        if didFinalizeSummary {
            return cachedSummary
        }

        didFinalizeSummary = true

        #if canImport(Darwin) || canImport(Glibc)
        await reconcileWorktreeChangesIfNeeded()
        #endif

        var entries: [TurnFileChangeSummary.Entry] = []
        for snapshot in snapshotsByPath.values {
            var isDirectory: ObjCBool = false
            let existsNow = fileManager.fileExists(
                atPath: snapshot.absolutePath,
                isDirectory: &isDirectory
            ) && !isDirectory.boolValue

            let afterData: Data?
            if existsNow {
                afterData = try? Data(contentsOf: URL(fileURLWithPath: snapshot.absolutePath))
                if afterData == nil {
                    continue
                }
            } else {
                afterData = nil
            }

            if snapshot.existedInitially == existsNow,
               snapshot.beforeData == afterData {
                continue
            }

            let status: TurnFileChangeSummary.Entry.Status
            switch (snapshot.existedInitially, existsNow) {
            case (false, true):
                status = .added
            case (true, false):
                status = .deleted
            default:
                status = .modified
            }

            let diffStats = await resolvedDiffStats(
                before: snapshot.beforeData,
                after: afterData,
                status: status
            )
            let patch = await gitPatch(
                before: snapshot.beforeData,
                after: afterData,
                displayPath: snapshot.displayPath,
                existedBefore: snapshot.existedInitially,
                existsNow: existsNow
            )

            entries.append(
                TurnFileChangeSummary.Entry(
                    path: snapshot.displayPath,
                    additions: diffStats?.additions ?? 0,
                    deletions: diffStats?.deletions ?? 0,
                    status: status,
                    isBinary: diffStats?.isBinary ?? false,
                    existedBefore: snapshot.existedInitially,
                    beforeDataBase64: snapshot.beforeData?.base64EncodedString(),
                    patch: patch
                )
            )
        }

        entries = entries
            .sorted { lhs, rhs in
                lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }

        cachedSummary = entries.isEmpty ? nil : TurnFileChangeSummary(entries: entries)
        return cachedSummary
    }

    func resolvedDiffStats(
        before: Data?,
        after: Data?,
        status: TurnFileChangeSummary.Entry.Status
    ) async -> DiffStats? {
        let primaryStats = await diffStats(before: before, after: after)
        if let primaryStats,
           primaryStats.isBinary || primaryStats.additions > 0 || primaryStats.deletions > 0 {
            return primaryStats
        }

        return fallbackDiffStats(before: before, after: after, status: status) ?? primaryStats
    }

    func trackedPathCandidates(for request: ToolRequest) -> [String] {
        switch Self.normalizedTrackedToolName(request.name) {
        case "local.writeFile":
            return compactedPaths([
                request.arguments["file_path"]?.stringValue,
                request.arguments["filePath"]?.stringValue,
                request.arguments["path"]?.stringValue
            ])
        case "local.replace", "local.editFile", "local.multiEdit", "local.delete", "local.append":
            return compactedPaths([
                request.arguments["path"]?.stringValue,
                request.arguments["file_path"]?.stringValue,
                request.arguments["filePath"]?.stringValue
            ])
        case "local.applyPatch":
            let rawPatch = request.arguments["patch"]?.stringValue
                ?? request.arguments["diff"]?.stringValue
            return compactedPaths(Self.patchPathCandidates(from: rawPatch))
        case "local.move", "XcodeMV":
            return compactedPaths([
                request.arguments["sourcePath"]?.stringValue,
                request.arguments["destinationPath"]?.stringValue
            ])
        case "XcodeUpdate", "XcodeWrite", "XcodeRM":
            return compactedPaths([
                request.arguments["filePath"]?.stringValue
                    ?? request.arguments["path"]?.stringValue
            ])
        default:
            return []
        }
    }

    static func patchPathCandidates(from rawPatch: String?) -> [String] {
        guard let rawPatch,
              !rawPatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var candidates: [String] = []
        let lines = rawPatch.components(separatedBy: "\n")

        func appendStripped(_ value: String) {
            guard let normalized = normalizedPatchPath(value) else {
                return
            }
            candidates.append(normalized)
        }

        for rawLine in lines {
            let line = rawLine
            if let value = sectionValue(line, prefix: "*** Add File: ")
                ?? sectionValue(line, prefix: "*** Update File: ")
                ?? sectionValue(line, prefix: "*** Delete File: ") {
                appendStripped(value)
            } else if line.hasPrefix("+++ ") {
                appendStripped(String(line.dropFirst(4)))
            } else if line.hasPrefix("--- ") {
                appendStripped(String(line.dropFirst(4)))
            }
        }

        return candidates
    }

    private static func sectionValue(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else {
            return nil
        }
        let value = String(line.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func normalizedPatchPath(_ rawValue: String) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tab = value.firstIndex(of: "\t") {
            value = String(value[..<tab]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty, value != "/dev/null" else {
            return nil
        }
        if value.hasPrefix("a/") || value.hasPrefix("b/") {
            value.removeFirst(2)
        }
        return value.isEmpty ? nil : value
    }

    private static func normalizedTrackedToolName(_ name: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if XcodeToolIntegration.isToolName(trimmedName) {
            return XcodeToolIntegration.rawToolName(fromPublicName: trimmedName)
        }
        return trimmedName
    }

    private static func jsonValueArguments(
        from object: [String: Any]
    ) -> [String: JSONValue] {
        object.reduce(into: [:]) { result, pair in
            if let value = jsonValue(from: pair.value) {
                result[pair.key] = value
            }
        }
    }

    private static func jsonValue(from value: Any) -> JSONValue? {
        switch value {
        case let value as JSONValue:
            return value
        case let value as String:
            return .string(value)
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .number(Double(value))
        case let value as Double:
            return value.isFinite ? .number(value) : nil
        case let value as [String: Any]:
            return .object(jsonValueArguments(from: value))
        case let value as [Any]:
            return .array(value.compactMap(jsonValue(from:)))
        default:
            return nil
        }
    }

    func compactedPaths(_ paths: [String?]) -> [String] {
        var resolved: [String] = []
        var seen: Set<String> = []

        for path in paths {
            guard let rawPath = path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawPath.isEmpty,
                  !seen.contains(rawPath) else {
                continue
            }

            seen.insert(rawPath)
            resolved.append(rawPath)
        }

        return resolved
    }

    func resolvedAbsolutePath(for rawPath: String) -> String {
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath).standardizedFileURL.path
        }

        let normalizedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let literalCandidate = baseDirectoryURL
            .appendingPathComponent(normalizedPath)
            .standardizedFileURL
            .path

        if shouldPreferCandidatePath(literalCandidate) {
            return literalCandidate
        }

        let deduplicatedPath = deduplicatedProjectRelativePath(normalizedPath)
        guard deduplicatedPath != normalizedPath else {
            return literalCandidate
        }

        let deduplicatedCandidate = baseDirectoryURL
            .appendingPathComponent(deduplicatedPath)
            .standardizedFileURL
            .path
        if shouldPreferCandidatePath(deduplicatedCandidate) {
            return deduplicatedCandidate
        }

        return literalCandidate
    }

    func displayPath(for absolutePath: String) -> String {
        let standardizedPath = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        let basePath = baseDirectoryURL.path

        guard standardizedPath == basePath || standardizedPath.hasPrefix(basePath + "/") else {
            return standardizedPath
        }

        let relativePath = String(standardizedPath.dropFirst(basePath.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return deduplicatedProjectRelativePath(relativePath)
    }

    func deduplicatedProjectRelativePath(_ path: String) -> String {
        let normalizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else {
            return normalizedPath
        }

        let components = normalizedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2,
              components[0] == Substring(baseDirectoryName),
              components[1] == Substring(baseDirectoryName) else {
            return normalizedPath
        }

        return components.dropFirst().joined(separator: "/")
    }

    func shouldPreferCandidatePath(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            return !isDirectory.boolValue
        }

        let parentDirectoryPath = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path
        var parentIsDirectory: ObjCBool = false
        return fileManager.fileExists(
            atPath: parentDirectoryPath,
            isDirectory: &parentIsDirectory
        ) && parentIsDirectory.boolValue
    }

    func diffStats(before: Data?, after: Data?) async -> DiffStats? {
        #if canImport(Darwin) || canImport(Glibc)
        await platformDiffStats(before: before, after: after)
        #else
        fallbackDiffStats(before: before, after: after, status: .modified)
        #endif
    }

    func gitPatch(
        before: Data?,
        after: Data?,
        displayPath: String,
        existedBefore: Bool,
        existsNow: Bool
    ) async -> String? {
        #if canImport(Darwin) || canImport(Glibc)
        await platformGitPatch(
            before: before,
            after: after,
            displayPath: displayPath,
            existedBefore: existedBefore,
            existsNow: existsNow
        )
        #else
        nil
        #endif
    }

    func rewrittenPatch(
        _ patch: String,
        displayPath: String,
        beforePath: String,
        afterPath: String
    ) -> String? {
        let trimmedPatch = patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPatch.isEmpty else {
            return nil
        }

        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let rewrittenLines = lines.map { line -> String in
            if line.hasPrefix("diff --git ") {
                return "diff --git a/\(displayPath) b/\(displayPath)"
            }

            if line.hasPrefix("--- ") {
                return "--- \(beforePath)"
            }

            if line.hasPrefix("+++ ") {
                return "+++ \(afterPath)"
            }

            return line
        }

        return rewrittenLines.joined(separator: "\n")
    }

    func fallbackDiffStats(
        before: Data?,
        after: Data?,
        status: TurnFileChangeSummary.Entry.Status
    ) -> DiffStats? {
        let beforeData = before ?? Data()
        let afterData = after ?? Data()
        if beforeData == afterData {
            return nil
        }

        if containsLikelyBinaryData(beforeData) || containsLikelyBinaryData(afterData) {
            return DiffStats(additions: 0, deletions: 0, isBinary: true)
        }

        let beforeLines = lineFragments(from: beforeData)
        let afterLines = lineFragments(from: afterData)

        switch status {
        case .added:
            return DiffStats(additions: afterLines.count, deletions: 0, isBinary: false)
        case .deleted:
            return DiffStats(additions: 0, deletions: beforeLines.count, isBinary: false)
        case .modified:
            let difference = afterLines.difference(from: beforeLines)
            var additions = 0
            var deletions = 0

            for change in difference {
                switch change {
                case .insert:
                    additions += 1
                case .remove:
                    deletions += 1
                }
            }

            return DiffStats(additions: additions, deletions: deletions, isBinary: false)
        }
    }

    func containsLikelyBinaryData(_ data: Data) -> Bool {
        data.contains(0)
    }

    func lineFragments(from data: Data) -> [String] {
        guard !data.isEmpty else {
            return []
        }

        let text = String(decoding: data, as: UTF8.self)
        guard !text.isEmpty else {
            return []
        }

        let nsText = text as NSString
        var lines: [String] = []
        nsText.enumerateSubstrings(
            in: NSRange(location: 0, length: nsText.length),
            options: [.byLines, .substringNotRequired]
        ) { _, range, _, _ in
            lines.append(nsText.substring(with: range))
        }
        return lines
    }

    static func platformDefaultBaseDirectoryURL() -> URL {
        #if os(iOS)
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .standardizedFileURL
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).standardizedFileURL
        #else
        UserHomeDirectory.current()
        #endif
    }
}
