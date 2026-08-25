import Foundation
import Testing
@testable import UsageBarCore

/// A fixed clock and a fixed calendar. Achievements read hours and day boundaries,
/// so a test that used the machine's time zone would pass or fail by geography.
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2027-01-21 00:00 UTC, the start of a day.
private let origin = Date(timeIntervalSince1970: 1_800_000_000 - 28_800)

private func reading(
    hours: Double,
    _ utilization: Double,
    locked: LockState = .unknown,
    provider: Provider = .claude,
    trackingID: String = "acct-1",
    limitID: String = "weekly_all",
    label: String = "Week",
    scope: LimitScope = .account,
    resetHours: Double? = nil
) -> UsageMeasurement {
    let observedAt = origin.addingTimeInterval(hours * 3600)
    return UsageMeasurement(
        observedAt: observedAt,
        provider: provider,
        trackingID: trackingID,
        limitID: limitID,
        label: label,
        utilization: utilization,
        resetsAt: resetHours.map { observedAt.addingTimeInterval($0 * 3600) },
        locked: locked,
        scope: scope,
        severity: .normal
    )
}

/// `count` finished full-runs, three hours apart: rise, wall, reset.
private func maxOuts(_ count: Int) -> [UsageMeasurement] {
    (0..<count).flatMap { index -> [UsageMeasurement] in
        let base = Double(index) * 3
        return [
            reading(hours: base, 0.5),
            reading(hours: base + 1, 1.0),
            reading(hours: base + 2, 0.0),
        ]
    }
}

private func evaluate(
    _ series: [[UsageMeasurement]],
    days: Set<Date> = []
) -> [Achievements.Achievement] {
    Achievements.evaluate(series: series, observedDays: days, calendar: utc)
}

private func days(_ count: Int, fromHour: Double = 0) -> Set<Date> {
    Set((0..<count).map {
        utc.startOfDay(for: origin.addingTimeInterval((fromHour + Double($0) * 24) * 3600))
    })
}

private func earned(_ list: [Achievements.Achievement], _ kind: Achievements.Kind) -> Achievements.Achievement {
    list.first { $0.kind == kind }!
}

@Suite("Achievements")
struct AchievementsTests {

    @Test func aFullRunIsBoundedByTheReadingsThatSawIt() {
        let series = [
            reading(hours: 0, 0.5),
            reading(hours: 1, 1.0),
            reading(hours: 4, 1.0),
            reading(hours: 5, 0.0),
        ]
        let runs = Achievements.fullRuns(series)
        #expect(runs.count == 1)
        #expect(runs[0].start == origin.addingTimeInterval(3600))
        #expect(runs[0].end == origin.addingTimeInterval(5 * 3600))
        #expect(runs[0].completedDuration == 14_400)  // h1 full … h5 free
    }

    @Test func aRunStillGoingHasNoCompletedDuration() {
        let runs = Achievements.fullRuns([reading(hours: 0, 0.4), reading(hours: 1, 1.0)])
        #expect(runs.count == 1)
        #expect(runs[0].end == nil)
        #expect(runs[0].completedDuration == nil)
    }

    @Test func aRunAlreadyFullAtTheFirstReadingHasNoMeasuredStart() {
        let runs = Achievements.fullRuns([reading(hours: 0, 1.0), reading(hours: 2, 0.0)])
        #expect(runs[0].start == nil)
        #expect(runs[0].completedDuration == nil)
        // The lower bound survives, which is what "Maxed out" may claim.
        #expect(runs[0].firstSeenFull == origin)
    }

