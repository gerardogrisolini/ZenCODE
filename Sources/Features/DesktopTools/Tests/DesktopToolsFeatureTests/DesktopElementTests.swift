import CoreGraphics
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopElementReferenceTests {
    private let fingerprint = "fbbf52e3"

    @Test
    func encodesWindowIDAnchor() {
        let reference = DesktopElementReference(pid: 1234, window: .windowID(1294), path: [0, 3, 1], role: "AXTextField", fingerprint: fingerprint)
        #expect(reference.encoded == "p1234.w1294:0.3.1:AXTextField:fbbf52e3")
    }

    @Test
    func encodesIndexAnchorWithAndWithoutTitle() throws {
        let untitled = DesktopElementReference(pid: 7, window: .windowIndex(2, titlePrefix: nil), path: [], role: "AXWindow", fingerprint: fingerprint)
        #expect(untitled.encoded == "p7.i2::AXWindow:fbbf52e3")
        let titled = DesktopElementReference(pid: 7, window: .windowIndex(0, titlePrefix: "Project: Ä/b+c?"), path: [4], role: "AXButton", fingerprint: fingerprint)
        let encoded = try #require(titled.encoded)
        #expect(encoded.hasPrefix("p7.i0.t"))
        #expect(encoded.hasSuffix(":4:AXButton:fbbf52e3"))
        #expect(encoded.split(separator: ":", omittingEmptySubsequences: false).count == 4)
        #expect(!encoded.contains("="))
        #expect(!encoded.contains("+") && !encoded.contains("/"))
    }

    @Test
    func decodesEncodedReferences() throws {
        let reference = try DesktopElementReference(parsing: "p1234.w1294:0.3.1:AXTextField:0a1b2c3d")
        #expect(reference.pid == 1234)
        #expect(reference.window == .windowID(1294))
        #expect(reference.path == [0, 3, 1])
        #expect(reference.role == "AXTextField")
        #expect(reference.fingerprint == "0a1b2c3d")
        let window = try DesktopElementReference(parsing: "p9.i0::AXWindow:00000000")
        #expect(window.window == .windowIndex(0, titlePrefix: nil))
        #expect(window.path.isEmpty)
    }

    @Test(arguments: [
        DesktopElementReference(pid: 1, window: .windowID(1), path: [0], role: "AXButton", fingerprint: "00000000"),
        DesktopElementReference(pid: Int32.max, window: .windowID(UInt32.max), path: Array(repeating: 999_999, count: 60), role: "AXRow", fingerprint: "ffffffff"),
        DesktopElementReference(pid: 42, window: .windowIndex(500, titlePrefix: "Untitled — Edited 🎬"), path: [1, 0, 12], role: "AX_custom9", fingerprint: "e9b14ae0"),
        DesktopElementReference(pid: 42, window: .windowIndex(3, titlePrefix: nil), path: [], role: "AXSheet", fingerprint: "fbbf52e3"),
        DesktopElementReference(pid: 42, window: .windowIndex(0, titlePrefix: "a:b.c"), path: [5], role: "AXLink", fingerprint: "12ab34cd")
    ])
    func roundTrips(_ reference: DesktopElementReference) throws {
        let encoded = try #require(reference.encoded)
        #expect(encoded.utf8.count <= DesktopElementReference.maximumLength)
        let decoded = try DesktopElementReference(parsing: encoded)
        #expect(decoded == reference)
        #expect(decoded.encoded == encoded)
    }

    @Test
    func longTitlesAreStoredAsABoundedPrefix() throws {
        let title = String(repeating: "Ü", count: 300)
        let reference = DesktopElementReference(pid: 5, window: .windowIndex(0, titlePrefix: title), path: [1], role: "AXButton", fingerprint: fingerprint)
        #expect(reference.window == .windowIndex(0, titlePrefix: String(repeating: "Ü", count: 64)))
        let decoded = try DesktopElementReference(parsing: try #require(reference.encoded))
        #expect(decoded == reference)
        #expect(DesktopElementReference.titleMatches(title, prefix: String(repeating: "Ü", count: 64)))
        #expect(!DesktopElementReference.titleMatches("Other", prefix: "Ü"))
        #expect(DesktopElementReference.titleMatches(nil, prefix: nil))
    }

    @Test(arguments: [
        "", "p1", "p1.w2", "p1.w2:0", "p1.w2:0:AXButton:fbbf52e3:extra", "x1.w2:0:AXButton:fbbf52e3",
        "p0.w2:0:AXButton:fbbf52e3", "p-1.w2:0:AXButton:fbbf52e3", "p+1.w2:0:AXButton:fbbf52e3", "p01.w2:0:AXButton:fbbf52e3",
        "p2147483648.w2:0:AXButton:fbbf52e3", "p1.w0:0:AXButton:fbbf52e3", "p1.w4294967296:0:AXButton:fbbf52e3",
        "p1.w2.t QQ:0:AXButton:fbbf52e3", "p1.x2:0:AXButton:fbbf52e3", "p1.i501:0:AXButton:fbbf52e3", "p1.i01:0:AXButton:fbbf52e3",
        "p1.i0.t:0:AXButton:fbbf52e3", "p1.i0.tQQ=:0:AXButton:fbbf52e3", "p1.i0.t$$:0:AXButton:fbbf52e3", "p1.i0.q:0:AXButton:fbbf52e3",
        "p1.i0.tQQ.tQQ:0:AXButton:fbbf52e3", "p1.w2:0..1:AXButton:fbbf52e3", "p1.w2:.0:AXButton:fbbf52e3", "p1.w2:0.:AXButton:fbbf52e3",
        "p1.w2:00:AXButton:fbbf52e3", "p1.w2:-1:AXButton:fbbf52e3", "p1.w2:1000000:AXButton:fbbf52e3", "p1.w2:0::fbbf52e3",
        "p1.w2:0:AX Button:fbbf52e3", "p1.w2:0:AX.Button:fbbf52e3", "p1.w2:0:AXBütton:fbbf52e3",
        "p1.w2:0:" + String(repeating: "A", count: 65) + ":fbbf52e3",
        // The fingerprint is required and is exactly eight lowercase hex digits.
        "p1.w2:0:AXButton", "p1.w2:0:AXButton:", "p1.w2:0:AXButton:FBBF52E3", "p1.w2:0:AXButton:fbbf52e",
        "p1.w2:0:AXButton:fbbf52e30", "p1.w2:0:AXButton:fbbf52eg", "p1.w2:0:AXButton:-bbf52e3"
    ])
    func malformedReferencesAreRejected(_ raw: String) {
        #expect(throws: DesktopControlError.self) {
            _ = try DesktopElementReference(parsing: raw)
        }
    }

    @Test
    func pathDepthAndLengthAreBounded() throws {
        let deepPath = Array(repeating: "0", count: DesktopElementReference.maximumPathDepth + 1).joined(separator: ".")
        #expect(throws: DesktopControlError.self) {
            _ = try DesktopElementReference(parsing: "p1.w2:\(deepPath):AXButton:fbbf52e3")
        }
        let maximumPath = Array(repeating: 0, count: DesktopElementReference.maximumPathDepth)
        let atLimit = DesktopElementReference(pid: 1, window: .windowID(2), path: maximumPath, role: "AXButton", fingerprint: fingerprint)
        #expect(try DesktopElementReference(parsing: try #require(atLimit.encoded)) == atLimit)

        let tooLong = DesktopElementReference(
            pid: 1, window: .windowIndex(0, titlePrefix: String(repeating: "🎬", count: 64)),
            path: Array(repeating: 999_999, count: DesktopElementReference.maximumPathDepth), role: "AXButton",
            fingerprint: fingerprint
        )
        #expect(tooLong.encoded == nil)
        #expect(throws: DesktopControlError.self) {
            _ = try DesktopElementReference(parsing: "p1.w2:0:AXButton:fbbf52e3" + String(repeating: "x", count: 1024))
        }
    }

    @Test
    func unrepresentableReferencesDoNotEncode() {
        #expect(DesktopElementReference(pid: 0, window: .windowID(2), path: [0], role: "AXButton", fingerprint: fingerprint).encoded == nil)
        #expect(DesktopElementReference(pid: 1, window: .windowID(0), path: [0], role: "AXButton", fingerprint: fingerprint).encoded == nil)
        #expect(DesktopElementReference(pid: 1, window: .windowIndex(501, titlePrefix: nil), path: [0], role: "AXButton", fingerprint: fingerprint).encoded == nil)
        #expect(DesktopElementReference(pid: 1, window: .windowID(2), path: [-1], role: "AXButton", fingerprint: fingerprint).encoded == nil)
        #expect(DesktopElementReference(pid: 1, window: .windowID(2), path: [0], role: "AX:Button", fingerprint: fingerprint).encoded == nil)
        #expect(DesktopElementReference(pid: 1, window: .windowID(2), path: [0], role: "", fingerprint: fingerprint).encoded == nil)
        for invalid in ["", "FBBF52E3", "fbbf52e", "fbbf52e3a", "fbbf:2e3"] {
            #expect(DesktopElementReference(pid: 1, window: .windowID(2), path: [0], role: "AXButton", fingerprint: invalid).encoded == nil)
        }
    }

    @Test
    func windowIndexAnchorPrefersRecordedIndexThenUniqueTitle() {
        let titles: [String?] = ["Inspector", "Project", nil, "Project copy"]
        #expect(DesktopElementReference.resolveWindowIndex(titles: titles, index: 1, titlePrefix: "Project") == 1)
        // Windows reorder as focus changes: a unique title match is followed.
        #expect(DesktopElementReference.resolveWindowIndex(titles: titles, index: 0, titlePrefix: "Project copy") == 3)
        #expect(DesktopElementReference.resolveWindowIndex(titles: ["Project", "Project"], index: 5, titlePrefix: "Project") == nil)
        #expect(DesktopElementReference.resolveWindowIndex(titles: titles, index: 0, titlePrefix: "Missing") == nil)
        #expect(DesktopElementReference.resolveWindowIndex(titles: titles, index: 2, titlePrefix: nil) == 2)
        #expect(DesktopElementReference.resolveWindowIndex(titles: titles, index: 9, titlePrefix: nil) == nil)
    }

    @Test
    func indexAnchorNeverClaimsAnUntitledWindowWhenTheTitleReadFailed() {
        // A readable title, or a window that has none, still anchors by index.
        #expect(DesktopElementReference.indexAnchor(index: 2, title: "Project", titleReadFailed: false)
            == .windowIndex(2, titlePrefix: "Project"))
        #expect(DesktopElementReference.indexAnchor(index: 2, title: nil, titleReadFailed: false)
            == .windowIndex(2, titlePrefix: nil))
        #expect(DesktopElementReference.indexAnchor(index: 0, title: "", titleReadFailed: false)
            == .windowIndex(0, titlePrefix: nil))
        let long = String(repeating: "x", count: 100)
        #expect(DesktopElementReference.indexAnchor(index: 1, title: long, titleReadFailed: false)
            == .windowIndex(1, titlePrefix: String(repeating: "x", count: DesktopElementReference.titlePrefixLength)))
        // A timeout or an AX error while reading the title leaves no anchor, so no ref.
        #expect(DesktopElementReference.indexAnchor(index: 2, title: nil, titleReadFailed: true) == nil)
        #expect(DesktopElementReference.indexAnchor(index: 2, title: "Project", titleReadFailed: true) == nil)
        #expect(DesktopElementReference.indexAnchor(index: nil, title: "Project", titleReadFailed: false) == nil)
    }

    @Test
    func untitledAnchorAcceptsOnlyAnUntitledWindow() {
        let titles: [String?] = ["Inspector", nil, "", "Project"]
        // The window now at the recorded index has a title: not the same window.
        #expect(DesktopElementReference.resolveWindowIndex(titles: titles, index: 0, titlePrefix: nil) == nil)
        #expect(DesktopElementReference.resolveWindowIndex(titles: titles, index: 3, titlePrefix: nil) == nil)
        // Untitled windows (nil or empty title) still match, but only at the recorded index.
        #expect(DesktopElementReference.resolveWindowIndex(titles: titles, index: 1, titlePrefix: nil) == 1)
        #expect(DesktopElementReference.resolveWindowIndex(titles: titles, index: 2, titlePrefix: nil) == 2)
        #expect(!DesktopElementReference.titleMatches("Inspector", prefix: nil))
        #expect(DesktopElementReference.titleMatches("", prefix: nil))
        // A titled anchor never matches an untitled window.
        #expect(DesktopElementReference.resolveWindowIndex(titles: [nil], index: 0, titlePrefix: "Project") == nil)
    }

    // MARK: Fingerprint

    @Test
    func fingerprintIsADeterministicFNV1aOfTheIdentityFields() {
        // Reference values computed independently (FNV-1a, 32 bit).
        #expect(DesktopElementReference.fingerprint(role: "AXButton", subrole: nil, title: "Save", description: nil, identifier: nil) == "fbbf52e3")
        #expect(DesktopElementReference.fingerprint(
            role: "AXTextField", subrole: "AXSearchField", title: nil, description: "Search", identifier: "search.field"
        ) == "e9b14ae0")
        let info = DesktopElementPolicy.makeInfo(role: "AXButton", title: "Save")
        #expect(DesktopElementReference.fingerprint(of: info) == "fbbf52e3")
        #expect(DesktopElementReference.isValidFingerprint(DesktopElementReference.fingerprint(of: info)))
    }

    @Test
    func fingerprintIgnoresValueAndFrameButNotIdentity() {
        let base = DesktopElementPolicy.makeInfo(
            role: "AXTextField", title: "Name", value: "one", frame: CGRect(x: 0, y: 0, width: 10, height: 10)
        )
        let edited = DesktopElementPolicy.makeInfo(
            role: "AXTextField", title: "Name", value: "two", frame: CGRect(x: 50, y: 60, width: 20, height: 10)
        )
        #expect(DesktopElementReference.fingerprint(of: base) == DesktopElementReference.fingerprint(of: edited))
        let changes = [
            DesktopElementPolicy.makeInfo(role: "AXTextArea", title: "Name"),
            DesktopElementPolicy.makeInfo(role: "AXTextField", subrole: "AXSearchField", title: "Name"),
            DesktopElementPolicy.makeInfo(role: "AXTextField", title: "Surname"),
            DesktopElementPolicy.makeInfo(role: "AXTextField", title: "Name", description: "name"),
            DesktopElementPolicy.makeInfo(role: "AXTextField", title: "Name", identifier: "name.field")
        ]
        for changed in changes {
            #expect(DesktopElementReference.fingerprint(of: changed) != DesktopElementReference.fingerprint(of: base))
        }
        // The same text in another field is a different element.
        #expect(DesktopElementReference.fingerprint(role: "AXButton", subrole: nil, title: "Save", description: nil, identifier: nil)
            != DesktopElementReference.fingerprint(role: "AXButton", subrole: nil, title: nil, description: "Save", identifier: nil))
        // Blank texts count as absent.
        #expect(DesktopElementReference.fingerprint(role: "AXButton", subrole: " ", title: "Save", description: "", identifier: nil) == "fbbf52e3")
    }

    @Test
    func aReferenceToAChangedElementDoesNotMatchItsFingerprint() throws {
        let original = DesktopElementPolicy.makeInfo(role: "AXButton", title: "Save")
        let reference = DesktopElementReference(
            pid: 3, window: .windowID(9), path: [0, 2], role: "AXButton",
            fingerprint: DesktopElementReference.fingerprint(of: original)
        )
        let decoded = try DesktopElementReference(parsing: try #require(reference.encoded))
        #expect(decoded.fingerprint == DesktopElementReference.fingerprint(of: original))
        // Same path and role, different element: resolution treats it as stale.
        let sibling = DesktopElementPolicy.makeInfo(role: "AXButton", title: "Delete")
        #expect(decoded.fingerprint != DesktopElementReference.fingerprint(of: sibling))
    }
}

