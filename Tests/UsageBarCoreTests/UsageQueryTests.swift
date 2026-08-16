import Foundation
import Testing
@testable import UsageBarCore

private let origin = Date(timeIntervalSince1970: 1_800_000_000)

private func row(
    trackingID: String,
    limitID: String,
    utilization: Double,
    provider: Provider = .claude,
    locked: LockState = .unknown,
    scope: LimitScope = .account,
    resetsAt: Date? = origin.addingTimeInterval(86_400),
    minutesAgo: Double = 1,
    now: Date = origin
) -> UsageMeasurement {
    UsageMeasurement(
        observedAt: now.addingTimeInterval(-minutesAgo * 60),
        provider: provider,
        trackingID: trackingID,
        limitID: limitID,
        label: limitID,
        utilization: utilization,
        resetsAt: resetsAt,
        locked: locked,
        scope: scope,
        severity: .normal
    )
}

@Suite("UsageQuery")
struct UsageQueryTests {

    @Test func aFreshReadingKeepsItsNumber() {
        let now = origin
        let status = UsageQuery.status(
            from: [row(trackingID: "acct-1", limitID: "weekly_all", utilization: 0.42, now: now)],
            now: now
        )
        #expect(status.accounts.count == 1)
        #expect(status.accounts[0].limits[0].utilization == 0.42)
        #expect(status.accounts[0].limits[0].locked == .unknown)
    }

    @Test func aReadingOlderThanRefreshPlusReserveIsUnknown() {
        let now = origin
        let staleMinutes = (UsageQuery.staleAfter / 60) + 1
        let status = UsageQuery.status(
            from: [row(
                trackingID: "acct-1",
                limitID: "weekly_all",
                utilization: 0.1,
                minutesAgo: staleMinutes,
                now: now
            )],
            now: now
        )
        // 10 % sitting in the file must not come out as the current value.
        #expect(status.accounts[0].limits[0].utilization == nil)
        #expect(status.accounts[0].limits[0].locked == nil)
        #expect(status.accounts[0].limits[0].resetsAt == nil)
        #expect(status.accounts[0].limits[0].observedAt != nil)
    }

    @Test func aReadingJustInsideTheWindowStaysCurrent() {
        let now = origin
        let freshMinutes = (UsageQuery.staleAfter / 60) - 0.1
        let status = UsageQuery.status(
            from: [row(
                trackingID: "acct-1",
                limitID: "weekly_all",
                utilization: 0.33,
                minutesAgo: freshMinutes,
                now: now
            )],
            now: now
        )
        #expect(status.accounts[0].limits[0].utilization == 0.33)
    }

    @Test func pickChoosesTheAccountWithTheMostRoom() {
        let now = origin
        let latest = [
            row(trackingID: "full", limitID: "weekly_all", utilization: 0.9, now: now),
            row(trackingID: "air", limitID: "weekly_all", utilization: 0.1, now: now),
        ]
        let picked = UsageQuery.pick(from: latest, now: now)
        #expect(picked.trackingID == "air")
        #expect(picked.utilization == 0.1)
        #expect(picked.found)
    }

    @Test func pickIsStableWhenTheInputOrderSwaps() {
        let now = origin
        let a = row(trackingID: "acct-a", limitID: "weekly_all", utilization: 0.4, now: now)
        let b = row(trackingID: "acct-b", limitID: "weekly_all", utilization: 0.4, now: now)
        let forward = UsageQuery.pick(from: [a, b], now: now)
        let reverse = UsageQuery.pick(from: [b, a], now: now)
        #expect(forward.trackingID == reverse.trackingID)
        #expect(forward.trackingID == "acct-a")
    }

