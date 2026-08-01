//
//  ContextHashing.swift
//  ZenCODE
//

import Foundation

enum ContextFileReadState {
    case missing
    case loaded(String)
    case unreadable
}

func readContextFile(
    at fileURL: URL,
    fileManager: FileManager
) -> ContextFileReadState {
    guard fileManager.fileExists(atPath: fileURL.path) else {
        return .missing
    }

    do {
        return .loaded(try String(contentsOf: fileURL, encoding: .utf8))
    } catch {
        return .unreadable
    }
}

func fnv1aHash(_ value: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}
