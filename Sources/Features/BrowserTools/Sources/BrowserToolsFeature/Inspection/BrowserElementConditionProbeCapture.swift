//
//  BrowserElementConditionProbeCapture.swift
//  BrowserToolsFeature
//
//  Fixed JavaScript probe for element conditions and the decoding of its
//  bounded result.
//

import FeatureKit
import ToolCore
import Dispatch
import Foundation

private struct BrowserElementConditionProbePayload: Decodable {
    let present: Bool
    let visible: Bool?
    let enabled: Bool?
    let checked: Bool?
    let text: String?
    let value: String?
    let textTruncated: Bool?
    let valueTruncated: Bool?
}

/// The only JavaScript used by these tools. It is fixed source selected by the
/// host and runs only on a DOM object resolved from the authorized backend node
/// id. No selector, literal, or executable source comes from tool input.
enum BrowserElementConditionProbeCapture {
    static let functionDeclaration = #"""
    function () {
      const absent = () => JSON.stringify({ present: false });
      if (!this || this.nodeType !== 1 || !this.isConnected) return absent();

      try {
        const element = this;
        const tag = String(element.tagName || '').toLowerCase();
        const clip = value => {
          const string = String(value == null ? '' : value);
          if (string.length <= 16000) return { value: string, truncated: false };
          return { value: string.slice(0, 16000), truncated: true };
        };
        const style = typeof getComputedStyle === 'function' ? getComputedStyle(element) : null;
        const rect = typeof element.getBoundingClientRect === 'function'
          ? element.getBoundingClientRect()
          : null;
        const display = style ? String(style.display || '').toLowerCase() : '';
        const visibility = style ? String(style.visibility || '').toLowerCase() : '';
        const opacity = style ? Number(style.opacity) : 1;
        const hasArea = !!rect && rect.width > 0 && rect.height > 0;
        const ariaHidden = String(element.getAttribute('aria-hidden') || '').trim().toLowerCase() === 'true';
        const visible = !element.hidden
          && !ariaHidden
          && display !== 'none'
          && visibility !== 'hidden'
          && visibility !== 'collapse'
          && (!Number.isFinite(opacity) || opacity > 0)
          && hasArea;
        const ariaDisabled = String(element.getAttribute('aria-disabled') || '').trim().toLowerCase() === 'true';
        const nativeDisabled = typeof element.disabled === 'boolean' && element.disabled;
        const enabled = !(ariaDisabled || nativeDisabled);

        let checked = null;
        if (tag === 'input') {
          const type = String(element.type || '').toLowerCase();
          if (type === 'checkbox' || type === 'radio') checked = !!element.checked;
        }
        if (checked === null) {
          const ariaChecked = String(element.getAttribute('aria-checked') || '').trim().toLowerCase();
          if (ariaChecked === 'true') checked = true;
          if (ariaChecked === 'false') checked = false;
        }

        let text = '';
        try { text = element.innerText || element.textContent || ''; } catch (_) {}
        const value = (() => {
          if (tag === 'input') {
            const type = String(element.type || '').toLowerCase();
            if (type === 'password') return null;
            return element.value || '';
          }
          if (tag === 'textarea' || tag === 'select' || tag === 'option') return element.value || '';
          if (element.isContentEditable) return element.textContent || '';
          return null;
        })();
        const textResult = clip(text);
        const valueResult = value === null ? null : clip(value);
        return JSON.stringify({
          present: true,
          visible,
          enabled,
          checked,
          text: textResult.value,
          value: valueResult ? valueResult.value : null,
          textTruncated: textResult.truncated,
          valueTruncated: valueResult ? valueResult.truncated : false
        });
      } catch (_) {
        return JSON.stringify({ present: true, visible: null, enabled: null, checked: null });
      }
    }
    """#

    static func decode(_ json: String) throws -> BrowserElementConditionProbe {
        guard json.lengthOfBytes(using: .utf8) <= BrowserElementConditionLimits.maximumProbePayloadBytes else {
            throw CDPError.invalidResponse("Browser element condition probe exceeded its host-side byte limit")
        }
        guard let data = json.data(using: .utf8) else {
            throw CDPError.invalidResponse("Browser element condition probe was not UTF-8")
        }

        let payload: BrowserElementConditionProbePayload
        do {
            payload = try JSONDecoder().decode(BrowserElementConditionProbePayload.self, from: data)
        } catch {
            throw CDPError.invalidResponse("Unable to decode Browser element condition probe: \(error.localizedDescription)")
        }

        guard payload.present else { return .absent }
        let boundedText = payload.text.map(BrowserElementConditionLimits.clipProbeValue)
        let boundedValue = payload.value.map(BrowserElementConditionLimits.clipProbeValue)
        return BrowserElementConditionProbe(
            present: true,
            visible: payload.visible,
            enabled: payload.enabled,
            checked: payload.checked,
            text: boundedText?.value,
            value: boundedValue?.value,
            textTruncated: (payload.textTruncated ?? false) || (boundedText?.truncated ?? false),
            valueTruncated: (payload.valueTruncated ?? false) || (boundedValue?.truncated ?? false)
        )
    }

    /// Only well-known DOM identity failures are interpreted as disappearance.
    /// Transport, runtime-context, parsing, and all other errors remain errors
    /// (or retryable wait probe failures), never false `absent` results.
    static func isTargetNoLongerAvailable(_ error: Error) -> Bool {
        guard let cdpError = error as? CDPError,
              case let .commandFailed(message) = cdpError
        else {
            return false
        }
        let normalized = message.lowercased()
        let missingNodeMarkers = [
            "could not find node with given id",
            "no node with given id",
            "could not find node with given backend id",
            "no node with given backend id",
            "could not find object with given id",
            "does not belong to the document",
        ]
        return missingNodeMarkers.contains { normalized.contains($0) }
    }
}
