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

    @Test
    func stemmerStaysConservativeOnShortAndBaseForms() {
        // Short words and digit-bearing tokens are untouched.
        for token in ["id", "ids", "is", "has", "was", "v2", "arm64", "sha256", "test"] {
            #expect(MemoryTokenizer.stem(token) == token)
        }
        // `es` is a plural marker only after s/x/z/ch/sh.
        #expect(MemoryTokenizer.stem("notes") == MemoryTokenizer.stem("note"))
        #expect(MemoryTokenizer.stem("caches") == MemoryTokenizer.stem("cache"))
        #expect(MemoryTokenizer.stem("fixes") == "fix")
        // Doubled l/s/f belong to the base form.
        #expect(MemoryTokenizer.stem("recalled") == "recall")
        #expect(MemoryTokenizer.stem("calls") == "call")
        // Letters outside ASCII are left alone rather than mangled.
        #expect(MemoryTokenizer.stem("ereditarietà") == "ereditarietà")
    }

    @Test
    func inflectedQueriesReachEntriesWrittenInTheOtherForm() async throws {
        let engine = MemoryEngine(selector: ScoreThresholdMemorySelector())
        try await engine.insert(
            EngineMemoryEntry(
                id: "italian",
                category: .fact,
                content: "Stabilizzati i test intermittenti della diagnostica CPR."
            ),
            persist: false
        )
        try await engine.insert(
            EngineMemoryEntry(
                id: "unrelated",
                category: .fact,
                content: "Telegram review rounds, all committed on main."
            ),
            persist: false
        )
        try await engine.insert(
            EngineMemoryEntry(
                id: "identifier",
                category: .fact,
                content: "AgentCoreSessionRunner owns the prompt turn and the memory learning permit."
            ),
            persist: false
        )

        let english = try await engine.searchReadOnlyDetailed("flaky test stabilize diagnostics")
        #expect(english.candidates.first?.memory.id == "italian")

        let prose = try await engine.searchReadOnlyDetailed("which type owns the session runner for a prompt turn")
        #expect(prose.candidates.first?.memory.id == "identifier")

        let exact = try await engine.searchReadOnlyDetailed("AgentCoreSessionRunner")
        #expect(exact.candidates.first?.memory.id == "identifier")
    }
}
