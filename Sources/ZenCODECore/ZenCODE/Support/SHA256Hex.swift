//
//  SHA256Hex.swift
//  ZenCODE
//

import Crypto
import Foundation

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}
