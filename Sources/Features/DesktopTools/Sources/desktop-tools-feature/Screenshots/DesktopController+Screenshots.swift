//  Created by Gerardo Grisolini on 30/05/26.
//
import AppKit
import CoreGraphics
import FeatureKit
import Foundation
import ToolCore
import CryptoKit

extension DesktopController {

    static func screenshot(_ input: DesktopRunInput, context: FeatureContext, action: String) async throws -> DesktopRunOutput {
        let scope = (input.scope?.nilIfBlank ?? "display").lowercased()
        guard ["display", "window", "region"].contains(scope) else {
            throw DesktopControlError.invalidArgument("scope", "must be display, window, or region.")
        }
        return try await capture(input, context: context, action: action, scope: scope)
    }

    static func zoom(_ input: DesktopRunInput, context: FeatureContext, action: String) async throws -> DesktopRunOutput {
        try await capture(input, context: context, action: action, scope: "zoom")
    }

    private static func requestedRegion(_ input: DesktopRunInput, action: String) throws -> DesktopSafetyPolicy.CaptureRegion {
        let origin = try requiredPoint(x: input.x, y: input.y, action: action)
        let width = try positiveFinite(input.width, name: "width", action: action)
        let height = try positiveFinite(input.height, name: "height", action: action)
        let selectedRegion = try DesktopSafetyPolicy.captureRegion(x: Double(origin.x), y: Double(origin.y), width: width, height: height)
        guard DesktopSafetyPolicy.intersects(selectedRegion.rect, displays: displayBounds()) else {
            throw DesktopControlError.invalidArgument("x/y/width/height", "rounded region does not intersect an attached display.")
        }
        return selectedRegion
    }

