import Foundation
import Testing
@testable import UsageBarCore

@Suite("CredentialMerge")
struct CredentialMergeTests {
    private let claudeA = ClaudeCredentials(
        sessionKey: Fixtures.sampleClaudeKey,
        lastActiveOrg: "00000000-0000-4000-8000-000000000002"
    )
    private let claudeB = ClaudeCredentials(
        sessionKey: Fixtures.sampleClaudeKeyB,
        lastActiveOrg: "00000000-0000-4000-8000-000000000099"
    )
    private let gptA = ChatGPTCredentials(
        parts: [],
        assembled: Fixtures.sampleChatGPTPart0,
        accountID: Fixtures.sampleChatGPTAccountID
    )

    @Test func secondClaudeOrgBecomesItsOwnRow() {
        var n = 0
        let next = { n += 1; return "id-\(n)" }
        let first = CredentialMerge.applying(
            ExtractedCredentials(claude: claudeA),
            to: CredentialStore(),
            newID: next
        )
        let second = CredentialMerge.applying(
            ExtractedCredentials(claude: claudeB),
            to: first,
            newID: next
        )
        #expect(second.accounts.count == 2)
        #expect(second.accounts.map { $0.claude?.sessionKey } == [claudeA.sessionKey, claudeB.sessionKey])
    }

    @Test func sameSessionKeyDoesNotDuplicate() {
        var n = 0
        let next = { n += 1; return "id-\(n)" }
        let first = CredentialMerge.applying(
            ExtractedCredentials(claude: claudeA),
            to: CredentialStore(),
            newID: next
        )
        let again = CredentialMerge.applying(
            ExtractedCredentials(claude: claudeA),
            to: first,
            newID: next
        )
        #expect(again.accounts.count == 1)
        #expect(again.accounts[0].id == "id-1")
    }

    @Test func newKeyForTheSameLastActiveOrgUpdates() {
        var n = 0
        let next = { n += 1; return "id-\(n)" }
        let first = CredentialMerge.applying(
            ExtractedCredentials(claude: claudeA),
            to: CredentialStore(),
            newID: next
        )
        let refreshed = ClaudeCredentials(
            sessionKey: Fixtures.sampleClaudeKeyB,
            lastActiveOrg: claudeA.lastActiveOrg
        )
        let second = CredentialMerge.applying(
            ExtractedCredentials(claude: refreshed),
            to: first,
            newID: next
        )
        #expect(second.accounts.count == 1)
        #expect(second.accounts[0].id == "id-1")
        #expect(second.accounts[0].claude?.sessionKey == Fixtures.sampleClaudeKeyB)
    }

    @Test func chatGPTAccountIDUpdatesTheToken() {
        var n = 0
        let next = { n += 1; return "id-\(n)" }
        let first = CredentialMerge.applying(
            ExtractedCredentials(chatGPT: gptA),
            to: CredentialStore(),
            newID: next
        )
        let refreshed = ChatGPTCredentials(
            parts: [],
            assembled: Fixtures.sampleChatGPTPart0 + "NEW",
            accountID: gptA.accountID
        )
        let second = CredentialMerge.applying(
            ExtractedCredentials(chatGPT: refreshed),
            to: first,
            newID: next
        )
        #expect(second.accounts.count == 1)
        #expect(second.accounts[0].chatGPT?.assembled == Fixtures.sampleChatGPTPart0 + "NEW")
    }

    @Test func differentChatGPTAccountIDIsANewRow() {
        var n = 0
        let next = { n += 1; return "id-\(n)" }
        let first = CredentialMerge.applying(
            ExtractedCredentials(chatGPT: gptA),
            to: CredentialStore(),
            newID: next
        )
        let other = ChatGPTCredentials(
            parts: [],
            assembled: "other-token-XXXXXXXXXXXX",
            accountID: "00000000-0000-4000-8000-0000000000bb"
        )
        let second = CredentialMerge.applying(
            ExtractedCredentials(chatGPT: other),
            to: first,
            newID: next
        )
        #expect(second.accounts.count == 2)
    }

    @Test func differentGrokSSOIsANewRow() {
        var n = 0
        let next = { n += 1; return "id-\(n)" }
        let first = CredentialMerge.applying(
            ExtractedCredentials(grok: GrokCredentials(sso: Fixtures.sampleGrokSSO)),
            to: CredentialStore(),
            newID: next
        )
        let second = CredentialMerge.applying(
            ExtractedCredentials(grok: GrokCredentials(sso: "sso-placeholder-value-yyyyyyyy")),
            to: first,
            newID: next
        )
        #expect(second.accounts.count == 2)
    }

    @Test func sameGrokSSODoesNotDuplicate() {
        var n = 0
        let next = { n += 1; return "id-\(n)" }
        let first = CredentialMerge.applying(
            ExtractedCredentials(grok: GrokCredentials(sso: Fixtures.sampleGrokSSO)),
            to: CredentialStore(),
            newID: next
        )
        let again = CredentialMerge.applying(
            ExtractedCredentials(grok: GrokCredentials(sso: Fixtures.sampleGrokSSO)),
            to: first,
            newID: next
        )
        #expect(again.accounts.count == 1)
    }

    @Test func collapsingKeepsTheNewerClaudeWhenOrgsOverlap() {
        let older = CredentialAccount(id: "old", claude: claudeA)
        let newer = CredentialAccount(id: "new", claude: claudeB)
        let collapsed = CredentialMerge.collapsingClaudeDuplicates(
            CredentialStore(accounts: [older, newer]),
            orgIDsByAccountID: [
                "old": ["org-1"],
                "new": ["org-1", "org-2"],
            ]
        )
        #expect(collapsed.accounts.map(\.id) == ["new"])
    }

