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

    @Test func grokOneValidTokenCountsAndKeepsItsEnd() {
        let end = now.addingTimeInterval(3600)
        let body = ResetWire.grok(tokens: [
            ResetWire.token(id: "tok-1", start: now.addingTimeInterval(-3600), end: end),
        ])
        let read = UsageParser.parseGrokRemainingResets(body: body, now: now)
        #expect(read == .available(1, expiring: [end]))
        #expect(read?.firstExpiry == end)
        #expect(ResetRead.label(for: 1, expiring: end, now: now) == "Reset available · expires in 1h")
    }

    /// The soonest end is the one the user has to act on, whatever order the
    /// provider listed the tokens in.
    @Test func grokTwoValidTokensCountAndReportTheSoonestEnd() {
        let soon = now.addingTimeInterval(3600)
        let later = now.addingTimeInterval(86_400)
        let body = ResetWire.grok(tokens: [
            ResetWire.token(id: "tok-late", start: now.addingTimeInterval(-60), end: later),
            ResetWire.token(id: "tok-soon", start: now.addingTimeInterval(-3600), end: soon),
        ])
        let read = UsageParser.parseGrokRemainingResets(body: body, now: now)
        #expect(read == .available(2, expiring: [soon, later]))
        #expect(read?.firstExpiry == soon)
        #expect(ResetRead.label(for: 2, expiring: soon, now: now) == "2 resets available · next expires in 1h")
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
        let end = now.addingTimeInterval(3600)
        let body = ResetWire.grok(tokens: [
            ResetWire.token(id: "tok-open", start: nil, end: end),
        ])
        #expect(UsageParser.parseGrokRemainingResets(body: body, now: now) == .available(1, expiring: [end]))
    }

    @Test func chatGPTZeroIsNoneNotAGuess() {
        let body = Data(#"{"available_count":0,"credits":[],"immediate_reset_purchase_eligible":false}"#.utf8)
        #expect(UsageParser.parseChatGPTResetCredits(body: body) == ResetRead.none)
    }

    /// An entry without `expires_at` is undated. The count still stands.
    @Test func chatGPTPositiveCountIsAvailable() {
        let body = Data(#"{"available_count":3,"credits":[{}],"immediate_reset_purchase_eligible":false}"#.utf8)
        let read = UsageParser.parseChatGPTResetCredits(body: body)
        #expect(read == .available(3))
        #expect(read?.firstExpiry == nil)
    }

    /// Shape measured live 2026-09-06; values are placeholders.
    @Test func chatGPTDatesEveryAvailableCreditAndReportsTheSoonest() {
        let body = Data(#"""
        {"available_count":2,
         "credits":[
           {"id":"RateLimitResetCredit_placeholder2","status":"available","title":"Full reset",
            "reset_type":"codex_rate_limits","is_supported_by_plan":true,
            "granted_at":"2026-09-04T05:40:42.702365Z","expires_at":"2026-10-04T05:40:42.702365Z",
            "redeemed_at":null,"redeem_started_at":null},
           {"id":"RateLimitResetCredit_placeholder1","status":"available","title":"Full reset",
            "reset_type":"codex_rate_limits","is_supported_by_plan":true,
            "granted_at":"2026-08-22T00:25:41.334314Z","expires_at":"2026-09-21T00:25:41.334314Z",
            "redeemed_at":null,"redeem_started_at":null}],
         "history_enabled":false,"immediate_reset_purchase_eligible":false,"total_earned_count":0}
        """#.utf8)
        let read = UsageParser.parseChatGPTResetCredits(body: body, now: isoDate("2026-09-06T12:00:00.000Z"))
        #expect(read?.count == 2)
        #expect(read?.firstExpiry == isoDate("2026-09-21T00:25:41.334314Z"))
    }

    /// A used voucher keeps its `expires_at`. Counting that date would warn
    /// about a deadline that passed for a voucher that is gone.
    @Test func chatGPTIgnoresTheExpiryOfACreditThatIsNoLongerAvailable() {
        let body = Data(#"""
        {"available_count":1,
         "credits":[
           {"id":"RateLimitResetCredit_placeholder1","status":"redeemed",
            "expires_at":"2026-09-10T00:00:00.000000Z","redeemed_at":"2026-09-01T00:00:00.000000Z"},
           {"id":"RateLimitResetCredit_placeholder2","status":"available",
            "expires_at":"2026-10-04T05:40:42.702365Z","redeemed_at":null}],
         "immediate_reset_purchase_eligible":false}
        """#.utf8)
        let read = UsageParser.parseChatGPTResetCredits(body: body, now: isoDate("2026-09-06T12:00:00.000Z"))
        #expect(read == .available(1, expiring: [isoDate("2026-10-04T05:40:42.702365Z")]))
    }

    /// One stale entry must not win `min()` and hide the deadline that is still
    /// ahead. The count is the provider's either way.
    @Test func chatGPTDropsAnExpiryThatHasAlreadyPassed() {
        let body = Data(#"""
        {"available_count":2,
         "credits":[
           {"id":"RateLimitResetCredit_placeholder1","status":"available",
            "expires_at":"2026-09-01T00:00:00.000000Z"},
           {"id":"RateLimitResetCredit_placeholder2","status":"available",
            "expires_at":"2026-10-04T05:40:42.702365Z"}],
         "immediate_reset_purchase_eligible":false}
        """#.utf8)
        let read = UsageParser.parseChatGPTResetCredits(body: body, now: isoDate("2026-09-06T12:00:00.000Z"))
        #expect(read == .available(2, expiring: [isoDate("2026-10-04T05:40:42.702365Z")]))
    }

    /// The provider still counts it, so we still show it — just without a
    /// deadline in the past.
    @Test func anExpiryAlreadyPastIsDroppedFromTheLabel() {
        #expect(ResetRead.label(for: 1, expiring: now.addingTimeInterval(-60), now: now) == "Reset available")
        #expect(ResetRead.label(for: 0, expiring: now.addingTimeInterval(3600), now: now) == nil)
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

    @Test func cardTakesCountAndExpiryFromTheRead() {
        let end = now.addingTimeInterval(15 * 86_400)
        let card = sampleCard(resetAvailable: nil).withReset(.available(3, expiring: [end]))
        #expect(card.resetAvailable == 3)
        #expect(card.resetExpiry == end)
        #expect(card.resetLabel(now: now) == "3 resets available · next expires in 15d")
        #expect(card.displaying(limits: []).resetLabel(now: now) == "3 resets available · next expires in 15d")
    }

    /// A miss must not blank a card that was showing a good count.
    @Test func cardWithoutAReadShowsNothing() {
        let card = sampleCard(resetAvailable: 2, resetExpiry: now).withReset(nil)
        #expect(card.resetAvailable == nil)
        #expect(card.resetLabel(now: now) == nil)
    }
}

private func isoDate(_ raw: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: String(raw.prefix(23)) + "Z")!
}

private func sampleCard(resetAvailable: Int?, resetExpiry: Date? = nil) -> AccountCard {
    AccountCard(
        trackingID: "grok:placeholder",
        provider: .grok,
        defaultName: "Grok",
        limits: [],
        tone: .blocked,
        utilization: 1,
        resetAvailable: resetAvailable,
        resetExpiry: resetExpiry
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
