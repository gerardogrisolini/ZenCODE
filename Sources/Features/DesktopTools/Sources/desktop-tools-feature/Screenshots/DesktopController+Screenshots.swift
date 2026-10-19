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
        let delay = try boundedDouble(input.delay ?? 0, name: "delay", range: 0...30)
        let label = try sanitizedLabel(input.label)

        var arguments = ["-x", "-tpng"]
        var displayIndex: Int?
        var windowID: UInt32?
        var region: CGRect?

        switch scope {
        case "display":
            let index = input.display_index ?? 1
            guard displays().contains(where: { $0.capture_index == index }) else {
                throw DesktopControlError.invalidArgument("display_index", "no display has capture index \(index); call system_info.")
            }
            arguments.append("-D\(index)")
            displayIndex = index
        case "window":
            let selected = try selectedQuartzWindow(input)
            guard let selectedID = selected.window_id else { throw DesktopControlError.windowNotFound }
            arguments.append("-l\(selectedID)")
            if !(input.include_shadow ?? true) { arguments.append("-o") }
            windowID = selectedID
        case "region":
            let origin = try requiredPoint(x: input.x, y: input.y, action: action)
            let width = try positiveFinite(input.width, name: "width", action: action)
            let height = try positiveFinite(input.height, name: "height", action: action)
            let selectedRegion = try DesktopSafetyPolicy.captureRegion(x: Double(origin.x), y: Double(origin.y), width: width, height: height)
            guard DesktopSafetyPolicy.intersects(selectedRegion.rect, displays: displayBounds()) else {
                throw DesktopControlError.invalidArgument("x/y/width/height", "rounded region does not intersect an attached display.")
            }
            arguments.append(selectedRegion.argument)
            region = selectedRegion.rect
        default:
            throw DesktopControlError.invalidArgument("scope", "must be display, window, or region.")
        }

        guard CGPreflightScreenCaptureAccess() else {
            throw DesktopControlError.permissionRequired(
                "Screen Recording permission is required. Run action=request_permissions, then allow ZenCODE/macOS in System Settings > Privacy & Security > Screen & System Audio Recording."
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
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard !data.isEmpty else {
                throw DesktopControlError.operationFailed("The screenshot artifact is empty.")
            }
            let dimensions = pngDimensions(data)
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
                created_at: ISO8601DateFormatter().string(from: Date())
            )
            try pruneArtifacts(in: root, keeping: maximumArtifacts)
            return DesktopRunOutput(
                action: action,
                summary: "Captured a \(scope) screenshot to \(url.path).",
                artifact: artifact,
                note: "The PNG is attached to the model's multimodal tool context and retained as a private desktop feature artifact."
            )
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
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
