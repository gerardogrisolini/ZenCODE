//
//  BrowserInteraction+CDP.swift
//  BrowserToolsFeature
//
//  CDP-backed semantic actions and DOM helpers.
//

import FeatureKit
import ToolCore
import Foundation

extension CDPSession {
    func click(target: BrowserAccessibilityTarget, authorization: BrowserSnapshotAuthorization) async throws {
        try requireInteractive(target)
        let point = try await interactionPoint(for: target, authorization: authorization)
        // Intentionally pre-dispatch only: a click can navigate the document
        // as its expected side effect.
        try await validateSnapshotState(authorization)
        try await dispatchMouseClick(at: point, clickCount: 1)
    }

    func doubleClick(target: BrowserAccessibilityTarget, authorization: BrowserSnapshotAuthorization) async throws {
        try requireInteractive(target)
        let point = try await interactionPoint(for: target, authorization: authorization)
        // Chrome recognizes a double click from the ordinary first click and
        // the second clickCount=2 sequence. This preserves page click handlers
        // while remaining a fixed CDP input sequence.
        // Do not insert a validation between input events: the first event can
        // legitimately navigate as part of this requested action.
        try await validateSnapshotState(authorization)
        try await dispatchMouseClick(at: point, clickCount: 1)
        try await dispatchMouseClick(at: point, clickCount: 2)
    }

    func hover(target: BrowserAccessibilityTarget, authorization: BrowserSnapshotAuthorization) async throws {
        try requireInteractive(target)
        let point = try await interactionPoint(for: target, authorization: authorization)
        try await validateSnapshotState(authorization)
        _ = try await send(
            method: "Input.dispatchMouseEvent",
            params: [
                "type": "mouseMoved",
                "x": point.x,
                "y": point.y,
                "button": "none",
            ]
        )
    }

    func scrollIntoView(target: BrowserAccessibilityTarget, authorization: BrowserSnapshotAuthorization) async throws {
        try await validateSnapshotState(authorization)
        _ = try await send(method: "DOM.enable")
        do {
            // This is the requested action itself; never reject a navigation
            // after it solely because the old snapshot no longer matches.
            _ = try await send(method: "DOM.scrollIntoViewIfNeeded", params: ["backendNodeId": target.backendDOMNodeID])
        } catch {
            throw BrowserInteractionError.targetNoLongerAvailable(target.ref)
        }
    }

    func fill(target: BrowserAccessibilityTarget, value: String, authorization: BrowserSnapshotAuthorization) async throws {
        try requireBoundedInput(value)
        try await prepareActionTarget(target, authorization: authorization)
        let element = try await elementInfo(for: target, authorization: authorization)
        if element.isPasswordLike {
            throw BrowserInteractionError.sensitiveInputRequiresUser
        }
        if element.isFileInput {
            throw BrowserInteractionError.fileInputNotSupported
        }
        guard element.isSupportedFillTarget else { throw BrowserInteractionError.unsupportedFillTarget(target.ref) }

        let result = try await callFixedFunction(Self.fillFunction, on: target, authorization: authorization, argument: ["value": value])
        switch result {
        case "filled":
            return
        case "disabled", "readonly":
            throw BrowserInteractionError.inputIsDisabled
        case "file":
            throw BrowserInteractionError.fileInputNotSupported
        case "password":
            throw BrowserInteractionError.sensitiveInputRequiresUser
        default:
            throw BrowserInteractionError.unsupportedFillTarget(target.ref)
        }
    }

    func selectOption(
        target: BrowserAccessibilityTarget,
        value: String,
        authorization: BrowserSnapshotAuthorization
    ) async throws {
        try requireInteractive(target)
        try requireBoundedInput(value)
        try await prepareActionTarget(target, authorization: authorization)
        let result = try await callFixedFunction(Self.selectOptionFunction, on: target, authorization: authorization, argument: ["value": value])
        switch result {
        case "selected":
            return
        case "disabled":
            throw BrowserInteractionError.targetIsDisabled
        case "option-not-found":
            throw BrowserInteractionError.optionNotFound(target.ref)
        default:
            throw BrowserInteractionError.unsupportedSelectTarget(target.ref)
        }
    }

    func setChecked(target: BrowserAccessibilityTarget, checked: Bool, authorization: BrowserSnapshotAuthorization) async throws {
        try requireInteractive(target)
        try await prepareActionTarget(target, authorization: authorization)
        let result = try await callFixedFunction(Self.setCheckedFunction, on: target, authorization: authorization, argument: ["value": checked])
        switch result {
        case "checked", "unchecked":
            return
        case "disabled":
            throw BrowserInteractionError.targetIsDisabled
        case "unsupported":
            throw BrowserInteractionError.unsupportedCheckTarget(target.ref)
        default:
            throw BrowserInteractionError.unableToSetCheckedState(target.ref)
        }
    }