    @Test func theWaitTakesTheLongestFinishedRunAndIgnoresTheRunningOne() {
        let series = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 4, 1.0),   // finished at h5
            reading(hours: 5, 0.1),
            reading(hours: 6, 1.0),   // still going, longer — must not win
            reading(hours: 20, 1.0),
        ]]
        let wait = earned(Achievements.evaluate(series: series, observedDays: [], calendar: utc), .longestWait)
        #expect(wait.isEarned)
        #expect(wait.detail == "4h 00m waiting on Week.")
    }

    @Test func aDurationNeverReadsSixtyMinutes() {
        #expect(TimeInterval(45 * 60).hoursAndMinutes == "45m")
        #expect(TimeInterval(3 * 3600 + 5 * 60).hoursAndMinutes == "3h 05m")
        // 119.6 min: rounding must carry into the hour, not print "1h 60m".
        #expect(TimeInterval(119.6 * 60).hoursAndMinutes == "2h 00m")
        // A day or more switches unit; under a day stays as it was.
        #expect(TimeInterval(23 * 3600 + 59 * 60).hoursAndMinutes == "23h 59m")
        #expect(TimeInterval(24 * 3600).hoursAndMinutes == "1d 00h")
        #expect(TimeInterval(6 * 86_400 + 2 * 3600).hoursAndMinutes == "6d 02h")
        #expect(TimeInterval(48 * 3600).hoursAndMinutes == "2d 00h")
    }

    @Test func aShortBlockIsNotAWait() {
        let series = [[reading(hours: 0, 0.2), reading(hours: 1, 1.0), reading(hours: 1.5, 0.0)]]
        #expect(!earned(Achievements.evaluate(series: series, observedDays: [], calendar: utc), .longestWait).isEarned)
    }

    @Test func fullHouseNeedsTwoProvidersBlockedAtTheSameTime() {
        let claude = [
            reading(hours: 0, 0.5),
            reading(hours: 2, 1.0),
            reading(hours: 8, 0.0),
        ]
        let grok = [
            reading(hours: 0, 0.5, provider: .grok, trackingID: "acct-2", limitID: "weekly"),
            reading(hours: 6, 0.9, locked: .locked, provider: .grok, trackingID: "acct-2", limitID: "weekly"),
            reading(hours: 9, 0.1, provider: .grok, trackingID: "acct-2", limitID: "weekly"),
        ]
        let house = earned(
            Achievements.evaluate(series: [claude, grok], observedDays: [], calendar: utc),
            .fullHouse
        )
        #expect(house.isEarned)
        #expect(house.earnedAt == origin.addingTimeInterval(6 * 3600))
        #expect(house.detail.hasPrefix("2 providers"))
    }

    @Test func twoBlocksThatNeverOverlapAreNoFullHouse() {
        let claude = [reading(hours: 0, 1.0), reading(hours: 2, 0.0)]
        let grok = [
            reading(hours: 5, 1.0, provider: .grok, trackingID: "acct-2", limitID: "weekly"),
            reading(hours: 7, 0.0, provider: .grok, trackingID: "acct-2", limitID: "weekly"),
        ]
        #expect(!earned(Achievements.evaluate(series: [claude, grok], observedDays: [], calendar: utc), .fullHouse).isEarned)
    }

    @Test func twoAccountsOfOneProviderAreNotAFullHouse() {
        // Same provider twice is one subscription's problem, not two.
        let first = [reading(hours: 0, 1.0), reading(hours: 4, 0.0)]
        let second = [
            reading(hours: 1, 1.0, trackingID: "acct-2"),
            reading(hours: 4, 0.0, trackingID: "acct-2"),
        ]
        #expect(!earned(Achievements.evaluate(series: [first, second], observedDays: [], calendar: utc), .fullHouse).isEarned)
    }

    @Test func speedrunIsEmptyToFullInsideTheWindow() {
        let fast = [[reading(hours: 0, 0.05), reading(hours: 3, 1.0)]]
        let slow = [[reading(hours: 0, 0.05), reading(hours: 9, 1.0)]]
        #expect(earned(Achievements.evaluate(series: fast, observedDays: [], calendar: utc), .speedrun).isEarned)
        #expect(!earned(Achievements.evaluate(series: slow, observedDays: [], calendar: utc), .speedrun).isEarned)
    }

    @Test func nightShiftNeedsUsageToRiseInTheSmallHours() {
        let night = [[reading(hours: 1.5, 0.2), reading(hours: 2.5, 0.4)]]
        let evening = [[reading(hours: 20, 0.2), reading(hours: 21, 0.4)]]
        #expect(earned(Achievements.evaluate(series: night, observedDays: [], calendar: utc), .nightOwl).isEarned)
        #expect(!earned(Achievements.evaluate(series: evening, observedDays: [], calendar: utc), .nightOwl).isEarned)
    }

    @Test func aFallingLimitAtNightIsNotNightWork() {
        // A reset at 03:00 is the provider working, not you.
        let series = [[reading(hours: 2, 1.0), reading(hours: 3, 0.0)]]
        #expect(!earned(Achievements.evaluate(series: series, observedDays: [], calendar: utc), .nightOwl).isEarned)
    }

    @Test func sevenInARowCountsDaysWithUsageAndReportsProgressWhileShort() {
        var rows = [reading(hours: 0, 0)]
        for day in 0..<7 {
            rows.append(reading(hours: Double(day) * 24 + 10, Double(day + 1) * 0.1))
        }
        let full = Achievements.evaluate(series: [rows], observedDays: [], calendar: utc)
        #expect(earned(full, .weekStreak).isEarned)
        #expect(earned(full, .weekStreak).detail == "7 days in a row.")

        let short = Achievements.evaluate(series: [Array(rows.prefix(4))], observedDays: [], calendar: utc)
        #expect(!earned(short, .weekStreak).isEarned)
        #expect(earned(short, .weekStreak).detail == "3 of 7 days so far.")
    }

    @Test func aGapBreaksTheStreak() {
        var rows = [reading(hours: 0, 0)]
        for day in [0, 1, 2, 4, 5, 6, 7, 8] {
            rows.append(reading(hours: Double(day) * 24 + 10, Double(day + 1) * 0.05))
        }
        // The longest run is 5 days (4…8), not 8.
        #expect(earned(Achievements.evaluate(series: [rows], observedDays: [], calendar: utc), .weekStreak).detail
            == "5 of 7 days so far.")
    }

    @Test func aCleanWeekOnlyCountsDaysThatWereActuallyWatched() {
        let days = Set((0..<7).map { utc.startOfDay(for: origin.addingTimeInterval(Double($0) * 86_400)) })
        let quiet = [[reading(hours: 5, 0.3), reading(hours: 100, 0.6)]]
        #expect(earned(Achievements.evaluate(series: quiet, observedDays: days, calendar: utc), .cleanWeek).isEarned)

        // Six watched days is not a week, however clean.
        let sixDays = Set(days.sorted().prefix(6))
        #expect(!earned(Achievements.evaluate(series: quiet, observedDays: sixDays, calendar: utc), .cleanWeek).isEarned)
    }

    @Test func oneBlockedDayCostsTheCleanWeek() {
        let days = Set((0..<7).map { utc.startOfDay(for: origin.addingTimeInterval(Double($0) * 86_400)) })
        let blocked = [[reading(hours: 5, 0.3), reading(hours: 72, 1.0), reading(hours: 80, 0.0)]]
        #expect(!earned(Achievements.evaluate(series: blocked, observedDays: days, calendar: utc), .cleanWeek).isEarned)
    }

    @Test func aModelLimitDoesNotBlockTheAccount() {
        // A full Fable week is not a blocked subscription — same rule as the bar.
        let days = Set((0..<7).map { utc.startOfDay(for: origin.addingTimeInterval(Double($0) * 86_400)) })
        let modelOnly = [[
            reading(hours: 5, 0.3, limitID: "weekly_opus", scope: .model),
            reading(hours: 72, 1.0, limitID: "weekly_opus", scope: .model),
            reading(hours: 80, 0.2, limitID: "weekly_opus", scope: .model),
        ]]
        #expect(earned(Achievements.evaluate(series: modelOnly, observedDays: days, calendar: utc), .cleanWeek).isEarned)
    }

    @Test func nothingIsClaimedFromAnEmptyLog() {
        let list = Achievements.evaluate(series: [], observedDays: [], calendar: utc)
        #expect(list.count == Achievements.Kind.allCases.count)
        #expect(list.allSatisfy { !$0.isEarned })
        // The rule lives on `requirement`. `detail` is the state, never a copy
        // of the rule, so the window can show both without repeating.
        #expect(list.allSatisfy { !$0.detail.isEmpty })
        #expect(list.allSatisfy { !$0.requirement.isEmpty })
        #expect(list.allSatisfy { $0.detail != $0.requirement })
        #expect(earned(list, .regular).detail == "0 of 10 so far.")
        #expect(earned(list, .firstMaxOut).detail == "Not yet.")
        #expect(earned(list, .patience).detail == "0m waiting in all.")
    }

    @Test func currentWaitsAreOnlyTheLimitsStillFullLongestFirst() {
        let waiting = [reading(hours: 0, 0.5), reading(hours: 2, 1.0)]
        let alsoWaiting = [
            reading(hours: 0, 0.5, trackingID: "acct-2", label: "Session"),
            reading(hours: 1, 1.0, trackingID: "acct-2", label: "Session"),
        ]
        let free = [reading(hours: 0, 1.0), reading(hours: 3, 0.2)]
        let waits = Achievements.currentWaits(series: [waiting, alsoWaiting, free])
        #expect(waits.map(\.label) == ["Session", "Week"])
    }

    @Test func regularIsTenFullRunsAndNineIsShort() {
        let ten = earned(evaluate([maxOuts(10)]), .regular)
        #expect(ten.isEarned)
        #expect(ten.detail.hasPrefix("10 full limits."))

        let nine = earned(evaluate([maxOuts(9)]), .regular)
        #expect(!nine.isEarned)
        #expect(nine.detail == "9 of 10 so far.")
    }

    @Test func centuryIsAHundredFullRunsAndNinetyNineIsShort() {
        let hundred = earned(evaluate([maxOuts(100)]), .century)
        #expect(hundred.isEarned)
        #expect(hundred.detail.hasPrefix("100 full limits."))

        let ninetyNine = earned(evaluate([maxOuts(99)]), .century)
        #expect(!ninetyNine.isEarned)
        #expect(ninetyNine.detail == "99 of 100 so far.")
    }

    @Test func doubleNeedsTwoDifferentLimitsOnTheSameDay() {
        let week = [reading(hours: 2, 0.5), reading(hours: 3, 1.0)]
        let session = [
            reading(hours: 4, 0.5, limitID: "session", label: "Session"),
            reading(hours: 5, 1.0, limitID: "session", label: "Session"),
        ]
        let hit = earned(evaluate([week, session]), .double)
        #expect(hit.isEarned)
        #expect(hit.detail.hasPrefix("2 different limits full"))
        #expect(hit.earnedAt == origin.addingTimeInterval(5 * 3600))
    }

    @Test func aShadowingModelLimitDoesNotCountTwice() {
        // Fable is full because the account week is full. That is one event.
        let week = [
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 1 + 4 * 24, 0.0),
        ]
        let fable = [
            reading(hours: 0, 0.2, limitID: "weekly_scoped", label: "Fable", scope: .model),
            reading(hours: 1, 1.0, limitID: "weekly_scoped", label: "Fable", scope: .model),
            reading(hours: 1 + 4 * 24, 0.0, limitID: "weekly_scoped", label: "Fable", scope: .model),
        ]
        let list = evaluate([week, fable])
        #expect(earned(list, .firstMaxOut).isEarned)
        #expect(earned(list, .regular).detail == "1 of 10 so far.")
        #expect(earned(list, .double).detail == "1 of 2 so far.")
        #expect(!earned(list, .patience).isEarned)
        #expect(earned(list, .longestWait).detail == "4d 00h waiting on Week.")
    }

    @Test func aModelLimitDoesNotPadEverythingAtOnce() {
        let four = (0..<4).map { index in
            [
                reading(hours: 0, 0.5, trackingID: "acct-\(index)", limitID: "L\(index)", label: "L\(index)"),
                reading(hours: 2, 1.0, trackingID: "acct-\(index)", limitID: "L\(index)", label: "L\(index)"),
                reading(hours: 6, 0.0, trackingID: "acct-\(index)", limitID: "L\(index)", label: "L\(index)"),
            ]
        }
        let model = [
            reading(hours: 0, 0.5, trackingID: "acct-0", limitID: "weekly_opus", label: "Fable", scope: .model),
            reading(hours: 2, 1.0, trackingID: "acct-0", limitID: "weekly_opus", label: "Fable", scope: .model),
            reading(hours: 6, 0.0, trackingID: "acct-0", limitID: "weekly_opus", label: "Fable", scope: .model),
        ]
        #expect(earned(evaluate(four + [model]), .everythingAtOnce).detail == "4 of 5 so far.")
    }

    @Test func twoRunsOfTheSameLimitAreNotADouble() {
        let same = [
            reading(hours: 1, 0.5),
            reading(hours: 2, 1.0),
            reading(hours: 3, 0.0),
            reading(hours: 4, 1.0),
        ]
        let miss = earned(evaluate([same]), .double)
        #expect(!miss.isEarned)
        #expect(miss.detail == "1 of 2 so far.")
    }

    @Test func hatTrickNeedsThreeAccountsOnTheSameDay() {
        let one = [reading(hours: 2, 0.5), reading(hours: 3, 1.0)]
        let two = [
            reading(hours: 4, 0.5, trackingID: "acct-2"),
            reading(hours: 5, 1.0, trackingID: "acct-2"),
        ]
        let three = [
            reading(hours: 6, 0.5, trackingID: "acct-3"),
            reading(hours: 7, 1.0, trackingID: "acct-3"),
        ]
        let hit = earned(evaluate([one, two, three]), .hatTrick)
        #expect(hit.isEarned)
        #expect(hit.detail.hasPrefix("3 accounts full"))
        #expect(hit.earnedAt == origin.addingTimeInterval(7 * 3600))
    }

    @Test func aModelLimitDoesNotMakeTheThirdAccountForAHatTrick() {
        let one = [reading(hours: 2, 0.5), reading(hours: 3, 1.0)]
        let two = [
            reading(hours: 4, 0.5, trackingID: "acct-2"),
            reading(hours: 5, 1.0, trackingID: "acct-2"),
        ]
        let model = [
            reading(hours: 6, 0.5, trackingID: "acct-3", limitID: "weekly_opus", scope: .model),
            reading(hours: 7, 1.0, trackingID: "acct-3", limitID: "weekly_opus", scope: .model),
        ]
        let miss = earned(evaluate([one, two, model]), .hatTrick)
        #expect(!miss.isEarned)
        #expect(miss.detail == "2 of 3 so far.")
    }

    @Test func grandSlamNeedsAllThreeProvidersBlockedTogether() {
        let claude = [reading(hours: 0, 0.5), reading(hours: 2, 1.0), reading(hours: 10, 0.0)]
        let grok = [
            reading(hours: 0, 0.5, provider: .grok, trackingID: "acct-g", limitID: "weekly"),
            reading(hours: 3, 1.0, provider: .grok, trackingID: "acct-g", limitID: "weekly"),
            reading(hours: 10, 0.0, provider: .grok, trackingID: "acct-g", limitID: "weekly"),
        ]
        let gpt = [
            reading(hours: 0, 0.5, provider: .chatGPT, trackingID: "acct-c", limitID: "weekly"),
            reading(hours: 4, 1.0, provider: .chatGPT, trackingID: "acct-c", limitID: "weekly"),
            reading(hours: 10, 0.0, provider: .chatGPT, trackingID: "acct-c", limitID: "weekly"),
        ]
        let slam = earned(evaluate([claude, grok, gpt]), .grandSlam)
        #expect(slam.isEarned)
        #expect(slam.earnedAt == origin.addingTimeInterval(4 * 3600))
        #expect(slam.detail.hasPrefix("All three providers"))
    }

    @Test func twoProvidersAreNotAGrandSlam() {
        let claude = [reading(hours: 0, 0.5), reading(hours: 2, 1.0), reading(hours: 8, 0.0)]
        let grok = [
            reading(hours: 0, 0.5, provider: .grok, trackingID: "acct-2", limitID: "weekly"),
            reading(hours: 6, 1.0, provider: .grok, trackingID: "acct-2", limitID: "weekly"),
            reading(hours: 9, 0.0, provider: .grok, trackingID: "acct-2", limitID: "weekly"),
        ]
        let miss = earned(evaluate([claude, grok]), .grandSlam)
        #expect(!miss.isEarned)
        #expect(miss.detail == "2 of 3 so far.")
    }

    @Test func everythingAtOnceNeedsFiveLimitsFullTogether() {
        let five = (0..<5).map { index in
            [
                reading(hours: 0, 0.5, trackingID: "acct-\(index)", limitID: "L\(index)", label: "L\(index)"),
                reading(hours: 2, 1.0, trackingID: "acct-\(index)", limitID: "L\(index)", label: "L\(index)"),
                reading(hours: 6, 0.0, trackingID: "acct-\(index)", limitID: "L\(index)", label: "L\(index)"),
            ]
        }
        let hit = earned(evaluate(five), .everythingAtOnce)
        #expect(hit.isEarned)
        #expect(hit.detail.hasPrefix("5 limits full at once"))
        #expect(hit.earnedAt == origin.addingTimeInterval(2 * 3600))
    }

    @Test func fourLimitsTogetherAreNotEverythingAtOnce() {
        let four = (0..<4).map { index in
            [
                reading(hours: 0, 0.5, trackingID: "acct-\(index)", limitID: "L\(index)", label: "L\(index)"),
                reading(hours: 2, 1.0, trackingID: "acct-\(index)", limitID: "L\(index)", label: "L\(index)"),
                reading(hours: 6, 0.0, trackingID: "acct-\(index)", limitID: "L\(index)", label: "L\(index)"),
            ]
        }
        let miss = earned(evaluate(four), .everythingAtOnce)
        #expect(!miss.isEarned)
        #expect(miss.detail == "4 of 5 so far.")
    }

    @Test func splitPersonalityIsTwoAccountsOfOneProviderAtOnce() {
        let first = [reading(hours: 0, 1.0), reading(hours: 4, 0.0)]
        let second = [
            reading(hours: 1, 1.0, trackingID: "acct-2"),
            reading(hours: 4, 0.0, trackingID: "acct-2"),
        ]
        let hit = earned(evaluate([first, second]), .splitPersonality)
        #expect(hit.isEarned)
        #expect(hit.earnedAt == origin.addingTimeInterval(3600))
        #expect(hit.detail.hasPrefix("Two accounts of one provider"))
    }

    @Test func twoLimitsOnTheSameAccountAreNotSplitPersonality() {
        let session = [
            reading(hours: 0, 0.5, limitID: "session", label: "Session"),
            reading(hours: 1, 1.0, limitID: "session", label: "Session"),
            reading(hours: 4, 0.0, limitID: "session", label: "Session"),
        ]
        let week = [
            reading(hours: 0, 0.5),
            reading(hours: 2, 1.0),
            reading(hours: 4, 0.0),
        ]
        #expect(!earned(evaluate([session, week]), .splitPersonality).isEarned)
    }

    @Test func longHaulIsSixHoursWaitingAndJustUnderIsShort() {
        let six = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 7, 0.0),
        ]]
        #expect(earned(evaluate(six), .longHaul).isEarned)
        #expect(earned(evaluate(six), .longHaul).detail == "6h 00m waiting on Week.")

        let shy = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 6 + 59.0 / 60.0, 0.0),
        ]]
        #expect(!earned(evaluate(shy), .longHaul).isEarned)
    }

    @Test func overnightIsTwelveHoursWaitingAndElevenIsShort() {
        let twelve = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 13, 0.0),
        ]]
        #expect(earned(evaluate(twelve), .overnight).isEarned)
        #expect(earned(evaluate(twelve), .overnight).detail == "12h 00m waiting on Week.")

        let eleven = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 12, 0.0),
        ]]
        #expect(!earned(evaluate(eleven), .overnight).isEarned)
    }

    @Test func lostWeekendIsFortyEightHoursWaitingAndFortySevenIsShort() {
        let fortyEight = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 49, 0.0),
        ]]
        #expect(earned(evaluate(fortyEight), .lostWeekend).isEarned)
        #expect(earned(evaluate(fortyEight), .lostWeekend).detail == "2d 00h waiting on Week.")

        let fortySeven = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 48, 0.0),
        ]]
        #expect(!earned(evaluate(fortySeven), .lostWeekend).isEarned)
        #expect(earned(evaluate(fortySeven), .lostWeekend).detail == "1d 23h waiting on Week.")
    }

    @Test func patienceSumsFinishedWaitsToSevenDays() {
        let seven = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 1 + 7 * 24, 0.0),
        ]]
        let hit = earned(evaluate(seven), .patience)
        #expect(hit.isEarned)
        #expect(hit.detail == "7d 00h waiting in all.")

        let shy = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 1 + 6 * 24 + 23, 0.0),
        ]]
        #expect(!earned(evaluate(shy), .patience).isEarned)
        #expect(earned(evaluate(shy), .patience).detail == "6d 23h waiting in all.")
    }

    @Test func sprintIsEmptyToFullInsideAnHour() {
        let fast = [[reading(hours: 0, 0.05), reading(hours: 0.75, 1.0)]]
        let hit = earned(evaluate(fast), .sprint)
        #expect(hit.isEarned)
        #expect(hit.detail == "Empty to full in 45m on Week.")

        let slow = [[reading(hours: 0, 0.05), reading(hours: 1.1, 1.0)]]
        #expect(!earned(evaluate(slow), .sprint).isEarned)
        // Still a speedrun — just not a sprint.
        #expect(earned(evaluate(slow), .speedrun).isEarned)
    }

    @Test func fromZeroNeedsAStoredZeroAndAFullOnTheSameDay() {
        let sameDay = [[reading(hours: 1, 0), reading(hours: 8, 1.0)]]
        let hit = earned(evaluate(sameDay), .fromZero)
        #expect(hit.isEarned)
        #expect(hit.detail.hasPrefix("0 % to full on Week"))

        let nextDay = [[reading(hours: 23, 0), reading(hours: 25, 1.0)]]
        #expect(!earned(evaluate(nextDay), .fromZero).isEarned)

        let notZero = [[reading(hours: 1, 0.01), reading(hours: 8, 1.0)]]
        #expect(!earned(evaluate(notZero), .fromZero).isEarned)
    }

    @Test func slowBurnIsSixDaysOnAWeeklyLimit() {
        let weekly = [[
            reading(hours: 0, 0.1, resetHours: 7 * 24),
            reading(hours: 6 * 24, 1.0, resetHours: 24),
        ]]
        let hit = earned(evaluate(weekly), .slowBurn)
        #expect(hit.isEarned)
        #expect(hit.detail == "Filled Week in 6d 00h.")

        let shy = [[
            reading(hours: 0, 0.1, resetHours: 7 * 24),
            reading(hours: 5 * 24 + 23, 1.0, resetHours: 25),
        ]]
        #expect(!earned(evaluate(shy), .slowBurn).isEarned)
    }

    @Test func aSessionLimitIsNotASlowBurnEvenIfItTakesDays() {
        let session = [[
            reading(hours: 0, 0.1, limitID: "session", label: "Session", resetHours: 5),
            reading(hours: 6 * 24, 1.0, limitID: "session", label: "Session", resetHours: 5),
        ]]
        #expect(!earned(evaluate(session), .slowBurn).isEarned)
    }

    @Test func theWindowCanGroupEveryKindBySection() {
        #expect(Achievements.Kind.firstMaxOut.section == .heavyUse)
        #expect(Achievements.Kind.century.section == .heavyUse)
        #expect(Achievements.Kind.hatTrick.section == .heavyUse)
        #expect(Achievements.Kind.grandSlam.section == .simultaneous)
        #expect(Achievements.Kind.splitPersonality.section == .simultaneous)
        #expect(Achievements.Kind.patience.section == .waiting)
        #expect(Achievements.Kind.slowBurn.section == .pace)
        #expect(Achievements.Kind.nightOwl.section == .clock)
        #expect(Achievements.Kind.dawnPatrol.section == .clock)
        #expect(Achievements.Kind.roundTheClock.section == .clock)
        #expect(Achievements.Kind.cleanWeek.section == .stamina)
        #expect(Achievements.Kind.marathonWeek.section == .stamina)
        #expect(Achievements.Kind.twoHorses.section == .collection)
        #expect(Achievements.Kind.bounce.section == .husbandry)
        #expect(Achievements.Kind.theAnswer.section == .log)
        #expect(Achievements.Kind.allCases.contains(.theAnswer))
    }

    @Test func dawnPatrolNeedsARiseBetweenFiveAndSeven() {
        let dawn = [[reading(hours: 5.2, 0.2), reading(hours: 5.8, 0.4)]]
        #expect(earned(evaluate(dawn), .dawnPatrol).isEarned)

        let sitting = [[reading(hours: 5.5, 0.3), reading(hours: 6.5, 0.3)]]
        #expect(!earned(evaluate(sitting), .dawnPatrol).isEarned)

        let night = [[reading(hours: 1.5, 0.2), reading(hours: 2.5, 0.4)]]
        #expect(!earned(evaluate(night), .dawnPatrol).isEarned)
        #expect(earned(evaluate(night), .nightOwl).isEarned)
    }

    @Test func weekendWarriorNeedsSaturdayAndTheSundayAfter() {
        let both = [[
            reading(hours: 26, 0.5),
            reading(hours: 28, 1.0),
            reading(hours: 52, 1.0),
            reading(hours: 55, 0.0),
        ]]
        #expect(earned(evaluate(both), .weekendWarrior).isEarned)

        let saturdayOnly = [[
            reading(hours: 26, 0.5),
            reading(hours: 28, 1.0),
            reading(hours: 30, 0.0),
        ]]
        #expect(!earned(evaluate(saturdayOnly), .weekendWarrior).isEarned)
    }

    @Test func mondayMorningIsARiseToFullBeforeTen() {
        let hit = [[reading(hours: 80, 0.5), reading(hours: 81, 1.0)]]
        #expect(earned(evaluate(hit), .mondayMorning).isEarned)

        let leftover = [[reading(hours: 70, 1.0), reading(hours: 81, 1.0)]]
        #expect(!earned(evaluate(leftover), .mondayMorning).isEarned)

        let tooLate = [[reading(hours: 82, 0.5), reading(hours: 83, 1.0)]]
        #expect(!earned(evaluate(tooLate), .mondayMorning).isEarned)
    }

    @Test func fridayFinisherIsARiseToFullAfterEighteen() {
        let hit = [[reading(hours: 17, 0.5), reading(hours: 19, 1.0)]]
        #expect(earned(evaluate(hit), .fridayFinisher).isEarned)

        let tooEarly = [[reading(hours: 17, 0.5), reading(hours: 17.5, 1.0)]]
        #expect(!earned(evaluate(tooEarly), .fridayFinisher).isEarned)
    }

    @Test func aModelLimitDoesNotCountAsMondayMorning() {
        let model = [[
            reading(hours: 80, 0.5, limitID: "weekly_opus", scope: .model),
            reading(hours: 81, 1.0, limitID: "weekly_opus", scope: .model),
        ]]
        #expect(!earned(evaluate(model), .mondayMorning).isEarned)
    }

    @Test func roundTheClockNeedsARiseInEveryQuarter() {
        let all = [[
            reading(hours: 1, 0.1), reading(hours: 2, 0.2),
            reading(hours: 7, 0.3), reading(hours: 8, 0.4),
            reading(hours: 13, 0.5), reading(hours: 14, 0.6),
            reading(hours: 19, 0.7), reading(hours: 20, 0.8),
        ]]
        #expect(earned(evaluate(all), .roundTheClock).isEarned)

        let three = [[
            reading(hours: 1, 0.1), reading(hours: 2, 0.2),
            reading(hours: 7, 0.3), reading(hours: 8, 0.4),
            reading(hours: 13, 0.5), reading(hours: 14, 0.6),
        ]]
        let miss = earned(evaluate(three), .roundTheClock)
        #expect(!miss.isEarned)
        #expect(miss.detail == "3 of 4 quarters so far.")
    }

    @Test func thirtyInARowAndAGapOfTwentyNine() {
        var rows = [reading(hours: 0, 0)]
        for day in 0..<30 {
            rows.append(reading(hours: Double(day) * 24 + 10, Double(day + 1) * 0.01))
        }
        #expect(earned(evaluate([rows]), .thirtyInARow).isEarned)

        let short = Achievements.evaluate(series: [Array(rows.prefix(30))], observedDays: [], calendar: utc)
        // prefix(30) is the zero plus 29 rises
        #expect(!earned(short, .thirtyInARow).isEarned)
        #expect(earned(short, .thirtyInARow).detail == "29 of 30 days so far.")
    }

    @Test func hundredInARowAndNinetyNineIsShort() {
        var rows = [reading(hours: 0, 0)]
        for day in 0..<100 {
            rows.append(reading(hours: Double(day) * 24 + 10, 0.01 + Double(day) * 0.001))
        }
        #expect(earned(evaluate([rows]), .hundredInARow).isEarned)

        let short = Achievements.evaluate(series: [Array(rows.prefix(100))], observedDays: [], calendar: utc)
        #expect(!earned(short, .hundredInARow).isEarned)
        #expect(earned(short, .hundredInARow).detail == "99 of 100 days so far.")
    }

    @Test func cleanMonthNeedsThirtyWatchedDays() {
        let quiet = [[reading(hours: 5, 0.3), reading(hours: 29 * 24, 0.4)]]
        #expect(earned(evaluate(quiet, days: days(30)), .cleanMonth).isEarned)
        #expect(!earned(evaluate(quiet, days: days(29)), .cleanMonth).isEarned)
    }

    @Test func comebackIsACleanWeekAfterThreeFullLimits() {
        let one = [reading(hours: 2, 0.5), reading(hours: 3, 1.0), reading(hours: 4, 0.0)]
        let two = [
            reading(hours: 10, 0.5, limitID: "session", label: "Session"),
            reading(hours: 11, 1.0, limitID: "session", label: "Session"),
            reading(hours: 12, 0.0, limitID: "session", label: "Session"),
        ]
        let three = [
            reading(hours: 20, 0.5, trackingID: "acct-2"),
            reading(hours: 21, 1.0, trackingID: "acct-2"),
            reading(hours: 22, 0.0, trackingID: "acct-2"),
        ]
        let later = [reading(hours: 8 * 24, 0.2), reading(hours: 13 * 24, 0.3)]
        let watched = days(14)
        #expect(earned(evaluate([one, two, three, later], days: watched), .comeback).isEarned)

        #expect(!earned(evaluate([one, two, later], days: watched), .comeback).isEarned)
    }

    @Test func marathonWeekCoversAFlatStretchOnWatchedDays() {
        let high = [[
            reading(hours: 0, 0.91),
            reading(hours: 6 * 24, 0.91),
            reading(hours: 6 * 24 + 1, 0.5),
        ]]
        #expect(earned(evaluate(high, days: days(7)), .marathonWeek).isEarned)
        #expect(!earned(evaluate(high, days: days(6)), .marathonWeek).isEarned)

        let shy = [[
            reading(hours: 0, 0.89),
            reading(hours: 6 * 24, 0.89),
        ]]
        #expect(!earned(evaluate(shy, days: days(7)), .marathonWeek).isEarned)
    }

    @Test func twoHorsesNeedOverlappingProviders() {
        let claude = [reading(hours: 0, 0.2), reading(hours: 10, 0.3)]
        let grok = [
            reading(hours: 2, 0.2, provider: .grok, trackingID: "acct-g", limitID: "weekly"),
            reading(hours: 8, 0.3, provider: .grok, trackingID: "acct-g", limitID: "weekly"),
        ]
        #expect(earned(evaluate([claude, grok]), .twoHorses).isEarned)

        let later = [
            reading(hours: 20, 0.2, provider: .grok, trackingID: "acct-g", limitID: "weekly"),
            reading(hours: 22, 0.3, provider: .grok, trackingID: "acct-g", limitID: "weekly"),
        ]
        #expect(!earned(evaluate([claude, later]), .twoHorses).isEarned)
    }

    @Test func fullStableNeedsAllThreeProvidersTogether() {
        let claude = [reading(hours: 0, 0.2), reading(hours: 10, 0.3)]
        let grok = [
            reading(hours: 1, 0.2, provider: .grok, trackingID: "acct-g", limitID: "weekly"),
            reading(hours: 9, 0.3, provider: .grok, trackingID: "acct-g", limitID: "weekly"),
        ]
        let gpt = [
            reading(hours: 2, 0.2, provider: .chatGPT, trackingID: "acct-c", limitID: "weekly"),
            reading(hours: 8, 0.3, provider: .chatGPT, trackingID: "acct-c", limitID: "weekly"),
        ]
        #expect(earned(evaluate([claude, grok, gpt]), .fullStable).isEarned)
        #expect(!earned(evaluate([claude, grok]), .fullStable).isEarned)
    }

    @Test func twinsAreTwoAccountsOfOneProvider() {
        let first = [reading(hours: 0, 0.2), reading(hours: 10, 0.3)]
        let second = [
            reading(hours: 2, 0.2, trackingID: "acct-2"),
            reading(hours: 8, 0.3, trackingID: "acct-2"),
        ]
        #expect(earned(evaluate([first, second]), .twins).isEarned)

        let sameAccount = [
            reading(hours: 2, 0.2, limitID: "session", label: "Session"),
            reading(hours: 8, 0.3, limitID: "session", label: "Session"),
        ]
        #expect(!earned(evaluate([first, sameAccount]), .twins).isEarned)
    }

    @Test func fiveASideNeedsFiveAccountsTogether() {
        let five = (0..<5).map { index in
            [
                reading(hours: 0, 0.2, trackingID: "acct-\(index)", limitID: "L\(index)"),
                reading(hours: 8, 0.3, trackingID: "acct-\(index)", limitID: "L\(index)"),
            ]
        }
        #expect(earned(evaluate(five), .fiveASide).isEarned)
        #expect(earned(evaluate(Array(five.prefix(4))), .fiveASide).detail == "4 of 5 so far.")
    }

    @Test func cooldownIsADayUnderTenAfterAFull() {
        let hit = [[
            reading(hours: 0, 0.5),
            reading(hours: 1, 1.0),
            reading(hours: 2, 0.05),
            reading(hours: 26, 0.05),
        ]]
        #expect(earned(evaluate(hit), .cooldown).isEarned)

        let bounced = [[
            reading(hours: 0, 0.5),
            reading(hours: 1, 1.0),
            reading(hours: 2, 0.05),
            reading(hours: 25, 1.0),
        ]]
        #expect(!earned(evaluate(bounced), .cooldown).isEarned)

        let shy = [[
            reading(hours: 0, 0.5),
            reading(hours: 1, 1.0),
            reading(hours: 2, 0.05),
            reading(hours: 25, 0.05),
        ]]
        #expect(!earned(evaluate(shy), .cooldown).isEarned)
    }

    @Test func rationingHoldsAWeeklyLimitUnderFiftyForAWeek() {
        let quiet = [[
            reading(hours: 0, 0.3, resetHours: 7 * 24),
            reading(hours: 6 * 24, 0.4, resetHours: 24),
        ]]
        #expect(earned(evaluate(quiet, days: days(7)), .rationing).isEarned)

        let over = [[
            reading(hours: 0, 0.3, resetHours: 7 * 24),
            reading(hours: 6 * 24, 0.51, resetHours: 24),
        ]]
        #expect(!earned(evaluate(over, days: days(7)), .rationing).isEarned)
        #expect(!earned(evaluate(quiet, days: days(6)), .rationing).isEarned)
    }

    @Test func downToTheWireHitsNinetyNineAndTheWeekEnds() {
        let hit = [[
            reading(hours: 0, 0.5, resetHours: 7 * 24),
            reading(hours: 5 * 24, 0.99, resetHours: 2 * 24),
            reading(hours: 7 * 24, 0.05, resetHours: 7 * 24),
        ]]
        #expect(earned(evaluate(hit), .downToTheWire).isEarned)

        let full = [[
            reading(hours: 0, 0.5, resetHours: 7 * 24),
            reading(hours: 5 * 24, 1.0, resetHours: 2 * 24),
            reading(hours: 7 * 24, 0.05, resetHours: 7 * 24),
        ]]
        #expect(!earned(evaluate(full), .downToTheWire).isEarned)

        let shy = [[
            reading(hours: 0, 0.5, resetHours: 7 * 24),
            reading(hours: 5 * 24, 0.98, resetHours: 2 * 24),
            reading(hours: 7 * 24, 0.05, resetHours: 7 * 24),
        ]]
        #expect(!earned(evaluate(shy), .downToTheWire).isEarned)
    }

    @Test func bounceIsFullThenUnderTenInsideAnHour() {
        let hit = [[reading(hours: 0, 0.5), reading(hours: 1, 1.0), reading(hours: 1.5, 0.05)]]
        #expect(earned(evaluate(hit), .bounce).isEarned)
        #expect(earned(evaluate(hit), .bounce).detail == "Full to under 10 % in 30m on Week.")

        let slow = [[reading(hours: 0, 0.5), reading(hours: 1, 1.0), reading(hours: 2 + 1.0 / 60.0, 0.05)]]
        #expect(!earned(evaluate(slow), .bounce).isEarned)

        let notLow = [[reading(hours: 0, 0.5), reading(hours: 1, 1.0), reading(hours: 1.5, 0.15)]]
        #expect(!earned(evaluate(notLow), .bounce).isEarned)
    }

    @Test func firstLightIsTheFirstReading() {
        let one = [[reading(hours: 3, 0.2)]]
        #expect(earned(evaluate(one), .firstLight).isEarned)
        #expect(!earned(evaluate([]), .firstLight).isEarned)
    }

    @Test func oldTimerNeedsNinetyDaysOfLog() {
        let long = [[reading(hours: 0, 0.1), reading(hours: 90 * 24, 0.2)]]
        #expect(earned(evaluate(long), .oldTimer).isEarned)

        let shy = [[reading(hours: 0, 0.1), reading(hours: 89 * 24, 0.2)]]
        #expect(!earned(evaluate(shy), .oldTimer).isEarned)
        #expect(earned(evaluate(shy), .oldTimer).detail.hasPrefix("Log stretches 89d"))
        #expect(earned(evaluate(shy), .oldTimer).detail != Achievements.Kind.oldTimer.requirement)
    }

    @Test func theAnswerTracksEveryOtherKind() {
        let empty = evaluate([])
        let needed = Achievements.Kind.allCases.count - 1
        #expect(!earned(empty, .theAnswer).isEarned)
        #expect(earned(empty, .theAnswer).detail == "0 of \(needed) so far.")

        let one = evaluate([[reading(hours: 0, 0.1)]])
        #expect(earned(one, .firstLight).isEarned)
        #expect(earned(one, .theAnswer).detail == "1 of \(needed) so far.")
        #expect(!earned(one, .theAnswer).isEarned)
    }

    @Test func twoFullLimitsOnOneAccountAreTwoWaitsWithDistinctIDs() {
        let session = [
            reading(hours: 0, 0.5, limitID: "session", label: "5 hours"),
            reading(hours: 1, 1.0, limitID: "session", label: "5 hours"),
        ]
        let week = [
            reading(hours: 0, 0.5, limitID: "weekly_all", label: "Week"),
            reading(hours: 2, 1.0, limitID: "weekly_all", label: "Week"),
        ]
        let waits = Achievements.currentWaits(series: [session, week])
        #expect(waits.count == 2)
        #expect(Set(waits.map(\.id)).count == 2)
        #expect(waits.allSatisfy { $0.trackingID == "acct-1" })
        #expect(Set(waits.map(\.limitID)) == ["session", "weekly_all"])
    }
}

