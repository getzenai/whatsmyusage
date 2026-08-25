import Foundation

/// One stretch during which a limit was full, as far as the log saw it.
public struct FullRun: Equatable, Sendable {
    public let provider: Provider
    public let trackingID: String
    public let limitID: String
    public let label: String
    public let scope: LimitScope
    /// Nil when the log's first reading of this series was already full: the app was
    /// started mid-block and cannot know when the block began. `firstSeenFull` still
    /// holds — it is a lower bound, which is all we may claim.
    public let start: Date?
    /// First reading that showed this run full.
    public let firstSeenFull: Date
    /// First reading that was no longer full. Nil while the run is still going.
    public let end: Date?
    /// Last reading that was still full.
    public let lastSeenFull: Date

    /// Only for runs with both ends measured. A run of unknown start has no duration,
    /// and one that is still going is not finished — neither may be called a record.
    ///
    /// Measured from the reading that first saw it full to the reading that first saw
    /// it free, so it overstates by at most one refresh interval — the reset happened
    /// somewhere in that last gap. Measuring to `lastSeenFull` instead would understate
    /// by the same amount, and would collapse to zero on change points, where the
    /// identical readings in between are not stored.
    public var completedDuration: TimeInterval? {
        guard let start, let end else { return nil }
        return end.timeIntervalSince(start)
    }
}

/// Turns the raw log into things worth telling the user.
///
/// Everything is derived on read. Nothing about an achievement is stored, so a rule
/// that turns out wrong is a code change, not a lost badge or a wrong one baked in.
public enum Achievements {

    // MARK: - Full runs

    /// `series` must be one limit's readings in time order. Feeding it the change
    /// points (`UsageLog.changePoints`) instead of every row gives the same runs:
    /// a run can only begin or end where the reading changed.
    public static func fullRuns(_ series: [UsageMeasurement], threshold: Double = 1.0) -> [FullRun] {
        var runs: [FullRun] = []
        var start: Date?
        var startedAtFirstReading = false
        var lastFull: Date?

        for (index, row) in series.enumerated() {
            if UsageHistory.isFull(row, threshold: threshold) {
                if start == nil {
                    start = row.observedAt
                    startedAtFirstReading = index == 0
                }
                lastFull = row.observedAt
            } else if let began = start, let lastSeenFull = lastFull {
                runs.append(
                    run(from: series[index - 1], start: startedAtFirstReading ? nil : began,
                        firstSeenFull: began, end: row.observedAt, lastSeenFull: lastSeenFull)
                )
                start = nil
                lastFull = nil
            }
        }
        if let began = start, let lastSeenFull = lastFull, let last = series.last {
            runs.append(
                run(from: last, start: startedAtFirstReading ? nil : began,
                    firstSeenFull: began, end: nil, lastSeenFull: lastSeenFull)
            )
        }
        return runs
    }

    private static func run(
        from row: UsageMeasurement,
        start: Date?,
        firstSeenFull: Date,
        end: Date?,
        lastSeenFull: Date
    ) -> FullRun {
        FullRun(
            provider: row.provider,
            trackingID: row.trackingID,
            limitID: row.limitID,
            label: row.label,
            scope: row.scope,
            start: start,
            firstSeenFull: firstSeenFull,
            end: end,
            lastSeenFull: lastSeenFull
        )
    }

    // MARK: - Achievements

    public enum Section: String, CaseIterable, Sendable {
        case heavyUse = "Heavy use"
        case simultaneous = "At once"
        case waiting = "Waiting"
        case pace = "Pace"
        case clock = "Time of day"
        case stamina = "Stamina"
        case collection = "Collection"
        case husbandry = "Husbandry"
        case log = "The log"
    }

    public enum Kind: String, CaseIterable, Sendable {
        case firstMaxOut
        case regular
        case century
        case double
        case hatTrick
        case fullHouse
        case grandSlam
        case everythingAtOnce
        case splitPersonality
        case longestWait
        case longHaul
        case overnight
        case lostWeekend
        case patience
        case speedrun
        case sprint
        case fromZero
        case slowBurn
        case nightOwl
        case dawnPatrol
        case weekendWarrior
        case mondayMorning
        case fridayFinisher
        case roundTheClock
        case weekStreak
        case thirtyInARow
        case hundredInARow
        case cleanWeek
        case cleanMonth
        case comeback
        case marathonWeek
        case twoHorses
        case fullStable
        case twins
        case fiveASide
        case cooldown
        case rationing
        case downToTheWire
        case bounce
        case firstLight
        case oldTimer
        case theAnswer

        public var title: String {
            switch self {
            case .firstMaxOut: "Maxed out"
            case .regular: "Regular"
            case .century: "Century"
            case .double: "Double"
            case .hatTrick: "Hat trick"
            case .fullHouse: "Full house"
            case .grandSlam: "Grand slam"
            case .everythingAtOnce: "Everything at once"
            case .splitPersonality: "Split personality"
            case .longestWait: "The wait"
            case .longHaul: "Long haul"
            case .overnight: "Overnight"
            case .lostWeekend: "Lost weekend"
            case .patience: "Patience"
            case .speedrun: "Speedrun"
            case .sprint: "Sprint"
            case .fromZero: "From zero"
            case .slowBurn: "Slow burn"
            case .nightOwl: "Night shift"
            case .dawnPatrol: "Dawn patrol"
            case .weekendWarrior: "Weekend warrior"
            case .mondayMorning: "Monday morning"
            case .fridayFinisher: "Friday finisher"
            case .roundTheClock: "Round the clock"
            case .weekStreak: "Seven in a row"
            case .thirtyInARow: "Thirty in a row"
            case .hundredInARow: "Hundred in a row"
            case .cleanWeek: "Clean week"
            case .cleanMonth: "Clean month"
            case .comeback: "Comeback"
            case .marathonWeek: "Marathon week"
            case .twoHorses: "Two horses"
            case .fullStable: "Full stable"
            case .twins: "Twins"
            case .fiveASide: "Five-a-side"
            case .cooldown: "Cooldown"
            case .rationing: "Rationing"
            case .downToTheWire: "Down to the wire"
            case .bounce: "Bounce"
            case .firstLight: "First light"
            case .oldTimer: "Old timer"
            case .theAnswer: "The answer"
            }
        }

