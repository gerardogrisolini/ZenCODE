import Foundation
@testable import BrowserToolsFeature
import FeatureKit
import Testing

extension BrowserToolsFeatureTests {
    @Test
    func accessibilitySnapshotUsesSemanticRolesAndBoundsInteractiveResults() throws {
        let response: [String: Any] = [
            "result": [
                "nodes": [
                    [
                        "nodeId": "1",
                        "ignored": false,
                        "role": ["value": "RootWebArea"],
                        "name": ["value": "Example"],
                    ],
                    [
                        "nodeId": "2",
                        "backendDOMNodeId": 42,
                        "ignored": false,
                        "role": ["value": "button"],
                        "name": ["value": "Save"],
                        "properties": [
                            ["name": "focusable", "value": ["value": true]],
                            ["name": "disabled", "value": ["value": true]],
                        ],
                    ],
                    [
                        "nodeId": "3",
                        "ignored": true,
                        "role": ["value": "link"],
                    ],
                ],
            ],
        ]

        let allNodes = try BrowserAccessibilitySnapshot.parse(response, interactiveOnly: false)
        #expect(allNodes.totalNodeCount == 2)
        #expect(allNodes.nodes.map(\.ref) == ["ax-1", "ax-2"])

        let interactiveNodes = try BrowserAccessibilitySnapshot.parse(response, interactiveOnly: true)
        let button = try #require(interactiveNodes.nodes.first)
        #expect(interactiveNodes.totalNodeCount == 1)
        #expect(button.role == "button")
        #expect(button.name == "Save")
        #expect(button.interactive)
        #expect(button.states == ["disabled"])
        #expect(interactiveNodes.targets["ax-2"]?.backendDOMNodeID == 42)
    }

