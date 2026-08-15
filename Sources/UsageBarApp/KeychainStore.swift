import Foundation
import Security
import UsageBarCore

/// Credentials live in the Keychain. Never in a file, never in a log.
enum KeychainStore {
    private static let service = AppIdentity.keychainService
    private static let account = "credentials"

    private struct Stored: Codable {
        var accounts: [StoredAccount]?
        // Pre-multi-account fields. Read on upgrade, never written again.
        var claudeSessionKey: String?
        var claudeLastActiveOrg: String?
        var chatGPTParts: [Part]?
        var chatGPTAssembled: String?
        var grokSSO: String?

        struct Part: Codable {
            var index: Int
            var value: String
        }
    }

    private struct StoredAccount: Codable {
        var id: String
        var claudeSessionKey: String?
        var claudeLastActiveOrg: String?
        var chatGPTParts: [Stored.Part]?
        var chatGPTAssembled: String?
        var chatGPTAccountID: String?
        var grokSSO: String?
        var claudeOrgIDs: [String]?
    }

    static func load() -> CredentialStore {
        if let current = read(service: service) {
            let loaded = decode(current)
            if loaded.persist, !loaded.store.isEmpty {
                write(encode(loaded.store))
            }
            return loaded.store
        }
        // Service name changed with the product domain. Copy the old item
        // across so a rebuild does not look like a fresh install.
        for legacy in AppIdentity.legacyKeychainServices {
            guard let data = read(service: legacy) else { continue }
            let loaded = decode(data)
            // An empty or unreadable item is not a hit — try the older name.
            guard !loaded.store.isEmpty else { continue }
            write(encode(loaded.store))
            delete(service: legacy)
            return loaded.store
        }
        return CredentialStore()
    }

    static func save(_ incoming: ExtractedCredentials) {
        let merged = CredentialMerge.applying(incoming, to: load())
        replace(merged)
    }

    static func replace(_ store: CredentialStore) {
        if store.isEmpty {
            delete()
            return
        }
        write(encode(store))
    }

    static func recordClaudeOrgs(_ orgIDsByAccountID: [String: Set<String>]) {
        let stamped = load().stampingClaudeOrgs(orgIDsByAccountID)
        let collapsed = CredentialMerge.collapsingClaudeDuplicates(stamped, orgIDsByAccountID: orgIDsByAccountID)
        if collapsed != load() {
            replace(collapsed)
        }
    }

    static func remove(trackingID: String) {
        replace(load().removing(trackingID: trackingID))
    }

    private struct Decoded {
        var store: CredentialStore
        var persist: Bool
    }

    private static func decode(_ data: Data?) -> Decoded {
        guard let data, let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Decoded(store: CredentialStore(), persist: false)
        }
        if let accounts = stored.accounts {
            return Decoded(store: CredentialStore(accounts: accounts.compactMap(account(from:))), persist: false)
        }
        return Decoded(store: migrateLegacy(stored), persist: true)
    }

    private static func migrateLegacy(_ stored: Stored) -> CredentialStore {
        var accounts: [CredentialAccount] = []
        if let key = stored.claudeSessionKey {
            accounts.append(CredentialAccount(
                id: UUID().uuidString,
                claude: ClaudeCredentials(sessionKey: key, lastActiveOrg: stored.claudeLastActiveOrg)
            ))
        }
        if let parts = stored.chatGPTParts, !parts.isEmpty {
            let cookieParts = parts.map { ChatGPTCredentials.CookiePart(index: $0.index, value: $0.value) }
            accounts.append(CredentialAccount(
                id: UUID().uuidString,
                chatGPT: ChatGPTCredentials(parts: cookieParts, assembled: cookieParts.map(\.value).joined())
            ))
        } else if let assembled = stored.chatGPTAssembled {
            accounts.append(CredentialAccount(
                id: UUID().uuidString,
                chatGPT: ChatGPTCredentials(parts: [], assembled: assembled)
            ))
        }
        if let sso = stored.grokSSO {
            accounts.append(CredentialAccount(id: UUID().uuidString, grok: GrokCredentials(sso: sso)))
        }
        if let grok = accounts.first(where: { $0.grok != nil }) {
            AccountNames.remap(from: "grok", to: "grok:\(grok.id)")
        }
        if let gpt = accounts.first(where: { $0.chatGPT != nil }) {
            AccountNames.remap(from: "chatGPT", to: "chatgpt:\(gpt.id)")
        }
        return CredentialStore(accounts: accounts)
    }

    private static func account(from stored: StoredAccount) -> CredentialAccount? {
        var account = CredentialAccount(id: stored.id)
        if let key = stored.claudeSessionKey {
            account.claude = ClaudeCredentials(sessionKey: key, lastActiveOrg: stored.claudeLastActiveOrg)
        }
        if let parts = stored.chatGPTParts, !parts.isEmpty {
            let cookieParts = parts.map { ChatGPTCredentials.CookiePart(index: $0.index, value: $0.value) }
            account.chatGPT = ChatGPTCredentials(
                parts: cookieParts,
                assembled: cookieParts.map(\.value).joined(),
                accountID: stored.chatGPTAccountID
            )
        } else if let assembled = stored.chatGPTAssembled {
            account.chatGPT = ChatGPTCredentials(
                parts: [],
                assembled: assembled,
                accountID: stored.chatGPTAccountID
            )
        }
        if let sso = stored.grokSSO {
            account.grok = GrokCredentials(sso: sso)
        }
        if let orgs = stored.claudeOrgIDs {
            account.claudeOrgIDs = Set(orgs)
        }
        if account.claude == nil && account.chatGPT == nil && account.grok == nil {
            return nil
        }
        return account
    }

    private static func encode(_ store: CredentialStore) -> Data? {
        let stored = Stored(
            accounts: store.accounts.map { account in
                StoredAccount(
                    id: account.id,
                    claudeSessionKey: account.claude?.sessionKey,
                    claudeLastActiveOrg: account.claude?.lastActiveOrg,
                    chatGPTParts: account.chatGPT?.parts.map { Stored.Part(index: $0.index, value: $0.value) },
                    chatGPTAssembled: account.chatGPT?.assembled,
                    chatGPTAccountID: account.chatGPT?.accountID,
                    grokSSO: account.grok?.sso,
                    claudeOrgIDs: account.claudeOrgIDs.isEmpty ? nil : Array(account.claudeOrgIDs).sorted()
                )
            }
        )
        return try? JSONEncoder().encode(stored)
    }

    private static func read(service: String = service) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func write(_ data: Data?) {
        delete(service: service)
        guard let data else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: service,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func delete(service: String = service) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
