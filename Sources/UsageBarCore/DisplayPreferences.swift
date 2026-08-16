import Foundation

/// What the popover and pill show. Names stay on the card; this only hides
/// and reorders. Settings itself always lists everything.
public struct DisplayPreferences: Equatable, Sendable {
    public var hiddenLimitKeys: Set<String>
    public var hiddenAccountIDs: Set<String>
    public var accountOrder: [String]
    /// One slot for everything instead of one per account. The popover is unaffected.
    public var pill: PillStyle

    public init(
        hiddenLimitKeys: Set<String> = [],
        hiddenAccountIDs: Set<String> = [],
        accountOrder: [String] = [],
        pill: PillStyle = .perAccount
    ) {
        self.hiddenLimitKeys = hiddenLimitKeys
        self.hiddenAccountIDs = hiddenAccountIDs
        self.accountOrder = accountOrder
        self.pill = pill
    }

    public static func limitKey(trackingID: String, limitID: String) -> String {
        "\(trackingID)|\(limitID)"
    }

    public func isLimitVisible(trackingID: String, limitID: String) -> Bool {
        !hiddenLimitKeys.contains(Self.limitKey(trackingID: trackingID, limitID: limitID))
    }

    public func isAccountVisible(_ trackingID: String) -> Bool {
        !hiddenAccountIDs.contains(trackingID)
    }

    public mutating func toggleLimit(trackingID: String, limitID: String) {
        let key = Self.limitKey(trackingID: trackingID, limitID: limitID)
        if hiddenLimitKeys.contains(key) {
            hiddenLimitKeys.remove(key)
        } else {
            hiddenLimitKeys.insert(key)
        }
    }

    public mutating func toggleAccount(_ trackingID: String) {
        if hiddenAccountIDs.contains(trackingID) {
            hiddenAccountIDs.remove(trackingID)
        } else {
            hiddenAccountIDs.insert(trackingID)
        }
    }

    public mutating func move(trackingID: String, by delta: Int, among cards: [AccountCard]) {
        var ids = ordered(cards).map(\.trackingID)
        guard let index = ids.firstIndex(of: trackingID) else { return }
        let next = index + delta
        guard ids.indices.contains(next) else { return }
        ids.swapAt(index, next)
        accountOrder = ids
    }

    public mutating func move(from source: IndexSet, to destination: Int, among cards: [AccountCard]) {
        var ids = ordered(cards).map(\.trackingID)
        let moving = source.sorted().map { ids[$0] }
        for index in source.sorted().reversed() {
            ids.remove(at: index)
        }
        let dest = min(max(0, destination - source.filter { $0 < destination }.count), ids.count)
        ids.insert(contentsOf: moving, at: dest)
        accountOrder = ids
    }

    /// Cards for the popover and the pill. Hidden rows stay in Settings.
    public func applied(to cards: [AccountCard]) -> [AccountCard] {
        let visible = cards.compactMap { card -> AccountCard? in
            guard isAccountVisible(card.trackingID) else { return nil }
            let limits = card.limits.filter { isLimitVisible(trackingID: card.trackingID, limitID: $0.id) }
            if limits.isEmpty && card.message == nil { return nil }
            return card.displaying(limits: limits)
        }
        return ordered(visible)
    }

    public func ordered(_ cards: [AccountCard]) -> [AccountCard] {
        var rank: [String: Int] = [:]
        for (index, id) in accountOrder.enumerated() {
            rank[id] = index
        }
        return cards.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.trackingID] ?? (1_000 + lhs.offset)
            let right = rank[rhs.element.trackingID] ?? (1_000 + rhs.offset)
            return left < right
        }.map(\.element)
    }
}
