//  Created by Gerardo Grisolini on 30/05/26.
//
import AppKit
import CoreGraphics
import FeatureKit
import Foundation
import ToolCore
import CryptoKit

extension DesktopController {

    /// What a capture is, as decided by `screenshot` and `zoom`.
    private struct CaptureRequest {
        /// display, window, region, element, or zoom (the zoom of a region).
        let scope: String
        /// Native resolution (zoom) rather than point scale (screenshot).
        let zoomed: Bool
        /// The window chosen by default, the frontmost one; nil to select it
        /// from the input.
        var window: DesktopWindowInfo?
        /// Says why the scope was chosen, when it was not given.
        var scopeNote: String?
        /// The scope defaulted to window because of the call's own window or app selectors.
        var windowSelectedByArguments = false
    }

    /// screenshot: `scope` is display, window, region, or element; when it is
    /// omitted, `DesktopScreenshotScope.decide` chooses it from the other
    /// arguments, and a note says which.
    static func screenshot(_ input: DesktopRunInput, context: FeatureContext, action: String) async throws -> DesktopRunOutput {
        var arguments = DesktopScreenshotScope.Arguments(input)
        arguments.scope = try DesktopScreenshotScope.explicitScope(input.scope)
        try DesktopScreenshotScope.validate(arguments, action: action)
        let decision = DesktopScreenshotScope.decide(
            arguments,
            windows: { visibleWindowStack() },
            hostPID: DesktopHostApplication.current()?.pid,
            hostName: DesktopHostApplication.currentName()
        )
        return try await capture(
            input, context: context, action: action,
            request: CaptureRequest(
                scope: decision.scope, zoomed: false, window: decision.window, scopeNote: decision.note,
                windowSelectedByArguments: decision.selectedByArguments
            )
        )
    }

    /// zoom: the region x, y, width, and height at native resolution, or the
    /// frame of the element selected by element_ref, query, or identifier. It has
    /// never used `scope`, which is refused only next to an element selector.
    static func zoom(_ input: DesktopRunInput, context: FeatureContext, action: String) async throws -> DesktopRunOutput {
        let arguments = DesktopScreenshotScope.Arguments(input)
        try DesktopScreenshotScope.validate(arguments, action: action)
        return try await capture(
            input, context: context, action: action,
            request: CaptureRequest(scope: arguments.hasElementSelectors ? "element" : "zoom", zoomed: true)
        )
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

    /// The `screencapture -R` argument and the areas of a region capture.
    private struct RegionCapture {
        let argument: String
        /// The region as requested (rounded to whole points).
        let region: CGRect
        /// The area the image really covers.
        let desktopBounds: CGRect
        /// The region extends beyond the displays, so the image covers less.
        let isClipped: Bool
    }

    /// `screencapture -R` crops to the bounding box of the region's
    /// intersections with the attached displays; capture exactly that box so
    /// desktop_bounds is the area the image really covers.
    private static func regionCapture(of selectedRegion: DesktopSafetyPolicy.CaptureRegion) throws -> RegionCapture {
        guard let covered = DesktopScreenshotGeometry.coveredBounds(of: selectedRegion.rect, displays: displayBounds()) else {
            throw DesktopControlError.invalidArgument("x/y/width/height", "rounded region does not intersect an attached display.")
        }
        let captured = try DesktopSafetyPolicy.captureRegion(
            x: Double(covered.minX), y: Double(covered.minY),
            width: Double(covered.width), height: Double(covered.height)
        )
        return RegionCapture(
            argument: captured.argument, region: selectedRegion.rect, desktopBounds: captured.rect,
            isClipped: captured.rect != selectedRegion.rect
        )
    }

    /// Shared pipeline for the screenshot (display, window, region, element) and
    /// zoom (region, element) captures.
    private static func capture(
        _ input: DesktopRunInput,
        context: FeatureContext,
        action: String,
        request: CaptureRequest
    ) async throws -> DesktopRunOutput {
        let scope = request.scope
        let delay = try boundedDouble(input.delay ?? 0, name: "delay", range: 0...30)
        let label = try sanitizedLabel(input.label)

        var arguments = ["-x", "-tpng"]
        var displayIndex: Int?
        var windowID: UInt32?
        var region: CGRect?
        var desktopBounds: CGRect?
        var shadowedWindowCenter: CGPoint?
        var regionWasClipped = false
        var element: ResolvedElement?
        var elementWasClipped = false

        // An element can move while delay stabilizes the UI: resolve its frame
        // only after the wait, immediately before choosing the capture region.
        if scope == "element" { try await preflightCapture(delay: delay) }
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
            let selected: DesktopWindowInfo
            if let chosen = request.window {
                selected = chosen
            } else {
                do {
                    selected = try selectedQuartzWindow(input)
                } catch DesktopControlError.windowNotFound where request.windowSelectedByArguments {
                    throw DesktopControlError.operationFailed(
                        DesktopScreenshotScope.defaultedWindowNotFoundMessage(DesktopControlError.windowNotFound.errorDescription ?? "")
                    )
                }
            }
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
            let capture = try regionCapture(of: try requestedRegion(input, action: action))
            arguments.append(capture.argument)
            region = capture.region
            desktopBounds = capture.desktopBounds
            regionWasClipped = capture.isClipped
        case "element":
            // Like press_element, but without the host protection: it only reads.
            let target = try resolveElementTarget(input, action: action)
            let frame = target.info.frame.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            switch DesktopScreenshotGeometry.elementRegion(frame: frame, displays: displayBounds()) {
            case .noFrame:
                throw DesktopControlError.operationFailed(DesktopCaptureText.elementWithoutFrameMessage(target.phrase))
            case .offScreen:
                throw DesktopControlError.operationFailed(DesktopCaptureText.elementOffScreenMessage(target.phrase))
            case let .region(rect, _, isClipped):
                let capture = try regionCapture(of: try DesktopSafetyPolicy.captureRegion(
                    x: Double(rect.minX), y: Double(rect.minY), width: Double(rect.width), height: Double(rect.height)
                ))
                arguments.append(capture.argument)
                region = capture.region
                desktopBounds = capture.desktopBounds
                elementWasClipped = isClipped || capture.isClipped
            }
            element = target
        default:
            throw DesktopControlError.invalidArgument("scope", "must be \(DesktopScreenshotScope.namesPhrase).")
        }

        if scope != "element" { try await preflightCapture(delay: delay) }
        // Read after the delay, so it describes the screen that is captured.
        let frontmost = currentFrontmost().map { appInfo($0) }
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
            if request.zoomed {
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
                summary: DesktopCaptureText.summary(
                    scope: scope,
                    dimensions: dimensions,
                    pointsPerPixel: pointsPerPixel,
                    path: url.path,
                    frontmostAppName: frontmost?.name ?? frontmost?.bundle_id,
                    frontmostHostsZen: frontmost?.hosts_zen == true,
                    element: element?.phrase,
                    zoomed: request.zoomed
                ),
                artifact: artifact,
                note: DesktopListPaging.joined([
                    request.scopeNote,
                    element?.relocationNote,
                    DesktopCaptureText.note(mapped: pointsPerPixel != nil, clipped: regionWasClipped, elementClipped: elementWasClipped)
                ]),
                element: element.map { DesktopElementPolicy.compact($0.info) },
                frontmost_app: frontmost
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func preflightCapture(delay: Double) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw DesktopControlError.permissionRequired(
                "Screen Recording permission is required. Run action=request_permissions, then allow \(DesktopHostApplication.subject()) in System Settings > Privacy & Security > Screen & System Audio Recording."
            )
        }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
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
