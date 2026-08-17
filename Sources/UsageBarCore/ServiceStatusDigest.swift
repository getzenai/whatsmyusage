import Foundation

/// The reads, the preferences and the clock turned into the three things the
/// UI paints: a line under the accounts, a banner on a card, a dot in a slot.
/// Derived here so every rule is a unit test and AppKit only draws.
public struct StatusDigest: Equatable, Sendable {
    public enum State: String, Sendable, Equatable {
        case ok
        case trouble
        /// We asked and got nothing usable. Never rendered as health.
        case unchecked
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { source.rawValue }
        public let source: StatusSource
        public let state: State
        /// One line a human can act on: what is wrong, and where.
        public let headline: String?
        public let incidents: [StatusIncident]
        /// Watched components that are not operational, incident or not.
        public let degraded: [StatusComponent]

        public init(
            source: StatusSource,
            state: State,
            headline: String? = nil,
            incidents: [StatusIncident] = [],
            degraded: [StatusComponent] = []
        ) {
            self.source = source
            self.state = state
            self.headline = headline
            self.incidents = incidents
            self.degraded = degraded
        }
    }

    public let entries: [Entry]
    public let checkedAt: Date?

    public init(entries: [Entry], checkedAt: Date?) {
        self.entries = entries
        self.checkedAt = checkedAt
    }

    public static let off = StatusDigest(entries: [], checkedAt: nil)

    /// Build from what came back. Sources the user switched off are not in
    /// `reads` at all — there was no request to make.
    public static func of(
        reads: [StatusRead],
        preferences: StatusPreferences,
        checkedAt: Date?
    ) -> StatusDigest {
        guard preferences.enabled else { return .off }
        let entries = StatusSource.allCases.compactMap { source -> Entry? in
            guard preferences.isEnabled(source) else { return nil }
            guard let read = reads.first(where: { $0.source == source }) else { return nil }
            return entry(for: read, preferences: preferences)
        }
        return StatusDigest(entries: entries, checkedAt: entries.isEmpty ? nil : checkedAt)
    }

    static func entry(for read: StatusRead, preferences: StatusPreferences) -> Entry {
        switch read {
        case .unchecked(let source, let reason):
            return Entry(source: source, state: .unchecked, headline: reason)
        case .report(let report):
            let watched = preferences.watched(report.source, among: report.components)
            let degraded = report.components.filter { component in
                component.health.isTrouble && (watched?.contains(component.id) ?? true)
            }
            let known = Set(report.components.map(\.id))
            let incidents = report.incidents.filter { incident in
                guard let watched else { return true }
                // A page that does not say which service is affected is telling
                // us it might be any of them. Counting that as "not my
                // component" is how a real outage disappears.
                guard !incident.componentIDs.isEmpty else { return true }
                if incident.componentIDs.contains(where: watched.contains) { return true }
                // A service the page has invented since we last looked at it is
                // not a service the user decided to ignore.
                return incident.componentIDs.contains { !known.contains($0) }
            }
            guard !incidents.isEmpty || !degraded.isEmpty else {
                return Entry(source: report.source, state: .ok)
            }
            return Entry(
                source: report.source,
                state: .trouble,
                headline: headline(incidents: incidents, degraded: degraded),
                incidents: incidents,
                degraded: degraded
            )
        }
    }

    /// The incident's own words first — the page wrote them for a human. The
    /// component list is the fallback for a degradation nobody declared.
    static func headline(incidents: [StatusIncident], degraded: [StatusComponent]) -> String? {
        if let first = incidents.first {
            let more = incidents.count - 1
            return more > 0 ? "\(first.title) (+\(more) more)" : first.title
        }
        guard !degraded.isEmpty else { return nil }
        let names = degraded.map(\.name).joined(separator: ", ")
        let worst = degraded.map(\.health).max(by: { rank($0) < rank($1) }) ?? .unknown
        return "\(worst.label.capitalizedFirst): \(names)"
    }

    private static func rank(_ health: ComponentHealth) -> Int {
        switch health {
        case .operational, .maintenance: 0
        case .degraded: 1
        case .partialOutage: 2
        case .unknown: 3
        case .majorOutage: 4
        }
    }

    // MARK: - What the UI asks

    public func entry(for source: StatusSource) -> Entry? {
        entries.first { $0.source == source }
    }

    /// The banner for one account card. Only real trouble earns a banner;
    /// "unchecked" belongs in the one line at the bottom, not on every card.
    public func banner(for provider: Provider) -> Entry? {
        entries.first { $0.source.provider == provider && $0.state == .trouble }
    }

    /// Trackings whose pill slot gets a dot.
    public func dottedTrackingIDs(cards: [AccountCard]) -> Set<String> {
        let providers = Set(entries.filter { $0.state == .trouble }.compactMap(\.source.provider))
        guard !providers.isEmpty else { return [] }
        return Set(cards.filter { providers.contains($0.provider) }.map(\.trackingID))
    }

    /// True when the compact pill — one slot for everything — should carry a dot.
    public func dotsCompactSlot(cards: [AccountCard]) -> Bool {
        !dottedTrackingIDs(cards: cards).isEmpty
    }

    public enum LineTone: String, Sendable, Equatable {
        case quiet
        case trouble
        case unchecked
    }

    public struct Line: Equatable, Sendable {
        public let text: String
        public let tone: LineTone

        public init(text: String, tone: LineTone) {
            self.text = text
            self.tone = tone
        }
    }

    /// The single line above the popover footer. Nil when the feature is off —
    /// then the popover looks exactly like it did before.
    ///
    /// Trouble that belongs to no account (GitHub) can only be seen here, so it
    /// speaks first. A quiet line carries the time and nothing else: a standing
    /// "All Systems Operational" is read once and then never again, and the
    /// outage gets skipped with it.
    public func line(now: Date = Date(), formatter: DateFormatter = Self.timeFormatter) -> Line? {
        guard !entries.isEmpty else { return nil }

        let troubled = entries.filter { $0.state == .trouble }
        let homeless = troubled.filter { $0.source.provider == nil }
        if let only = homeless.first, troubled.count == 1 {
            // Nowhere else to show it: this source has no card of its own.
            let text = only.headline.map { "\(only.source.displayName): \($0)" }
                ?? "\(only.source.displayName) has an incident"
            return Line(text: text, tone: .trouble)
        }
        if !homeless.isEmpty {
            let names = troubled.map(\.source.displayName).joined(separator: ", ")
            return Line(text: "Incidents · \(names)", tone: .trouble)
        }

        let unchecked = entries.filter { $0.state == .unchecked }
        if !unchecked.isEmpty {
            let names = unchecked.map(\.source.displayName).joined(separator: ", ")
            return Line(text: "Status unchecked · \(names)", tone: .unchecked)
        }

        guard let checkedAt else { return Line(text: "Status unchecked", tone: .unchecked) }
        // Every remaining trouble already has a banner on its own card, one
        // scroll up. Repeating it here would be noise — but "No incidents"
        // would be a lie, so the line shrinks to the time it was checked.
        guard troubled.isEmpty else {
            return Line(text: "Checked \(formatter.string(from: checkedAt))", tone: .quiet)
        }
        return Line(text: "No incidents · checked \(formatter.string(from: checkedAt))", tone: .quiet)
    }

    public static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
