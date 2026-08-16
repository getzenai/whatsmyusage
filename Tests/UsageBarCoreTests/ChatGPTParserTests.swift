import Foundation
import Testing
@testable import UsageBarCore

private func parse(_ json: String, status: Int = 200) -> UsageOutcome {
    UsageParser.parseUsage(provider: .chatGPT, statusCode: status, body: Data(json.utf8))
}

private func snapshot(_ json: String) throws -> UsageSnapshot {
    let outcome = parse(json)
    guard case .snapshot(let snap) = outcome else {
        Issue.record("expected snapshot, got \(outcome)")
        throw UsageOutcomeMismatch()
    }
    return snap
}

private struct UsageOutcomeMismatch: Error {}

@Suite("ChatGPT parseUsage")
struct ChatGPTParserTests {

    @Test func lockedWorkspaceUsesAllowedAndPercent() throws {
        let snap = try snapshot(Fixtures.chatGPTLocked)
        let limit = try #require(snap.limits.first)
        #expect(limit.id == "primary")
        #expect(limit.utilization == 1)
        #expect(limit.locked == .locked)
        #expect(limit.label == "Week")
        #expect(limit.scope == .account)
        #expect(snap.accountLabel == "team")
        #expect(limit.resetsAt == Date(timeIntervalSince1970: 1_787_043_909))
    }

    @Test func secondaryWindowIsItsOwnLimit() throws {
        let snap = try snapshot(Fixtures.chatGPTOpen)
        #expect(snap.limits.map(\.id) == ["primary", "secondary"])
        #expect(snap.limits.map(\.locked) == [.unlocked, .unlocked])
        #expect(snap.worstAccountLimit?.id == "secondary")
        #expect(snap.worstAccountLimit?.utilization == 0.40)
        #expect(snap.limits.first { $0.id == "primary" }?.label == "3 hours")
    }

    @Test func missingAllowedStaysUnknown() throws {
        let json = """
        {"rate_limit": {"primary_window": {"used_percent": 10, "limit_window_seconds": 3600}}}
        """
        let snap = try snapshot(json)
        #expect(snap.limits.first?.locked == .unknown)
    }

    @Test func forbiddenIsNotExpired() {
        // Cloudflare 403 is a fingerprint, not a logout.
        #expect(parse("{}", status: 403) == .httpError(status: 403))
    }

    @Test func unauthorizedIsExpired() {
        #expect(parse("{}", status: 401) == .expired)
    }

    @Test func sessionWithoutAccessTokenIsExpired() {
        let body = Data(Fixtures.chatGPTSessionLoggedOut.utf8)
        #expect(UsageParser.chatGPTAccessToken(statusCode: 200, body: body) == .failed(.expired))
    }

    @Test func sessionWithAccessTokenYieldsBearer() {
        let body = Data(Fixtures.chatGPTSession.utf8)
        #expect(
            UsageParser.chatGPTAccessToken(statusCode: 200, body: body)
                == .bearer(Fixtures.sampleChatGPTAccessToken)
        )
    }

    @Test func missingWindowsIsEmpty() {
        #expect(parse(#"{"plan_type":"team","rate_limit":{}}"#) == .empty)
    }

    @Test func resetCreditsZeroIsNoneNotDisplayed() {
        let body = Data(#"{"available_count":0,"credits":[],"immediate_reset_purchase_eligible":false,"total_earned_count":0}"#.utf8)
        #expect(UsageParser.parseChatGPTResetCredits(body: body) == .none)
        #expect(ResetRead.label(for: 0) == nil)
    }

    @Test func resetCreditsMissingKeyIsOmitted() {
        #expect(UsageParser.parseChatGPTResetCredits(body: Data(#"{"credits":[]}"#.utf8)) == nil)
        #expect(UsageParser.parseChatGPTResetCredits(body: Data(#"{}"#.utf8)) == nil)
        #expect(UsageParser.parseChatGPTResetCredits(body: Data("not-json".utf8)) == nil)
    }

    @Test func resetCreditsPositiveIsAvailable() {
        let one = Data(#"{"available_count":1,"credits":[],"immediate_reset_purchase_eligible":false}"#.utf8)
        let two = Data(#"{"available_count":2}"#.utf8)
        #expect(UsageParser.parseChatGPTResetCredits(body: one) == .available(1))
        #expect(UsageParser.parseChatGPTResetCredits(body: two) == .available(2))
        #expect(ResetRead.label(for: 1) == "Reset available")
        #expect(ResetRead.label(for: 2) == "2 resets available")
    }
}
