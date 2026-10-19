import Foundation
@testable import BrowserToolsFeature
import Testing

@Suite
struct BrowserFormInputRobustnessTests {
    // MARK: - Ref resolution

    @Test
    func refResolutionIgnoresTheSnapshotOutputBudget() throws {
        // Enough non-interactive text nodes to exceed the snapshot byte budget,
        // followed by the composer an interactiveOnly snapshot would expose.
        let filler = String(repeating: "x", count: 900)
        var nodes: [[String: Any]] = (1...200).map { index in
            [
                "nodeId": "\(index)",
                "backendDOMNodeId": index,
                "ignored": false,
                "role": ["value": "StaticText"],
                "name": ["value": filler],
            ]
        }
        nodes.append([
            "nodeId": "9999",
            "backendDOMNodeId": 4242,
            "ignored": false,
            "role": ["value": "textbox"],
            "name": ["value": "What is happening?"],
        ])
        let response: [String: Any] = ["result": ["nodes": nodes]]

        let full = try BrowserAccessibilitySnapshot.parse(response, interactiveOnly: false)
        #expect(full.truncated)
        #expect(full.targets["ax-9999"] == nil)

        let interactive = try BrowserAccessibilitySnapshot.parse(response, interactiveOnly: true)
        #expect(interactive.targets["ax-9999"] != nil)

        let target = try #require(try BrowserAccessibilitySnapshot.target(for: "ax-9999", in: response))
        #expect(target.backendDOMNodeID == 4242)
        #expect(target.interactive)
        #expect(try BrowserAccessibilitySnapshot.target(for: "ax-123456", in: response) == nil)
    }

    // MARK: - Fill

    @Test
    func fillResolvesEditorHostsAndNeverAssignsTextContent() {
        let prepare = CDPSession.prepareFillFunction
        // Rich-text editors expose descendants or wrappers of the host.
        #expect(prepare.contains("host.parentElement.isContentEditable"))
        #expect(prepare.contains("querySelectorAll('textarea, input, [contenteditable]')"))
        // Sensitive inputs stay guarded on the resolved host as well.
        #expect(prepare.contains("return 'password'"))
        #expect(prepare.contains("return 'file'"))
        #expect(prepare.contains("/password|passcode|secret/i"))
        #expect(prepare.contains("aria-readonly"))
        // Writing textContent desynchronizes framework editors.
        for function in [
            prepare,
            CDPSession.verifyFillFunction,
            CDPSession.nativeSetterFillFunction,
            CDPSession.editorCommandFillFunction,
        ] {
            #expect(!function.contains("textContent ="))
        }
        #expect(CDPSession.editorCommandFillFunction.contains("execCommand('insertText'"))
        #expect(CDPSession.verifyFillFunction.contains("return 'match'"))
    }

    @Test
    func fillNormalizesLineBreaks() {
        #expect(CDPSession.normalizedLineBreaks("a\r\nb\rc\nd") == "a\nb\nc\nd")
    }

