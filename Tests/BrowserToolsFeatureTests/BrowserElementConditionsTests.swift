import Dispatch
import Foundation
@testable import BrowserToolsFeature
import FeatureKit
import Testing

@Suite
struct BrowserElementConditionsTests {
    @Test
    func elementConditionResolverAndLimitsAreClosedAndBounded() throws {
        #expect(try BrowserElementCondition.resolve("PRESENT") == .present)
        #expect(try BrowserElementCondition.resolve("text_contains") == .textContains)
        #expect(try BrowserElementCondition.resolve("VALUE_EQUALS") == .valueEquals)
        #expect(throws: BrowserToolsFeatureError.self) {
            try BrowserElementCondition.resolve("selector_matches")
        }

        let textLiteral = try #require(
            try BrowserElementConditionLiteral.resolve("Saved", for: .textContains)
        )
        #expect(textLiteral.value == "Saved")

        let emptyValue = try #require(
            try BrowserElementConditionLiteral.resolve("", for: .valueEquals)
        )
        #expect(emptyValue.value.isEmpty)
        #expect(try BrowserElementConditionLiteral.resolve(nil, for: .present) == nil)
        #expect(throws: BrowserToolsFeatureError.self) {
            try BrowserElementConditionLiteral.resolve("", for: .textContains)
        }
        #expect(throws: BrowserToolsFeatureError.self) {
            try BrowserElementConditionLiteral.resolve(
                String(repeating: "é", count: 501),
                for: .valueEquals
            )
        }
        #expect(throws: BrowserToolsFeatureError.self) {
            try BrowserElementConditionLiteral.resolve(
                String(repeating: "x", count: BrowserElementConditionLimits.maximumLiteralBytes + 1),
                for: .present
            )
        }

        #expect(try BrowserElementConditionLimits.resolveTimeout(nil) == 10)
        #expect(try BrowserElementConditionLimits.resolveTimeout(30) == 30)
        #expect(throws: BrowserToolsFeatureError.self) {
            try BrowserElementConditionLimits.resolveTimeout(31)
        }
    }

    @Test
    func elementConditionsEvaluateHostSideWithoutLeakingTextOrValues() throws {
        let textLiteral = try #require(
            try BrowserElementConditionLiteral.resolve("Saved", for: .textContains)
        )
        let valueLiteral = try #require(
            try BrowserElementConditionLiteral.resolve("draft", for: .valueEquals)
        )
        let probe = BrowserElementConditionProbe(
            present: true,
            visible: true,
            enabled: true,
            checked: false,
            text: "Saved successfully",
            value: "draft"
        )

        #expect(BrowserElementCondition.present.evaluate(probe: probe, literal: nil).satisfied)
        #expect(!BrowserElementCondition.absent.evaluate(probe: probe, literal: nil).satisfied)
        #expect(BrowserElementCondition.visible.evaluate(probe: probe, literal: nil).satisfied)
        #expect(!BrowserElementCondition.hidden.evaluate(probe: probe, literal: nil).satisfied)
        #expect(BrowserElementCondition.enabled.evaluate(probe: probe, literal: nil).satisfied)
        #expect(!BrowserElementCondition.disabled.evaluate(probe: probe, literal: nil).satisfied)
        #expect(!BrowserElementCondition.checked.evaluate(probe: probe, literal: nil).satisfied)
        #expect(BrowserElementCondition.unchecked.evaluate(probe: probe, literal: nil).satisfied)
        #expect(BrowserElementCondition.textContains.evaluate(probe: probe, literal: textLiteral).satisfied)
        #expect(BrowserElementCondition.valueEquals.evaluate(probe: probe, literal: valueLiteral).satisfied)

        let evaluation = BrowserElementCondition.valueEquals.evaluate(
            probe: probe,
            literal: valueLiteral
        )
        #expect(evaluation.observation.present == true)
        #expect(evaluation.observation.textByteCount == "Saved successfully".lengthOfBytes(using: .utf8))
        #expect(evaluation.observation.valueByteCount == "draft".lengthOfBytes(using: .utf8))
        #expect(!evaluation.observed.contains("draft"))
        #expect(!evaluation.observed.contains("Saved successfully"))

        let truncatedValue = BrowserElementConditionProbe(
            present: true,
            value: "draft",
            valueTruncated: true
        )
        #expect(!BrowserElementCondition.valueEquals.evaluate(
            probe: truncatedValue,
            literal: valueLiteral
        ).satisfied)

        let nonCheckable = BrowserElementConditionProbe(present: true, checked: nil)
        #expect(!BrowserElementCondition.unchecked.evaluate(probe: nonCheckable, literal: nil).satisfied)
    }

    @Test
    func disappearedElementProducesStructuredAbsentAndHiddenObservations() {
        let disappeared = BrowserElementConditionProbe.absent

        let absent = BrowserElementCondition.absent.evaluate(probe: disappeared, literal: nil)
        let hidden = BrowserElementCondition.hidden.evaluate(probe: disappeared, literal: nil)
        let visible = BrowserElementCondition.visible.evaluate(probe: disappeared, literal: nil)

        #expect(absent.satisfied)
        #expect(hidden.satisfied)
        #expect(!visible.satisfied)
        #expect(absent.observation.present == false)
        #expect(absent.observation.visible == nil)
        #expect(absent.observation.enabled == nil)
        #expect(absent.observed.contains("not present"))
    }

    @Test
    func fixedProbeDecoderBoundsPayloadAndDoesNotDependOnSelectors() throws {
        let decoded = try BrowserElementConditionProbeCapture.decode(
            #"{"present":true,"visible":false,"enabled":false,"checked":true,"text":"Hidden note","value":"off","textTruncated":false,"valueTruncated":false}"#
        )
        #expect(decoded.present)
        #expect(decoded.visible == false)
        #expect(decoded.enabled == false)
        #expect(decoded.checked == true)
        #expect(decoded.text == "Hidden note")
        #expect(decoded.value == "off")

        let absent = try BrowserElementConditionProbeCapture.decode(#"{"present":false}"#)
        #expect(!absent.present)
        #expect(absent.visible == nil)

        #expect(!BrowserElementConditionProbeCapture.functionDeclaration.contains("querySelector"))
        #expect(!BrowserElementConditionProbeCapture.functionDeclaration.contains("selector"))
        #expect(BrowserElementConditionProbeCapture.functionDeclaration.contains("getBoundingClientRect"))
        #expect(BrowserWaitElementTool.name == "browser.wait_element")
        #expect(BrowserAssertElementTool.name == "browser.assert_element")
    }

    @Test
    func targetNotBelongingToDocumentIsClassifiedAsAbsent() {
        let detached = CDPError.commandFailed(
            "Node with given id does not belong to the document"
        )
        #expect(BrowserElementConditionProbeCapture.isTargetNoLongerAvailable(detached))
    }

    @Test
    func probeRaceCancelsAndDrainsDeadlineLoser() async throws {
        let marker = BrowserElementConditionCancellationMarker()
        let deadline = DispatchTime.now().uptimeNanoseconds &+ 50_000_000

        let result = try await BrowserElementConditionProbeRace.race(
            until: deadline,
            operation: {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    await marker.markCancelled()
                    throw error
                }
                return 1
            }
        )

        #expect(result == nil)
        let didObserveCancellation = await marker.didObserveCancellation()
        // `race` awaits its cancelled child before returning, so the marker is
        // already set here rather than being completed by a leaked task later.
        #expect(didObserveCancellation)
    }
}

private actor BrowserElementConditionCancellationMarker {
    private var cancelled = false

    func markCancelled() {
        cancelled = true
    }

    func didObserveCancellation() -> Bool {
        cancelled
    }
}
