import Foundation

/// One login we persist. A provider can appear many times — two Claude Max
/// plans on two emails are two accounts, not one overwritten cookie.
public struct CredentialAccount: Equatable, Sendable, Identifiable {
    public var id: String
    public var claude: ClaudeCredentials?
    public var chatGPT: ChatGPTCredentials?
    public var grok: GrokCredentials?
    /// Org UUIDs last seen on this Claude login. Used to delete the right cookie
    /// when the card's tracking id is `claude:{org}`.
    public var claudeOrgIDs: Set<String>

    public init(
        id: String,
        claude: ClaudeCredentials? = nil,
        chatGPT: ChatGPTCredentials? = nil,
        grok: GrokCredentials? = nil,
        claudeOrgIDs: Set<String> = []
    ) {
        self.id = id
        self.claude = claude
        self.chatGPT = chatGPT
        self.grok = grok
        self.claudeOrgIDs = claudeOrgIDs
    }

    public func owns(trackingID: String) -> Bool {
        if trackingID == "chatgpt:\(id)" { return chatGPT != nil }
        if trackingID == "grok:\(id)" { return grok != nil }
        if trackingID == "claude:account:\(id)" { return claude != nil }
        guard trackingID.hasPrefix("claude:"), claude != nil else { return false }
        let org = String(trackingID.dropFirst("claude:".count))
        if org.hasPrefix("account:") { return false }
        return claude?.lastActiveOrg == org || claudeOrgIDs.contains(org)
    }

    public var provider: Provider {
        if claude != nil { return .claude }
        if chatGPT != nil { return .chatGPT }
        return .grok
    }

    public var trackingPrefix: String {
        switch provider {
        case .claude: "claude"
        case .chatGPT: "chatgpt:\(id)"
        case .grok: "grok:\(id)"
        }
    }
}

public struct CredentialStore: Equatable, Sendable {
    public var accounts: [CredentialAccount]

    public init(accounts: [CredentialAccount] = []) {
        self.accounts = accounts
    }

    public var isEmpty: Bool { accounts.isEmpty }

    public func removing(trackingID: String) -> CredentialStore {
        CredentialStore(accounts: accounts.filter { !$0.owns(trackingID: trackingID) })
    }

    public func stampingClaudeOrgs(_ orgIDsByAccountID: [String: Set<String>]) -> CredentialStore {
        CredentialStore(accounts: accounts.map { account in
            guard let orgs = orgIDsByAccountID[account.id], !orgs.isEmpty else { return account }
            var next = account
            next.claudeOrgIDs = orgs
            return next
        })
    }
}

/// Decide whether a newly pasted cookie is a new login or a refresh of one
/// we already have. Match on the secret first, then on a stable identity the
/// provider put in the same paste (`lastActiveOrg`, `_account`). If neither
/// matches, it is a new row.
public enum CredentialMerge {
    public static func applying(
        _ incoming: ExtractedCredentials,
        to store: CredentialStore,
        newID: () -> String = { UUID().uuidString }
    ) -> CredentialStore {
        var accounts = store.accounts

        for claude in incoming.claudeAccounts {
            if let index = accounts.firstIndex(where: { $0.claude?.sessionKey == claude.sessionKey }) {
                accounts[index].claude = claude
            } else if let org = claude.lastActiveOrg,
                      let index = accounts.firstIndex(where: { $0.claude?.lastActiveOrg == org }) {
                accounts[index].claude = claude
            } else {
                accounts.append(CredentialAccount(id: newID(), claude: claude))
            }
        }

        for gpt in incoming.chatGPTAccounts {
            if let index = accounts.firstIndex(where: { $0.chatGPT?.assembled == gpt.assembled }) {
                accounts[index].chatGPT = gpt
            } else if let accountID = gpt.accountID,
                      let index = accounts.firstIndex(where: { $0.chatGPT?.accountID == accountID }) {
                accounts[index].chatGPT = gpt
            } else {
                accounts.append(CredentialAccount(id: newID(), chatGPT: gpt))
            }
        }

        for grok in incoming.grokAccounts {
            if let index = accounts.firstIndex(where: { $0.grok?.sso == grok.sso }) {
                accounts[index].grok = grok
            } else {
                accounts.append(CredentialAccount(id: newID(), grok: grok))
            }
        }

        return CredentialStore(accounts: accounts)
    }

    /// Two Claude cookies that resolve to the same org are the same login
    /// after a session refresh. Keep the later account, drop the earlier.
    public static func collapsingClaudeDuplicates(
        _ store: CredentialStore,
        orgIDsByAccountID: [String: Set<String>]
    ) -> CredentialStore {
        var keep: [CredentialAccount] = []
        var claimed = Set<String>()

        for account in store.accounts.reversed() {
            guard account.claude != nil,
                  let orgs = orgIDsByAccountID[account.id],
                  !orgs.isEmpty
            else {
                keep.append(account)
                continue
            }
            if orgs.contains(where: claimed.contains) {
                continue
            }
            claimed.formUnion(orgs)
            keep.append(account)
        }

        return CredentialStore(accounts: keep.reversed())
    }
}

/// What the trash will actually throw away. One cookie, every card it feeds.
public struct LoginDeletion: Equatable, Sendable {
    public let provider: Provider
    public let names: [String]

    public init(provider: Provider, names: [String]) {
        self.provider = provider
        self.names = names
    }

    public var message: String {
        "Removes the \(provider.displayName) login for \(Self.list(names))."
    }

    public static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return "this login"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + ", and \(names[names.count - 1])"
        }
    }
}

public extension CredentialStore {
    func deletion(
        of trackingID: String,
        cards: [AccountCard],
        displayName: (String, String) -> String = { _, fallback in fallback }
    ) -> LoginDeletion? {
        guard let account = accounts.first(where: { $0.owns(trackingID: trackingID) }) else {
            return nil
        }
        let doomed = cards.filter { account.owns(trackingID: $0.trackingID) }
        let names = doomed.map { displayName($0.trackingID, $0.defaultName) }
        return LoginDeletion(
            provider: account.provider,
            names: names.isEmpty ? ["this login"] : names
        )
    }
}
