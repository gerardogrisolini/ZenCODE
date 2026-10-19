//  Created by Gerardo Grisolini on 30/05/26.
//
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ToolCore

extension DesktopController {
    static func windowRecords(onScreenOnly: Bool, matching input: DesktopRunInput) -> [DesktopWindowInfo] {
        let options: CGWindowListOption = onScreenOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]
        guard let dictionaries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        let appsByPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { ($0.processIdentifier, $0) })

        return dictionaries.compactMap { dictionary in
            guard let number = (dictionary[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (dictionary[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (dictionary[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let boundsDictionary = dictionary[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width > 1,
                  bounds.height > 1 else {
                return nil
            }

            let app = appsByPID[pid]
            let appName = (dictionary[kCGWindowOwnerName as String] as? String) ?? app?.localizedName
            let bundleID = app?.bundleIdentifier
            let title = (dictionary[kCGWindowName as String] as? String)?.nilIfBlank
            let onScreen = (dictionary[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let alpha = (dictionary[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1

            if let selectorPID = input.pid, selectorPID != pid { return nil }
            if let selectorBundle = input.bundle_id?.nilIfBlank,
               bundleID?.caseInsensitiveCompare(selectorBundle) != .orderedSame { return nil }
            if let selectorApp = input.app_name?.nilIfBlank,
               appName?.localizedCaseInsensitiveContains(selectorApp) != true { return nil }
            if let selectorTitle = input.title?.nilIfBlank,
               title?.localizedCaseInsensitiveContains(selectorTitle) != true { return nil }
            if let selectorID = input.window_id, selectorID != number { return nil }

            return DesktopWindowInfo(
                window_id: number,
                pid: pid,
                app_name: appName,
                bundle_id: bundleID,
                title: title,
                bounds: DesktopRect(bounds),
                layer: layer,
                is_on_screen: onScreen,
                alpha: alpha,
                is_focused: nil,
                is_minimized: onScreenOnly ? false : nil,
                is_fullscreen: nil
            )
        }
    }

    static func selectedQuartzWindow(_ input: DesktopRunInput) throws -> DesktopWindowInfo {
        try DesktopSafetyPolicy.validateSelectors(windowID: input.window_id, windowIndex: input.window_index)
        let records: [DesktopWindowInfo]
        if input.window_id != nil
            || input.pid != nil || input.bundle_id?.nilIfBlank != nil || input.app_name?.nilIfBlank != nil || input.title?.nilIfBlank != nil {
            records = windowRecords(onScreenOnly: false, matching: input)
        } else if let frontmost = NSWorkspace.shared.frontmostApplication {
            var copy = input
            copy.pid = frontmost.processIdentifier
            records = windowRecords(onScreenOnly: false, matching: copy)
        } else {
            records = []
        }
        let index = try boundedInteger(input.window_index ?? 0, name: "window_index", range: 0...500)
        guard records.indices.contains(index) else { throw DesktopControlError.windowNotFound }
        return records[index]
    }


    struct AXWindowSelection {
        let element: AXUIElement
        let pid: pid_t
        let expected: DesktopWindowInfo?
    }

    struct AXWindowCandidate {
        let element: AXUIElement
        let title: String?
        let frame: CGRect?
        var identity: DesktopSafetyPolicy.WindowIdentity { .init(title: title, frame: frame) }
    }

    static func selectedAXWindow(_ input: DesktopRunInput) throws -> AXWindowSelection {
        try DesktopSafetyPolicy.validateSelectors(windowID: input.window_id, windowIndex: input.window_index)
        try requireAccessibility()

        let expected = input.window_id == nil ? nil : windowRecords(onScreenOnly: false, matching: input).first
        let pid = try DesktopWindowSelectionPolicy.selectedProcessID(
            requestedWindowID: input.window_id,
            matchingWindowPID: expected?.pid,
            fallbackProcessID: {
                matchingRunningApp(input, defaultToFrontmost: true)?.processIdentifier
            }
        )

        let application = AXUIElementCreateApplication(pid)
        var rawWindows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows)
        guard result == .success else {
            throw DesktopControlError.accessibilityFailed("read application windows", result)
        }
        guard let elements = rawWindows as? [AXUIElement] else {
            throw DesktopControlError.windowNotFound
        }

        var candidates = elements.map { element in
            AXWindowCandidate(element: element, title: copyAXString(element, attribute: kAXTitleAttribute as CFString), frame: axFrame(element))
        }

        if let title = input.title?.nilIfBlank {
            candidates = candidates.filter { $0.title?.localizedCaseInsensitiveContains(title) == true }
        }

        if let expected {
            let identity = windowIdentity(expected)
            let index = try DesktopSafetyPolicy.uniqueMatch(candidates.map(\.identity), expected: identity)
            // Check the reverse association too: one AX element can otherwise
            // appear unique when Quartz exposes two indistinguishable windows.
            let quartz = windowRecords(onScreenOnly: false, matching: DesktopRunInput(action: "list_windows", pid: pid))
            let quartzIndex = try DesktopSafetyPolicy.uniqueMatch(quartz.map(windowIdentity), expected: candidates[index].identity)
            guard quartz[quartzIndex].window_id == expected.window_id else {
                throw DesktopControlError.windowNotFound
            }
            return AXWindowSelection(element: candidates[index].element, pid: pid, expected: expected)
        }

        let index = try boundedInteger(input.window_index ?? 0, name: "window_index", range: 0...500)
        guard candidates.indices.contains(index) else { throw DesktopControlError.windowNotFound }
        return AXWindowSelection(element: candidates[index].element, pid: pid, expected: expected)
    }

    static func windowIdentity(_ window: DesktopWindowInfo) -> DesktopSafetyPolicy.WindowIdentity {
        .init(title: window.title, frame: CGRect(x: window.bounds.x, y: window.bounds.y,
                                               width: window.bounds.width, height: window.bounds.height))
    }

    static func axWindowInfo(_ selection: AXWindowSelection) -> DesktopWindowInfo {
        let frame = axFrame(selection.element) ?? .zero
        let app = NSRunningApplication(processIdentifier: selection.pid)
        let title = copyAXString(selection.element, attribute: kAXTitleAttribute as CFString)
        let records = windowRecords(
            onScreenOnly: false,
            matching: DesktopRunInput(action: "list_windows", pid: selection.pid)
        )
        let index = try? DesktopSafetyPolicy.uniqueMatch(
            records.map(windowIdentity), expected: .init(title: title, frame: axFrame(selection.element))
        )
        let matchedWindow = index.map { records[$0] }
        var verifiedWindowID: UInt32?
        if let matchedWindow {
            let application = AXUIElementCreateApplication(selection.pid)
            var rawWindows: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &rawWindows) == .success,
               let elements = rawWindows as? [AXUIElement] {
                let identities = elements.map {
                    DesktopSafetyPolicy.WindowIdentity(title: copyAXString($0, attribute: kAXTitleAttribute as CFString), frame: axFrame($0))
                }
                if let axIndex = try? DesktopSafetyPolicy.uniqueMatch(identities, expected: windowIdentity(matchedWindow)),
                   CFEqual(elements[axIndex], selection.element) {
                    verifiedWindowID = matchedWindow.window_id
                }
            }
        }

        return DesktopWindowInfo(
            window_id: verifiedWindowID,
            pid: selection.pid,
            app_name: app?.localizedName ?? matchedWindow?.app_name,
            bundle_id: app?.bundleIdentifier ?? matchedWindow?.bundle_id,
            title: title ?? matchedWindow?.title,
            bounds: DesktopRect(frame),
            layer: matchedWindow?.layer ?? 0,
            is_on_screen: matchedWindow?.is_on_screen ?? !(copyAXBoolean(selection.element, attribute: kAXMinimizedAttribute as CFString) ?? false),
            alpha: matchedWindow?.alpha ?? 1,
            is_focused: copyAXBoolean(selection.element, attribute: kAXFocusedAttribute as CFString),
            is_minimized: copyAXBoolean(selection.element, attribute: kAXMinimizedAttribute as CFString),
            is_fullscreen: copyAXBoolean(selection.element, attribute: axFullScreenAttribute)
        )
    }

    static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let point = copyAXPoint(element, attribute: kAXPositionAttribute as CFString),
              let size = copyAXSize(element, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }
        return CGRect(origin: point, size: size)
    }

    static func copyAXRaw(_ element: AXUIElement, attribute: CFString) -> CFTypeRef? {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute, &raw) == .success ? raw : nil
    }

    static func copyAXString(_ element: AXUIElement, attribute: CFString) -> String? {
        copyAXRaw(element, attribute: attribute) as? String
    }

    static func copyAXBoolean(_ element: AXUIElement, attribute: CFString) -> Bool? {
        (copyAXRaw(element, attribute: attribute) as? NSNumber)?.boolValue
    }

    static func copyAXValue(_ element: AXUIElement, attribute: CFString, type: AXValueType) -> AXValue? {
        guard let raw = copyAXRaw(element, attribute: attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        return AXValueGetType(value) == type ? value : nil
    }

    static func copyAXPoint(_ element: AXUIElement, attribute: CFString) -> CGPoint? {
        var point = CGPoint.zero
        guard let value = copyAXValue(element, attribute: attribute, type: .cgPoint) else { return nil }
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func copyAXSize(_ element: AXUIElement, attribute: CFString) -> CGSize? {
        var size = CGSize.zero
        guard let value = copyAXValue(element, attribute: attribute, type: .cgSize) else { return nil }
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    static func copyAXElement(_ element: AXUIElement, attribute: CFString, operation: String) throws -> AXUIElement {
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &raw)
        guard result == .success else {
            throw DesktopControlError.accessibilityFailed(operation, result)
        }
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw DesktopControlError.operationFailed("Accessibility did not return a usable element for '\(operation)'.")
        }
        return raw as! AXUIElement
    }

    static func setAXValue(
        _ element: AXUIElement, attribute: CFString, encoded: AXValue?, what: String, operation: String
    ) throws {
        guard let encoded else {
            throw DesktopControlError.operationFailed("Could not encode the requested window \(what).")
        }
        let result = AXUIElementSetAttributeValue(element, attribute, encoded)
        guard result == .success else { throw DesktopControlError.accessibilityFailed(operation, result) }
    }

    static func setAXBoolean(_ element: AXUIElement, attribute: CFString, value: Bool, operation: String) throws {
        let result = AXUIElementSetAttributeValue(element, attribute, value ? kCFBooleanTrue : kCFBooleanFalse)
        guard result == .success else { throw DesktopControlError.accessibilityFailed(operation, result) }
    }
}
