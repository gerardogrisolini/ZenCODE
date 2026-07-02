//
//  MLXServerChatSessionIdentity.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 11/06/26.
//

import CryptoKit
import Foundation
import MLXLMCommon

/// Identity of a chat session's KV cache. A KV cache is only reusable for
/// the same model, runtime and cache layout, so the client-visible session
/// key is scoped by all three.
public struct MLXServerChatSessionCacheKey: Hashable, Sendable {
    public var sessionKey: String
    public var modelID: String
    public var runtimeKind: MLXServerModelRuntimeKind
    public var cacheLayoutSignature: String

    public init(
        sessionKey: String,
        modelID: String,
        runtimeKind: MLXServerModelRuntimeKind,
        cacheLayoutSignature: String
    ) {
        self.sessionKey = sessionKey
        self.modelID = modelID
        self.runtimeKind = runtimeKind
        self.cacheLayoutSignature = cacheLayoutSignature
    }

    /// Stable filesystem-safe key for disk entries and persistence
    /// coalescing.
    public var entryKey: String {
        var hasher = SHA256()
        SHA256.appendLengthPrefixed("mlx-server-chat-session-cache-v1", to: &hasher)
        SHA256.appendLengthPrefixed(sessionKey, to: &hasher)
        SHA256.appendLengthPrefixed(modelID, to: &hasher)
        SHA256.appendLengthPrefixed(runtimeKind.rawValue, to: &hasher)
        SHA256.appendLengthPrefixed(cacheLayoutSignature, to: &hasher)
        return SHA256.hexString(from: hasher.finalize())
    }
}

/// Compact fingerprint of one chat message, used to record which transcript
/// a cached `ChatSession` represents and to verify that a new request is a
/// continuation of it.
public struct MLXServerChatTranscriptFingerprint: Codable, Hashable, Sendable {
    public var role: String
    public var contentDigest: String

    public init(role: String, contentDigest: String) {
        self.role = role
        self.contentDigest = contentDigest
    }

    /// Placeholder appended after a generated assistant turn. The client's
    /// resent assistant message may differ from the raw generated text
    /// (stripped thinking, restructured tool calls), so assistant entries
    /// are matched by role only.
    public static let generatedAssistantPlaceholder = Self(
        role: MLXServerChatMessage.Role.assistant.rawValue,
        contentDigest: ""
    )
}

public enum MLXServerChatSessionTranscript {
    /// Returns the index in `request` where new (not yet cached) messages
    /// start, or nil when the cached transcript cannot serve the request.
    ///
    /// The cached transcript must be a strict prefix of the request:
    /// system, user and tool messages must match exactly by content, while
    /// assistant messages are matched by role only. The KV cache holds the
    /// model's actual generated tokens for assistant turns, which is higher
    /// fidelity than the client's lossy transcript (thinking stripped,
    /// tool-call markup reformatted), so content differences there are
    /// expected and safe to tolerate.
    public static func continuationSuffixStartIndex(
        stored: [MLXServerChatTranscriptFingerprint],
        request: [MLXServerChatTranscriptFingerprint]
    ) -> Int? {
        matchingPrefixEndIndex(
            stored: stored,
            request: request,
            acceptsCompleteMatch: false
        )
    }

    /// Returns the request index immediately after the cached transcript
    /// prefix, accepting an exact match. This is used when a saved session is
    /// loaded and its KV cache is restored before the next user turn exists.
    public static func storedPrefixEndIndex(
        stored: [MLXServerChatTranscriptFingerprint],
        request: [MLXServerChatTranscriptFingerprint]
    ) -> Int? {
        matchingPrefixEndIndex(
            stored: stored,
            request: request,
            acceptsCompleteMatch: true
        )
    }

    private static func matchingPrefixEndIndex(
        stored: [MLXServerChatTranscriptFingerprint],
        request: [MLXServerChatTranscriptFingerprint],
        acceptsCompleteMatch: Bool
    ) -> Int? {
        guard !stored.isEmpty else {
            return nil
        }
        let assistantRole = MLXServerChatMessage.Role.assistant.rawValue
        var storedIndex = 0
        var requestIndex = 0

        while storedIndex < stored.count {
            guard requestIndex < request.count else {
                return nil
            }
            let storedFingerprint = stored[storedIndex]
            let requestFingerprint = request[requestIndex]
            guard storedFingerprint.role == requestFingerprint.role else {
                return nil
            }

            if storedFingerprint.role == assistantRole {
                // A generated assistant turn is stored as one placeholder,
                // while clients may replay it as one or more assistant
                // messages (e.g. reasoning summary + visible content/tool
                // call). The KV cache already contains the model's raw
                // generated tokens, so consume the whole replayed assistant
                // run and resume from the following non-assistant message.
                if storedFingerprint.contentDigest.isEmpty {
                    repeat {
                        requestIndex += 1
                    } while requestIndex < request.count
                        && request[requestIndex].role == assistantRole
                } else {
                    requestIndex += 1
                }
                storedIndex += 1
                continue
            }

            guard storedFingerprint.contentDigest == requestFingerprint.contentDigest else {
                return nil
            }
            storedIndex += 1
            requestIndex += 1
        }

        return acceptsCompleteMatch || requestIndex < request.count ? requestIndex : nil
    }

