import Foundation
import Testing
@testable import UsageBarCore

/// A throwaway log in a temp directory. Never touches the real one under
/// Application Support — a test that writes into live data is a bug, not a test.
private func makeLog() throws -> (UsageLog, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("usage-log-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("usage-log.sqlite")
    return (try UsageLog(url: url), directory)
}

private func measurement(
    _ minute: Double,
    utilization: Double,
    locked: LockState = .unknown,
    limitID: String = "weekly_all",
    trackingID: String = "acct-1"
) -> UsageMeasurement {
    UsageMeasurement(
        observedAt: Date(timeIntervalSince1970: 1_800_000_000 + minute * 60),
        provider: .claude,
        trackingID: trackingID,
        limitID: limitID,
        label: "Week",
        utilization: utilization,
        resetsAt: Date(timeIntervalSince1970: 1_800_100_000),
        locked: locked,
        scope: .account,
        severity: .normal
    )
}

@Suite("UsageLog")
struct UsageLogTests {

    @Test func everyReadingBecomesARowIncludingUnchangedOnes() throws {
        let (log, directory) = try makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshot = UsageSnapshot(provider: .claude, trackingID: "acct-1", limits: [
            Limit(id: "session", label: "5 hours", utilization: 0.2, resetsAt: nil, locked: .unknown, scope: .account),
            Limit(id: "weekly_all", label: "Week", utilization: 0.5, resetsAt: nil, locked: .unknown, scope: .account),
        ])
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try log.record([snapshot], at: first) == 2)
        #expect(try log.record([snapshot], at: first.addingTimeInterval(300)) == 2)

        // Two identical readings five minutes apart are two rows. That is the point:
        // "nothing changed" is itself data, and a graph needs it.
        #expect(try log.count() == 4)
        #expect(try log.series(trackingID: "acct-1", limitID: "weekly_all").count == 2)
    }

    @Test func rowsSurviveACloseAndReopenWithEveryFieldIntact() throws {
        let (log, directory) = try makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("usage-log.sqlite")

        let row = UsageMeasurement(
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            provider: .grok,
            trackingID: "acct-2",
            limitID: "weekly",
            label: "Week",
            utilization: 0.75,
            resetsAt: Date(timeIntervalSince1970: 1_800_100_000),
            locked: .locked,
            scope: .model,
            severity: .critical
        )
        try log.append([row])

        let reopened = try UsageLog(url: url)
        let read = try reopened.series(trackingID: "acct-2", limitID: "weekly")
        #expect(read == [row])
    }

    @Test func aMissingResetDateStaysMissing() throws {
        let (log, directory) = try makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }

        try log.record([UsageSnapshot(provider: .chatGPT, trackingID: "acct-3", limits: [
            Limit(id: "session", label: "5 hours", utilization: 0, resetsAt: nil, locked: .unknown, scope: .account),
        ])], at: Date(timeIntervalSince1970: 1_800_000_000))

        // nil must not come back as 1970 — a fabricated date would show up as a
        // reset that already happened.
        #expect(try log.series(trackingID: "acct-3", limitID: "session").first?.resetsAt == nil)
    }

    @Test func seriesIsScopedToOneLimitOfOneAccountAndOrderedInTime() throws {
        let (log, directory) = try makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }

        try log.append([
            measurement(10, utilization: 0.4),
            measurement(0, utilization: 0.2),
            measurement(5, utilization: 0.3, limitID: "session"),
            measurement(5, utilization: 0.9, trackingID: "acct-9"),
        ])

        let series = try log.series(trackingID: "acct-1", limitID: "weekly_all")
        #expect(series.map(\.utilization) == [0.2, 0.4])
        #expect(try log.knownSeries().count == 3)
    }

    @Test func windowQueryHonoursBothEnds() throws {
        let (log, directory) = try makeLog()
        defer { try? FileManager.default.removeItem(at: directory) }

        try log.append((0..<10).map { measurement(Double($0), utilization: Double($0) / 10) })
        let since = Date(timeIntervalSince1970: 1_800_000_000 + 3 * 60)
        let until = Date(timeIntervalSince1970: 1_800_000_000 + 6 * 60)
        let window = try log.measurements(since: since, until: until)
        #expect(window.count == 4)
    }
}

@Suite("UsageHistory")
struct UsageHistoryTests {

