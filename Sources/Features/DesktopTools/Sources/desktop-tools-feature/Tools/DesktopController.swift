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
    static let maximumZoomLongEdge = 2000
    static let axFullScreenAttribute = "AXFullScreen" as CFString

    static func execute(_ input: DesktopRunInput, context: FeatureContext) async throws -> DesktopRunOutput {
        let normalized = input.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            throw DesktopControlError.invalidArgument("action", "must not be empty.")
        }
        guard let parsedAction = DesktopAction(rawValue: normalized) else {
            throw DesktopControlError.invalidAction(normalized)
        }
        let action = parsedAction.rawValue

        switch parsedAction {
        case .permissions:
            return DesktopRunOutput(action: action, summary: "Read macOS automation permissions.", permissions: permissions())

        case .requestPermissions:
            requestPermissions()
            return DesktopRunOutput(
                action: action,
                summary: "Requested macOS automation permissions.",
                permissions: permissions(),
                note: "Approve any macOS prompts for \(DesktopHostApplication.subject()). macOS may require quitting and reopening \(DesktopHostApplication.currentName() ?? "that app") before a permission change takes effect."
            )

        case .systemInfo:
            let info = DesktopSystemInfo(
                os_version: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: architectureName,
                process_id: ProcessInfo.processInfo.processIdentifier,
                displays: displays(),
                pointer: pointer(),
                frontmost_app: NSWorkspace.shared.frontmostApplication.map { appInfo($0) }
            )
            return DesktopRunOutput(action: action, summary: "Read macOS system, display, pointer, and frontmost-app state.", permissions: permissions(), system: info)

        case .listApps:
            let limit = try boundedInteger(input.limit ?? 100, name: "limit", range: 1...200)
            let apps = runningApps(matching: input).prefix(limit).map { appInfo($0) }
            return DesktopRunOutput(action: action, summary: "Listed \(apps.count) running application(s).", apps: Array(apps), count: apps.count)

        case .listWindows:
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

        case .screenshot:
            return try await screenshot(input, context: context, action: action)

        case .zoom:
            return try await zoom(input, context: context, action: action)

        case .moveMouse:
            try requireEventPosting()
            let destination = try moveToRequestedPoint(input, action: action)
            return DesktopRunOutput(action: action, summary: "Moved the pointer to (\(format(destination.x)), \(format(destination.y))).", pointer: pointer())

        case .click:
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

        case .drag:
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

        case .scroll:
            try requireEventPosting()
            let dx = try boundedScroll(input.delta_x ?? 0, name: "delta_x")
            let dy = try boundedScroll(input.delta_y ?? 0, name: "delta_y")
            guard dx != 0 || dy != 0 else {
                throw DesktopControlError.invalidArgument("delta_x/delta_y", "at least one scroll amount must be non-zero.")
            }
            let unit = try parseScrollUnit(input.scroll_unit)
            var location = ""
            if input.x != nil || input.y != nil {
                let target = try moveToRequestedPoint(input, action: action)
                location = " at (\(format(target.x)), \(format(target.y)))"
            }
            try postScroll(deltaX: dx, deltaY: dy, unit: unit)
            return DesktopRunOutput(action: action, summary: "Scrolled by (\(dx), \(dy)) \(unit.name) unit(s)\(location); the pointer is at the scroll location.", pointer: pointer())

        case .typeText:
            let text = try boundedText(input.text, action: action)
            let interval = try boundedDouble(input.interval ?? 0.01, name: "interval", range: 0...1)
            try DesktopSafetyPolicy.validateTypingBudget(characterCount: text.count, interval: interval)
            try requireEventPosting()
            try typeText(text, interval: interval)
            return DesktopRunOutput(action: action, summary: "Typed \(text.count) character(s) into the focused control.", count: text.count)

        case .pressKey:
            try requireEventPosting()
            let key = try requiredNonempty(input.key, name: "key", action: action)
            let repeatCount = try boundedInteger(input.repeat_count ?? 1, name: "repeat_count", range: 1...100)
            let interval = try boundedDouble(input.interval ?? 0.05, name: "interval", range: 0...1)
            let flags = try modifierFlags(input.modifiers ?? [])
            try pressKey(key, modifiers: flags, repeatCount: repeatCount, interval: interval)
            return DesktopRunOutput(action: action, summary: "Pressed key '\(key)' \(repeatCount) time(s).", count: repeatCount)

        case .launchApp:
            let app = try await launchApp(input, context: context)
            return DesktopRunOutput(action: action, summary: "Launched \(app.localizedName ?? app.bundleIdentifier ?? "application").", app: appInfo(app))

        case .activateApp:
            var app = matchingRunningApp(input, defaultToFrontmost: false)
            if app == nil, input.launch_if_needed ?? false {
                app = try await launchApp(input, context: context)
            }
            guard let app else { throw DesktopControlError.appNotFound }
            guard let activeProbe = try await activateApplication(app) else {
                throw DesktopControlError.operationFailed(
                    "The selected application did not become active before timeout."
                        + (AXIsProcessTrusted() ? "" : " Granting Accessibility permission lets desktop.run use a fallback.")
                )
            }
            return DesktopRunOutput(
                action: action,
                summary: "Activated \(app.localizedName ?? app.bundleIdentifier ?? "application").",
                app: appInfo(app, probe: activeProbe)
            )

        case .hideApp, .unhideApp:
            let hide = parsedAction == .hideApp
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

        case .terminateApp:
            let app = try selectedRunningApp(input, allowPartialName: false)
            let name = app.localizedName ?? app.bundleIdentifier ?? "application"
            let timeout = try boundedDouble(input.timeout ?? 5, name: "timeout", range: 0...30)
            let forced = input.force ?? false
            let accepted = forced ? app.forceTerminate() : app.terminate()
            guard accepted else {
                throw DesktopControlError.operationFailed("macOS refused to terminate the selected application.")
            }
            guard let finalProbe = try await waitForApplicationExit(pid: app.processIdentifier, timeout: timeout) else {
                throw DesktopControlError.operationFailed(
                    "Requested termination of \(name), but it is still running after \(format(timeout)) s; it may be asking to save changes or to confirm quitting. Take a screenshot to inspect it."
                )
            }
            return DesktopRunOutput(
                action: action,
                summary: forced ? "Force-terminated \(name)." : "Terminated \(name).",
                app: appInfo(app, probe: finalProbe)
            )

        case .focusWindow:
            let selection = try selectedAXWindow(input)
            if let app = NSRunningApplication(processIdentifier: selection.pid) {
                do { _ = try await activateApplication(app) } catch is CancellationError { throw CancellationError() } catch {}
            }
            let raiseResult = AXUIElementPerformAction(selection.element, kAXRaiseAction as CFString)
            guard raiseResult == .success else {
                throw DesktopControlError.accessibilityFailed("raise window", raiseResult)
            }
            _ = AXUIElementSetAttributeValue(selection.element, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(selection.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: "Focused the selected window.", window: window)

        case .moveWindow:
            let selection = try selectedAXWindow(input)
            var point = try requiredPoint(x: input.x, y: input.y, action: action)
            try setAXValue(selection.element, attribute: kAXPositionAttribute as CFString, encoded: AXValueCreate(.cgPoint, &point), what: "position", operation: "move window")
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: "Moved the selected window.", window: window)

        case .resizeWindow:
            let selection = try selectedAXWindow(input)
            let width = try positiveFinite(input.width, name: "width", action: action)
            let height = try positiveFinite(input.height, name: "height", action: action)
            var size = CGSize(width: width, height: height)
            try setAXValue(selection.element, attribute: kAXSizeAttribute as CFString, encoded: AXValueCreate(.cgSize, &size), what: "size", operation: "resize window")
            let window = axWindowInfo(selection)
            return DesktopRunOutput(action: action, summary: "Resized the selected window.", window: window)

        case .minimizeWindow, .setFullscreen:
            let selection = try selectedAXWindow(input)
            guard let state = input.state else {
                throw DesktopControlError.missingArgument("state", action)
            }
            let minimize = parsedAction == .minimizeWindow
            try setAXBoolean(
                selection.element,
                attribute: minimize ? kAXMinimizedAttribute as CFString : axFullScreenAttribute,
                value: state,
                operation: minimize ? "set minimized state" : "set fullscreen state"
            )
            try await waitForAXBoolean(
                selection.element,
                attribute: minimize ? kAXMinimizedAttribute as CFString : axFullScreenAttribute,
                expected: state,
                budget: minimize ? 2 : 3,
                failure: "The window did not reach the requested \(minimize ? (state ? "minimized" : "restored") : (state ? "fullscreen" : "windowed")) state before timeout."
            )
            let summary = minimize
                ? (state ? "Minimized the selected window." : "Restored the selected window.")
                : (state ? "Entered fullscreen for the selected window." : "Exited fullscreen for the selected window.")
            return DesktopRunOutput(action: action, summary: summary, window: axWindowInfo(selection))

        case .closeWindow:
            let selection = try selectedAXWindow(input)
            let before = axWindowInfo(selection)
            let closeButton = try copyAXElement(selection.element, attribute: kAXCloseButtonAttribute as CFString, operation: "read close button")
            let result = AXUIElementPerformAction(closeButton, kAXPressAction as CFString)
            guard result == .success else {
                throw DesktopControlError.accessibilityFailed("close window", result)
            }
            try await waitForWindowClosed(selection)
            return DesktopRunOutput(action: action, summary: "Closed the selected window.", window: before)

        case .readClipboard:
            let value = NSPasteboard.general.string(forType: .string)
            let bounded = value.map { DesktopSafetyPolicy.boundedClipboardText($0) }
            return DesktopRunOutput(
                action: action,
                summary: value == nil ? "The clipboard does not contain plain text." : "Read \(value?.count ?? 0) character(s) from the clipboard.",
                clipboard_text: bounded?.text,
                count: value?.count ?? 0,
                note: (bounded?.omittedCharacters ?? 0) > 0
                    ? "clipboard_text was truncated to \(DesktopSafetyPolicy.maximumClipboardTextCharacters) characters; \(bounded?.omittedCharacters ?? 0) character(s) were omitted."
                    : nil
            )

        case .writeClipboard:
            let text = try boundedText(input.text, action: action)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                throw DesktopControlError.operationFailed("macOS refused to write plain text to the clipboard.")
            }
            return DesktopRunOutput(action: action, summary: "Wrote \(text.count) character(s) to the clipboard.", count: text.count)

        case .open:
            try await openTarget(input, context: context)
            return DesktopRunOutput(action: action, summary: "Opened the requested URL or file.")

        case .wait:
            let duration = try boundedDouble(
                input.duration ?? { throw DesktopControlError.missingArgument("duration", action) }(),
                name: "duration",
                range: 0...30
            )
            let started = Date()
            try await Task.sleep(for: .seconds(duration))
            let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
            return DesktopRunOutput(action: action, summary: "Waited \(format(duration)) second(s).", elapsed_ms: elapsed)
        }
    }
}
