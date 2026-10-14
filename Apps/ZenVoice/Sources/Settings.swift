import Foundation

/// Connection details are read from ZenCODE for each activation, never persisted by ZenVoice.
enum VoiceProvider: Sendable {
    case api, chatGPTSubscription
}

enum VoiceConnection: Sendable {
    case api(key: String)
    case chatGPTSubscription

    var provider: VoiceProvider {
        switch self {
        case .api: .api
        case .chatGPTSubscription: .chatGPTSubscription
        }
    }
}

struct Settings: Codable, Sendable {
    static let executable = "/usr/local/bin/zen"
    var projects: [String] = []

    // Decoding only projects also migrates the old settings without retaining connection overrides.
    static func load(defaults: UserDefaults = .standard) -> Settings {
        guard let data = defaults.data(forKey: "settings"),
              let value = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return value
    }

    func save(defaults: UserDefaults = .standard) throws {
        defaults.set(try JSONEncoder().encode(self), forKey: "settings")
    }
    static func canonicalProject(_ path: String) throws -> String {
        guard path.hasPrefix("/") else { throw VoiceError.invalid("Usa percorsi assoluti") }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { throw VoiceError.invalid("Cartella progetto inesistente") }
        // A subdirectory shares the checkout lock of its nearest .git directory/file.
        var root = url
        while root.path != "/" {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) { return root.path }
            root.deleteLastPathComponent()
        }
        return url.path
    }
    func validated(requiresProjects: Bool = true) throws -> Settings {
        guard !requiresProjects || !projects.isEmpty else {
            throw VoiceError.invalid("Scegli almeno un progetto consentito")
        }
        return Settings(projects: try Array(Set(projects.map(Self.canonicalProject))).sorted())
    }
}

struct RegisteredProject: Identifiable, Sendable {
    let name: String
    let path: String
    var id: String { path }
}

