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
/// state actually changed are reported. When no candidate maps onto the disk,
/// as with local packages nested below the project folder, the project roots
/// are searched for the file. Content is read only from the local filesystem,
/// never through additional Xcode tool calls.
struct XcodeFileChangeCapture: Sendable {
    /// Unique, standardized on-disk candidates for one tool path argument.
    struct PathCandidates: Sendable {
        let urls: [URL]
        /// Base directory of every candidate found by searching the roots,
        /// keyed by candidate path: the navigator path resolved against the
        /// base names the candidate.
        var searchBases: [String: URL] = [:]
    }

    /// A file located by searching the project roots for a navigator path.
    struct SearchMatch: Equatable, Sendable {
        let url: URL
        let base: URL
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

    /// Entries visited at most while searching the project roots.
    static let searchEntryLimit = 20_000
    /// Matches kept at most per navigator path.
    static let searchMatchLimit = 8
    /// Directories never descended while searching, besides hidden ones and
    /// packages such as `.xcodeproj`: build products and dependency caches.
    static let searchSkippedDirectoryNames: Set<String> = ["DerivedData", "node_modules"]

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
    /// `knownBases` are base directories confirmed by earlier searches; they
    /// resolve navigator paths like `roots` do, but are never searched.
    init?(request: ToolRequest, roots: [URL], knownBases: [URL] = []) {
        let keys = Self.pathArgumentKeys(forToolName: request.name)
        let paths = keys.compactMap { key -> PathCandidates? in
            guard let raw = request.arguments[key]?.stringValue else { return nil }
            return Self.resolve(raw, roots: roots, knownBases: knownBases)
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

    /// Base directories of searched candidates that `changes` confirm as
    /// really changed. The executor reuses them as `knownBases`, so later
    /// paths under the same mapping resolve without another search.
    func confirmedSearchBases(in changes: [FeatureInvocationFileChange]) -> [URL] {
        let changedPaths = Set(changes.lazy
            .filter { $0.explanation != Self.notFoundExplanation }
            .map(\.path))
        var seen = Set<String>()
        var bases: [URL] = []
        for path in paths {
            for (candidatePath, base) in path.searchBases.sorted(by: { $0.key < $1.key })
            where changedPaths.contains(candidatePath) && seen.insert(base.path).inserted {
                bases.append(base)
            }
        }
        return bases
    }

    // MARK: - Path resolution

    private enum NormalizedPath {
        case absolute(URL)
        case relative([String])
    }

    private static func normalize(_ rawPath: String) -> NormalizedPath? {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            path = url.path
        }
        path = NSString(string: path).expandingTildeInPath
        if path.hasPrefix("/") {
            return .absolute(URL(fileURLWithPath: path).standardizedFileURL)
        }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !components.contains("..") else {
            return nil
        }
        return .relative(components)
    }

    /// Direct candidates first; the project roots are searched only when no
    /// direct candidate maps onto the disk.
    static func resolve(_ rawPath: String, roots: [URL], knownBases: [URL]) -> PathCandidates? {
        let bases = roots + knownBases
        let urls = candidates(for: rawPath, roots: bases)
        guard !urls.isEmpty else { return nil }
        guard case let .relative(components)? = normalize(rawPath),
              needsSearch(urls, bases: bases) else {
            return PathCandidates(urls: urls)
        }
        var seen = Set(urls.map(\.path))
        var all = urls
        var searchBases: [String: URL] = [:]
        for match in search(components, in: roots) where seen.insert(match.url.path).inserted {
            all.append(match.url)
            searchBases[match.url.path] = match.base
        }
        return PathCandidates(urls: all, searchBases: searchBases)
    }

    /// A search is needed only when no candidate exists and no candidate's
    /// directory exists below a base: an existing directory already locates
    /// the file a call creates.
    static func needsSearch(_ urls: [URL], bases: [URL]) -> Bool {
        let fileManager = FileManager.default
        let basePaths = Set(bases.map(\.standardizedFileURL.path))
        for url in urls {
            // Does not traverse a final symlink, so a dangling link exists.
            if (try? fileManager.attributesOfItem(atPath: url.path)) != nil {
                return false
            }
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            var isDirectory: ObjCBool = false
            if !basePaths.contains(parent),
               fileManager.fileExists(atPath: parent, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return false
            }
        }
        return true
    }

    /// Absolute paths are used as-is. Navigator paths are tried relative to
    /// each root both whole and without their first component, which is the
    /// project/group name Xcode prefixes to project-relative paths.
    static func candidates(for rawPath: String, roots: [URL]) -> [URL] {
        guard let normalized = normalize(rawPath) else { return [] }
        let components: [String]
        switch normalized {
        case let .absolute(url):
            return [url]
        case let .relative(relative):
            components = relative
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

    // MARK: - Search

    /// Searches `roots` for the file a navigator path names when it does not
    /// map directly onto the disk. A file matches when its path below a root
    /// ends with the navigator components, whole or else without the
    /// project/group prefix; when no file matches, the parent directory is
    /// matched the same way so a file the call creates is located too. The
    /// matched suffix always spans at least two components, the walk is
    /// bounded, and hidden directories, packages, and build caches are skipped.
    static func search(
        _ components: [String],
        in roots: [URL],
        entryLimit: Int = searchEntryLimit,
        matchLimit: Int = searchMatchLimit
    ) -> [SearchMatch] {
        guard components.count >= 2, let fileName = components.last else { return [] }
        let parent = Array(components.dropLast())
        // Suffixes in preference order: whole path, then without the prefix.
        let fileSuffixes = [components, Array(components.dropFirst())].filter { $0.count >= 2 }
        let directorySuffixes = [parent, Array(parent.dropFirst())].filter { !$0.isEmpty }
        var fileMatches = Array(repeating: [SearchMatch](), count: fileSuffixes.count)
        var directoryMatches = Array(repeating: [SearchMatch](), count: directorySuffixes.count)

        func record(
            relative: [String],
            suffixes: [[String]],
            root: URL,
            appending trailing: String?,
            into matches: inout [[SearchMatch]]
        ) {
            guard let index = suffixes.firstIndex(where: { suffix in
                relative.count >= suffix.count && relative.suffix(suffix.count).elementsEqual(suffix)
            }), matches[index].count < matchLimit else { return }
            // Rebuilt from the root as given, so paths keep the roots' form
            // even when the enumerator reports resolved ones.
            var url = root.appendingPathComponent(relative.joined(separator: "/"))
            if let trailing {
                url.appendPathComponent(trailing)
            }
            let baseComponents = relative.dropLast(suffixes[index].count)
            let base = baseComponents.isEmpty
                ? root
                : root.appendingPathComponent(baseComponents.joined(separator: "/"))
            matches[index].append(SearchMatch(
                url: url.standardizedFileURL,
                base: base.standardizedFileURL
            ))
        }

        var remaining = entryLimit
        for root in outermost(roots) where remaining > 0 {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while remaining > 0, let url = enumerator.nextObject() as? URL {
                remaining -= 1
                let name = url.lastPathComponent
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory == true
                if isDirectory, searchSkippedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                    continue
                }
                guard name == (isDirectory ? parent.last : fileName) else { continue }
                // The level is the depth below the root, so the components
                // relative to the root are the URL's trailing components.
                let relative = Array(url.pathComponents.suffix(enumerator.level))
                if isDirectory {
                    record(
                        relative: relative, suffixes: directorySuffixes, root: root,
                        appending: fileName, into: &directoryMatches
                    )
                } else {
                    record(
                        relative: relative, suffixes: fileSuffixes, root: root,
                        appending: nil, into: &fileMatches
                    )
                }
            }
        }
        return (fileMatches + directoryMatches).first { !$0.isEmpty } ?? []
    }

    /// Whether `url` is `root` or lies below it.
    static func isWithin(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// Unique roots, without those nested in another root.
    private static func outermost(_ roots: [URL]) -> [URL] {
        var seen = Set<String>()
        let unique = roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return unique.filter { root in
            !unique.contains { other in
                other.standardizedFileURL.path != root.standardizedFileURL.path
                    && isWithin(root, root: other)
            }
        }
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

        var type = (attributes[.type] as? FileAttributeType) ?? .typeUnknown
        var size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        var modified = attributes[.modificationDate] as? Date
        if type == .typeSymbolicLink {
            // Xcode edits the file the link points to, so sample the target;
            // a dangling link stays opaque and its own metadata is kept.
            let target = url.resolvingSymlinksInPath()
            if target.path != url.path,
               let targetAttributes = try? FileManager.default.attributesOfItem(atPath: target.path) {
                type = (targetAttributes[.type] as? FileAttributeType) ?? .typeUnknown
                size = (targetAttributes[.size] as? NSNumber)?.uint64Value ?? 0
                modified = targetAttributes[.modificationDate] as? Date
            }
        }
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
