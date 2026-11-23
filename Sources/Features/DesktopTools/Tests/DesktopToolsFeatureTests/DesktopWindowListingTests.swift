import ApplicationServices
import CoreGraphics
import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopWindowListingTests {
    private func window(
        id: UInt32,
        app: String? = "Final Cut Pro",
        title: String? = nil,
        frame: CGRect = CGRect(x: 10, y: 20, width: 800, height: 600),
        onScreen: Bool = true,
        host: Bool = false,
        frontmost: Bool = false
    ) -> DesktopWindowInfo {
        DesktopWindowInfo(
            window_id: id, pid: 100 + Int32(id), app_name: app, bundle_id: nil, title: title,
            bounds: DesktopRect(frame), layer: 0, is_on_screen: onScreen, alpha: 1,
            is_focused: nil, is_minimized: nil, is_fullscreen: nil,
            is_frontmost_app: frontmost ? true : nil, hosts_zen: host ? true : nil
        )
    }

    private func identity(_ title: String?, _ x: Double, _ y: Double = 0, _ width: Double = 100, _ height: Double = 100)
        -> DesktopSafetyPolicy.WindowIdentity {
        .init(title: title, frame: CGRect(x: x, y: y, width: width, height: height))
    }

    private func outputSchemaObject() throws -> [String: Any] {
        let schema = try #require(DesktopRunTool.outputSchema)
        return try #require(try JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
    }

    private func json(_ info: DesktopWindowInfo) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])
    }

    // MARK: Summary and note

    @Test
    func summaryNamesFrontmostAppWithoutOffScreenWindows() {
        let text = DesktopWindowListing.text(
            windows: [window(id: 1), window(id: 2)],
            frontmostAppName: "Final Cut Pro", hostAppName: "Terminal", screenRecordingGranted: true
        )
        #expect(text.summary == "Listed 2 window(s) in front-to-back order. Frontmost app: Final Cut Pro.")
        #expect(text.note == nil)
    }

    @Test
    func summaryCountsOffScreenWindows() {
        let text = DesktopWindowListing.text(
            windows: [window(id: 1), window(id: 2, onScreen: false), window(id: 3, onScreen: false)],
            frontmostAppName: "Final Cut Pro", hostAppName: nil, screenRecordingGranted: true
        )
        #expect(text.summary == "Listed 3 window(s) in front-to-back order. Frontmost app: Final Cut Pro. "
            + "2 of them are not on screen (minimized, hidden, or on another Space).")
        #expect(text.note == nil)
    }

    @Test
    func summaryWithoutFrontmostApp() {
        let text = DesktopWindowListing.text(
            windows: [window(id: 1, onScreen: false)],
            frontmostAppName: nil, hostAppName: nil, screenRecordingGranted: true
        )
        #expect(text.summary == "Listed 1 window(s) in front-to-back order. "
            + "1 of them are not on screen (minimized, hidden, or on another Space).")
        for blank in ["", "  \n"] {
            let blankText = DesktopWindowListing.text(
                windows: [], frontmostAppName: blank, hostAppName: nil, screenRecordingGranted: true
            )
            #expect(blankText.summary == "Listed 0 window(s) in front-to-back order.")
        }
    }

    @Test
    func noteExplainsHostWindows() {
        let text = DesktopWindowListing.text(
            windows: [window(id: 1, app: "Terminal", host: true, frontmost: true), window(id: 2)],
            frontmostAppName: "Terminal", hostAppName: "Terminal", screenRecordingGranted: true
        )
        #expect(text.summary == "Listed 2 window(s) in front-to-back order. Frontmost app: Terminal.")
        #expect(text.note == "Windows marked hosts_zen belong to Terminal, which runs this zen session; they are not the app to control.")
    }

    @Test
    func hostNoteFallsBackToTheHostNameThenToAGenericPhrase() {
        let unnamed = window(id: 1, app: nil, host: true)
        let named = DesktopWindowListing.text(
            windows: [unnamed], frontmostAppName: nil, hostAppName: "iTerm2", screenRecordingGranted: true
        )
        #expect(named.note?.contains("belong to iTerm2, which runs this zen session") == true)
        let generic = DesktopWindowListing.text(
            windows: [unnamed], frontmostAppName: nil, hostAppName: nil, screenRecordingGranted: true
        )
        #expect(generic.note?.contains("belong to the app that launched zen, which runs this zen session") == true)
    }

    @Test
    func noHostNoteWithoutHostWindows() {
        let text = DesktopWindowListing.text(
            windows: [window(id: 1)], frontmostAppName: "Terminal", hostAppName: "Terminal", screenRecordingGranted: true
        )
        #expect(text.note == nil)
    }

    @Test
    func screenRecordingNoteIsKeptAndMergedWithTheHostNote() {
        let only = DesktopWindowListing.text(
            windows: [window(id: 1)], frontmostAppName: nil, hostAppName: nil, screenRecordingGranted: false
        )
        #expect(only.note == "Without Screen Recording permission, some window titles may be unavailable.")
        let merged = DesktopWindowListing.text(
            windows: [window(id: 1, app: "Terminal", host: true)],
            frontmostAppName: nil, hostAppName: "Terminal", screenRecordingGranted: false
        )
        #expect(merged.note == "Windows marked hosts_zen belong to Terminal, which runs this zen session; they are not the app to control. "
            + "Without Screen Recording permission, some window titles may be unavailable.")
    }

    @Test
    func accessibilityTimeoutAddsANote() {
        let timedOut = DesktopWindowListing.text(
            windows: [window(id: 1)], frontmostAppName: nil, hostAppName: nil,
            screenRecordingGranted: true, accessibilityTimedOut: true
        )
        #expect(DesktopWindowListing.accessibilityBudget == 3)
        #expect(timedOut.note == "Some apps did not answer Accessibility requests within the 3-second budget, so subrole, is_main, is_focused, and is_minimized are missing for some windows.")
        let both = DesktopWindowListing.text(
            windows: [window(id: 1)], frontmostAppName: nil, hostAppName: nil,
            screenRecordingGranted: false, accessibilityTimedOut: true
        )
        #expect(both.note == DesktopWindowListing.screenRecordingNote + " " + DesktopWindowListing.accessibilityTimeoutNote)
        #expect(DesktopWindowListing.text(
            windows: [window(id: 1)], frontmostAppName: nil, hostAppName: nil, screenRecordingGranted: true
        ).note == nil)
    }

    // MARK: Pairing

    @Test
    func pairingMatchesUniqueWindowsByTitleAndFrame() {
        let quartz = [identity("A", 0), identity("B", 200)]
        let ax = [identity("B", 200), identity("A", 0)]
        #expect(DesktopWindowListing.pairing(quartz: quartz, ax: ax) == [1, 0])
    }

    @Test
    func pairingToleratesTwoPointsAndUsesFrameWhenQuartzHasNoTitle() {
        let quartz = [identity(nil, 0), identity(nil, 300)]
        let ax = [identity("One", 1.5), identity("Two", 300)]
        #expect(DesktopWindowListing.pairing(quartz: quartz, ax: ax) == [0, 1])
    }

    @Test
    func pairingLeavesNilWhenThereIsNoCounterpart() {
        let quartz = [identity("A", 0), identity("Elsewhere", 500)]
        let ax = [identity("A", 0)]
        #expect(DesktopWindowListing.pairing(quartz: quartz, ax: ax) == [0, nil])
        #expect(DesktopWindowListing.pairing(quartz: quartz, ax: []) == [nil, nil])
        // An AX window without a usable frame never matches.
        let noFrame = [DesktopSafetyPolicy.WindowIdentity(title: "A", frame: nil)]
        #expect(DesktopWindowListing.pairing(quartz: quartz, ax: noFrame) == [nil, nil])
    }

    @Test
    func pairingRejectsDuplicateAXWindows() {
        let quartz = [identity("A", 0)]
        let ax = [identity("A", 0), identity("A", 1)]
        #expect(DesktopWindowListing.pairing(quartz: quartz, ax: ax) == [nil])
    }

    @Test
    func pairingRejectsDuplicateQuartzWindows() {
        // Two indistinguishable Quartz windows would otherwise share one AX window.
        let quartz = [identity("A", 0), identity("A", 0), identity("B", 400)]
        let ax = [identity("A", 0), identity("B", 400)]
        #expect(DesktopWindowListing.pairing(quartz: quartz, ax: ax) == [nil, nil, 1])
    }

    // MARK: Applying AX attributes

    @Test
    func applyingAddsAccessibilityAttributes() throws {
        let base = window(id: 7, title: "Export", frontmost: true)
        let enriched = DesktopWindowListing.applying(
            .init(subrole: "AXDialog", isMain: false, isFocused: true, isMinimized: false), to: base
        )
        #expect(enriched.subrole == "AXDialog")
        #expect(enriched.is_main == false)
        #expect(enriched.is_focused == true)
        #expect(enriched.is_minimized == false)
        #expect(enriched.window_id == 7)
        #expect(enriched.is_frontmost_app == true)
        let encoded = try json(enriched)
        #expect(encoded["subrole"] as? String == "AXDialog")
        #expect(encoded["is_main"] as? Bool == false)
    }

    @Test
    func applyingKeepsExistingValuesForUnknownAttributes() {
        var base = window(id: 7)
        base.is_minimized = false
        let enriched = DesktopWindowListing.applying(.init(subrole: "  ", isMain: nil, isFocused: nil, isMinimized: nil), to: base)
        #expect(enriched.subrole == nil)
        #expect(enriched.is_main == nil)
        #expect(enriched.is_focused == nil)
        #expect(enriched.is_minimized == false)
    }

    // MARK: Decoding AX window attributes

    @Test @MainActor
    func axWindowSnapshotDecodesTheBatchedAttributes() {
        #expect(DesktopController.windowSnapshotAttributes == [
            kAXTitleAttribute, kAXPositionAttribute, kAXSizeAttribute,
            kAXSubroleAttribute, kAXMainAttribute, kAXFocusedAttribute, kAXMinimizedAttribute
        ])
        var origin = CGPoint(x: 12, y: 34)
        var extent = CGSize(width: 560, height: 420)
        let values: [AnyObject?] = [
            "Export" as NSString,
            AXValueCreate(.cgPoint, &origin),
            AXValueCreate(.cgSize, &extent),
            "AXDialog" as NSString,
            NSNumber(value: false),
            NSNumber(value: true),
            NSNumber(value: false)
        ]
        let snapshot = DesktopController.axWindowSnapshot(values: values)
        #expect(snapshot.identity.title == "Export")
        #expect(snapshot.identity.frame == CGRect(x: 12, y: 34, width: 560, height: 420))
        #expect(snapshot.attributes == .init(subrole: "AXDialog", isMain: false, isFocused: true, isMinimized: false))
    }

    @Test @MainActor
    func axWindowSnapshotTreatsErrorsAndMissingValuesAsUnknown() {
        var error = AXError.attributeUnsupported
        var origin = CGPoint(x: 1, y: 2)
        let values: [AnyObject?] = [
            nil,
            AXValueCreate(.cgPoint, &origin),
            AXValueCreate(.axError, &error),
            AXValueCreate(.axError, &error),
            "not a number" as NSString
        ]
        let snapshot = DesktopController.axWindowSnapshot(values: values)
        #expect(snapshot.identity.title == nil)
        #expect(snapshot.identity.frame == nil)
        #expect(snapshot.attributes == .init(subrole: nil, isMain: nil, isFocused: nil, isMinimized: nil))
        #expect(DesktopController.axWindowSnapshot(values: []).identity.frame == nil)
    }

    // MARK: Model and schema

    @Test
    func windowInfoOmitsNilFieldsAndBooleanFlagsWhenFalse() throws {
        let plain = try json(window(id: 1))
        #expect(Set(plain.keys) == ["window_id", "pid", "app_name", "bounds", "layer", "is_on_screen", "alpha"])
        for absent in ["subrole", "is_main", "is_focused", "is_minimized", "is_fullscreen", "is_frontmost_app", "hosts_zen", "title", "bundle_id"] {
            #expect(plain[absent] == nil)
        }

        let flagged = try json(window(id: 2, host: true, frontmost: true))
        #expect(flagged["is_frontmost_app"] as? Bool == true)
        #expect(flagged["hosts_zen"] as? Bool == true)
    }

    @Test
    func windowSchemaDeclaresTheNewFields() throws {
        let root = try outputSchemaObject()
        let defs = try #require(root["$defs"] as? [String: Any])
        let schema = try #require(defs["window"] as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let expected = [
            "window_id", "pid", "app_name", "bundle_id", "title", "bounds", "layer", "is_on_screen", "alpha",
            "is_focused", "is_minimized", "is_fullscreen", "subrole", "is_main", "is_frontmost_app", "hosts_zen"
        ]
        #expect(Set(properties.keys) == Set(expected))
        #expect(schema["required"] as? [String] == ["pid", "bounds", "layer", "is_on_screen", "alpha"])
        #expect((properties["subrole"] as? [String: Any])?["type"] as? String == "string")
        #expect((properties["is_main"] as? [String: Any])?["type"] as? String == "boolean")
        for flag in ["is_frontmost_app", "hosts_zen"] {
            let declaration = try #require(properties[flag] as? [String: Any])
            #expect(declaration["type"] as? String == "boolean")
            #expect(declaration["const"] as? Bool == true)
        }
    }

    @Test
    func everyEncodedWindowKeyIsDeclaredInTheSchema() throws {
        var full = window(id: 3, title: "Window", host: true, frontmost: true)
        full = DesktopWindowListing.applying(.init(subrole: "AXStandardWindow", isMain: true, isFocused: true, isMinimized: false), to: full)
        let root = try outputSchemaObject()
        let defs = try #require(root["$defs"] as? [String: Any])
        let properties = try #require((defs["window"] as? [String: Any])?["properties"] as? [String: Any])
        for key in try json(full).keys {
            #expect(properties[key] != nil, "window key \(key) is missing from $defs/window")
        }
    }

    @Test
    func toolDescriptionsDescribeWindowFieldsAndScreenshotDelivery() throws {
        #expect(DesktopRunTool.description.contains(
            "The screenshot PNG is attached to the model's multimodal tool context; models that cannot view images do not see it, and when ZenCODE has to remove it (a DS4 model without a vision encoder, or a provider that rejects images) it is replaced by a text notice. Without images, use list_windows and list_elements."
        ))
        #expect(!DesktopRunTool.description.contains("accepts images"))
        #expect(!DesktopRunTool.description.contains("attached automatically"))
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(DesktopRunTool.inputSchema.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let action = try #require((properties["action"] as? [String: Any])?["description"] as? String)
        for term in ["subrole", "is_frontmost_app", "hosts_zen", "frontmost_app", "close_window", "click by element_ref or query", "exact app_name"] {
            #expect(action.contains(term))
        }
    }

    @Test
    func textDescriptionExplainsHowToReplaceAFieldContent() throws {
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(DesktopRunTool.inputSchema.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let text = try #require((properties["text"] as? [String: Any])?["description"] as? String)
        #expect(text.contains("type_text inserts at the insertion point"))
        #expect(text.contains("use set_value, or press_key key=a with modifiers=[command] before typing"))
        let reference = try #require((properties["element_ref"] as? [String: Any])?["description"] as? String)
        #expect(reference.contains("role, subrole, title, description, or identifier change"))
    }
}
