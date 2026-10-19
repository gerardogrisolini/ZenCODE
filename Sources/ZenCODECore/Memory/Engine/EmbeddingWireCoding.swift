//
//  EmbeddingWireCoding.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 19/10/26.
//
//  Wire form of an entry's embedding vector inside the graph JSON.
//

import Foundation

/// Encodes an embedding vector for the graph file.
///
/// Graph version 3 stores a vector as one base64 string of its IEEE-754
/// binary32 components in little-endian byte order. Up to version 2 the vector
/// was a numeric JSON array: pretty-printed, every component cost about twenty
/// bytes of decimal text, so real-world vectors (4 096 dimensions) made the
/// file and its decode time two orders of magnitude larger than the journal
/// they belong to. The binary form is lossless — the bit pattern of every
/// component is preserved — roughly four times smaller, and decodes without
/// number parsing. Decoding accepts both spellings so a file written by any
/// earlier version keeps loading unchanged; encoding always writes the current
/// form.
enum EmbeddingWireCoding {
    /// One IEEE-754 binary32 per component.
    static let bytesPerComponent = MemoryLayout<UInt32>.size

    static func string(from values: [Float]) -> String {
        data(from: values).base64EncodedString()
    }

    /// `nil` when `string` is not valid base64 or its payload is not a whole
    /// number of components. An empty string is the empty vector.
    static func values(fromBase64 string: String) -> [Float]? {
        guard let data = Data(base64Encoded: string) else { return nil }
        return values(from: data)
    }

    static func data(from values: [Float]) -> Data {
        let bits = values.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func values(from data: Data) -> [Float]? {
        guard data.count % bytesPerComponent == 0 else { return nil }
        let count = data.count / bytesPerComponent
        // One bulk copy into aligned storage, then a reinterpretation per
        // component; the byte-order conversion is a no-op on little-endian hosts.
        let bits = [UInt32](unsafeUninitializedCapacity: count) { buffer, initialized in
            data.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
            initialized = count
        }
        return bits.map { Float(bitPattern: UInt32(littleEndian: $0)) }
    }
}

/// The two spellings of `embedding` accepted on the wire: the version 3
/// base64 string and the numeric array of earlier versions.
enum EmbeddingWireValue: Decodable {
    case base64(String)
    case components([Float])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            self = .base64(string)
            return
        }
        self = .components(try container.decode([Float].self))
    }

    /// The decoded components, or `nil` when the base64 payload is malformed.
    /// The caller reports the corruption with its own coding path.
    var components: [Float]? {
        switch self {
        case let .components(values):
            values
        case let .base64(string):
            EmbeddingWireCoding.values(fromBase64: string)
        }
    }
}
