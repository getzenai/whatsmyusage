import Foundation
import Testing
@testable import UsageBarCore

@Suite("Provider links")
struct ProviderLinkTests {

    @Test func everyProviderHasAnHTTPSLink() {
        for provider in Provider.allCases {
            #expect(provider.usageURL.scheme == "https")
            #expect(provider.usageURL.host != nil)
        }
    }

    @Test func theLinkGoesToTheProviderTheAccountIsOn() {
        #expect(Provider.claude.usageURL.host == "claude.ai")
        #expect(Provider.chatGPT.usageURL.host == "chatgpt.com")
        #expect(Provider.grok.usageURL.host == "grok.com")
    }

    /// A hint is the rest of the way. Claude is linked straight to the page, so
    /// a hint there would tell the user to look for something already open.
    @Test func onlyTheSitesWeCannotDeepLinkCarryAHint() {
        #expect(Provider.claude.usageURL.path == "/settings/usage")
        #expect(Provider.claude.usageHint == nil)
        #expect(Provider.chatGPT.usageHint != nil)
        #expect(Provider.grok.usageHint != nil)
    }
}
