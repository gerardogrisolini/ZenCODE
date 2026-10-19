//
//  BrowserInteraction+Fill.swift
//  BrowserToolsFeature
//
//  Robust text entry for `browser.act` fill. Text controls and rich-text
//  editors (Draft.js, Lexical, ProseMirror, Quill, plain contenteditable) are
//  filled with trusted CDP text input, so editors update their own model, and
//  the result is read back before the action reports success.
//

import FeatureKit
import ToolCore
import Foundation

/// How a fill was applied and whether the control kept the requested text.
struct BrowserFillReport: Codable, Hashable, Sendable {
    enum Method: String, Codable, Sendable {
        /// Trusted CDP text input (`Input.insertText`), like a user typing.
        case typed
        /// The native value setter plus input/change events.
        case nativeSetter = "native_setter"
        /// The editor's own `insertText` editing command.
        case editorCommand = "editor_command"
    }

    let method: Method
    /// False only when a text control accepted the value but reformatted it
    /// (for example an input mask); rich-text editors that do not keep the
    /// text fail the action instead.
    let verified: Bool
}

extension CDPSession {
    func fill(
        target: BrowserAccessibilityTarget,
        value: String,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> BrowserFillReport {
        try requireBoundedInput(value)
        try await prepareActionTarget(target, authorization: authorization)
        let element = try await elementInfo(for: target, authorization: authorization)
        if element.isPasswordLike {
            throw BrowserInteractionError.sensitiveInputRequiresUser
        }
        if element.isFileInput {
            throw BrowserInteractionError.fileInputNotSupported
        }

        var mode = try await prepareFill(target, authorization: authorization)
        if mode == "unfocused" {
            // Some editors only activate on a real pointer click.
            let point = try await unobstructedInteractionPoint(for: target, authorization: authorization)
            try await validateSnapshotState(authorization)
            try await dispatchMouseClick(at: point, clickCount: 1)
            try await Task.sleep(for: .milliseconds(150))
            mode = try await prepareFill(target, authorization: authorization)
        }

        switch mode {
        case "text":
            return try await fillTextControl(target, value: value, authorization: authorization)
        case "setter":
            return try await fillWithNativeSetter(target, value: value, authorization: authorization)
        case "editable", "editable-empty":
            return try await fillEditor(
                target,
                value: value,
                replacingExistingText: mode == "editable",
                authorization: authorization
            )
        case "unfocused":
            throw BrowserInteractionError.fillNotApplied(target.ref)
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

    // MARK: - Strategies

    private func fillTextControl(
        _ target: BrowserAccessibilityTarget,
        value: String,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> BrowserFillReport {
        if !value.isEmpty {
            // The prepare step selected the current value, so trusted text
            // input replaces it and frameworks see a real `input` event.
            try await validateSnapshotState(authorization)
            _ = try await send(method: "Input.insertText", params: ["text": Self.normalizedLineBreaks(value)])
            try await Task.sleep(for: .milliseconds(50))
            if try await fillVerification(target, value: value, authorization: authorization) == "match" {
                return BrowserFillReport(method: .typed, verified: true)
            }
        }
        return try await fillWithNativeSetter(target, value: value, authorization: authorization)
    }

    private func fillWithNativeSetter(
        _ target: BrowserAccessibilityTarget,
        value: String,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> BrowserFillReport {
        let result = try await callFixedFunction(
            Self.nativeSetterFillFunction,
            on: target,
            authorization: authorization,
            argument: ["value": ["value": value]]
        )
        guard result == "filled" else { throw BrowserInteractionError.unsupportedFillTarget(target.ref) }
        let verified = try await fillVerification(target, value: value, authorization: authorization) == "match"
        return BrowserFillReport(method: .nativeSetter, verified: verified)
    }

    private func fillEditor(
        _ target: BrowserAccessibilityTarget,
        value: String,
        replacingExistingText: Bool,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> BrowserFillReport {
        try await validateSnapshotState(authorization)
        if replacingExistingText {
            // The editor's own select-all keeps its internal selection model
            // consistent, unlike a DOM Range around framework-owned nodes.
            try await press(.selectAll())
            if value.isEmpty {
                try await press(.backspace)
            }
        }
        if !value.isEmpty {
            try await typeEditorText(value)
        }
        try await Task.sleep(for: .milliseconds(50))
        let verification = try await fillVerification(target, value: value, authorization: authorization)
        if verification == "match" || (!replacingExistingText && verification == "contains") {
            return BrowserFillReport(method: .typed, verified: true)
        }

        let result = try await callFixedFunction(
            Self.editorCommandFillFunction,
            on: target,
            authorization: authorization,
            argument: ["value": ["value": value]]
        )
        try await Task.sleep(for: .milliseconds(50))
        if result == "inserted",
           try await fillVerification(target, value: value, authorization: authorization) == "match"
        {
            return BrowserFillReport(method: .editorCommand, verified: true)
        }
        throw BrowserInteractionError.fillNotApplied(target.ref)
    }

    /// Types text into a focused rich-text editor. Line breaks become
    /// Shift+Enter so a chat composer does not send the message early.
    private func typeEditorText(_ value: String) async throws {
        let lines = Self.normalizedLineBreaks(value).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if index > 0 {
                try await press(.softLineBreak)
            }
            if !line.isEmpty {
                _ = try await send(method: "Input.insertText", params: ["text": line])
            }
        }
    }

    private func prepareFill(
        _ target: BrowserAccessibilityTarget,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> String {
        try await callFixedFunction(Self.prepareFillFunction, on: target, authorization: authorization, argument: ["value": 0])
    }

    private func fillVerification(
        _ target: BrowserAccessibilityTarget,
        value: String,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> String {
        try await callFixedFunction(
            Self.verifyFillFunction,
            on: target,
            authorization: authorization,
            argument: ["value": ["value": value]]
        )
    }

    static func normalizedLineBreaks(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: - Fixed host-side functions

    /// Shared prelude: resolves the editable host for a snapshot target. The
    /// accessibility node of a rich-text editor is often a descendant of the
    /// contenteditable root (a paragraph) or a wrapper around it, so the host
    /// is the outermost contenteditable ancestor, or the first editable
    /// descendant of a wrapper.
    static let fillHostPrelude = #"""
      const textInputTypes = ['text', 'search', 'email', 'url', 'tel', 'number'];
      const setterInputTypes = ['date', 'time', 'datetime-local', 'month', 'week', 'color', 'range'];
      const isTextControl = (el) => el instanceof HTMLTextAreaElement
        || (el instanceof HTMLInputElement && textInputTypes.concat(setterInputTypes, ['password', 'file']).includes((el.type || 'text').toLowerCase()));
      const resolveFillHost = (start) => {
        if (start instanceof HTMLTextAreaElement || start instanceof HTMLInputElement) return start;
        if (!(start instanceof HTMLElement)) return null;
        if (start.isContentEditable) {
          let host = start;
          while (host.parentElement && host.parentElement.isContentEditable) host = host.parentElement;
          return host;
        }
        const inner = Array.from(start.querySelectorAll('textarea, input, [contenteditable]'))
          .find(el => isTextControl(el) || (el instanceof HTMLElement && el.isContentEditable));
        if (!inner) return null;
        return isTextControl(inner) ? inner : resolveFillHost(inner);
      };
      const isSensitive = (host) => ['type', 'autocomplete', 'name', 'id', 'aria-label', 'placeholder']
        .some(attribute => /password|passcode|secret/i.test(host.getAttribute(attribute) || ''));
      const textOf = (host) => (host instanceof HTMLInputElement || host instanceof HTMLTextAreaElement)
        ? host.value
        : (host.innerText || '');
      const normalize = (text) => String(text)
        .replace(/\u00a0/g, ' ')
        .replace(/[\u200b\ufeff]/g, '')
        .replace(/\s+/g, ' ')
        .trim();
    """#

    /// Classifies, guards, and focuses the fill host. Text controls get their
    /// current value selected so typed input replaces it.
    static let prepareFillFunction = """
    function () {
    \(fillHostPrelude)
      const host = resolveFillHost(this);
      if (!host) return 'unsupported';
      const type = host instanceof HTMLInputElement ? (host.type || 'text').toLowerCase() : '';
      if (type === 'file') return 'file';
      if (type === 'password' || isSensitive(host)) return 'password';
      if (host instanceof HTMLInputElement && !textInputTypes.includes(type) && !setterInputTypes.includes(type)) return 'unsupported';
      if (host.disabled || host.getAttribute('aria-disabled') === 'true') return 'disabled';
      if (host.readOnly || host.getAttribute('aria-readonly') === 'true') return 'readonly';
      host.focus({ preventScroll: true });
      const root = host.getRootNode();
      const active = root instanceof ShadowRoot ? root.activeElement : document.activeElement;
      if (active !== host && !(active && host.contains(active))) return 'unfocused';
      if (host instanceof HTMLInputElement || host instanceof HTMLTextAreaElement) {
        if (setterInputTypes.includes(type)) return 'setter';
        try { host.select(); } catch (error) {}
        return 'text';
      }
      return normalize(textOf(host)).length > 0 ? 'editable' : 'editable-empty';
    }
    """

    /// Reads the host's text back and compares it whitespace-insensitively,
    /// because editors render paragraphs and non-breaking spaces differently.
    static let verifyFillFunction = """
    function (options) {
    \(fillHostPrelude)
      const host = resolveFillHost(this);
      if (!host) return 'missing';
      const actual = normalize(textOf(host));
      const expected = normalize(options.value);
      if (actual === expected) return 'match';
      if (expected.length > 0 && actual.includes(expected)) return 'contains';
      return 'mismatch';
    }
    """

    /// Native value setter, kept for date-like inputs and as the fallback
    /// for text controls whose typed input did not stick.
    static let nativeSetterFillFunction = """
    function (options) {
    \(fillHostPrelude)
      const host = resolveFillHost(this);
      if (!(host instanceof HTMLInputElement || host instanceof HTMLTextAreaElement)) return 'unsupported';
      if (host.disabled || host.readOnly) return 'disabled';
      if ((host.type || '').toLowerCase() === 'password' || (host.type || '').toLowerCase() === 'file' || isSensitive(host)) return 'unsupported';
      host.focus({ preventScroll: true });
      const prototype = host instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
      if (setter) setter.call(host, options.value); else host.value = options.value;
      host.dispatchEvent(new Event('input', { bubbles: true }));
      host.dispatchEvent(new Event('change', { bubbles: true }));
      return 'filled';
    }
    """

    /// Editor-command fallback for contenteditable hosts: selects the host's
    /// contents and replaces them through `insertText`, which still emits
    /// `beforeinput`/`input` events that editors observe.
    static let editorCommandFillFunction = """
    function (options) {
    \(fillHostPrelude)
      const host = resolveFillHost(this);
      if (!(host instanceof HTMLElement) || !host.isContentEditable) return 'unsupported';
      host.focus({ preventScroll: true });
      const selection = host.ownerDocument.getSelection();
      if (!selection) return 'failed';
      const range = host.ownerDocument.createRange();
      range.selectNodeContents(host);
      selection.removeAllRanges();
      selection.addRange(range);
      const inserted = options.value.length > 0
        ? host.ownerDocument.execCommand('insertText', false, options.value)
        : host.ownerDocument.execCommand('delete', false);
      return inserted ? 'inserted' : 'failed';
    }
    """
}
