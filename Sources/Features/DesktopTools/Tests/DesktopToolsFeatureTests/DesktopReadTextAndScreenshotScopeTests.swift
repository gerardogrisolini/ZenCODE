import CoreGraphics
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopTextReadingTests {
    private func element(
        role: String = "AXStaticText",
        subrole: String? = nil,
        title: String? = nil,
        description: String? = nil,
        value: String? = nil,
        placeholder: String? = nil,
        ref: String? = nil,
        frame: CGRect? = nil
    ) -> DesktopElementInfo {
        var element = DesktopElementInfo(role: role)
        element.subrole = subrole
        element.title = title
        element.description = description
        element.value = value
        element.placeholder = placeholder
        element.ref = ref
        element.frame = frame.map(DesktopRect.init)
        return element
    }

    @Test
    func valuesWinOverLabelsButNeverExposeSecureValues() {
        #expect(DesktopTextReading.text(of: element(title: "Name", value: " typed text ")) == "typed text")
        #expect(DesktopTextReading.text(of: element(role: "AXSecureTextField", title: "Password", value: "secret")) == "Password")
        #expect(DesktopTextReading.text(of: element(
            role: "AXTextField", subrole: "AXSecureTextField", title: "Password", value: "secret"
        )) == "Password")
        #expect(DesktopTextReading.text(of: element(
            role: "AXSecureTextField", description: "Password", value: "secret"
        )) == "Password")
    }

    @Test
    func labelsAreDistinctAndEdgeNoiseIsRemoved() {
        let entry = element(
            title: " Title \n", description: "Title", placeholder: "Search"
        )
        #expect(DesktopTextReading.text(of: entry) == "Title | Search")
        #expect(DesktopTextReading.text(of: element(title: " \n\u{200B} ")) == nil)
        #expect(DesktopTextReading.text(of: element(value: "one\ntwo")) == "one\ntwo")
        #expect(DesktopTextReading.text(of: element(value: "\u{200E} Result \n")) == "Result")
    }

    @Test
    func emptyAndConsecutiveDuplicateTextsAreDroppedAndDetailsAreOptIn() {
        let frame = CGRect(x: 10, y: 20, width: 30, height: 40)
        let elements = [
            element(title: "First", ref: "first", frame: frame),
            element(title: "First", ref: "duplicate"),
            element(title: " \n ", ref: "empty"),
            element(value: "Second", ref: "second"),
            element(title: "First", ref: "later"),
        ]

        let compact = DesktopTextReading.entries(from: elements, includeDetails: false)
        #expect(compact.map(\.item.text) == ["First", "Second", "First"])
        #expect(compact.map(\.item.role) == ["AXStaticText", "AXStaticText", "AXStaticText"])
        #expect(compact.allSatisfy { $0.item.ref == nil && $0.item.frame == nil })

        let detailed = DesktopTextReading.entries(from: elements, includeDetails: true)
        #expect(detailed.map(\.item.ref) == ["first", "second", "later"])
        let actualFrame = detailed.first?.item.frame
        #expect(actualFrame?.x == 10)
        #expect(actualFrame?.y == 20)
        #expect(actualFrame?.width == 30)
        #expect(actualFrame?.height == 40)
    }

    @Test
    func framelessElementsStillContributeText() {
        let entries = DesktopTextReading.entries(
            from: [element(title: "Off-screen result", frame: nil)], includeDetails: true
        )
        #expect(entries.count == 1)
        #expect(entries.first?.item.text == "Off-screen result")
        #expect(entries.first?.item.frame == nil)
    }

    @Test
    func longTextsAreBoundedOnCharacterBoundariesAndReported() {
        let long = String(repeating: "a", count: 496) + "é" + String(repeating: "b", count: 10)
        let bounded = DesktopTextReading.bounded(long)
        #expect(bounded.wasTruncated)
        #expect(bounded.text.count == DesktopTextReading.maximumTextCharacters)
        #expect(bounded.text.hasSuffix("..."))
        #expect(bounded.text == String(repeating: "a", count: 496) + "é...")

        let exact = String(repeating: "x", count: DesktopTextReading.maximumTextCharacters)
        #expect(DesktopTextReading.bounded(exact).wasTruncated == false)
        #expect(DesktopTextReading.truncationNote(count: 0) == nil)
        #expect(DesktopTextReading.truncationNote(count: 2)?.contains("2 text(s)") == true)
    }

    @Test
    func textEntriesPageDeterministicallyWithinTheSizeBudget() {
        let entries = DesktopTextReading.entries(
            from: (0..<20).map { element(title: "Text \($0)") }, includeDetails: false
        )
        let page = DesktopListPaging.page(
            entries, offset: 0, limit: 20, budget: 180,
            size: { DesktopListPaging.encodedLength($0.item) }
        )
        #expect(page.entries.isEmpty == false)
        #expect(page.entries.count < entries.count)
        #expect(page.stoppedByBudget)
        #expect(page.nextOffset == page.entries.count)
        #expect(page.entries.map { DesktopListPaging.encodedLength($0.item) }.reduce(0, +) <= 180)

        let next = DesktopListPaging.page(
            Array(entries.dropFirst(page.entries.count)), offset: page.entries.count,
            limit: 20, budget: 180,
            size: { DesktopListPaging.encodedLength($0.item) }
        )
        #expect(next.entries.first?.item.text == entries[page.entries.count].item.text)
        #expect(next.entries.map(\.item.text).allSatisfy { !page.entries.map(\.item.text).contains($0) })
    }

    @Test
    func textItemEncodingMatchesTheOutputSchema() throws {
        let item = DesktopTextItem(
            role: "AXStaticText", text: "Result", ref: "p1.w2:0:AXStaticText",
            frame: DesktopRect(CGRect(x: 1, y: 2, width: 3, height: 4))
        )
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        #expect(Set(encoded.keys) == ["role", "text", "ref", "frame"])

        let outputSchema = try #require(DesktopRunTool.outputSchema)
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(outputSchema.utf8)) as? [String: Any])
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let textItem = try #require(definitions["text_item"] as? [String: Any])
        let properties = try #require(textItem["properties"] as? [String: Any])
        #expect(Set(encoded.keys) == Set(properties.keys))
        let rootProperties = try #require(schema["properties"] as? [String: Any])
        #expect(rootProperties["texts"] != nil)
    }
}

