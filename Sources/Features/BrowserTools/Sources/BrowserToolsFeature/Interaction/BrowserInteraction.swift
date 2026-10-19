//
//  BrowserInteraction.swift
//  BrowserToolsFeature
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Controlled semantic Browser interaction. The public contract accepts only
//  opaque snapshot refs and constrained actions; raw CDP and JavaScript remain
//  internal implementation details.
//

import FeatureKit
import ToolCore
import Foundation
import Synchronization

// MARK: - Errors and output

enum BrowserInteractionError: LocalizedError, Equatable {
    case staleSnapshot
    case targetNoLongerAvailable(String)
    case targetIsNotInteractive(String)
    case unsupportedFillTarget(String)
    case sensitiveInputRequiresUser
    case fileInputNotSupported
    case inputIsDisabled
    case inputValueTooLarge
    case unsupportedSelectTarget(String)
    case optionNotFound(String)
    case unsupportedCheckTarget(String)
    case targetIsDisabled
    case unableToSetCheckedState(String)
    case unsupportedKey(String)

    var errorDescription: String? {
        switch self {
        case .staleSnapshot:
            "The Browser snapshot is stale or does not authorize this element. Take a fresh browser.snapshot before acting."
        case let .targetNoLongerAvailable(ref):
            "Browser element '\(ref)' is no longer available. Take a fresh browser.snapshot."
        case let .targetIsNotInteractive(ref):
            "Browser element '\(ref)' is not an interactive semantic control."
        case let .unsupportedFillTarget(ref):
            "Browser element '\(ref)' cannot be filled. Use a textbox, textarea, or contenteditable control from a fresh snapshot."
        case .sensitiveInputRequiresUser:
            "Browser will not fill password-like fields. Ask the user to type the value directly into the visible Chrome window."
        case .fileInputNotSupported:
            "Browser will not populate file upload inputs. Ask the user to choose the file in the visible Chrome window."
        case .inputIsDisabled:
            "Browser cannot fill a disabled or read-only control."
        case .inputValueTooLarge:
            "Browser fill values are limited to 16,000 UTF-8 bytes."
        case let .unsupportedSelectTarget(ref):
            "Browser element '\(ref)' is not a selectable HTML select control."
        case let .optionNotFound(ref):
            "Browser element '\(ref)' does not contain an option with that value. Take a fresh browser.snapshot and inspect the control before selecting."
        case let .unsupportedCheckTarget(ref):
            "Browser element '\(ref)' is not a checkbox or radio control that Browser can set."
        case .targetIsDisabled:
            "Browser cannot change a disabled control."
        case let .unableToSetCheckedState(ref):
            "Browser element '\(ref)' did not reach the requested checked state. Take a fresh browser.snapshot before retrying."
        case let .unsupportedKey(key):
            "Unsupported Browser key '\(key)'. Use a navigation or editing key such as Enter, Tab, Escape, ArrowDown, Backspace, or Delete."
        }
    }
}

enum BrowserActionKind: String, Codable, Sendable {
    case click
    case fill
    case press
    case hover
    case doubleClick = "double_click"
    case scrollIntoView = "scroll_into_view"
    case selectOption = "select_option"
    case check
    case uncheck

    static func resolve(_ rawValue: String?) throws -> Self {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            throw BrowserToolsFeatureError.missingArgument("action")
        }
        guard let action = Self(rawValue: rawValue.lowercased()) else {
            throw BrowserToolsFeatureError.browserError(
                "Unsupported Browser action '\(rawValue)'. Use click, fill, press, hover, double_click, scroll_into_view, select_option, check, or uncheck."
            )
        }
        return action
    }
}

enum BrowserDialogAction: String, Codable, Sendable {
    case accept
    case dismiss

    static func resolve(_ rawValue: String?) throws -> Self {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            throw BrowserToolsFeatureError.missingArgument("action")
        }
        guard let action = Self(rawValue: rawValue.lowercased()) else {
            throw BrowserToolsFeatureError.browserError("Unsupported Browser dialog action '\(rawValue)'. Use accept or dismiss.")
        }
        return action
    }
}

struct BrowserDialogInfo: Codable, Hashable, Sendable {
    let type: String
    let message: String
    let defaultPrompt: String?
    let url: String?
}

struct BrowserActionOutput: Codable, Sendable {
    let page: BrowserPage
    let action: BrowserActionKind
    let targetRef: String?
    let dialog: BrowserDialogInfo?
    let note: String

    init(page: BrowserPage, action: BrowserActionKind, targetRef: String?, dialog: BrowserDialogInfo?) {
        self.page = page
        self.action = action
        self.targetRef = targetRef
        self.dialog = dialog
        self.note = dialog == nil
            ? "The action was dispatched through Browser's constrained semantic interaction API."
            : "A JavaScript dialog is open. Call browser.dialog explicitly to accept or dismiss it."
    }
}