    func focus(target: BrowserAccessibilityTarget, authorization: BrowserSnapshotAuthorization) async throws {
        try await prepareActionTarget(target, authorization: authorization)
        let result = try await withResolvedDOMObject(target, authorization: authorization) { objectID in
            try await callFunctionReturningString(objectID: objectID, functionDeclaration: Self.focusFunction)
        }
        guard result == "focused" else { throw BrowserInteractionError.targetNoLongerAvailable(target.ref) }
    }

    func press(_ key: BrowserKeyStroke) async throws {
        let params: [String: Any] = [
            "key": key.key,
            "code": key.code,
            "windowsVirtualKeyCode": key.virtualKeyCode,
            "nativeVirtualKeyCode": key.virtualKeyCode,
        ]
        _ = try await send(method: "Input.dispatchKeyEvent", params: params.merging(["type": "keyDown"]) { _, new in new })
        _ = try await send(method: "Input.dispatchKeyEvent", params: params.merging(["type": "keyUp"]) { _, new in new })
    }

    private func requireInteractive(_ target: BrowserAccessibilityTarget) throws {
        guard target.interactive else { throw BrowserInteractionError.targetIsNotInteractive(target.ref) }
    }

    private func requireBoundedInput(_ value: String) throws {
        guard value.lengthOfBytes(using: .utf8) <= 16_000 else { throw BrowserInteractionError.inputValueTooLarge }
    }

    private func callFixedFunction(
        _ declaration: String,
        on target: BrowserAccessibilityTarget,
        authorization: BrowserSnapshotAuthorization,
        argument: [String: Any]
    ) async throws -> String {
        try await withResolvedDOMObject(target, authorization: authorization) { objectID in
            try await callFunctionReturningString(objectID: objectID, functionDeclaration: declaration, arguments: [argument])
        }
    }

    private func prepareActionTarget(
        _ target: BrowserAccessibilityTarget,
        authorization: BrowserSnapshotAuthorization
    ) async throws {
        try await validateSnapshotState(authorization)
        _ = try await send(method: "DOM.enable")
        _ = try? await send(method: "DOM.scrollIntoViewIfNeeded", params: ["backendNodeId": target.backendDOMNodeID])
    }

