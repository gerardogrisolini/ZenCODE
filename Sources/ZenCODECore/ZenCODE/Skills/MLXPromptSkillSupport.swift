//
//  MLXPromptSkillSupport.swift
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
    "ui": "UI",
    "xcode": "Xcode"
]
