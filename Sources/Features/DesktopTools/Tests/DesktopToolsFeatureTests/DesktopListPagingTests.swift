import AppKit
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopListPagingTests {
    private func paged(
        _ entries: [Int],
        offset: Int = 0,
        limit: Int,
        more: Bool = false,
        budget: Int = 8_000,
        size: (Int) -> Int = { _ in 10 }
    ) -> DesktopListPaging.Page<Int> {
        DesktopListPaging.page(entries, offset: offset, limit: limit, moreAvailable: more, budget: budget, size: size)
    }

    // MARK: limit and next_offset

    @Test
    func pageStopsAtLimitAndPointsToTheNextEntry() {
        let page = paged(Array(0..<10), limit: 4)
        #expect(page.entries == [0, 1, 2, 3])
        #expect(page.nextOffset == 4)
        #expect(!page.stoppedByBudget)
    }

    @Test
    func pageOmitsNextOffsetAtTheEndOfTheList() {
        #expect(paged(Array(0..<3), limit: 5).nextOffset == nil)
        // Exactly `limit` entries and nothing after them: nothing remains.
        let exact = paged(Array(0..<5), limit: 5)
        #expect(exact.entries.count == 5 && exact.nextOffset == nil)
        #expect(paged([], limit: 5).entries.isEmpty)
        #expect(paged([], limit: 5).nextOffset == nil)
    }

    @Test
    func nextOffsetContinuesFromTheOffsetOfThePage() {
        let page = paged(Array(5..<12), offset: 5, limit: 3)
        #expect(page.entries == [5, 6, 7])
        #expect(page.offset == 5)
        #expect(page.nextOffset == 8)
    }

    @Test
    func moreAvailableKeepsTheListOpenWhenTheCallerDidNotGatherTheRest() {
        let open = paged(Array(0..<3), offset: 10, limit: 5, more: true)
        #expect(open.entries == [0, 1, 2])
        #expect(open.nextOffset == 13)
        #expect(paged(Array(0..<3), offset: 10, limit: 5, more: false).nextOffset == nil)
    }

    @Test
    func offsetPagesTileTheListWithoutOverlapOrGaps() {
        let list = Array(0..<23)
        var collected: [Int] = []
        var offset = 0
        var pages = 0
        while true {
            let page = paged(Array(list.dropFirst(offset).prefix(8)), offset: offset, limit: 7, more: list.count > offset + 7)
            collected += page.entries
            pages += 1
            guard let next = page.nextOffset else { break }
            #expect(next == offset + page.entries.count)
            offset = next
        }
        #expect(collected == list)
        #expect(pages == 4)
    }

    @Test
    func pagingIsDeterministic() {
        let entries = Array(0..<30)
        let first = paged(entries, offset: 4, limit: 9, size: { 100 + $0 })
        let second = paged(entries, offset: 4, limit: 9, size: { 100 + $0 })
        #expect(first.entries == second.entries)
        #expect(first.nextOffset == second.nextOffset)
    }

    // MARK: size budget

    @Test
    func budgetCutsThePageBeforeLimitAndPointsToTheNextEntry() {
        let page = paged(Array(0..<10), offset: 20, limit: 10, budget: 8_000, size: { _ in 3_000 })
        #expect(page.entries == [0, 1])
        #expect(page.stoppedByBudget)
        #expect(page.nextOffset == 22)
    }

    @Test
    func theSumOfTheEntriesMayReachTheBudgetExactly() {
        let page = paged(Array(0..<3), limit: 10, budget: 8_000, size: { _ in 4_000 })
        #expect(page.entries == [0, 1])
        #expect(page.nextOffset == 2)
        let fits = paged(Array(0..<2), limit: 10, budget: 8_000, size: { _ in 4_000 })
        #expect(fits.entries == [0, 1])
        #expect(fits.nextOffset == nil && !fits.stoppedByBudget)
    }

    @Test
    func theFirstEntryIsReturnedEvenWhenItExceedsTheBudget() {
        let page = paged(Array(0..<4), offset: 3, limit: 10, budget: 8_000, size: { _ in 20_000 })
        #expect(page.entries == [0])
        #expect(page.stoppedByBudget)
        #expect(page.nextOffset == 4)
        let alone = paged([9], limit: 10, budget: 8_000, size: { _ in 20_000 })
        #expect(alone.entries == [9] && alone.nextOffset == nil)
    }

    @Test
    func budgetPagesTileTheListAndEachStaysWithinTheBudget() {
        let sizes = [900, 1200, 300, 2500, 4000, 100, 7000, 50, 50, 3000, 3000, 3000, 8100, 10, 10]
        var collected: [Int] = []
        var offset = 0
        while offset < sizes.count {
            let remaining = Array(sizes.indices.dropFirst(offset))
            let page = paged(remaining, offset: offset, limit: 200, size: { sizes[$0] })
            let total = page.entries.map { sizes[$0] }.reduce(0, +)
            #expect(total <= 8_000 || page.entries.count == 1)
            #expect(!page.entries.isEmpty)
            collected += page.entries
            guard let next = page.nextOffset else { break }
            offset = next
        }
        #expect(collected == Array(sizes.indices))
    }

    @Test
    func theBudgetIsEightThousandCharactersUnderTheRuntimeLimit() {
        #expect(DesktopSafetyPolicy.maximumListPayloadCharacters == 8_000)
        #expect(DesktopSafetyPolicy.maximumListPayloadCharacters < 12_000)
        #expect(DesktopSafetyPolicy.maximumListOffset == 5_000)
    }

    @Test
    func accessibilityAttributesCannotDefeatTheResponseBudget() {
        let long = String(repeating: "\u{1}", count: 20_000)
        let info = DesktopElementPolicy.makeInfo(
            role: "AXStaticText", subrole: long, roleDescription: long,
            title: long, description: long, value: long, placeholder: long,
            identifier: long, appName: long, windowTitle: long
        )
        // Bounding is output-only: the integral AX attributes remain available
        // to fingerprints and relocation, including escape-heavy text.
        #expect(info.title?.count == 20_000)
        #expect(info.description?.count == 20_000)
        #expect(info.placeholder?.count == 20_000)
        for includeDetails in [false, true] {
            let projected = DesktopElementPolicy.projected(info, includeDetails: includeDetails)
            #expect(DesktopListPaging.encodedLength(projected) <= DesktopElementPolicy.maximumProjectedElementCharacters)
        }
    }

    @Test
    func longAttributeSuffixesStillProduceDistinctFingerprints() {
        let prefix = String(repeating: "a", count: 1_000)
        let first = DesktopElementPolicy.makeInfo(role: "AXButton", title: prefix + "A")
        let second = DesktopElementPolicy.makeInfo(role: "AXButton", title: prefix + "B")
        #expect(DesktopElementReference.fingerprint(of: first) != DesktopElementReference.fingerprint(of: second))
        _ = DesktopElementPolicy.projected(first, includeDetails: true)
        #expect(first.title == prefix + "A")
    }

    // MARK: encoded size

    private struct Sample: Encodable {
        let path: String
    }

    @Test
    func encodedLengthUsesTheOutputEncoder() {
        // Sorted keys and unescaped slashes, in characters rather than bytes.
        #expect(DesktopListPaging.encodedLength(Sample(path: "a/b")) == 14)
        #expect(DesktopListPaging.encodedLength(Sample(path: "è")) == 12)
    }

    @Test
    func encodablePagesAreMeasuredAsJSON() {
        let app = { (index: Int) in
            DesktopAppInfo(
                pid: Int32(index), name: "App \(index)", bundle_id: "com.example.app\(index)",
                bundle_path: "/Applications/" + String(repeating: "Long Name ", count: 12) + "\(index).app",
                activation_policy: "regular", is_active: false, is_hidden: false, is_terminated: false
            )
        }
        let apps = (0..<100).map(app)
        let each = DesktopListPaging.encodedLength(apps[0])
        #expect(each > 200)
        let page = DesktopListPaging.page(apps, offset: 0, limit: 100)
        let total = page.entries.map(DesktopListPaging.encodedLength).reduce(0, +)
        #expect(total <= DesktopSafetyPolicy.maximumListPayloadCharacters)
        #expect(page.entries.count < 100 && page.entries.count >= 1)
        #expect(page.stoppedByBudget)
        #expect(page.nextOffset == page.entries.count)
        #expect(page.entries.map(\.pid) == Array(0..<Int32(page.entries.count)))
    }

    // MARK: notes and summary

    @Test
    func theLimitNoteSuggestsTheNextOffset() {
        let page = paged(Array(0..<10), offset: 100, limit: 4)
        let note = DesktopListPaging.note(page, limit: 4, noun: "elements", narrowedBy: "query or role")
        #expect(note == "Stopped at limit 4; more elements exist. Continue with offset=104, or narrow the list with query or role.")
    }

    @Test
    func theBudgetNoteCountsTheEntriesAndSuggestsTheNextOffset() {
        let page = paged(Array(0..<10), offset: 20, limit: 10, size: { _ in 3_000 })
        #expect(DesktopListPaging.note(page, limit: 10, noun: "windows", narrowedBy: "title")
            == "Stopped at the response size budget after 2 entries; continue with offset=22.")
        let single = paged(Array(0..<4), limit: 10, size: { _ in 20_000 })
        #expect(DesktopListPaging.note(single, limit: 10, noun: "windows", narrowedBy: "title")
            == "Stopped at the response size budget after 1 entry; continue with offset=1.")
    }

    @Test
    func thereIsNoNoteAtTheEndOfTheListButOneForAnOffsetPastIt() {
        #expect(DesktopListPaging.note(paged(Array(0..<3), limit: 10), limit: 10, noun: "apps", narrowedBy: "query") == nil)
        let past = paged([], offset: 40, limit: 10)
        #expect(DesktopListPaging.note(past, limit: 10, noun: "applications", narrowedBy: "query")
            == "No applications at offset=40; the list ends before it. Use a lower offset.")
        #expect(DesktopListPaging.note(paged([], limit: 10), limit: 10, noun: "applications", narrowedBy: "query") == nil)
    }

    @Test
    func summaryNamesTheCountTheOffsetTheScopeAndTheNextOffset() {
        #expect(DesktopListPaging.summary(noun: "element(s)", count: 12, offset: 0, nextOffset: nil, scope: "window 'Main' of Calculator")
            == "Listed 12 element(s) in window 'Main' of Calculator.")
        #expect(DesktopListPaging.summary(noun: "element(s)", count: 12, offset: 24, nextOffset: 36, scope: "window 'Main' of Calculator")
            == "Listed 12 element(s) from offset 24 in window 'Main' of Calculator; more remain (next_offset=36).")
        #expect(DesktopListPaging.summary(noun: "running application(s)", count: 3, offset: 0, nextOffset: nil)
            == "Listed 3 running application(s).")
    }

    @Test
    func windowSummaryNamesTheOffsetAndTheNextOffset() {
        let text = DesktopWindowListing.text(
            windows: [], frontmostAppName: "Calculator", hostAppName: nil, screenRecordingGranted: true,
            offset: 5, nextOffset: 5
        )
        #expect(text.summary == "Listed 0 window(s) from offset 5 in front-to-back order. Frontmost app: Calculator. More windows remain (next_offset=5).")
        let first = DesktopWindowListing.text(
            windows: [], frontmostAppName: nil, hostAppName: nil, screenRecordingGranted: true
        )
        #expect(first.summary == "Listed 0 window(s) in front-to-back order.")
    }

    @Test
    func notesAreJoinedSkippingTheEmptyOnes() {
        #expect(DesktopListPaging.joined([nil, "A.", "", "B."]) == "A. B.")
        #expect(DesktopListPaging.joined([nil, nil]) == nil)
    }

    // MARK: validation

    @Test
    func limitAndOffsetDefaultTo100And0() throws {
        let defaults = try DesktopListPaging.validated(limit: nil, offset: nil)
        #expect(defaults.limit == 100 && defaults.offset == 0)
        let bounds = try DesktopListPaging.validated(limit: 200, offset: 5_000)
        #expect(bounds.limit == 200 && bounds.offset == 5_000)
        let low = try DesktopListPaging.validated(limit: 1, offset: 0)
        #expect(low.limit == 1 && low.offset == 0)
    }

    @Test(arguments: [(0, 0), (201, 0), (-1, 0), (10, -1), (10, 5_001)])
    func outOfRangeLimitAndOffsetAreRejected(limit: Int, offset: Int) {
        #expect(throws: DesktopControlError.self) {
            try DesktopListPaging.validated(limit: limit, offset: offset)
        }
    }

    @Test
    func theErrorNamesTheArgumentAndItsRange() {
        do {
            _ = try DesktopListPaging.validated(limit: 10, offset: 5_001)
            Issue.record("offset 5001 was accepted")
        } catch {
            #expect(error.localizedDescription == "Invalid argument 'offset': must be between 0 and 5000.")
        }
        do {
            _ = try DesktopListPaging.validated(limit: 0, offset: nil)
            Issue.record("limit 0 was accepted")
        } catch {
            #expect(error.localizedDescription == "Invalid argument 'limit': must be between 1 and 200.")
        }
    }
}

