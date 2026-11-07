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
    func returnsNilForBlankOrPseudoLocaleCodes() {
        #expect(ResponseLanguageResolver.displayName(forCode: nil) == nil)
        #expect(ResponseLanguageResolver.displayName(forCode: "") == nil)
        #expect(ResponseLanguageResolver.displayName(forCode: "   ") == nil)
        #expect(ResponseLanguageResolver.displayName(forCode: "C") == nil)
        #expect(ResponseLanguageResolver.displayName(forCode: "POSIX") == nil)
    }
}