@Suite
struct DesktopElementPolicyTests {
    private func element(
        _ role: String,
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        identifier: String? = nil,
        roleDescription: String? = nil,
        ref: String? = nil
    ) -> DesktopElementInfo {
        DesktopElementPolicy.makeInfo(
            role: role, subrole: subrole, roleDescription: roleDescription, title: title,
            description: description, value: value, placeholder: placeholder, identifier: identifier, ref: ref
        )
    }

    @Test
    func roleFilterIsNormalizedAndValidated() throws {
        #expect(try DesktopElementPolicy.normalizedRoleFilter(nil) == nil)
        #expect(try DesktopElementPolicy.normalizedRoleFilter("  ") == nil)
        #expect(try DesktopElementPolicy.normalizedRoleFilter(" AXTextField ") == "axtextfield")
        for invalid in ["AX TextField", "AX:Button", String(repeating: "a", count: 65), "role!"] {
            #expect(throws: DesktopControlError.self) {
                _ = try DesktopElementPolicy.normalizedRoleFilter(invalid)
            }
        }
    }

    @Test(arguments: ["AXTextField", "textfield", "TextField", "axtextfield", "AXTEXTFIELD"])
    func roleMatchesWithOrWithoutPrefix(_ filter: String) throws {
        let normalized = try #require(try DesktopElementPolicy.normalizedRoleFilter(filter))
        #expect(DesktopElementPolicy.roleMatches(normalized, role: "AXTextField", subrole: nil))
        #expect(!DesktopElementPolicy.roleMatches(normalized, role: "AXTextArea", subrole: nil))
    }

    @Test
    func roleFilterMatchesSubroles() {
        #expect(DesktopElementPolicy.roleMatches("axsearchfield", role: "AXTextField", subrole: "AXSearchField"))
        #expect(DesktopElementPolicy.roleMatches("searchfield", role: "AXTextField", subrole: "AXSearchField"))
        #expect(!DesktopElementPolicy.roleMatches("searchfield", role: "AXTextField", subrole: nil))
        // A role whose name itself starts with "Ax" still matches without the prefix.
        #expect(DesktopElementPolicy.roleMatches("axislabel", role: "AXAxisLabel", subrole: nil))
        #expect(!DesktopElementPolicy.roleMatches("field", role: "AXTextField", subrole: nil))
    }

    @Test
    func interactiveFilterUsesRolesSubrolesActionsAndSettableValues() {
        #expect(DesktopElementPolicy.isInteractive(role: "AXButton", subrole: nil, actions: [], valueSettable: false))
        #expect(DesktopElementPolicy.isInteractive(role: "AXRadioButton", subrole: "AXTabButton", actions: [], valueSettable: false))
        #expect(DesktopElementPolicy.isInteractive(role: "AXGroup", subrole: "AXSearchField", actions: [], valueSettable: false))
        #expect(DesktopElementPolicy.isInteractive(role: "AXGroup", subrole: nil, actions: ["AXShowMenu", "AXPress"], valueSettable: false))
        #expect(DesktopElementPolicy.isInteractive(role: "AXCell", subrole: nil, actions: ["AXPick"], valueSettable: false))
        #expect(DesktopElementPolicy.isInteractive(role: "AXGroup", subrole: nil, actions: ["AXConfirm"], valueSettable: false))
        #expect(DesktopElementPolicy.isInteractive(role: "AXStaticText", subrole: nil, actions: [], valueSettable: true))
        #expect(!DesktopElementPolicy.isInteractive(role: "AXStaticText", subrole: nil, actions: ["AXShowMenu"], valueSettable: false))
        #expect(!DesktopElementPolicy.isInteractive(role: "AXGroup", subrole: nil, actions: [], valueSettable: false))
    }

    @Test
    func clickFocusFallbackIsLimitedToTextEntry() {
        #expect(DesktopElementPolicy.allowsFocusClickFallback(role: "AXTextField", subrole: nil))
        #expect(DesktopElementPolicy.allowsFocusClickFallback(role: "AXTextArea", subrole: nil))
        #expect(DesktopElementPolicy.allowsFocusClickFallback(role: "AXComboBox", subrole: nil))
        #expect(DesktopElementPolicy.allowsFocusClickFallback(role: "AXGroup", subrole: "AXSearchField"))
        #expect(DesktopElementPolicy.allowsFocusClickFallback(role: "AXGroup", subrole: "AXSecureTextField"))
        // A settable value is not enough: a click would move a slider, a
        // scroll bar, or a stepper instead of focusing it.
        for other in ["AXSlider", "AXScrollBar", "AXIncrementor", "AXStaticText", "AXGroup", "AXButton", "AXCheckBox",
                      "AXRadioButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXPopUpButton", "AXMenuButton",
                      "AXDisclosureTriangle"] {
            #expect(!DesktopElementPolicy.allowsFocusClickFallback(role: other, subrole: nil), "\(other) must not be clicked to focus it")
        }
        #expect(!DesktopElementPolicy.allowsFocusClickFallback(role: "AXRadioButton", subrole: "AXTabButton"))
    }

    @Test
    func queryMatchesTextFieldsIgnoringCaseAndDiacritics() throws {
        #expect(try DesktopElementPolicy.validatedQuery("  ") == nil)
        #expect(try DesktopElementPolicy.validatedQuery(" Save ") == "Save")
        #expect(throws: DesktopControlError.self) {
            _ = try DesktopElementPolicy.validatedQuery(String(repeating: "q", count: 201))
        }
        #expect(DesktopElementPolicy.matchesQuery("cafe", element: element("AXButton", title: "Café Crème")))
        #expect(DesktopElementPolicy.matchesQuery("CRÈME", element: element("AXButton", title: "café creme")))
        #expect(DesktopElementPolicy.matchesQuery("export", element: element("AXButton", description: "Export Movie")))
        #expect(DesktopElementPolicy.matchesQuery("hello", element: element("AXTextField", value: "Hello world")))
        #expect(DesktopElementPolicy.matchesQuery("search", element: element("AXTextField", placeholder: "Search library")))
        #expect(DesktopElementPolicy.matchesQuery("toolbar", element: element("AXButton", identifier: "toolbar.share")))
        #expect(DesktopElementPolicy.matchesQuery("disclosure", element: element("AXDisclosureTriangle", roleDescription: "Disclosure triangle")))
        #expect(!DesktopElementPolicy.matchesQuery("save", element: element("AXButton", title: "Open")))
        // Secure fields never expose their value, so it cannot be matched.
        #expect(!DesktopElementPolicy.matchesQuery("hunter2", element: element("AXTextField", subrole: "AXSecureTextField", value: "hunter2")))
    }

    @Test
    func singleMatchIsChosen() {
        #expect(DesktopElementPolicy.choose([element("AXButton", title: "Save as…")], query: "save") == .unique(0))
        #expect(DesktopElementPolicy.choose([], query: "save") == .noMatch)
    }

    @Test
    func uniqueExactMatchIsPreferred() {
        let candidates = [
            element("AXButton", title: "Save as…"),
            element("AXButton", title: "save"),
            element("AXMenuItem", title: "Autosave"),
            element("AXTextField", value: "Save")
        ]
        #expect(DesktopElementPolicy.choose(candidates, query: "Save") == .unique(1))
        let byDescription = [element("AXButton", description: "Export"), element("AXButton", description: "Export all")]
        #expect(DesktopElementPolicy.choose(byDescription, query: "EXPORT") == .unique(0))
        let byPlaceholder = [element("AXTextField", placeholder: "Search"), element("AXTextField", placeholder: "Search mail")]
        #expect(DesktopElementPolicy.choose(byPlaceholder, query: "search") == .unique(0))
    }

    @Test
    func ambiguityListsUpToFiveCandidatesWithRefs() {
        let candidates = (0..<7).map { index in
            element("AXButton", title: "Item \(index)", ref: "p1.w2:\(index):AXButton")
        }
        guard case let .ambiguous(indices) = DesktopElementPolicy.choose(candidates, query: "item") else {
            Issue.record("Expected an ambiguous choice.")
            return
        }
        #expect(indices.count == 7)
        let message = DesktopElementPolicy.ambiguityMessage(
            query: "item", candidates: indices.map { candidates[$0] }, scope: "window 'Main' of App"
        )
        #expect(message.contains("7 elements match query 'item' in window 'Main' of App"))
        #expect(message.contains("AXButton 'Item 0' (element_ref p1.w2:0:AXButton)"))
        #expect(message.contains("p1.w2:4:AXButton"))
        #expect(!message.contains("p1.w2:5:AXButton"))
        #expect(message.contains("element_ref"))

        // Two exact matches stay ambiguous, listed first.
        let twoExact = [element("AXButton", title: "OK x"), element("AXButton", title: "ok"), element("AXButton", title: "OK")]
        #expect(DesktopElementPolicy.choose(twoExact, query: "ok") == .ambiguous([1, 2, 0]))
    }

    @Test
    func noMatchSuggestsListElements() {
        let message = DesktopElementPolicy.noMatchMessage(query: "Render", role: "button", scope: "window 'Main' of App", interactiveOnly: true)
        #expect(message.contains("No element matches query 'Render' with role button in window 'Main' of App"))
        #expect(message.contains("list_elements"))
        #expect(message.contains("interactive_only=false"))
        #expect(!DesktopElementPolicy.noMatchMessage(query: "x", role: nil, scope: "App", interactiveOnly: false).contains("interactive_only"))
    }

    // MARK: Truncated visits

    @Test
    func truncatedVisitActsOnlyOnASingleExactMatch() {
        // A lone substring match is not enough when the visit was cut short.
        #expect(DesktopElementPolicy.choose([element("AXButton", title: "Save as…")], query: "save", visitIsComplete: false) == .incomplete([0]))
        #expect(DesktopElementPolicy.choose([element("AXButton", title: "Save as…")], query: "save", visitIsComplete: true) == .unique(0))
        // A single exact match still wins.
        #expect(DesktopElementPolicy.choose([element("AXButton", title: "Save")], query: "save", visitIsComplete: false) == .unique(0))
        let mixed = [element("AXButton", title: "Save as…"), element("AXButton", description: "SAVE"), element("AXMenuItem", title: "Autosave")]
        #expect(DesktopElementPolicy.choose(mixed, query: "save", visitIsComplete: false) == .unique(1))
        // Two exact matches, or none among several, stay unresolved, exact first.
        let twoExact = [element("AXButton", title: "OK x"), element("AXButton", title: "ok"), element("AXButton", title: "OK")]
        #expect(DesktopElementPolicy.choose(twoExact, query: "ok", visitIsComplete: false) == .incomplete([1, 2, 0]))
        let noneExact = [element("AXButton", title: "Save as…"), element("AXMenuItem", title: "Autosave")]
        #expect(DesktopElementPolicy.choose(noneExact, query: "save", visitIsComplete: false) == .incomplete([0, 1]))
        #expect(DesktopElementPolicy.choose([], query: "save", visitIsComplete: false) == .noMatch)
    }

    @Test
    func incompleteVisitMessageCarriesTheBudgetNoteAndTheWayOut() {
        let candidates = [element("AXButton", title: "Save as…", ref: "p1.w2:0:AXButton:fbbf52e3")]
        let message = DesktopElementPolicy.incompleteVisitMessage(
            query: "save", candidates: candidates, scope: "window 'Main' of App",
            truncation: "The Accessibility tree visit stopped at the 4000-node budget."
        )
        #expect(message.hasPrefix("1 element(s) match query 'save' in window 'Main' of App so far"))
        #expect(message.contains("AXButton 'Save as…' (element_ref p1.w2:0:AXButton:fbbf52e3)"))
        #expect(message.contains("The Accessibility tree visit stopped at the 4000-node budget."))
        for hint in ["role", "window_id or title", "max_depth", "element_ref from list_elements"] {
            #expect(message.contains(hint))
        }
    }

    @Test
    func unresponsiveNoteNamesTheAppAndTheSkippedNodes() {
        #expect(DesktopElementPolicy.unresponsiveNote(appName: "Final Cut Pro", nodes: 3)
            == "Final Cut Pro is not responding to Accessibility requests; 3 node(s) could not be read.")
    }

    // MARK: set_value

    @Test
    func setValueOutcomeComparesTheReadBackWithBeforeAndRequested() {
        #expect(DesktopElementPolicy.setValueOutcome(requested: "new", before: "old", after: "new") == .applied)
        #expect(DesktopElementPolicy.setValueOutcome(requested: "", before: "old", after: nil) == .applied)
        // Unchanged from before the write: not applied.
        #expect(DesktopElementPolicy.setValueOutcome(requested: "new", before: "old", after: "old") == .notApplied)
        #expect(DesktopElementPolicy.setValueOutcome(requested: "new", before: nil, after: nil) == .notApplied)
        #expect(DesktopElementPolicy.setValueOutcome(requested: "new", before: "", after: nil) == .notApplied)
        // Different from both: the app stored something else.
        #expect(DesktopElementPolicy.setValueOutcome(requested: "1000", before: "5", after: "1,000") == .changed(readBack: "1,000"))
        #expect(DesktopElementPolicy.setValueOutcome(requested: "abc", before: "old", after: nil) == .changed(readBack: ""))
    }

    @Test
    func setValueIsReReadWithinAHalfSecondBudget() {
        #expect(DesktopElementPolicy.setValueReadBackInterval >= .milliseconds(50))
        #expect(DesktopElementPolicy.setValueReadBackInterval <= .milliseconds(100))
        #expect(DesktopElementPolicy.setValueReadBackBudget == .milliseconds(500))
    }

    @Test
    func notAppliedValueAsksToReReadBeforeTypingAgain() {
        let message = DesktopElementPolicy.valueNotAppliedMessage(element: "AXTextField 'Name' in Notes")
        #expect(message.hasPrefix("Value not applied: AXTextField 'Name' in Notes still reads back its previous value"))
        #expect(message.contains("Re-read the value with list_elements before using focus_element and type_text"))
        #expect(message.contains("not typed twice"))
    }

    @Test
    func unconfirmedValueNoteSaysItMayHaveBeenApplied() {
        let note = DesktopElementPolicy.valueUnconfirmedNote
        #expect(note.contains("did not confirm the write before the Accessibility timeout"))
        #expect(note.contains("may have been applied"))
        #expect(note.contains("re-read it"))
    }

    // MARK: Argument validation

    @Test(arguments: ["scroll", "drag", "move_mouse"])
    func pointerActionsRefuseElementSelectors(_ action: String) throws {
        try DesktopElementPolicy.validatePointerAction(action, elementRef: nil, query: nil)
        try DesktopElementPolicy.validatePointerAction(action, elementRef: "  ", query: "\n", identifier: " ")
        let selectors: [(String?, String?, String?)] = [
            ("p1.w2:0:AXButton:fbbf52e3", nil, nil), (nil, "Save", nil), ("p1.w2:0:AXButton:fbbf52e3", "Save", nil),
            (nil, nil, "save-button"), (nil, "Save", "save-button")
        ]
        for (reference, query, identifier) in selectors {
            let error = #expect(throws: DesktopControlError.self) {
                try DesktopElementPolicy.validatePointerAction(action, elementRef: reference, query: query, identifier: identifier)
            }
            let message = error?.errorDescription ?? ""
            #expect(message.hasPrefix("Invalid argument 'element_ref/query/identifier': \(action) does not target elements"))
            #expect(message.contains("coordinates"))
        }
    }

    @Test
    func elementReferenceRefusesTitleAndWindowIndex() throws {
        try DesktopElementPolicy.validateReferenceSelectors(title: nil, windowIndex: nil)
        try DesktopElementPolicy.validateReferenceSelectors(title: "  ", windowIndex: nil)
        let title = #expect(throws: DesktopControlError.self) {
            try DesktopElementPolicy.validateReferenceSelectors(title: "Project", windowIndex: nil)
        }
        #expect(title?.errorDescription?.hasPrefix("Invalid argument 'title': must be omitted with element_ref") == true)
        // window_index 0 is still a selector.
        for index in [0, 3] {
            let error = #expect(throws: DesktopControlError.self) {
                try DesktopElementPolicy.validateReferenceSelectors(title: nil, windowIndex: index)
            }
            #expect(error?.errorDescription?.hasPrefix("Invalid argument 'window_index': must be omitted with element_ref") == true)
        }
    }

    @Test
    func coveredClicksAreRetriedBrieflyBeforeBeingRefused() {
        #expect(DesktopElementPolicy.topmostAttempts == 3)
        #expect(DesktopElementPolicy.topmostRetryDelay == .milliseconds(100))
    }

    @Test
    func changedValueNoteTruncatesTheReadBack() {
        let note = DesktopElementPolicy.changedValueNote(element: "AXTextField 'Amount'", readBack: "1,000")
        #expect(note == "AXTextField 'Amount' reads back '1,000' instead of the requested text; the app may have reformatted, filtered, or truncated it.")
        let preview = DesktopElementPolicy.readBackPreview("line one\n" + String(repeating: "x", count: 200))
        #expect(preview.count == DesktopElementPolicy.maximumReadBackPreviewCharacters)
        #expect(preview.hasPrefix("line one x") && preview.hasSuffix("...") && !preview.contains("\n"))
        #expect(DesktopElementPolicy.readBackPreview("short") == "short")
    }

    @Test
    func elementInfoBoundsValuesAndHidesSecureFields() {
        let long = String(repeating: "é", count: 250)
        let info = DesktopElementPolicy.makeInfo(
            role: "AXTextArea", title: "  ", value: long, frame: CGRect(x: 10, y: 20, width: 100, height: 40),
            pid: 3, appName: "Notes", windowTitle: "Draft", hostsZen: false
        )
        #expect(info.value?.count == 200)
        #expect(info.title == nil)
        #expect(info.hosts_zen == nil)
        #expect(info.center?.x == 60 && info.center?.y == 40)
        #expect(info.frame?.width == 100)

        let secure = DesktopElementPolicy.makeInfo(role: "AXTextField", subrole: "AXSecureTextField", value: "secret", hostsZen: true)
        #expect(secure.value == nil)
        #expect(secure.hosts_zen == true)
        #expect(DesktopElementPolicy.makeInfo(role: "AXSecureTextField", value: "secret").value == nil)

        let flat = DesktopElementPolicy.makeInfo(role: "AXGroup", frame: CGRect(x: 0, y: 0, width: 0, height: 10), actions: [])
        #expect(flat.frame == nil && flat.center == nil)
        #expect(flat.actions == nil)
    }

    @Test
    func nonStringValuesAreRenderedAsText() {
        #expect(DesktopElementPolicy.textValue("text") == "text")
        #expect(DesktopElementPolicy.textValue(NSNumber(value: true)) == "true")
        #expect(DesktopElementPolicy.textValue(kCFBooleanFalse) == "false")
        #expect(DesktopElementPolicy.textValue(NSNumber(value: 1)) == "1")
        #expect(DesktopElementPolicy.textValue(NSNumber(value: 0.5)) == "0.5")
        #expect(DesktopElementPolicy.textValue(NSAttributedString(string: "styled")) == "styled")
        #expect(DesktopElementPolicy.textValue(URL(string: "https://example.com/a")!) == "https://example.com/a")
        #expect(DesktopElementPolicy.textValue(nil) == nil)
        #expect(DesktopElementPolicy.textValue([1, 2]) == nil)
    }

    @Test
    func summariesDescribeRoleLabelAppAndWindow() {
        let info = DesktopElementPolicy.makeInfo(role: "AXButton", title: "Share", appName: "Final Cut Pro", windowTitle: "Project")
        #expect(DesktopElementPolicy.describe(info) == "AXButton 'Share'")
        #expect(DesktopElementPolicy.locationPhrase(info) == "AXButton 'Share' in Final Cut Pro — window 'Project'")
        #expect(DesktopElementPolicy.locationPhrase(DesktopElementPolicy.makeInfo(role: "AXGroup")) == "AXGroup")
        let labeled = DesktopElementPolicy.makeInfo(role: "AXTextField", value: "typed", placeholder: "Name")
        #expect(DesktopElementPolicy.label(of: labeled) == "Name")
        let multiline = DesktopElementPolicy.makeInfo(role: "AXTextArea", value: "line one\nline two" + String(repeating: "x", count: 80))
        let label = DesktopElementPolicy.label(of: multiline) ?? ""
        #expect(!label.contains("\n") && label.hasSuffix("...") && label.count == 60)
    }

    @Test
    func topmostWindowIsTheFirstVisibleNormalWindowContainingThePoint() {
        let windows = [
            DesktopElementPolicy.StackedWindow(pid: 1, appName: "Overlay", bounds: CGRect(x: 0, y: 0, width: 50, height: 50), alpha: 0, layer: 0),
            // Overlays and panels above the normal layer do not cover the target.
            DesktopElementPolicy.StackedWindow(pid: 4, appName: "Window Server", bounds: CGRect(x: 0, y: 0, width: 900, height: 900), alpha: 1, layer: 25),
            DesktopElementPolicy.StackedWindow(pid: 2, appName: "Terminal", bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 1, layer: 0),
            DesktopElementPolicy.StackedWindow(pid: 3, appName: "Final Cut Pro", bounds: CGRect(x: 0, y: 0, width: 500, height: 500), alpha: 1, layer: 0)
        ]
        #expect(DesktopElementPolicy.topmostWindow(at: CGPoint(x: 10, y: 10), in: windows)?.pid == 2)
        #expect(DesktopElementPolicy.topmostWindow(at: CGPoint(x: 200, y: 200), in: windows)?.pid == 3)
        #expect(DesktopElementPolicy.topmostWindow(at: CGPoint(x: 800, y: 800), in: windows) == nil)
        #expect(DesktopElementPolicy.topmostWindow(at: CGPoint(x: 900, y: 900), in: windows) == nil)
    }

    @Test
    func coveredMessageNamesTheElementAndTheAppAtTheCenter() {
        let message = DesktopElementPolicy.coveredMessage(
            target: "AXButton 'Export' in Final Cut Pro", point: "(10.00, 20.00)",
            cover: "AXButton 'OK'", coverApp: "Finder", targetApp: "Final Cut Pro"
        )
        #expect(message.hasPrefix("The center of AXButton 'Export' in Final Cut Pro at (10.00, 20.00) is covered by AXButton 'OK' of Finder; no click was sent."))
        #expect(message.contains("Bring Final Cut Pro to the front with activate_app or focus_window"))
    }
}

