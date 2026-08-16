import Foundation
import Testing
@testable import UsageBarCore

@Suite("AccountDisplayNames")
struct AccountDisplayNamesTests {
    @Test func customNameBeatsDefaultAndFallback() {
        let name = AccountDisplayNames.resolve(
            trackingID: "aaa-1111-2222",
            provider: .claude,
            custom: ["aaa-1111-2222": "Claude Max Zen AI"],
            defaults: ["aaa-1111-2222": "Claude Max"],
            peers: ["aaa-1111-2222", "bbb-3333"]
        )
        #expect(name == "Claude Max Zen AI")
    }

    @Test func defaultNameBeatsFallback() {
        let name = AccountDisplayNames.resolve(
            trackingID: "aaa-1111-2222",
            provider: .claude,
            custom: [:],
            defaults: ["aaa-1111-2222": "Claude Max"],
            peers: ["aaa-1111-2222"]
        )
        #expect(name == "Claude Max")
    }

    @Test func leftoverPrefixKeyDoesNotMatchAUUID() {
        let name = AccountDisplayNames.resolve(
            trackingID: "chatGPT-deadbeef",
            provider: .chatGPT,
            custom: ["chatGPT": "Old name"],
            defaults: [:],
            peers: ["chatGPT-deadbeef"]
        )
        #expect(name == "chatGPT #1 (chatGPT-)")
    }

    @Test func emptyCustomNameFallsThrough() {
        let name = AccountDisplayNames.resolve(
            trackingID: "aaa-1111",
            provider: .claude,
            custom: ["aaa-1111": "   "],
            defaults: ["aaa-1111": "Claude Team"],
            peers: ["aaa-1111"]
        )
        #expect(name == "Claude Team")
    }

    @Test func fallbackNumberIsStableWhenPeerOrderSwaps() {
        let peersA = ["bbb-2222-cccc", "aaa-1111-dddd"]
        let peersB = ["aaa-1111-dddd", "bbb-2222-cccc"]
        let first = AccountDisplayNames.fallback(
            trackingID: "bbb-2222-cccc",
            provider: .claude,
            peers: peersA
        )
        let second = AccountDisplayNames.fallback(
            trackingID: "bbb-2222-cccc",
            provider: .claude,
            peers: peersB
        )
        #expect(first == second)
        #expect(first == "claude #2 (bbb-2222)")
    }
}
