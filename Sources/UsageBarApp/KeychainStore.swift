import Foundation
import Security
import UsageBarCore

/// Credentials live in the Keychain. Never in a file, never in a log.
enum KeychainStore {
    private static let service = "de.getzenai.ai-usage-bar"
    private static let account = "credentials"

    private struct Stored: Codable {
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

    static func load() -> ExtractedCredentials {
        guard let data = read(),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return ExtractedCredentials() }

        var creds = ExtractedCredentials()
        if let key = stored.claudeSessionKey {
            creds.claude = ClaudeCredentials(sessionKey: key, lastActiveOrg: stored.claudeLastActiveOrg)
        }
        if let parts = stored.chatGPTParts, !parts.isEmpty {
            let cookieParts = parts.map { ChatGPTCredentials.CookiePart(index: $0.index, value: $0.value) }
            creds.chatGPT = ChatGPTCredentials(parts: cookieParts, assembled: cookieParts.map(\.value).joined())
        } else if let assembled = stored.chatGPTAssembled {
            creds.chatGPT = ChatGPTCredentials(parts: [], assembled: assembled)
        }
        if let sso = stored.grokSSO {
            creds.grok = GrokCredentials(sso: sso)
        }
        return creds
    }

    static func save(_ creds: ExtractedCredentials) {
        let existing = load()
        let merged = ExtractedCredentials(
            claude: creds.claude ?? existing.claude,
            chatGPT: creds.chatGPT ?? existing.chatGPT,
            grok: creds.grok ?? existing.grok
        )
        write(encode(merged))
    }

    static func replace(_ creds: ExtractedCredentials) {
        write(encode(creds))
    }

    static func clear(_ provider: Provider) {
        var creds = load()
        switch provider {
        case .claude: creds.claude = nil
        case .chatGPT: creds.chatGPT = nil
        case .grok: creds.grok = nil
        }
        write(encode(creds))
    }

    private static func encode(_ creds: ExtractedCredentials) -> Data? {
        let stored = Stored(
            claudeSessionKey: creds.claude?.sessionKey,
            claudeLastActiveOrg: creds.claude?.lastActiveOrg,
            chatGPTParts: creds.chatGPT?.parts.map { Stored.Part(index: $0.index, value: $0.value) },
            chatGPTAssembled: creds.chatGPT?.assembled,
            grokSSO: creds.grok?.sso
        )
        if stored.claudeSessionKey == nil && stored.chatGPTAssembled == nil && stored.chatGPTParts == nil && stored.grokSSO == nil {
            delete()
            return nil
        }
        return try? JSONEncoder().encode(stored)
    }

    private static func read() -> Data? {
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
        delete()
        guard let data else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