        public var section: Section {
            switch self {
            case .firstMaxOut, .regular, .century, .double, .hatTrick: .heavyUse
            case .fullHouse, .grandSlam, .everythingAtOnce, .splitPersonality: .simultaneous
            case .longestWait, .longHaul, .overnight, .lostWeekend, .patience: .waiting
            case .speedrun, .sprint, .fromZero, .slowBurn: .pace
            case .nightOwl, .dawnPatrol, .weekendWarrior, .mondayMorning, .fridayFinisher, .roundTheClock: .clock
            case .weekStreak, .thirtyInARow, .hundredInARow, .cleanWeek, .cleanMonth, .comeback, .marathonWeek: .stamina
            case .twoHorses, .fullStable, .twins, .fiveASide: .collection
            case .cooldown, .rationing, .downToTheWire, .bounce: .husbandry
            case .firstLight, .oldTimer, .theAnswer: .log
            }
        }

        /// What it takes. Every row shows this, earned or locked — `detail` is only
        /// the measured state, never this sentence.
        public var requirement: String {
            switch self {
            case .firstMaxOut: "Run one limit all the way to full."
            case .regular: "Hit a full limit ten times."
            case .century: "Hit a full limit a hundred times."
            case .double: "Fill two different limits on the same day."
            case .hatTrick: "Fill three different accounts on the same day."
            case .fullHouse: "Have two providers blocked at the same time."
            case .grandSlam: "Have all three providers blocked at once."
            case .everythingAtOnce: "Have five limits full at the same moment."
            case .splitPersonality: "Have two accounts of the same provider full at once."
            case .longestWait: "Wait out a full limit for an hour or more."
            case .longHaul: "Wait out a full limit for six hours."
            case .overnight: "Stay full for twelve hours straight."
            case .lostWeekend: "Stay full for forty-eight hours straight."
            case .patience: "Accumulate seven days of waiting."
            case .speedrun: "Go from under 10 % to full within six hours."
            case .sprint: "Go from under 10 % to full within one hour."
            case .fromZero: "Go from 0 % to full on the same day."
            case .slowBurn: "Take six days to fill a weekly limit."
            case .nightOwl: "Burn limit between 1 and 5 in the morning."
            case .dawnPatrol: "Burn limit between 5 and 7 in the morning."
            case .weekendWarrior: "Fill a limit on Saturday and on Sunday."
            case .mondayMorning: "Fill a limit before 10 on a Monday."
            case .fridayFinisher: "Fill a limit after 18 on a Friday."
            case .roundTheClock: "Use something in all four quarters of one day."
            case .weekStreak: "Use something seven days in a row."
            case .thirtyInARow: "Use something thirty days in a row."
            case .hundredInARow: "Use something a hundred days in a row."
            case .cleanWeek: "Seven days watched without hitting a single limit."
            case .cleanMonth: "Thirty days watched without hitting a single limit."
            case .comeback: "A clean week right after a week with three full limits."
            case .marathonWeek: "Seven watched days that each went over 90 %."
            case .twoHorses: "Watch two providers at the same time."
            case .fullStable: "Watch all three providers at the same time."
            case .twins: "Watch two accounts of the same provider."
            case .fiveASide: "Watch five accounts at the same time."
            case .cooldown: "Drop under 10 % after a full and stay there a day."
            case .rationing: "Keep a weekly limit under 50 % for a whole week."
            case .downToTheWire: "Hit 99 % and finish the week without going full."
            case .bounce: "Go full and back under 10 % within an hour."
            case .firstLight: "Take the first measurement."
            case .oldTimer: "Keep a log that stretches ninety days."
            case .theAnswer: "Earn every other achievement."
            }
        }
    }

    public struct Achievement: Equatable, Sendable, Identifiable {
        public let kind: Kind
        /// Nil while it is still locked.
        public let earnedAt: Date?
        /// The measured fact, or the progress still short of it. Never the rule —
        /// that lives on `kind.requirement`.
        public let detail: String

        public var id: String { kind.rawValue }
        public var isEarned: Bool { earnedAt != nil }
        public var title: String { kind.title }
        public var requirement: String { kind.requirement }
    }

    /// What the popover shows live, next to the badges: the reset you are waiting on.
    public struct CurrentWait: Equatable, Sendable, Identifiable {
        public let label: String
        public let trackingID: String
        public let limitID: String
        public let since: Date
        public let asOf: Date
        /// One account can wait on two limits at once (session and week). The
        /// popover `ForEach` must not key on `trackingID` alone.
        public var id: String { "\(trackingID)|\(limitID)" }
        public var duration: TimeInterval { asOf.timeIntervalSince(since) }
    }