@Suite
struct DesktopScreenshotScopeTests {
    private func window(
        id: UInt32? = 1,
        pid: Int32 = 10,
        name: String? = "Editor",
        layer: Int = 0,
        onScreen: Bool = true,
        alpha: Double = 1,
        width: Double = 800,
        height: Double = 600
    ) -> DesktopWindowInfo {
        DesktopWindowInfo(
            window_id: id, pid: pid, app_name: name, bundle_id: nil, title: nil,
            bounds: DesktopRect(CGRect(x: 0, y: 0, width: width, height: height)),
            layer: layer, is_on_screen: onScreen, alpha: alpha, is_fullscreen: nil
        )
    }

    private func validationError(_ arguments: DesktopScreenshotScope.Arguments) -> String? {
        do {
            try DesktopScreenshotScope.validate(arguments, action: "screenshot")
            return nil
        } catch let error as DesktopControlError {
            return error.errorDescription
        } catch {
            return String(describing: error)
        }
    }

    @Test
    func omittedScopeFollowsTheSelectorPrecedenceAndExplainsTheChoice() {
        let noWindows: () -> [DesktopWindowInfo] = { [] }
        let cases: [(DesktopScreenshotScope.Arguments, String, String)] = [
            (.init(hasElementSelectors: true, hasRegion: true, hasDisplayIndex: true), "element", "element"),
            (.init(hasRegion: true, hasDisplayIndex: true, hasWindowSelectors: true), "region", "x, y, width, or height"),
            (.init(hasDisplayIndex: true, hasWindowSelectors: true), "display", "display_index"),
            (.init(hasWindowSelectors: true), "window", "window or app selector"),
            (.init(hasAppSelectors: true), "window", "window or app selector"),
        ]
        for (arguments, expectedScope, noteFragment) in cases {
            let decision = DesktopScreenshotScope.decide(arguments, windows: noWindows, hostPID: 99)
            #expect(decision.scope == expectedScope)
            #expect(decision.note?.contains(noteFragment) == true)
            #expect(decision.selectedByArguments == (expectedScope == "window"))
        }

        let explicit = DesktopScreenshotScope.decide(.init(scope: "display"), windows: noWindows, hostPID: nil)
        #expect(explicit.scope == "display" && explicit.note == nil)
    }

