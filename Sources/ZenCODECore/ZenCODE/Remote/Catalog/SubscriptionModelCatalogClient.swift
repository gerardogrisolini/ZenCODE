import Foundation
import CoreFoundation
import Crypto
import ZenPackageMetadata
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Setup-only authenticated catalog. Never refreshes credentials or changes runtime state.
struct SubscriptionModelCatalogClient: Sendable {
    enum Provider: String, Codable, Sendable { case chatGPT, anthropic }
    struct Model: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let contextWindow: Int?
        let maxContextWindow: Int?
        let maxOutputTokens: Int?
        let reasoningLevels: [String]
        let defaultReasoningLevel: String?
        let inputModalities: [String]
        var anthropicThinkingMode: String? = nil

        var thinkingSupport: ModelThinkingSupport? {
            if anthropicThinkingMode == "enabled" { return .generic }
            let levels = reasoningLevels.compactMap(Self.reasoningSelection)
            guard !levels.isEmpty else { return nil }
            let hasThinking = levels.contains { $0 != .off }
            return ModelThinkingSupport(
                supportsThinking: hasThinking, supportsReasoningEffort: hasThinking,
                supportsPreserveThinking: false,
                availableSelections: anthropicThinkingMode == "adaptive" ? [.off] + levels : levels,
                defaultSelection: defaultReasoningLevel.flatMap(Self.reasoningSelection)
                    .flatMap { levels.contains($0) ? $0 : nil } ?? levels[0]
            )
        }