    /// - Parameters:
    ///   - series: one array per limit, each in time order (change points are enough).
    ///   - observedDays: start-of-day for every day that has at least one reading.
    ///     Needed because "no measurement" and "nothing changed" look alike in change
    ///     points, and a clean week must not be claimed for days nobody watched.
    public static func evaluate(
        series: [[UsageMeasurement]],
        observedDays: Set<Date>,
        calendar: Calendar = .current
    ) -> [Achievement] {
        let runs = series.flatMap { fullRuns($0) }
        let accountRuns = runs.filter { $0.scope == .account }
        let accountSeries = series.filter { $0.first?.scope == .account }
        let rest: [Achievement] = Kind.allCases.compactMap { kind in
            switch kind {
            case .theAnswer: nil
            case .firstMaxOut: firstMaxOut(runs)
            case .regular: countedMaxOuts(accountRuns, needed: 10, kind: .regular)
            case .century: countedMaxOuts(accountRuns, needed: 100, kind: .century)
            case .double: sameDayDistinctLimits(accountRuns, needed: 2, kind: .double, calendar: calendar)
            case .hatTrick: sameDayDistinctAccounts(accountRuns, needed: 3, kind: .hatTrick, calendar: calendar)
            case .fullHouse: overlappingProviders(accountRuns, needed: 2, kind: .fullHouse)
            case .grandSlam: overlappingProviders(accountRuns, needed: 3, kind: .grandSlam)
            case .everythingAtOnce: overlappingLimits(accountRuns, needed: 5, kind: .everythingAtOnce)
            case .splitPersonality: splitPersonality(accountRuns)
            case .longestWait: waitOfAtLeast(accountRuns, 3600, kind: .longestWait)
            case .longHaul: waitOfAtLeast(accountRuns, 6 * 3600, kind: .longHaul)
            case .overnight: waitOfAtLeast(accountRuns, 12 * 3600, kind: .overnight)
            case .lostWeekend: waitOfAtLeast(accountRuns, 48 * 3600, kind: .lostWeekend)
            case .patience: patience(accountRuns)
            case .speedrun: speedrun(series, within: 6 * 3600, kind: .speedrun)
            case .sprint: speedrun(series, within: 3600, kind: .sprint)
            case .fromZero: fromZero(series, calendar: calendar)
            case .slowBurn: slowBurn(series)
            case .nightOwl: hourWindow(series, calendar: calendar, hours: 1..<5, kind: .nightOwl)
            case .dawnPatrol: hourWindow(series, calendar: calendar, hours: 5..<7, kind: .dawnPatrol)
            case .weekendWarrior: weekendWarrior(accountRuns, calendar: calendar)
            case .mondayMorning: becameFull(accountSeries, calendar: calendar, kind: .mondayMorning) { date in
                calendar.component(.weekday, from: date) == 2
                    && calendar.component(.hour, from: date) < 10
            }
            case .fridayFinisher: becameFull(accountSeries, calendar: calendar, kind: .fridayFinisher) { date in
                calendar.component(.weekday, from: date) == 6
                    && calendar.component(.hour, from: date) >= 18
            }
            case .roundTheClock: roundTheClock(series, calendar: calendar)
            case .weekStreak: usageStreak(series, needed: 7, kind: .weekStreak, calendar: calendar)
            case .thirtyInARow: usageStreak(series, needed: 30, kind: .thirtyInARow, calendar: calendar)
            case .hundredInARow: usageStreak(series, needed: 100, kind: .hundredInARow, calendar: calendar)
            case .cleanWeek: cleanStreak(accountRuns, observedDays: observedDays, needed: 7, kind: .cleanWeek, calendar: calendar)
            case .cleanMonth: cleanStreak(accountRuns, observedDays: observedDays, needed: 30, kind: .cleanMonth, calendar: calendar)
            case .comeback: comeback(accountRuns, observedDays: observedDays, calendar: calendar)
            case .marathonWeek: marathonWeek(series, observedDays: observedDays, calendar: calendar)
            case .twoHorses: overlappingWatched(series, needed: 2, kind: .twoHorses, by: \.provider)
            case .fullStable: overlappingWatched(series, needed: 3, kind: .fullStable, by: \.provider)
            case .twins: twins(series)
            case .fiveASide: overlappingWatched(series, needed: 5, kind: .fiveASide, by: \.trackingID)
            case .cooldown: cooldown(accountSeries)
            case .rationing: rationing(accountSeries, observedDays: observedDays, calendar: calendar)
            case .downToTheWire: downToTheWire(accountSeries)
            case .bounce: bounce(accountSeries)
            case .firstLight: firstLight(series)
            case .oldTimer: oldTimer(series)
            }
        }
        let answer = theAnswer(rest)
        return Kind.allCases.map { kind in
            kind == .theAnswer ? answer : rest.first { $0.kind == kind }!
        }
    }

    /// The limit you are waiting on right now, longest wait first.
    public static func currentWaits(series: [[UsageMeasurement]]) -> [CurrentWait] {
        series.compactMap { rows in
            guard let wait = UsageHistory.waitingForReset(rows), let last = rows.last else { return nil }
            return CurrentWait(
                label: last.label,
                trackingID: last.trackingID,
                limitID: last.limitID,
                since: wait.since,
                asOf: wait.asOf
            )
        }
        .sorted { $0.since < $1.since }
    }

    // MARK: - The rules

    private static func firstMaxOut(_ runs: [FullRun]) -> Achievement {
        guard let first = runs.map(\.firstSeenFull).min() else {
            return locked(.firstMaxOut)
        }
        return Achievement(kind: .firstMaxOut, earnedAt: first, detail: "First hit \(Self.day(first)).")
    }

    private static func countedMaxOuts(_ runs: [FullRun], needed: Int, kind: Kind) -> Achievement {
        let ordered = runs.sorted { $0.firstSeenFull < $1.firstSeenFull }
        guard ordered.count >= needed else {
            return Achievement(kind: kind, earnedAt: nil, detail: "\(ordered.count) of \(needed) so far.")
        }
        let hit = ordered[needed - 1]
        return Achievement(
            kind: kind,
            earnedAt: hit.firstSeenFull,
            detail: "\(needed) full limits. Last one \(hit.label) on \(Self.day(hit.firstSeenFull))."
        )
    }

