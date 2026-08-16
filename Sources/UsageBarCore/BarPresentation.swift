import Foundation

/// Four living steps, hottest last. Red is reserved for the wall — at 95 % there is
/// still work left, and painting that the same colour as a locked account hid the
/// only difference that changes what you do next.
public enum BarTone: String, Sendable, Equatable {
    case idle
    case ok
    case warning
    case critical
    /// Locked, or the meter is full. Nothing left to spend.
    case blocked
    case expired
    case error
}

/// How many slots the menu-bar pill paints.
public enum PillStyle: String, Sendable, Equatable, CaseIterable {
    /// One slot per account, in the order Settings sets.
    case perAccount
    /// A single slot for every account at once.
    case compact
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
    /// Count of unused reset vouchers. Nil means hide the line — never 0.
    public let resetAvailable: Int?

    public init(
        trackingID: String,
        provider: Provider,
        defaultName: String,
        limits: [Limit],
        tone: BarTone,
        utilization: Double?,
        message: String? = nil,
        resetAvailable: Int? = nil
    ) {
        self.trackingID = trackingID
        self.provider = provider
        self.defaultName = defaultName
        self.limits = limits
        self.tone = tone
        self.utilization = utilization
        self.message = message
        self.resetAvailable = resetAvailable.flatMap { $0 >= 1 ? $0 : nil }
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

    /// Rebuild tone from the limits that are still visible. A hidden Fable
    /// week must not keep painting the slot red.
    public func displaying(limits visible: [Limit]) -> AccountCard {
        let worst = visible.filter { $0.scope == .account }.max(by: Limit.isLessUrgent)
        return AccountCard(
            trackingID: trackingID,
            provider: provider,
            defaultName: defaultName,
            limits: visible,
            tone: worst.map(BarPresentation.tone(of:)) ?? (message == nil ? .idle : tone),
            utilization: worst?.utilization,
            message: message,
            resetAvailable: resetAvailable
        )
    }

    public func withResetAvailable(_ count: Int?) -> AccountCard {
        AccountCard(
            trackingID: trackingID,
            provider: provider,
            defaultName: defaultName,
            limits: limits,
            tone: tone,
            utilization: utilization,
            message: message,
            resetAvailable: count
        )
    }

    public var resetAvailableLabel: String? {
        resetAvailable.flatMap(ResetRead.label(for:))
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

            let failures = outcomes.filter { outcome in
                if case .snapshot = outcome { return false }
                return true
            }

            if provider == .grok {
                let grouped = Dictionary(grouping: snapshots, by: \.trackingID)
                for trackingID in grouped.keys.sorted() {
                    let group = grouped[trackingID] ?? []
                    let limits = group.flatMap(\.limits)
                    if !limits.isEmpty {
                        let name = group.compactMap(\.accountLabel).first ?? provider.displayName
                        result.append(liveCard(
                            trackingID: trackingID,
                            provider: provider,
                            name: name,
                            limits: limits
                        ))
                    }
                    for snap in group {
                        if let card = diagnosticCard(snap) {
                            result.append(card)
                        }
                    }
                }
            } else {
                for snap in snapshots {
                    if let card = diagnosticCard(snap) {
                        result.append(card)
                    } else {
                        result.append(liveCard(
                            trackingID: snap.trackingID,
                            provider: snap.provider,
                            name: snap.accountLabel ?? snap.provider.displayName,
                            limits: snap.limits
                        ))
                    }
                }
            }

            if let failed = failureCard(provider: provider, outcomes: failures) {
                result.append(uniqued(failed, among: result))
            }
        }
        return result
    }

    /// Pick the worst *account-scoped* limit across every successful snapshot.
    /// Expired or untrackable providers do not hide a real reading from another one.
    public static func of(outcomes: [UsageOutcome], pill: PillStyle = .perAccount) -> BarPresentation {
        of(cards: cards(from: outcomes), outcomes: outcomes, pill: pill)
    }

    public static func of(byProvider: [Provider: [UsageOutcome]], pill: PillStyle = .perAccount) -> BarPresentation {
        let flat = Provider.allCases.flatMap { byProvider[$0] ?? [] }
        return of(cards: cards(byProvider: byProvider), outcomes: flat, pill: pill)
    }

    /// Already-filtered cards (hidden limits removed, order applied).
    /// Worst, tone, and title come from the cards — not from a second copy of
    /// the outcomes. Empty outcomes here used to paint "idle" while two
    /// accounts were locked.
    public static func showing(_ cards: [AccountCard], pill: PillStyle = .perAccount) -> BarPresentation {
        of(cards: cards, outcomes: [], pill: pill)
    }

