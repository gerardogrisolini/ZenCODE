//
//  MemoryVectorFileTests.swift
//  ZenCODECoreTests (memory engine)
//
//  The binary vectors file of graph version 4: deterministic little-endian
//  encoding, decoding with bounds checks on every length, the content-and-model
//  fingerprint, and the rule that assigns a vector only to the entry it was
//  written for.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite struct MemoryVectorFileTests {
    private static func entry(
        _ id: String,
        content: String,
        model: String? = "m",
        vector: [Float]?
    ) -> EngineMemoryEntry {
        EngineMemoryEntry(
            id: id,
            category: .fact,
            content: content,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            embedding: vector,
            embeddingModel: model
        )
    }

    private static func graph(_ entries: [EngineMemoryEntry]) -> MemoryGraph {
        var graph = MemoryGraph()
        for entry in entries { graph.addMemory(entry) }
        return graph
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    // MARK: - Fingerprint

    @Test func fingerprintIsFNV1a64OfModelZeroByteAndContent() {
        #expect(MemoryVectorFile.fingerprint(model: "", content: "") == 0xAF63_BD4C_8601_B7DF)
        #expect(MemoryVectorFile.fingerprint(model: "m", content: "x") == 0x0879_4B19_17C7_B1D0)
        #expect(MemoryVectorFile.fingerprint(model: "modèl", content: "città ✓") == 0x1BBF_BE17_0464_C928)
        // The separator keeps model and content apart.
        #expect(MemoryVectorFile.fingerprint(model: "ab", content: "c")
            != MemoryVectorFile.fingerprint(model: "a", content: "bc"))
        // An entry without a model is fingerprinted with the model recall uses.
        let unnamed = Self.entry("u", content: "x", model: nil, vector: [1])
        #expect(MemoryVectorFile.fingerprint(of: unnamed)
            == MemoryVectorFile.fingerprint(model: unspecifiedEmbeddingModel, content: "x"))
    }

    // MARK: - Encoding

    @Test func encodingHasTheDocumentedLittleEndianLayout() throws {
        let data = try MemoryVectorFile.encode(Self.graph([
            Self.entry("a", content: "x", vector: [1, -2]),
        ]))
        var expected: [UInt8] = Array("ZMVF".utf8)
        expected += Self.littleEndian(UInt16(1))          // format version
        expected += Self.littleEndian(UInt16(1))          // binary16
        expected += Self.littleEndian(UInt32(1))          // records
        expected += Self.littleEndian(UInt16(1)) + Array("a".utf8)
        expected += [0xD0, 0xB1, 0xC7, 0x17, 0x19, 0x4B, 0x79, 0x08]   // fingerprint
        expected += Self.littleEndian(UInt32(1))          // content bytes
        expected += Self.littleEndian(UInt32(2))          // dimension
        expected += [0x00, 0x3C, 0x00, 0xC0]              // 1, -2 as binary16
        #expect(Array(data) == expected)
    }

    @Test func encodingIsDeterministicSortedByIDAndSkipsEntriesWithoutAVector() throws {
        let entries = [
            Self.entry("b", content: "second", vector: [0.5]),
            Self.entry("a", content: "first", vector: [0.25, 0.75]),
            Self.entry("plain", content: "no vector", vector: nil),
            Self.entry("c", content: "third", model: "other", vector: []),
        ]
        let forward = try MemoryVectorFile.encode(Self.graph(entries))
        let backward = try MemoryVectorFile.encode(Self.graph(entries.reversed()))
        #expect(forward == backward)
        #expect(try MemoryVectorFile.encode(Self.graph(entries)) == forward)

        // Record ids in file order.
        var ids: [String] = []
        var offset = MemoryVectorFile.headerSize
        let bytes = Array(forward)
        #expect(bytes[8..<12] == [3, 0, 0, 0])
        for _ in 0..<3 {
            let idLength = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            ids.append(String(decoding: bytes[(offset + 2)..<(offset + 2 + idLength)], as: UTF8.self))
            offset += 2 + idLength + 8 + 4
            let dimension = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
            offset += 4 + dimension * 2
        }
        #expect(ids == ["a", "b", "c"])
        #expect(offset == bytes.count)
    }

    @Test func emptyGraphEncodesAHeaderWithNoRecords() throws {
        let data = try MemoryVectorFile.encode(MemoryGraph())
        #expect(data.count == MemoryVectorFile.headerSize)
        #expect(MemoryVectorFile.decode(data) == [:])
    }

    @Test func encodingRefusesAnIdentifierLongerThanItsLengthField() {
        let long = String(repeating: "x", count: Int(UInt16.max) + 1)
        #expect(throws: MemoryVectorFile.EncodingError.identifierTooLong(long)) {
            try MemoryVectorFile.encode(Self.graph([Self.entry(long, content: "c", vector: [1])]))
        }
    }

    // MARK: - Decoding

    @Test func decodingReturnsEveryRecord() throws {
        let graph = Self.graph([
            Self.entry("a", content: "città", vector: [0.1, -0.2, 3]),
            Self.entry("b", content: "x", model: nil, vector: [65504, -0.0]),
        ])
        let records = try #require(MemoryVectorFile.decode(MemoryVectorFile.encode(graph)))
        #expect(Set(records.keys) == ["a", "b"])
        let a = try #require(records["a"])
        #expect(a.contentByteCount == 6)
        #expect(a.fingerprint == MemoryVectorFile.fingerprint(model: "m", content: "città"))
        #expect(a.components == graph.memories["a"]?.embedding)
        let b = try #require(records["b"])
        #expect(b.components.map(\.bitPattern) == [Float(65504).bitPattern, Float(-0.0).bitPattern])
    }

    /// The component type is in the header: a binary32 file decodes losslessly
    /// whatever precision this build writes.
    @Test func binary32FilesDecodeExactly() throws {
        var entry = Self.entry("a", content: "x", vector: nil)
        entry.setEmbeddingWithoutRounding([0.1, 1.0 / 3.0, -1e-30], model: "m")
        let data = try MemoryVectorFile.encode(Self.graph([entry]), componentType: .binary32)
        #expect(Array(data[6..<8]) == [2, 0])
        let record = try #require(MemoryVectorFile.decode(data)?["a"])
        #expect(record.components.map(\.bitPattern) == [Float(0.1), Float(1.0 / 3.0), Float(-1e-30)].map(\.bitPattern))
    }

    @Test func everyTruncationIsRejected() throws {
        let data = try MemoryVectorFile.encode(Self.graph([
            Self.entry("a", content: "x", vector: [1, 2, 3]),
            Self.entry("b", content: "y", vector: [4]),
        ]))
        for length in 0..<data.count {
            #expect(MemoryVectorFile.decode(data.prefix(length)) == nil, "length \(length)")
        }
        #expect(MemoryVectorFile.decode(data) != nil)
        #expect(MemoryVectorFile.decode(data + [0]) == nil)
    }

    @Test func malformedHeadersAreRejected() throws {
        let valid = Array(try MemoryVectorFile.encode(Self.graph([Self.entry("a", content: "x", vector: [1])])))
        func patched(_ range: Range<Int>, _ bytes: [UInt8]) -> Data {
            var copy = valid
            copy.replaceSubrange(range, with: bytes)
            return Data(copy)
        }
        #expect(MemoryVectorFile.decode(patched(0..<4, Array("ZMVG".utf8))) == nil)        // magic
        #expect(MemoryVectorFile.decode(patched(4..<6, [2, 0])) == nil)                     // version
        #expect(MemoryVectorFile.decode(patched(6..<8, [3, 0])) == nil)                     // component type
        #expect(MemoryVectorFile.decode(patched(6..<8, [0, 0])) == nil)
        #expect(MemoryVectorFile.decode(patched(8..<12, [2, 0, 0, 0])) == nil)              // count too high
        #expect(MemoryVectorFile.decode(patched(8..<12, [0, 0, 0, 0])) == nil)              // count too low
    }

    /// Lengths that would make a reader run past the end, or allocate for
    /// records that cannot be there, reject the file without reading further.
    @Test func hugeLengthsAreRejectedWithoutAllocating() {
        var header: [UInt8] = Array("ZMVF".utf8) + Self.littleEndian(UInt16(1)) + Self.littleEndian(UInt16(1))
        #expect(MemoryVectorFile.decode(Data(header + Self.littleEndian(UInt32.max))) == nil)
        header += Self.littleEndian(UInt32(1))

        // An id length past the end.
        let longID = header + Self.littleEndian(UInt16.max) + Array(repeating: 0x61, count: 30)
        #expect(MemoryVectorFile.decode(Data(longID)) == nil)

        // A dimension past the end.
        let record = Self.littleEndian(UInt16(1)) + [0x61] + Self.littleEndian(UInt64(0))
            + Self.littleEndian(UInt32(1))
        #expect(MemoryVectorFile.decode(Data(header + record + Self.littleEndian(UInt32.max) + [0, 0])) == nil)
        #expect(MemoryVectorFile.decode(Data(header + record + Self.littleEndian(UInt32(2)) + [0, 0])) == nil)
        #expect(MemoryVectorFile.decode(Data(header + record + Self.littleEndian(UInt32(1)) + [0, 0x3C]))?["a"]?.components == [1])
    }

    @Test func invalidUTF8AndDuplicateIDsAreRejected() {
        let header: [UInt8] = Array("ZMVF".utf8) + Self.littleEndian(UInt16(1)) + Self.littleEndian(UInt16(1))
        func record(_ id: [UInt8]) -> [UInt8] {
            Self.littleEndian(UInt16(id.count)) + id + Self.littleEndian(UInt64(7))
                + Self.littleEndian(UInt32(1)) + Self.littleEndian(UInt32(1)) + [0, 0x3C]
        }
        let invalid = header + Self.littleEndian(UInt32(1)) + record([0xC3, 0x28])
        #expect(MemoryVectorFile.decode(Data(invalid)) == nil)
        let duplicate = header + Self.littleEndian(UInt32(2)) + record([0x61]) + record([0x61])
        #expect(MemoryVectorFile.decode(Data(duplicate)) == nil)
        let distinct = header + Self.littleEndian(UInt32(2)) + record([0x61]) + record([0x62])
        #expect(MemoryVectorFile.decode(Data(distinct))?.count == 2)
    }

    // MARK: - Assignment

    /// A vector reaches only the entry it was written for: same id, same
    /// content and same model. Anything else leaves the entry without a vector.
    @Test func vectorsAttachOnlyToTheEntryTheyWereWrittenFor() throws {
        let written = Self.graph([
            Self.entry("same", content: "unchanged", vector: [1, 2]),
            Self.entry("edited", content: "abc", vector: [3, 4]),
            Self.entry("longer", content: "short", vector: [5, 6]),
            Self.entry("remodelled", content: "text", model: "old", vector: [7, 8]),
            Self.entry("removed", content: "gone", vector: [9, 10]),
        ])
        let records = try #require(MemoryVectorFile.decode(MemoryVectorFile.encode(written)))

        var loaded = Self.graph([
            Self.entry("same", content: "unchanged", vector: nil),
            Self.entry("edited", content: "abd", vector: nil),              // same length, other text
            Self.entry("longer", content: "short!", vector: nil),           // other length
            Self.entry("remodelled", content: "text", model: "new", vector: nil),
            Self.entry("added", content: "gone", vector: nil),              // another id
        ])
        let attached = MemoryVectorFile.attach(records, to: &loaded)

        #expect(attached == 1)
        #expect(loaded.memories["same"]?.embedding == [1, 2])
        #expect(loaded.memories["same"]?.embeddingModel == "m")
        for id in ["edited", "longer", "remodelled", "added"] {
            #expect(loaded.memories[id]?.embedding == nil, "\(id)")
        }
        #expect(loaded.memories["removed"] == nil)
        #expect(loaded.memories["remodelled"]?.embeddingModel == "new")
    }
}