    /// Fallback session key for clients that do not send a session
    /// identifier: the conversation opening (system prompt and first user
    /// message) identifies the session, which matches the standard
    /// stateless pattern of resending a growing transcript.
    public static func derivedSessionKey(
        messages: [MLXServerChatMessage]
    ) -> String {
        var hasher = SHA256()
        SHA256.appendLengthPrefixed("mlx-server-derived-session-key-v1", to: &hasher)
        let firstSystem = messages.first { $0.role == .system }
        let firstUser = messages.first { $0.role == .user }
        SHA256.appendLengthPrefixed(firstSystem?.content ?? "", to: &hasher)
        SHA256.appendLengthPrefixed(firstUser?.content ?? "", to: &hasher)
        return "derived-" + SHA256.hexString(from: hasher.finalize())
    }
}

extension MLXServerChatMessage {
    /// Fingerprint of this message for transcript continuation matching.
    public var transcriptFingerprint: MLXServerChatTranscriptFingerprint {
        var hasher = SHA256()
        SHA256.appendLengthPrefixed("mlx-server-chat-message-fingerprint-v1", to: &hasher)
        SHA256.appendLengthPrefixed(content, to: &hasher)
        SHA256.appendLengthPrefixed(toolCallID ?? "", to: &hasher)
        SHA256.appendLengthPrefixed(toolName ?? "", to: &hasher)
        for toolCall in toolCalls {
            SHA256.appendLengthPrefixed(toolCall.id ?? "", to: &hasher)
            SHA256.appendLengthPrefixed(toolCall.function.name, to: &hasher)
        }
        return MLXServerChatTranscriptFingerprint(
            role: role.rawValue,
            contentDigest: SHA256.hexString(from: hasher.finalize())
        )
    }
}

/// Signature of the generation parameters that determine the KV cache
/// layout. Caches created under different layouts are not interchangeable.
public enum MLXServerChatSessionCacheSignature {
    public static func cacheLayout(_ parameters: GenerateParameters) -> String {
        [
            "kvBits=\(parameters.kvBits.map(String.init) ?? "nil")",
            "kvGroupSize=\(parameters.kvGroupSize)",
            "quantizedKVStart=\(parameters.quantizedKVStart)",
            "maxKVSize=\(parameters.maxKVSize.map(String.init) ?? "nil")"
        ].joined(separator: "&")
    }
}

/// Deterministic signatures for request facets that change the rendered
/// prompt prefix (tools, additional template context). A cached session is
/// only continued when these match, because the chat template renders them
/// into the prompt preamble that the KV cache already encodes.
public enum MLXServerChatSessionRequestSignature {
    public static func tools(_ tools: [ToolSpec]?) -> String {
        guard let tools, !tools.isEmpty else {
            return "none"
        }
        return digest(tools.map(canonicalDescription).joined(separator: "\u{1C}"))
    }

    public static func additionalContext(_ context: [String: any Sendable]?) -> String {
        guard let context, !context.isEmpty else {
            return "none"
        }
        return digest(canonicalDescription(context))
    }

    private static func digest(_ value: String) -> String {
        var hasher = SHA256()
        SHA256.appendLengthPrefixed(value, to: &hasher)
        return SHA256.hexString(from: hasher.finalize())
    }

    /// Mirror-based canonical rendering with sorted dictionary keys, so the
    /// same logical payload always produces the same signature.
    static func canonicalDescription(_ value: Any) -> String {
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let child = mirror.children.first else {
                return "null"
            }
            return canonicalDescription(child.value)
        }
        if let string = value as? String {
            return "s:\(string)"
        }
        if let bool = value as? Bool {
            return "b:\(bool)"
        }
        if let int = value as? Int {
            return "i:\(int)"
        }
        if let double = value as? Double {
            return "d:\(double)"
        }
        if let float = value as? Float {
            return "d:\(Double(float))"
        }
        if mirror.displayStyle == .collection {
            let elements = mirror.children.map { canonicalDescription($0.value) }
            return "[\(elements.joined(separator: ","))]"
        }
        if mirror.displayStyle == .dictionary {
            var pairs: [(String, String)] = []
            for child in mirror.children {
                let pair = Array(Mirror(reflecting: child.value).children)
                guard pair.count == 2, let key = pair[0].value as? String else {
                    continue
                }
                pairs.append((key, canonicalDescription(pair[1].value)))
            }
            pairs.sort { $0.0 < $1.0 }
            let rendered = pairs.map { "\($0.0)=\($0.1)" }
            return "{\(rendered.joined(separator: ","))}"
        }
        return "x:\(String(describing: value))"
    }
}

extension SHA256 {
    static func appendLengthPrefixed(_ value: String, to hasher: inout SHA256) {
        let data = Data(value.utf8)
        var count = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &count) { rawBuffer in
            hasher.update(data: Data(rawBuffer))
        }
        hasher.update(data: data)
    }

    static func hexString<D: Sequence>(
        from digest: D
    ) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
