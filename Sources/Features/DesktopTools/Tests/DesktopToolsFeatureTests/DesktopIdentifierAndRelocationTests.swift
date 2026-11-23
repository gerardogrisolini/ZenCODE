import CoreGraphics
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopIdentifierAndRelocationTests {
    private func element(
        _ role: String = "AXButton",
        title: String? = nil,
        description: String? = nil,
        identifier: String? = nil,
        pid: Int32 = 42,
        ref: String? = "p42.w7:0.4:AXButton:00000000"
    ) -> DesktopElementInfo {
        DesktopElementPolicy.makeInfo(
            role: role, title: title, description: description, identifier: identifier,
            frame: CGRect(x: 1, y: 2, width: 30, height: 40), actions: ["AXPress"],
            pid: pid, appName: "Calculator", windowTitle: "Calculator", ref: ref
        )
    }

    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: identifier

    @Test
    func identifierIsValidatedWithoutTrimming() throws {
        #expect(try DesktopElementPolicy.validatedIdentifier(nil) == nil)
        #expect(try DesktopElementPolicy.validatedIdentifier("   ") == nil)
        #expect(try DesktopElementPolicy.validatedIdentifier("Eight") == "Eight")
        #expect(try DesktopElementPolicy.validatedIdentifier(" Eight ") == " Eight ")
        let longest = String(repeating: "i", count: DesktopElementPolicy.maximumIdentifierCharacters)
        #expect(try DesktopElementPolicy.validatedIdentifier(longest) == longest)
        let error = #expect(throws: DesktopControlError.self) {
            try DesktopElementPolicy.validatedIdentifier(longest + "i")
        }
        #expect(error?.errorDescription == "Invalid argument 'identifier': must contain at most 256 characters.")
    }

    @Test
    func identifierMatchesExactlyAndCaseSensitively() {
        #expect(DesktopElementPolicy.identifierMatches("Eight", candidate: "Eight"))
        #expect(!DesktopElementPolicy.identifierMatches("Eight", candidate: "eight"))
        #expect(!DesktopElementPolicy.identifierMatches("Eight", candidate: "Eight "))
        #expect(!DesktopElementPolicy.identifierMatches("Eig", candidate: "Eight"))
        #expect(!DesktopElementPolicy.identifierMatches("Eight", candidate: nil))
    }

    @Test
    func elementSelectorsAcceptIdentifierAloneOrWithQuery() throws {
        let identifier = try DesktopElementPolicy.validatedElementSelectors(elementRef: nil, query: nil, identifier: "Eight")
        #expect(identifier == .init(reference: nil, query: nil, identifier: "Eight"))
        #expect(!identifier.isEmpty)
        let both = try DesktopElementPolicy.validatedElementSelectors(elementRef: " ", query: " 8 ", identifier: "Eight")
        #expect(both == .init(reference: nil, query: "8", identifier: "Eight"))
        let reference = try DesktopElementPolicy.validatedElementSelectors(elementRef: "p1.w2:0:AXButton:fbbf52e3", query: "", identifier: "  ")
        #expect(reference.reference == "p1.w2:0:AXButton:fbbf52e3" && reference.query == nil && reference.identifier == nil)
        #expect(try DesktopElementPolicy.validatedElementSelectors(elementRef: nil, query: nil, identifier: nil).isEmpty)
    }

    @Test
    func elementRefIsRefusedWithQueryOrIdentifier() {
        for (query, identifier) in [("Save", nil), (nil, "save-button"), ("Save", "save-button")] as [(String?, String?)] {
            let error = #expect(throws: DesktopControlError.self) {
                try DesktopElementPolicy.validatedElementSelectors(
                    elementRef: "p1.w2:0:AXButton:fbbf52e3", query: query, identifier: identifier
                )
            }
            #expect(error?.errorDescription == "Invalid argument 'element_ref/query/identifier': pass either element_ref, or query and/or identifier, not both.")
        }
        let tooLong = #expect(throws: DesktopControlError.self) {
            try DesktopElementPolicy.validatedElementSelectors(elementRef: nil, query: nil, identifier: String(repeating: "x", count: 300))
        }
        #expect(tooLong?.errorDescription?.hasPrefix("Invalid argument 'identifier'") == true)
    }

    @Test @MainActor
    func identifierCountsAsAnElementSelector() throws {
        let decode = { (json: String) in try JSONDecoder().decode(DesktopRunInput.self, from: Data(json.utf8)) }
        #expect(DesktopController.hasElementSelectors(try decode(#"{"action":"click","identifier":"Eight"}"#)))
        #expect(!DesktopController.hasElementSelectors(try decode(#"{"action":"click","identifier":"  "}"#)))
        #expect(!DesktopController.hasElementSelectors(try decode(#"{"action":"click","x":1,"y":2}"#)))
        #expect(try decode(#"{"action":"press_element","identifier":"Eight","query":"8","role":"button"}"#).identifier == "Eight")
    }

    @Test
    func identifierAloneActsOnASingleMatchEvenAfterAnIncompleteVisit() {
        let one = [element(identifier: "Eight")]
        #expect(DesktopElementPolicy.choose(one, query: nil, visitIsComplete: true) == .unique(0))
        #expect(DesktopElementPolicy.choose(one, query: nil, visitIsComplete: false) == .unique(0))
        let two = [element(title: "8", identifier: "Eight"), element(title: "8", identifier: "Eight")]
        #expect(DesktopElementPolicy.choose(two, query: nil, visitIsComplete: true) == .ambiguous([0, 1]))
        #expect(DesktopElementPolicy.choose(two, query: nil, visitIsComplete: false) == .incomplete([0, 1]))
        #expect(DesktopElementPolicy.choose([], query: nil) == .noMatch)
        // With a query too, the query's exact-match rule decides among them.
        let mixed = [element(title: "8 key", identifier: "Eight"), element(title: "8", identifier: "Eight")]
        #expect(DesktopElementPolicy.choose(mixed, query: "8", visitIsComplete: false) == .unique(1))
    }

    @Test
    func resolutionMessagesNameTheIdentifier() {
        #expect(DesktopElementPolicy.selectorPhrase(query: "8", identifier: nil) == "query '8'")
        #expect(DesktopElementPolicy.selectorPhrase(query: nil, identifier: "Eight") == "identifier 'Eight'")
        #expect(DesktopElementPolicy.selectorPhrase(query: "8", identifier: "Eight") == "query '8' and identifier 'Eight'")

        let none = DesktopElementPolicy.noMatchMessage(query: nil, identifier: "Eight", role: "button", scope: "window 'Calculator' of Calculator", interactiveOnly: true)
        #expect(none.hasPrefix("No element matches identifier 'Eight' with role button in window 'Calculator' of Calculator."))
        let candidates = [element(title: "8", identifier: "Eight"), element(title: "8", identifier: "Eight")]
        let ambiguous = DesktopElementPolicy.ambiguityMessage(query: "8", identifier: "Eight", candidates: candidates, scope: "Calculator")
        #expect(ambiguous.hasPrefix("2 elements match query '8' and identifier 'Eight' in Calculator: "))
        #expect(ambiguous.contains("Refine query, identifier, or role"))
        let incomplete = DesktopElementPolicy.incompleteVisitMessage(
            query: nil, identifier: "Eight", candidates: candidates, scope: "Calculator", truncation: "Stopped."
        )
        #expect(incomplete.hasPrefix("2 element(s) match identifier 'Eight' in Calculator so far, and the search did not cover the whole window: "))
        #expect(!incomplete.contains("exact title"))
    }

    @Test
    func identifierIsDeclaredInTheSchema() throws {
        let properties = try #require(try object(DesktopRunTool.inputSchema)["properties"] as? [String: Any])
        let identifier = try #require(properties["identifier"] as? [String: Any])
        #expect(identifier["type"] as? String == "string")
        #expect(identifier["maxLength"] as? Int == DesktopElementPolicy.maximumIdentifierCharacters)
        let description = try #require(identifier["description"] as? String)
        for fragment in ["Exact, case-sensitive AXIdentifier", "include_details=true", "alone or with query and role",
                         "Do not combine with element_ref or x/y", "scroll, drag, move_mouse, and press_key do not accept it"] {
            #expect(description.contains(fragment), "\(fragment)")
        }
    }

    @Test
    func reservedBytesCannotReframeDifferentFingerprintFields() {
        let first = DesktopElementReference.fingerprint(
            role: "AXButton", subrole: nil, title: "A\u{1F}\u{01}B", description: "C", identifier: nil
        )
        let second = DesktopElementReference.fingerprint(
            role: "AXButton", subrole: nil, title: "A", description: "B\u{1F}\u{01}C", identifier: nil
        )
        #expect(first != second)
    }

    // MARK: Relocation

    private let fingerprint = DesktopElementReference.fingerprint(
        role: "AXButton", subrole: nil, title: nil, description: "8", identifier: "Eight"
    )

    private var reference: DesktopElementReference {
        DesktopElementReference(pid: 42, window: .windowID(7), path: [0, 3], role: "AXButton", fingerprint: fingerprint)
    }

    @Test
    func aSingleMatchInACompleteVisitIsRelocated() {
        let moved = element(description: "8", identifier: "Eight", ref: "p42.w7:0.4:AXButton:\(fingerprint)")
        let others = [element(description: "7", identifier: "Seven"), element("AXStaticText", description: "8", identifier: "Eight")]
        #expect(DesktopElementReference.relocation(of: reference, candidates: [moved], visitIsComplete: true) == .relocated(0))
        #expect(DesktopElementReference.relocation(of: reference, candidates: others + [moved], visitIsComplete: true) == .relocated(2))
    }

    @Test
    func noMatchSeveralMatchesOrAnIncompleteVisitStayStale() {
        let moved = element(description: "8", identifier: "Eight", ref: "p42.w7:0.4:AXButton:\(fingerprint)")
        #expect(DesktopElementReference.relocation(of: reference, candidates: [], visitIsComplete: true) == .stale)
        #expect(DesktopElementReference.relocation(of: reference, candidates: [element(description: "9")], visitIsComplete: true) == .stale)
        #expect(DesktopElementReference.relocation(of: reference, candidates: [moved, moved], visitIsComplete: true) == .stale)
        #expect(DesktopElementReference.relocation(of: reference, candidates: [moved], visitIsComplete: false) == .stale)
    }

    @Test
    func anotherProcessOrAChangedElementIsNeverTaken() {
        // Same texts in another process: never the reference's element.
        let elsewhere = element(description: "8", identifier: "Eight", pid: 43, ref: "p43.w9:0:AXButton:\(fingerprint)")
        #expect(DesktopElementReference.relocation(of: reference, candidates: [elsewhere], visitIsComplete: true) == .stale)
        // A changed title or identifier changes the fingerprint.
        let renamed = element(description: "8", identifier: "EightKey")
        #expect(DesktopElementReference.relocation(of: reference, candidates: [renamed], visitIsComplete: true) == .stale)
        // Another role never matches, even with the same texts.
        let otherRole = element("AXMenuItem", description: "8", identifier: "Eight")
        #expect(DesktopElementReference.relocation(of: reference, candidates: [otherRole], visitIsComplete: true) == .stale)
    }

    @Test
    func aMatchWithoutANewRefIsNotRelocatedAndStillCounts() {
        let unanchored = element(description: "8", identifier: "Eight", ref: nil)
        let moved = element(description: "8", identifier: "Eight", ref: "p42.w7:0.4:AXButton:\(fingerprint)")
        #expect(DesktopElementReference.relocation(of: reference, candidates: [unanchored], visitIsComplete: true) == .stale)
        #expect(DesktopElementReference.relocation(of: reference, candidates: [unanchored, moved], visitIsComplete: true) == .stale)
    }

    @Test
    func relocationNoteTellsToUseTheNewRef() {
        #expect(DesktopElementReference.relocationNote
            == "element_ref was relocated: the element moved in the window's Accessibility tree; use the returned ref from now on.")
    }
}
