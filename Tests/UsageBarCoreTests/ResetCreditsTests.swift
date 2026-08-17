import Foundation
import Testing
@testable import UsageBarCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("Reset credits")
struct ResetCreditsTests {

    @Test func grokEmptyDataFrameIsNoneNotZeroGuess() {
        let body = GrpcWeb.encode(message: Data())
        #expect(UsageParser.parseGrokRemainingResets(body: body, now: now) == ResetRead.none)
    }

    @Test func grokTrailerWithoutDataFrameIsAMiss() {
        let trailer = GrpcWeb.frame(flag: 0x80, payload: Data("grpc-status:0\r\n".utf8))
        #expect(UsageParser.parseGrokRemainingResets(body: trailer, now: now) == nil)
    }

    @Test func grokOneValidTokenCounts() {
        let body = ResetWire.grok(tokens: [
            ResetWire.token(id: "tok-1", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600)),
        ])
        #expect(UsageParser.parseGrokRemainingResets(body: body, now: now) == .available(1))
        #expect(ResetRead.label(for: 1) == "Reset available")
    }

    @Test func grokTwoValidTokensCount() {
        let body = ResetWire.grok(tokens: [
            ResetWire.token(id: "tok-1", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600)),
            ResetWire.token(id: "tok-2", start: now.addingTimeInterval(-60), end: now.addingTimeInterval(86_400)),
        ])
        #expect(UsageParser.parseGrokRemainingResets(body: body, now: now) == .available(2))
        #expect(ResetRead.label(for: 2) == "2 resets available")
    }

    @Test func grokExpiredEndDoesNotCount() {
        let body = ResetWire.grok(tokens: [
            ResetWire.token(id: "tok-old", start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(-1)),
        ])
        #expect(UsageParser.parseGrokRemainingResets(body: body, now: now) == ResetRead.none)
    }

    @Test func grokEmptyTokenIdDoesNotCount() {
        let body = ResetWire.grok(tokens: [
            ResetWire.token(id: "", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600)),
        ])
        #expect(UsageParser.parseGrokRemainingResets(body: body, now: now) == ResetRead.none)
    }

    @Test func grokFutureStartDoesNotCountToday() {
        let body = ResetWire.grok(tokens: [
            ResetWire.token(id: "tok-later", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(86_400)),
        ])
        #expect(UsageParser.parseGrokRemainingResets(body: body, now: now) == ResetRead.none)
    }

    @Test func grokMissingStartStillCountsWhenEndIsFuture() {
        let body = ResetWire.grok(tokens: [
            ResetWire.token(id: "tok-open", start: nil, end: now.addingTimeInterval(3600)),
        ])
        #expect(UsageParser.parseGrokRemainingResets(body: body, now: now) == .available(1))
    }

    @Test func chatGPTZeroIsNoneNotAGuess() {
        let body = Data(#"{"available_count":0,"credits":[],"immediate_reset_purchase_eligible":false}"#.utf8)
        #expect(UsageParser.parseChatGPTResetCredits(body: body) == ResetRead.none)
    }

    @Test func chatGPTPositiveCountIsAvailable() {
        let body = Data(#"{"available_count":3,"credits":[{}],"immediate_reset_purchase_eligible":false}"#.utf8)
        #expect(UsageParser.parseChatGPTResetCredits(body: body) == .available(3))
    }

    @Test func chatGPTMissingCountIsAMiss() {
        let body = Data(#"{"credits":[],"immediate_reset_purchase_eligible":false}"#.utf8)
        #expect(UsageParser.parseChatGPTResetCredits(body: body) == nil)
    }

    @Test func cardHidesAZeroAndKeepsAOne() {
        let hidden = sampleCard(resetAvailable: 0)
        #expect(hidden.resetAvailable == nil)
        #expect(hidden.resetAvailableLabel == nil)
        let shown = sampleCard(resetAvailable: 1)
        #expect(shown.resetAvailable == 1)
        #expect(shown.resetAvailableLabel == "Reset available")
    }
}

private func sampleCard(resetAvailable: Int?) -> AccountCard {
    AccountCard(
        trackingID: "grok:placeholder",
        provider: .grok,
        defaultName: "Grok",
        limits: [],
        tone: .blocked,
        utilization: 1,
        resetAvailable: resetAvailable
    )
}

/// Hand-built GetRemainingResets frames. Values are invented — never a live token.
private enum ResetWire {
    static func grok(tokens: [Data]) -> Data {
        var message = Data()
        for token in tokens {
            message += field(10, message: token)
        }
        return GrpcWeb.encode(message: message)
    }

    static func token(id: String, start: Date?, end: Date) -> Data {
        var out = field(10, string: id)
        if let start {
            out += field(20, message: timestamp(start))
        }
        out += field(30, message: timestamp(end))
        return out
    }

    static func timestamp(_ date: Date) -> Data {
        field(1, varint: UInt64(date.timeIntervalSince1970.rounded(.down)))
    }

    static func field(_ number: UInt64, varint value: UInt64) -> Data {
        encodeVarint((number << 3) | 0) + encodeVarint(value)
    }

    static func field(_ number: UInt64, string: String) -> Data {
        let bytes = Data(string.utf8)
        return encodeVarint((number << 3) | 2) + encodeVarint(UInt64(bytes.count)) + bytes
    }

    static func field(_ number: UInt64, message: Data) -> Data {
        encodeVarint((number << 3) | 2) + encodeVarint(UInt64(message.count)) + message
    }

    static func encodeVarint(_ value: UInt64) -> Data {
        var n = value
        var out = Data()
        while n >= 0x80 {
            out.append(UInt8(n & 0x7F) | 0x80)
            n >>= 7
        }
        out.append(UInt8(n))
        return out
    }
}