    private static func sameDayDistinctLimits(
        _ runs: [FullRun],
        needed: Int,
        kind: Kind,
        calendar: Calendar
    ) -> Achievement {
        let grouped = Dictionary(grouping: runs) { calendar.startOfDay(for: $0.firstSeenFull) }
        var best: (at: Date, count: Int)?
        for (_, dayRuns) in grouped {
            let firstByLimit = Dictionary(grouping: dayRuns) { "\($0.trackingID)|\($0.limitID)" }
                .mapValues { $0.map(\.firstSeenFull).min()! }
            let count = firstByLimit.count
            guard count > 0 else { continue }
            let at = firstByLimit.values.sorted()[min(needed, count) - 1]
            if best == nil || count > best!.count || (count == best!.count && at < best!.at) {
                best = (at, count)
            }
        }
        guard let best, best.count >= needed else {
            return Achievement(kind: kind, earnedAt: nil, detail: "\(best?.count ?? 0) of \(needed) so far.")
        }
        return Achievement(
            kind: kind,
            earnedAt: best.at,
            detail: "\(best.count) different limits full on \(Self.day(best.at))."
        )
    }

    private static func sameDayDistinctAccounts(
        _ runs: [FullRun],
        needed: Int,
        kind: Kind,
        calendar: Calendar
    ) -> Achievement {
        let grouped = Dictionary(grouping: runs) { calendar.startOfDay(for: $0.firstSeenFull) }
        var best: (at: Date, count: Int)?
        for (_, dayRuns) in grouped {
            let firstByAccount = Dictionary(grouping: dayRuns, by: \.trackingID)
                .mapValues { $0.map(\.firstSeenFull).min()! }
            let count = firstByAccount.count
            guard count > 0 else { continue }
            let at = firstByAccount.values.sorted()[min(needed, count) - 1]
            if best == nil || count > best!.count || (count == best!.count && at < best!.at) {
                best = (at, count)
            }
        }
        guard let best, best.count >= needed else {
            return Achievement(kind: kind, earnedAt: nil, detail: "\(best?.count ?? 0) of \(needed) so far.")
        }
        return Achievement(
            kind: kind,
            earnedAt: best.at,
            detail: "\(best.count) accounts full on \(Self.day(best.at))."
        )
    }

    private static func waitOfAtLeast(_ runs: [FullRun], _ seconds: TimeInterval, kind: Kind) -> Achievement {
        let completed = runs.compactMap { run -> (FullRun, TimeInterval)? in
            guard let duration = run.completedDuration else { return nil }
            return (run, duration)
        }
        guard let (run, duration) = completed.max(by: { $0.1 < $1.1 }) else {
            return locked(kind)
        }
        return Achievement(
            kind: kind,
            earnedAt: duration >= seconds ? run.end : nil,
            detail: "\(duration.hoursAndMinutes) waiting on \(run.label)."
        )
    }

    private static func overlappingProviders(_ runs: [FullRun], needed: Int, kind: Kind) -> Achievement {
        // A run of unknown start counts from the first reading that saw it full —
        // a lower bound, never an invented earlier one.
        var best: (at: Date, providers: Set<Provider>)?
        for (index, left) in runs.enumerated() {
            for right in runs[(index + 1)...] where right.provider != left.provider {
                guard let overlap = overlapStart(left, right) else { continue }
                var providers: Set<Provider> = [left.provider, right.provider]
                for other in runs where !providers.contains(other.provider) {
                    if covers(other, overlap) { providers.insert(other.provider) }
                }
                if best == nil || providers.count > best!.providers.count {
                    best = (overlap, providers)
                }
            }
        }
        guard let best, best.providers.count >= needed else {
            return Achievement(
                kind: kind,
                earnedAt: nil,
                detail: "\(best?.providers.count ?? 0) of \(needed) so far."
            )
        }
        return Achievement(
            kind: kind,
            earnedAt: best.at,
            detail: kind == .grandSlam
                ? "All three providers blocked at once on \(Self.day(best.at))."
                : "\(best.providers.count) providers blocked at once on \(Self.day(best.at))."
        )
    }

    private static func overlappingLimits(_ runs: [FullRun], needed: Int, kind: Kind) -> Achievement {
        struct Event {
            var time: Date
            var opening: Bool
            var id: String
        }
        var events: [Event] = []
        for run in runs {
            let id = "\(run.trackingID)|\(run.limitID)"
            events.append(Event(time: run.firstSeenFull, opening: true, id: id))
            events.append(Event(time: run.end ?? run.lastSeenFull, opening: false, id: id))
        }
        events.sort { left, right in
            if left.time != right.time { return left.time < right.time }
            return left.opening && !right.opening
        }
        var active: Set<String> = []
        var best: (at: Date, count: Int)?
        for event in events {
            if event.opening {
                active.insert(event.id)
                if best == nil || active.count > best!.count {
                    best = (event.time, active.count)
                }
            } else {
                active.remove(event.id)
            }
        }
        guard let best, best.count >= needed else {
            return Achievement(kind: kind, earnedAt: nil, detail: "\(best?.count ?? 0) of \(needed) so far.")
        }
        return Achievement(
            kind: kind,
            earnedAt: best.at,
            detail: "\(best.count) limits full at once on \(Self.day(best.at))."
        )
    }

    private static func splitPersonality(_ runs: [FullRun]) -> Achievement {
        var best: Date?
        for (index, left) in runs.enumerated() {
            for right in runs[(index + 1)...] {
                guard left.provider == right.provider, left.trackingID != right.trackingID else { continue }
                guard let overlap = overlapStart(left, right) else { continue }
                if best == nil || overlap < best! { best = overlap }
            }
        }
        guard let best else { return locked(.splitPersonality) }
        return Achievement(
            kind: .splitPersonality,
            earnedAt: best,
            detail: "Two accounts of one provider full on \(Self.day(best))."
        )
    }

