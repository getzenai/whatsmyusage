import Foundation

public enum BarTone: String, Sendable, Equatable {
    case idle
    case ok
    case warning
    case critical
    case expired
    case error
}

/// What the menu bar item itself shows. Derived here so the rule is unit-tested
/// and the AppKit target only paints.
public struct BarPresentation: Equatable, Sendable {
    public let title: String
    public let utilization: Double?
    public let tone: BarTone
    public let worst: Limit?
    public let provider: Provider?

    public init(title: String, utilization: Double?, tone: BarTone, worst: Limit? = nil, provider: Provider? = nil) {
        self.title = title
        self.utilization = utilization
        self.tone = tone
        self.worst = worst
        self.provider = provider
    }

    public static let idle = BarPresentation(title: "—", utilization: nil, tone: .idle)

    /// Pick the worst *account-scoped* limit across every successful snapshot.
    /// Expired or untrackable providers do not hide a real reading from another one.
    public static func of(outcomes: [UsageOutcome]) -> BarPresentation {
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
                tone: tone(for: worst),
                worst: worst,
                provider: owner
            )
        }

        if outcomes.contains(where: { if case .expired = $0 { true } else { false } }) {
            return BarPresentation(title: "login", utilization: nil, tone: .expired)
        }
        if outcomes.contains(where: {
            switch $0 {
            case .httpError, .notJSON, .empty: true
            default: false
            }
        }) {
            return BarPresentation(title: "!", utilization: nil, tone: .error)
        }
        return .idle
    }

    public static func percentString(_ utilization: Double) -> String {
        let pct = Int((utilization * 100).rounded())
        return "\(pct)%"
    }

    private static func tone(for limit: Limit) -> BarTone {
        if limit.locked == .locked { return .critical }
        if limit.utilization >= 0.9 { return .critical }
        if limit.utilization >= 0.7 { return .warning }
        return .ok
    }
}
