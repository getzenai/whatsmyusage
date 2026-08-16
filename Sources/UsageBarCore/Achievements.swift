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
        case weekStreak
        case cleanWeek

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
            case .weekStreak: "Seven in a row"
            case .cleanWeek: "Clean week"
            }
        }

        public var section: Section {
            switch self {
            case .firstMaxOut, .regular, .century, .double, .hatTrick: .heavyUse
            case .fullHouse, .grandSlam, .everythingAtOnce, .splitPersonality: .simultaneous
            case .longestWait, .longHaul, .overnight, .lostWeekend, .patience: .waiting
            case .speedrun, .sprint, .fromZero, .slowBurn: .pace
            case .nightOwl: .clock
            case .weekStreak, .cleanWeek: .stamina
            }
        }

        /// What it takes — shown while it is still locked, so the list is a goal and
        /// not a riddle.
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
        return Kind.allCases.map { kind in
            switch kind {
            case .firstMaxOut: firstMaxOut(runs)
            case .regular: countedMaxOuts(runs, needed: 10, kind: .regular)
            case .century: countedMaxOuts(runs, needed: 100, kind: .century)
            case .double: sameDayDistinctLimits(runs, needed: 2, kind: .double, calendar: calendar)
            case .hatTrick: sameDayDistinctAccounts(accountRuns, needed: 3, kind: .hatTrick, calendar: calendar)
            case .fullHouse: overlappingProviders(accountRuns, needed: 2, kind: .fullHouse)
            case .grandSlam: overlappingProviders(accountRuns, needed: 3, kind: .grandSlam)
            case .everythingAtOnce: overlappingLimits(runs, needed: 5, kind: .everythingAtOnce)
            case .splitPersonality: splitPersonality(accountRuns)
            case .longestWait: waitOfAtLeast(runs, 3600, kind: .longestWait)
            case .longHaul: waitOfAtLeast(runs, 6 * 3600, kind: .longHaul)
            case .overnight: waitOfAtLeast(runs, 12 * 3600, kind: .overnight)
            case .lostWeekend: waitOfAtLeast(runs, 48 * 3600, kind: .lostWeekend)
            case .patience: patience(runs)
            case .speedrun: speedrun(series, within: 6 * 3600, kind: .speedrun)
            case .sprint: speedrun(series, within: 3600, kind: .sprint)
            case .fromZero: fromZero(series, calendar: calendar)
            case .slowBurn: slowBurn(series)
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
            if let best, best.count > 0 {
                return Achievement(kind: kind, earnedAt: nil, detail: "\(best.count) of \(needed) so far.")
            }
            return locked(kind)
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
            if let best, best.count > 0 {
                return Achievement(kind: kind, earnedAt: nil, detail: "\(best.count) of \(needed) so far.")
            }
            return locked(kind)
        }
        return Achievement(
            kind: kind,
            earnedAt: best.at,
            detail: "\(best.count) accounts full on \(Self.day(best.at))."
        )
    }

    private static func waitOfAtLeast(_ runs: [FullRun], _ seconds: TimeInterval, kind: Kind) -> Achievement {
        let completed = runs.compactMap { run -> (FullRun, TimeInterval)? in
            guard let duration = run.completedDuration, duration >= seconds else { return nil }
            return (run, duration)
        }
        guard let (run, duration) = completed.max(by: { $0.1 < $1.1 }) else {
            return locked(kind)
        }
        return Achievement(
            kind: kind,
            earnedAt: run.end,
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
            if let best, best.providers.count > 0 {
                return Achievement(
                    kind: kind,
                    earnedAt: nil,
                    detail: "\(best.providers.count) of \(needed) so far."
                )
            }
            return locked(kind)
        }
        return Achievement(
            kind: kind,
            earnedAt: best.at,
            detail: "\(best.providers.count) providers blocked at once on \(Self.day(best.at))."
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
            if let best, best.count > 0 {
                return Achievement(kind: kind, earnedAt: nil, detail: "\(best.count) of \(needed) so far.")
            }
            return locked(kind)
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
        return locked(.patience)
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
        let weekHorizon: TimeInterval = 4 * 86_400
        let needed: TimeInterval = 6 * 86_400
        var best: (at: Date, took: TimeInterval, label: String)?
        for rows in series {
            let weekly = rows.contains { row in
                guard let reset = row.resetsAt else { return false }
                return reset.timeIntervalSince(row.observedAt) > weekHorizon
            }
            guard weekly else { continue }
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
    /// "3h 05m", "45m". Never "0h", and never "1h 60m" — the carry happens before
    /// the split, so 119.6 minutes reads "2h 00m" rather than an hour plus sixty.
    var hoursAndMinutes: String {
        let minutes = Int((self / 60).rounded())
        let hours = minutes / 60
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
