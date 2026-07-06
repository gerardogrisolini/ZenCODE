//
//  DS4CoderBackendSupportTests.swift
//  ZenCODE
//

#if ZENCODE_LOCAL_DS4
import Testing
@testable import zen

@Suite
struct DS4CoderBackendSupportTests {
    @Test
    func zeroGenerationSeedKeepsRuntimeDefaultForEveryRound() {
        #expect(DS4CoderBackend.generationSeed(base: 0, round: 0) == 0)
        #expect(DS4CoderBackend.generationSeed(base: 0, round: 3) == 0)
    }

    @Test
    func fixedGenerationSeedVariesAfterFirstToolRound() {
        #expect(DS4CoderBackend.generationSeed(base: 42, round: 0) == 42)
        #expect(DS4CoderBackend.generationSeed(base: 42, round: 1) == 43)
        #expect(DS4CoderBackend.generationSeed(base: 42, round: 2) == 44)
    }
}
#endif
