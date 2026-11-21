//
//  PromptSkillSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(CryptoKit)

import CryptoKit
#else
import Crypto
#endif
import Foundation

/// `urls` standardized, without the repeated paths, in their order.
func uniqueStandardizedURLs(_ urls: [URL]) -> [URL] {
    var uniqueURLs: [URL] = []
    var seenPaths: Set<String> = []

    for url in urls {
        let standardizedURL = url.standardizedFileURL
        guard seenPaths.insert(standardizedURL.path).inserted else {
            continue
        }
        uniqueURLs.append(standardizedURL)
    }

    return uniqueURLs
}

let genericSkillHeadingTitles: Set<String> = [
    "overview",
    "quick start",
    "workflow",
    "instructions",
    "references",
    "references and examples",
    "examples",
    "prerequisites",
    "requirements",
    "usage",
    "details",
    "introduction",
    "summary",
    "core instructions",
    "output format"
]

let preferredTitleComponents: [String: String] = [
    "api": "API",
    "cli": "CLI",
    "ios": "iOS",
    "macos": "macOS",
    "swiftdata": "SwiftData",
    "swiftui": "SwiftUI",
    "tui": "TUI",
    "ui": "UI"
]