@Suite
struct DesktopHostInputPolicyTests {
    private func exact(_ pid: Int32) -> DesktopHostInputPolicy.Selection { .init(pid: pid, isExact: true) }

    @Test
    func withoutAHostNothingIsRefused() {
        #expect(DesktopHostInputPolicy.decide(targetPID: 10, hostPID: nil, selection: nil) == .allow)
    }

    @Test
    func unknownOrOtherTargetsAreAllowed() {
        #expect(DesktopHostInputPolicy.decide(targetPID: nil, hostPID: 10, selection: nil) == .allow)
        #expect(DesktopHostInputPolicy.decide(targetPID: 20, hostPID: 10, selection: nil) == .allow)
        #expect(DesktopHostInputPolicy.decide(targetPID: 20, hostPID: 10, selection: exact(20)) == .allow)
        #expect(DesktopHostInputPolicy.decide(targetPID: 20, hostPID: 10, selection: exact(10)) == .allow)
        #expect(DesktopHostInputPolicy.decide(targetPID: 20, hostPID: 10, selection: .init(pid: 20, isExact: false)) == .allow)
    }

    @Test
    func hostTargetRequiresAnExactSelectionOfTheHost() {
        #expect(DesktopHostInputPolicy.decide(targetPID: 10, hostPID: 10, selection: nil) == .refuse)
        // Selecting another app that failed to take focus does not authorize the host.
        #expect(DesktopHostInputPolicy.decide(targetPID: 10, hostPID: 10, selection: exact(20)) == .refuse)
        #expect(DesktopHostInputPolicy.decide(targetPID: 10, hostPID: 10, selection: exact(10)) == .allow)
        // A partial app_name that happens to resolve to the host does not either.
        #expect(DesktopHostInputPolicy.decide(targetPID: 10, hostPID: 10, selection: .init(pid: 10, isExact: false)) == .refuseInexactSelection)
    }

