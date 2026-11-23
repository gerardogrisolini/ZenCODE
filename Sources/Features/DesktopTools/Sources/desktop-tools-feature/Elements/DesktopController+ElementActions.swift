import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ToolCore

/// Element actions and input feedback for desktop.run.
extension DesktopController {

    // MARK: list_elements

    static func listElements(_ input: DesktopRunInput, action: String) throws -> DesktopRunOutput {
        try requireAccessibility()
        prepareAXMessaging()
        guard input.element_ref?.nilIfBlank == nil else {
            throw DesktopControlError.invalidArgument("element_ref", "is not used by list_elements; select the window with window_id, pid, bundle_id, or app_name.")
        }
        let limit = try boundedInteger(input.limit ?? 100, name: "limit", range: 1...200)
        let maxDepth = try boundedInteger(input.max_depth ?? 30, name: "max_depth", range: 1...60)
        let roleFilter = try DesktopElementPolicy.normalizedRoleFilter(input.role)
        let query = try DesktopElementPolicy.validatedQuery(input.query)
        let (scope, window) = elementScope(for: try elementWindowSelection(input))
        let visit = visitElements(
            in: scope, maxDepth: maxDepth, interactiveOnly: input.interactive_only ?? true,
            roleFilter: roleFilter, query: query, limit: limit
        )
        var notes: [String] = []
        if scope.hostsZen {
            notes.append("\(scope.appLabel) hosts this zen session: these elements belong to zen's own window, not to the app you may want to control. Select the target with app_name, bundle_id, pid, or window_id.")
        }
        if let budgetNote = visit.budgetNote { notes.append(budgetNote) }
        if visit.stoppedByLimit {
            notes.append("Stopped at limit \(limit); more elements may exist. Narrow the list with query or role, or raise limit.")
        }
        if visit.unresponsiveNodes > 0 {
            notes.append(DesktopElementPolicy.unresponsiveNote(appName: scope.appLabel, nodes: visit.unresponsiveNodes))
        }
        if visit.matches.contains(where: { $0.info.ref == nil }) {
            notes.append("Some elements have no element_ref because their window could not be anchored; target them by query or coordinates.")
        }
        let elements = visit.matches.map(\.info)
        return DesktopRunOutput(
            action: action,
            summary: "Listed \(elements.count) element(s) in \(scope.phrase).",
            window: window,
            count: elements.count,
            note: notes.isEmpty ? nil : notes.joined(separator: " "),
            elements: elements
        )
    }

    // MARK: press_element, focus_element, set_value

    /// The way out when an element cannot be pressed or focused: a targeted
    /// click, which applies the same host protection.
    static let clickByReferenceHint = "click with the same element_ref (keeping any pid, bundle_id, or app_name you passed)"

    static func pressElement(_ input: DesktopRunInput, action: String) async throws -> DesktopRunOutput {
        let target = try resolveElementTarget(input, action: action)
        try enforceHostPolicy(targetPID: target.pid, input: input, kind: .pressElement)
        let available = target.info.actions ?? []
        guard let pressAction = DesktopElementPolicy.pressActions.first(where: available.contains) else {
            throw DesktopControlError.operationFailed(
                "\(target.phrase) exposes no AXPress, AXConfirm, or AXPick action; use \(clickByReferenceHint) instead."
            )
        }
        let result = AXUIElementPerformAction(target.element, pressAction as CFString)
        var note: String?
        switch result {
        case .success:
            break
        case .cannotComplete:
            // A timeout usually means the action opened something modal: it
            // may have been applied, so do not let the model retry blindly.
            note = "\(pressAction) did not confirm completion before the Accessibility timeout; the app may be busy or showing a dialog. Check its state before retrying."
        default:
            throw DesktopControlError.accessibilityFailed("press element (\(pressAction))", result)
        }
        try await Task.sleep(for: .milliseconds(150))
        let after = describeElement(target.element, scope: target.scope, path: target.path)
        if after == nil {
            note = [note, "The element no longer exists after the action (for example, its window or menu closed)."]
                .compactMap { $0 }.joined(separator: " ")
        }
        return DesktopRunOutput(
            action: action,
            summary: "Performed \(pressAction) on \(target.phrase).",
            note: note,
            element: after
        )
    }

