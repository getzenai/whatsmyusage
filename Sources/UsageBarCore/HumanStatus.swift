import Foundation

/// Text a person can read. `--json` stays the data structure.
public enum HumanStatus {
    public struct Names: Equatable, Sendable {
        public var custom: [String: String]
        public var defaults: [String: String]

        public init(custom: [String: String] = [:], defaults: [String: String] = [:]) {
            self.custom = custom
            self.defaults = defaults
        }
    }

    public static func render(
        status: UsageQuery.Status,
        pick: UsageQuery.Pick,
        names: Names,
        now: Date,
        showLimits: Bool,
        preferences: DisplayPreferences = DisplayPreferences(),
        calendar: Calendar = .current
    ) -> String {
        let shown = preferences.applied(to: status)
        let roster = status.accounts.map { (trackingID: $0.trackingID, provider: $0.provider) }
        func name(for trackingID: String, provider: Provider) -> String {
            AccountDisplayNames.resolve(
                trackingID: trackingID,
                provider: provider,
                custom: names.custom,
                defaults: names.defaults,
                peers: AccountDisplayNames.peers(for: trackingID, provider: provider, accounts: roster)
            )
        }

        if status.accounts.isEmpty {
            return "No readings in the log."
        }

        var lines: [String] = []
        let stale = status.observedAt.map { UsageQuery.isStale($0, now: now) } ?? false
        if stale, let observedAt = status.observedAt {
            lines.append(
                "Readings are \(agePhrase(from: observedAt, now: now)) old. Open WhatsMyUsage so it can refresh."
            )
            lines.append("")
        }

        lines.append(pickLine(pick: pick, status: shown, now: now, calendar: calendar, name: name))

        if shown.accounts.isEmpty {
            return lines.joined(separator: "\n")
        }

        lines.append("")
        for account in shown.accounts {
            let label = name(for: account.trackingID, provider: account.provider)
            let accountStale = account.limits.allSatisfy { $0.utilization == nil }
            if accountStale {
                lines.append(label)
                continue
            }
            let worst = worstAccountLimit(account)
            lines.append(accountLine(name: label, limit: worst, now: now, calendar: calendar))
            let extras = extraLimits(account, forced: showLimits)
            for limit in extras {
                lines.append("  \(limitLine(limit, now: now, calendar: calendar))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func renderPick(
        _ pick: UsageQuery.Pick,
        status: UsageQuery.Status,
        names: Names,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let roster = status.accounts.map { (trackingID: $0.trackingID, provider: $0.provider) }
        return pickLine(
            pick: pick,
            status: status,
            now: now,
            calendar: calendar,
            name: { trackingID, provider in
                AccountDisplayNames.resolve(
                    trackingID: trackingID,
                    provider: provider,
                    custom: names.custom,
                    defaults: names.defaults,
                    peers: AccountDisplayNames.peers(
                        for: trackingID,
                        provider: provider,
                        accounts: roster
                    )
                )
            }
        )
    }

    public static func localReset(_ date: Date, now: Date, calendar: Calendar) -> String {
        let sameDay = calendar.isDate(date, inSameDayAs: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US_POSIX")
        if sameDay {
            formatter.dateFormat = "HH:mm"
            return "opens \(formatter.string(from: date))"
        }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        if (0..<7).contains(days) {
            formatter.dateFormat = "EEE HH:mm"
            return "opens \(formatter.string(from: date))"
        }
        formatter.dateFormat = "d MMM HH:mm"
        return "opens \(formatter.string(from: date))"
    }

    // MARK: - Private

    private static func pickLine(
        pick: UsageQuery.Pick,
        status: UsageQuery.Status,
        now: Date,
        calendar: Calendar,
        name: (String, Provider) -> String
    ) -> String {
        guard let trackingID = pick.trackingID, let provider = pick.provider else {
            if let reset = pick.resetsAt {
                return "No account has room — earliest \(localReset(reset, now: now, calendar: calendar))"
            }
            if status.observedAt.map({ UsageQuery.isStale($0, now: now) }) == true {
                return "No account has room — numbers are stale."
            }
            return "No account has room."
        }
        let display = name(trackingID, provider)
        let account = status.accounts.first { $0.trackingID == trackingID }
        let worst = account.flatMap(worstAccountLimit)
        let pct = pick.utilization.map(BarPresentation.percentString)
        let label = worst?.label
        switch (pct, label) {
        case let (pct?, label?):
            return "Use \(display) — \(pct) \(label)"
        case let (pct?, nil):
            return "Use \(display) — \(pct)"
        default:
            return "Use \(display)"
        }
    }

    private static func accountLine(
        name: String,
        limit: UsageQuery.LimitStatus?,
        now: Date,
        calendar: Calendar
    ) -> String {
        guard let limit else { return name }
        return "\(name)  \(limitLine(limit, now: now, calendar: calendar))"
    }

    private static func limitLine(
        _ limit: UsageQuery.LimitStatus,
        now: Date,
        calendar: Calendar
    ) -> String {
        var parts: [String] = [limit.label]
        if let utilization = limit.utilization {
            parts.append(BarPresentation.percentString(utilization))
        }
        if let locked = limit.locked, locked != .unknown {
            parts.append(locked.rawValue)
        }
        if let reset = limit.resetsAt {
            parts.append(localReset(reset, now: now, calendar: calendar))
        }
        return parts.joined(separator: "  ")
    }

    private static func worstAccountLimit(_ account: UsageQuery.AccountStatus) -> UsageQuery.LimitStatus? {
        let accountScoped = account.limits.filter { $0.scope == .account && $0.utilization != nil }
        let pool = accountScoped.isEmpty
            ? account.limits.filter { $0.utilization != nil }
            : accountScoped
        return pool.max { lhs, rhs in
            Limit.isLessUrgent(asLimit(lhs), asLimit(rhs))
        }
    }

    /// Extra rows: asked for with `--limits`, or when limits disagree about blocked.
    private static func extraLimits(
        _ account: UsageQuery.AccountStatus,
        forced: Bool
    ) -> [UsageQuery.LimitStatus] {
        let fresh = account.limits.filter { $0.utilization != nil }
        guard fresh.count > 1 else { return [] }
        let disagree = fresh.contains(where: isBlocked) && fresh.contains(where: { !isBlocked($0) })
        guard forced || disagree else { return [] }
        let worst = worstAccountLimit(account)
        return fresh
            .filter { $0.limitID != worst?.limitID }
            .sorted { $0.limitID < $1.limitID }
    }

    private static func isBlocked(_ limit: UsageQuery.LimitStatus) -> Bool {
        if limit.locked == .locked { return true }
        if let utilization = limit.utilization, utilization >= 1 { return true }
        return false
    }

    private static func asLimit(_ status: UsageQuery.LimitStatus) -> Limit {
        Limit(
            id: status.limitID,
            label: status.label,
            utilization: status.utilization ?? 0,
            resetsAt: status.resetsAt,
            locked: status.locked ?? .unknown,
            scope: status.scope
        )
    }

    /// Floor only. Under an hour: `6m`. After that: `2h 20m`, never `1h` for six minutes.
    public static func agePhrase(from observedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(observedAt).rounded(.down)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}
