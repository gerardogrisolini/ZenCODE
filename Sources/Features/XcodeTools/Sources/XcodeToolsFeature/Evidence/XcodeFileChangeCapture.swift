//
//  XcodeFileChangeCapture.swift
//  ZenCODE
//

import FeatureKit
import Foundation
import ToolCore

/// Captures on-disk evidence for Xcode MCP tools that change files.
///
/// Xcode performs the mutation in its own process, so the feature samples the
/// filesystem around the call. Tool paths are project-navigator paths whose
/// mapping to the disk is not guaranteed; every plausible on-disk candidate is
/// therefore sampled before and after the call, and only candidates whose
/// state actually changed are reported. Content is read only from the local
/// filesystem, never through additional Xcode tool calls.
struct XcodeFileChangeCapture: Sendable {
    /// Unique, standardized on-disk candidates for one tool path argument.
    struct PathCandidates: Sendable {
        let urls: [URL]
    }

    enum Snapshot: Equatable, Sendable {
        case absent
        case contents(Data)
        /// Directory, symlink, special, unreadable, or oversized item. Size and
        /// modification date still reveal whether the item changed.
        case opaque(type: String, size: UInt64, modified: Date?)
    }

    static let unavailableExplanation =
        "Diff unavailable: contents are nonregular, binary, unreadable, or exceed the evidence byte limit."
    static let notFoundExplanation =
        "Diff unavailable: Xcode reported success, but no on-disk change was found at a resolvable path."

    /// Raw Xcode tool names whose path arguments identify changed files.
    /// `XcodeMakeDir` is intentionally absent: like `local.mkdir`, creating a
    /// directory produces no file-change evidence.
    static func pathArgumentKeys(forToolName toolName: String) -> [String] {
        switch toolName {
        case "XcodeUpdate", "XcodeWrite":
            return ["filePath"]
        case "XcodeRM":
            return ["path"]
        case "XcodeMV":
            return ["sourcePath", "destinationPath"]
        default:
            return []
        }
    }

    static func tracksChanges(toolName: String) -> Bool {
        !pathArgumentKeys(forToolName: toolName).isEmpty
    }

    let paths: [PathCandidates]
    let before: [[Snapshot]]

    /// Samples every candidate before the tool call. Returns `nil` for tools
    /// that do not change files or when no path argument can be resolved.
    init?(request: ToolRequest, roots: [URL]) {
        let keys = Self.pathArgumentKeys(forToolName: request.name)
        let paths = keys.compactMap { key -> PathCandidates? in
            guard let raw = request.arguments[key]?.stringValue else { return nil }
            let urls = Self.candidates(for: raw, roots: roots)
            return urls.isEmpty ? nil : PathCandidates(urls: urls)
        }
        guard !paths.isEmpty else { return nil }
        self.paths = paths
        self.before = paths.map { $0.urls.map(Self.snapshot) }
    }

    /// Samples every candidate after the tool call and reports changed files.
    /// When Xcode reported success but nothing changed on disk, the most
    /// plausible path is still reported with an explanation so the operation
    /// stays visible; a failed call reports only real on-disk changes.
    func finish(succeeded: Bool) -> [FeatureInvocationFileChange] {
        var changes: [FeatureInvocationFileChange] = []
        var seen = Set<String>()
        func append(_ change: FeatureInvocationFileChange) {
            guard seen.insert(change.path).inserted else { return }
            changes.append(change)
        }

        for (index, path) in paths.enumerated() {
            let after = path.urls.map(Self.snapshot)
            var foundChange = false
            for (candidateIndex, url) in path.urls.enumerated() {
                let old = before[index][candidateIndex]
                let new = after[candidateIndex]
                guard old != new else { continue }
                foundChange = true
                append(Self.change(path: url.path, before: old, after: new))
            }
            if !foundChange, succeeded {
                let existingIndex = path.urls.indices.first {
                    before[index][$0] != .absent || after[$0] != .absent
                }
                let url = path.urls[existingIndex ?? path.urls.startIndex]
                append(FeatureInvocationFileChange(
                    path: url.path,
                    oldText: nil,
                    newText: nil,
                    explanation: Self.notFoundExplanation
                ))
            }
        }
        return changes
    }

    // MARK: - Path resolution

    /// Absolute paths are used as-is. Navigator paths are tried relative to
    /// each root both whole and without their first component, which is the
    /// project/group name Xcode prefixes to project-relative paths.
    static func candidates(for rawPath: String, roots: [URL]) -> [URL] {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return [] }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            path = url.path
        }
        path = NSString(string: path).expandingTildeInPath
        if path.hasPrefix("/") {
            return [URL(fileURLWithPath: path).standardizedFileURL]
        }

        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !components.contains("..") else {
            return []
        }
        var relativePaths = [components.joined(separator: "/")]
        if components.count >= 2 {
            relativePaths.append(components.dropFirst().joined(separator: "/"))
        }

        var seen = Set<String>()
        var urls: [URL] = []
        for root in roots {
            for relativePath in relativePaths {
                let url = root.appendingPathComponent(relativePath).standardizedFileURL
                if seen.insert(url.path).inserted {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    // MARK: - Sampling

    static func snapshot(_ url: URL) -> Snapshot {
        let attributes: [FileAttributeKey: Any]
        do {
            // Does not traverse a final symlink.
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               nsError.code == NSFileReadNoSuchFileError {
                return .absent
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain,
               underlying.code == Int(ENOENT) {
                return .absent
            }
            return .opaque(type: "unreadable", size: 0, modified: nil)
        }

        let type = (attributes[.type] as? FileAttributeType) ?? .typeUnknown
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date
        let opaque = Snapshot.opaque(type: type.rawValue, size: size, modified: modified)
        guard type == .typeRegular,
              size <= UInt64(OperationFileChangeRecorder.maximumSnapshotBytes),
              let data = try? Data(contentsOf: url),
              data.count <= OperationFileChangeRecorder.maximumSnapshotBytes else {
            return opaque
        }
        return .contents(data)
    }

    static func change(
        path: String,
        before: Snapshot,
        after: Snapshot
    ) -> FeatureInvocationFileChange {
        switch (before, after) {
        case let (.absent, .contents(data)):
            if let text = text(data) {
                return FeatureInvocationFileChange(path: path, oldText: nil, newText: text)
            }
        case let (.contents(data), .absent):
            if let text = text(data) {
                return FeatureInvocationFileChange(path: path, oldText: text, newText: nil)
            }
        case let (.contents(oldData), .contents(newData)):
            if let oldText = text(oldData), let newText = text(newData) {
                return FeatureInvocationFileChange(path: path, oldText: oldText, newText: newText)
            }
        default:
            break
        }
        return FeatureInvocationFileChange(
            path: path,
            oldText: nil,
            newText: nil,
            explanation: unavailableExplanation
        )
    }

    private static func text(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8),
              !text.contains("\0") else {
            return nil
        }
        return text
    }
}
