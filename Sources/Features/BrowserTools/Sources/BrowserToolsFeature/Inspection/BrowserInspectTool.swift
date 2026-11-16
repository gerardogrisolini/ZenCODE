//
//  BrowserInspectTool.swift
//  BrowserToolsFeature
//
//  The browser.inspect tool and the read-only CDP DOM/CSS inspection it runs
//  on a snapshot-authorized target.
//

import FeatureKit
import ToolCore
import Foundation

// MARK: - CDP read-only inspection

extension CDPSession {
    /// Reads the one snapshot-authorized target using only DOM and CSS CDP
    /// domains. No selector, raw protocol method, or page script reaches this
    /// surface from tool input.
    func inspectDOMAndCSS(
        target: BrowserAccessibilityTarget,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> BrowserDOMInspection.Selection {
        _ = try await send(method: "DOM.enable")
        // `DOM.describeNode(backendNodeId:)` may legitimately report nodeId=0
        // until the document has been requested by this short-lived DevTools
        // session. Push the authorized backend identity into the frontend DOM
        // first so CSS.getComputedStyleForNode receives a usable nodeId.
        _ = try await snapshotBoundRead(authorization, method: "DOM.getDocument", params: ["depth": 0, "pierce": false])
        let pushedNodeResponse = try await snapshotBoundRead(
            authorization,
            method: "DOM.pushNodesByBackendIdsToFrontend",
            params: ["backendNodeIds": [target.backendDOMNodeID]]
        )
        let frontendNodeID = try BrowserDOMInspection.parseFrontendNodeID(pushedNodeResponse)
        let nodeResponse = try await snapshotBoundRead(
            authorization,
            method: "DOM.describeNode",
            params: [
                "nodeId": frontendNodeID,
                "depth": 0,
                "pierce": false,
            ]
        )
        let node = try BrowserDOMInspection.parseDOMNode(nodeResponse)

        _ = try await send(method: "CSS.enable")
        let styleResponse = try await snapshotBoundRead(
            authorization,
            method: "CSS.getComputedStyleForNode",
            params: ["nodeId": node.frontendNodeID]
        )
        let style = try BrowserDOMInspection.parseComputedStyle(styleResponse)

        // A detached or display:none node has no box model. That is useful
        // observation rather than a reason to reveal raw CDP failure text.
        let boxResponse: [String: Any]?
        do {
            boxResponse = try await snapshotBoundRead(
                authorization,
                method: "DOM.getBoxModel",
                params: ["backendNodeId": target.backendDOMNodeID]
            )
        } catch let error as BrowserInteractionError {
            // A document mismatch is an authorization failure, not an absent
            // box model, and must remain fail-closed.
            throw error
        } catch {
            boxResponse = nil
        }
        let boxModel = boxResponse.flatMap(BrowserDOMInspection.parseBoxModel)

        return BrowserDOMInspection.Selection(
            element: node.element,
            boxModel: boxModel,
            computedStyle: style.values,
            truncated: node.truncated || style.truncated
        )
    }
}

// MARK: - Public tool (registration is intentionally owned by integration)

struct BrowserInspectTool: FeatureTool {
    struct Input: Decodable, Sendable {
        let pageId: String?
        let page_id: String?
        let id: String?
        let snapshotId: String?
        let snapshot_id: String?
        let ref: String?

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

    static let name = "browser.inspect"
    static let description = "Inspects one ref from the current browser.snapshot using a bounded, redacted DOM and computed-CSS projection. Browser never accepts selectors, JavaScript, or raw CDP commands."
    static let inputSchema = buildInputSchema(
        [
            .string("pageId", description: "pageId returned by browser.open or browser.pages."),
            .string("page_id", description: "Snake-case alias for pageId."),
            .string("snapshotId", description: "snapshotId returned by the current browser.snapshot for this page."),
            .string("snapshot_id", description: "Snake-case alias for snapshotId."),
            .string("ref", description: "Opaque element ref from that exact snapshot."),
        ],
        required: ["pageId", "snapshotId", "ref"]
    )

    func run(_ input: Input, context: FeatureContext) async throws -> BrowserInspectOutput {
        guard let pageID = input.resolvedPageID else { throw BrowserToolsFeatureError.missingArgument("pageId") }
        guard let snapshotID = input.resolvedSnapshotID else { throw BrowserToolsFeatureError.missingArgument("snapshotId") }
        guard let ref = input.resolvedRef else { throw BrowserToolsFeatureError.missingArgument("ref") }

        return try await BrowserToolsRunner.withPage(pageID: pageID, context: context) { session, tab in
            let authorization = BrowserSnapshotAuthorization(pageID: tab.id, snapshotID: snapshotID, ref: ref)
            let target = try await session.resolveSnapshotTarget(authorization)
            let inspection = try await session.inspectDOMAndCSS(target: target, authorization: authorization)
            // Tab metadata is Browser-owned CDP data; unlike pageMetadata(),
            // this inspector does not evaluate an additional page expression.
            return BrowserInspectOutput(page: BrowserPage(tab: tab), snapshotID: snapshotID, ref: ref, inspection: inspection)
        }
    }
}

extension BrowserInspectTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Browser target", action: "Inspect", kind: .inspect, targetKeyPaths: ["ref", "pageId", "page_id"])
    }
}
