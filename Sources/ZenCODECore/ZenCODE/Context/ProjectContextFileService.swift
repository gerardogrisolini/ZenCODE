//
//  ProjectContextFileService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum ProjectContextFileKind: String, CaseIterable, Hashable, Identifiable, Sendable {
    case agents
    case memory

    public static var allCases: [ProjectContextFileKind] {
        [.agents, .memory]
    }

    public var id: String {
        rawValue
    }

    public var filename: String {
        switch self {
        case .agents:
            return AgentsContextService.filename
        case .memory:
            return MemoryService.filename
        }
    }
}

public struct ProjectContextDocument: Hashable, Sendable {
    public struct Section: Hashable, Sendable {
        public let title: String
        public let content: String
    }

    public let kind: ProjectContextFileKind
    public let rootURL: URL
    public let fileURL: URL
    public let content: String
    public let sections: [Section]
    public let digest: String
}

public struct ProjectContextFileService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func document(
        kind: ProjectContextFileKind,
        at rootURL: URL
    ) -> ProjectContextDocument? {
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

        return ProjectContextDocument(
            kind: kind,
            rootURL: standardizedRootURL,
            fileURL: fileURL.standardizedFileURL,
            content: normalizedContent,
            sections: Self.sections(from: normalizedContent),
            digest: Self.digest(normalizedContent)
        )
    }

    public func createDefaultDocument(
        kind: ProjectContextFileKind,
        at rootURL: URL,
        projectName: String
    ) throws -> ProjectContextDocument {
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
        kind: ProjectContextFileKind,
        at rootURL: URL,
        projectName: String
    ) throws -> ProjectContextDocument {
        try writeDefaultDocument(
            kind: kind,
            at: rootURL.standardizedFileURL,
            projectName: projectName
        )
    }

    public func materializeDocument(
        kind: ProjectContextFileKind,
        content: String,
        at rootURL: URL
    ) throws -> ProjectContextDocument {
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

    public static func sections(from markdown: String) -> [ProjectContextDocument.Section] {
        var sections: [ProjectContextDocument.Section] = []
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
            sections.append(ProjectContextDocument.Section(title: title, content: content))
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
        kind: ProjectContextFileKind,
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
            return MemoryService.defaultProjectMemoryContent
        }
    }

    private func writeDefaultDocument(
        kind: ProjectContextFileKind,
        at rootURL: URL,
        projectName: String
    ) throws -> ProjectContextDocument {
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

        return """
        # AGENTS.md

        ## Project

        - Name: \(displayName)
        \(projectSummaryLines(from: inventory))

        ## Repository Map

        \(repositoryMapLines(from: inventory))

        ## Navigation

        \(navigationGuidance(from: inventory))

        ## Build and Test

        \(projectVerificationGuidance(inventory: inventory))
        """
    }

    private struct SwiftPackageTarget: Hashable {
        enum Kind: String, Hashable {
            case regular = "target"
            case executable = "executableTarget"
            case test = "testTarget"
        }

        let name: String
        let kind: Kind
    }

    private struct ProjectInventory {
        var topLevelDirectories: [String] = []
        var sourceDirectories: [String] = []
        var sourceAreaDirectories: [String] = []
        var testDirectories: [String] = []
        var testAreaDirectories: [String] = []
        var moduleDirectories: [String] = []
        var packageManifests: [String] = []
        var swiftToolsVersion: String?
        var swiftPackageTargets: [SwiftPackageTarget] = []
        var swiftManifestUsesEnvironment = false
        var xcodeProjects: [String] = []
        var xcodeWorkspaces: [String] = []
        var sharedSchemes: [String] = []
        var documentationPaths: [String] = []
        var automationDirectories: [String] = []
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
            .filter { !ignoredDirectoryNames.contains($0.lowercased()) }
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

        let packageManifestURLs = inventory.packageManifests.map {
            rootURL.appendingPathComponent($0)
        }
        let preferredManifestURL = packageManifestURLs.first {
            $0.lastPathComponent == "Package.swift"
                && $0.deletingLastPathComponent().standardizedFileURL == rootURL
        } ?? packageManifestURLs.first
        inventory.swiftToolsVersion = preferredManifestURL.flatMap(swiftToolsVersion)
        inventory.swiftPackageTargets = Array(
            Set(packageManifestURLs.flatMap(swiftPackageTargets))
        ).sorted(by: swiftPackageTargetSort)
        inventory.swiftManifestUsesEnvironment = packageManifestURLs.contains(
            where: swiftManifestUsesEnvironment
        )

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
        inventory.sourceAreaDirectories = childDirectoryPaths(
            under: inventory.sourceDirectories,
            rootURL: rootURL,
            fileManager: fileManager
        )
        inventory.testAreaDirectories = childDirectoryPaths(
            under: inventory.testDirectories,
            rootURL: rootURL,
            fileManager: fileManager
        )
        inventory.sharedSchemes = sharedSchemeNames(
            rootURL: rootURL,
            xcodeProjects: inventory.xcodeProjects,
            xcodeWorkspaces: inventory.xcodeWorkspaces,
            fileManager: fileManager
        )
        inventory.documentationPaths = documentationPaths(
            rootEntries: rootEntries,
            fileManager: fileManager
        )
        inventory.automationDirectories = inventory.topLevelDirectories
            .filter { automationDirectoryNames.contains($0.lowercased()) }
            .sorted()

        return inventory
    }

    private static let ignoredDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        "build",
        "deriveddata",
        "node_modules",
        "pods"
    ]

    private static let automationDirectoryNames: Set<String> = [
        "automation",
        "script",
        "scripts"
    ]

    private static let documentationDirectoryNames: Set<String> = [
        "doc",
        "docs",
        "documentation"
    ]

    private static let documentationFileNames: Set<String> = [
        "architecture.md",
        "contributing.md",
        "readme.md"
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

    private static func swiftToolsVersion(at manifestURL: URL) -> String? {
        guard let content = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            return nil
        }
        return firstRegularExpressionCapture(
            pattern: "swift-tools-version\\s*:\\s*([0-9]+(?:\\.[0-9]+)*)",
            in: content,
            captureGroup: 1
        )
    }

    private static func swiftManifestUsesEnvironment(at manifestURL: URL) -> Bool {
        guard let content = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            return false
        }
        return content.contains("Context.environment")
    }

    private static func swiftPackageTargets(at manifestURL: URL) -> [SwiftPackageTarget] {
        guard let content = try? String(contentsOf: manifestURL, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: "\\.(target|executableTarget|testTarget)\\s*\\(\\s*name\\s*:\\s*\"([^\"]+)\""
              ) else {
            return []
        }

        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        let targets = expression.matches(in: content, range: range).compactMap { match -> SwiftPackageTarget? in
            guard let kindRange = Range(match.range(at: 1), in: content),
                  let nameRange = Range(match.range(at: 2), in: content),
                  let kind = SwiftPackageTarget.Kind(rawValue: String(content[kindRange])) else {
                return nil
            }
            return SwiftPackageTarget(name: String(content[nameRange]), kind: kind)
        }

        return Array(Set(targets)).sorted(by: swiftPackageTargetSort)
    }

    private static func swiftPackageTargetSort(
        _ lhs: SwiftPackageTarget,
        _ rhs: SwiftPackageTarget
    ) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue {
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private static func firstRegularExpressionCapture(
        pattern: String,
        in content: String,
        captureGroup: Int
    ) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = expression.firstMatch(in: content, range: range),
              let captureRange = Range(match.range(at: captureGroup), in: content) else {
            return nil
        }
        return String(content[captureRange])
    }

    private static func childDirectoryPaths(
        under parentPaths: [String],
        rootURL: URL,
        fileManager: FileManager
    ) -> [String] {
        let paths = parentPaths.flatMap { parentPath in
            directoryEntries(
                at: rootURL.appendingPathComponent(parentPath),
                fileManager: fileManager
            )
            .filter { isDirectory($0, fileManager: fileManager) }
            .filter { !ignoredDirectoryNames.contains($0.lastPathComponent.lowercased()) }
            .map { "\(parentPath)/\($0.lastPathComponent)" }
        }
        return Array(Set(paths)).sorted()
    }

    private static func documentationPaths(
        rootEntries: [URL],
        fileManager: FileManager
    ) -> [String] {
        rootEntries.compactMap { entry in
            let name = entry.lastPathComponent
            let normalizedName = name.lowercased()
            if isDirectory(entry, fileManager: fileManager) {
                return documentationDirectoryNames.contains(normalizedName) ? name : nil
            }
            return documentationFileNames.contains(normalizedName) ? name : nil
        }
        .sorted()
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

    private static func projectSummaryLines(from inventory: ProjectInventory) -> String {
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

        var lines = ["- Type: \(parts.isEmpty ? "local source project" : parts.joined(separator: ", "))"]
        if let swiftToolsVersion = inventory.swiftToolsVersion {
            lines.append("- Swift tools version: \(swiftToolsVersion)")
        }
        return lines.joined(separator: "\n")
    }

    private static func repositoryMapLines(from inventory: ProjectInventory) -> String {
        var lines: [String] = []
        appendLimitedListLine("Build manifests", values: inventory.packageManifests, to: &lines)
        appendLimitedListLine("Source roots", values: inventory.sourceDirectories, to: &lines)
        appendLimitedListLine("Source areas", values: inventory.sourceAreaDirectories, limit: 20, to: &lines)
        appendLimitedListLine("Test roots", values: inventory.testDirectories, to: &lines)
        appendLimitedListLine("Test areas", values: inventory.testAreaDirectories, limit: 20, to: &lines)

        let regularTargets = inventory.swiftPackageTargets
            .filter { $0.kind == .regular }
            .map(\.name)
        let executableTargets = inventory.swiftPackageTargets
            .filter { $0.kind == .executable }
            .map(\.name)
        let testTargets = inventory.swiftPackageTargets
            .filter { $0.kind == .test }
            .map(\.name)
        appendLimitedListLine("Declared SwiftPM library/support targets", values: regularTargets, limit: 20, to: &lines)
        appendLimitedListLine("Declared SwiftPM executable targets", values: executableTargets, limit: 20, to: &lines)
        appendLimitedListLine("Declared SwiftPM test targets", values: testTargets, limit: 20, to: &lines)

        appendLimitedListLine("Xcode projects", values: inventory.xcodeProjects, to: &lines)
        appendLimitedListLine("Xcode workspaces", values: inventory.xcodeWorkspaces, to: &lines)
        appendLimitedListLine("Shared schemes", values: inventory.sharedSchemes, to: &lines)
        appendLimitedListLine("Project documentation", values: inventory.documentationPaths, to: &lines)
        appendLimitedListLine("Automation", values: inventory.automationDirectories, to: &lines)

        if lines.isEmpty {
            lines.append("- No conventional source, test, manifest, documentation, or automation paths were detected.")
        }
        return lines.joined(separator: "\n")
    }

    private static func navigationGuidance(from inventory: ProjectInventory) -> String {
        var lines: [String] = []
        if !inventory.packageManifests.isEmpty {
            lines.append("- Open `Package.swift` first for target dependencies, platform requirements, conditional compilation, and custom target paths.")
        }
        if !inventory.swiftPackageTargets.isEmpty {
            lines.append("- Use the declared target names above for focused builds; conditional declarations may not be active in every manifest configuration.")
        }
        if inventory.swiftManifestUsesEnvironment {
            lines.append("- `Package.swift` reads environment variables; keep the same environment for build and test, and inspect its flags before changing the package graph.")
        }
        if !inventory.sourceAreaDirectories.isEmpty && !inventory.testAreaDirectories.isEmpty {
            lines.append("- Start in the narrowest matching source area and its corresponding test area instead of scanning all of `Sources` or `Tests`.")
        }
        if !inventory.moduleDirectories.isEmpty {
            lines.append("- Inspect the module-local `Package.swift`, `Sources`, and `Tests` before changing shared contracts.")
        }
        if !inventory.documentationPaths.isEmpty {
            lines.append("- Use the project documentation paths above for architecture and setup questions; read only the document relevant to the task.")
        }
        if !inventory.automationDirectories.isEmpty {
            lines.append("- Inspect automation scripts before running them; install/deploy scripts are not routine validation commands.")
        }
        if !inventory.xcodeWorkspaces.isEmpty {
            lines.append("- Prefer the detected workspace over opening a project directly when resolving Xcode files and schemes.")
        }
        if lines.isEmpty {
            lines.append("- Inspect the nearest manifest and sibling tests before editing; avoid broad repository reads.")
        }
        return lines.joined(separator: "\n")
    }

    private static func projectVerificationGuidance(
        inventory: ProjectInventory
    ) -> String {
        var lines: [String] = []
        if !inventory.sharedSchemes.isEmpty {
            lines.append("- Xcode: build and test the narrowest relevant shared scheme listed above with the available Xcode tooling.")
        }
        if !inventory.packageManifests.isEmpty {
            lines.append("- Fast SwiftPM compile check: `swift build --target <TargetName>`.")
            lines.append("- Focused SwiftPM test: `swift test --filter <SuiteOrTestName>`.")
            lines.append("- Full SwiftPM verification when justified: `swift build` followed by `swift test`.")
        }
        if lines.isEmpty {
            lines.append("- No build command was inferred; derive validation from the detected manifest or shared scheme before editing.")
        }
        return lines.joined(separator: "\n")
    }

    private static func appendLimitedListLine(
        _ title: String,
        values: [String],
        limit: Int = 12,
        to lines: inout [String]
    ) {
        guard !values.isEmpty else {
            return
        }

        let visibleValues = values
            .prefix(limit)
            .map { "`\($0)`" }
            .joined(separator: ", ")
        let suffix = values.count > limit ? ", +\(values.count - limit) more" : ""
        lines.append("- \(title): \(visibleValues)\(suffix).")
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
