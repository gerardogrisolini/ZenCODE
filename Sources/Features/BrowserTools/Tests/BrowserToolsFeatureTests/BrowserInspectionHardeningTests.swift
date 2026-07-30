@testable import BrowserToolsFeature
import Testing

@Suite
struct BrowserInspectionHardeningTests {
    @Test
    func inspectorProjectionNeverReturnsFormValueOrCursor() throws {
        let node = try BrowserDOMInspection.parseDOMNode([
            "result": [
                "node": [
                    "nodeId": 17,
                    "localName": "input",
                    "attributes": [
                        "type", "text",
                        "value", "sensitive draft",
                        "placeholder", "Search",
                    ],
                ],
            ],
        ])
        #expect(node.element.attributes["value"] == nil)
        #expect(node.element.attributes["placeholder"] == "Search")

        let style = try BrowserDOMInspection.parseComputedStyle([
            "result": [
                "computedStyle": [
                    ["name": "cursor", "value": "url(https://example.test/private.cur), pointer"],
                    ["name": "display", "value": "block"],
                ],
            ],
        ])
        #expect(style.values == ["display": "block"])
        #expect(!BrowserDOMInspection.allowedComputedStyleProperties.contains("cursor"))
    }

    @Test
    func finalInspectorOutputDefensivelyStripsValueAndCursor() {
        let output = BrowserInspectOutput(
            page: BrowserPage(pageID: "page", title: "Title", url: "https://example.test/"),
            snapshotID: "snapshot",
            ref: "ax-1",
            inspection: BrowserDOMInspection.Selection(
                element: BrowserInspectableElement(
                    tagName: "input",
                    attributes: ["value": "must-not-appear", "placeholder": "Search"]
                ),
                boxModel: nil,
                computedStyle: ["cursor": "pointer", "display": "block"],
                truncated: false
            )
        )

        #expect(output.element.attributes["value"] == nil)
        #expect(output.element.attributes["placeholder"] == "Search")
        #expect(output.computedStyle["cursor"] == nil)
        #expect(output.computedStyle["display"] == "block")
        #expect(output.truncated)
    }
}
