//
//  Extensions.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Crypto
import Foundation
#if canImport(Security)
import Security
#endif

extension Data {
    /// Returns a Base64-URL encoded string (no padding, `-`/`_` replacing `+`/`/`).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func randomBase64URLString(
        byteCount: Int,
        randomBytesFailure: (Int32) -> Error
    ) throws -> String {
        #if canImport(Security)
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw randomBytesFailure(status)
        }
        #else
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }
        #endif
        return Data(bytes).base64URLEncodedString()
    }
    
    func sha256Hex() -> String {
        SHA256.hash(data: self)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension String {
    func sha256Base64URL() -> String {
        Data(SHA256.hash(data: Data(self.utf8))).base64URLEncodedString()
    }
    
    func markdownHeadingTitle() -> String? {
        let trimmedLine = self.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("#") else {
            return nil
        }

        let markerCount = trimmedLine.prefix { $0 == "#" }.count
        guard markerCount <= 3,
              trimmedLine.dropFirst(markerCount).first == " " else {
            return nil
        }

        let title = trimmedLine.dropFirst(markerCount)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