    private static func patience(_ runs: [FullRun]) -> Achievement {
        let finished = runs.compactMap { run -> (Date, TimeInterval)? in
            guard let end = run.end, let duration = run.completedDuration else { return nil }
            return (end, duration)
        }
        .sorted { $0.0 < $1.0 }
        let needed: TimeInterval = 7 * 86_400
        var total: TimeInterval = 0
        for (end, duration) in finished {
            total += duration
            if total >= needed {
                return Achievement(
                    kind: .patience,
                    earnedAt: end,
                    detail: "\(total.hoursAndMinutes) waiting in all."
                )
            }
        }
        return Achievement(
            kind: .patience,
            earnedAt: nil,
            detail: "\(total.hoursAndMinutes) waiting in all."
        )
    }

    private static func overlapStart(_ left: FullRun, _ right: FullRun) -> Date? {
        let start = max(left.firstSeenFull, right.firstSeenFull)
        let leftEnd = left.end ?? left.lastSeenFull
        let rightEnd = right.end ?? right.lastSeenFull
        return start <= min(leftEnd, rightEnd) ? start : nil
    }

    private static func covers(_ run: FullRun, _ moment: Date) -> Bool {
        run.firstSeenFull <= moment && moment <= (run.end ?? run.lastSeenFull)
    }

    private static func speedrun(
        _ series: [[UsageMeasurement]],
        within: TimeInterval,
        kind: Kind
    ) -> Achievement {
        var best: (Date, TimeInterval, String)?
        for rows in series {
            var lastLow: Date?
            for row in rows {
                if row.utilization <= 0.1 { lastLow = row.observedAt }
                guard UsageHistory.isFull(row), let low = lastLow else { continue }
                let took = row.observedAt.timeIntervalSince(low)
                if took <= within, best == nil || took < best!.1 {
                    best = (row.observedAt, took, row.label)
                }
                lastLow = nil
            }
        }
        guard let best else { return locked(kind) }
        return Achievement(
            kind: kind,
            earnedAt: best.0,
            detail: "Empty to full in \(best.1.hoursAndMinutes) on \(best.2)."
        )
    }

    private static func fromZero(
        _ series: [[UsageMeasurement]],
        calendar: Calendar
    ) -> Achievement {
        // A stored 0 % reading and a stored full reading on the same calendar day.
        // A flat 0 % that crosses midnight is one change point, so sitting at empty
        // overnight and filling the next day does not count — we never stored a 0 %
        // on the day it filled.
        var best: (at: Date, label: String)?
        for rows in series {
            var lastZero: Date?
            for row in rows {
                if row.utilization == 0 { lastZero = row.observedAt }
                guard UsageHistory.isFull(row), let zero = lastZero else { continue }
                if calendar.isDate(zero, inSameDayAs: row.observedAt),
                   best == nil || row.observedAt < best!.at {
                    best = (row.observedAt, row.label)
                }
                lastZero = nil
            }
        }
        guard let best else { return locked(.fromZero) }
        return Achievement(
            kind: .fromZero,
            earnedAt: best.at,
            detail: "0 % to full on \(best.label) on \(Self.day(best.at))."
        )
    }

    private static func slowBurn(_ series: [[UsageMeasurement]]) -> Achievement {
        // A weekly limit is one that still had more than four days until reset on
        // some reading. Limit names are the provider's, not ours.
        let needed: TimeInterval = 6 * 86_400
        var best: (at: Date, took: TimeInterval, label: String)?
        for rows in series where looksWeekly(rows) {
            var lastLow: Date?
            for row in rows {
                if row.utilization <= 0.1 { lastLow = row.observedAt }
                guard UsageHistory.isFull(row), let low = lastLow else { continue }
                let took = row.observedAt.timeIntervalSince(low)
                if took >= needed, best == nil || took < best!.1 {
                    best = (row.observedAt, took, row.label)
                }
                lastLow = nil
            }
        }
        guard let best else { return locked(.slowBurn) }
        return Achievement(
            kind: .slowBurn,
            earnedAt: best.at,
            detail: "Filled \(best.label) in \(best.took.hoursAndMinutes)."
        )
    }

    /// A rise is two neighbouring change points where utilization went up. The later
    /// reading is when we *saw* the burn — a value that merely sat in the window
    /// because the Mac woke up there is not usage.
    private static func rises(
        _ series: [[UsageMeasurement]]
    ) -> [(UsageMeasurement, UsageMeasurement)] {
        series.flatMap { rows in
            zip(rows, rows.dropFirst()).filter { $1.utilization > $0.utilization }
        }
    }

    private static func hourWindow(
        _ series: [[UsageMeasurement]],
        calendar: Calendar,
        hours: Range<Int>,
        kind: Kind
    ) -> Achievement {
        var earliest: Date?
        for (_, row) in rises(series) {
            let hour = calendar.component(.hour, from: row.observedAt)
            guard hours.contains(hour) else { continue }
            if earliest == nil || row.observedAt < earliest! { earliest = row.observedAt }
        }
        guard let earliest else { return locked(kind) }
        return Achievement(
            kind: kind,
            earnedAt: earliest,
            detail: "Working at \(Self.clock(earliest, calendar: calendar)) on \(Self.day(earliest))."
        )
    }

