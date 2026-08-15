import Foundation

public enum BarTone: String, Sendable, Equatable {
    case idle
    case ok
    case warning
    case critical
    case expired
    case error
}

/// One slot in the menu-bar pill. One tracking, one colour.
public struct BarSegment: Equatable, Sendable, Identifiable {
    public var id: String { trackingID }
    public let trackingID: String
    public let provider: Provider
    public let name: String
    public let utilization: Double?
    public let tone: BarTone

    public init(
        trackingID: String,
        provider: Provider,
        name: String,
        utilization: Double?,
        tone: BarTone
    ) {
        self.trackingID = trackingID
        self.provider = provider
        self.name = name
        self.utilization = utilization
        self.tone = tone
    }
}

/// One account in the popover: header once, then every limit.
public struct AccountCard: Equatable, Sendable, Identifiable {
    public var id: String { trackingID }
    public let trackingID: String
    public let provider: Provider
    public let defaultName: String
    public let limits: [Limit]
    public let tone: BarTone
    public let utilization: Double?
    public let message: String?

    public init(
        trackingID: String,
        provider: Provider,
        defaultName: String,
        limits: [Limit],
        tone: BarTone,
        utilization: Double?,
        message: String? = nil
    ) {
        self.trackingID = trackingID
        self.provider = provider
        self.defaultName = defaultName
        self.limits = limits
        self.tone = tone
        self.utilization = utilization
        self.message = message
    }

    public var segment: BarSegment {
        BarSegment(
            trackingID: trackingID,
            provider: provider,
            name: defaultName,
            utilization: utilization,
            tone: tone
        )
    }
}

/// Days and hours until reset — the date itself makes the user do the arithmetic.
public enum ResetFormatting {
    public static func remaining(until date: Date, now: Date = Date()) -> String {
        let interval = date.timeIntervalSince(now)
        if interval <= 0 { return "resetting" }

        let totalMinutes = Int(interval / 60)
        let totalHours = totalMinutes / 60
        let days = totalHours / 24
        let hours = totalHours % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
        }
        if totalHours > 0 {
            return minutes > 0 ? "in \(totalHours)h \(minutes)m" : "in \(totalHours)h"
        }
        if minutes > 0 { return "in \(minutes)m" }
        return "in <1m"
    }
}

/// What the menu bar item itself shows. Derived here so the rule is unit-tested
/// and the AppKit target only paints.
public struct BarPresentation: Equatable, Sendable {
    public let title: String
    public let utilization: Double?
    public let tone: BarTone
    public let worst: Limit?
    public let provider: Provider?
    public let segments: [BarSegment]
    public let cards: [AccountCard]

    public init(
        title: String,
        utilization: Double?,
        tone: BarTone,
        worst: Limit? = nil,
        provider: Provider? = nil,
        segments: [BarSegment] = [],
        cards: [AccountCard] = []
    ) {
        self.title = title
        self.utilization = utilization
        self.tone = tone
        self.worst = worst
        self.provider = provider
        self.segments = segments
        self.cards = cards
    }

    public static let idle = BarPresentation(title: "—", utilization: nil, tone: .idle)

    /// Group snapshots into one card per tracking. Every Grok window — Fast,
    /// Expert, week — belongs to the same account.
    public static func cards(from outcomes: [UsageOutcome]) -> [AccountCard] {
        var byProvider: [Provider: [UsageOutcome]] = [:]
        for outcome in outcomes {
            if case .snapshot(let snap) = outcome {
                byProvider[snap.provider, default: []].append(outcome)
            }
        }
        return cards(byProvider: byProvider)
    }

    public static func cards(byProvider: [Provider: [UsageOutcome]]) -> [AccountCard] {
        var result: [AccountCard] = []
        for provider in Provider.allCases {
            guard let outcomes = byProvider[provider], !outcomes.isEmpty else { continue }
            let snapshots = outcomes.compactMap { outcome -> UsageSnapshot? in
                if case .snapshot(let snap) = outcome { return snap }
                return nil
            }

            if provider == .grok {
                let limits = snapshots.flatMap(\.limits)
                if !limits.isEmpty {
                    let name = snapshots.compactMap(\.accountLabel).first ?? provider.displayName
                    result.append(liveCard(
                        trackingID: "grok",
                        provider: provider,
                        name: name,
                        limits: limits
                    ))
                    continue
                }
            } else if !snapshots.isEmpty {
                for snap in snapshots {
                    result.append(liveCard(
                        trackingID: snap.trackingID,
                        provider: snap.provider,
                        name: snap.accountLabel ?? snap.provider.displayName,
                        limits: snap.limits
                    ))
                }
                continue
            }

            if let failed = failureCard(provider: provider, outcomes: outcomes) {
                result.append(failed)
            }
        }
        return result
    }

