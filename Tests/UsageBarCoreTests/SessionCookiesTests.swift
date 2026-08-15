import Foundation
import Testing
@testable import UsageBarCore

@Suite("extractSessionKey")
struct SessionCookiesTests {

    @Test func safariClaudeTable() throws {
        let creds = try SessionCookies.extractSessionKey(from: Fixtures.safariClaudeTable)
        let claude = try #require(creds.claude)
        #expect(claude.sessionKey == Fixtures.sampleClaudeKey)
        #expect(claude.lastActiveOrg == "00000000-0000-4000-8000-000000000002")
        #expect(creds.chatGPT == nil)
        #expect(creds.grok == nil)
    }

    @Test func timestampNeighbourIsNotTheKey() throws {
        let claude = try #require(try SessionCookies.extractSessionKey(from: Fixtures.safariClaudeTable).claude)
        #expect(claude.sessionKey != "1786713417363")
    }

    @Test func routingHintIsNotTheKey() throws {
        let claude = try #require(try SessionCookies.extractSessionKey(from: Fixtures.safariClaudeTable).claude)
        #expect(claude.sessionKey.hasPrefix("sk-ant-sid"))
        #expect(!claude.sessionKey.hasPrefix("sk-ant-rh-"))
    }

    @Test func requestHeaderLine() throws {
        let pasted = "Cookie: lastActiveOrg=00000000-0000-4000-8000-000000000002; sessionKey=\(Fixtures.sampleClaudeKey); ajs_user_id=x"
        let claude = try #require(try SessionCookies.extractSessionKey(from: pasted).claude)
        #expect(claude.sessionKey == Fixtures.sampleClaudeKey)
        #expect(claude.lastActiveOrg == "00000000-0000-4000-8000-000000000002")
    }

    @Test func documentCookieString() throws {
        let pasted = "sessionKeyLC=1786713417363; sessionKey=\(Fixtures.sampleClaudeKey)"
        #expect(try SessionCookies.extractSessionKey(from: pasted).claude?.sessionKey == Fixtures.sampleClaudeKey)
    }

    @Test func bareValue() throws {
        let creds = try SessionCookies.extractSessionKey(from: "  \(Fixtures.sampleClaudeKey)\n")
        #expect(creds.claude?.sessionKey == Fixtures.sampleClaudeKey)
        #expect(creds.claude?.lastActiveOrg == nil)
    }

    @Test func sessionKeyV3IsAccepted() throws {
        let pasted = "sessionKeyV3=\(Fixtures.sampleClaudeKey)"
        #expect(try SessionCookies.extractSessionKey(from: pasted).claude?.sessionKey == Fixtures.sampleClaudeKey)
    }

    @Test func emptyPasteThrows() {
        #expect(throws: CookieExtractionError.nothingFound) {
            try SessionCookies.extractSessionKey(from: "   \n  ")
        }
    }

    @Test func truncatedClaudeKeyIsRejected() {
        #expect(throws: CookieExtractionError.nothingFound) {
            try SessionCookies.extractSessionKey(from: "sessionKey=sk-ant-sid02-Yu")
        }
    }

    @Test func claudeHeaderCarriesOnlyTheSessionKey() throws {
        let claude = try #require(try SessionCookies.extractSessionKey(from: Fixtures.safariClaudeTable).claude)
        let header = claude.cookieHeader
        #expect(header == "sessionKey=\(Fixtures.sampleClaudeKey)")
        #expect(!header.contains("routingHint"))
        #expect(!header.contains("lastActiveOrg"))
        #expect(!header.contains("\t"))
        #expect(!header.contains("\n"))
    }

    @Test func chatGPTPartsAssembleInIndexOrder() throws {
        let creds = try SessionCookies.extractSessionKey(from: Fixtures.safariChatGPTTable)
        let gpt = try #require(creds.chatGPT)
        #expect(gpt.parts.map(\.index) == [0, 1])
        #expect(gpt.assembled == Fixtures.sampleChatGPTPart0 + Fixtures.sampleChatGPTPart1)
        #expect(creds.claude == nil)
    }

    @Test func chatGPTHeaderKeepsNumberedCookies() throws {
        let gpt = try #require(try SessionCookies.extractSessionKey(from: Fixtures.safariChatGPTTable).chatGPT)
        #expect(gpt.cookieHeader == "__Secure-next-auth.session-token.0=\(Fixtures.sampleChatGPTPart0); __Secure-next-auth.session-token.1=\(Fixtures.sampleChatGPTPart1)")
    }

    @Test func chatGPTUnchunkedToken() throws {
        let pasted = "__Secure-next-auth.session-token=\(Fixtures.sampleChatGPTPart0)\(Fixtures.sampleChatGPTPart1)"
        let gpt = try #require(try SessionCookies.extractSessionKey(from: pasted).chatGPT)
        #expect(gpt.parts.isEmpty)
        #expect(gpt.assembled == Fixtures.sampleChatGPTPart0 + Fixtures.sampleChatGPTPart1)
        #expect(gpt.cookieHeader.hasPrefix("__Secure-next-auth.session-token="))
        #expect(!gpt.cookieHeader.contains("session-token.0"))
    }

    @Test func chatGPTNumericSortPutsTenAfterTwo() throws {
        let pasted = """
        __Secure-next-auth.session-token.10\tPART10_XXXXXXXXXXXXXXXX\t.chatgpt.com
        __Secure-next-auth.session-token.2\tPART02_XXXXXXXXXXXXXXXX\t.chatgpt.com
        """
        let gpt = try #require(try SessionCookies.extractSessionKey(from: pasted).chatGPT)
        #expect(gpt.parts.map(\.index) == [2, 10])
        #expect(gpt.assembled == "PART02_XXXXXXXXXXXXXXXXPART10_XXXXXXXXXXXXXXXX")
    }

    @Test func grokSSOFromSafariTable() throws {
        let creds = try SessionCookies.extractSessionKey(from: Fixtures.safariGrokTable)
        #expect(creds.grok?.sso == Fixtures.sampleGrokSSO)
        #expect(creds.grok?.cookieHeader == "sso=\(Fixtures.sampleGrokSSO)")
    }

    @Test func ssoOnAForeignDomainIsIgnored() {
        let pasted = "sso\tnot-grok-value-xxxxxxxx\t.chatgpt.com\t/"
        #expect(throws: CookieExtractionError.nothingFound) {
            try SessionCookies.extractSessionKey(from: pasted)
        }
    }

    @Test func mixedPasteExtractsEveryProvider() throws {
        let pasted = Fixtures.safariClaudeTable + "\n" + Fixtures.safariChatGPTTable + "\n" + Fixtures.safariGrokTable
        let creds = try SessionCookies.extractSessionKey(from: pasted)
        #expect(creds.claude?.sessionKey == Fixtures.sampleClaudeKey)
        #expect(creds.chatGPT?.assembled == Fixtures.sampleChatGPTPart0 + Fixtures.sampleChatGPTPart1)
        #expect(creds.grok?.sso == Fixtures.sampleGrokSSO)
        #expect(creds.configuredProviders == [.claude, .chatGPT, .grok])
    }
}