    @Test func waitingSinceIsTheStartOfTheCurrentFullRun() {
        let series = [
            measurement(0, utilization: 0.8),
            measurement(5, utilization: 1.0),   // filled here
            measurement(10, utilization: 1.0),
            measurement(15, utilization: 1.0),
        ]
        let wait = UsageHistory.waitingForReset(series)
        #expect(wait?.since == Date(timeIntervalSince1970: 1_800_000_000 + 5 * 60))
        #expect(wait?.duration == 600)
        #expect(wait?.largestGap == 300)
    }

    @Test func notWaitingWhenTheNewestReadingIsNotFull() {
        let series = [
            measurement(0, utilization: 1.0),
            measurement(5, utilization: 0.1),
        ]
        #expect(UsageHistory.waitingForReset(series) == nil)
    }

    @Test func anEarlierFullRunDoesNotCountTowardsTheCurrentOne() {
        let series = [
            measurement(0, utilization: 1.0),
            measurement(5, utilization: 0.1),   // reset
            measurement(10, utilization: 1.0),  // full again
            measurement(15, utilization: 1.0),
        ]
        let wait = UsageHistory.waitingForReset(series)
        #expect(wait?.since == Date(timeIntervalSince1970: 1_800_000_000 + 10 * 60))
    }

    @Test func aLockCountsAsFullEvenWhenTheNumberDoesNot() {
        // Grok reports locked without ever reaching 100 %.
        let series = [measurement(0, utilization: 0.62, locked: .locked)]
        #expect(UsageHistory.waitingForReset(series)?.since
            == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func aSleepingMacShowsUpAsAGapInsteadOfABrokenRun() {
        let series = [
            measurement(0, utilization: 1.0),
            measurement(600, utilization: 1.0),  // ten hours later, app was off
        ]
        let wait = UsageHistory.waitingForReset(series)
        #expect(wait?.since == Date(timeIntervalSince1970: 1_800_000_000))
        // The run is unbroken as far as we saw — and the gap says how much we did
        // not see, so nobody reads 10 h of blindness as 10 h of measured waiting.
        #expect(wait?.largestGap == 36_000)
    }

    @Test func resetsAreTheDropBetweenTwoNeighbouringRows() {
        let series = [
            measurement(0, utilization: 0.9),
            measurement(5, utilization: 1.0),
            measurement(10, utilization: 1.0),
            measurement(15, utilization: 0.0),
            measurement(20, utilization: 0.3),
        ]
        let resets = UsageHistory.resets(series)
        #expect(resets.count == 1)
        #expect(resets.first?.at == Date(timeIntervalSince1970: 1_800_000_000 + 15 * 60))
        // From the first full reading to the last one — the fill happened somewhere
        // before minute 5 and the release somewhere after minute 10; only the measured
        // span is claimed.
        #expect(resets.first?.waitedFor == 300)
    }

    @Test func aRunAlreadyFullAtTheFirstReadingHasNoKnownWait() {
        let series = [
            measurement(0, utilization: 1.0),
            measurement(5, utilization: 0.0),
        ]
        // The app started mid-block. Reporting 0 s of waiting would be a lie;
        // "unknown" is the honest answer.
        #expect(UsageHistory.resets(series).first?.waitedFor == nil)
    }

    @Test func burnRateAndProjectionComeFromTheWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 60 * 60)
        let series = (0...12).map { measurement(Double($0) * 5, utilization: Double($0) * 0.05) }
        let rate = UsageHistory.burnRatePerHour(series, window: 3600, now: now)
        #expect(rate != nil)
        #expect(abs((rate ?? 0) - 0.6) < 0.001)

        let projection = UsageHistory.projectedFull(series, now: now)
        // 60 % used at 60 %/h → full 40 minutes after the last reading.
        #expect(abs((projection ?? .distantPast).timeIntervalSince(now) - 40 * 60) < 1)
    }

    @Test func aFallingLimitGetsNoProjection() {
        let now = Date(timeIntervalSince1970: 1_800_000_000 + 60 * 60)
        let series = [
            measurement(0, utilization: 0.9),
            measurement(30, utilization: 0.1),
        ]
        #expect(UsageHistory.burnRatePerHour(series, window: 3600, now: now) == nil)
        #expect(UsageHistory.projectedFull(series, now: now) == nil)
    }
}
