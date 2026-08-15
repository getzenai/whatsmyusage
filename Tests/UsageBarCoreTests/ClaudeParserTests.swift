import Foundation
import Testing
@testable import UsageBarCore

private func parse(
    _ json: String,
    status: Int = 200,
    endpoint: Endpoint = .usage
) -> UsageOutcome {
    UsageParser.parseUsage(
        provider: .claude,
        statusCode: status,
        body: Data(json.utf8),
        endpoint: endpoint
    )
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

@Suite("Claude parseUsage")
struct ClaudeParserTests {

    /// The bar that only looks at the 5-hour window would show 0 % here.
    @Test func blockedAccountIsFullDespiteEmptySessionWindow() throws {
        let snap = try snapshot(Fixtures.claudeBlocked)
        let session = try #require(snap.limits.first { $0.id == "session" })
        #expect(session.utilization == 0)
        #expect(session.locked == .unknown)

        let worst = try #require(snap.worstAccountLimit)
        #expect(worst.id == "weekly_all")
        #expect(worst.utilization == 1)
        #expect(worst.locked == .unknown)
    }

    /// A full model limit must not drive the bar: the account is still at 20 %.
    @Test func modelLimitDoesNotDriveTheBar() throws {
        let snap = try snapshot(Fixtures.claudeModelHigher)
        let model = try #require(snap.limits.first { $0.scope == .model })
        #expect(model.label == "Week · ExampleModel")
        #expect(model.utilization == 0.35)
        #expect(snap.worstAccountLimit?.utilization == 0.20)
    }

    @Test func limitsArrayIsTheSource() throws {
        let snap = try snapshot(Fixtures.claudeBlocked)
        #expect(snap.limits.map(\.id) == ["session", "weekly_all", "weekly_scoped:ExampleModel"])
    }

    @Test func unknownKindSurvives() throws {
        let snap = try snapshot(#"{"limits": [{"kind": "monthly_extra", "percent": 42, "scope": null}]}"#)
        let bucket = try #require(snap.limits.first)
        #expect(bucket.id == "monthly_extra")
        #expect(bucket.scope == .account)
        #expect(bucket.label == "monthly extra")
        #expect(bucket.utilization == 0.42)
    }

    @Test func limitWithoutPercentIsDropped() throws {
        let json = """
        {"limits": [{"kind": "session", "scope": null},
                    {"kind": "weekly_all", "percent": 7, "scope": null}]}
        """
        #expect(try snapshot(json).limits.map(\.id) == ["weekly_all"])
    }

    @Test func fallsBackToTopLevelKeysWhenLimitsMissing() throws {
        let json = """
        {"five_hour": {"utilization": 30, "resets_at": null},
         "seven_day": {"utilization": 60, "resets_at": null},
         "seven_day_opus": {"utilization": 90, "resets_at": null}}
        """
        let snap = try snapshot(json)
        #expect(snap.limits.map(\.id) == ["five_hour", "seven_day", "seven_day_opus"])
        #expect(snap.worstAccountLimit?.utilization == 0.60)
        #expect(snap.limits.first { $0.id == "seven_day_opus" }?.scope == .model)
    }

    @Test func emptyLimitsArrayFallsBack() throws {
        let snap = try snapshot(#"{"limits": [], "five_hour": {"utilization": 5}}"#)
        #expect(snap.limits.map(\.id) == ["five_hour"])
    }

    @Test func fantasyTopLevelKeysAreNotLimits() throws {
        let json = """
        {"amber_ladder": null, "tangelo": null, "omelette_promotional": {"utilization": null},
         "limits": [{"kind": "session", "percent": 1, "scope": null}]}
        """
        #expect(try snapshot(json).limits.map(\.id) == ["session"])
    }

    @Test func permissionErrorBodyOn200IsNotTrackable() {
        let outcome = parse(Fixtures.claudePermissionError)
        guard case .notTrackable(let message) = outcome else {
            Issue.record("expected notTrackable, got \(outcome)")
            return
        }
        #expect(message.contains("Invalid authorization"))
    }

    @Test func permissionErrorOn403IsNotExpired() {
        let outcome = parse(Fixtures.claudePermissionError, status: 403)
        guard case .notTrackable = outcome else {
            Issue.record("expected notTrackable, got \(outcome)")
            return
        }
    }

    @Test func unauthorizedIsExpired() {
        #expect(parse("{}", status: 401) == .expired)
    }

    @Test func forbiddenBootstrapIsExpired() {
        #expect(parse("{}", status: 403, endpoint: .bootstrap) == .expired)
    }

    @Test func responseWithoutBucketsIsEmpty() {
        #expect(parse(#"{"member_dashboard_available": false}"#) == .empty)
    }

    @Test func nonJSONIsNotJSON() {
        #expect(parse("<html>Just a moment…") == .notJSON)
    }

    @Test func severityIsCarriedAndUnknownDoesNotThrow() throws {
        let snap = try snapshot(Fixtures.claudeBlocked)
        #expect(snap.limits.first { $0.id == "session" }?.severity == .normal)
        #expect(snap.limits.first { $0.id == "weekly_all" }?.severity == .critical)

        let weird = try snapshot(#"{"limits": [{"kind": "session", "percent": 1, "severity": "meltdown"}]}"#)
        #expect(weird.limits.first?.severity == .unknown)
    }

    @Test func fractionalPercentBecomesUtilization() throws {
        let snap = try snapshot(#"{"limits": [{"kind": "session", "percent": 14.3}]}"#)
        #expect(abs((snap.limits.first?.utilization ?? 0) - 0.143) < 0.0001)
    }

    @Test func sixFractionalDigitsParseToTheSameMomentAsThree() throws {
        let six = try snapshot("""
        {"limits": [{"kind": "weekly_all", "percent": 1,
                     "resets_at": "2026-08-17T00:59:59.562414+00:00"}]}
        """)
        let three = try snapshot("""
        {"limits": [{"kind": "weekly_all", "percent": 1,
                     "resets_at": "2026-08-17T00:59:59.562+00:00"}]}
        """)
        let a = try #require(six.limits.first?.resetsAt)
        let b = try #require(three.limits.first?.resetsAt)
        #expect(abs(a.timeIntervalSince1970 - b.timeIntervalSince1970) < 0.001)
    }

    @Test func zuluDateParses() throws {
        let snap = try snapshot(#"{"limits": [{"kind": "session", "percent": 1, "resets_at": "2026-08-17T00:59:59Z"}]}"#)
        #expect(snap.limits.first?.resetsAt != nil)
    }

    @Test func bootstrapListsChatOrgsAndKeepsTheAPIConsole() {
        let orgs = UsageParser.claudeOrganizations(from: Data(Fixtures.claudeBootstrap.utf8))
        #expect(orgs.map(\.id) == [
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002",
            "00000000-0000-4000-8000-000000000003",
        ])
        #expect(orgs.filter(\.isChatCapable).map(\.id) == [
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002",
        ])
    }
}
