//
//  MLXAgentsContextServiceTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//

import Foundation
import ZenCODECore
import Testing

@Suite
struct MLXAgentsContextServiceTests {
    @Test
    func globalAgentsTemplateFramesAssistantBehavior() {
        let content = AgentsContextService.defaultGlobalAgentsContent

        #expect(content.contains("do what the user asked"))
        #expect(content.contains("on the user's machine"))
        #expect(!content.contains("on the user's Mac"))
        #expect(content.contains("do not invent extra requirements"))
        #expect(content.contains("Briefly explain the intent behind non-obvious or risky actions"))
        #expect(content.contains("Ask focused questions when they help"))
        #expect(!content.contains("response-language"))
        #expect(!content.contains("operating system language"))
        #expect(!content.contains("user's active language"))
        #expect(!content.contains("prepare a concise implementation plan"))
        #expect(!content.contains("verify the plan point by point"))
        #expect(!content.contains("approves the plan"))
    }

    @Test
    func projectAgentsTemplateDoesNotAssumeSharedXcodeSchemes() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-agents-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try Data().write(to: rootURL.appendingPathComponent("Package.swift"))

        let content = ProjectContextFileService.defaultContent(
            kind: .agents,
            projectName: "PackageOnly",
            rootPath: rootURL.path
        )

        #expect(content.contains("- Type: Swift Package"))
        #expect(content.contains("- Build manifests: `Package.swift`."))
        #expect(content.contains("- Fast SwiftPM compile check: `swift build --target <TargetName>`."))
        #expect(content.contains("- Focused SwiftPM test: `swift test --filter <SuiteOrTestName>`."))
        #expect(!content.contains("Keep only durable project-specific facts"))
        #expect(!content.contains("Context Strategy"))
        #expect(!content.contains("none detected"))
        #expect(!content.contains(rootURL.path))
    }

    @Test
    func projectAgentsTemplateMapsSwiftPackageForFocusedNavigation() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-agents-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        for path in [
            "Sources/App",
            "Sources/Core",
            "Tests/CoreTests",
            "Docs",
            "Scripts",
            "modules/Analytics/Sources/Analytics",
            "modules/Analytics/Tests/AnalyticsTests",
            ".build/Noise"
        ] {
            try FileManager.default.createDirectory(
                at: rootURL.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data().write(to: rootURL.appendingPathComponent("README.md"))
        let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription

        let optionalFeature = Context.environment["DEMO_FEATURE"] == "1"
        let package = Package(
            name: "Demo",
            targets: [
                .target(
                    name: "Core"
                ),
                .executableTarget(
                    name: "demo"
                ),
                .testTarget(
                    name: "CoreTests"
                )
            ]
        )
        """
        try manifest.write(
            to: rootURL.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let moduleManifest = """
        // swift-tools-version: 6.1
        import PackageDescription

        let package = Package(
            name: "Analytics",
            targets: [
                .target(name: "Analytics"),
                .testTarget(name: "AnalyticsTests")
            ]
        )
        """
        try moduleManifest.write(
            to: rootURL.appendingPathComponent("modules/Analytics/Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let content = ProjectContextFileService.defaultContent(
            kind: .agents,
            projectName: "Demo",
            rootPath: rootURL.path
        )

        #expect(content.contains("- Swift tools version: 6.2"))
        #expect(content.contains("- Build manifests: `Package.swift`, `modules/Analytics/Package.swift`."))
        #expect(content.contains("- Source areas: `Sources/App`, `Sources/Core`, `modules/Analytics/Sources/Analytics`."))
        #expect(content.contains("- Test areas: `Tests/CoreTests`, `modules/Analytics/Tests/AnalyticsTests`."))
        #expect(content.contains("- Declared SwiftPM library/support targets: `Analytics`, `Core`."))
        #expect(content.contains("- Declared SwiftPM executable targets: `demo`."))
        #expect(content.contains("- Declared SwiftPM test targets: `AnalyticsTests`, `CoreTests`."))
        #expect(content.contains("- Project documentation: `Docs`, `README.md`."))
        #expect(content.contains("- Automation: `Scripts`."))
        #expect(content.contains("`Package.swift` reads environment variables"))
        #expect(!content.contains(".build"))
    }

    @Test
    func projectAgentsTemplateUsesSharedSchemesWhenDetected() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-agents-tests-\(UUID().uuidString)", isDirectory: true)
        let schemesURL = rootURL
            .appendingPathComponent("App.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: schemesURL,
            withIntermediateDirectories: true
        )
        try Data().write(to: schemesURL.appendingPathComponent("App.xcscheme"))

        let content = ProjectContextFileService.defaultContent(
            kind: .agents,
            projectName: "XcodeApp",
            rootPath: rootURL.path
        )

        #expect(content.contains("- Shared schemes: `App`."))
        #expect(content.contains("Xcode: build and test the narrowest relevant shared scheme"))
    }

    @Test
    func promptSectionFiltersProjectMetaGuidance() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-agents-tests-\(UUID().uuidString)", isDirectory: true)
        let globalURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let projectContent = """
        # AGENTS.md

        ## Project

        - Name: Demo

        ## Project Guidance

        - Keep only durable project-specific facts here.
        - Confirmed command: swift test.

        ## Context Strategy

        - This line is editor guidance and should not enter the runtime prompt.
        """
        try projectContent.write(
            to: workspaceURL.appendingPathComponent(AgentsContextService.filename),
            atomically: true,
            encoding: .utf8
        )

        let prompt = AgentsContextService(globalAgentsDirectoryURL: globalURL)
            .promptSection(workspaceRootURL: workspaceURL)

        #expect(prompt?.contains("Global context:") == true)
        #expect(prompt?.contains("Project context:") == true)
        #expect(prompt?.contains("Confirmed command: swift test.") == true)
        #expect(prompt?.contains("editor guidance") == false)
    }
}
