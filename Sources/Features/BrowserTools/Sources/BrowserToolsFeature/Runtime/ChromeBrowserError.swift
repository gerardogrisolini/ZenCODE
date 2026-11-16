//
//  ChromeBrowserError.swift
//  BrowserToolsFeature
//
//  Errors raised while discovering, launching or talking to the dedicated
//  Chrome instance used by the Browser feature.
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

// MARK: - Errors

enum ChromeBrowserError: LocalizedError, Sendable {
    case chromeNotFound
    case spawnFailed(String)
    case cdpNotReady(String)
    case httpError(String)
    case invalidTabResponse(String)
    case pageNotFound(String)
    case unsafeRootExecution
    case profileInUseByLoginSession
    case loginRequiresVisibleBrowser
    case automatedBrowserDidNotExit

    var errorDescription: String? {
        switch self {
        case .chromeNotFound:
            "No Chrome or Chromium executable found. Set ZENCODE_CHROME to a Chrome path."
        case let .spawnFailed(message):
            "Failed to start Chrome: \(message)"
        case let .cdpNotReady(message):
            message
        case let .httpError(message):
            "CDP HTTP request failed: \(message)"
        case let .invalidTabResponse(message):
            "Chrome returned an unexpected response: \(message)"
        case let .pageNotFound(pageID):
            "Browser page '\(pageID)' no longer exists. Open or list pages and use a current pageId."
        case .unsafeRootExecution:
            "Browser refuses to launch Chrome as root without its sandbox. Run ZenCODE as a non-root user, or set ZENCODE_BROWSER_ALLOW_UNSANDBOXED_ROOT=1 only inside an externally isolated environment."
        case .profileInUseByLoginSession:
            "The Browser profile is open in a manual login window started by browser.login. Ask the user to finish signing in and quit that Chrome window, then retry."
        case .loginRequiresVisibleBrowser:
            "browser.login needs a visible Chrome window, but ZENCODE_BROWSER_HEADLESS is enabled. Unset it on a machine with a display to sign in manually."
        case .automatedBrowserDidNotExit:
            "The automated Browser Chrome instance did not exit, so the manual login window cannot use its profile. Quit Chrome for the Browser profile and retry."
        }
    }
}
