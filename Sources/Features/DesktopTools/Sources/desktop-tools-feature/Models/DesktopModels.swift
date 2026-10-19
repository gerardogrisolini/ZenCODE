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
    var launch_if_needed: Bool?
    var force: Bool?
    var state: Bool?
    var timeout: Double?
    var target: String?
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
    let app_name: String?
    let bundle_id: String?
    let title: String?
    let bounds: DesktopRect
    let layer: Int
    let is_on_screen: Bool
    let alpha: Double
    let is_focused: Bool?
    let is_minimized: Bool?
    let is_fullscreen: Bool?
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
    var elapsed_ms: Int?
    var note: String?

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