    static func focusElementAction(_ input: DesktopRunInput, action: String) async throws -> DesktopRunOutput {
        let target = try resolveElementTarget(input, action: action)
        try enforceHostPolicy(targetPID: target.pid, input: input, kind: .focusElement)
        let method = try await focusResolvedElement(target)
        let after = describeElement(target.element, scope: target.scope, path: target.path) ?? target.info
        return DesktopRunOutput(
            action: action,
            summary: "Focused \(target.phrase) via \(method).",
            element: after,
            focused_element: describeFocusedElement(of: target.pid)?.info,
            focus_method: method
        )
    }

    static func setElementValue(_ input: DesktopRunInput, action: String) async throws -> DesktopRunOutput {
        let text = try boundedText(input.text, action: action)
        let target = try resolveElementTarget(input, action: action)
        try enforceHostPolicy(targetPID: target.pid, input: input, kind: .setValue)
        guard target.info.value_settable == true else {
            throw DesktopControlError.operationFailed(
                "\(target.phrase) has no settable AXValue; use focus_element then type_text."
            )
        }
        let secure = DesktopElementPolicy.isSecure(role: target.info.role, subrole: target.info.subrole)
        // Secure fields are never read, before or after the write.
        let before = secure ? nil : readElementValue(target.element)
        let result = AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, text as CFString)
        var note: String?
        switch result {
        case .success:
            break
        case .cannotComplete:
            // The app did not answer in time: the write may have been applied,
            // so it is neither an error nor confirmed. Like press_element.
            note = DesktopElementPolicy.valueUnconfirmedNote
        default:
            throw DesktopControlError.accessibilityFailed("set value", result)
        }
        if !secure, result == .success {
            let after = try await valueAfterWrite(of: target.element, requested: text, before: before)
            switch DesktopElementPolicy.setValueOutcome(requested: text, before: before, after: after) {
            case .applied:
                break
            case .notApplied:
                throw DesktopControlError.operationFailed(
                    DesktopElementPolicy.valueNotAppliedMessage(element: target.phrase)
                )
            case let .changed(readBack):
                note = DesktopElementPolicy.changedValueNote(element: DesktopElementPolicy.describe(target.info), readBack: readBack)
            }
        }
        return DesktopRunOutput(
            action: action,
            summary: "Set the value of \(target.phrase) (\(text.count) character(s))\(secure ? "; secure fields are not read back" : "").",
            count: text.count,
            note: note,
            element: describeElement(target.element, scope: target.scope, path: target.path) ?? target.info
        )
    }

    static func readElementValue(_ element: AXUIElement) -> String? {
        DesktopElementPolicy.textValue(copyAXRaw(element, attribute: kAXValueAttribute as CFString))
    }

    /// The value of an element after a write. Some apps apply the value a
    /// moment later, so while it still reads back as before (and not as
    /// requested) it is re-read every 75 ms, for up to 0.5 s; the last value
    /// read is returned and judged by `setValueOutcome`.
    static func valueAfterWrite(of element: AXUIElement, requested: String, before: String?) async throws -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: DesktopElementPolicy.setValueReadBackBudget)
        var after = readElementValue(element)
        while DesktopElementPolicy.setValueOutcome(requested: requested, before: before, after: after) == .notApplied,
              clock.now < deadline {
            try await Task.sleep(for: DesktopElementPolicy.setValueReadBackInterval)
            after = readElementValue(element)
        }
        return after
    }

    // MARK: click, scroll, and drag

    static func clickAction(_ input: DesktopRunInput, action: String) async throws -> DesktopRunOutput {
        try requireEventPosting()
        let mouseButton = try parseMouseButton(input.button)
        let clickCount = try boundedInteger(input.click_count ?? 1, name: "click_count", range: 1...3)
        if hasElementSelectors(input) {
            guard input.x == nil, input.y == nil else {
                throw DesktopControlError.invalidArgument("x/y", "must be omitted when element_ref or query selects the click target.")
            }
            return try await clickElement(input, action: action, button: mouseButton, count: clickCount)
        }

        var destination: CGPoint?
        if input.x != nil || input.y != nil {
            let point = try requiredPoint(x: input.x, y: input.y, action: action)
            try validateDesktopPoint(point, argument: "x/y")
            destination = point
        }
        let duration = try movementDuration(input.duration)
        let hit = hitTest(at: destination ?? currentPointerLocation())
        if let destination {
            try movePointer(to: destination, duration: duration)
        }
        try click(button: mouseButton, count: clickCount)
        let focused = try await focusedElementAfterClick()
        let location = pointer()
        return DesktopRunOutput(
            action: action,
            summary: "Performed \(clickCount) \(mouseButton.name) click(s) at (\(format(location.x)), \(format(location.y)))"
                + (hit.map { " on " + $0.phrase } ?? "") + ".",
            pointer: location,
            count: clickCount,
            note: hit.flatMap { hostLandingNote(for: $0, event: .click) },
            element: hit?.info,
            focused_element: focused?.info
        )
    }

    /// A click aimed at an element. Unlike a coordinate click, it is refused
    /// for the app hosting zen unless that app is selected exactly, and it is
    /// sent only when the element itself is under its center.
    static func clickElement(
        _ input: DesktopRunInput, action: String, button: MouseButtonDefinition, count: Int
    ) async throws -> DesktopRunOutput {
        let target = try resolveElementTarget(input, action: action)
        try enforceHostPolicy(targetPID: target.pid, input: input, kind: .clickElement)
        guard let center = target.info.center else {
            throw DesktopControlError.operationFailed("\(target.phrase) has no on-screen frame to click.")
        }
        let point = CGPoint(x: center.x, y: center.y)
        try validateElementPoint(point, target: target)
        try await bringToFront(target, purpose: "clicking")
        try await ensureTopmost(at: point, target: target)
        try movePointer(to: point, duration: try movementDuration(input.duration))
        try click(button: button, count: count)
        let focused = try await focusedElementAfterClick()
        return DesktopRunOutput(
            action: action,
            summary: "Performed \(count) \(button.name) click(s) on \(target.phrase) at (\(format(point.x)), \(format(point.y))).",
            pointer: pointer(),
            count: count,
            element: target.info,
            focused_element: focused?.info
        )
    }

    static func scrollAction(_ input: DesktopRunInput, action: String) throws -> DesktopRunOutput {
        try DesktopElementPolicy.validatePointerAction(action, elementRef: input.element_ref, query: input.query)
        try requireEventPosting()
        let dx = try boundedScroll(input.delta_x ?? 0, name: "delta_x")
        let dy = try boundedScroll(input.delta_y ?? 0, name: "delta_y")
        guard dx != 0 || dy != 0 else {
            throw DesktopControlError.invalidArgument("delta_x/delta_y", "at least one scroll amount must be non-zero.")
        }
        let unit = try parseScrollUnit(input.scroll_unit)
        var destination: CGPoint?
        if input.x != nil || input.y != nil {
            let point = try requiredPoint(x: input.x, y: input.y, action: action)
            try validateDesktopPoint(point, argument: "x/y")
            destination = point
        }
        let duration = try movementDuration(input.duration)
        let hit = hitTest(at: destination ?? currentPointerLocation())
        var location = ""
        if let destination {
            try movePointer(to: destination, duration: duration)
            location = " at (\(format(destination.x)), \(format(destination.y)))"
        }
        try postScroll(deltaX: dx, deltaY: dy, unit: unit)
        return DesktopRunOutput(
            action: action,
            summary: "Scrolled by (\(dx), \(dy)) \(unit.name) unit(s)\(location)\(hit.map { " on " + $0.phrase } ?? ""); the pointer is at the scroll location.",
            pointer: pointer(),
            note: hit.flatMap { hostLandingNote(for: $0, event: .scroll) },
            element: hit?.info
        )
    }

    /// Drags between two points and reports the element under the
    /// destination, read before any event is posted; never refused.
    static func dragAction(_ input: DesktopRunInput, action: String) throws -> DesktopRunOutput {
        try DesktopElementPolicy.validatePointerAction(action, elementRef: input.element_ref, query: input.query)
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
        let duration = try movementDuration(input.duration)
        let hit = hitTest(at: destination)
        try dragPointer(from: start, to: destination, duration: duration, button: mouseButton)
        return DesktopRunOutput(
            action: action,
            summary: "Dragged the \(mouseButton.name) button to (\(format(destination.x)), \(format(destination.y)))"
                + (hit.map { " onto " + $0.phrase } ?? "") + ".",
            pointer: pointer(),
            note: hit.flatMap { hostLandingNote(for: $0, event: .drag) },
            element: hit?.info
        )
    }

    static func focusedElementAfterClick() async throws -> ResolvedElement? {
        guard AXIsProcessTrusted() else { return nil }
        try await Task.sleep(for: .milliseconds(150))
        return describeSystemFocusedElement()
    }

    static func hostLandingNote(for element: ResolvedElement, event: DesktopHostInputPolicy.LandingEvent) -> String? {
        guard element.scope.hostsZen else { return nil }
        return DesktopHostInputPolicy.landingNote(event, appName: element.scope.appLabel)
    }

    // MARK: type_text and press_key

    static func typeTextAction(_ input: DesktopRunInput, action: String) async throws -> DesktopRunOutput {
        let text = try boundedText(input.text, action: action)
        let interval = try boundedDouble(input.interval ?? 0.01, name: "interval", range: 0...1)
        try DesktopSafetyPolicy.validateTypingBudget(characterCount: text.count, interval: interval)
        try requireEventPosting()

        if hasElementSelectors(input) {
            let target = try resolveElementTarget(input, action: action)
            try enforceHostPolicy(targetPID: target.pid, input: input, kind: .typeIntoElement)
            let method = try await focusResolvedElement(target)
            let focused = describeFocusedElement(of: target.pid)
            try typeText(text, interval: interval, focusCheck: keyboardFocusCheck(
                expectedPID: target.pid, appName: target.scope.appLabel, input: .typing(total: text.count)
            ))
            return DesktopRunOutput(
                action: action,
                summary: "Typed \(text.count) character(s) into \(DesktopElementPolicy.describe(target.info)) of \(target.scope.appLabel) (focused via \(method)).",
                count: text.count,
                element: describeElement(target.element, scope: target.scope, path: target.path) ?? target.info,
                focused_element: focused?.info ?? target.info,
                focus_method: method
            )
        }

        let receiver = try await keyboardReceiver(input, purpose: "typing", kind: .typeText)
        let focused = receiver.flatMap { describeFocusedElement(of: $0.pid) }
        try typeText(text, interval: interval, focusCheck: receiver.flatMap { receiver in
            keyboardFocusCheck(expectedPID: receiver.pid, appName: receiver.name, input: .typing(total: text.count))
        })
        return DesktopRunOutput(
            action: action,
            summary: "Typed \(text.count) character(s) into \(keyboardTargetPhrase(receiver: receiver, focused: focused)).",
            count: text.count,
            focused_element: focused?.info
        )
    }

    static func pressKeyAction(_ input: DesktopRunInput, action: String) async throws -> DesktopRunOutput {
        try requireEventPosting()
        guard !hasElementSelectors(input) else {
            throw DesktopControlError.invalidArgument(
                "element_ref/query", "press_key does not target elements; call focus_element first, then press_key."
            )
        }
        let key = try requiredNonempty(input.key, name: "key", action: action)
        let repeatCount = try boundedInteger(input.repeat_count ?? 1, name: "repeat_count", range: 1...100)
        let interval = try boundedDouble(input.interval ?? 0.05, name: "interval", range: 0...1)
        let flags = try modifierFlags(input.modifiers ?? [])
        // Resolve the key before activating anything, so a bad key sends no input.
        _ = try DesktopKeyResolver.resolve(key, translator: CarbonKeyTranslator())
        let receiver = try await keyboardReceiver(input, purpose: "pressing keys", kind: .pressKey)
        let focused = receiver.flatMap { describeFocusedElement(of: $0.pid) }
        try pressKey(key, modifiers: flags, repeatCount: repeatCount, interval: interval, focusCheck: receiver.flatMap { receiver in
            keyboardFocusCheck(expectedPID: receiver.pid, appName: receiver.name, input: .keyPresses(total: repeatCount))
        })
        return DesktopRunOutput(
            action: action,
            summary: "Pressed key '\(key)' \(repeatCount) time(s) in \(keyboardTargetPhrase(receiver: receiver, focused: focused)).",
            count: repeatCount,
            focused_element: focused?.info
        )
    }

    struct KeyboardReceiver {
        let pid: pid_t
        let name: String
    }

    /// The app that will receive keyboard input, checked against the host
    /// policy before anything is activated or sent. Explicit app or window
    /// selectors activate that app (and raise the window) first, and
    /// activation failure throws before any input. Otherwise it is the app
    /// with the keyboard focus: the focused application from Accessibility
    /// (NSWorkspace can be stale in this one-shot worker), and only without
    /// Accessibility the frontmost app.
    static func keyboardReceiver(
        _ input: DesktopRunInput, purpose: String, kind: DesktopHostInputPolicy.Kind
    ) async throws -> KeyboardReceiver? {
        func receiver(_ pid: pid_t) -> KeyboardReceiver {
            KeyboardReceiver(pid: pid, name: applicationName(of: pid))
        }

        if hasAppSelectors(input) || hasWindowSelectors(input) {
            var window: AXWindowSelection?
            let app: NSRunningApplication
            if hasWindowSelectors(input) {
                let selection = try selectedAXWindow(input)
                guard let owner = NSRunningApplication(processIdentifier: selection.pid) else { throw DesktopControlError.appNotFound }
                window = selection
                app = owner
            } else {
                guard let owner = matchingRunningApp(input, defaultToFrontmost: false) else { throw DesktopControlError.appNotFound }
                app = owner
            }
            let name = app.localizedName ?? app.bundleIdentifier ?? "the selected application"
            try enforceHostPolicy(targetPID: app.processIdentifier, input: input, kind: kind)
            guard try await activateApplication(app) != nil else {
                throw DesktopControlError.operationFailed(
                    "Could not activate \(name) before \(purpose); no input was sent."
                        + (AXIsProcessTrusted() ? "" : " Granting Accessibility permission lets desktop.run use a fallback.")
                )
            }
            if let window {
                let raise = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                guard raise == .success else {
                    throw DesktopControlError.operationFailed(
                        "Could not raise the selected window of \(name) before \(purpose) (AXError \(raise.rawValue)); no input was sent."
                    )
                }
                _ = AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            return receiver(app.processIdentifier)
        }

        let pid: pid_t?
        if AXIsProcessTrusted() {
            // With Accessibility the focused app comes from Accessibility only:
            // NSWorkspace can be stale in this one-shot worker, so an error
            // here sends nothing (the host protection could not be applied).
            prepareAXMessaging()
            guard let focusedPID = systemFocusedApplicationPID() else {
                throw DesktopControlError.operationFailed(
                    "Could not read which application has the keyboard focus (Accessibility did not answer), so no input was sent. Retry, or select the target with pid, bundle_id, app_name, or window_id, or move the focus with focus_element."
                )
            }
            pid = focusedPID
        } else {
            // Without Accessibility there is nothing else to ask.
            pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        try enforceHostPolicy(targetPID: pid, input: input, kind: kind)
        return pid.map(receiver)
    }

    static func keyboardTargetPhrase(receiver: KeyboardReceiver?, focused: ResolvedElement?) -> String {
        let control = focused.map { DesktopElementPolicy.describe($0.info) } ?? "the focused control"
        guard let receiver else { return control }
        return "\(control) of \(receiver.name)"
    }

    /// The re-check run right before keyboard input and while it is sent (before
    /// the first character, every 20 characters, before every line break or tab,
    /// and before every key press): it stops the input when the focused
    /// application is no longer `expectedPID`, including when Accessibility
    /// cannot tell. Nil without Accessibility, which keeps the unchecked behavior.
    static func keyboardFocusCheck(
        expectedPID: pid_t, appName: String, input: DesktopKeyboardFocusPolicy.Input
    ) -> KeyboardFocusCheck? {
        guard AXIsProcessTrusted() else { return nil }
        prepareAXMessaging()
        return { sent in
            let focusedPID = keyboardFocusPID()
            guard focusedPID != expectedPID else { return }
            let focus = DesktopKeyboardFocusPolicy.focusPhrase(
                appName: focusedPID.map(applicationName(of:)),
                element: focusedPID.flatMap(focusedUIElement(of:)).flatMap(briefDescription(of:))
            )
            throw DesktopControlError.operationFailed(DesktopKeyboardFocusPolicy.focusLostMessage(
                input: input, sent: sent, expectedApp: appName, focus: focus
            ))
        }
    }

    // MARK: Host protection

    /// Refuses input into the app hosting zen unless pid, bundle_id, or the
    /// exact app_name select it; a partial app_name, element_ref, query,
    /// title, and window_id do not count.
    static func enforceHostPolicy(targetPID: pid_t?, input: DesktopRunInput, kind: DesktopHostInputPolicy.Kind) throws {
        guard let host = DesktopHostApplication.current() else { return }
        let selection = hasAppSelectors(input)
            ? matchingRunningApp(input, defaultToFrontmost: false).map { app in
                DesktopHostInputPolicy.Selection(
                    pid: app.processIdentifier,
                    isExact: DesktopHostInputPolicy.isExactSelection(
                        pid: input.pid, bundleID: input.bundle_id, appName: input.app_name,
                        appPID: app.processIdentifier, appBundleID: app.bundleIdentifier,
                        appLocalizedName: app.localizedName
                    )
                )
            }
            : nil
        switch DesktopHostInputPolicy.decide(targetPID: targetPID, hostPID: host.pid, selection: selection) {
        case .allow:
            return
        case .refuse:
            throw DesktopControlError.operationFailed(DesktopHostInputPolicy.refusalMessage(kind, appName: host.name))
        case .refuseInexactSelection:
            throw DesktopControlError.operationFailed(DesktopHostInputPolicy.inexactSelectionMessage(
                kind, appName: host.name, selector: input.app_name?.nilIfBlank ?? ""
            ))
        }
    }

    // MARK: Focus

    /// Moves keyboard focus to the element: activate its app, raise its window,
    /// set AXFocused, and verify. A single click at its center is the only
    /// fallback, and only for text-entry elements (text fields, text areas,
    /// combo boxes, search and secure fields) that are under their own center.
    /// Returns "accessibility" or "click".
    static func focusResolvedElement(_ target: ResolvedElement) async throws -> String {
        try await bringToFront(target, purpose: "moving the keyboard focus")
        _ = AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if try await waitForKeyboardFocus(target) { return "accessibility" }

        guard DesktopElementPolicy.allowsFocusClickFallback(role: target.info.role, subrole: target.info.subrole) else {
            throw DesktopControlError.operationFailed(
                "Could not move keyboard focus to \(target.phrase) through Accessibility; the click fallback is used only on text fields, text areas, combo boxes, and search or secure fields, since on other elements a click would activate or change them. Nothing was typed or clicked. To activate it, use press_element or \(clickByReferenceHint)."
            )
        }
        guard let center = target.info.center else {
            throw focusFailure(target, reason: "it has no on-screen frame for the click fallback")
        }
        let point = CGPoint(x: center.x, y: center.y)
        try validateElementPoint(point, target: target)
        try await ensureTopmost(at: point, target: target)
        try requireEventPosting()
        try movePointer(to: point, duration: 0)
        try click(button: try parseMouseButton("left"), count: 1)
        try await Task.sleep(for: .milliseconds(150))
        if try await waitForKeyboardFocus(target) { return "click" }
        throw focusFailure(target, reason: "neither Accessibility nor a click at its center moved the keyboard focus there")
    }

    static func waitForKeyboardFocus(_ target: ResolvedElement, budget: Double = 0.5) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(budget))
        while true {
            if hasKeyboardFocus(target) { return true }
            guard clock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    static func focusFailure(_ target: ResolvedElement, reason: String) -> DesktopControlError {
        .operationFailed(
            "Could not move keyboard focus to \(target.phrase): \(reason); nothing was typed. Inspect the window with list_elements or a screenshot."
        )
    }

    /// Activates the element's app, then raises its window. A regular app that
    /// does not become active is an error before any input; the raise is best
    /// effort, since the hit test and the focus check verify the outcome. Apps
    /// that are not regular (Control Center, menu bar popovers, the Dock) may
    /// never report themselves active: activation is only requested, not
    /// required, and the hit test and the focus check decide.
    static func bringToFront(_ target: ResolvedElement, purpose: String) async throws {
        let failure = "Could not activate \(target.scope.appLabel) before \(purpose); no input was sent."
        guard let app = NSRunningApplication(processIdentifier: target.pid), !app.isTerminated else {
            throw DesktopControlError.operationFailed(failure + " The app is no longer running.")
        }
        if app.activationPolicy == .regular {
            let probe: DesktopAppProbe?
            do {
                probe = try await activateApplication(app)
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                throw DesktopControlError.operationFailed(failure + " " + error.localizedDescription)
            }
            guard probe != nil else { throw DesktopControlError.operationFailed(failure) }
        } else {
            _ = app.activate(options: [])
        }
        if let window = target.scope.window {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    static func validateElementPoint(_ point: CGPoint, target: ResolvedElement) throws {
        guard DesktopSafetyPolicy.contains(point, displays: displayBounds()) else {
            throw DesktopControlError.operationFailed(
                "The center of \(target.phrase) lies outside all attached displays; scroll it into view or move its window, then retry."
            )
        }
    }

    /// Refuses to click unless the element under `point` is the target or one
    /// of its descendants (Accessibility hit test). When the hit test is not
    /// available or fails, the front-most normal window (layer 0) at `point`
    /// must belong to the target's app. A refusal is retried up to
    /// `DesktopElementPolicy.topmostAttempts` times, 100 ms apart, since a window
    /// that is still coming forward or a transient overlay may be in the way.
    static func ensureTopmost(at point: CGPoint, target: ResolvedElement) async throws {
        for attempt in 1...DesktopElementPolicy.topmostAttempts {
            guard let failure = topmostFailure(at: point, target: target) else { return }
            if attempt == DesktopElementPolicy.topmostAttempts { throw failure }
            try await Task.sleep(for: DesktopElementPolicy.topmostRetryDelay)
        }
    }

    /// One hit test: nil when `target` is under `point`, else why it is not.
    private static func topmostFailure(at point: CGPoint, target: ResolvedElement) -> DesktopControlError? {
        let location = "(\(format(point.x)), \(format(point.y)))"
        if let hit = elementAtPoint(point) {
            guard !isElement(hit, sameAsOrBelow: target.element) else { return nil }
            return .operationFailed(DesktopElementPolicy.coveredMessage(
                target: target.phrase,
                point: location,
                cover: briefDescription(of: hit) ?? "another element",
                coverApp: elementPID(hit).map(applicationName(of:)) ?? "an application that could not be identified",
                targetApp: target.scope.appLabel
            ))
        }
        guard let top = DesktopElementPolicy.topmostWindow(at: point, in: stackedWindows()) else {
            return .operationFailed(
                "No visible window is under the center of \(target.phrase); no click was sent. Bring \(target.scope.appLabel) to the front with activate_app or focus_window, then retry."
            )
        }
        guard top.pid == target.pid else {
            return .operationFailed(DesktopElementPolicy.coveredMessage(
                target: target.phrase,
                point: location,
                cover: "a window",
                coverApp: top.appName ?? applicationName(of: top.pid),
                targetApp: target.scope.appLabel
            ))
        }
        return nil
    }
}
