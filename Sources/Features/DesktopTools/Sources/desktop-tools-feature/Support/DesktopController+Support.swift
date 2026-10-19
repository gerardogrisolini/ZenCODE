//  Created by Gerardo Grisolini on 30/05/26.
//
import AppKit
import CoreGraphics
import FeatureKit
import Foundation
import ToolCore

extension DesktopController {
    static func permissions() -> DesktopPermissions {
        DesktopPermissions(accessibility: AXIsProcessTrusted(), screen_recording: CGPreflightScreenCaptureAccess(), event_posting: CGPreflightPostEventAccess())
    }

    static func requestPermissions() {
        let promptKey = "AXTrustedCheckOptionPrompt"
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        _ = CGRequestScreenCaptureAccess()
        _ = CGRequestPostEventAccess()
    }

    static func requireEventPosting() throws {
        guard CGPreflightPostEventAccess() else {
            throw DesktopControlError.permissionRequired(
                "Input control permission is required. Run action=request_permissions, then allow ZenCODE/macOS in System Settings > Privacy & Security > Accessibility."
            )
        }
    }

    static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw DesktopControlError.permissionRequired(
                "Accessibility permission is required for window control. Run action=request_permissions, then allow ZenCODE/macOS in System Settings > Privacy & Security > Accessibility."
            )
        }
    }

    static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static func displays() -> [DesktopDisplayInfo] {
        let screens = NSScreen.screens.sorted { lhs, rhs in
            let lhsID = displayID(for: lhs)
            let rhsID = displayID(for: rhs)
            if CGDisplayIsMain(lhsID) != 0 { return true }
            if CGDisplayIsMain(rhsID) != 0 { return false }
            return lhs.frame.origin.x < rhs.frame.origin.x
        }
        return screens.enumerated().map { offset, screen in
            let id = displayID(for: screen)
            return DesktopDisplayInfo(
                capture_index: offset + 1,
                display_id: id,
                name: screen.localizedName,
                is_main: CGDisplayIsMain(id) != 0,
                bounds: DesktopRect(CGDisplayBounds(id)),
                pixel_width: CGDisplayPixelsWide(id),
                pixel_height: CGDisplayPixelsHigh(id),
                scale_factor: Double(screen.backingScaleFactor)
            )
        }
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func currentPointerLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    static func pointer() -> DesktopPoint {
        DesktopPoint(currentPointerLocation())
    }


    struct ProcessResult {
        let status: Int32
        let stderr: String

        var message: String {
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "process exited with status \(status)." : trimmed
        }
    }

    static func runProcess(executable: String, arguments: [String]) async throws -> ProcessResult {
        let result = try await DesktopProcess.run(
            executableURL: URL(fileURLWithPath: executable), arguments: arguments
        )
        return ProcessResult(status: result.exitCode, stderr: String(decoding: result.stderrData, as: UTF8.self))
    }

    static func requiredNonempty(_ value: String?, name: String, action: String, allowEmpty: Bool = false) throws -> String {
        guard let value else { throw DesktopControlError.missingArgument(name, action) }
        if !allowEmpty, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DesktopControlError.invalidArgument(name, "must not be empty.")
        }
        return value
    }

    static func requiredPoint(
        x: Double?,
        y: Double?,
        action: String,
        xName: String = "x",
        yName: String = "y"
    ) throws -> CGPoint {
        guard let x else { throw DesktopControlError.missingArgument(xName, action) }
        guard let y else { throw DesktopControlError.missingArgument(yName, action) }
        guard x.isFinite else { throw DesktopControlError.invalidArgument(xName, "must be finite.") }
        guard y.isFinite else { throw DesktopControlError.invalidArgument(yName, "must be finite.") }
        return CGPoint(x: x, y: y)
    }

    static func boundedText(_ value: String?, action: String) throws -> String {
        let text = try requiredNonempty(value, name: "text", action: action, allowEmpty: true)
        guard text.count <= maximumTextLength else {
            throw DesktopControlError.invalidArgument("text", "must contain at most \(maximumTextLength) characters.")
        }
        return text
    }

    static func positiveFinite(_ value: Double?, name: String, action: String) throws -> Double {
        guard let value else { throw DesktopControlError.missingArgument(name, action) }
        guard value.isFinite, value > 0 else {
            throw DesktopControlError.invalidArgument(name, "must be a finite number greater than zero.")
        }
        return value
    }

    static func boundedDouble(_ value: Double, name: String, range: ClosedRange<Double>) throws -> Double {
        guard value.isFinite, range.contains(value) else {
            throw DesktopControlError.invalidArgument(name, "must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return value
    }

    static func boundedInteger(_ value: Int, name: String, range: ClosedRange<Int>) throws -> Int {
        guard range.contains(value) else {
            throw DesktopControlError.invalidArgument(name, "must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return value
    }

    static func boundedScroll(_ value: Double, name: String) throws -> Int32 {
        guard value.isFinite, (-10_000...10_000).contains(value) else {
            throw DesktopControlError.invalidArgument(name, "must be between -10000 and 10000.")
        }
        return Int32(value.rounded())
    }

    static func movementDuration(_ value: Double?) throws -> Double {
        try boundedDouble(value ?? 0.2, name: "duration", range: 0...10)
    }

    @discardableResult
    static func moveToRequestedPoint(_ input: DesktopRunInput, action: String) throws -> CGPoint {
        let destination = try requiredPoint(x: input.x, y: input.y, action: action)
        try validateDesktopPoint(destination, argument: "x/y")
        try movePointer(to: destination, duration: try movementDuration(input.duration))
        return destination
    }

    static func displayBounds() -> [CGRect] {
        NSScreen.screens.map { CGDisplayBounds(displayID(for: $0)) }
    }

    static func validateDesktopPoint(_ point: CGPoint, argument: String) throws {
        guard DesktopSafetyPolicy.contains(point, displays: displayBounds()) else {
            throw DesktopControlError.invalidArgument(argument, "point lies outside all attached displays; call system_info for global bounds.")
        }
    }

    static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func format(_ value: CGFloat) -> String {
        format(Double(value))
    }
}