enum ZenCODEConfiguration {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zencode", isDirectory: true)
    }

    static func loadConnection(directory: URL = directory, now: Date = Date()) throws -> VoiceConnection {
        let data: Data
        do {
            data = try Data(contentsOf: directory.appendingPathComponent("settings.json"))
        } catch {
            throw VoiceError.invalid("Configurazione assente o non leggibile: ~/.zencode/settings.json. Configura ZenCODE prima di attivare ZenVoice.")
        }
        return try connection(from: data, now: now)
    }

    static func connection(from data: Data, now: Date = Date()) throws -> VoiceConnection {
        let manifest: ConnectionManifest
        do {
            manifest = try JSONDecoder().decode(ConnectionManifest.self, from: data)
        } catch {
            // Decoder errors can contain credential data: expose only a fixed diagnostic.
            throw VoiceError.invalid("Configurazione non valida in ~/.zencode/settings.json")
        }
        guard (4...13).contains(manifest.version) else {
            throw VoiceError.invalid("Versione di ~/.zencode/settings.json non supportata")
        }
        let models = manifest.models.filter { $0.id == manifest.selected?.modelID }
        guard models.count == 1, let providerID = models.first?.providerID else {
            throw VoiceError.invalid("Seleziona una connessione remota in ZenCODE prima di attivare ZenVoice")
        }
        let providers = manifest.providers.filter { $0.id == providerID }
        guard providers.count == 1, let provider = providers.first else {
            throw VoiceError.invalid("Connessione selezionata assente o ambigua in ~/.zencode/settings.json")
        }

        if provider.providerProfileID == "openai",
           provider.protocolProfileID == "openai.chatgpt-subscription",
           provider.authPolicy == "chatgpt_subscription",
           provider.baseURL.lowercased() == "chatgpt://subscription" {
            guard let login = manifest.chatGPTSubscriptionCredentials, login.isPresent else {
                throw VoiceError.invalid("Login ChatGPT assente: configura ZenCODE prima di attivare ZenVoice")
            }
            guard login.expiresAt.timeIntervalSince(now) > 60 else {
                throw VoiceError.invalid("Login ChatGPT scaduto: rinnova il login in ZenCODE")
            }
            return .chatGPTSubscription
        }

        // An OpenAI-compatible chat endpoint is not necessarily an OpenAI Realtime service.
        guard provider.providerProfileID == "openai",
              ["openai.chat-completions", "openai.responses"].contains(provider.protocolProfileID),
              ["api_key_required", "api_key_optional"].contains(provider.authPolicy),
              let url = URL(string: provider.baseURL), url.scheme == "https",
              url.host?.lowercased() == "api.openai.com", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              ["", "/", "/v1", "/v1/"].contains(url.path) else {
            throw VoiceError.invalid("La connessione selezionata in ZenCODE non supporta la voce di ZenVoice. Usa ChatGPT Subscription oppure OpenAI API; nessun fallback automatico.")
        }
        let key = manifest.remoteAPIKeysByProviderID?[providerID.uuidString.lowercased()]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty, key.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw VoiceError.invalid("Chiave OpenAI API assente o non valida in ~/.zencode/settings.json")
        }
        return .api(key: key)
    }

    static func loadProjects(directory: URL = directory, including savedPaths: [String] = []) throws -> [RegisteredProject] {
        var projects: [String: RegisteredProject] = [:]
        func add(_ path: String?, name: String? = nil) {
            guard let path, let canonical = try? Settings.canonicalProject(path), projects[canonical] == nil else { return }
            let label = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            projects[canonical] = RegisteredProject(
                name: label.isEmpty ? URL(fileURLWithPath: canonical).lastPathComponent : label,
                path: canonical
            )
        }

        let foldersURL = directory.appendingPathComponent("ui-working-folders.plist")
        if FileManager.default.fileExists(atPath: foldersURL.path) {
            do {
                let folders = try PropertyListDecoder().decode(WorkingFolders.self, from: Data(contentsOf: foldersURL))
                guard folders.version == 1 else { throw VoiceError.invalid("Versione indice progetti non supportata") }
                for project in folders.projects { add(project.path, name: project.name) }
            } catch {
                throw VoiceError.invalid("Impossibile leggere i progetti da ~/.zencode/ui-working-folders.plist")
            }
        }

        let sessionsURL = directory.appendingPathComponent("sessions.json")
        if FileManager.default.fileExists(atPath: sessionsURL.path) {
            do {
                // Read only the global project index, never individual session files or conversations.
                let index = try JSONDecoder().decode(SessionIndex.self, from: Data(contentsOf: sessionsURL))
                guard index.version == 1 else { throw VoiceError.invalid("Versione indice progetti non supportata") }
                for session in index.sessions { add(session.projectPath) }
            } catch {
                throw VoiceError.invalid("Impossibile leggere i progetti da ~/.zencode/sessions.json")
            }
        }
        for path in savedPaths { add(path) }
        return projects.values.sorted { $0.path < $1.path }
    }

    private struct ConnectionManifest: Decodable {
        let version: Int
        let selected: Selection?
        let models: [Model]
        let providers: [Provider]
        let remoteAPIKeysByProviderID: [String: String]?
        let chatGPTSubscriptionCredentials: SubscriptionLogin?
    }

    private struct Selection: Decodable {
        let modelID: String?
    }

    private struct Model: Decodable {
        let id: String
        let providerID: UUID?
    }

    private struct Provider: Decodable {
        let id: UUID
        let baseURL: String
        let providerProfileID: String
        let protocolProfileID: String
        let authPolicy: String
    }

    private struct SubscriptionLogin: Decodable {
        let isPresent: Bool
        let expiresAt: Date
        private enum CodingKeys: String, CodingKey { case accessToken, accountID, expiresAt }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // Retain readiness only, not subscription secrets. Authentication remains owned by zen.
            let token = try values.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
            let account = try values.decodeIfPresent(String.self, forKey: .accountID) ?? ""
            isPresent = !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        }
    }

    private struct WorkingFolders: Decodable {
        let version: Int
        let projects: [Entry]
        struct Entry: Decodable {
            let name: String?
            let path: String?
        }
    }

    private struct SessionIndex: Decodable {
        let version: Int
        let sessions: [Entry]
        struct Entry: Decodable {
            let projectPath: String?
        }
    }
}