    /// Shared pipeline for the screenshot (display/window/region) and zoom scopes.
    private static func capture(
        _ input: DesktopRunInput,
        context: FeatureContext,
        action: String,
        scope: String
    ) async throws -> DesktopRunOutput {
        let delay = try boundedDouble(input.delay ?? 0, name: "delay", range: 0...30)
        let label = try sanitizedLabel(input.label)

        var arguments = ["-x", "-tpng"]
        var displayIndex: Int?
        var windowID: UInt32?
        var region: CGRect?
        var desktopBounds: CGRect?
        var shadowedWindowCenter: CGPoint?
        var regionWasClipped = false

        switch scope {
        case "display":
            let index = input.display_index ?? 1
            guard let display = displays().first(where: { $0.capture_index == index }) else {
                throw DesktopControlError.invalidArgument("display_index", "no display has capture index \(index); call system_info.")
            }
            let bounds = CGRect(x: display.bounds.x, y: display.bounds.y, width: display.bounds.width, height: display.bounds.height)
            let displayRegion = try DesktopSafetyPolicy.captureRegion(x: display.bounds.x, y: display.bounds.y, width: display.bounds.width, height: display.bounds.height)
            arguments.append(displayRegion.argument)
            displayIndex = index
            desktopBounds = bounds
        case "window":
            let selected = try selectedQuartzWindow(input)
            guard let selectedID = selected.window_id else { throw DesktopControlError.windowNotFound }
            arguments.append("-l\(selectedID)")
            let bounds = CGRect(x: selected.bounds.x, y: selected.bounds.y, width: selected.bounds.width, height: selected.bounds.height)
            if input.include_shadow == true {
                shadowedWindowCenter = CGPoint(x: bounds.midX, y: bounds.midY)
            } else {
                arguments.append("-o")
                desktopBounds = bounds
            }
            windowID = selectedID
        case "region", "zoom":
            let selectedRegion = try requestedRegion(input, action: action)
            // screencapture -R crops to the bounding box of the region's
            // intersections with the attached displays; capture exactly that
            // box so desktop_bounds is the area the image really covers.
            guard let covered = DesktopScreenshotGeometry.coveredBounds(of: selectedRegion.rect, displays: displayBounds()) else {
                throw DesktopControlError.invalidArgument("x/y/width/height", "rounded region does not intersect an attached display.")
            }
            let captured = try DesktopSafetyPolicy.captureRegion(
                x: Double(covered.minX), y: Double(covered.minY),
                width: Double(covered.width), height: Double(covered.height)
            )
            arguments.append(captured.argument)
            region = selectedRegion.rect
            desktopBounds = captured.rect
            regionWasClipped = captured.rect != selectedRegion.rect
        default:
            throw DesktopControlError.invalidArgument("scope", "must be display, window, or region.")
        }

        guard CGPreflightScreenCaptureAccess() else {
            throw DesktopControlError.permissionRequired(
                "Screen Recording permission is required. Run action=request_permissions, then allow \(DesktopHostApplication.subject()) in System Settings > Privacy & Security > Screen & System Audio Recording."
            )
        }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        let root = try artifactDirectory(context: context)
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = root.appendingPathComponent("\(label)-\(timestamp)-\(UUID().uuidString).png")
        if input.include_cursor ?? false { arguments.append("-C") }
        arguments.append(url.path)

        do {
            let result = try await runProcess(executable: "/usr/sbin/screencapture", arguments: arguments)
            guard result.status == 0 else {
                throw DesktopControlError.processFailed("Screenshot capture failed: \(result.message)")
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw DesktopControlError.operationFailed("screencapture reported success but did not create a PNG artifact.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

            let native = try nativePixelSize(of: url)
            if let bounds = desktopBounds,
               !DesktopScreenshotGeometry.isUniformScaling(nativePixels: native, covered: bounds.size) {
                throw DesktopControlError.operationFailed(
                    "The capture (\(native.width)x\(native.height) px) does not match the expected desktop area (\(Int(bounds.width))x\(Int(bounds.height)) points), so no exact coordinate mapping is possible. Retry with a region inside a single display."
                )
            }
            let target: DesktopScreenshotGeometry.PixelSize
            if scope == "zoom" {
                target = DesktopScreenshotGeometry.zoomSize(nativePixels: native, maximumLongEdge: maximumZoomLongEdge)
            } else if let desktopBounds {
                target = DesktopScreenshotGeometry.pointScaleSize(coveredPoints: desktopBounds.size)
            } else {
                target = DesktopScreenshotGeometry.shadowedWindowSize(
                    nativePixels: native,
                    backingScale: backingScale(at: shadowedWindowCenter)
                )
            }
            try DesktopImageScaler.resample(pngAt: url, width: target.width, height: target.height)

            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else {
                throw DesktopControlError.operationFailed("The screenshot artifact is empty.")
            }
            let dimensions = pngDimensions(data)
            let pointsPerPixel = desktopBounds.flatMap { bounds in
                dimensions.flatMap { DesktopScreenshotGeometry.pointsPerPixel(coveredWidth: Double(bounds.width), pixelWidth: $0.width) }
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let artifact = DesktopScreenshotArtifact(
                path: url.path,
                mime_type: "image/png",
                size_bytes: data.count,
                sha256: digest,
                pixel_width: dimensions?.width,
                pixel_height: dimensions?.height,
                scope: scope,
                display_index: displayIndex,
                window_id: windowID,
                region: region.map(DesktopRect.init),
                desktop_bounds: pointsPerPixel == nil ? nil : desktopBounds.map(DesktopRect.init),
                points_per_pixel: pointsPerPixel,
                created_at: ISO8601DateFormatter().string(from: Date())
            )
            try pruneArtifacts(in: root, keeping: maximumArtifacts)
            return DesktopRunOutput(
                action: action,
                summary: captureSummary(scope: scope, dimensions: dimensions, pointsPerPixel: pointsPerPixel, path: url.path),
                artifact: artifact,
                note: captureNote(mapped: pointsPerPixel != nil, clipped: regionWasClipped)
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func nativePixelSize(of url: URL) throws -> DesktopScreenshotGeometry.PixelSize {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 24) ?? Data()
        guard let dimensions = pngDimensions(header) else {
            throw DesktopControlError.operationFailed("The captured screenshot is not a valid PNG.")
        }
        return DesktopScreenshotGeometry.PixelSize(width: dimensions.width, height: dimensions.height)
    }

    private static func backingScale(at point: CGPoint?) -> Double? {
        let all = displays()
        if let point, let match = all.first(where: {
            CGRect(x: $0.bounds.x, y: $0.bounds.y, width: $0.bounds.width, height: $0.bounds.height).contains(point)
        }) {
            return match.scale_factor
        }
        return all.first(where: { $0.is_main })?.scale_factor
    }

    private static func formatScale(_ value: Double) -> String {
        var text = String(format: "%.4f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private static func captureSummary(scope: String, dimensions: (width: Int, height: Int)?, pointsPerPixel: Double?, path: String) -> String {
        let noun: String
        switch scope {
        case "zoom": noun = "a zoom of the region"
        case "display": noun = "a display screenshot"
        case "window": noun = "a window screenshot"
        default: noun = "a region screenshot"
        }
        let size = dimensions.map { "\($0.width)x\($0.height) px" } ?? "unknown size"
        if let pointsPerPixel {
            let unit = abs(pointsPerPixel - 1) < 0.00005 ? "point" : "points"
            return "Captured \(noun) (\(size), \(formatScale(pointsPerPixel)) \(unit) per pixel) to \(path)."
        }
        return "Captured \(noun) (\(size)) to \(path); the shadow margin prevents an exact image-to-desktop coordinate mapping."
    }

    private static func captureNote(mapped: Bool, clipped: Bool) -> String {
        let attachment = "The PNG is attached to the model's multimodal tool context and retained as a private desktop feature artifact."
        guard mapped else { return attachment }
        let clipping = clipped
            ? "The requested region extends beyond the attached displays, so the image covers only desktop_bounds. "
            : ""
        return clipping
            + "Image pixel (px, py) maps to desktop point (desktop_bounds.x + px * points_per_pixel, desktop_bounds.y + py * points_per_pixel). "
            + attachment
    }

    static func artifactDirectory(context: FeatureContext) throws -> URL {
        let root: URL
        if let configured = context.environment["ZENCODE_SUPPORT_DIRECTORY"]?.nilIfBlank {
            root = URL(fileURLWithPath: NSString(string: configured).expandingTildeInPath, isDirectory: true)
        } else if let home = context.environment["HOME"]?.nilIfBlank {
            root = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".zencode", isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zencode", isDirectory: true)
        }
        let directory = root
            .appendingPathComponent("desktop", isDirectory: true)
            .appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory.standardizedFileURL
    }

    static func sanitizedLabel(_ value: String?) throws -> String {
        guard let value = value?.nilIfBlank else { return "screenshot" }
        guard value.count <= 64 else {
            throw DesktopControlError.invalidArgument("label", "must contain at most 64 characters.")
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted
        let sanitized = value.components(separatedBy: allowed).filter { !$0.isEmpty }.joined(separator: "-")
        guard !sanitized.isEmpty else {
            throw DesktopControlError.invalidArgument("label", "must contain a letter, number, hyphen, or underscore.")
        }
        return sanitized
    }

    static func pruneArtifacts(in directory: URL, keeping maximum: Int) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { url in
                guard url.pathExtension.lowercased() == "png" else { return false }
                return (try? url.resourceValues(forKeys: keys).isRegularFile) == true
            }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                return left > right
            }
        for stale in files.dropFirst(maximum) {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    static func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = Array(data.prefix(24))
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count == 24,
              Array(bytes[0..<8]) == signature,
              Array(bytes[12..<16]) == [73, 72, 68, 82] else { return nil }
        func value(_ range: Range<Int>) -> Int {
            bytes[range].reduce(0) { ($0 << 8) | Int($1) }
        }
        let width = value(16..<20)
        let height = value(20..<24)
        return width > 0 && height > 0 ? (width, height) : nil
    }

}