    @Test func pickSkipsAStaleAccountEvenWhenItsNumberLooksOpen() {
        let now = origin
        let staleMinutes = (UsageQuery.staleAfter / 60) + 1
        let latest = [
            row(
                trackingID: "stale-open",
                limitID: "weekly_all",
                utilization: 0.01,
                minutesAgo: staleMinutes,
                now: now
            ),
            row(trackingID: "fresh-tighter", limitID: "weekly_all", utilization: 0.5, now: now),
        ]
        let picked = UsageQuery.pick(from: latest, now: now)
        #expect(picked.trackingID == "fresh-tighter")
    }

    @Test func pickTreatsALockAsBlockedEvenWhenTheNumberIsNotFull() {
        let now = origin
        let latest = [
            row(
                trackingID: "grok-1",
                limitID: "weekly",
                utilization: 0.62,
                provider: .grok,
                locked: .locked,
                now: now
            ),
        ]
        let picked = UsageQuery.pick(from: latest, now: now)
        #expect(!picked.found)
        #expect(picked.trackingID == nil)
        #expect(picked.utilization == nil)
    }

    @Test func aFullModelLimitBlocksEvenWhenTheAccountHasRoom() {
        let now = origin
        let soon = now.addingTimeInterval(3600)
        let latest = [
            row(trackingID: "acct-1", limitID: "weekly_all", utilization: 0.2, now: now),
            row(
                trackingID: "acct-1",
                limitID: "weekly_opus",
                utilization: 1,
                scope: .model,
                resetsAt: soon,
                now: now
            ),
        ]
        let picked = UsageQuery.pick(from: latest, now: now)
        #expect(!picked.found)
        #expect(picked.resetsAt == soon)
    }

    @Test func pickKeepsAccountUtilizationWhenAModelLimitIsHighButOpen() {
        let now = origin
        let latest = [
            row(trackingID: "acct-1", limitID: "weekly_all", utilization: 0.2, now: now),
            row(
                trackingID: "acct-1",
                limitID: "weekly_opus",
                utilization: 0.9,
                scope: .model,
                now: now
            ),
        ]
        let picked = UsageQuery.pick(from: latest, now: now)
        #expect(picked.trackingID == "acct-1")
        #expect(picked.utilization == 0.2)
    }

    @Test func pickPrefersATighterOpenAccountOverOneWithAFullModel() {
        let now = origin
        let airButFableFull = [
            row(trackingID: "fable-full", limitID: "weekly_all", utilization: 0.1, now: now),
            row(
                trackingID: "fable-full",
                limitID: "weekly_scoped:Fable",
                utilization: 1,
                scope: .model,
                now: now
            ),
        ]
        let tighterButOpen = [
            row(trackingID: "open", limitID: "weekly_all", utilization: 0.4, now: now),
        ]
        let forward = UsageQuery.pick(from: airButFableFull + tighterButOpen, now: now)
        let reverse = UsageQuery.pick(from: tighterButOpen + airButFableFull, now: now)
        #expect(forward.trackingID == "open")
        #expect(reverse.trackingID == "open")
        #expect(forward.utilization == 0.4)
    }

    @Test func pickRestrictedToAProviderIgnoresTheOthers() {
        let now = origin
        let latest = [
            row(trackingID: "claude-1", limitID: "weekly_all", utilization: 0.8, now: now),
            row(
                trackingID: "grok-1",
                limitID: "weekly",
                utilization: 0.1,
                provider: .grok,
                now: now
            ),
        ]
        let picked = UsageQuery.pick(from: latest, now: now, provider: .claude)
        #expect(picked.trackingID == "claude-1")
        #expect(picked.provider == .claude)
    }

    @Test func whenEverythingIsBlockedTheEarliestResetSurvives() {
        let now = origin
        let soon = now.addingTimeInterval(3600)
        let later = now.addingTimeInterval(7200)
        let latest = [
            row(
                trackingID: "later",
                limitID: "weekly_all",
                utilization: 1,
                resetsAt: later,
                now: now
            ),
            row(
                trackingID: "sooner",
                limitID: "weekly_all",
                utilization: 1,
                resetsAt: soon,
                now: now
            ),
        ]
        let picked = UsageQuery.pick(from: latest, now: now)
        #expect(!picked.found)
        #expect(picked.resetsAt == soon)
    }

