import Foundation

/// Reading the raw log. Nothing here is stored — every answer is derived from the
/// measurement rows, so a wrong rule is a fixable query and never lost data.
public enum UsageHistory {
    /// A limit counts as full when the provider says it is locked, or when the number
    /// has reached the top. The lock flag alone is not enough: Claude never sends one
    /// (see `LockState`), and a 100 % Claude week is exactly the case this measures.
    public static func isFull(_ measurement: UsageMeasurement, threshold: Double = 1.0) -> Bool {
        measurement.locked == .locked || measurement.utilization >= threshold
    }

    /// "How long have you been waiting for a reset?"
    public struct Wait: Equatable, Sendable {
        /// First reading of the unbroken full run the newest reading belongs to.
        public let since: Date
        /// Newest reading in that run.
        public let asOf: Date
        /// Longest stretch inside the run with no measurement at all. The app is not
        /// running while the Mac sleeps, so a long gap means the run *may* have been
        /// broken unseen — the number stays honest by saying so instead of guessing.
        public let largestGap: TimeInterval

        public var duration: TimeInterval { asOf.timeIntervalSince(since) }
    }

    /// Nil when the newest reading of the series is not full — you are not waiting.
    public static func waitingForReset(
        _ series: [UsageMeasurement],
        threshold: Double = 1.0
    ) -> Wait? {
        guard let newest = series.last, isFull(newest, threshold: threshold) else { return nil }
        var index = series.count - 1
        var largestGap: TimeInterval = 0
        while index > 0, isFull(series[index - 1], threshold: threshold) {
            let gap = series[index].observedAt.timeIntervalSince(series[index - 1].observedAt)
            largestGap = max(largestGap, gap)
            index -= 1
        }
        return Wait(since: series[index].observedAt, asOf: newest.observedAt, largestGap: largestGap)
    }

    /// A reset seen in the data: the reading where the number dropped back.
    public struct Reset: Equatable, Sendable {
        /// Last reading before the drop.
        public let before: UsageMeasurement
        /// First reading after it.
        public let after: UsageMeasurement
        /// How long the limit had been full before it let go. Nil when the log never
        /// saw it fill — an app started mid-block cannot know when the block began.
        public let waitedFor: TimeInterval?

        public var at: Date { after.observedAt }
    }

    /// Every reset in the series: a full reading followed by a not-full one. Derived
    /// from two neighbouring rows, which is the whole reason the log keeps raw rows.
    public static func resets(
        _ series: [UsageMeasurement],
        threshold: Double = 1.0
    ) -> [Reset] {
        var result: [Reset] = []
        var runStart: Int?
        for (index, current) in series.enumerated() {
            let full = isFull(current, threshold: threshold)
            if full, runStart == nil { runStart = index }
            guard !full, index > 0 else { continue }
            let previous = series[index - 1]
            if isFull(previous, threshold: threshold) {
                // A run that starts at the very first row began before the log did —
                // the app was started mid-block, and 0 s of waiting would be a lie.
                let waitedFor = runStart.flatMap { start -> TimeInterval? in
                    start == 0 ? nil : previous.observedAt.timeIntervalSince(series[start].observedAt)
                }
                result.append(Reset(before: previous, after: current, waitedFor: waitedFor))
            }
            runStart = nil
        }
        return result
    }

    /// Consumption per hour over the last `window`, from the first and last reading in
    /// it. Negative results are dropped: a fall is a reset, not negative usage.
    public static func burnRatePerHour(
        _ series: [UsageMeasurement],
        window: TimeInterval,
        now: Date
    ) -> Double? {
        let recent = series.filter { $0.observedAt >= now.addingTimeInterval(-window) }
        guard let first = recent.first, let last = recent.last else { return nil }
        let hours = last.observedAt.timeIntervalSince(first.observedAt) / 3600
        guard hours > 0 else { return nil }
        let rate = (last.utilization - first.utilization) / hours
        return rate > 0 ? rate : nil
    }

    /// When the limit runs out at the current rate. Nil when it is not filling, already
    /// full, or the window holds too little to say anything.
    public static func projectedFull(
        _ series: [UsageMeasurement],
        window: TimeInterval = 3600,
        now: Date
    ) -> Date? {
        // The last reading *inside the window*, so the rate and the starting point
        // describe the same stretch of time.
        guard let last = series.last(where: { $0.observedAt >= now.addingTimeInterval(-window) }),
              last.utilization < 1,
              let rate = burnRatePerHour(series, window: window, now: now)
        else { return nil }
        let hoursLeft = (1 - last.utilization) / rate
        return last.observedAt.addingTimeInterval(hoursLeft * 3600)
    }
}
