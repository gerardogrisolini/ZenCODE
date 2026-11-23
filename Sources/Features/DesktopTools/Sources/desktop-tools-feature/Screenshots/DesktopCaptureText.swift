import Foundation

/// Pure text composition for screenshot and zoom results, kept free of live
/// desktop state so it is deterministic to test.
enum DesktopCaptureText {
    static func formatScale(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// "Frontmost app: Terminal. It hosts this zen session." (the second sentence
    /// only for the host app), or nil when no app is in front.
    static func frontmostSentence(appName: String?, hostsZen: Bool) -> String? {
        guard let appName = appName?.trimmingCharacters(in: .whitespacesAndNewlines), !appName.isEmpty else { return nil }
        return "Frontmost app: \(appName)." + (hostsZen ? " It hosts this zen session." : "")
    }

    /// - Parameters:
    ///   - element: for scope "element", the phrase that describes the element
    ///     (`DesktopElementPolicy.locationPhrase`).
    ///   - zoomed: for scope "element", whether it is a zoom (native resolution)
    ///     rather than a screenshot (point scale).
    static func summary(
        scope: String,
        dimensions: (width: Int, height: Int)?,
        pointsPerPixel: Double?,
        path: String,
        frontmostAppName: String? = nil,
        frontmostHostsZen: Bool = false,
        element: String? = nil,
        zoomed: Bool = false
    ) -> String {
        let noun: String
        switch scope {
        case "zoom": noun = "a zoom of the region"
        case "display": noun = "a display screenshot"
        case "window": noun = "a window screenshot"
        case "element":
            let target = element.map { "the element \($0)" } ?? "an element"
            noun = zoomed ? "a zoom of \(target)" : "a screenshot of \(target)"
        default: noun = "a region screenshot"
        }
        let size = dimensions.map { "\($0.width)x\($0.height) px" } ?? "unknown size"
        let base: String
        if let pointsPerPixel {
            let unit = abs(pointsPerPixel - 1) < 0.00005 ? "point" : "points"
            base = "Captured \(noun) (\(size), \(formatScale(pointsPerPixel)) \(unit) per pixel) to \(path)."
        } else {
            base = "Captured \(noun) (\(size)) to \(path); the shadow margin prevents an exact image-to-desktop coordinate mapping."
        }
        guard let frontmost = frontmostSentence(appName: frontmostAppName, hostsZen: frontmostHostsZen) else { return base }
        return base + " " + frontmost
    }

    static let attachmentSentence = "The PNG is attached to the model's multimodal tool context and is retained as a private desktop feature artifact. Models that cannot view images do not see it, and when ZenCODE has to remove it (a DS4 model without a vision encoder, or a provider that rejects images) it is replaced by a text notice. Without images, use list_windows, list_elements, and read_text."

    static func note(mapped: Bool, clipped: Bool, elementClipped: Bool = false) -> String {
        guard mapped else { return attachmentSentence }
        let clipping = clipped
            ? "The requested region extends beyond the attached displays, so the image covers only desktop_bounds. "
            : ""
        let elementClipping = elementClipped
            ? "The element extends beyond its display, so the image covers only its visible part, desktop_bounds. "
            : ""
        return clipping
            + elementClipping
            + "Image pixel (px, py) maps to desktop point (desktop_bounds.x + px * points_per_pixel, desktop_bounds.y + py * points_per_pixel). "
            + attachmentSentence
    }

    /// The error of an element that reports no usable frame.
    static func elementWithoutFrameMessage(_ element: String) -> String {
        "\(element) reports no frame, or an empty one, so it cannot be captured. Capture its window with scope=window, or a region with x, y, width, and height."
    }

    /// The error of an element whose frame lies outside every attached display.
    static func elementOffScreenMessage(_ element: String) -> String {
        "\(element) lies outside every attached display (it may be scrolled out of view, in a hidden window, or on a display that is gone), so there is nothing to capture. Bring it into view, or call system_info for the displays."
    }
}