    @Test
    func defaultWindowIsTopmostEligibleAndNeverBelongsToTheHost() {
        let eligible = window(id: 7, pid: 20, name: "Editor")
        let windows = [
            window(id: 1, pid: 99, name: "Terminal"),
            window(id: 2, pid: 20, layer: 1),
            window(id: 3, pid: 20, onScreen: false),
            window(id: 4, pid: 20, alpha: 0),
            window(id: 5, pid: 20, width: 99, height: 600),
            eligible,
            window(id: 8, pid: 30, name: "Browser"),
        ]
        let decision = DesktopScreenshotScope.decide(.init(), windows: { windows }, hostPID: 99, hostName: "Terminal")
        #expect(decision.scope == "window")
        #expect(decision.window?.window_id == eligible.window_id)
        #expect(decision.note?.contains("frontmost window of Editor") == true)
        #expect(DesktopScreenshotScope.frontmostWindow(in: windows, hostPID: nil)?.window_id == 1)
    }

    @Test
    func displayIsTheFallbackWhenNoEligibleWindowExists() {
        let windows = [window(pid: 99), window(id: nil, pid: 20), window(pid: 20, width: 20, height: 20)]
        let decision = DesktopScreenshotScope.decide(.init(), windows: { windows }, hostPID: 99, hostName: "Terminal")
        #expect(decision.scope == "display")
        #expect(decision.window == nil)
        #expect(decision.note?.contains("no visible window of at least 100x100 points outside Terminal") == true)
    }

    @Test
    func elementCapturesRefuseContradictoryArguments() {
        #expect(validationError(.init(scope: "element"))?.contains("requires argument 'element_ref, query, or identifier'") == true)
        #expect(validationError(.init(hasElementSelectors: true, hasRegion: true))?.contains("x/y/width/height") == true)
        #expect(validationError(.init(hasElementSelectors: true, hasDisplayIndex: true))?.contains("display_index") == true)
        #expect(validationError(.init(scope: "window", hasElementSelectors: true))?.contains("must be element") == true)
        #expect(validationError(.init(scope: "element", hasElementSelectors: true, hasWindowSelectors: true)) == nil)
    }

    @Test
    func scopeArgumentsComeFromTheDecodedInput() throws {
        let input = try JSONDecoder().decode(DesktopRunInput.self, from: Data(
            #"{"action":"screenshot","identifier":"result","window_index":2}"#.utf8
        ))
        let arguments = DesktopScreenshotScope.Arguments(input)
        #expect(arguments.hasElementSelectors)
        #expect(arguments.hasWindowSelectors)
        #expect(!arguments.hasRegion && !arguments.hasDisplayIndex && !arguments.hasAppSelectors)
    }
}

@Suite
struct DesktopElementCaptureGeometryTests {
    private let displays = [
        CGRect(x: 0, y: 0, width: 1000, height: 800),
        CGRect(x: 1000, y: 0, width: 800, height: 600),
    ]

    @Test
    func elementFrameIsRoundedOutwardAndClippedToItsLargestDisplayOverlap() {
        let region = DesktopScreenshotGeometry.elementRegion(
            frame: CGRect(x: 900.2, y: 100.8, width: 300.2, height: 100.2), displays: displays
        )
        #expect(region == .region(
            CGRect(x: 1000, y: 100, width: 201, height: 101), displayIndex: 1, isClipped: true
        ))

        let contained = DesktopScreenshotGeometry.elementRegion(
            frame: CGRect(x: 10.2, y: 20.2, width: 30.2, height: 40.2), displays: displays
        )
        #expect(contained == .region(CGRect(x: 10, y: 20, width: 31, height: 41), displayIndex: 0, isClipped: false))
    }

    @Test
    func missingEmptyAndOffscreenFramesAreDistinguished() {
        #expect(DesktopScreenshotGeometry.elementRegion(frame: nil, displays: displays) == .noFrame)
        #expect(DesktopScreenshotGeometry.elementRegion(frame: .zero, displays: displays) == .noFrame)
        #expect(DesktopScreenshotGeometry.elementRegion(
            frame: CGRect(x: 3000, y: 0, width: 100, height: 100), displays: displays
        ) == .offScreen)
    }

    @Test
    func elementSummariesDistinguishScreenshotFromZoom() {
        let screenshot = DesktopCaptureText.summary(
            scope: "element", dimensions: (100, 50), pointsPerPixel: 1,
            path: "/tmp/element.png", element: "AXButton 'Save'", zoomed: false
        )
        let zoom = DesktopCaptureText.summary(
            scope: "element", dimensions: (200, 100), pointsPerPixel: 0.5,
            path: "/tmp/element.png", element: "AXButton 'Save'", zoomed: true
        )
        #expect(screenshot.contains("a screenshot of the element AXButton 'Save'"))
        #expect(zoom.contains("a zoom of the element AXButton 'Save'"))
        #expect(DesktopCaptureText.note(mapped: true, clipped: false, elementClipped: true).contains("visible part") == true)
    }
}
