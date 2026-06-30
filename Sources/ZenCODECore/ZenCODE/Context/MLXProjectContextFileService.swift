//
//  MLXProjectContextFileService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public enum MLXProjectContextFileKind: String, CaseIterable, Hashable, Identifiable, Sendable {
    case agents
    case memory

    public static var allCases: [MLXProjectContextFileKind] {
        [.agents, .memory]
    }

    public var id: String {
        rawValue
    }

    public var filename: String {
        switch self {
        case .agents:
            return MLXAgentsContextService.filename
        case .memory:
            return MLXMemoryService.filename
        }
    }
}

public struct MLXProjectContextDocument: Hashable, Sendable {
    public struct Section: Hashable, Sendable {
        public let title: String
        public let content: String
    }

    public let kind: MLXProjectContextFileKind
    public let rootURL: URL
    public let fileURL: URL
    public let content: String
    public let sections: [Section]
    public let digest: String
}

public struct MLXProjectContextFileService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func document(
        kind: MLXProjectContextFileKind,
        at rootURL: URL
    ) -> MLXProjectContextDocument? {
        let standardizedRootURL = rootURL.standardizedFileURL
        let fileURL = standardizedRootURL.appendingPathComponent(kind.filename)
        guard fileManager.fileExists(atPath: fileURL.path),
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }

        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else {
            return nil
        }

        return MLXProjectContextDocument(
            kind: kind,
            rootURL: standardizedRootURL,
            fileURL: fileURL.standardizedFileURL,
            content: normalizedContent,
            sections: Self.sections(from: normalizedContent),
            digest: Self.digest(normalizedContent)
        )
    }

    public func createDefaultDocument(
        kind: MLXProjectContextFileKind,
        at rootURL: URL,
        projectName: String
    ) throws -> MLXProjectContextDocument {
        let standardizedRootURL = rootURL.standardizedFileURL
        if let existingDocument = document(kind: kind, at: standardizedRootURL) {
            return existingDocument
        }

        return try writeDefaultDocument(
            kind: kind,
            at: standardizedRootURL,
            projectName: projectName
        )
    }

    public func regenerateDefaultDocument(
        kind: MLXProjectContextFileKind,
        at rootURL: URL,
        projectName: String
    ) throws -> MLXProjectContextDocument {
        try writeDefaultDocument(
            kind: kind,
            at: rootURL.standardizedFileURL,
            projectName: projectName
        )
    }

    public func materializeDocument(
        kind: MLXProjectContextFileKind,
        content: String,
        at rootURL: URL
    ) throws -> MLXProjectContextDocument {
        let standardizedRootURL = rootURL.standardizedFileURL
        let fileURL = standardizedRootURL.appendingPathComponent(kind.filename)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else {
            throw CocoaError(.fileWriteUnknown)
        }

        try normalizedContent.write(to: fileURL, atomically: true, encoding: .utf8)

        guard let document = document(kind: kind, at: standardizedRootURL) else {
            throw CocoaError(.fileWriteUnknown)
        }

        return document
    }

    public static func sections(from markdown: String) -> [MLXProjectContextDocument.Section] {
        var sections: [MLXProjectContextDocument.Section] = []
        var currentTitle: String?
        var currentLines: [String] = []

        func flush() {
            guard let title = currentTitle else {
                currentLines.removeAll()
                return
            }

            let content = currentLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sections.append(MLXProjectContextDocument.Section(title: title, content: content))
            currentLines.removeAll()
        }

        for line in markdown.components(separatedBy: .newlines) {
            if let heading = headingTitle(from: line) {
                flush()
                currentTitle = heading
            } else {
                currentLines.append(line)
            }
        }

        flush()
        return sections
    }

    public static func defaultContent(
        kind: MLXProjectContextFileKind,
        projectName: String,
        rootPath: String,
        fileManager: FileManager = .default
    ) -> String {
        switch kind {
        case .agents:
            return defaultAgentsContent(
                projectName: projectName,
                rootPath: rootPath,
                fileManager: fileManager
            )
        case .memory:
            return MLXMemoryService.defaultProjectMemoryContent
        }
    }

    private func writeDefaultDocument(
        kind: MLXProjectContextFileKind,
        at rootURL: URL,
        projectName: String
    ) throws -> MLXProjectContextDocument {
        let standardizedRootURL = rootURL.standardizedFileURL
        let fileURL = standardizedRootURL.appendingPathComponent(kind.filename)
        let content = Self.defaultContent(
            kind: kind,
            projectName: projectName,
            rootPath: standardizedRootURL.path,
            fileManager: fileManager
        )
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        guard let document = document(kind: kind, at: standardizedRootURL) else {
            throw CocoaError(.fileWriteUnknown)
        }

        return document
    }

    private static func headingTitle(from line: String) -> String? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLine.hasPrefix("#") else {
            return nil
        }

        let markerCount = trimmedLine.prefix { $0 == "#" }.count
        guard markerCount > 0,
              markerCount <= 3,
              trimmedLine.dropFirst(markerCount).first == " " else {
            return nil
        }

        let title = trimmedLine
            .dropFirst(markerCount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private static func defaultAgentsContent(
        projectName: String,
        rootPath: String,
        fileManager: FileManager
    ) -> String {
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        let normalizedProjectName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = normalizedProjectName.isEmpty
            ? rootURL.lastPathComponent
            : normalizedProjectName
        let inventory = projectInventory(at: rootURL, fileManager: fileManager)
        let verificationGuidance = projectVerificationGuidance(
            projectName: displayName,
            inventory: inventory
        )

        return """
        # AGENTS.md

        ## Project

        - Name: \(displayName)
        - Root: \(rootURL.path)
        \(projectKindLine(from: inventory))

        ## Source Layout

        \(sourceLayoutLines(from: inventory))

        ## Modules

        \(moduleLines(from: inventory))

        ## Project Guidance

        - Keep only durable project-specific facts, conventions, commands, caveats, and constraints here.
        - Record architecture boundaries, important setup details, module ownership, and confirmed build or test workflows.
        - Do not duplicate global operating rules, user preferences, generic coding workflow instructions, or temporary task status.
        \(verificationGuidance)

        ## Context Strategy

        - Use this file to quickly re-enter the project after reopening the folder.
        - Prefer facts confirmed by files, project metadata, Git history, build output, tests, or explicit user instructions.
        - Keep cross-project behavior in the global AGENTS.md file.
        """
    }

    private struct ProjectInventory {
        var topLevelDirectories: [String] = []
        var sourceDirectories: [String] = []
        var testDirectories: [String] = []
        var moduleDirectories: [String] = []
        var packageManifests: [String] = []
        var xcodeProjects: [String] = []
        var xcodeWorkspaces: [String] = []
        var sharedSchemes: [String] = []
    }

    private static func projectInventory(
        at rootURL: URL,
        fileManager: FileManager
    ) -> ProjectInventory {
        var inventory = ProjectInventory()
        let rootEntries = directoryEntries(at: rootURL, fileManager: fileManager)

        inventory.topLevelDirectories = rootEntries
            .filter { isDirectory($0, fileManager: fileManager) }
            .map(\.lastPathComponent)
            .filter { !ignoredDirectoryNames.contains($0) }
            .sorted()

        inventory.xcodeProjects = rootEntries
            .filter { $0.pathExtension == "xcodeproj" }
            .map(\.lastPathComponent)
            .sorted()
        inventory.xcodeWorkspaces = rootEntries
            .filter { $0.pathExtension == "xcworkspace" }
            .map(\.lastPathComponent)
            .sorted()

        if fileManager.fileExists(atPath: rootURL.appendingPathComponent("Package.swift").path) {
            inventory.packageManifests.append("Package.swift")
        }

        let modulesURL = rootURL.appendingPathComponent("modules")
        if isDirectory(modulesURL, fileManager: fileManager) {
            inventory.moduleDirectories = directoryEntries(at: modulesURL, fileManager: fileManager)
                .filter { isDirectory($0, fileManager: fileManager) }
                .map { "modules/\($0.lastPathComponent)" }
                .sorted()
            inventory.packageManifests.append(
                contentsOf: inventory.moduleDirectories.compactMap { modulePath in
                    let packagePath = rootURL
                        .appendingPathComponent(modulePath)
                        .appendingPathComponent("Package.swift")
                        .path
                    return fileManager.fileExists(atPath: packagePath)
                        ? "\(modulePath)/Package.swift"
                        : nil
                }
            )
        }

        inventory.sourceDirectories = sourceDirectoryCandidates(
            rootURL: rootURL,
            topLevelDirectories: inventory.topLevelDirectories,
            moduleDirectories: inventory.moduleDirectories,
            fileManager: fileManager
        )
        inventory.testDirectories = testDirectoryCandidates(
            rootURL: rootURL,
            topLevelDirectories: inventory.topLevelDirectories,
            moduleDirectories: inventory.moduleDirectories,
            fileManager: fileManager
        )
        inventory.sharedSchemes = sharedSchemeNames(
            rootURL: rootURL,
            xcodeProjects: inventory.xcodeProjects,
            xcodeWorkspaces: inventory.xcodeWorkspaces,
            fileManager: fileManager
        )

        return inventory
    }

    private static let ignoredDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        "build",
        "DerivedData",
        "node_modules",
        "Pods"
    ]

    private static func directoryEntries(
        at url: URL,
        fileManager: FileManager
    ) -> [URL] {
        (try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    private static func isDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func sourceDirectoryCandidates(
        rootURL: URL,
        topLevelDirectories: [String],
        moduleDirectories: [String],
        fileManager: FileManager
    ) -> [String] {
        var candidates: [String] = []
        for name in topLevelDirectories {
            let normalized = name.lowercased()
            if normalized == "sources"
                || normalized == "source"
                || normalized == "src"
                || normalized == "app"
                || normalized.hasSuffix("app") {
                candidates.append(name)
            }
        }

        for modulePath in moduleDirectories {
            let sourcesPath = "\(modulePath)/Sources"
            if isDirectory(rootURL.appendingPathComponent(sourcesPath), fileManager: fileManager) {
                candidates.append(sourcesPath)
            }
        }

        return Array(Set(candidates)).sorted()
    }

    private static func testDirectoryCandidates(
        rootURL: URL,
        topLevelDirectories: [String],
        moduleDirectories: [String],
        fileManager: FileManager
    ) -> [String] {
        var candidates = topLevelDirectories.filter { name in
            name.lowercased().contains("test")
        }

        for modulePath in moduleDirectories {
            let testsPath = "\(modulePath)/Tests"
            if isDirectory(rootURL.appendingPathComponent(testsPath), fileManager: fileManager) {
                candidates.append(testsPath)
            }
        }

        return Array(Set(candidates)).sorted()
    }

    private static func sharedSchemeNames(
        rootURL: URL,
        xcodeProjects: [String],
        xcodeWorkspaces: [String],
        fileManager: FileManager
    ) -> [String] {
        let containers = xcodeProjects + xcodeWorkspaces
        let schemes = containers.flatMap { container in
            let schemeURL = rootURL
                .appendingPathComponent(container)
                .appendingPathComponent("xcshareddata/xcschemes")
            return directoryEntries(at: schemeURL, fileManager: fileManager)
                .filter { $0.pathExtension == "xcscheme" }
                .map { $0.deletingPathExtension().lastPathComponent }
        }

        return Array(Set(schemes)).sorted()
    }

    private static func projectKindLine(from inventory: ProjectInventory) -> String {
        var parts: [String] = []
        if !inventory.xcodeProjects.isEmpty || !inventory.xcodeWorkspaces.isEmpty {
            parts.append("Xcode")
        }
        if !inventory.packageManifests.isEmpty {
            parts.append("Swift Package")
        }
        if !inventory.moduleDirectories.isEmpty {
            parts.append("modular")
        }

        return "- Detected: \(parts.isEmpty ? "local source project" : parts.joined(separator: ", "))"
    }

    private static func sourceLayoutLines(from inventory: ProjectInventory) -> String {
        var lines: [String] = []
        lines.append(limitedListLine("Top-level folders", values: inventory.topLevelDirectories))
        lines.append(limitedListLine("Source folders", values: inventory.sourceDirectories))
        lines.append(limitedListLine("Test folders", values: inventory.testDirectories))
        lines.append(limitedListLine("Xcode projects", values: inventory.xcodeProjects))
        lines.append(limitedListLine("Xcode workspaces", values: inventory.xcodeWorkspaces))
        lines.append(limitedListLine("Shared schemes", values: inventory.sharedSchemes))
        if !inventory.packageManifests.isEmpty {
            lines.append("- SwiftPM target roots are under `Sources/<target>` and `Tests/<target>`; build diagnostics and target-relative reasoning may omit those container folders.")
        }
        return lines.joined(separator: "\n")
    }

    private static func moduleLines(from inventory: ProjectInventory) -> String {
        var lines: [String] = []
        lines.append(limitedListLine("Module folders", values: inventory.moduleDirectories))
        lines.append(limitedListLine("Package manifests", values: inventory.packageManifests))
        if !inventory.moduleDirectories.isEmpty {
            lines.append("- Inspect the module-local `Package.swift`, `Sources`, and `Tests` before changing shared contracts.")
        }
        return lines.joined(separator: "\n")
    }

    private static func projectVerificationGuidance(
        projectName: String,
        inventory: ProjectInventory
    ) -> String {
        if !inventory.sharedSchemes.isEmpty {
            return "- Use the shared schemes listed above for \(projectName) build and test verification."
        }
        if !inventory.packageManifests.isEmpty {
            return "- Use the package manifests listed above to choose the right SwiftPM build and test command."
        }
        return "- Add confirmed project-specific build and test commands here when they are discovered."
    }

    private static func limitedListLine(
        _ title: String,
        values: [String],
        emptyValue: String = "none detected",
        limit: Int = 12
    ) -> String {
        guard !values.isEmpty else {
            return "- \(title): \(emptyValue)."
        }

        let visibleValues = values.prefix(limit).joined(separator: ", ")
        let suffix = values.count > limit ? ", +\(values.count - limit) more" : ""
        return "- \(title): \(visibleValues)\(suffix)."
    }

    public static func digest(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }
}
