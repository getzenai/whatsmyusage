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

    public enum Kind: String, CaseIterable, Sendable {
        case firstMaxOut
        case longestWait
        case fullHouse
        case speedrun
        case nightOwl
        case weekStreak
        case cleanWeek

        public var title: String {
            switch self {
            case .firstMaxOut: "Maxed out"
            case .longestWait: "The wait"
            case .fullHouse: "Full house"
            case .speedrun: "Speedrun"
            case .nightOwl: "Night shift"
            case .weekStreak: "Seven in a row"
            case .cleanWeek: "Clean week"
            }
        }

        /// What it takes — shown while it is still locked, so the list is a goal and
        /// not a riddle.
        public var requirement: String {
            switch self {
            case .firstMaxOut: "Run one limit all the way to full."
            case .longestWait: "Wait out a full limit for an hour or more."
            case .fullHouse: "Have two providers blocked at the same time."
            case .speedrun: "Go from under 10 % to full within six hours."
            case .nightOwl: "Burn limit between 1 and 5 in the morning."
            case .weekStreak: "Use something seven days in a row."
            case .cleanWeek: "Seven days watched without hitting a single limit."
            }
        }
    }

    public struct Achievement: Equatable, Sendable, Identifiable {
        public let kind: Kind
        /// Nil while it is still locked.
        public let earnedAt: Date?
        /// The measured fact behind it, or what is still missing.
        public let detail: String

        public var id: String { kind.rawValue }
        public var isEarned: Bool { earnedAt != nil }
        public var title: String { kind.title }
    }

    /// What the popover shows live, next to the badges: the reset you are waiting on.
    public struct CurrentWait: Equatable, Sendable {
        public let label: String
        public let trackingID: String
        public let since: Date
        public let asOf: Date
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
        return Kind.allCases.map { kind in
            switch kind {
            case .firstMaxOut: firstMaxOut(runs)
            case .longestWait: longestWait(runs)
            case .fullHouse: fullHouse(accountRuns)
            case .speedrun: speedrun(series)
            case .nightOwl: nightOwl(series, calendar: calendar)
            case .weekStreak: weekStreak(series, calendar: calendar)
            case .cleanWeek: cleanWeek(accountRuns, observedDays: observedDays, calendar: calendar)
            }
        }
    }

    /// The limit you are waiting on right now, longest wait first.
    public static func currentWaits(series: [[UsageMeasurement]]) -> [CurrentWait] {
        series.compactMap { rows in
            guard let wait = UsageHistory.waitingForReset(rows), let last = rows.last else { return nil }
            return CurrentWait(
                label: last.label,
                trackingID: last.trackingID,
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

    private static func longestWait(_ runs: [FullRun]) -> Achievement {
        let completed = runs.compactMap { run -> (FullRun, TimeInterval)? in
            guard let duration = run.completedDuration, duration >= 3600 else { return nil }
            return (run, duration)
        }
        guard let (run, duration) = completed.max(by: { $0.1 < $1.1 }) else {
            return locked(.longestWait)
        }
        return Achievement(
            kind: .longestWait,
            earnedAt: run.end,
            detail: "\(duration.hoursAndMinutes) waiting on \(run.label)."
        )
    }

    private static func fullHouse(_ runs: [FullRun]) -> Achievement {
        // Two providers blocked at once means their full stretches overlap. A run of
        // unknown start counts from the first reading that saw it full — a lower
        // bound, never an invented earlier one.
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
        guard let best else { return locked(.fullHouse) }
        return Achievement(
            kind: .fullHouse,
            earnedAt: best.at,
            detail: "\(best.providers.count) providers blocked at once on \(Self.day(best.at))."
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

    private static func speedrun(_ series: [[UsageMeasurement]], within: TimeInterval = 6 * 3600) -> Achievement {
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
        guard let best else { return locked(.speedrun) }
        return Achievement(
            kind: .speedrun,
            earnedAt: best.0,
            detail: "Empty to full in \(best.1.hoursAndMinutes) on \(best.2)."
        )
    }

    private static func nightOwl(_ series: [[UsageMeasurement]], calendar: Calendar) -> Achievement {
        var earliest: Date?
        for rows in series {
            for (index, row) in rows.enumerated() where index > 0 {
                guard row.utilization > rows[index - 1].utilization else { continue }
                let hour = calendar.component(.hour, from: row.observedAt)
                guard hour >= 1, hour < 5 else { continue }
                if earliest == nil || row.observedAt < earliest! { earliest = row.observedAt }
            }
        }
        guard let earliest else { return locked(.nightOwl) }
        return Achievement(
            kind: .nightOwl,
            earnedAt: earliest,
            detail: "Working at \(Self.clock(earliest, calendar: calendar)) on \(Self.day(earliest))."
        )
    }

    private static func weekStreak(_ series: [[UsageMeasurement]], calendar: Calendar) -> Achievement {
        var days: Set<Date> = []
        for rows in series {
            for (index, row) in rows.enumerated() where index > 0 {
                if row.utilization > rows[index - 1].utilization {
                    days.insert(calendar.startOfDay(for: row.observedAt))
                }
            }
        }
        let (length, end) = longestRun(of: days, calendar: calendar)
        guard length >= 7, let end else {
            return Achievement(
                kind: .weekStreak,
                earnedAt: nil,
                detail: "\(length) of 7 days so far."
            )
        }
        return Achievement(kind: .weekStreak, earnedAt: end, detail: "\(length) days in a row.")
    }

    private static func cleanWeek(
        _ runs: [FullRun],
        observedDays: Set<Date>,
        calendar: Calendar
    ) -> Achievement {
        let blocked = Set(runs.flatMap { run -> [Date] in
            calendar.days(from: run.firstSeenFull, through: run.end ?? run.lastSeenFull)
        })
        let clean = observedDays.subtracting(blocked)
        let (length, end) = longestRun(of: clean, calendar: calendar)
        guard length >= 7, let end else {
            return Achievement(kind: .cleanWeek, earnedAt: nil, detail: "\(length) of 7 clean days.")
        }
        return Achievement(kind: .cleanWeek, earnedAt: end, detail: "\(length) days without a single block.")
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
        Achievement(kind: kind, earnedAt: nil, detail: kind.requirement)
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
    /// "3 h 05 min", "45 min". Never "0 h".
    var hoursAndMinutes: String {
        let minutes = Int((self / 60).rounded())
        let hours = minutes / 60
        guard hours > 0 else { return "\(minutes) min" }
        return String(format: "%d h %02d min", hours, minutes % 60)
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