    @Test func removingAChatGPTTrackingIDDropsThatLogin() {
        let gpt = CredentialAccount(id: "gpt-1", chatGPT: gptA)
        let claude = CredentialAccount(id: "c-1", claude: claudeA)
        let store = CredentialStore(accounts: [gpt, claude]).removing(trackingID: "chatgpt:gpt-1")
        #expect(store.accounts.map(\.id) == ["c-1"])
    }

    @Test func removingAClaudeOrgDropsTheLoginThatOwnsIt() {
        let claude = CredentialAccount(
            id: "c-1",
            claude: claudeA,
            claudeOrgIDs: ["00000000-0000-4000-8000-000000000002"]
        )
        let store = CredentialStore(accounts: [claude])
            .removing(trackingID: "claude:00000000-0000-4000-8000-000000000002")
        #expect(store.isEmpty)
    }

    @Test func nakedChatGPTIdDoesNotMatchEveryLogin() {
        let other = ChatGPTCredentials(
            parts: [],
            assembled: "other-token-XXXXXXXXXXXX",
            accountID: "00000000-0000-4000-8000-0000000000bb"
        )
        let a = CredentialAccount(id: "a", chatGPT: gptA)
        let b = CredentialAccount(id: "b", chatGPT: other)
        #expect(a.owns(trackingID: "chatgpt:a"))
        #expect(!a.owns(trackingID: "chatGPT"))
        #expect(!a.owns(trackingID: "chatgpt:b"))
        let store = CredentialStore(accounts: [a, b]).removing(trackingID: "chatGPT")
        #expect(store.accounts.map(\.id) == ["a", "b"])
        let one = CredentialStore(accounts: [a, b]).removing(trackingID: "chatgpt:a")
        #expect(one.accounts.map(\.id) == ["b"])
    }

    @Test func nakedGrokIdDoesNotMatchEveryLogin() {
        let a = CredentialAccount(id: "a", grok: GrokCredentials(sso: Fixtures.sampleGrokSSO))
        let b = CredentialAccount(id: "b", grok: GrokCredentials(sso: "sso-placeholder-value-yyyyyyyy"))
        #expect(a.owns(trackingID: "grok:a"))
        #expect(!a.owns(trackingID: "grok"))
        let store = CredentialStore(accounts: [a, b]).removing(trackingID: "grok")
        #expect(store.accounts.map(\.id) == ["a", "b"])
    }

    @Test func deletingOneClaudeOrgNamesEverySibling() {
        let orgA = "00000000-0000-4000-8000-000000000002"
        let orgB = "00000000-0000-4000-8000-000000000099"
        let claude = CredentialAccount(id: "c-1", claude: claudeA, claudeOrgIDs: [orgA, orgB])
        let cards = [
            AccountCard(
                trackingID: "claude:\(orgA)",
                provider: .claude,
                defaultName: "Zen AI GmbH",
                limits: [],
                tone: .ok,
                utilization: 0.1
            ),
            AccountCard(
                trackingID: "claude:\(orgB)",
                provider: .claude,
                defaultName: "Max-Org",
                limits: [],
                tone: .critical,
                utilization: 1
            ),
        ]
        let deletion = CredentialStore(accounts: [claude]).deletion(of: "claude:\(orgB)", cards: cards)
        #expect(deletion?.provider == .claude)
        #expect(deletion?.names == ["Zen AI GmbH", "Max-Org"])
        #expect(deletion?.message == "Removes the Claude login for Zen AI GmbH and Max-Org.")
        let after = CredentialStore(accounts: [claude]).removing(trackingID: "claude:\(orgB)")
        #expect(after.isEmpty)
    }

    @Test func deletingOneChatGPTNamesOnlyThatLogin() {
        let a = CredentialAccount(id: "a", chatGPT: gptA)
        let b = CredentialAccount(
            id: "b",
            chatGPT: ChatGPTCredentials(
                parts: [],
                assembled: "other-token-XXXXXXXXXXXX",
                accountID: "00000000-0000-4000-8000-0000000000bb"
            )
        )
        let cards = [
            AccountCard(
                trackingID: "chatgpt:a",
                provider: .chatGPT,
                defaultName: "Work",
                limits: [],
                tone: .error,
                utilization: nil
            ),
            AccountCard(
                trackingID: "chatgpt:b",
                provider: .chatGPT,
                defaultName: "Personal",
                limits: [],
                tone: .ok,
                utilization: 0.2
            ),
        ]
        let deletion = CredentialStore(accounts: [a, b]).deletion(of: "chatgpt:a", cards: cards)
        #expect(deletion?.provider == .chatGPT)
        #expect(deletion?.names == ["Work"])
        #expect(deletion?.message == "Removes the ChatGPT login for Work.")
        #expect(LoginDeletion.list(["Zen AI", "Max-Org", "Personal"]) == "Zen AI, Max-Org, and Personal")
    }

    @Test func collapsingLeavesDisjointClaudeOrgsAlone() {
        let a = CredentialAccount(id: "a", claude: claudeA)
        let b = CredentialAccount(id: "b", claude: claudeB)
        let collapsed = CredentialMerge.collapsingClaudeDuplicates(
            CredentialStore(accounts: [a, b]),
            orgIDsByAccountID: [
                "a": ["org-1"],
                "b": ["org-2"],
            ]
        )
        #expect(collapsed.accounts.map(\.id) == ["a", "b"])
    }
}
