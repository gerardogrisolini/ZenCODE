//
//  MemoryTokenizerTests.swift
//  ZenCODECoreTests
//
//  Lexical tokens for a bilingual, identifier-heavy journal: camel-case
//  splitting with the whole identifier retained, and a light English/Italian
//  suffix stemmer applied identically to documents and queries.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct MemoryTokenizerTests {
    @Test
    func identifiersYieldTheWholeTokenAndTheirSegments() {
        #expect(MemoryTokenizer.tokens("AgentCoreSessionRunner") == [
            "agentcoresessionrunner", "agent", "core", "session", "runner"
        ])
        // Acronym runs end before the next capitalised word.
        #expect(MemoryTokenizer.tokens("HTTPServer") == ["httpserver", "http", "server"])
        #expect(MemoryTokenizer.tokens("ACPSession") == ["acpsession", "acp", "session"])
        // All-caps constants are lower-cased and stemmed like prose, so
        // `ZENCODE`, `ZenCODE` and `zencode` coincide; digit-bearing words are
        // never altered.
        #expect(MemoryTokenizer.tokens("ZENCODE_SUPPORT_DIRECTORY") == ["zencod", "support", "directori"])
        #expect(MemoryTokenizer.tokens("ZenCODE").first == "zencod")
        #expect(MemoryTokenizer.tokens("zencode") == ["zencod"])
        #expect(MemoryTokenizer.tokens("arm64 v2 sha256") == ["arm64", "v2", "sha256"])
        // Connectors and punctuation split as before.
        #expect(MemoryTokenizer.tokens("rpios-test.sh memory.graph.json") == ["rpio", "test", "sh", "memori", "graph", "json"])
    }

    @Test
    func englishAndItalianInflectionsMeetOnOneStem() {
        let valid = ["validated", "validation", "validations", "validate", "validazione", "validazioni", "validata", "validati", "valida"]
        #expect(Set(valid.map(MemoryTokenizer.stem)) == ["valid"])

        let memory = ["memory", "memories", "memoria", "memorie"]
        #expect(Set(memory.map(MemoryTokenizer.stem)) == ["memori"])

        let session = ["session", "sessions", "sessione", "sessioni"]
        #expect(Set(session.map(MemoryTokenizer.stem)) == ["session"])

        let stabilize = ["stabilize", "stabilized", "stabilizzati", "stabilizzazione"]
        #expect(Set(stabilize.map(MemoryTokenizer.stem)) == ["stabiliz"])

        #expect(Set(["test", "tests", "testing"].map(MemoryTokenizer.stem)) == ["test"])
        #expect(Set(["diagnostics", "diagnostica"].map(MemoryTokenizer.stem)) == ["diagnostic"])
        #expect(Set(["commit", "commits", "committed"].map(MemoryTokenizer.stem)) == ["commit"])
        #expect(Set(["embed", "embedding", "embeddings"].map(MemoryTokenizer.stem)) == ["embed"])
        #expect(Set(["release", "released", "releases"].map(MemoryTokenizer.stem)) == ["releas"])
        #expect(Set(["entry", "entries"].map(MemoryTokenizer.stem)) == ["entri"])
        #expect(Set(["agent", "agents", "agente", "agenti"].map(MemoryTokenizer.stem)) == ["agent"])
    }
}
