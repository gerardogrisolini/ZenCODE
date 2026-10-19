//
//  BrowserElementConditions+Tools.swift
//  BrowserToolsFeature
//
//  Public wait/assert element tools and their presentation.
//

import FeatureKit
import ToolCore
import Dispatch

// MARK: - Public tools (registration is intentionally external)

struct BrowserWaitElementTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let snapshotId: String?
        let snapshot_id: String?
        let ref: String?
        let condition: String?
        let value: String?
        let timeoutSeconds: Int?
        let timeout_seconds: Int?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id)
        }

        var resolvedSnapshotID: String? {
            snapshotId?.nilIfBlank ?? snapshot_id?.nilIfBlank
        }

        var resolvedRef: String? {
            ref?.nilIfBlank
        }

        var resolvedTimeout: Int? {
            timeoutSeconds ?? timeout_seconds
        }
    }

    static let name = "browser.wait_element"
    static let description = "Waits up to a bounded timeout for one fixed condition on an element authorized by pageId, snapshotId, and ref. Conditions are host-side enums; Browser never accepts selectors, JavaScript, or CDP methods."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("snapshotId", description: "snapshotId returned by browser.snapshot for this page."),
            .string("snapshot_id", description: "Snake-case alias for snapshotId."),
            .string("ref", description: "Opaque element ref from that snapshot."),
            .string(
                "condition",
                enumValues: BrowserElementCondition.allCases.map(\.rawValue),
                description: "Fixed element condition."
            ),
            .string("value", description: "Literal required by text_contains and value_equals (maximum 1000 UTF-8 bytes)."),
            .number("timeoutSeconds", description: "Timeout in whole seconds (1 through 30; defaults to 10)."),
            .number("timeout_seconds", description: "Snake-case alias for timeoutSeconds."),
        ],
        required: ["pageId", "snapshotId", "ref", "condition"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserWaitElementOutput {
        guard let pageID = input.resolvedPageID else { throw BrowserToolsFeatureError.missingArgument("pageId") }
        guard let snapshotID = input.resolvedSnapshotID else { throw BrowserToolsFeatureError.missingArgument("snapshotId") }
        guard let ref = input.resolvedRef else { throw BrowserToolsFeatureError.missingArgument("ref") }
        let condition = try BrowserElementCondition.resolve(input.condition)
        let literal = try BrowserElementConditionLiteral.resolve(input.value, for: condition)
        let timeoutSeconds = try BrowserElementConditionLimits.resolveTimeout(input.resolvedTimeout)

        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context, waitForReady: false) { session, tab in
            let authorization = BrowserSnapshotAuthorization(pageID: tab.id, snapshotID: snapshotID, ref: ref)
            let result = try await session.waitForElementCondition(
                authorization: authorization,
                condition: condition,
                literal: literal,
                timeoutSeconds: timeoutSeconds
            )
            try await session.validateSnapshotState(authorization)
            let page = (try? await session.pageMetadata(pageID: tab.id)) ?? BrowserPage(tab: tab)
            try await session.validateSnapshotState(authorization)
            return BrowserWaitElementOutput(
                page: page,
                snapshotID: snapshotID,
                ref: ref,
                condition: condition,
                literal: literal,
                result: result
            )
        }
    }
}

struct BrowserAssertElementTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let snapshotId: String?
        let snapshot_id: String?
        let ref: String?
        let condition: String?
        let value: String?

        var resolvedPageID: String? {
            BrowserPageInput.resolve(pageID: pageId, pageIDSnakeCase: page_id)
        }

        var resolvedSnapshotID: String? {
            snapshotId?.nilIfBlank ?? snapshot_id?.nilIfBlank
        }

        var resolvedRef: String? {
            ref?.nilIfBlank
        }
    }

    static let name = "browser.assert_element"
    static let description = "Evaluates one fixed condition on an element authorized by pageId, snapshotId, and ref, returning a structured pass/fail result. Browser never accepts selectors, JavaScript, or CDP methods."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("snapshotId", description: "snapshotId returned by browser.snapshot for this page."),
            .string("snapshot_id", description: "Snake-case alias for snapshotId."),
            .string("ref", description: "Opaque element ref from that snapshot."),
            .string(
                "condition",
                enumValues: BrowserElementCondition.allCases.map(\.rawValue),
                description: "Fixed element condition."
            ),
            .string("value", description: "Literal required by text_contains and value_equals (maximum 1000 UTF-8 bytes)."),
        ],
        required: ["pageId", "snapshotId", "ref", "condition"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserAssertElementOutput {
        guard let pageID = input.resolvedPageID else { throw BrowserToolsFeatureError.missingArgument("pageId") }
        guard let snapshotID = input.resolvedSnapshotID else { throw BrowserToolsFeatureError.missingArgument("snapshotId") }
        guard let ref = input.resolvedRef else { throw BrowserToolsFeatureError.missingArgument("ref") }
        let condition = try BrowserElementCondition.resolve(input.condition)
        let literal = try BrowserElementConditionLiteral.resolve(input.value, for: condition)

        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context, waitForReady: false) { session, tab in
            let authorization = BrowserSnapshotAuthorization(pageID: tab.id, snapshotID: snapshotID, ref: ref)
            // As with wait, validate before resolving a backend identity.
            let target = try await session.resolveElementConditionTarget(authorization: authorization)
            let evaluation = try await session.evaluateElementCondition(
                authorization: authorization,
                target: target,
                condition: condition,
                literal: literal
            )
            try await session.validateSnapshotState(authorization)
            let page = (try? await session.pageMetadata(pageID: tab.id)) ?? BrowserPage(tab: tab)
            try await session.validateSnapshotState(authorization)
            return BrowserAssertElementOutput(
                page: page,
                snapshotID: snapshotID,
                ref: ref,
                condition: condition,
                literal: literal,
                evaluation: evaluation
            )
        }
    }
}
