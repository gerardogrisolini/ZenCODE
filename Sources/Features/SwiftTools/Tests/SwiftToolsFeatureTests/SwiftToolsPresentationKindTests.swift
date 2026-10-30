import FeatureKit
import Testing
import ToolCore
@testable import swift_tools_feature

/// ACP clients (Xcode) render `execute` as "Terminal Command". Only the core
/// `local.exec` tool may use that kind; every Swift tool must present as
/// something else while keeping its action and the rest of its presentation.
@Suite("SwiftTools presentation kinds")
struct SwiftToolsPresentationKindTests {
    private struct Expectation {
        let name: String
        let tool: AnyFeatureTool
        let kind: ToolPresentationKind
        let action: String
    }

    private static let expectations: [Expectation] = [
        Expectation(name: "swift.build", tool: AnyFeatureTool(SwiftBuildTool()), kind: .other, action: "Build"),
        Expectation(name: "swift.test", tool: AnyFeatureTool(SwiftTestTool()), kind: .other, action: "Test"),
        Expectation(name: "swift.run", tool: AnyFeatureTool(SwiftRunTool()), kind: .other, action: "Run"),
        Expectation(name: "swift.package", tool: AnyFeatureTool(SwiftPackageTool()), kind: .manage, action: "Manage"),
        Expectation(name: "swift.outline", tool: AnyFeatureTool(SwiftOutlineTool()), kind: .inspect, action: "Inspect")
    ]

    @Test func noSwiftToolPresentsAsExecute() {
        for expectation in Self.expectations {
            #expect(
                expectation.tool.descriptor.presentation?.kind != .execute,
                "\(expectation.name) must not use the execute presentation kind"
            )
        }
    }

    @Test func toolKindsAndActionsMatchTheExpectedPresentation() {
        for expectation in Self.expectations {
            let descriptor = expectation.tool.descriptor
            let presentation = descriptor.presentation

            #expect(descriptor.name == expectation.name)
            #expect(presentation?.kind == expectation.kind, "\(expectation.name) kind")
            #expect(presentation?.action == expectation.action, "\(expectation.name) action")
        }
    }

    @Test func buildTestAndRunKeepTheirTitlesAndTargetsWhenPresentedAsOther() {
        let build = SwiftBuildTool.presentation
        #expect(build.title == "Swift package")
        #expect(build.target == .argument(["target", "product", "path", "workingDirectory"], format: .automatic))

        let test = SwiftTestTool.presentation
        #expect(test.title == "Swift tests")
        #expect(test.target == .argument(["filter", "target", "path", "workingDirectory"], format: .automatic))

        let run = SwiftRunTool.presentation
        #expect(run.title == "Swift executable")
        #expect(run.target == .argument(["executable", "product", "path", "workingDirectory"], format: .automatic))
    }
}