    /// Per account, the limit that comes back soonest. The model carries no window
    /// length, only a reset time, so "shortest window" means "next to reset" —
    /// a session limit outranks a week for as long as the week is further away.
    /// Model-scoped limits stay out, as everywhere else.
    public static func shortestWindowLimits(_ cards: [AccountCard]) -> [Limit] {
        cards.compactMap { card in
            card.limits
                .filter { $0.scope == .account }
                .min(by: comesBackSooner)
        }
    }

    /// What the compact pill measures: the mean of those limits. Nil when no account
    /// has a usable reading — an average over nothing would paint a colour from air.
    public static func averageOfShortestWindows(_ cards: [AccountCard]) -> Double? {
        let limits = shortestWindowLimits(cards)
        guard !limits.isEmpty else { return nil }
        return limits.reduce(0) { $0 + $1.utilization } / Double(limits.count)
    }

    /// The single slot of the compact pill, or nil when there is nothing to show.
    public static func compactSegment(_ cards: [AccountCard]) -> BarSegment? {
        guard let first = cards.first else { return nil }
        let limits = shortestWindowLimits(cards)
        guard let average = averageOfShortestWindows(cards) else {
            // No reading anywhere: keep the failure visible instead of a green slot.
            let tone: BarTone = cards.contains { $0.tone == .expired } ? .expired
                : cards.contains { $0.tone == .error } ? .error
                : .idle
            return BarSegment(
                trackingID: compactTrackingID,
                provider: first.provider,
                name: compactName,
                utilization: nil,
                tone: tone
            )
        }
        // A lock is blocked work, wherever it sits. Grok's week can be locked while
        // its two-hour window — the shortest one, the one the average is built
        // from — is half empty; a green slot would then paint over a wall.
        let blocked = cards
            .flatMap(\.limits)
            .contains { $0.scope == .account && $0.locked == .locked }
        let tone: BarTone = blocked ? .blocked : toneOf(utilization: average)
        return BarSegment(
            trackingID: compactTrackingID,
            provider: first.provider,
            name: compactName,
            utilization: average,
            tone: tone
        )
    }

    public static let compactTrackingID = "compact"
    public static let compactName = "All accounts"

    /// Sooner reset first; undated last; a date tie goes to the fuller limit.
    private static func comesBackSooner(_ lhs: Limit, _ rhs: Limit) -> Bool {
        switch (lhs.resetsAt, rhs.resetsAt) {
        case let (l?, r?) where l != r: return l < r
        case (nil, _?): return false
        case (_?, nil): return true
        default: return lhs.utilization > rhs.utilization
        }
    }

    private static func of(cards: [AccountCard], outcomes: [UsageOutcome], pill: PillStyle = .perAccount) -> BarPresentation {
        let segments = pill == .compact
            ? [compactSegment(cards)].compactMap { $0 }
            : cards.map(\.segment)
        let worst = cards
            .flatMap(\.limits)
            .filter { $0.scope == .account }
            .max(by: Limit.isLessUrgent)

        if let worst {
            let owner = cards.first { $0.limits.contains(worst) }?.provider
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

    /// Fill fraction for a bar. Extra credit above 100 % must not paint past the track.
    public static func filledFraction(_ utilization: Double) -> Double {
        min(1, max(0, utilization))
    }

    public static func tone(of limit: Limit) -> BarTone {
        if limit.locked == .locked { return .blocked }
        return toneOf(utilization: limit.utilization)
    }

    /// A provider that never sends a lock state — Claude — still hits the wall at
    /// 100 %, so full counts as blocked even when `locked` stays unknown.
    public static func toneOf(utilization: Double) -> BarTone {
        if utilization >= 1 { return .blocked }
        if utilization >= 0.9 { return .critical }
        if utilization >= 0.7 { return .warning }
        return .ok
    }

    private static func diagnosticCard(_ snap: UsageSnapshot) -> AccountCard? {
        guard let diagnostic = snap.diagnostic, snap.limits.isEmpty else { return nil }
        let expired = diagnostic == "Sign-in expired"
        return AccountCard(
            trackingID: snap.trackingID,
            provider: snap.provider,
            defaultName: snap.accountLabel ?? snap.provider.displayName,
            limits: [],
            tone: expired ? .expired : .error,
            utilization: nil,
            message: diagnostic
        )
    }

    private static func uniqued(_ card: AccountCard, among existing: [AccountCard]) -> AccountCard {
        guard existing.contains(where: { $0.trackingID == card.trackingID }) else { return card }
        return AccountCard(
            trackingID: card.trackingID + ":error",
            provider: card.provider,
            defaultName: card.defaultName,
            limits: card.limits,
            tone: card.tone,
            utilization: card.utilization,
            message: card.message,
            resetAvailable: card.resetAvailable
        )
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
