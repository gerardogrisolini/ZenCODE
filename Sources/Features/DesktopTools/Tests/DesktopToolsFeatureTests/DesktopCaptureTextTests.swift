import Foundation
import Testing

@testable import desktop_tools_feature

@Suite
struct DesktopCaptureTextTests {
    @Test
    func summaryNamesTheFrontmostApp() {
        let summary = DesktopCaptureText.summary(
            scope: "display", dimensions: (1728, 1117), pointsPerPixel: 1, path: "/tmp/a.png",
            frontmostAppName: "Final Cut Pro", frontmostHostsZen: false
        )
        #expect(summary == "Captured a display screenshot (1728x1117 px, 1 point per pixel) to /tmp/a.png. Frontmost app: Final Cut Pro.")
    }

    @Test
    func summaryFlagsTheHostApp() {
        let summary = DesktopCaptureText.summary(
            scope: "window", dimensions: (800, 600), pointsPerPixel: 0.5, path: "/tmp/b.png",
            frontmostAppName: "Terminal", frontmostHostsZen: true
        )
        #expect(summary == "Captured a window screenshot (800x600 px, 0.5 points per pixel) to /tmp/b.png. Frontmost app: Terminal. It hosts this zen session.")
    }

    @Test
    func summaryWithoutFrontmostAppIsUnchanged() {
        let summary = DesktopCaptureText.summary(
            scope: "zoom", dimensions: nil, pointsPerPixel: nil, path: "/tmp/c.png"
        )
        #expect(summary == "Captured a zoom of the region (unknown size) to /tmp/c.png; the shadow margin prevents an exact image-to-desktop coordinate mapping.")
        #expect(summary == DesktopCaptureText.summary(
            scope: "zoom", dimensions: nil, pointsPerPixel: nil, path: "/tmp/c.png", frontmostAppName: " ", frontmostHostsZen: true
        ))
    }

    @Test
    func frontmostSentenceAppendsTheHostSuffixOnlyForTheHost() {
        #expect(DesktopCaptureText.frontmostSentence(appName: "Safari", hostsZen: false) == "Frontmost app: Safari.")
        #expect(DesktopCaptureText.frontmostSentence(appName: "Terminal", hostsZen: true) == "Frontmost app: Terminal. It hosts this zen session.")
        #expect(DesktopCaptureText.frontmostSentence(appName: nil, hostsZen: true) == nil)
    }

    @Test
    func noteDescribesImageDeliveryAndKeepsTheCoordinateMapping() {
        let attachment = "The PNG is attached to the model's multimodal tool context and is retained as a private desktop feature artifact. Models that cannot view images do not see it, and when ZenCODE has to remove it (a DS4 model without a vision encoder, or a provider that rejects images) it is replaced by a text notice. Without images, use list_windows, list_elements, and read_text."
        #expect(DesktopCaptureText.note(mapped: false, clipped: false) == attachment)
        let mapped = "Image pixel (px, py) maps to desktop point (desktop_bounds.x + px * points_per_pixel, desktop_bounds.y + py * points_per_pixel). "
        #expect(DesktopCaptureText.note(mapped: true, clipped: false) == mapped + attachment)
        #expect(DesktopCaptureText.note(mapped: true, clipped: true)
            == "The requested region extends beyond the attached displays, so the image covers only desktop_bounds. " + mapped + attachment)
        // The notice replaces the image only when ZenCODE removes it, not for
        // every model that cannot view images.
        #expect(!attachment.contains("accepts images"))
    }

    @Test
    func screenshotOutputCarriesTheFrontmostAppInItsOwnField() throws {
        var app = DesktopAppInfo(
            pid: 1, name: "Terminal", bundle_id: nil, bundle_path: nil, activation_policy: "regular",
            is_active: true, is_hidden: false, is_terminated: false
        )
        app.hosts_zen = true
        var output = DesktopRunOutput(action: "screenshot", summary: "Captured.")
        output.frontmost_app = app
        let encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        #expect(encoded["app"] == nil)
        let encodedApp = try #require(encoded["frontmost_app"] as? [String: Any])
        #expect(encodedApp["name"] as? String == "Terminal")
        #expect(encodedApp["hosts_zen"] as? Bool == true)

        let outputSchema = try #require(DesktopRunTool.outputSchema)
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(outputSchema.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let declaration = try #require(properties["frontmost_app"] as? [String: Any])
        #expect(declaration["$ref"] as? String == "#/$defs/app")
    }
}
