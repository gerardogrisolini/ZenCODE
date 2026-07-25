//
//  ResponseLanguageResolverTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite("Response language resolver")
struct ResponseLanguageResolverTests {
    @Test
    func resolvesKnownCodesToDisplayNames() {
        #expect(ResponseLanguageResolver.displayName(forCode: "it") == "Italian")
        #expect(ResponseLanguageResolver.displayName(forCode: "en") == "English")
        #expect(ResponseLanguageResolver.displayName(forCode: "ja") == "Japanese")
        #expect(ResponseLanguageResolver.displayName(forCode: "zh") == "Chinese")
    }

    @Test
    func resolvesCaseInsensitivelyAndTrimsWhitespace() {
        #expect(ResponseLanguageResolver.displayName(forCode: " IT ") == "Italian")
        #expect(ResponseLanguageResolver.displayName(forCode: "EN") == "English")
    }

    @Test
    func fallsBackToFoundationForCodesOutsideTheStaticMap() {
        // "ca" (Catalan) is not in the curated map but is a valid ISO code.
        let name = ResponseLanguageResolver.displayName(forCode: "ca")
        #expect(name != nil)
        #expect(name?.lowercased() != "ca")
    }

    @Test
    func returnsNilForBlankOrPseudoLocaleCodes() {
        #expect(ResponseLanguageResolver.displayName(forCode: nil) == nil)
        #expect(ResponseLanguageResolver.displayName(forCode: "") == nil)
        #expect(ResponseLanguageResolver.displayName(forCode: "   ") == nil)
        #expect(ResponseLanguageResolver.displayName(forCode: "C") == nil)
        #expect(ResponseLanguageResolver.displayName(forCode: "POSIX") == nil)
    }

    @Test
    func selectableLanguagesAreNonEmptyAndUnique() {
        #expect(!ResponseLanguageResolver.selectableLanguages.isEmpty)
        let codes = ResponseLanguageResolver.selectableLanguages.map(\.code)
        #expect(Set(codes).count == codes.count)
        // Every selectable entry has a resolvable display name.
        for language in ResponseLanguageResolver.selectableLanguages {
            #expect(ResponseLanguageResolver.displayName(forCode: language.code) == language.displayName)
        }
    }

    @Test
    func systemLanguageCodeIsNonNilOnMostHosts() {
        #expect(ResponseLanguageResolver.systemLanguageCode() != nil)
    }
}