@Suite
struct DesktopAppListingTests {
    private func listed(
        _ policy: String = "regular", name: String? = "Calculator", bundleID: String? = "com.apple.calculator",
        background: Bool = false, query: String? = nil
    ) -> Bool {
        DesktopAppListing.isListed(
            activationPolicy: policy, name: name, bundleID: bundleID, includeBackground: background, query: query
        )
    }

    @Test
    func onlyRegularAppsAreListedByDefault() {
        #expect(listed("regular"))
        #expect(!listed("accessory"))
        #expect(!listed("prohibited"))
        #expect(!listed("unknown"))
    }

    @Test
    func includeBackgroundAddsAccessoryAndProhibitedApps() {
        #expect(listed("regular", background: true))
        #expect(listed("accessory", background: true))
        #expect(listed("prohibited", background: true))
    }

    @Test
    func queryMatchesTheNameOrTheBundleIdentifierIgnoringCaseAndDiacritics() {
        #expect(listed(query: "calc"))
        #expect(listed(query: "CALCULATOR"))
        #expect(listed(query: "apple.CALC"))
        #expect(!listed(query: "safari"))
        #expect(listed(name: "Café Écran", bundleID: nil, query: "cafe ecran"))
        #expect(listed(name: "cafe", bundleID: nil, query: "CAFÉ"))
        #expect(listed(name: nil, bundleID: "com.example.tool", query: "example"))
        #expect(!listed(name: nil, bundleID: nil, query: "x"))
        #expect(listed(query: nil))
    }