@Suite("Achievements over the log")
struct AchievementsOverLogTests {

    @Test func changePointsCollapseTheFlatStretchesAndKeepTheEnds() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("achievements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try UsageLog(url: directory.appendingPathComponent("usage-log.sqlite"))

        // Twelve identical readings, then a rise, then twelve identical again.
        var rows: [UsageMeasurement] = []
        for tick in 0..<12 { rows.append(reading(hours: Double(tick) / 12, 0.5)) }
        for tick in 12..<24 { rows.append(reading(hours: Double(tick) / 12, 1.0)) }
        try log.append(rows)

        let points = try log.changePoints(trackingID: "acct-1", limitID: "weekly_all")
        // First row, the row where it changed, and the last row. Nothing in between.
        #expect(points.count == 3)
        #expect(points.map(\.utilization) == [0.5, 1.0, 1.0])

        // And the rules see the same run they would see in the full series.
        #expect(Achievements.fullRuns(points) == Achievements.fullRuns(rows))
    }

    @Test func aWaitIsTheSameLengthWhetherReadFromEveryRowOrFromTheChangePoints() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("achievements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try UsageLog(url: directory.appendingPathComponent("usage-log.sqlite"))

        // Full for five hours with nothing changing in between, then free again.
        var rows: [UsageMeasurement] = []
        for tick in 0..<12 { rows.append(reading(hours: Double(tick) / 12, 0.5)) }
        for tick in 12..<72 { rows.append(reading(hours: Double(tick) / 12, 1.0)) }
        rows.append(reading(hours: 6, 0.0))
        try log.append(rows)

        let points = try log.changePoints(trackingID: "acct-1", limitID: "weekly_all")
        #expect(points.count == 3)
        // The flat middle is not stored, so a rule that measured to the last *stored*
        // full row would report zero here. Both readings must agree.
        #expect(Achievements.fullRuns(points).first?.completedDuration
            == Achievements.fullRuns(rows).first?.completedDuration)
        #expect(Achievements.fullRuns(points).first?.completedDuration == 18_000)
    }

    @Test func observedDaysComeFromTheLogNotFromGuesswork() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("achievements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try UsageLog(url: directory.appendingPathComponent("usage-log.sqlite"))

        try log.append([
            reading(hours: 1, 0.1),
            reading(hours: 5, 0.2),     // same day
            reading(hours: 30, 0.3),    // next day
            reading(hours: 100, 0.4),   // and a later one, with a day missing
        ])
        #expect(try log.observedDays(calendar: utc).count == 3)
    }
}
