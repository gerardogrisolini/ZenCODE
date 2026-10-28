//
//  MemoryVectorFile.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/10/26.
//
//  The binary file that holds a graph's embedding vectors next to its JSON
//  (`memory.graph.json.vectors`) from graph version 4 on.
//

import Foundation

/// Encoding of the vectors file.
///
/// Every integer is little-endian, whatever the platform, and the output is
/// deterministic: the same graph always yields the same bytes.
///
/// ```
/// header   magic        4 bytes  "ZMVF"
///          version      UInt16   1
///          component    UInt16   1 = binary16, 2 = binary32
///          count        UInt32   number of records
/// record   idLength     UInt16   byte length of the id
///          id           idLength bytes of UTF-8
///          fingerprint  UInt64   FNV-1a 64 of UTF-8(model) 0x00 UTF-8(content)
///          contentBytes UInt32   byte length of the UTF-8 content
///          dimension    UInt32   number of components
///          components   dimension × 2 (binary16) or × 4 (binary32) bytes
/// ```
///
/// Records are sorted by the UTF-8 bytes of the id; ids are unique. A vector
/// is given to an entry only when the entry of the JSON just loaded has that
/// id, the same content byte length and the same fingerprint of its
/// `embedding_model` (`unspecified` when absent) and `content`. The
/// fingerprint detects accidental mismatches — a JSON and a vectors file from
/// different saves, a copied backup — not tampering: the file is owner-only.
///
/// Decoding is all or nothing: a truncated file, a wrong magic, an unknown
/// version or component type, a length that runs past the end, trailing
/// bytes, invalid UTF-8 or a duplicate id make the whole file unusable, and
/// the graph then loads without vectors.
enum MemoryVectorFile {
    static let magic: [UInt8] = Array("ZMVF".utf8)
    static let formatVersion: UInt16 = 1
    static let headerSize = 12
    /// idLength + fingerprint + contentBytes + dimension.
    static let minimumRecordSize = 18

    enum ComponentType: UInt16, Sendable {
        case binary16 = 1
        case binary32 = 2

        var byteCount: Int {
            switch self {
            case .binary16: 2
            case .binary32: 4
            }
        }

        /// `values` at this precision: what writing and reading them back
        /// returns. Returns the same storage when nothing changes.
        func rounded(_ values: [Float]) -> [Float] {
            switch self {
            case .binary16: HalfPrecision.rounded(values)
            case .binary32: values
            }
        }
    }

    /// Precision every save writes, and therefore the precision at which an
    /// entry holds its vector in memory (see `EngineMemoryEntry.embedding`).
    /// Binary16 was chosen by measurement: on a real 289-entry graph with
    /// 2 560-dimension vectors it changed no top-5 of the A/B harness.
    static let storedComponentType: ComponentType = .binary16

    struct Record: Equatable, Sendable {
        let id: String
        let fingerprint: UInt64
        let contentByteCount: UInt32
        let components: [Float]
        /// Precision of the file the record was read from.
        var componentType: ComponentType = MemoryVectorFile.storedComponentType
    }

    enum EncodingError: Error, Equatable {
        /// An id longer than 65 535 UTF-8 bytes cannot be stored.
        case identifierTooLong(String)
    }

    // MARK: - Fingerprint

    /// 64-bit FNV-1a over the UTF-8 bytes of `model`, one 0x00 byte and the
    /// UTF-8 bytes of `content`. Stable across platforms and processes.
    static func fingerprint(model: String, content: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        for byte in model.utf8 { mix(byte) }
        mix(0)
        for byte in content.utf8 { mix(byte) }
        return hash
    }

    static func fingerprint(of entry: EngineMemoryEntry) -> UInt64 {
        fingerprint(model: entry.effectiveEmbeddingModel, content: entry.content)
    }

    // MARK: - Encoding

    /// The vectors file of `graph`: one record per entry with a vector,
    /// archived entries included.
    static func encode(
        _ graph: MemoryGraph,
        componentType: ComponentType = storedComponentType
    ) throws -> Data {
        var records: [(id: [UInt8], entry: EngineMemoryEntry, vector: [Float])] = []
        records.reserveCapacity(graph.memories.count)
        var size = headerSize
        for entry in graph.memories.values {
            guard let vector = entry.embedding else { continue }
            let id = Array(entry.id.utf8)
            guard id.count <= Int(UInt16.max) else {
                throw EncodingError.identifierTooLong(entry.id)
            }
            records.append((id, entry, vector))
            size += minimumRecordSize + id.count + vector.count * componentType.byteCount
        }
        records.sort { $0.id.lexicographicallyPrecedes($1.id) }

        var data = Data(count: size)
        data.withUnsafeMutableBytes { raw in
            var writer = Writer(buffer: raw)
            writer.put(magic)
            writer.put(formatVersion)
            writer.put(componentType.rawValue)
            writer.put(UInt32(records.count))
            for record in records {
                writer.put(UInt16(record.id.count))
                writer.put(record.id)
                writer.put(fingerprint(of: record.entry))
                writer.put(UInt32(record.entry.content.utf8.count))
                writer.put(UInt32(record.vector.count))
                switch componentType {
                case .binary16:
                    for component in record.vector {
                        writer.put(HalfPrecision.bits(from: component))
                    }
                case .binary32:
                    for component in record.vector {
                        writer.put(component.bitPattern)
                    }
                }
            }
            assert(writer.offset == raw.count, "vectors file size mismatch")
        }
        return data
    }

