//
//  BrowserInteraction+Scroll.swift
//  BrowserToolsFeature
//
//  `browser.act` scroll: moves the page, or the scroll container of a ref,
//  with a real mouse-wheel event (so lazy loading and scroll listeners run)
//  and falls back to a programmatic scroll when the wheel had no effect.
//

import FeatureKit
import ToolCore
import Foundation

enum BrowserScrollDirection: String, Codable, Sendable {
    case up
    case down
    case left
    case right

    static let maximumAmount: Double = 100_000

    var isVertical: Bool { self == .up || self == .down }
    var sign: Double { self == .down || self == .right ? 1 : -1 }

    static func resolve(_ rawValue: String?) throws -> Self {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return .down
        }
        guard let direction = Self(rawValue: rawValue.lowercased()) else {
            throw BrowserInteractionError.unsupportedScrollDirection(rawValue)
        }
        return direction
    }

    static func resolveAmount(_ rawValue: Double?) throws -> Double? {
        guard let rawValue else { return nil }
        guard rawValue.isFinite, rawValue >= 1, rawValue <= maximumAmount else {
            throw BrowserInteractionError.invalidScrollAmount
        }
        return rawValue
    }
}

struct BrowserScrollReport: Codable, Hashable, Sendable {
    enum Container: String, Codable, Sendable {
        case page
        case element
    }

    let direction: BrowserScrollDirection
    let container: Container
    let requestedPixels: Double
    let scrollX: Double
    let scrollY: Double
    /// Whether the container's scroll position changed.
    let moved: Bool
    /// Whether the container cannot scroll further in this direction.
    let reachedEnd: Bool
}

/// Scroll state of one container, as reported by the fixed metrics function.
struct BrowserScrollMetrics: Decodable, Equatable, Sendable {
    let page: Bool
    let x: Double
    let y: Double
    let maxX: Double
    let maxY: Double
    let clientWidth: Double
    let clientHeight: Double

    func position(vertical: Bool) -> Double { vertical ? y : x }

    func reachedEnd(_ direction: BrowserScrollDirection) -> Bool {
        switch direction {
        case .up: y <= 0.5
        case .down: y >= maxY - 0.5
        case .left: x <= 0.5
        case .right: x >= maxX - 0.5
        }
    }

    func moved(from previous: BrowserScrollMetrics, vertical: Bool) -> Bool {
        abs(position(vertical: vertical) - previous.position(vertical: vertical)) >= 1
    }

    static func parse(_ raw: String) throws -> BrowserScrollMetrics {
        do {
            return try JSONDecoder().decode(BrowserScrollMetrics.self, from: Data(raw.utf8))
        } catch {
            throw CDPError.invalidResponse("Browser scroll metrics were malformed")
        }
    }
}

struct BrowserViewportBounds: Equatable, Sendable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    /// Center of the part of these bounds that lies inside the viewport, or
    /// the viewport center when they do not intersect it.
    func visibleCenter(viewportWidth: Double, viewportHeight: Double) -> (x: Double, y: Double) {
        let left = max(minX, 0)
        let right = min(maxX, viewportWidth)
        let top = max(minY, 0)
        let bottom = min(maxY, viewportHeight)
        guard right > left, bottom > top else { return (viewportWidth / 2, viewportHeight / 2) }
        return ((left + right) / 2, (top + bottom) / 2)
    }

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    init?(quad rawContent: [Any]) {
        let values = rawContent.compactMap { value -> Double? in
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            if let value = value as? NSNumber { return value.doubleValue }
            return nil
        }
        guard values.count >= 8 else { return nil }
        let xs = [values[0], values[2], values[4], values[6]]
        let ys = [values[1], values[3], values[5], values[7]]
        self.init(minX: xs.min() ?? 0, minY: ys.min() ?? 0, maxX: xs.max() ?? 0, maxY: ys.max() ?? 0)
    }
}

