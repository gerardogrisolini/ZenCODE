//
//  MCPServerConfiguration+Mac.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if os(macOS)
import AppKit
import Darwin
import Foundation
import ToolCore

extension MCPServerConfiguration {
    public static func platformDetectedXcodePID() -> String? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
        guard !apps.isEmpty else {
            return nil
        }

        if let activeApp = apps.first(where: \.isActive) {
            return String(activeApp.processIdentifier)
        }

        return String(apps[0].processIdentifier)
    }

    public static func platformDetectedXcodeBridgeExecutablePath() -> String? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode")
        guard !apps.isEmpty else {
            return nil
        }

        let app = apps.first(where: \.isActive) ?? apps[0]
        guard let bundleURL = app.bundleURL else {
            return nil
        }

        let bridgeURL = bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("Developer")
            .appendingPathComponent("usr")
            .appendingPathComponent("bin")
            .appendingPathComponent("mcpbridge")

        guard FileManager.default.isExecutableFile(atPath: bridgeURL.path) else {
            return nil
        }

        return bridgeURL.path
    }

    public static func platformIsUsableXcodeProcessID(_ pidString: String) -> Bool {
        guard let pid = Int32(pidString), pid > 0 else {
            return false
        }

        if kill(pid, 0) != 0, errno != EPERM {
            return false
        }

        guard let app = NSRunningApplication(processIdentifier: pid_t(pid)) else {
            return false
        }

        return app.bundleIdentifier == "com.apple.dt.Xcode"
    }
}
#endif