        static func reasoningSelection(_ wireValue: String) -> ThinkingSelection? {
            switch wireValue {
            case "none", "off": return .off
            default: return ThinkingSelection(rawValue: wireValue)
            }
        }
    }
    struct Snapshot: Codable, Sendable {
        let schema: Int
        let provider: Provider
        let scope: String
        let clientVersion: String
        let fetchedAt: Date
        let models: [Model]
    }
    struct Result: Sendable {
        let models: [Model]
        let fetchedAt: Date
        let isCached: Bool
        let cacheWriteFailed: Bool
    }
    enum CatalogError: LocalizedError {
        case unavailable
        case http(Int)
        case invalidResponse
        var errorDescription: String? {
            switch self {
            case .unavailable: "Subscription catalog unavailable and no valid account-scoped cache exists. Configured models are unchanged."
            case .http(let status): "Subscription catalog HTTP \(status). Configured models are unchanged; cached models do not confirm current access."
            case .invalidResponse: "Subscription catalog returned an invalid response."
            }
        }
    }
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    let directory: URL
    let clientVersion: String
    let transport: Transport

    init(directory: URL = AppStorageDirectory.appSupportDirectoryURL(),
         version: String = ZenPackageMetadata.version,
         transport: @escaping Transport = Self.send) {
        self.directory = directory
        self.clientVersion = Self.normalizedVersion(version)
        self.transport = transport
    }

    static func normalizedVersion(_ value: String) -> String {
        let base = value.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
        let core = base.components(separatedBy: "-")[0].components(separatedBy: "+")[0]
        let components = core.split(separator: ".").prefix(3).map { Int($0) ?? 0 }
        return (components + Array(repeating: 0, count: max(0, 3 - components.count)))
            .map(String.init).joined(separator: ".")
    }

    /// Account identity only, never token or token hash. No identity means no disk cache.
    static func accountScope(_ accountID: String?) -> String? {
        guard let accountID, !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return SHA256.hash(data: Data(("subscription-account-v1:" + accountID).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func cacheURL(provider: Provider, scope: String) -> URL {
        directory.appendingPathComponent("subscription-catalog-\(provider.rawValue)-\(scope).json")
    }

    func load(provider: Provider, accessToken: String, accountID: String? = nil,
              catalogScopeID: UUID? = nil) async throws -> Result {
        try Task.checkCancellation()
        // Anthropic uses a random login lineage maintained by the OAuth manager.
        // Legacy/environment credentials without a lineage do not reuse disk cache.
        let scope = provider == .chatGPT ? Self.accountScope(accountID) : catalogScopeID?.uuidString.lowercased()
        let cache: Snapshot? = scope.flatMap { scope in
            let url = cacheURL(provider: provider, scope: scope)
            guard (try? SensitiveFilePermissions.hardenExistingFile(at: url)) != nil,
                  let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.schema == 1, snapshot.provider == provider, snapshot.scope == scope,
                  snapshot.clientVersion == clientVersion,
                  snapshot.fetchedAt <= Date(), Self.valid(snapshot.models) else { return nil }
            return snapshot
        }
        do {
            let models = try await fetch(provider: provider, accessToken: accessToken, accountID: accountID)
            try Task.checkCancellation()
            let now = Date()
            var writeFailed = false
            if let scope {
                let snapshot = Snapshot(schema: 1, provider: provider, scope: scope,
                                        clientVersion: clientVersion, fetchedAt: now, models: models)
                do {
                    try SensitiveFilePermissions.write(JSONEncoder().encode(snapshot),
                                                       to: cacheURL(provider: provider, scope: scope))
                } catch { writeFailed = true }
            }
            return Result(models: models, fetchedAt: now, isCached: false, cacheWriteFailed: writeFailed)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if case CatalogError.http(let status) = error, status == 401 || status == 403 { throw error }
            guard let cache else { throw CatalogError.unavailable }
            return Result(models: cache.models, fetchedAt: cache.fetchedAt, isCached: true, cacheWriteFailed: false)
        }
    }

    func fetch(provider: Provider, accessToken: String, accountID: String?) async throws -> [Model] {
        var models: [Model] = []
        var cursor: String?
        var cursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            var components = URLComponents(string: provider == .chatGPT
                ? "https://chatgpt.com/backend-api/codex/models" : "https://api.anthropic.com/v1/models")!
            if provider == .chatGPT {
                components.queryItems = [URLQueryItem(name: "client_version", value: clientVersion)]
            } else if let cursor {
                components.queryItems = [URLQueryItem(name: "after_id", value: cursor)]
            }
            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            request.timeoutInterval = 10
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            if provider == .chatGPT, let accountID {
                request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
            } else if provider == .anthropic {
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                request.setValue(AnthropicSubscriptionGenerationClient.oauthBetaHeader, forHTTPHeaderField: "anthropic-beta")
            }
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            guard response.statusCode == 200 else { throw CatalogError.http(response.statusCode) }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = root[provider == .chatGPT ? "models" : "data"] as? [[String: Any]] else {
                throw CatalogError.invalidResponse
            }
            for entry in entries {
                guard let id = entry[provider == .chatGPT ? "slug" : "id"] as? String, !id.isEmpty else {
                    throw CatalogError.invalidResponse
                }
                if provider == .chatGPT {
                    guard entry["visibility"] as? String == "list" else { continue }
                    // ZenCODE's version identifies this client; it is not a Codex compatibility version.
                    // The provider's visible catalog is authoritative; do not compare unrelated versions.
                }
                var levels = (entry["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                    .compactMap { $0["effort"] as? String }
                var anthropicMode: String?
                var modalities = entry["input_modalities"] as? [String] ?? []
                if provider == .anthropic {
                    let capabilities = entry["capabilities"] as? [String: Any] ?? [:]
                    let thinking = capabilities["thinking"] as? [String: Any] ?? [:]
                    let types = thinking["types"] as? [String: Any] ?? [:]
                    let effort = capabilities["effort"] as? [String: Any] ?? [:]
                    anthropicMode = "disabled"
                    if thinking["supported"] as? Bool == true {
                        if Self.supported(types["adaptive"]), effort["supported"] as? Bool == true {
                            levels = ["low", "medium", "high", "xhigh", "max"].filter { Self.supported(effort[$0]) }
                            if !levels.isEmpty { anthropicMode = "adaptive" }
                        } else if Self.supported(types["enabled"]) {
                            anthropicMode = "enabled"
                        }
                    }
                    modalities = ["text"]
                    if Self.supported(capabilities["image_input"]) { modalities.append("image") }
                    if Self.supported(capabilities["pdf_input"]) { modalities.append("pdf") }
                }
                models.append(Model(id: id, title: entry["display_name"] as? String ?? id,
                    contextWindow: positive(entry[provider == .chatGPT ? "context_window" : "max_input_tokens"]),
                    maxContextWindow: positive(entry["max_context_window"]),
                    maxOutputTokens: positive(entry["max_tokens"]),
                    reasoningLevels: levels,
                    defaultReasoningLevel: entry["default_reasoning_level"] as? String,
                    inputModalities: modalities, anthropicThinkingMode: anthropicMode))
            }
            cursor = nil
            if provider == .anthropic {
                // JSONSerialization bridges numbers too: accept only an actual JSON boolean.
                guard let hasMore = root["has_more"] as? NSNumber,
                      CFGetTypeID(hasMore) == CFBooleanGetTypeID() else { throw CatalogError.invalidResponse }
                if hasMore.boolValue {
                    guard let last = root["last_id"] as? String,
                          !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          cursors.insert(last).inserted, cursors.count < 100 else { throw CatalogError.invalidResponse }
                    cursor = last
                }
            }
        } while cursor != nil
        guard Self.valid(models) else { throw CatalogError.invalidResponse }
        return models
    }

    private static func supported(_ value: Any?) -> Bool {
        (value as? [String: Any])?["supported"] as? Bool == true
    }

    private func positive(_ value: Any?) -> Int? {
        guard let value = value as? Int, value > 0 else { return nil }
        return value
    }
    private static func valid(_ models: [Model]) -> Bool {
        // Empty is a successful authoritative catalog, not a reason to resurrect old models.
        Set(models.map(\.id)).count == models.count && models.allSatisfy { !$0.id.isEmpty }
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
        return (data, response)
    }
}
