import Foundation
import Testing
@testable import UsageBarCore

private func parse(_ json: String, status: Int = 200, model: String = "fast") -> UsageOutcome {
    UsageParser.parseUsage(
        provider: .grok,
        statusCode: status,
        body: Data(json.utf8),
        context: ParseContext(grokModel: model)
    )
}

private func snapshot(_ json: String, model: String = "fast") throws -> UsageSnapshot {
    let outcome = parse(json, model: model)
    guard case .snapshot(let snap) = outcome else {
        Issue.record("expected snapshot, got \(outcome)")
        throw UsageOutcomeMismatch()
    }
    return snap
}

private struct UsageOutcomeMismatch: Error {}

@Suite("Grok parseUsage")
struct GrokParserTests {

    @Test func unusedWindowIsZeroAndUnlocked() throws {
        let snap = try snapshot(Fixtures.grokUnused)
        let limit = try #require(snap.limits.first)
        #expect(limit.utilization == 0)
        #expect(limit.locked == .unlocked)
        #expect(limit.label == "2 Stunden · fast")
        #expect(limit.resetsAt == nil)
        #expect(limit.id == "fast")
    }

    @Test func zeroRemainingIsLockedAndFull() throws {
        let snap = try snapshot(Fixtures.grokEmpty)
        let limit = try #require(snap.limits.first)
        #expect(limit.utilization == 1)
        #expect(limit.locked == .locked)
    }

    @Test func utilizationIsComputedNotTakenFromTheProvider() throws {
        let snap = try snapshot(#"{"remainingQueries": 27, "totalQueries": 270, "windowSizeSeconds": 7200}"#)
        #expect(abs((snap.limits.first?.utilization ?? -1) - 0.9) < 0.0001)
    }

    @Test func modelNameIsNotHardcoded() throws {
        let snap = try snapshot(Fixtures.grokUnused, model: "expert")
        #expect(snap.limits.first?.id == "expert")
        #expect(snap.limits.first?.label == "2 Stunden · expert")
    }

    @Test func nestedWindowsArePickedUpByShape() throws {
        let json = """
        {"remainingQueries": 10, "totalQueries": 10, "windowSizeSeconds": 7200,
         "lowEffortRateLimits": {"remainingQueries": 1, "totalQueries": 2, "windowSizeSeconds": 7200}}
        """
        let snap = try snapshot(json)
        #expect(snap.limits.map(\.id) == ["fast", "fast/lowEffortRateLimits"])
        #expect(snap.limits.first { $0.id == "fast/lowEffortRateLimits" }?.utilization == 0.5)
    }

    @Test func divideByZeroIsEmpty() {
        #expect(parse(#"{"remainingQueries": 0, "totalQueries": 0}"#) == .empty)
    }

    @Test func forbiddenIsNotExpired() {
        #expect(parse("{}", status: 403) == .httpError(status: 403))
    }
}