    @Test
    func controlledInteractionGuardsSensitiveInputsAndKeys() throws {
        let password = BrowserDOMElementInfo(tagName: "input", attributes: ["type": "password"])
        let upload = BrowserDOMElementInfo(tagName: "input", attributes: ["type": "file"])
        let textArea = BrowserDOMElementInfo(tagName: "textarea", attributes: [:])
        let contentEditable = BrowserDOMElementInfo(tagName: "div", attributes: ["contenteditable": ""])

        #expect(password.isPasswordLike)
        #expect(!password.isFileInput)
        #expect(upload.isFileInput)
        #expect(upload.isSupportedFillTarget)
        #expect(textArea.isSupportedFillTarget)
        #expect(contentEditable.isSupportedFillTarget)
        #expect(try BrowserActionKind.resolve("CLICK") == .click)
        #expect(try BrowserDialogAction.resolve("dismiss") == .dismiss)
        #expect(try BrowserKeyStroke.resolve("Arrow_Down").key == "ArrowDown")
        #expect(throws: BrowserInteractionError.unsupportedKey("a")) {
            try BrowserKeyStroke.resolve("a")
        }
    }

    @Test
    func browserInspectProjectionRedactsSensitiveDOMAndAllowsOnlyFixedCSS() throws {
        #expect(try BrowserDOMInspection.parseFrontendNodeID([
            "result": ["nodeIds": [77]],
        ]) == 77)
        #expect(throws: CDPError.self) {
            try BrowserDOMInspection.parseFrontendNodeID([
                "result": ["nodeIds": [0]],
            ])
        }

        let node = try BrowserDOMInspection.parseDOMNode([
            "result": [
                "node": [
                    "nodeId": 77,
                    "localName": "INPUT",
                    "attributes": [
                        "type", "password",
                        "value", "do-not-expose-this",
                        "class", "credential-field",
                        "href", "https://user:password@example.com/path?token=secret&mode=debug#fragment",
                        "src", "javascript:alert('secret')",
                        "data-token", "must-not-appear",
                        "style", "background-image:url(https://example.com/secret.png)",
                    ],
                ],
            ],
        ])

        #expect(node.frontendNodeID == 77)
        #expect(node.element.tagName == "input")
        #expect(node.element.attributes["class"] == "credential-field")
        #expect(node.element.attributes["value"] == nil)
        #expect(node.element.attributes["data-token"] == nil)
        #expect(node.element.attributes["style"] == nil)
        let href = try #require(node.element.attributes["href"])
        #expect(!href.contains("user:password"))
        #expect(!href.contains("secret"))
        #expect(!href.contains("#fragment"))
        #expect(node.element.attributes["src"] == "[redacted]")

        let style = try BrowserDOMInspection.parseComputedStyle([
            "result": [
                "computedStyle": [
                    ["name": "display", "value": "flex"],
                    ["name": "COLOR", "value": "rgb(1, 2, 3)"],
                    ["name": "background-image", "value": "url(https://example.com/private.png)"],
                    ["name": "content", "value": "secret generated text"],
                    ["name": "--page-controlled", "value": "secret custom property"],
                ],
            ],
        ])
        #expect(style.values == ["color": "rgb(1, 2, 3)", "display": "flex"])

        let box = BrowserDOMInspection.parseBoxModel([
            "result": [
                "model": [
                    "content": [0, 0, 10, 0, 10, 20, 0, 20],
                    "padding": [0, 0, 12, 0, 12, 22, 0, 22],
                    "border": [0, 0, 14, 0, 14, 24, 0, 24],
                    "margin": [0, 0, 16, 0, 16, 26, 0, 26],
                    "width": 10,
                    "height": 20,
                ],
            ],
        ])
        #expect(box?.content == [0, 0, 10, 0, 10, 20, 0, 20])
        #expect(box?.width == 10)
        #expect(box?.height == 20)
    }

    @Test
    func browserInspectOutputIsStrictlyBoundedAndReportsTruncation() throws {
        let styleValues = Dictionary(uniqueKeysWithValues: BrowserDOMInspection
            .allowedComputedStyleProperties
            .map { ($0, String(repeating: "x", count: 512)) })
        let selection = BrowserDOMInspection.Selection(
            element: BrowserInspectableElement(
                tagName: "div",
                attributes: [
                    "class": String(repeating: "a", count: 512),
                    "title": String(repeating: "b", count: 512),
                ]
            ),
            boxModel: BrowserInspectionBoxModel(
                content: [0, 0, 10, 0, 10, 10, 0, 10],
                padding: [0, 0, 10, 0, 10, 10, 0, 10],
                border: [0, 0, 10, 0, 10, 10, 0, 10],
                margin: [0, 0, 10, 0, 10, 10, 0, 10],
                width: 10,
                height: 10
            ),
            computedStyle: styleValues,
            truncated: false
        )
        let output = BrowserInspectOutput(
            page: BrowserPage(
                pageID: "page-1",
                title: String(repeating: "t", count: 8_000),
                url: "https://example.com/?token=secret"
            ),
            snapshotID: "snapshot-1",
            ref: "ax-1",
            inspection: selection
        )

        #expect(output.truncated)
        #expect(!output.page.url.contains("secret"))
        let encodedOutput = try JSONEncoder().encode(output)
        #expect(encodedOutput.count <= BrowserDOMInspection.maximumOutputBytes)
    }

    @Test
    func browserInspectAndExtendedActionContractsUseClosedEnums() throws {
        #expect(try BrowserActionKind.resolve("hover") == .hover)
        #expect(try BrowserActionKind.resolve("DOUBLE_CLICK") == .doubleClick)
        #expect(try BrowserActionKind.resolve("scroll_into_view") == .scrollIntoView)
        #expect(try BrowserActionKind.resolve("select_option") == .selectOption)
        #expect(try BrowserActionKind.resolve("check") == .check)
        #expect(try BrowserActionKind.resolve("uncheck") == .uncheck)
        #expect(throws: BrowserToolsFeatureError.self) {
            try BrowserActionKind.resolve("evaluate")
        }

        let actionSchema = try schemaObject(BrowserActTool.inputSchema)
        let actionProperties = try #require(actionSchema["properties"] as? [String: Any])
        let action = try #require(actionProperties["action"] as? [String: Any])
        let actionValues = try #require(action["enum"] as? [String])
        let expectedActionValues: Set<String> = [
            "click", "fill", "press", "hover", "double_click", "scroll_into_view", "select_option", "check", "uncheck",
        ]
        #expect(Set(actionValues) == expectedActionValues)

        let inspectSchema = try schemaObject(BrowserInspectTool.inputSchema)
        let required = try #require(inspectSchema["required"] as? [String])
        let expectedRequired: Set<String> = ["pageId", "snapshotId", "ref"]
        #expect(Set(required) == expectedRequired)
        let inspectProperties = try #require(inspectSchema["properties"] as? [String: Any])
        #expect(inspectProperties["selector"] == nil)
        #expect(inspectProperties["javascript"] == nil)
        #expect(inspectProperties["cdp"] == nil)
    }

    @Test
    func browserInspectRejectsMissingSnapshotBoundArgumentsBeforeOpeningChrome() async {
        let tool = AnyFeatureTool(BrowserInspectTool())
        let context = FeatureContext(environment: [:])

        await #expect(throws: BrowserToolsFeatureError.self) {
            try await tool.invoke(inputData: Data("{}".utf8), context: context)
        }
        await #expect(throws: BrowserToolsFeatureError.self) {
            try await tool.invoke(
                inputData: Data(#"{"pageId":"page-1"}"#.utf8),
                context: context
            )
        }
        await #expect(throws: BrowserToolsFeatureError.self) {
            try await tool.invoke(
                inputData: Data(#"{"pageId":"page-1","snapshotId":"snapshot-1"}"#.utf8),
                context: context
            )
        }
    }

    @Test
    func browserConditionsAreBoundedAndComparedHostSide() throws {
        let probe = BrowserPageConditionProbe(
            readyState: "complete",
            title: "Welcome to ZenCODE",
            url: "http://localhost:3000/dashboard",
            bodyText: "Saved successfully"
        )
        let title = try #require(
            try BrowserConditionLiteral.resolve("ZenCODE", for: .titleContains)
        )
        let text = try #require(
            try BrowserConditionLiteral.resolve("success", for: .textContains)
        )

        #expect(BrowserPageCondition.ready.evaluate(probe: probe, literal: nil).satisfied)
        #expect(BrowserPageCondition.titleContains.evaluate(probe: probe, literal: title).satisfied)
        #expect(BrowserPageCondition.textContains.evaluate(probe: probe, literal: text).satisfied)
        #expect(!BrowserPageCondition.urlContains.evaluate(probe: probe, literal: title).satisfied)
        #expect(try BrowserConditionLimits.resolveTimeout(nil) == 10)
        #expect(try BrowserConditionLimits.resolveTimeout(30) == 30)
        #expect(throws: BrowserToolsFeatureError.self) {
            try BrowserConditionLimits.resolveTimeout(31)
        }
        #expect(throws: BrowserToolsFeatureError.self) {
            try BrowserConditionLiteral.resolve(
                String(repeating: "x", count: BrowserConditionLimits.maximumLiteralBytes + 1),
                for: .textContains
            )
        }
        #expect(!BrowserPageConditionProbeCapture.script.contains("ZenCODE"))
        #expect(BrowserPageConditionProbeCapture.script.contains("document.body"))
    }

    @Test
    func browserReadBudgetTruncatesOnUTF8CharacterBoundaries() {
        let content = String(repeating: "é", count: 100)
        let clipped = BrowserContentBudget.clip(content, maximumBytes: 80)

        #expect(clipped.originalByteCount == 200)
        #expect(clipped.wasTruncated)
        #expect(clipped.content.contains("[Content truncated by Browser read budget.]"))
        #expect(clipped.content.lengthOfBytes(using: .utf8) <= 80)
        #expect(clipped.content.data(using: .utf8) != nil)
    }
}
