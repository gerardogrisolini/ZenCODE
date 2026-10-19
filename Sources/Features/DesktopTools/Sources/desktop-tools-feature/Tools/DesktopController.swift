//  Created by Gerardo Grisolini on 30/05/26.
//
import AppKit
import ApplicationServices
import CoreGraphics
import FeatureKit
import Foundation

@MainActor
enum DesktopController {
    static let maximumTextLength = 10_000
    static let maximumArtifacts = 50
    static let axFullScreenAttribute = "AXFullScreen" as CFString

    static func execute(_ input: DesktopRunInput, context: FeatureContext) async throws -> DesktopRunOutput {
        let action = input.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !action.isEmpty else {
            throw DesktopControlError.invalidArgument("action", "must not be empty.")
        }

        switch action {
        case "permissions":
            return DesktopRunOutput(action: action, summary: "Read macOS automation permissions.", permissions: permissions())

        case "request_permissions":
            requestPermissions()
            return DesktopRunOutput(
                action: action,
                summary: "Requested macOS automation permissions.",
                permissions: permissions(),
                note: "Approve any System Settings prompts. Permission changes may require relaunching ZenCODE before they become visible."
            )

        case "system_info":
            let info = DesktopSystemInfo(
                os_version: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architectureName,
                process_id: ProcessInfo.processInfo.processIdentifier,
                displays: displays(),
                pointer: pointer(),
                frontmost_app: NSWorkspace.shared.frontmostApplication.map { appInfo($0) }
            )
            return DesktopRunOutput(action: action, summary: "Read macOS system, display, pointer, and frontmost-app state.", permissions: permissions(), system: info)

        case "list_apps":
            let limit = try boundedInteger(input.limit ?? 100, name: "limit", range: 1...200)
            let apps = runningApps(matching: input).prefix(limit).map { appInfo($0) }
            return DesktopRunOutput(action: action, summary: "Listed \(apps.count) running application(s).", apps: Array(apps), count: apps.count)

        case "list_windows":
            let limit = try boundedInteger(input.limit ?? 100, name: "limit", range: 1...200)
            let windows = windowRecords(onScreenOnly: input.on_screen_only ?? false, matching: input)
            let result = Array(windows.prefix(limit))
            return DesktopRunOutput(
                action: action,
                summary: "Listed \(result.count) window(s) in front-to-back order.",
                windows: result,
                count: result.count,
                note: CGPreflightScreenCaptureAccess()
                    ? nil
                    : "Without Screen Recording permission, some window titles may be unavailable."
            )

        case "screenshot":
            return try await screenshot(input, context: context, action: action)

        case "move_mouse":
            try requireEventPosting()
            let destination = try moveToRequestedPoint(input, action: action)
            return DesktopRunOutput(action: action, summary: "Moved the pointer to (\(format(destination.x)), \(format(destination.y))).", pointer: pointer())

        case "click":
            try requireEventPosting()
            if input.x != nil || input.y != nil {
                try moveToRequestedPoint(input, action: action)
            }
            let mouseButton = try parseMouseButton(input.button)
            let clickCount = try boundedInteger(input.click_count ?? 1, name: "click_count", range: 1...3)
            try click(button: mouseButton, count: clickCount)
            let location = pointer()
            return DesktopRunOutput(
                action: action,
                summary: "Performed \(clickCount) \(mouseButton.name) click(s) at (\(format(location.x)), \(format(location.y))).",
                pointer: location,
                count: clickCount
            )

        case "drag":
            try requireEventPosting()
            let start: CGPoint
            if input.x != nil || input.y != nil {
                start = try requiredPoint(x: input.x, y: input.y, action: action)
            } else {
                start = currentPointerLocation()
            }
            let destination = try requiredPoint(x: input.to_x, y: input.to_y, action: action, xName: "to_x", yName: "to_y")
            try validateDesktopPoint(start, argument: "x/y")
            try validateDesktopPoint(destination, argument: "to_x/to_y")
            let mouseButton = try parseMouseButton(input.button)
            try dragPointer(from: start, to: destination, duration: try movementDuration(input.duration), button: mouseButton)
            return DesktopRunOutput(
                action: action,
                summary: "Dragged the \(mouseButton.name) button to (\(format(destination.x)), \(format(destination.y))).",
                pointer: pointer()
            )

        case "scroll":
            try requireEventPosting()
            let dx = try boundedScroll(input.delta_x ?? 0, name: "delta_x")
            let dy = try boundedScroll(input.delta_y ?? 0, name: "delta_y")
            guard dx != 0 || dy != 0 else {
                throw DesktopControlError.invalidArgument("delta_x/delta_y", "at least one scroll amount must be non-zero.")
            }
            let unit = try parseScrollUnit(input.scroll_unit)
            try postScroll(deltaX: dx, deltaY: dy, unit: unit)
            return DesktopRunOutput(action: action, summary: "Scrolled by (\(dx), \(dy)) \(unit.name) unit(s).", pointer: pointer())

        case "type_text":
            let text = try boundedText(input.text, action: action)
            let interval = try boundedDouble(input.interval ?? 0.01, name: "interval", range: 0...1)
            try DesktopSafetyPolicy.validateTypingBudget(characterCount: text.count, interval: interval)
            try requireEventPosting()
            try typeText(text, interval: interval)
            return DesktopRunOutput(action: action, summary: "Typed \(text.count) character(s) into the focused control.", count: text.count)

        case "press_key":
            try requireEventPosting()
            let key = try requiredNonempty(input.key, name: "key", action: action)
            let repeatCount = try boundedInteger(input.repeat_count ?? 1, name: "repeat_count", range: 1...100)
            let interval = try boundedDouble(input.interval ?? 0.05, name: "interval", range: 0...1)
            let flags = try modifierFlags(input.modifiers ?? [])
            try pressKey(key, modifiers: flags, repeatCount: repeatCount, interval: interval)
            return DesktopRunOutput(action: action, summary: "Pressed key '\(key)' \(repeatCount) time(s).", count: repeatCount)

        case "launch_app":
            let app = try await launchApp(input, context: context)
            return DesktopRunOutput(action: action, summary: "Launched \(app.localizedName ?? app.bundleIdentifier ?? "application").", app: appInfo(app))

        case "activate_app":
            var app = matchingRunningApp(input, defaultToFrontmost: false)
            if app == nil, input.launch_if_needed ?? false {
                app = try await launchApp(input, context: context)
            }
            guard let app else { throw DesktopControlError.appNotFound }
            guard app.activate(options: [.activateAllWindows]) else {
                throw DesktopControlError.operationFailed("macOS refused to activate the selected application.")
            }
            guard let activeProbe = try await waitForApplicationProbe(
                pid: app.processIdentifier,
                timeout: 2,
                where: { $0.exists && $0.is_active }
            ) else {
                throw DesktopControlError.operationFailed("The selected application did not become active before timeout.")
            }
            return DesktopRunOutput(
                action: action,
                summary: "Activated \(app.localizedName ?? app.bundleIdentifier ?? "application").",
                app: appInfo(app, probe: activeProbe)
            )

        case "hide_app", "unhide_app":
            let hide = action == "hide_app"
            let app = try selectedRunningApp(input)
            let initialProbe = try await applicationProbe(pid: app.processIdentifier)
            if initialProbe.is_hidden != hide {
                _ = hide ? app.hide() : app.unhide()
            }
            guard let probe = try await waitForApplicationProbe(
                pid: app.processIdentifier,
                timeout: 2,
                where: { $0.exists && $0.is_hidden == hide }
            ) else {
                throw DesktopControlError.operationFailed("The selected application did not become \(hide ? "hidden" : "visible") before timeout.")
            }
            return DesktopRunOutput(action: action, summary: "\(hide ? "Hid" : "Unhid") \(app.localizedName ?? "application").", app: appInfo(app, probe: probe))

        case "terminate_app":
            let app = try selectedRunningApp(input)
            let before = appInfo(app)
            let forced = input.force ?? false
            let accepted = forced ? app.forceTerminate() : app.terminate()
            guard accepted else {
                throw DesktopControlError.operationFailed("macOS refused to terminate the selected application.")
            }
            return DesktopRunOutput(
                action: action,
                summary: forced ? "Force-terminated \(app.localizedName ?? "application")." : "Requested termination of \(app.localizedName ?? "application").",
                app: before
            )

        case "focus_window":
            let selection = try selectedAXWindow(input)
            if let app = NSRunningApplication(processIdentifier: selection.pid) {
                _ = app.activate(options: [.activateAllWindows])
            }
            let raiseResult = AXUIElementPerformAction(selection.element, kAXRaiseAction as CFString)
            guard raiseResult == .success else {
                throw DesktopControlError.accessibilityFailed("raise window", raiseResult)
            }
            _ = AXUIElementSetAttributeValue(selection.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(selection.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: "Focused the selected window.", window: window)

        case "move_window":
            let selection = try selectedAXWindow(input)
            var point = try requiredPoint(x: input.x, y: input.y, action: action)
            try setAXValue(selection.element, attribute: kAXPositionAttribute as CFString, encoded: AXValueCreate(.cgPoint, &point), what: "position", operation: "move window")
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: "Moved the selected window.", window: window)

        case "resize_window":
            let selection = try selectedAXWindow(input)
            let width = try positiveFinite(input.width, name: "width", action: action)
            let height = try positiveFinite(input.height, name: "height", action: action)
            var size = CGSize(width: width, height: height)
            try setAXValue(selection.element, attribute: kAXSizeAttribute as CFString, encoded: AXValueCreate(.cgSize, &size), what: "size", operation: "resize window")
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: "Resized the selected window.", window: window)

        case "minimize_window", "set_fullscreen":
            let selection = try selectedAXWindow(input)
            guard let state = input.state else {
                throw DesktopControlError.missingArgument("state", action)
            }
            let minimize = action == "minimize_window"
            try setAXBoolean(
                selection.element,
                attribute: minimize ? kAXMinimizedAttribute as CFString : axFullScreenAttribute,
                value: state,
                operation: minimize ? "set minimized state" : "set fullscreen state"
            )
            let summary = minimize
                ? (state ? "Minimized the selected window." : "Restored the selected window.")
                : (state ? "Entered fullscreen for the selected window." : "Exited fullscreen for the selected window.")
            return DesktopRunOutput(action: action, summary: summary, window: axWindowInfo(selection))

        case "close_window":
            let selection = try selectedAXWindow(input)
            let before = axWindowInfo(selection)
            let closeButton = try copyAXElement(selection.element, attribute: kAXCloseButtonAttribute as CFString, operation: "read close button")
            let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            guard result == .success else {
                throw DesktopControlError.accessibilityFailed("close window", result)
            }
            return DesktopRunOutput(action: action, summary: "Closed the selected window.", window: before)

        case "read_clipboard":
            let value = NSPasteboard.general.string(forType: .string)
            return DesktopRunOutput(
                action: action,
                summary: value == nil ? "The clipboard does not contain plain text." : "Read \(value?.count ?? 0) character(s) from the clipboard.",
                clipboard_text: value,
                count: value?.count ?? 0
            )

        case "write_clipboard":
            let text = try boundedText(input.text, action: action)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw DesktopControlError.operationFailed("macOS refused to write plain text to the clipboard.")
            }
            return DesktopRunOutput(action: action, summary: "Wrote \(text.count) character(s) to the clipboard.", count: text.count)

        case "open":
            try await openTarget(input, context: context)
            return DesktopRunOutput(action: action, summary: "Opened the requested URL or file.")

        case "wait":
            let duration = try boundedDouble(
                input.duration ?? { throw DesktopControlError.missingArgument("duration", action) }(),
                name: "duration",
                range: 0...30
            )
            let started = Date()
            try await Task.sleep(for: .seconds(duration))
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            return DesktopRunOutput(action: action, summary: "Waited \(format(duration)) second(s).", elapsed_ms: elapsed)

        default:
            throw DesktopControlError.invalidAction(action)
        }
    }
}
