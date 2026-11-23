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

    static func summary(
        scope: String,
        dimensions: (width: Int, height: Int)?,
        pointsPerPixel: Double?,
        path: String,
        frontmostAppName: String? = nil,
        frontmostHostsZen: Bool = false
    ) -> String {
        let noun: String
        switch scope {
        case "zoom": noun = "a zoom of the region"
        case "display": noun = "a display screenshot"
        case "window": noun = "a window screenshot"
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

    static let attachmentSentence = "The PNG is attached to the model's multimodal tool context and is retained as a private desktop feature artifact. Models that cannot view images do not see it, and when ZenCODE has to remove it (a DS4 model without a vision encoder, or a provider that rejects images) it is replaced by a text notice. Without images, use list_windows and list_elements."

    static func note(mapped: Bool, clipped: Bool) -> String {
        guard mapped else { return attachmentSentence }
        let clipping = clipped
            ? "The requested region extends beyond the attached displays, so the image covers only desktop_bounds. "
            : ""
        return clipping
            + "Image pixel (px, py) maps to desktop point (desktop_bounds.x + px * points_per_pixel, desktop_bounds.y + py * points_per_pixel). "
            + attachmentSentence
    }
}