    @Test
    func onlyPidBundleIDOrTheWholeNameSelectAnAppExactly() {
        func isExact(pid: Int32? = nil, bundleID: String? = nil, appName: String? = nil) -> Bool {
            DesktopHostInputPolicy.isExactSelection(
                pid: pid, bundleID: bundleID, appName: appName,
                appPID: 300, appBundleID: "com.apple.Terminal", appLocalizedName: "Terminal"
            )
        }
        #expect(isExact(pid: 300))
        #expect(!isExact(pid: 301))
        #expect(isExact(bundleID: "com.apple.Terminal"))
        #expect(isExact(bundleID: "COM.APPLE.TERMINAL"))
        #expect(!isExact(bundleID: "com.apple"))
        #expect(isExact(appName: "Terminal"))
        #expect(isExact(appName: "  terminal "))
        #expect(!isExact(appName: "Term"))
        #expect(!isExact(appName: "minal"))
        #expect(!isExact())
        #expect(!isExact(appName: "  "))
        // matchingRunningApp precedence: pid, then bundle_id, then app_name.
        #expect(!isExact(pid: 301, appName: "Terminal"))
        #expect(isExact(bundleID: "com.apple.Terminal", appName: "Term"))
    }

    @Test
    func refusalMessagesNameTheHostAndTheWayOut() {
        let typing = DesktopHostInputPolicy.refusalMessage(.typeText, appName: "Terminal")
        #expect(typing == "Refusing to type: keyboard focus is in Terminal, the application hosting this zen session, so the input would go into zen itself. Activate the target app first (activate_app, focus_window, or pass app_name/bundle_id/pid, element_ref, or query), then retry. To type into Terminal on purpose, pass its exact app_name, its bundle_id, or its pid.")
        let keys = DesktopHostInputPolicy.refusalMessage(.pressKey, appName: "iTerm2")
        #expect(keys.hasPrefix("Refusing to press keys: keyboard focus is in iTerm2"))
        #expect(keys.contains("to switch apps, use activate_app rather than a shortcut such as command+tab"))
        #expect(!keys.contains("element_ref"))
        for (kind, verb) in [(DesktopHostInputPolicy.Kind.pressElement, "press"), (.focusElement, "focus"),
                             (.setValue, "set the value of"), (.typeIntoElement, "type into"), (.clickElement, "click")] {
            let message = DesktopHostInputPolicy.refusalMessage(kind, appName: "Terminal")
            #expect(message.hasPrefix("Refusing to \(verb) the element: it belongs to Terminal, the application hosting this zen session"))
            #expect(message.contains("pass its exact app_name, its bundle_id, or its pid."))
        }
        let close = DesktopHostInputPolicy.refusalMessage(.closeWindow, appName: "Terminal")
        #expect(close.hasPrefix("Refusing to close the window: it belongs to Terminal, the application hosting this zen session"))
        #expect(close.contains("window_id from list_windows"))
        #expect(close.hasSuffix("To close a window of Terminal on purpose, pass its exact app_name, its bundle_id, or its pid."))
    }