    private func interactionPoint(
        for target: BrowserAccessibilityTarget,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> (x: Double, y: Double) {
        try await prepareActionTarget(target, authorization: authorization)
        let response = try await snapshotBoundRead(
            authorization,
            method: "DOM.getBoxModel",
            params: ["backendNodeId": target.backendDOMNodeID]
        )
        guard let result = response["result"] as? [String: Any],
              let model = result["model"] as? [String: Any],
              let content = model["content"] as? [Any],
              let point = boxCenter(content)
        else {
            throw BrowserInteractionError.targetNoLongerAvailable(target.ref)
        }
        return point
    }

    private func dispatchMouseClick(at point: (x: Double, y: Double), clickCount: Int) async throws {
        let commonParams: [String: Any] = [
            "x": point.x,
            "y": point.y,
            "button": "left",
            "clickCount": clickCount,
        ]
        _ = try await send(
            method: "Input.dispatchMouseEvent",
            params: commonParams.merging(["type": "mousePressed"]) { _, new in new }
        )
        _ = try await send(
            method: "Input.dispatchMouseEvent",
            params: commonParams.merging(["type": "mouseReleased"]) { _, new in new }
        )
    }

    private func elementInfo(
        for target: BrowserAccessibilityTarget,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> BrowserDOMElementInfo {
        let response = try await snapshotBoundRead(
            authorization,
            method: "DOM.describeNode",
            params: ["backendNodeId": target.backendDOMNodeID]
        )
        guard let result = response["result"] as? [String: Any],
              let node = result["node"] as? [String: Any],
              let nodeName = (node["localName"] as? String ?? node["nodeName"] as? String)?.lowercased()
        else {
            throw BrowserInteractionError.targetNoLongerAvailable(target.ref)
        }
        let rawAttributes = node["attributes"] as? [String] ?? []
        var attributes: [String: String] = [:]
        for index in stride(from: 0, to: rawAttributes.count - 1, by: 2) {
            attributes[rawAttributes[index].lowercased()] = rawAttributes[index + 1]
        }
        return BrowserDOMElementInfo(tagName: nodeName, attributes: attributes)
    }

    private func withResolvedDOMObject<T>(
        _ target: BrowserAccessibilityTarget,
        authorization: BrowserSnapshotAuthorization,
        body: (String) async throws -> T
    ) async throws -> T {
        let response = try await snapshotBoundRead(
            authorization,
            method: "DOM.resolveNode",
            params: ["backendNodeId": target.backendDOMNodeID]
        )
        guard let result = response["result"] as? [String: Any],
              let object = result["object"] as? [String: Any],
              let objectID = object["objectId"] as? String,
              !objectID.isEmpty
        else {
            throw BrowserInteractionError.targetNoLongerAvailable(target.ref)
        }

        do {
            // `body` performs the mutation through Runtime.callFunctionOn.
            // Validate at the last possible point, but never afterward: a
            // page navigation can be the valid result of this action.
            try await validateSnapshotState(authorization)
            let output = try await body(objectID)
            _ = try? await send(method: "Runtime.releaseObject", params: ["objectId": objectID])
            return output
        } catch {
            _ = try? await send(method: "Runtime.releaseObject", params: ["objectId": objectID])
            throw error
        }
    }

    private func callFunctionReturningString(
        objectID: String,
        functionDeclaration: String,
        arguments: [[String: Any]] = []
    ) async throws -> String {
        let response = try await send(
            method: "Runtime.callFunctionOn",
            params: [
                "objectId": objectID,
                "functionDeclaration": functionDeclaration,
                "arguments": arguments,
                "returnByValue": true,
                "awaitPromise": true,
            ]
        )
        let result = response["result"] as? [String: Any] ?? [:]
        if let exceptionDetails = result["exceptionDetails"] {
            let description = (exceptionDetails as? [String: Any])?["text"] as? String
                ?? String(describing: exceptionDetails)
            throw CDPError.javaScriptError(description)
        }
        guard let remoteObject = result["result"] as? [String: Any],
              let value = remoteObject["value"] as? String
        else {
            throw CDPError.invalidResponse("Browser action did not return a result")
        }
        return value
    }

    private func boxCenter(_ rawContent: [Any]) -> (x: Double, y: Double)? {
        let values = rawContent.compactMap { value -> Double? in
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            if let value = value as? NSNumber { return value.doubleValue }
            return nil
        }
        guard values.count >= 8 else { return nil }
        let x = (values[0] + values[2] + values[4] + values[6]) / 4
        let y = (values[1] + values[3] + values[5] + values[7]) / 4
        return (x, y)
    }

    private static let focusFunction = #"""
    function () {
      if (!(this instanceof HTMLElement)) return 'unsupported';
      this.focus({ preventScroll: true });
      return document.activeElement === this ? 'focused' : 'unfocused';
    }
    """#

    private static let fillFunction = #"""
    function (value) {
      const element = this;
      const tag = (element.tagName || '').toLowerCase();
      if (tag !== 'input' && tag !== 'textarea' && !element.isContentEditable) return 'unsupported';
      if (element.disabled) return 'disabled';
      if (element.readOnly) return 'readonly';
      if (tag === 'input' && (element.type || '').toLowerCase() === 'file') return 'file';
      if (tag === 'input' && (element.type || '').toLowerCase() === 'password') return 'password';
      element.focus({ preventScroll: true });
      if (element.isContentEditable) {
        element.textContent = value;
      } else {
        const prototype = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
        const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
        if (setter) setter.call(element, value); else element.value = value;
      }
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
      return 'filled';
    }
    """#

    /// Fixed host-side function: the caller can supply only an option value,
    /// never a selector or executable source. Multiple selects retain their
    /// existing selected options and add the requested exact-value option.
    static let selectOptionFunction = #"""
    function (value) {
      const element = this;
      if (!(element instanceof HTMLSelectElement)) return 'unsupported';
      if (element.disabled) return 'disabled';
      const option = Array.from(element.options).find(candidate => candidate.value === value);
      if (!option) return 'option-not-found';
      const disabledGroup = option.parentElement instanceof HTMLOptGroupElement
        && option.parentElement.disabled;
      if (option.disabled || disabledGroup) return 'disabled';
      element.focus({ preventScroll: true });
      if (element.multiple) {
        option.selected = true;
      } else {
        element.value = value;
      }
      if (!option.selected) return 'option-not-found';
      element.dispatchEvent(new Event('input', { bubbles: true }));
      element.dispatchEvent(new Event('change', { bubbles: true }));
      return 'selected';
    }
    """#

    /// Fixed host-side function for native checkbox/radio controls. Calling
    /// the native `click()` only when state differs preserves normal page event
    /// handlers and makes check/uncheck idempotent. Browsers do not support a
    /// user-like uncheck operation for radio buttons, so that request fails
    /// closed as unsupported.
    private static let setCheckedFunction = #"""
    function (checked) {
      const element = this;
      if (!(element instanceof HTMLInputElement)) return 'unsupported';
      const type = (element.type || '').toLowerCase();
      if (type !== 'checkbox' && type !== 'radio') return 'unsupported';
      if (element.disabled) return 'disabled';
      if (!checked && type === 'radio') return 'unsupported';
      if (element.checked !== checked) element.click();
      if (element.checked !== checked) return 'failed';
      return checked ? 'checked' : 'unchecked';
    }
    """#
}
