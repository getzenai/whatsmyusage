import Foundation

/// Current-state answers from the measurement log. Used by the `whatsmyusage` CLI
/// and tested here so a wrong "unknown" rule cannot hide in argv parsing.
///
/// The CLI never talks to the network or the Keychain. It is only as fresh as the
/// last row the running app wrote. A reading older than one refresh interval plus
/// reserve is emitted as `nil` / "unknown" — never as a current number. Same rule
/// as the pill (spec 18, 20, 25): an old value must not look live.
public enum UsageQuery {
    /// Matches `AppDelegate`'s refresh timer.
    public static let refreshInterval: TimeInterval = 5 * 60
    /// Slack for timer tolerance (30 s) plus a slow refresh.
    public static let freshnessReserve: TimeInterval = 90
    public static var staleAfter: TimeInterval { refreshInterval + freshnessReserve }

    public static func isStale(_ observedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(observedAt) > staleAfter
    }

    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    // MARK: - Status

    public struct LimitStatus: Equatable, Sendable {
        public let trackingID: String
        public let provider: Provider
        public let limitID: String
        public let label: String
        public let scope: LimitScope
        public let observedAt: Date
        /// `nil` when the reading is stale — the number still exists on the row,
        /// but it is not current.
        public let utilization: Double?
        public let resetsAt: Date?
        public let locked: LockState?
    }

    public struct AccountStatus: Equatable, Sendable {
        public let trackingID: String
        public let provider: Provider
        public let observedAt: Date
        public let limits: [LimitStatus]
    }

    public struct Status: Equatable, Sendable {
        /// Newest `observedAt` across every series, even if that row is stale.
        public let observedAt: Date?
        public let accounts: [AccountStatus]
    }

    public static func status(from latest: [UsageMeasurement], now: Date) -> Status {
        let limits = latest.map { limitStatus(from: $0, now: now) }
        let grouped = Dictionary(grouping: limits, by: \.trackingID)
        let accounts = grouped.keys.sorted().compactMap { trackingID -> AccountStatus? in
            guard let rows = grouped[trackingID], let first = rows.first else { return nil }
            let ordered = rows.sorted { $0.limitID < $1.limitID }
            let newest = ordered.map(\.observedAt).max() ?? first.observedAt
            return AccountStatus(
                trackingID: trackingID,
                provider: first.provider,
                observedAt: newest,
                limits: ordered
            )
        }
        .sorted { lhs, rhs in
            if lhs.provider != rhs.provider {
                return providerOrder(lhs.provider) < providerOrder(rhs.provider)
            }
            return lhs.trackingID < rhs.trackingID
        }
        return Status(observedAt: latest.map(\.observedAt).max(), accounts: accounts)
    }

    private static func limitStatus(from row: UsageMeasurement, now: Date) -> LimitStatus {
        let stale = isStale(row.observedAt, now: now)
        return LimitStatus(
            trackingID: row.trackingID,
            provider: row.provider,
            limitID: row.limitID,
            label: row.label,
            scope: row.scope,
            observedAt: row.observedAt,
            utilization: stale ? nil : row.utilization,
            resetsAt: stale ? nil : row.resetsAt,
            locked: stale ? nil : row.locked
        )
    }

    // MARK: - Pick

    /// The account with the most remaining room, or the earliest reset when none
    /// are usable. `trackingID == nil` means every candidate is blocked or stale.
    public struct Pick: Equatable, Sendable {
        public let trackingID: String?
        public let provider: Provider?
        public let utilization: Double?
        public let resetsAt: Date?
        public let observedAt: Date?

        public var found: Bool { trackingID != nil }
    }