    @Test
    func fillReportEncodesMethodNames() throws {
        let data = try JSONEncoder().encode(BrowserFillReport(method: .nativeSetter, verified: false))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"native_setter\""))
        #expect(json.contains("\"verified\":false"))
    }

    // MARK: - Keys

    @Test
    func keyStrokesSupportModifierCombinations() throws {
        let selectAll = try BrowserKeyStroke.resolve("Control+A", platform: .other)
        #expect(selectAll.key == "a")
        #expect(selectAll.code == "KeyA")
        #expect(selectAll.virtualKeyCode == 65)
        #expect(selectAll.modifiers == .control)
        #expect(selectAll.text == nil)
        #expect(selectAll.commands.isEmpty)

        let submit = try BrowserKeyStroke.resolve("cmd + enter", platform: .macOS)
        #expect(submit.key == "Enter")
        #expect(submit.modifiers == .meta)
        #expect(submit.text == nil)

        let backTab = try BrowserKeyStroke.resolve("Shift+Tab")
        #expect(backTab.modifiers == .shift)
        #expect(backTab.key == "Tab")

        let wordLeft = try BrowserKeyStroke.resolve("Ctrl+Shift+Arrow_Left")
        #expect(wordLeft.modifiers == [.control, .shift])
        #expect(wordLeft.key == "ArrowLeft")

        let digit = try BrowserKeyStroke.resolve("Alt+1")
        #expect(digit.code == "Digit1")
        #expect(digit.virtualKeyCode == 49)
    }

    @Test
    func textProducingKeysCarryTheirText() throws {
        #expect(try BrowserKeyStroke.resolve("Enter").text == "\r")
        #expect(try BrowserKeyStroke.resolve("Shift+Enter").text == "\r")
        #expect(try BrowserKeyStroke.resolve("Space").text == " ")
        #expect(try BrowserKeyStroke.resolve("Control+Enter").text == nil)
        #expect(try BrowserKeyStroke.resolve("Tab").text == nil)
        #expect(BrowserKeyStroke.softLineBreak.modifiers == .shift)
        #expect(BrowserKeyStroke.softLineBreak.text == "\r")
    }

    @Test
    func macOSEditingShortcutsCarryEditorCommands() throws {
        #expect(try BrowserKeyStroke.resolve("Meta+A", platform: .macOS).commands == ["selectAll"])
        #expect(try BrowserKeyStroke.resolve("Meta+V", platform: .macOS).commands == ["paste"])
        #expect(try BrowserKeyStroke.resolve("Meta+Shift+Z", platform: .macOS).commands == ["redo"])
        #expect(try BrowserKeyStroke.resolve("Meta+A", platform: .other).commands.isEmpty)
        #expect(try BrowserKeyStroke.resolve("Control+A", platform: .macOS).commands.isEmpty)

        let macSelectAll = BrowserKeyStroke.selectAll(platform: .macOS)
        #expect(macSelectAll.modifiers == .meta)
        #expect(macSelectAll.commands == ["selectAll"])
        #expect(BrowserKeyStroke.selectAll(platform: .other).modifiers == .control)
    }

    @Test
    func keyStrokesRejectTextEntryAndMalformedCombinations() {
        for rawValue in ["a", "Shift+a", "Ctrl+Ctrl+A", "Hyper+A", "Control+", "+Enter", "Control+AB", "Control+é"] {
            #expect(throws: BrowserInteractionError.unsupportedKey(rawValue)) {
                try BrowserKeyStroke.resolve(rawValue)
            }
        }
    }

    // MARK: - Scroll

    @Test
    func scrollActionResolvesDirectionAndAmount() throws {
        #expect(try BrowserActionKind.resolve("SCROLL") == .scroll)
        #expect(try BrowserScrollDirection.resolve(nil) == .down)
        #expect(try BrowserScrollDirection.resolve(" Up ") == .up)
        #expect(throws: BrowserInteractionError.unsupportedScrollDirection("sideways")) {
            try BrowserScrollDirection.resolve("sideways")
        }
        #expect(try BrowserScrollDirection.resolveAmount(nil) == nil)
        #expect(try BrowserScrollDirection.resolveAmount(600) == 600)
        for invalid in [0, -5, 100_001, Double.nan, Double.infinity] {
            #expect(throws: BrowserInteractionError.invalidScrollAmount) {
                try BrowserScrollDirection.resolveAmount(invalid)
            }
        }
    }

    @Test
    func scrollMetricsReportMovementAndEnds() throws {
        let top = try BrowserScrollMetrics.parse(
            #"{"page":true,"x":0,"y":0,"maxX":0,"maxY":2000,"clientWidth":800,"clientHeight":600}"#
        )
        let bottom = try BrowserScrollMetrics.parse(
            #"{"page":true,"x":0,"y":2000,"maxX":0,"maxY":2000,"clientWidth":800,"clientHeight":600}"#
        )
        #expect(top.reachedEnd(.up))
        #expect(!top.reachedEnd(.down))
        #expect(top.reachedEnd(.left))
        #expect(top.reachedEnd(.right))
        #expect(bottom.reachedEnd(.down))
        #expect(bottom.moved(from: top, vertical: true))
        #expect(!bottom.moved(from: top, vertical: false))
        #expect(throws: CDPError.self) {
            try BrowserScrollMetrics.parse("not json")
        }
    }

    @Test
    func scrollPointUsesTheVisiblePartOfTheTarget() {
        let tallFeed = BrowserViewportBounds(minX: 100, minY: -500, maxX: 500, maxY: 3000)
        let center = tallFeed.visibleCenter(viewportWidth: 1000, viewportHeight: 800)
        #expect(center.x == 300)
        #expect(center.y == 400)

        let offscreen = BrowserViewportBounds(minX: 0, minY: 900, maxX: 100, maxY: 1000)
        let fallback = offscreen.visibleCenter(viewportWidth: 1000, viewportHeight: 800)
        #expect(fallback.x == 500)
        #expect(fallback.y == 400)

        let quad = BrowserViewportBounds(quad: [10, 20, 110, 20, 110, 70, 10, 70])
        #expect(quad == BrowserViewportBounds(minX: 10, minY: 20, maxX: 110, maxY: 70))
        #expect(BrowserViewportBounds(quad: [1, 2, 3]) == nil)
    }

    @Test
    func scrollContainerSearchCrossesShadowRootsAndFallsBackToThePage() {
        let locate = CDPSession.locateScrollContainerFunction
        #expect(locate.contains("root instanceof ShadowRoot ? root.host"))
        #expect(locate.contains("document.elementFromPoint(options.x, options.y)"))
        #expect(locate.contains("document.scrollingElement"))
        #expect(CDPSession.scrollMetricsFunction.contains("behavior: 'instant'"))
    }

    // MARK: - Hit testing

    @Test
    func hitTestResultsDistinguishCoveredAndOffscreenTargets() {
        #expect(BrowserHitTestResult.parse("ok") == .clear)
        #expect(BrowserHitTestResult.parse("unknown") == .clear)
        #expect(BrowserHitTestResult.parse("offscreen") == .outsideViewport)
        #expect(BrowserHitTestResult.parse(#"covered:<div role="dialog"> "Accept cookies""#)
            == .covered(#"<div role="dialog"> "Accept cookies""#))
        #expect(BrowserHitTestResult.parse("covered:") == .covered("unknown element"))

        let long = "covered:" + String(repeating: "y", count: 500)
        guard case let .covered(detail) = BrowserHitTestResult.parse(long) else {
            Issue.record("Expected a covered result")
            return
        }
        #expect(detail.lengthOfBytes(using: .utf8) <= BrowserHitTestResult.maximumObstructionBytes + 3)
    }

    @Test
    func hitTestAcceptsDescendantsLabelsAndReceivingAncestors() {
        let function = CDPSession.hitTestFunction
        #expect(function.contains("node.parentNode || node.host"))
        #expect(function.contains("label.control === element"))
        #expect(function.contains("hit.contains(element)"))
        #expect(function.contains("window !== window.top"))
    }

    @Test
    func actionOutputOmitsReportsForOtherActions() throws {
        let page = BrowserPage(pageID: "p", title: "Example", url: "https://example.com")
        let output = BrowserActionOutput(page: page, action: .click, targetRef: "ax-1", dialog: nil)
        let json = try #require(String(data: JSONEncoder().encode(output), encoding: .utf8))
        #expect(!json.contains("\"fill\""))
        #expect(!json.contains("\"scroll\""))
    }
}
