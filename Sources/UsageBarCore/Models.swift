import Foundation

public enum Provider: String, Sendable, CaseIterable {
    case claude
    case chatGPT
    case grok

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        case .grok: "Grok"
        }
    }
}

/// Whether the provider says work is currently blocked.
///
/// `.unknown` is a real value, not a missing one. Claude never sends a lock flag —
/// inventing one from `percent == 100` would pretend the API said something it did not.
public enum LockState: String, Sendable, Equatable {
    case locked
    case unlocked
    case unknown
}

/// What a full limit does to the user.
public enum LimitScope: String, Sendable, Equatable {
    /// Applies to the whole subscription. These drive the menu bar.
    case account
    /// Applies to one model or surface. Popover only — working on something else is fine.
    case model
}

/// The provider's own reading of how tight this limit is. Carried because it is free
/// and the provider knows its own thresholds better than we do.
public enum LimitSeverity: String, Sendable, Equatable {
    case normal
    case warning
    case critical
    case unknown
}

/// One limit, after translation into the common model.
public struct Limit: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    /// 0…1. The only quantity every provider can produce.
    public let utilization: Double
    public let resetsAt: Date?
    public let locked: LockState
    public let scope: LimitScope
    public let severity: LimitSeverity

    public init(
        id: String,
        label: String,
        utilization: Double,
        resetsAt: Date?,
        locked: LockState,
        scope: LimitScope,
        severity: LimitSeverity = .unknown
    ) {
        self.id = id
        self.label = label
        self.utilization = min(max(utilization, 0), 1)
        self.resetsAt = resetsAt
        self.locked = locked
        self.scope = scope
        self.severity = severity
    }

    public func prefixed(id prefix: String, label qualifier: String) -> Limit {
        Limit(
            id: "\(prefix)/\(id)",
            label: "\(qualifier) · \(label)",
            utilization: utilization,
            resetsAt: resetsAt,
            locked: locked,
            scope: scope,
            severity: severity
        )
    }
}

/// One successful reading from one provider.
public struct UsageSnapshot: Equatable, Sendable {
    public let provider: Provider
    /// Local display only (org name, plan). Never logged or committed.
    public let accountLabel: String?
    public let limits: [Limit]

    public init(provider: Provider, accountLabel: String? = nil, limits: [Limit]) {
        self.provider = provider
        self.accountLabel = accountLabel
        self.limits = limits
    }

    /// The limit the bar must show: a lock outranks any open number; among equals,
    /// higher utilization. Model-scoped limits stay out — a full Fable week does
    /// not mean the account is full.
    public var worstAccountLimit: Limit? {
        limits
            .filter { $0.scope == .account }
            .max(by: Limit.isLessUrgent)
    }
}

extension Limit {
    /// Lower urgency first. A lock outranks any open number (`unknown` counts as
    /// open — the provider did not say blocked). Among the same lock state,
    /// higher utilization wins; sooner reset breaks a further tie. Used only to
    /// pick "the worst" — never to drop a limit.
    static func isLessUrgent(_ lhs: Limit, _ rhs: Limit) -> Bool {
        if lhs.locked != rhs.locked {
            return lhs.locked != .locked && rhs.locked == .locked
        }
        if lhs.utilization != rhs.utilization {
            return lhs.utilization < rhs.utilization
        }
        switch (lhs.resetsAt, rhs.resetsAt) {
        case let (l?, r?):
            return l > r
        case (nil, _?):
            return true
        case (_?, nil):
            return false
        case (nil, nil):
            return false
        }
    }
}

public extension Array where Element == Limit {
    func sortedByUrgency() -> [Limit] {
        sorted { lhs, rhs in
            // Soonest reset first for the popover; undated last; higher utilization
            // breaks a date tie.
            switch (lhs.resetsAt, rhs.resetsAt) {
            case let (l?, r?) where l != r:
                return l < r
            case (nil, _?):
                return false
            case (_?, nil):
                return true
            default:
                return lhs.utilization > rhs.utilization
            }
        }
    }
}