    @Test
    func inexactSelectionAsksForTheExactNameBundleIDOrPid() {
        let message = DesktopHostInputPolicy.inexactSelectionMessage(.typeText, appName: "Terminal", selector: "term")
        #expect(message == "Refusing to type: app_name 'term' matches Terminal, the application hosting this zen session, only partially. To act on Terminal on purpose, pass its exact app_name ('Terminal'), its bundle_id, or its pid; to target another app, pass that app's exact name.")
        #expect(DesktopHostInputPolicy.inexactSelectionMessage(.pressKey, appName: "iTerm2", selector: "iterm").hasPrefix("Refusing to press keys: app_name 'iterm'"))
        #expect(DesktopHostInputPolicy.inexactSelectionMessage(.clickElement, appName: "Terminal", selector: "term").hasPrefix("Refusing to click the element:"))
        #expect(DesktopHostInputPolicy.inexactSelectionMessage(.setValue, appName: "Terminal", selector: "term").hasPrefix("Refusing to set the value of the element:"))
        #expect(DesktopHostInputPolicy.inexactSelectionMessage(.closeWindow, appName: "Terminal", selector: "term").hasPrefix("Refusing to close the window:"))
    }

    @Test
    func landingNotesDescribeWhereTheEventLanded() {
        #expect(DesktopHostInputPolicy.landingNote(.click, appName: "Terminal")
            == "The click landed on Terminal, which hosts this zen session; the intended window may be behind it. Activate the target app or use list_elements.")
        #expect(DesktopHostInputPolicy.landingNote(.scroll, appName: "Terminal").hasPrefix("The scroll landed on Terminal, which hosts this zen session"))
        #expect(DesktopHostInputPolicy.landingNote(.drag, appName: "iTerm2")
            == "The drag ended on iTerm2, which hosts this zen session; the intended window may be behind it. Activate the target app or use list_elements.")
    }

    @Test
    func hostWalkReportsTheHostProcess() {
        let parents: [pid_t: pid_t] = [500: 400, 400: 300]
        let host = DesktopHostApplication.firstApplicationAncestorProcess(
            startingAt: 500, parentOf: { parents[$0] }, applicationName: { $0 == 300 ? "Terminal" : nil }
        )
        #expect(host == DesktopHostApplication.Host(pid: 300, name: "Terminal"))
        #expect(DesktopHostApplication.firstApplicationAncestorProcess(
            startingAt: 500, parentOf: { parents[$0] }, applicationName: { _ in nil }
        ) == nil)
    }

    @Test
    func hostFallsBackToTheInheritedBundleIdentifier() {
        let terminal = DesktopHostApplication.Host(pid: 300, name: "Terminal")
        let iTerm = DesktopHostApplication.Host(pid: 310, name: "iTerm2")
        let running: [String: [DesktopHostApplication.Host]] = [
            "com.apple.Terminal": [terminal],
            "com.googlecode.iterm2": [iTerm, .init(pid: 311, name: "iTerm2")]
        ]
        var lookups: [String] = []
        let lookup: (String) -> [DesktopHostApplication.Host] = { bundleID in
            lookups.append(bundleID)
            return running[bundleID] ?? []
        }
        // The ancestor wins and the environment is not consulted.
        #expect(DesktopHostApplication.resolveHost(ancestor: iTerm, environmentBundleID: "com.apple.Terminal", regularApplications: lookup) == iTerm)
        #expect(lookups.isEmpty)
        // Without an ancestor, exactly one running regular app with the inherited id is the host.
        #expect(DesktopHostApplication.resolveHost(ancestor: nil, environmentBundleID: " com.apple.Terminal\n", regularApplications: lookup) == terminal)
        #expect(lookups == ["com.apple.Terminal"])
        // Several instances, none, or no variable leave the host unknown.
        #expect(DesktopHostApplication.resolveHost(ancestor: nil, environmentBundleID: "com.googlecode.iterm2", regularApplications: lookup) == nil)
        #expect(DesktopHostApplication.resolveHost(ancestor: nil, environmentBundleID: "com.example.Missing", regularApplications: lookup) == nil)
        #expect(DesktopHostApplication.resolveHost(ancestor: nil, environmentBundleID: nil, regularApplications: lookup) == nil)
        #expect(DesktopHostApplication.resolveHost(ancestor: nil, environmentBundleID: "  ", regularApplications: lookup) == nil)
        #expect(DesktopHostApplication.bundleIdentifierEnvironmentKey == "__CFBundleIdentifier")
    }
}

