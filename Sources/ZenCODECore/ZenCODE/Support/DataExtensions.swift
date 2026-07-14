//
//  DataExtensions.swift
//  ZenCODE
//

import Foundation

extension Data {
    /// Returns a Base64-URL encoded string (no padding, `-`/`_` replacing `+`/`/`).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
