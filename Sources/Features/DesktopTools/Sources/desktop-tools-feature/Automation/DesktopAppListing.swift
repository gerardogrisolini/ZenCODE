import AppKit
import Foundation

/// Pure rules behind list_apps: which running applications are listed.
enum DesktopAppListing {
    static let regularPolicy = "regular"

    static func activationPolicyName(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: return regularPolicy
        case .accessory: return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }

    /// Whether `query` is a case- and diacritic-insensitive substring of the
    /// app's name or bundle identifier. An empty query matches every app.
    static func matchesQuery(_ query: String, name: String?, bundleID: String?) -> Bool {
        let needle = DesktopElementPolicy.folded(query)
        guard !needle.isEmpty else { return true }
        return [name, bundleID].compactMap { $0 }.contains { DesktopElementPolicy.folded($0).contains(needle) }
    }

    /// Whether an app is listed: regular apps (those with a Dock icon) always,
    /// accessory and prohibited ones (menu-bar agents, daemons, helpers) only
    /// with `includeBackground`, and in any case only when it matches `query`.
    static func isListed(
        activationPolicy: String,
        name: String?,
        bundleID: String?,
        includeBackground: Bool,
        query: String?
    ) -> Bool {
        guard includeBackground || activationPolicy == regularPolicy else { return false }
        guard let query else { return true }
        return matchesQuery(query, name: name, bundleID: bundleID)
    }

    /// The note for a list_apps result that is empty only because background
    /// apps are not listed; nil otherwise.
    static func hiddenBackgroundNote(hidden: Int) -> String? {
        guard hidden > 0 else { return nil }
        return "\(hidden) matching background application(s) (accessory or prohibited activation policy) are not listed; pass include_background=true to include them."
    }
}