    @Test func statusJSONUsesModelFieldNamesAndNullsAStaleNumber() throws {
        let now = origin
        let staleMinutes = (UsageQuery.staleAfter / 60) + 1
        let status = UsageQuery.status(
            from: [
                row(trackingID: "acct-1", limitID: "weekly_all", utilization: 0.25, now: now),
                row(
                    trackingID: "acct-2",
                    limitID: "weekly_all",
                    utilization: 0.99,
                    minutesAgo: staleMinutes,
                    now: now
                ),
            ],
            now: now
        )
        let object = try JSONSerialization.jsonObject(with: try UsageQuery.statusJSON(status)) as! [String: Any]
        #expect(object["observedAt"] is String)
        let accounts = object["accounts"] as! [[String: Any]]
        #expect(accounts.count == 2)
        let first = accounts[0]
        #expect(first["trackingID"] as? String == "acct-1")
        let firstLimit = (first["limits"] as! [[String: Any]])[0]
        #expect(firstLimit["limitID"] as? String == "weekly_all")
        #expect(firstLimit["utilization"] as? Double == 0.25)
        #expect(firstLimit["resetsAt"] is String)
        let secondLimit = (accounts[1]["limits"] as! [[String: Any]])[0]
        #expect(secondLimit["utilization"] is NSNull)
        #expect(secondLimit["locked"] is NSNull)
        #expect(secondLimit["resetsAt"] is NSNull)
        #expect(secondLimit["observedAt"] is String)
    }

    @Test func pickJSONOmitsANumberWhenNothingIsUsable() throws {
        let now = origin
        let picked = UsageQuery.pick(
            from: [row(trackingID: "acct-1", limitID: "weekly_all", utilization: 1, now: now)],
            now: now
        )
        let object = try JSONSerialization.jsonObject(with: try UsageQuery.pickJSON(picked)) as! [String: Any]
        #expect(object["trackingID"] is NSNull)
        #expect(object["utilization"] is NSNull)
        #expect(object["resetsAt"] is String)
        #expect(object["observedAt"] is String)
    }
}

@Suite("UsageLog CLI seams")
struct UsageLogCLISeamTests {

    @Test func latestBySeriesIsTheNewestRowOfEachSeries() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage-log.sqlite")
        let log = try UsageLog(url: url)

        let first = Date(timeIntervalSince1970: 1_800_000_000)
        try log.record([
            UsageSnapshot(provider: .claude, trackingID: "acct-1", limits: [
                Limit(id: "weekly_all", label: "Week", utilization: 0.2, resetsAt: nil, locked: .unknown, scope: .account),
            ]),
        ], at: first)
        try log.record([
            UsageSnapshot(provider: .claude, trackingID: "acct-1", limits: [
                Limit(id: "weekly_all", label: "Week", utilization: 0.4, resetsAt: nil, locked: .unknown, scope: .account),
            ]),
        ], at: first.addingTimeInterval(300))

        let latest = try log.latestBySeries()
        #expect(latest.count == 1)
        #expect(latest[0].utilization == 0.4)
    }

    @Test func aReadOnlyOpenDoesNotCreateAMissingFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missing.sqlite")
        #expect(throws: UsageLogError.self) {
            _ = try UsageLog(url: url, readOnly: true)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aReadOnlyOpenSeesWhatTheWriterJustStored() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("usage-query-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage-log.sqlite")
        let writer = try UsageLog(url: url)
        try writer.record([
            UsageSnapshot(provider: .grok, trackingID: "acct-9", limits: [
                Limit(id: "weekly", label: "Week", utilization: 0.5, resetsAt: nil, locked: .unknown, scope: .account),
            ]),
        ], at: Date(timeIntervalSince1970: 1_800_000_000))

        let reader = try UsageLog(url: url, readOnly: true)
        #expect(try reader.latestBySeries().map(\.trackingID) == ["acct-9"])
    }
}
