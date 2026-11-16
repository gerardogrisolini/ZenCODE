//
//  ChromeBrowserManager+Launch.swift
//  BrowserToolsFeature
//
//  Chrome executable discovery and launch-argument builders of the dedicated
//  Chrome instance manager.
//

import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension ChromeBrowserManager {
    static func discoverExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let envPath = environment["ZENCODE_CHROME"],
           !envPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: envPath)
        {
            return envPath
        }

        #if os(macOS)
        let macOSApps = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ]
        for path in macOSApps where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        #endif

        let linuxPaths = [
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/snap/bin/chromium",
            "/opt/google/chrome/chrome",
        ]
        for path in linuxPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let names = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]
        if let pathEnv = environment["PATH"] {
            for directory in pathEnv.split(separator: ":") {
                let dir = String(directory)
                for name in names {
                    let candidate = "\(dir)/\(name)"
                    if FileManager.default.isExecutableFile(atPath: candidate) {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    /// Arguments shared by the automated and the manual login instance. Both
    /// must agree on the profile and on credential storage, otherwise cookies
    /// saved during a manual login could not be decrypted by the automated
    /// instance. On macOS Chrome uses the real Keychain like a normal install.
    static func profileLaunchArguments(configuration: ChromeBrowserConfiguration) -> [String] {
        var arguments = [
            "--user-data-dir=\(configuration.profileDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
        ]
        #if !os(macOS)
        // Linux machines (including headless ones) may have no keyring daemon;
        // a keyring prompt would block the automated instance.
        arguments.append("--password-store=basic")
        #endif
        return arguments
    }

    static func automationLaunchArguments(configuration: ChromeBrowserConfiguration) -> [String] {
        let port = configuration.portOverride ?? 0
        var arguments = [
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=\(port)",
        ]
        arguments += profileLaunchArguments(configuration: configuration)
        arguments.append("--mute-audio")
        if configuration.launchesHeadless {
            arguments.append("--headless=new")
        }
        arguments.append("about:blank")
        return arguments
    }

    /// A manual login instance deliberately exposes no debugging endpoint.
    static func loginLaunchArguments(configuration: ChromeBrowserConfiguration, url: URL?) -> [String] {
        profileLaunchArguments(configuration: configuration) + [url?.absoluteString ?? "about:blank"]
    }
}