    /// Sequential little-endian writer over a buffer sized in advance.
    private struct Writer {
        let buffer: UnsafeMutableRawBufferPointer
        var offset = 0

        mutating func put<T: FixedWidthInteger>(_ value: T) {
            buffer.storeBytes(of: value.littleEndian, toByteOffset: offset, as: T.self)
            offset += MemoryLayout<T>.size
        }

        mutating func put(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            bytes.withUnsafeBytes { source in
                UnsafeMutableRawBufferPointer(rebasing: buffer[offset..<(offset + source.count)])
                    .copyMemory(from: source)
            }
            offset += bytes.count
        }
    }

    // MARK: - Decoding

    /// The records of a vectors file keyed by id, or `nil` when the file is
    /// unusable as a whole.
    static func decode(_ data: Data) -> [String: Record]? {
        data.withUnsafeBytes { raw -> [String: Record]? in
            var reader = Reader(raw)
            guard let header = reader.bytes(4), Array(header) == magic,
                  let version: UInt16 = reader.integer(), version == formatVersion,
                  let typeValue: UInt16 = reader.integer(),
                  let componentType = ComponentType(rawValue: typeValue),
                  let count: UInt32 = reader.integer() else {
                return nil
            }
            // Every record takes at least `minimumRecordSize` bytes, so a count
            // the remaining bytes cannot hold is rejected before anything is
            // allocated for it.
            guard UInt64(count) * UInt64(minimumRecordSize) <= UInt64(reader.remaining) else {
                return nil
            }
            var records: [String: Record] = [:]
            records.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let idLength: UInt16 = reader.integer(),
                      let idBytes = reader.bytes(Int(idLength)),
                      let id = String(validating: idBytes, as: UTF8.self),
                      records[id] == nil,
                      let fingerprint: UInt64 = reader.integer(),
                      let contentByteCount: UInt32 = reader.integer(),
                      let dimension: UInt32 = reader.integer() else {
                    return nil
                }
                let (byteCount, overflow) = Int(dimension)
                    .multipliedReportingOverflow(by: componentType.byteCount)
                guard !overflow, let payload = reader.bytes(byteCount) else {
                    return nil
                }
                records[id] = Record(
                    id: id,
                    fingerprint: fingerprint,
                    contentByteCount: contentByteCount,
                    components: components(payload, componentType: componentType),
                    componentType: componentType
                )
            }
            guard reader.remaining == 0 else { return nil }
            return records
        }
    }

    private static func components(
        _ payload: UnsafeRawBufferPointer.SubSequence,
        componentType: ComponentType
    ) -> [Float] {
        let bytes = UnsafeRawBufferPointer(rebasing: payload)
        let count = bytes.count / componentType.byteCount
        return [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            switch componentType {
            case .binary16:
                for index in 0..<count {
                    let bits = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 2, as: UInt16.self))
                    buffer[index] = HalfPrecision.value(fromBits: bits)
                }
            case .binary32:
                for index in 0..<count {
                    let bits = UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
                    buffer[index] = Float(bitPattern: bits)
                }
            }
            initialized = count
        }
    }

    /// Bounds-checked sequential reader: every read either fits in the
    /// remaining bytes or returns `nil` without moving.
    private struct Reader {
        let buffer: UnsafeRawBufferPointer
        var offset = 0

        init(_ buffer: UnsafeRawBufferPointer) {
            self.buffer = buffer
        }

        var remaining: Int { buffer.count - offset }

        mutating func bytes(_ count: Int) -> UnsafeRawBufferPointer.SubSequence? {
            guard count >= 0, count <= remaining else { return nil }
            defer { offset += count }
            return buffer[offset..<(offset + count)]
        }

        mutating func integer<T: FixedWidthInteger>() -> T? {
            let size = MemoryLayout<T>.size
            guard size <= remaining else { return nil }
            defer { offset += size }
            return T(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
    }

    // MARK: - Assignment

    /// Gives every entry of `graph` the vector of its record when the record
    /// matches the entry exactly (id, content byte length, fingerprint), and
    /// returns how many entries received one. Entries without a matching
    /// record keep no vector.
    @discardableResult
    static func attach(_ records: [String: Record], to graph: inout MemoryGraph) -> Int {
        var attached = 0
        for (id, record) in records {
            guard var entry = graph.memories[id],
                  entry.content.utf8.count == Int(record.contentByteCount),
                  fingerprint(of: entry) == record.fingerprint else {
                continue
            }
            if record.componentType == storedComponentType {
                // Widened from the stored precision: already exact, nothing to round.
                entry.setEmbeddingWithoutRounding(record.components, model: entry.embeddingModel)
            } else {
                entry.setEmbedding(record.components, model: entry.embeddingModel)
            }
            graph.memories[id] = entry
            attached += 1
        }
        return attached
    }
}