struct BrowserDialogOutput: Codable, Sendable {
    let page: BrowserPage
    let action: BrowserDialogAction
    let note: String

    init(page: BrowserPage, action: BrowserDialogAction) {
        self.page = page
        self.action = action
        self.note = "The JavaScript dialog was handled explicitly. Browser does not supply prompt text on the model's behalf."
    }
}

private enum BrowserInteractionText {
    static let maximumBytes = 4_000

    static func clipped(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.lengthOfBytes(using: .utf8) > maximumBytes else { return value }
        let result = value.prefixFitting(utf8Bytes: maximumBytes)
        return result + "…"
    }
}

private final class BrowserDialogObserver: Sendable {
    private struct State: Sendable {
        var latestDialog: BrowserDialogInfo?
    }
    private let state = Mutex(State())

    func consume(_ event: CDPEvent) {
        guard event.method == "Page.javascriptDialogOpening" else { return }
        let params = event.params
        let dialog = BrowserDialogInfo(
            type: params["type"] as? String ?? "unknown",
            message: BrowserInteractionText.clipped(params["message"] as? String) ?? "",
            defaultPrompt: BrowserInteractionText.clipped(params["defaultPrompt"] as? String),
            url: BrowserInteractionText.clipped(params["url"] as? String)
        )
        state.withLock { state in
            state.latestDialog = dialog
            return
        }
    }

    var dialog: BrowserDialogInfo? {
        state.withLock { state in
            state.latestDialog
        }
    }
}

// MARK: - Key input

struct BrowserKeyStroke {
    let key: String
    let code: String
    let virtualKeyCode: Int

    static func resolve(_ rawValue: String?) throws -> BrowserKeyStroke {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            throw BrowserToolsFeatureError.missingArgument("key")
        }
        let normalized = rawValue
            .lowercased()
            .filter { $0 != "-" && $0 != "_" && !$0.isWhitespace }
        let supported: [String: BrowserKeyStroke] = [
            "enter": .init(key: "Enter", code: "Enter", virtualKeyCode: 13),
            "tab": .init(key: "Tab", code: "Tab", virtualKeyCode: 9),
            "escape": .init(key: "Escape", code: "Escape", virtualKeyCode: 27),
            "esc": .init(key: "Escape", code: "Escape", virtualKeyCode: 27),
            "space": .init(key: " ", code: "Space", virtualKeyCode: 32),
            "backspace": .init(key: "Backspace", code: "Backspace", virtualKeyCode: 8),
            "delete": .init(key: "Delete", code: "Delete", virtualKeyCode: 46),
            "arrowup": .init(key: "ArrowUp", code: "ArrowUp", virtualKeyCode: 38),
            "arrowdown": .init(key: "ArrowDown", code: "ArrowDown", virtualKeyCode: 40),
            "arrowleft": .init(key: "ArrowLeft", code: "ArrowLeft", virtualKeyCode: 37),
            "arrowright": .init(key: "ArrowRight", code: "ArrowRight", virtualKeyCode: 39),
            "home": .init(key: "Home", code: "Home", virtualKeyCode: 36),
            "end": .init(key: "End", code: "End", virtualKeyCode: 35),
            "pageup": .init(key: "PageUp", code: "PageUp", virtualKeyCode: 33),
            "pagedown": .init(key: "PageDown", code: "PageDown", virtualKeyCode: 34),
        ]
        guard let key = supported[normalized] else { throw BrowserInteractionError.unsupportedKey(rawValue) }
        return key
    }
}

// MARK: - DOM and Input helpers

struct BrowserDOMElementInfo {
    let tagName: String
    let attributes: [String: String]

    var isPasswordLike: Bool {
        let sensitiveValues = [
            attributes["type"],
            attributes["autocomplete"],
            attributes["name"],
            attributes["id"],
            attributes["aria-label"],
            attributes["placeholder"],
        ]
        .compactMap { $0?.lowercased() }
        return sensitiveValues.contains { value in
            value.contains("password") || value.contains("passcode") || value.contains("secret")
        }
    }

    var isFileInput: Bool {
        tagName == "input" && attributes["type"]?.lowercased() == "file"
    }

    var isSupportedFillTarget: Bool {
        let isContentEditable = attributes["contenteditable"].map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "false"
        } ?? false
        return tagName == "input"
            || tagName == "textarea"
            || isContentEditable
    }
}

// MARK: - Public tools

