import Foundation

public nonisolated func assignString(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstStringValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .string(value)
}

public nonisolated func assignPathString(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstStringValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .string(normalizedToolPathString(value))
}

public nonisolated func assignStringArray(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let values = firstStringArrayValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .array(values.map(JSONValue.string))
}

public nonisolated func assignNumber(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstNumberValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .number(value)
}

public nonisolated func assignBool(
    _ sourceKeys: [String],
    from arguments: [String: JSONValue],
    to destinationKey: String,
    in normalized: inout [String: JSONValue]
) {
    guard let value = firstBoolValue(sourceKeys, in: arguments) else {
        return
    }

    normalized[destinationKey] = .bool(value)
}

nonisolated func firstStringValue(_ keys: [String], in arguments: [String: JSONValue]) -> String? {
    for key in keys {
        guard let value = arguments[key] else {
            continue
        }

        switch value {
        case let .string(string):
            return string
        case let .number(number):
            guard number.isFinite else {
                continue
            }
            if floor(number) == number,
               let integer = Int(exactly: number) {
                return String(integer)
            }
            return String(number)
        case let .bool(bool):
            return bool ? "true" : "false"
        default:
            continue
        }
    }

    return nil
}

nonisolated func normalizedToolPathString(_ rawValue: String) -> String {
    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty else {
        return rawValue
    }

    let resolvedValue: String
    if trimmedValue.hasPrefix("file://"),
       let url = URL(string: trimmedValue),
       url.isFileURL {
        resolvedValue = url.path
    } else {
        resolvedValue = trimmedValue
    }

    guard !resolvedValue.hasPrefix("/") else {
        return resolvedValue
    }

    let normalizedSeparators = resolvedValue
        .replacingOccurrences(of: "\\", with: "/")
        .replacingOccurrences(of: #"^\./"#, with: "", options: .regularExpression)

    var components = normalizedSeparators
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)

    while components.count >= 2,
          components[0] == components[1],
          !components[0].contains(".") {
        components.removeFirst()
    }

    guard !components.isEmpty else {
        return normalizedSeparators
    }

    return components.joined(separator: "/")
}