@Suite
struct DesktopKeyboardFocusPolicyTests {
    @Test
    func focusIsCheckedBeforeTheFirstCharacterAndEveryTwenty() {
        #expect(DesktopKeyboardFocusPolicy.typingCheckInterval == 20)
        let text = Array(String(repeating: "a", count: 65))
        let checked = text.indices.filter { DesktopKeyboardFocusPolicy.checksFocus(beforeCharacter: $0, character: text[$0]) }
        #expect(checked == [0, 20, 40, 60])
        #expect(!DesktopKeyboardFocusPolicy.checksFocus(beforeCharacter: -1, character: "a"))
        #expect(!DesktopKeyboardFocusPolicy.checksFocus(beforeCharacter: -1, character: "\n"))
    }

    @Test(arguments: ["\n", "\r", "\r\n", "\t"] as [Character])
    func focusIsCheckedBeforeEveryReturnAndTab(_ character: Character) {
        #expect(DesktopKeyboardFocusPolicy.isReturnOrTab(character))
        for index in [1, 7, 19, 21, 39, 41] {
            #expect(DesktopKeyboardFocusPolicy.checksFocus(beforeCharacter: index, character: character))
        }
        // Still checked on the periodic boundary and at the very start.
        #expect(DesktopKeyboardFocusPolicy.checksFocus(beforeCharacter: 0, character: character))
        #expect(DesktopKeyboardFocusPolicy.checksFocus(beforeCharacter: 20, character: character))
    }

