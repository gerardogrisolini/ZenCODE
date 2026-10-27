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
