import Foundation
import Testing
@testable import UsageBarCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private func stamp(_ date: Date) -> String { date.ISO8601Format() }

/// One grant as `usage?cedar_ember=1` sends it. Placeholder ids and labels;
/// the keys are the ones measured on 2026-11-14.
private func grant(id: String = "grant-a", total: Int = 1, left: Int = 1, endsIn: TimeInterval?) -> String {
    let ends = endsIn.map { "\"\(stamp(now.addingTimeInterval($0)))\"" } ?? "null"
    return """
    {"id":"\(id)","label":"Placeholder","resets_total":\(total),"resets_left":\(left),
     "starts_at":"\(stamp(now.addingTimeInterval(-86_400)))","ends_at":\(ends),
     "clears":["seven_day"],"paused":false,"usable_now":true,"type":"full","gives_back_weekly":false}
    """
}

private func body(_ grants: [String], eligible: Bool = true) -> Data {
    Data("""
    {"five_hour":null,"seven_day":{"utilization":10.0,"resets_at":null},
     "cedar_ember":{"eligible":\(eligible),"ineligible_reason":null,"at_limit":false,
       "exhausted":[],"grants":[\(grants.joined(separator: ","))]}}
    """.utf8)
}

@Suite("Claude reset grants")
struct ClaudeResetGrantsTests {

    /// The shape behind claude.ai's "4 available": one weekly reset and three
    /// model resets with a later end. The count is the sum, the soonest end
    /// dates the line.
    @Test func sumsResetsLeftAcrossGrantsAndDatesEach() {
        let weekly = now.addingTimeInterval(26 * 86_400)
        let model = now.addingTimeInterval(115 * 86_400)
        let read = UsageParser.parseClaudeResetGrants(body: body([
            grant(id: "a", endsIn: 115 * 86_400),
            grant(id: "b", endsIn: 26 * 86_400),
            grant(id: "c", endsIn: 115 * 86_400),
            grant(id: "d", endsIn: 115 * 86_400),
        ]), now: now)
        #expect(read?.count == 4)
        #expect(read?.firstExpiry == weekly)
        #expect(read == .available(4, expiring: [weekly, model, model, model]))
    }

    @Test func aGrantWithTwoLeftCountsTwice() {
        let read = UsageParser.parseClaudeResetGrants(body: body([
            grant(total: 3, left: 2, endsIn: 3600),
        ]), now: now)
        #expect(read?.count == 2)
    }

    @Test func leftNeverExceedsTotal() {
        let read = UsageParser.parseClaudeResetGrants(body: body([
            grant(total: 1, left: 5, endsIn: 3600),
        ]), now: now)
        #expect(read?.count == 1)
    }

    @Test func usedUpExpiredAndUndatedGrantsDoNotCount() {
        let read = UsageParser.parseClaudeResetGrants(body: body([
            grant(id: "used", left: 0, endsIn: 3600),
            grant(id: "past", endsIn: -1),
            grant(id: "undated", endsIn: nil),
        ]), now: now)
        #expect(read == ResetRead.none)
    }

    /// An ineligible plan answers `eligible: false, grants: []` — a reading
    /// of zero, not a miss.
    @Test func ineligiblePlanIsNoneNotAMiss() {
        #expect(UsageParser.parseClaudeResetGrants(body: body([], eligible: false), now: now) == ResetRead.none)
    }

    /// The plain `/usage` call sends `cedar_ember: null`. That must not read
    /// as "0 resets" and clear a count we had.
    @Test func missingOrNullCedarEmberIsAMiss() {
        #expect(UsageParser.parseClaudeResetGrants(body: Data(#"{"cedar_ember":null}"#.utf8), now: now) == nil)
        #expect(UsageParser.parseClaudeResetGrants(body: Data(#"{"seven_day":null}"#.utf8), now: now) == nil)
        #expect(UsageParser.parseClaudeResetGrants(body: Data(#"{"cedar_ember":{"eligible":true}}"#.utf8), now: now) == nil)
        #expect(UsageParser.parseClaudeResetGrants(body: Data("not-json".utf8), now: now) == nil)
    }
}
