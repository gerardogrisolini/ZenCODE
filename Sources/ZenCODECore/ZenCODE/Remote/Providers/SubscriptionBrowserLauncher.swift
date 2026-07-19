//
//  SubscriptionBrowserLauncher.swift
//  ZenCODE
//

import Foundation
#if os(macOS)
import AppKit
#endif

enum SubscriptionBrowserLauncher {
    static func open(_ url: URL) async -> Bool {
        #if os(macOS)
        return await MainActor.run {
            NSWorkspace.shared.open(url)
        }
        #elseif os(Linux)
        let fileManager = FileManager.default
        let candidates = [
            "/usr/bin/wslview",
            "/usr/local/bin/wslview",
            "/usr/bin/xdg-open",
            "/usr/local/bin/xdg-open"
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            guard let result = try? await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: path),
                arguments: [url.absoluteString],
                timeout: 15
            ) else {
                continue
            }
            if result.exitCode == 0, !result.timedOut {
                return true
            }
        }
        return false
        #else
        _ = url
        return false
        #endif
    }
}
