//  Created by Gerardo Grisolini on 30/05/26.
//
import CoreGraphics
import FeatureKit
import Foundation

struct DesktopRunInput: Decodable, Sendable {
    let action: String

    var x: Double?
    var y: Double?
    var to_x: Double?
    var to_y: Double?
    var width: Double?
    var height: Double?
    var duration: Double?
    var interval: Double?

    var button: String?
    var click_count: Int?
    var delta_x: Double?
    var delta_y: Double?
    var scroll_unit: String?

    var text: String?
    var key: String?
    var modifiers: [String]?
    var repeat_count: Int?

    var scope: String?
    var display_index: Int?
    var window_id: UInt32?
    var include_cursor: Bool?
    var include_shadow: Bool?
    var delay: Double?
    var label: String?

    var pid: Int32?
    var bundle_id: String?
    var app_name: String?
    var app_path: String?
    var title: String?
    var window_index: Int?
    var on_screen_only: Bool?
    var limit: Int?
    /// Entries to skip in list_apps, list_windows, list_elements, and read_text.
    var offset: Int?
    /// list_apps: also list accessory and prohibited apps.
    var include_background: Bool?
    var launch_if_needed: Bool?
    var force: Bool?
    var state: Bool?
    var timeout: Double?
    var target: String?

    var element_ref: String?
    var query: String?
    var role: String?
    var interactive_only: Bool?
    var max_depth: Int?
    /// list_elements: the full element instead of the compact one; read_text:
    /// `ref` and `frame` with each text.
    var include_details: Bool?
    /// list_elements and element actions: exact, case-sensitive AXIdentifier.
    var identifier: String?

    /// batch: the calls to run in order, each with the fields of a call.
    var steps: [DesktopRunInput]?
    /// batch: stop at the first failed step; defaults to true.
    var stop_on_error: Bool?
    /// wait_for: what to wait for (app_active, window_present, window_absent,
    /// element_present, or element_absent).
    var condition: String?
}

struct DesktopPoint: Codable, Sendable {
    let x: Double
    let y: Double

    init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }
}

struct DesktopRect: Codable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }
}

struct DesktopPermissions: Codable, Sendable {
    let accessibility: Bool
    let screen_recording: Bool
    let event_posting: Bool
}

struct DesktopDisplayInfo: Codable, Sendable {
    let capture_index: Int
    let display_id: UInt32
    let name: String
    let is_main: Bool
    let bounds: DesktopRect
    let pixel_width: Int
    let pixel_height: Int
    let scale_factor: Double
}

struct DesktopAppInfo: Codable, Sendable {
    let pid: Int32
    let name: String?
    let bundle_id: String?
    let bundle_path: String?
    let activation_policy: String
    let is_active: Bool
    let is_hidden: Bool
    let is_terminated: Bool
    /// True only for the app hosting this zen session; omitted otherwise.
    var hosts_zen: Bool?
}

/// A deliberately tiny, read-only process snapshot used to bypass stale
/// NSRunningApplication instances in the short-lived feature worker. It is
/// emitted only for the executable's private probe mode, never as a tool.
struct DesktopAppProbe: Codable, Sendable {
    let exists: Bool
    let is_active: Bool
    let is_hidden: Bool
    let is_terminated: Bool
    let is_finished_launching: Bool
}

struct DesktopWindowInfo: Codable, Sendable {
    let window_id: UInt32?
    let pid: Int32
    var app_name: String?
    var bundle_id: String?
    var title: String?
    let bounds: DesktopRect
    let layer: Int
    let is_on_screen: Bool
    let alpha: Double
    /// `is_focused`, `is_minimized`, `subrole`, and `is_main` come from Accessibility
    /// and are nil when the window could not be paired with an AX window.
    var is_focused: Bool?
    var is_minimized: Bool?
    let is_fullscreen: Bool?
    var subrole: String?
    var is_main: Bool?
    /// True only when the owner is the frontmost app; omitted otherwise.
    var is_frontmost_app: Bool?
    /// True only for windows of the app hosting this zen session; omitted otherwise.
    var hosts_zen: Bool?
}