    public static func pick(
        from latest: [UsageMeasurement],
        now: Date,
        provider: Provider? = nil
    ) -> Pick {
        let status = status(from: latest, now: now)
        let accounts = status.accounts.filter { provider == nil || $0.provider == provider }
        let observedAt = accounts.map(\.observedAt).max() ?? status.observedAt

        var usable: [(trackingID: String, provider: Provider, utilization: Double, resetsAt: Date?)] = []
        var blockedResets: [Date] = []

        for account in accounts {
            let accountLimits = account.limits.filter { $0.scope == .account }
            let fresh = accountLimits.filter { $0.utilization != nil && $0.locked != nil }
            guard !fresh.isEmpty else { continue }

            let worst = fresh.max { lhs, rhs in
                Limit.isLessUrgent(limit(from: lhs), limit(from: rhs))
            }!
            if isBlocked(worst) {
                if let resetsAt = worst.resetsAt { blockedResets.append(resetsAt) }
                continue
            }
            usable.append((
                trackingID: account.trackingID,
                provider: account.provider,
                utilization: worst.utilization!,
                resetsAt: worst.resetsAt
            ))
        }

        if let chosen = usable.min(by: { lhs, rhs in
            if lhs.utilization != rhs.utilization { return lhs.utilization < rhs.utilization }
            if lhs.trackingID != rhs.trackingID { return lhs.trackingID < rhs.trackingID }
            return lhs.provider.rawValue < rhs.provider.rawValue
        }) {
            return Pick(
                trackingID: chosen.trackingID,
                provider: chosen.provider,
                utilization: chosen.utilization,
                resetsAt: chosen.resetsAt,
                observedAt: observedAt
            )
        }

        return Pick(
            trackingID: nil,
            provider: nil,
            utilization: nil,
            resetsAt: blockedResets.min(),
            observedAt: observedAt
        )
    }

    private static func isBlocked(_ limit: LimitStatus) -> Bool {
        guard let utilization = limit.utilization, let locked = limit.locked else { return false }
        return locked == .locked || utilization >= 1
    }

    private static func limit(from status: LimitStatus) -> Limit {
        Limit(
            id: status.limitID,
            label: status.label,
            utilization: status.utilization ?? 0,
            resetsAt: status.resetsAt,
            locked: status.locked ?? .unknown,
            scope: status.scope
        )
    }

    private static func providerOrder(_ provider: Provider) -> Int {
        Provider.allCases.firstIndex(of: provider) ?? Provider.allCases.count
    }

    // MARK: - JSON

    public static func statusJSON(_ status: Status) throws -> Data {
        var root: [String: Any] = [
            "observedAt": status.observedAt.map(iso8601) ?? NSNull(),
        ]
        root["accounts"] = status.accounts.map { account -> [String: Any] in
            [
                "trackingID": account.trackingID,
                "provider": account.provider.rawValue,
                "observedAt": iso8601(account.observedAt),
                "limits": account.limits.map { limit -> [String: Any] in
                    [
                        "limitID": limit.limitID,
                        "label": limit.label,
                        "scope": limit.scope.rawValue,
                        "observedAt": iso8601(limit.observedAt),
                        "utilization": limit.utilization ?? NSNull(),
                        "resetsAt": limit.resetsAt.map(iso8601) ?? NSNull(),
                        "locked": limit.locked?.rawValue ?? NSNull(),
                    ]
                },
            ]
        }
        return try jsonData(root)
    }

    public static func pickJSON(_ pick: Pick) throws -> Data {
        let root: [String: Any] = [
            "trackingID": pick.trackingID ?? NSNull(),
            "provider": pick.provider?.rawValue ?? NSNull(),
            "utilization": pick.utilization ?? NSNull(),
            "resetsAt": pick.resetsAt.map(iso8601) ?? NSNull(),
            "observedAt": pick.observedAt.map(iso8601) ?? NSNull(),
        ]
        return try jsonData(root)
    }

    public static func achievementsJSON(
        _ achievements: [Achievements.Achievement],
        observedAt: Date?
    ) throws -> Data {
        let root: [String: Any] = [
            "observedAt": observedAt.map(iso8601) ?? NSNull(),
            "achievements": achievements.map { item -> [String: Any] in
                [
                    "kind": item.kind.rawValue,
                    "title": item.title,
                    "earnedAt": item.earnedAt.map(iso8601) ?? NSNull(),
                    "detail": item.detail,
                ]
            },
        ]
        return try jsonData(root)
    }

    private static func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])
    }
}