    private static func becameFull(
        _ series: [[UsageMeasurement]],
        calendar: Calendar,
        kind: Kind,
        matches: (Date) -> Bool
    ) -> Achievement {
        var earliest: Date?
        for (_, row) in rises(series) {
            guard UsageHistory.isFull(row), matches(row.observedAt) else { continue }
            if earliest == nil || row.observedAt < earliest! { earliest = row.observedAt }
        }
        guard let earliest else { return locked(kind) }
        return Achievement(
            kind: kind,
            earnedAt: earliest,
            detail: "Full at \(Self.clock(earliest, calendar: calendar)) on \(Self.day(earliest))."
        )
    }

    private static func weekendWarrior(_ runs: [FullRun], calendar: Calendar) -> Achievement {
        let blocked = Set(runs.flatMap { run -> [Date] in
            calendar.days(from: run.firstSeenFull, through: run.end ?? run.lastSeenFull)
        })
        var best: Date?
        for day in blocked {
            guard calendar.component(.weekday, from: day) == 7 else { continue }
            guard let sunday = calendar.date(byAdding: .day, value: 1, to: day),
                  blocked.contains(sunday) else { continue }
            if best == nil || sunday < best! { best = sunday }
        }
        guard let best else { return locked(.weekendWarrior) }
        return Achievement(
            kind: .weekendWarrior,
            earnedAt: best,
            detail: "Saturday and Sunday full on the weekend of \(Self.day(best))."
        )
    }

    private static func roundTheClock(
        _ series: [[UsageMeasurement]],
        calendar: Calendar
    ) -> Achievement {
        var byDay: [Date: Set<Int>] = [:]
        for (_, row) in rises(series) {
            let day = calendar.startOfDay(for: row.observedAt)
            byDay[day, default: []].insert(calendar.component(.hour, from: row.observedAt) / 6)
        }
        var best: (day: Date, count: Int)?
        for (day, quarters) in byDay {
            if best == nil || quarters.count > best!.count || (quarters.count == best!.count && day < best!.day) {
                best = (day, quarters.count)
            }
        }
        guard let best, best.count >= 4 else {
            return Achievement(
                kind: .roundTheClock,
                earnedAt: nil,
                detail: "\(best?.count ?? 0) of 4 quarters so far."
            )
        }
        return Achievement(
            kind: .roundTheClock,
            earnedAt: best.day,
            detail: "All four quarters on \(Self.day(best.day))."
        )
    }

    private static func usageStreak(
        _ series: [[UsageMeasurement]],
        needed: Int,
        kind: Kind,
        calendar: Calendar
    ) -> Achievement {
        var days: Set<Date> = []
        for (_, row) in rises(series) {
            days.insert(calendar.startOfDay(for: row.observedAt))
        }
        let (length, end) = longestRun(of: days, calendar: calendar)
        guard length >= needed, let end else {
            return Achievement(kind: kind, earnedAt: nil, detail: "\(length) of \(needed) days so far.")
        }
        return Achievement(kind: kind, earnedAt: end, detail: "\(length) days in a row.")
    }

    private static func cleanStreak(
        _ runs: [FullRun],
        observedDays: Set<Date>,
        needed: Int,
        kind: Kind,
        calendar: Calendar
    ) -> Achievement {
        let blocked = Set(runs.flatMap { run -> [Date] in
            calendar.days(from: run.firstSeenFull, through: run.end ?? run.lastSeenFull)
        })
        let clean = observedDays.subtracting(blocked)
        let (length, end) = longestRun(of: clean, calendar: calendar)
        guard length >= needed, let end else {
            return Achievement(kind: kind, earnedAt: nil, detail: "\(length) of \(needed) clean days.")
        }
        return Achievement(kind: kind, earnedAt: end, detail: "\(length) days without a single block.")
    }