struct BrowserActTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let snapshotId: String?
        let snapshot_id: String?
        let action: String?
        let ref: String?
        let value: String?
        let key: String?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }

        var resolvedSnapshotID: String? {
            snapshotId?.nilIfBlank ?? snapshot_id?.nilIfBlank
        }

        var resolvedRef: String? {
            ref?.nilIfBlank
        }
    }

    static let name = "browser.act"
    static let description = "Performs one constrained semantic action on a ref returned by the current browser.snapshot: click, fill, press, hover, double_click, scroll_into_view, select_option, check, or uncheck. Password-like and file inputs are never filled. Actions can have external side effects."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("snapshotId", description: "snapshotId returned by the most recent browser.snapshot for this page."),
            .string("snapshot_id", description: "Snake-case alias for snapshotId."),
            .string("action", enumValues: ["click", "fill", "press", "hover", "double_click", "scroll_into_view", "select_option", "check", "uncheck"], description: "Constrained semantic action."),
            .string("ref", description: "Opaque element ref from that snapshot. Required for every action except press."),
            .string("value", description: "Value for fill or exact option value for select_option. Never use this for passwords or secrets."),
            .string("key", description: "Supported key for press, such as Enter, Tab, Escape, ArrowDown, Backspace, or Delete."),
        ],
        required: ["pageId", "snapshotId", "action"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserActionOutput {
        guard let pageID = input.resolvedPageID else { throw BrowserToolsFeatureError.missingArgument("pageId") }
        guard let snapshotID = input.resolvedSnapshotID else { throw BrowserToolsFeatureError.missingArgument("snapshotId") }
        let action = try BrowserActionKind.resolve(input.action)
        let ref = input.resolvedRef

        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context) { session, tab in
            let authorization = BrowserSnapshotAuthorization(pageID: tab.id, snapshotID: snapshotID, ref: ref)
            try await session.validateSnapshotState(authorization)
            let observer = BrowserDialogObserver()
            let token = session.addEventHandler { event in
                observer.consume(event)
            }
            defer { session.removeEventHandler(token) }

            switch action {
            case .click:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.click(target: target, authorization: authorization)
            case .fill:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                guard let value = input.value else { throw BrowserToolsFeatureError.missingArgument("value") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.fill(target: target, value: value, authorization: authorization)
            case .press:
                if ref != nil {
                    let target = try await session.resolveSnapshotTarget(authorization)
                    try await session.focus(target: target, authorization: authorization)
                }
                // Keyboard input can navigate too, so only validate before
                // dispatch and never after the action.
                try await session.validateSnapshotState(authorization)
                try await session.press(BrowserKeyStroke.resolve(input.key))
            case .hover:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.hover(target: target, authorization: authorization)
            case .doubleClick:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.doubleClick(target: target, authorization: authorization)
            case .scrollIntoView:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.scrollIntoView(target: target, authorization: authorization)
            case .selectOption:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                guard let value = input.value else { throw BrowserToolsFeatureError.missingArgument("value") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.selectOption(target: target, value: value, authorization: authorization)
            case .check:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.setChecked(target: target, checked: true, authorization: authorization)
            case .uncheck:
                guard ref != nil else { throw BrowserToolsFeatureError.missingArgument("ref") }
                let target = try await session.resolveSnapshotTarget(authorization)
                try await session.setChecked(target: target, checked: false, authorization: authorization)
            }

            try await Task.sleep(for: .milliseconds(150))
            let dialog = observer.dialog
            if dialog == nil {
                try? await session.waitNavigatedReady()
            }
            let page = dialog == nil
                ? (try? await session.pageMetadata(pageID: tab.id)) ?? BrowserPage(tab: tab)
                : BrowserPage(tab: tab)
            return BrowserActionOutput(page: page, action: action, targetRef: ref, dialog: dialog)
        }
    }
}

struct BrowserDialogTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let action: String?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id, id: id)
        }
    }

    static let name = "browser.dialog"
    static let description = "Explicitly accepts or dismisses a JavaScript dialog already opened on a persistent Browser page. Browser does not provide prompt text on the model's behalf."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId with the open dialog."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("action", enumValues: ["accept", "dismiss"], description: "How to handle the open dialog."),
        ],
        required: ["pageId", "action"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserDialogOutput {
        guard let pageID = input.resolvedPageID else { throw BrowserToolsFeatureError.missingArgument("pageId") }
        let action = try BrowserDialogAction.resolve(input.action)
        return try await BrowserToolsRunner.withPage(
            pageID: pageID,
            context: context,
            preparePage: false,
            validateCurrentDocument: false
        ) { session, tab in
            _ = try await session.send(method: "Page.handleJavaScriptDialog", params: ["accept": action == .accept])
            let page = (try? await session.pageMetadata(pageID: tab.id)) ?? BrowserPage(tab: tab)
            return BrowserDialogOutput(page: page, action: action)
        }
    }
}

// MARK: - Semantic presentation

extension BrowserActTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Browser action", action: "Perform", kind: .execute, targetKeyPaths: ["action", "ref", "pageId", "page_id"])
    }
}

extension BrowserDialogTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Browser dialog", action: "Handle", kind: .communicate, targetKeyPaths: ["action", "pageId", "page_id"])
    }
}