    @Test
    func focusIsNotCheckedBeforeOrdinaryCharactersBetweenTheBoundaries() {
        for character in ["a", " ", "é", "🎬", "\u{0B}", "\u{2028}"] as [Character] {
            #expect(!DesktopKeyboardFocusPolicy.isReturnOrTab(character))
            #expect(!DesktopKeyboardFocusPolicy.checksFocus(beforeCharacter: 5, character: character))
            #expect(!DesktopKeyboardFocusPolicy.checksFocus(beforeCharacter: 19, character: character))
        }
    }

    @Test
    func aLineBreakInTheMiddleOfTheTextIsPrecededByACheck() {
        let text = Array("echo hello\nrm file\tend\r\nnext")
        let checked = text.indices.filter { DesktopKeyboardFocusPolicy.checksFocus(beforeCharacter: $0, character: text[$0]) }
        for (index, character) in text.enumerated() where DesktopKeyboardFocusPolicy.isReturnOrTab(character) {
            #expect(checked.contains(index))
        }
        #expect(checked.contains(0))
        #expect(text.filter(DesktopKeyboardFocusPolicy.isReturnOrTab).count == 3)
    }

    @Test
    func focusPhraseNamesTheElementAndTheApp() {
        #expect(DesktopKeyboardFocusPolicy.focusPhrase(appName: "Safari", element: "AXTextField 'Search'") == "AXTextField 'Search' of Safari")
        #expect(DesktopKeyboardFocusPolicy.focusPhrase(appName: "Safari", element: nil) == "Safari")
        #expect(DesktopKeyboardFocusPolicy.focusPhrase(appName: nil, element: "AXTextField") == "an application that could not be identified")
    }