extension CDPSession {
    func scroll(
        target: BrowserAccessibilityTarget?,
        direction: BrowserScrollDirection,
        amount: Double?,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> BrowserScrollReport {
        let vertical = direction.isVertical
        if let target {
            try await prepareActionTarget(target, authorization: authorization)
        } else {
            try await validateSnapshotState(authorization)
        }
        let viewport = try await viewportSize()
        var point = (x: viewport.width / 2, y: viewport.height / 2)
        if let target, let bounds = try? await currentBoxBounds(of: target, authorization: authorization) {
            point = bounds.visibleCenter(viewportWidth: viewport.width, viewportHeight: viewport.height)
        }

        let containerID: String
        if let target {
            containerID = try await withResolvedDOMObject(target, authorization: authorization) { objectID in
                try await callFunctionReturningObjectID(
                    objectID: objectID,
                    functionDeclaration: Self.locateScrollContainerFunction,
                    argument: ["vertical": vertical, "usePoint": false]
                )
            }
        } else {
            containerID = try await evaluateReturningObjectID(
                Self.locateScrollContainerFunction,
                argument: ["vertical": vertical, "usePoint": true, "x": point.x, "y": point.y]
            )
        }

        do {
            let report = try await scrollContainer(
                containerID,
                direction: direction,
                amount: amount,
                point: point,
                authorization: authorization
            )
            _ = try? await send(method: "Runtime.releaseObject", params: ["objectId": containerID])
            return report
        } catch {
            _ = try? await send(method: "Runtime.releaseObject", params: ["objectId": containerID])
            throw error
        }
    }

    private func scrollContainer(
        _ containerID: String,
        direction: BrowserScrollDirection,
        amount: Double?,
        point: (x: Double, y: Double),
        authorization: BrowserSnapshotAuthorization
    ) async throws -> BrowserScrollReport {
        let vertical = direction.isVertical
        let before = try await scrollMetrics(containerID)
        let pixels = amount ?? max(100, (vertical ? before.clientHeight : before.clientWidth) * 0.8)
        let delta = pixels * direction.sign
        let deltaX = vertical ? 0 : delta
        let deltaY = vertical ? delta : 0

        // Scrolling never navigates by itself, but validate before dispatch
        // like every other input action.
        try await validateSnapshotState(authorization)
        _ = try await send(
            method: "Input.dispatchMouseEvent",
            params: ["type": "mouseMoved", "x": point.x, "y": point.y, "button": "none"]
        )
        _ = try await send(
            method: "Input.dispatchMouseEvent",
            params: [
                "type": "mouseWheel",
                "x": point.x,
                "y": point.y,
                "deltaX": deltaX,
                "deltaY": deltaY,
                "pointerType": "mouse",
            ]
        )

        // A wheel scroll can animate smoothly; poll briefly for movement.
        var after = before
        for _ in 0..<6 {
            try await Task.sleep(for: .milliseconds(100))
            after = try await scrollMetrics(containerID)
            if after.moved(from: before, vertical: vertical) { break }
        }

        if !after.moved(from: before, vertical: vertical), !before.reachedEnd(direction) {
            // The wheel can be swallowed by a non-scrolling overlay or a
            // listener that prevents default; scroll the container directly.
            _ = try await scrollMetrics(containerID, scrollBy: (deltaX, deltaY))
            try await Task.sleep(for: .milliseconds(100))
            after = try await scrollMetrics(containerID)
        }

        return BrowserScrollReport(
            direction: direction,
            container: after.page ? .page : .element,
            requestedPixels: pixels,
            scrollX: after.x,
            scrollY: after.y,
            moved: after.moved(from: before, vertical: vertical),
            reachedEnd: after.reachedEnd(direction)
        )
    }

    private func scrollMetrics(
        _ containerID: String,
        scrollBy delta: (x: Double, y: Double)? = nil
    ) async throws -> BrowserScrollMetrics {
        var options: [String: Any] = [:]
        if let delta {
            options = ["scrollBy": true, "dx": delta.x, "dy": delta.y]
        }
        let raw = try await callFunctionReturningString(
            objectID: containerID,
            functionDeclaration: Self.scrollMetricsFunction,
            arguments: [["value": options]]
        )
        return try BrowserScrollMetrics.parse(raw)
    }

    private func viewportSize() async throws -> (width: Double, height: Double) {
        let raw = try await evalString("JSON.stringify([window.innerWidth, window.innerHeight])")
        guard let values = try? JSONDecoder().decode([Double].self, from: Data(raw.utf8)),
              values.count == 2,
              values[0] > 0,
              values[1] > 0
        else {
            throw CDPError.invalidResponse("Browser could not read the viewport size")
        }
        return (values[0], values[1])
    }

    private func currentBoxBounds(
        of target: BrowserAccessibilityTarget,
        authorization: BrowserSnapshotAuthorization
    ) async throws -> BrowserViewportBounds? {
        let response = try await snapshotBoundRead(
            authorization,
            method: "DOM.getBoxModel",
            params: ["backendNodeId": target.backendDOMNodeID]
        )
        guard let result = response["result"] as? [String: Any],
              let model = result["model"] as? [String: Any],
              let border = model["border"] as? [Any] ?? model["content"] as? [Any]
        else {
            return nil
        }
        return BrowserViewportBounds(quad: border)
    }

    private func callFunctionReturningObjectID(
        objectID: String,
        functionDeclaration: String,
        argument: [String: Any]
    ) async throws -> String {
        let response = try await send(
            method: "Runtime.callFunctionOn",
            params: [
                "objectId": objectID,
                "functionDeclaration": functionDeclaration,
                "arguments": [["value": argument]],
                "returnByValue": false,
            ]
        )
        return try Self.remoteObjectID(from: response)
    }

    /// Evaluates a fixed host-owned function against the document element.
    /// The argument is JSON-encoded data, never caller-supplied source.
    private func evaluateReturningObjectID(_ functionDeclaration: String, argument: [String: Any]) async throws -> String {
        let data = try JSONSerialization.data(withJSONObject: argument)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        let response = try await send(
            method: "Runtime.evaluate",
            params: [
                "expression": "(\(functionDeclaration)).call(document.documentElement, \(json))",
                "returnByValue": false,
            ]
        )
        return try Self.remoteObjectID(from: response)
    }

    private static func remoteObjectID(from response: [String: Any]) throws -> String {
        let result = response["result"] as? [String: Any] ?? [:]
        if let exceptionDetails = result["exceptionDetails"] {
            let description = (exceptionDetails as? [String: Any])?["text"] as? String
                ?? String(describing: exceptionDetails)
            throw CDPError.javaScriptError(description)
        }
        guard let remoteObject = result["result"] as? [String: Any],
              let objectID = remoteObject["objectId"] as? String,
              !objectID.isEmpty
        else {
            throw CDPError.invalidResponse("Browser could not locate a scroll container")
        }
        return objectID
    }

    // MARK: - Fixed host-side functions

    /// Returns the nearest scrollable ancestor-or-self for the requested axis
    /// (crossing shadow roots), or the document scroller. With `usePoint`,
    /// the search starts at the element under the wheel point, matching the
    /// container the wheel event will actually scroll.
    static let locateScrollContainerFunction = #"""
    function (options) {
      const vertical = !!options.vertical;
      const canScroll = (el) => {
        const style = getComputedStyle(el);
        const overflow = vertical ? style.overflowY : style.overflowX;
        const range = vertical ? el.scrollHeight - el.clientHeight : el.scrollWidth - el.clientWidth;
        return range > 1 && /(auto|scroll|overlay)/.test(overflow);
      };
      let element = this instanceof Element ? this : document.documentElement;
      if (options.usePoint) {
        const hit = document.elementFromPoint(options.x, options.y);
        if (hit) element = hit;
      }
      while (element && element !== document.body && element !== document.documentElement && !canScroll(element)) {
        const root = element.getRootNode();
        element = element.parentElement || (root instanceof ShadowRoot ? root.host : null);
      }
      if (!element || element === document.body || element === document.documentElement) {
        return document.scrollingElement || document.documentElement;
      }
      return element;
    }
    """#

    /// Reports the container's scroll state; with `scrollBy` it first
    /// scrolls the container programmatically.
    static let scrollMetricsFunction = #"""
    function (options) {
      const scroller = document.scrollingElement || document.documentElement;
      const page = this === scroller || this === document.documentElement || this === document.body;
      if (options && options.scrollBy) {
        const delta = { left: options.dx || 0, top: options.dy || 0, behavior: 'instant' };
        if (page) window.scrollBy(delta); else this.scrollBy(delta);
      }
      const clientWidth = page ? window.innerWidth : this.clientWidth;
      const clientHeight = page ? window.innerHeight : this.clientHeight;
      const box = page ? scroller : this;
      return JSON.stringify({
        page: page,
        x: page ? window.scrollX : this.scrollLeft,
        y: page ? window.scrollY : this.scrollTop,
        maxX: Math.max(0, box.scrollWidth - clientWidth),
        maxY: Math.max(0, box.scrollHeight - clientHeight),
        clientWidth: clientWidth,
        clientHeight: clientHeight
      });
    }
    """#
}