/// An Accessibility element. Every field except `role` is omitted when unknown;
/// `value` is bounded and never reported for secure text fields. `label` is
/// set only by list_elements, which reports either the full element (with
/// `include_details`) or the compact one (`DesktopElementPolicy.compact`).
struct DesktopElementInfo: Codable, Sendable {
    var ref: String?
    var role: String
    var subrole: String?
    var role_description: String?
    var title: String?
    var description: String?
    var value: String?
    var placeholder: String?
    var identifier: String?
    var enabled: Bool?
    var focused: Bool?
    var value_settable: Bool?
    var frame: DesktopRect?
    var center: DesktopPoint?
    var actions: [String]?
    var pid: Int32?
    var app_name: String?
    var window_title: String?
    var hosts_zen: Bool?
    /// The distinct texts among title, description, and placeholder joined with " | ".
    var label: String?
}

/// One text read by read_text. `role` and `text` are always present; `ref` and
/// `frame` only with `include_details`. `text` is the element's value as text,
/// else its label, and is at most `DesktopTextReading.maximumTextCharacters`
/// characters (ending in "..." when cut). The value of a secure text field is
/// never reported.
struct DesktopTextItem: Codable, Sendable {
    let role: String
    let text: String
    var ref: String?
    var frame: DesktopRect?
}

/// The outcome of one step of a batch. `summary` is set when the step ran
/// and succeeded, `error` when it failed, and `skipped` (always true when
/// present) when it did not run. The payloads are those of the step's own
/// output, possibly reduced to fit the response size budget
/// (`DesktopBatchPolicy.fitted`).
struct DesktopBatchStepResult: Codable, Sendable {
    /// 1-based position of the step in `steps`.
    let index: Int
    let action: String
    let ok: Bool
    var summary: String?
    var error: String?
    var note: String?
    var skipped: Bool?
    var permissions: DesktopPermissions?
    var system: DesktopSystemInfo?
    var element: DesktopElementInfo?
    var focused_element: DesktopElementInfo?
    var app: DesktopAppInfo?
    var window: DesktopWindowInfo?
    var elements: [DesktopElementInfo]?
    var texts: [DesktopTextItem]?
    var windows: [DesktopWindowInfo]?
    var apps: [DesktopAppInfo]?
    var clipboard_text: String?
    var count: Int?
    var next_offset: Int?
}

struct DesktopScreenshotArtifact: Codable, Sendable {
    let path: String
    let mime_type: String
    let size_bytes: Int
    let sha256: String
    let pixel_width: Int?
    let pixel_height: Int?
    let scope: String
    let display_index: Int?
    let window_id: UInt32?
    let region: DesktopRect?
    let desktop_bounds: DesktopRect?
    let points_per_pixel: Double?
    let created_at: String
}

struct DesktopSystemInfo: Codable, Sendable {
    let os_version: String
    let architecture: String
    let process_id: Int32
    let displays: [DesktopDisplayInfo]
    let pointer: DesktopPoint
    let frontmost_app: DesktopAppInfo?
}

struct DesktopRunOutput: Codable, Sendable, FeatureInvocationAttachmentProviding {
    var ok = true
    let action: String
    let summary: String
    var permissions: DesktopPermissions?
    var system: DesktopSystemInfo?
    var apps: [DesktopAppInfo]?
    var windows: [DesktopWindowInfo]?
    var app: DesktopAppInfo?
    var window: DesktopWindowInfo?
    var pointer: DesktopPoint?
    var artifact: DesktopScreenshotArtifact?
    var clipboard_text: String?
    var count: Int?
    /// list_apps, list_windows, list_elements, and read_text: the `offset` of the
    /// next page; omitted when no more entries are known.
    var next_offset: Int?
    var elapsed_ms: Int?
    var note: String?
    var elements: [DesktopElementInfo]?
    /// read_text: the texts of the window's elements.
    var texts: [DesktopTextItem]?
    var element: DesktopElementInfo?
    var focused_element: DesktopElementInfo?
    var focus_method: String?
    /// screenshot and zoom: the frontmost app at capture time.
    var frontmost_app: DesktopAppInfo?
    /// batch: the outcome of every step, in order.
    var steps: [DesktopBatchStepResult]?

    var featureInvocationAttachments: [FeatureInvocationAttachment] {
        guard let artifact else {
            return []
        }
        return [
            FeatureInvocationAttachment(
                path: artifact.path,
                kind: .image,
                contentType: artifact.mime_type,
                originalFilename: URL(fileURLWithPath: artifact.path).lastPathComponent
            )
        ]
    }
}
