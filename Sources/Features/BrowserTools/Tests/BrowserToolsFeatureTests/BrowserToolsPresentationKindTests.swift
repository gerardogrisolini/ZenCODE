import FeatureKit
import Testing
import ToolCore
@testable import BrowserToolsFeature

/// ACP clients (Xcode) render `execute` as "Terminal Command". Only the core
/// `local.exec` tool may use that kind; every Browser tool must present as
/// something else while keeping its action and the rest of its presentation.
@Suite("BrowserTools presentation kinds")
struct BrowserToolsPresentationKindTests {
    private static var descriptorsByName: [String: FeatureToolDescriptor] {
        Dictionary(
            BrowserToolsFeatureRunner.tools().map { ($0.descriptor.name, $0.descriptor) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @Test func noBrowserToolPresentsAsExecute() {
        let tools = BrowserToolsFeatureRunner.tools()
        #expect(!tools.isEmpty)

        for tool in tools {
            let descriptor = tool.descriptor
            #expect(descriptor.presentation != nil, "\(descriptor.name) must declare a presentation")
            #expect(
                descriptor.presentation?.kind != .execute,
                "\(descriptor.name) must not use the execute presentation kind"
            )
        }
    }

    @Test func navigateOpenLoginAndPerformPresentAsOtherWithUnchangedActions() {
        let expectations: [(name: String, action: String)] = [
            ("browser.goto", "Navigate"),
            ("browser.login", "Open"),
            ("browser.act", "Perform")
        ]
        let descriptors = Self.descriptorsByName

        for expectation in expectations {
            let presentation = descriptors[expectation.name]?.presentation

            #expect(presentation != nil, "\(expectation.name) must be exposed by the feature")
            #expect(presentation?.kind == .other, "\(expectation.name) kind")
            #expect(presentation?.action == expectation.action, "\(expectation.name) action")
        }
    }

    @Test func modifiedToolsKeepTheirTitlesAndTargets() {
        let goto = BrowserGotoTool.presentation
        #expect(goto.title == "Browser page")
        #expect(goto.target == .argument(["url", "pageId", "page_id"], format: .url))

        let login = BrowserLoginTool.presentation
        #expect(login.title == "Browser login")
        #expect(login.target == .argument(["url"], format: .url))

        let act = BrowserActTool.presentation
        #expect(act.title == "Browser action")
        #expect(act.target == .argument(["action", "ref", "pageId", "page_id"], format: .automatic))
    }

    @Test func browserOpenKeepsItsCreateKind() {
        let presentation = BrowserOpenTool.presentation

        #expect(presentation.kind == .create)
        #expect(presentation.action == "Open")
    }
}