    private static func comeback(
        _ runs: [FullRun],
        observedDays: Set<Date>,
        calendar: Calendar
    ) -> Achievement {
        let blocked = Set(runs.flatMap { run -> [Date] in
            calendar.days(from: run.firstSeenFull, through: run.end ?? run.lastSeenFull)
        })
        let sorted = observedDays.sorted()
        var hit: Date?
        for start in sorted {
            let messy = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
            guard messy.count == 7, messy.allSatisfy(observedDays.contains) else { continue }
            let distinct = Set(
                runs.filter { messy.contains(calendar.startOfDay(for: $0.firstSeenFull)) }
                    .map { "\($0.trackingID)|\($0.limitID)" }
            ).count
            guard distinct >= 3 else { continue }
            guard let cleanStart = calendar.date(byAdding: .day, value: 7, to: start) else { continue }
            let clean = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: cleanStart) }
            guard clean.count == 7,
                  clean.allSatisfy({ observedDays.contains($0) && !blocked.contains($0) }) else { continue }
            if hit == nil || clean[6] < hit! { hit = clean[6] }
        }
        guard let hit else { return locked(.comeback) }
        return Achievement(
            kind: .comeback,
            earnedAt: hit,
            detail: "Clean week after three full limits, ending \(Self.day(hit))."
        )
    }

    private static func marathonWeek(
        _ series: [[UsageMeasurement]],
        observedDays: Set<Date>,
        calendar: Calendar
    ) -> Achievement {
        // A flat stretch at 91 % is one change point plus the last row. The days
        // in between were still over 90 % — same rule as a wait, measured to the
        // last high reading, never invented past it. Unwatched days stay out.
        var highDays: Set<Date> = []
        for rows in series {
            var start: Date?
            var lastHigh: Date?
            for row in rows {
                if row.utilization >= 0.9 {
                    if start == nil { start = row.observedAt }
                    lastHigh = row.observedAt
                } else if let began = start, let last = lastHigh {
                    highDays.formUnion(calendar.days(from: began, through: last))
                    start = nil
                    lastHigh = nil
                }
            }
            if let began = start, let last = lastHigh {
                highDays.formUnion(calendar.days(from: began, through: last))
            }
        }
        let watched = highDays.intersection(observedDays)
        let (length, end) = longestRun(of: watched, calendar: calendar)
        guard length >= 7, let end else {
            return Achievement(
                kind: .marathonWeek,
                earnedAt: nil,
                detail: "\(length) of 7 days over 90 %."
            )
        }
        return Achievement(
            kind: .marathonWeek,
            earnedAt: end,
            detail: "\(length) days over 90 %."
        )
    }

    private static func overlappingWatched<Key: Hashable>(
        _ series: [[UsageMeasurement]],
        needed: Int,
        kind: Kind,
        by key: KeyPath<UsageMeasurement, Key>
    ) -> Achievement {
        var grouped: [String: (start: Date, end: Date)] = [:]
        for rows in series {
            guard let first = rows.first, let last = rows.last else { continue }
            let id = "\(first[keyPath: key])"
            if let existing = grouped[id] {
                grouped[id] = (min(existing.start, first.observedAt), max(existing.end, last.observedAt))
            } else {
                grouped[id] = (first.observedAt, last.observedAt)
            }
        }
        var events: [(time: Date, opening: Bool)] = []
        for window in grouped.values {
            events.append((window.start, true))
            events.append((window.end, false))
        }
        events.sort { left, right in
            if left.time != right.time { return left.time < right.time }
            return left.opening && !right.opening
        }
        var active = 0
        var best: (at: Date, count: Int)?
        for event in events {
            if event.opening {
                active += 1
                if best == nil || active > best!.count {
                    best = (event.time, active)
                }
            } else {
                active -= 1
            }
        }
        guard let best, best.count >= needed else {
            return Achievement(kind: kind, earnedAt: nil, detail: "\(best?.count ?? 0) of \(needed) so far.")
        }
        let noun: String
        switch kind {
        case .twoHorses, .fullStable:
            noun = best.count == 1 ? "provider" : "providers"
        default:
            noun = best.count == 1 ? "account" : "accounts"
        }
        return Achievement(
            kind: kind,
            earnedAt: best.at,
            detail: kind == .fullStable
                ? "All three providers watched together on \(Self.day(best.at))."
                : "\(best.count) \(noun) watched together on \(Self.day(best.at))."
        )
    }

    private static func twins(_ series: [[UsageMeasurement]]) -> Achievement {
        var byProvider: [Provider: [String: (start: Date, end: Date)]] = [:]
        for rows in series {
            guard let first = rows.first, let last = rows.last else { continue }
            var accounts = byProvider[first.provider] ?? [:]
            if let existing = accounts[first.trackingID] {
                accounts[first.trackingID] = (
                    min(existing.start, first.observedAt),
                    max(existing.end, last.observedAt)
                )
            } else {
                accounts[first.trackingID] = (first.observedAt, last.observedAt)
            }
            byProvider[first.provider] = accounts
        }
        var best: Date?
        for accounts in byProvider.values {
            let windows = Array(accounts.values)
            for i in windows.indices {
                for j in windows.indices where j > i {
                    let start = max(windows[i].start, windows[j].start)
                    let end = min(windows[i].end, windows[j].end)
                    guard start <= end else { continue }
                    if best == nil || start < best! { best = start }
                }
            }
        }
        guard let best else { return locked(.twins) }
        return Achievement(
            kind: .twins,
            earnedAt: best,
            detail: "Two accounts of one provider watched on \(Self.day(best))."
        )
    }

    private static func cooldown(_ series: [[UsageMeasurement]]) -> Achievement {
        var best: (at: Date, label: String)?
        for rows in series {
            for run in fullRuns(rows) {
                guard let end = run.end else { continue }
                guard let drop = rows.first(where: { $0.observedAt >= end && $0.utilization <= 0.1 }) else {
                    continue
                }
                let until = drop.observedAt.addingTimeInterval(86_400)
                let bounced = rows.contains {
                    $0.observedAt > drop.observedAt && $0.observedAt <= until && UsageHistory.isFull($0)
                }
                guard !bounced else { continue }
                guard rows.contains(where: { $0.observedAt >= until && !UsageHistory.isFull($0) }) else {
                    continue
                }
                if best == nil || drop.observedAt < best!.at {
                    best = (drop.observedAt, drop.label)
                }
            }
        }
        guard let best else { return locked(.cooldown) }
        return Achievement(
            kind: .cooldown,
            earnedAt: best.at,
            detail: "Back under 10 % for 24h on \(best.label)."
        )
    }

    private static func rationing(
        _ series: [[UsageMeasurement]],
        observedDays: Set<Date>,
        calendar: Calendar
    ) -> Achievement {
        let sorted = observedDays.sorted()
        var hit: Date?
        for rows in series where looksWeekly(rows) {
            for start in sorted {
                let week = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
                guard week.count == 7, week.allSatisfy(observedDays.contains) else { continue }
                let under = week.allSatisfy { day in
                    guard let end = calendar.date(byAdding: .day, value: 1, to: day),
                          let util = rows.last(where: { $0.observedAt < end })?.utilization
                    else { return false }
                    return util < 0.5
                }
                guard under else { continue }
                if hit == nil || week[6] < hit! { hit = week[6] }
            }
        }
        guard let hit else { return locked(.rationing) }
        return Achievement(
            kind: .rationing,
            earnedAt: hit,
            detail: "Under 50 % for 7 days, ending \(Self.day(hit))."
        )
    }

    private static func downToTheWire(_ series: [[UsageMeasurement]]) -> Achievement {
        var best: (at: Date, label: String)?
        for rows in series where looksWeekly(rows) {
            var cycleMax = 0.0
            var cycleFull = false
            var prevRemaining: TimeInterval?
            var label = rows.first?.label ?? "Week"
            for row in rows {
                label = row.label
                let remaining = row.resetsAt.map { $0.timeIntervalSince(row.observedAt) }
                if let remaining, let prev = prevRemaining, remaining > prev + 3 * 86_400 {
                    if cycleMax >= 0.99, !cycleFull {
                        if best == nil || row.observedAt < best!.at {
                            best = (row.observedAt, label)
                        }
                    }
                    cycleMax = 0
                    cycleFull = false
                }
                cycleMax = max(cycleMax, row.utilization)
                if UsageHistory.isFull(row) { cycleFull = true }
                prevRemaining = remaining
            }
        }
        guard let best else { return locked(.downToTheWire) }
        return Achievement(
            kind: .downToTheWire,
            earnedAt: best.at,
            detail: "99 % and the week ended on \(best.label)."
        )
    }

    private static func bounce(_ series: [[UsageMeasurement]]) -> Achievement {
        var best: (at: Date, took: TimeInterval, label: String)?
        for rows in series {
            var fullSince: Date?
            var startedAtFirst = false
            for (index, row) in rows.enumerated() {
                if UsageHistory.isFull(row) {
                    if fullSince == nil {
                        fullSince = row.observedAt
                        startedAtFirst = index == 0
                    }
                    continue
                }
                guard let start = fullSince else { continue }
                let knownStart = startedAtFirst ? nil : start
                fullSince = nil
                guard let knownStart, row.utilization <= 0.1 else { continue }
                let took = row.observedAt.timeIntervalSince(knownStart)
                if took <= 3600, best == nil || took < best!.took {
                    best = (row.observedAt, took, row.label)
                }
            }
        }
        guard let best else { return locked(.bounce) }
        return Achievement(
            kind: .bounce,
            earnedAt: best.at,
            detail: "Full to under 10 % in \(best.took.hoursAndMinutes) on \(best.label)."
        )
    }

    private static func firstLight(_ series: [[UsageMeasurement]]) -> Achievement {
        let first = series.flatMap { $0 }.min(by: { $0.observedAt < $1.observedAt })
        guard let first else { return locked(.firstLight) }
        return Achievement(
            kind: .firstLight,
            earnedAt: first.observedAt,
            detail: "First reading on \(Self.day(first.observedAt))."
        )
    }

    private static func oldTimer(_ series: [[UsageMeasurement]]) -> Achievement {
        let all = series.flatMap { $0 }
        guard let first = all.min(by: { $0.observedAt < $1.observedAt }),
              let last = all.max(by: { $0.observedAt < $1.observedAt }) else {
            return locked(.oldTimer)
        }
        let span = last.observedAt.timeIntervalSince(first.observedAt)
        return Achievement(
            kind: .oldTimer,
            earnedAt: span >= 90 * 86_400 ? last.observedAt : nil,
            detail: "Log stretches \(span.hoursAndMinutes) from \(Self.day(first.observedAt))."
        )
    }

    /// Derived from whatever else `evaluate` just produced. A new kind in
    /// `Kind.allCases` is counted automatically — do not list the others here.
    private static func theAnswer(_ others: [Achievement]) -> Achievement {
        let needed = others.count
        let earned = others.filter(\.isEarned)
        guard earned.count == needed, needed > 0 else {
            return Achievement(
                kind: .theAnswer,
                earnedAt: nil,
                detail: "\(earned.count) of \(needed) so far."
            )
        }
        let at = earned.compactMap(\.earnedAt).max()
        return Achievement(
            kind: .theAnswer,
            earnedAt: at,
            detail: "All \(needed) others."
        )
    }

    private static func looksWeekly(_ rows: [UsageMeasurement]) -> Bool {
        rows.contains { row in
            guard let reset = row.resetsAt else { return false }
            return reset.timeIntervalSince(row.observedAt) > 4 * 86_400
        }
    }

    /// Longest run of consecutive days, and the day it ended on.
    private static func longestRun(of days: Set<Date>, calendar: Calendar) -> (Int, Date?) {
        let sorted = days.sorted()
        var best = 0
        var bestEnd: Date?
        var length = 0
        var previous: Date?
        for day in sorted {
            if let previous, calendar.dateComponents([.day], from: previous, to: day).day == 1 {
                length += 1
            } else {
                length = 1
            }
            if length >= best {
                best = length
                bestEnd = day
            }
            previous = day
        }
        return (best, bestEnd)
    }

    private static func locked(_ kind: Kind) -> Achievement {
        Achievement(kind: kind, earnedAt: nil, detail: "Not yet.")
    }

    // MARK: - Formatting

    private static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private static func clock(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

public extension TimeInterval {
    /// "3h 05m", "45m", and from a day up "6d 02h" / "2d 00h". Never "0h", and
    /// never "1h 60m" — the carry happens before the split, so 119.6 minutes
    /// reads "2h 00m" rather than an hour plus sixty.
    var hoursAndMinutes: String {
        let minutes = Int((self / 60).rounded())
        let hours = minutes / 60
        if hours >= 24 {
            return String(format: "%dd %02dh", hours / 24, hours % 24)
        }
        guard hours > 0 else { return "\(minutes)m" }
        return String(format: "%dh %02dm", hours, minutes % 60)
    }
}

extension Calendar {
    /// Every day touched by the span, start-of-day. Bounded so a corrupt pair of dates
    /// cannot spin here forever.
    func days(from: Date, through: Date, limit: Int = 400) -> [Date] {
        var result: [Date] = []
        var day = startOfDay(for: from)
        let last = startOfDay(for: through)
        while day <= last, result.count < limit {
            result.append(day)
            guard let next = date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}
