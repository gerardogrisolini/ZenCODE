//
//  Extensions.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Crypto
import Foundation

extension Data {
    /// Returns a Base64-URL encoded string (no padding, `-`/`_` replacing `+`/`/`).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