    /// Pick the worst *account-scoped* limit across every successful snapshot.
    /// Expired or untrackable providers do not hide a real reading from another one.
    public static func of(outcomes: [UsageOutcome]) -> BarPresentation {
        of(cards: cards(from: outcomes), outcomes: outcomes)
    }

    public static func of(byProvider: [Provider: [UsageOutcome]]) -> BarPresentation {
        let flat = Provider.allCases.flatMap { byProvider[$0] ?? [] }
        return of(cards: cards(byProvider: byProvider), outcomes: flat)
    }

    private static func of(cards: [AccountCard], outcomes: [UsageOutcome]) -> BarPresentation {
        let segments = cards.map(\.segment)
        let snapshots = outcomes.compactMap { outcome -> UsageSnapshot? in
            if case .snapshot(let s) = outcome { return s }
            return nil
        }
        let worst = snapshots
            .compactMap(\.worstAccountLimit)
            .max(by: Limit.isLessUrgent)

        if let worst {
            let owner = snapshots.first { snap in snap.limits.contains(worst) }?.provider
            return BarPresentation(
                title: percentString(worst.utilization),
                utilization: worst.utilization,
                tone: tone(of: worst),
                worst: worst,
                provider: owner,
                segments: segments,
                cards: cards
            )
        }

        if cards.contains(where: { $0.tone == .expired })
            || outcomes.contains(where: { if case .expired = $0 { true } else { false } }) {
            return BarPresentation(
                title: "login",
                utilization: nil,
                tone: .expired,
                segments: segments,
                cards: cards
            )
        }
        if outcomes.contains(where: {
            switch $0 {
            case .httpError, .notJSON, .empty: true
            default: false
            }
        }) || cards.contains(where: { $0.tone == .error }) {
            return BarPresentation(title: "!", utilization: nil, tone: .error, segments: segments, cards: cards)
        }
        return cards.isEmpty
            ? .idle
            : BarPresentation(title: "—", utilization: nil, tone: .idle, segments: segments, cards: cards)
    }

    public static func percentString(_ utilization: Double) -> String {
        let pct = Int((utilization * 100).rounded())
        return "\(pct)%"
    }

    public static func tone(of limit: Limit) -> BarTone {
        if limit.locked == .locked { return .critical }
        if limit.utilization >= 0.9 { return .critical }
        if limit.utilization >= 0.7 { return .warning }
        return .ok
    }

    private static func liveCard(
        trackingID: String,
        provider: Provider,
        name: String,
        limits: [Limit]
    ) -> AccountCard {
        let worst = limits.filter { $0.scope == .account }.max(by: Limit.isLessUrgent)
        return AccountCard(
            trackingID: trackingID,
            provider: provider,
            defaultName: name,
            limits: limits.sortedByUrgency(),
            tone: worst.map(tone(of:)) ?? .idle,
            utilization: worst?.utilization
        )
    }

    private static func failureCard(provider: Provider, outcomes: [UsageOutcome]) -> AccountCard? {
        if outcomes.contains(where: { if case .expired = $0 { true } else { false } }) {
            return AccountCard(
                trackingID: provider.rawValue,
                provider: provider,
                defaultName: provider.displayName,
                limits: [],
                tone: .expired,
                utilization: nil,
                message: "Sign-in expired"
            )
        }
        if outcomes.contains(where: { if case .notTrackable = $0 { true } else { false } }) {
            let message = outcomes.compactMap { outcome -> String? in
                if case .notTrackable(let message) = outcome { return message }
                return nil
            }.first
            return AccountCard(
                trackingID: provider.rawValue,
                provider: provider,
                defaultName: provider.displayName,
                limits: [],
                tone: .error,
                utilization: nil,
                message: message.map { "Not trackable: \($0)" } ?? "Not trackable"
            )
        }
        if outcomes.contains(where: {
            switch $0 {
            case .httpError, .notJSON, .empty: true
            default: false
            }
        }) {
            let message: String
            if outcomes.contains(where: { if case .httpError(let status) = $0 { return status < 0 } else { return false } }) {
                message = "Network error"
            } else if let status = outcomes.compactMap({ outcome -> Int? in
                if case .httpError(let status) = outcome { return status }
                return nil
            }).first {
                message = "HTTP \(status)"
            } else if outcomes.contains(where: { if case .notJSON = $0 { true } else { false } }) {
                message = "Response was not JSON"
            } else {
                message = "No limits in the response"
            }
            return AccountCard(
                trackingID: provider.rawValue,
                provider: provider,
                defaultName: provider.displayName,
                limits: [],
                tone: .error,
                utilization: nil,
                message: message
            )
        }
        return nil
    }
}
