//
//  BrowserTextClipping.swift
//  BrowserToolsFeature
//
//  Shared UTF-8 byte-budget clipping for untrusted page text.
//

extension String {
    /// Longest prefix on Character boundaries whose UTF-8 size fits `budget`.
    func prefixFitting(utf8Bytes budget: Int) -> String {
        var result = ""
        var usedBytes = 0
        for character in self {
            let characterBytes = character.utf8.count
            guard usedBytes + characterBytes <= budget else { break }
            result.append(character)
            usedBytes += characterBytes
        }
        return result
    }
}
