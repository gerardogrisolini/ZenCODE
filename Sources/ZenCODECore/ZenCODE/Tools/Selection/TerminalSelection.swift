import Foundation

/// Shared selection syntax; callers retain their domain-specific matching and errors.
enum TerminalSelection {
    static func parse(
        _ rawSelection: String,
        keys: [String],
        resolve: (String) throws -> String
    ) throws -> Set<String> {
        let tokens = rawSelection
            .replacingOccurrences(of: ",", with: " ")
            .split { $0.isWhitespace }
            .map(String.init)

        if tokens.count == 1 {
            let normalizedToken = tokens[0].lowercased()
            if normalizedToken == "all" {
                return Set(keys)
            }
            if ["none", "off", "clear", "disabled"].contains(normalizedToken) {
                return []
            }
        }

        var selectedKeys = Set<String>()
        for token in tokens {
            if let index = Int(token), keys.indices.contains(index - 1) {
                selectedKeys.insert(keys[index - 1])
            } else {
                selectedKeys.insert(try resolve(token))
            }
        }
        return selectedKeys
    }

    static func lookupKey(_ value: String) -> String {
        let foldedValue = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let characters = foldedValue.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(characters)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
