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

private func evaluate(_ series: [[UsageMeasurement]]) -> [Achievements.Achievement] {
    Achievements.evaluate(series: series, observedDays: [], calendar: utc)
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
        // A locked badge says what it takes instead of showing a blank.
        #expect(list.allSatisfy { !$0.detail.isEmpty })
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
        #expect(slam.detail.hasPrefix("3 providers"))
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
        #expect(earned(evaluate(fortyEight), .lostWeekend).detail == "48h 00m waiting on Week.")

        let fortySeven = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 48, 0.0),
        ]]
        #expect(!earned(evaluate(fortySeven), .lostWeekend).isEarned)
    }

    @Test func patienceSumsFinishedWaitsToSevenDays() {
        let seven = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 1 + 7 * 24, 0.0),
        ]]
        let hit = earned(evaluate(seven), .patience)
        #expect(hit.isEarned)
        #expect(hit.detail == "168h 00m waiting in all.")

        let shy = [[
            reading(hours: 0, 0.2),
            reading(hours: 1, 1.0),
            reading(hours: 1 + 6 * 24 + 23, 0.0),
        ]]
        #expect(!earned(evaluate(shy), .patience).isEarned)
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
        #expect(hit.detail == "Filled Week in 144h 00m.")

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
        #expect(Achievements.Kind.cleanWeek.section == .stamina)
        #expect(Set(Achievements.Kind.allCases.map(\.section)).isDisjoint(with: [
            Achievements.Section.collection,
            .husbandry,
            .log,
        ]))
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