    @Test
    func queryAndPolicyBothApply() {
        #expect(!listed("accessory", background: false, query: "calc"))
        #expect(listed("accessory", background: true, query: "calc"))
        #expect(!listed("accessory", background: true, query: "safari"))
        #expect(!listed("regular", background: true, query: "safari"))
    }

    @Test
    func activationPolicyNamesMatchTheAppInfoValues() {
        #expect(DesktopAppListing.activationPolicyName(.regular) == "regular")
        #expect(DesktopAppListing.activationPolicyName(.accessory) == "accessory")
        #expect(DesktopAppListing.activationPolicyName(.prohibited) == "prohibited")
    }

    @Test
    func theHiddenBackgroundNoteAppearsOnlyWhenSomeAppIsHidden() {
        #expect(DesktopAppListing.hiddenBackgroundNote(hidden: 0) == nil)
        let note = DesktopAppListing.hiddenBackgroundNote(hidden: 2)
        #expect(note?.contains("2 matching background application(s)") == true)
        #expect(note?.contains("include_background=true") == true)
    }
}

@Suite
struct DesktopListSchemaTests {
    private func object(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func inputProperties() throws -> [String: Any] {
        try #require(try object(DesktopRunTool.inputSchema)["properties"] as? [String: Any])
    }

    @Test
    func offsetIsABoundedInteger() throws {
        let offset = try #require(try inputProperties()["offset"] as? [String: Any])
        #expect(offset["type"] as? String == "integer")
        #expect(offset["minimum"] as? Int == 0)
        #expect(offset["maximum"] as? Int == DesktopSafetyPolicy.maximumListOffset)
        let description = try #require(offset["description"] as? String)
        #expect(description.contains("next_offset"))
    }

    @Test
    func limitKeepsItsBoundsAndDescribesTheSizeBudget() throws {
        let limit = try #require(try inputProperties()["limit"] as? [String: Any])
        #expect(limit["minimum"] as? Int == 1)
        #expect(limit["maximum"] as? Int == 200)
        let description = try #require(limit["description"] as? String)
        #expect(description.contains("next_offset"))
        #expect(description.contains("8000 characters"))
        #expect(description.contains("list_apps, list_windows, list_elements, and read_text"))
    }

    @Test
    func includeFlagsAreBooleans() throws {
        let properties = try inputProperties()
        for name in ["include_background", "include_details"] {
            let property = try #require(properties[name] as? [String: Any])
            #expect(property["type"] as? String == "boolean", "\(name)")
            #expect((property["description"] as? String)?.isEmpty == false, "\(name)")
        }
        let background = try #require((properties["include_background"] as? [String: Any])?["description"] as? String)
        #expect(background.contains("accessory and prohibited"))
        let details = try #require((properties["include_details"] as? [String: Any])?["description"] as? String)
        #expect(details.contains("compact"))
    }

    @Test
    func queryDescriptionCoversListApps() throws {
        let query = try #require((try inputProperties()["query"] as? [String: Any])?["description"] as? String)
        #expect(query.contains("list_apps"))
        #expect(query.contains("bundle_id"))
        #expect(query.contains("Filters list_elements"))
    }

    @Test
    func outputSchemaDeclaresNextOffsetAndTheElementLabel() throws {
        let root = try object(try #require(DesktopRunTool.outputSchema))
        let properties = try #require(root["properties"] as? [String: Any])
        let next = try #require(properties["next_offset"] as? [String: Any])
        #expect(next["type"] as? String == "integer")
        #expect(next["minimum"] as? Int == 0)
        let required = try #require(root["required"] as? [String])
        #expect(!required.contains("next_offset"))
        let defs = try #require(root["$defs"] as? [String: Any])
        let element = try #require(defs["element"] as? [String: Any])
        let label = try #require((element["properties"] as? [String: Any])?["label"] as? [String: Any])
        #expect(label["type"] as? String == "string")
        #expect(element["required"] as? [String] == ["role"])
    }

    @Test
    func theToolDescriptionExplainsPagingAndTheCompactForm() {
        let description = DesktopRunTool.description
        for fragment in ["next_offset", "offset", "include_background", "include_details", "8000 characters", "Dock icon"] {
            #expect(description.contains(fragment), "\(fragment)")
        }
    }

    @Test
    func theActionDescriptionListsTheCompactFields() throws {
        let action = try #require(try inputProperties()["action"] as? [String: Any])
        let description = try #require(action["description"] as? String)
        for fragment in ["AXPress, AXConfirm, AXPick, AXIncrement, AXDecrement, AXShowMenu, and AXCancel", "enabled only when false", "focused only when true", "next_offset"] {
            #expect(description.contains(fragment), "\(fragment)")
        }
    }
}