    @Test
    func focusLostMessagesReportWhatWasSent() {
        let before = DesktopKeyboardFocusPolicy.focusLostMessage(input: .typing(total: 50), sent: 0, expectedApp: "Notes", focus: "Terminal")
        #expect(before.hasPrefix("Keyboard focus is no longer in Notes: it is in Terminal, so nothing was typed."))
        let during = DesktopKeyboardFocusPolicy.focusLostMessage(input: .typing(total: 50), sent: 20, expectedApp: "Notes", focus: "AXTextArea of Terminal")
        #expect(during.hasPrefix("Keyboard focus moved from Notes to AXTextArea of Terminal after 20 of 50 character(s) were typed; typing stopped."))
        let keys = DesktopKeyboardFocusPolicy.focusLostMessage(input: .keyPresses(total: 5), sent: 2, expectedApp: "Notes", focus: "Finder")
        #expect(keys.hasPrefix("Keyboard focus moved from Notes to Finder after 2 of 5 key press(es); the remaining presses were not sent."))
        let noKey = DesktopKeyboardFocusPolicy.focusLostMessage(input: .keyPresses(total: 1), sent: 0, expectedApp: "Notes", focus: "Finder")
        #expect(noKey.contains("so no key was pressed"))
        for message in [before, during, keys, noKey] {
            #expect(message.contains("activate_app, focus_window, or focus_element"))
        }
    }
}
