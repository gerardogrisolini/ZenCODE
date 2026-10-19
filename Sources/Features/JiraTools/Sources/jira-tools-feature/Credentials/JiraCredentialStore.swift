import Foundation
#if os(macOS)
import Security
#endif
import ToolCore

#if os(macOS)
enum JiraCredentialStore {
    private static let service = "ZenCODE.JiraAPIToken"

    static func load(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw JiraToolsError.missingCredentials }
        guard status == errSecSuccess else { throw JiraToolsError.keychain(status) }
        guard let data = item as? Data,
              let token = String(validating: data, as: UTF8.self)?.nilIfBlank else {
            throw JiraToolsError.invalidConfiguration("Keychain item for account \(account) is not valid UTF-8 text.")
        }
        return token
    }

    static func save(_ apiToken: String, account: String) throws {
        let data = Data(apiToken.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else { throw JiraToolsError.keychain(updateStatus) }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw JiraToolsError.keychain(addStatus) }
    }

    static func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw JiraToolsError.keychain(status) }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
#else
enum JiraCredentialStore {
    static func load(account: String) throws -> String {
        try JiraFileCredentialStore().load(account: account)
    }

    static func save(_ apiToken: String, account: String) throws {
        try JiraFileCredentialStore().save(apiToken, account: account)
    }

    static func remove(account: String) throws {
        try JiraFileCredentialStore().remove(account: account)
    }
}
#endif
