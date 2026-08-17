import Foundation

/// Turns what the four status pages send into one model. No network here.
///
/// Three of them run Statuspage and answer JSON. xAI does not: its page is
/// server-rendered HTML with no API, and the only machine-readable thing it
/// publishes is an RSS feed. Measured 2026-08-17.
public enum ServiceStatusParser {
    /// The top badge is not the answer. On 2026-08-17 Claude's page said
    /// `indicator: none` / "All Systems Operational" while an incident
    /// "Degraded performance for Claude Opus 5, Claude Sonnet 5" was still open.
    /// So the components and the incident list decide, and `status.indicator`
    /// is never read.
    public static func statuspageSummary(source: StatusSource, body: Data) -> StatusRead {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .unchecked(source: source, reason: "Status page did not answer JSON")
        }
        guard let rawComponents = JSONValue.array(root["components"]) else {
            return .unchecked(source: source, reason: "Status page listed no services")
        }
        let components = rawComponents.compactMap(component(from:))
        guard !components.isEmpty else {
            return .unchecked(source: source, reason: "Status page listed no services")
        }
        // `summary.json` carries the unresolved incidents. OpenAI's build drops
        // the key entirely — there the caller adds them from `incidents.json`.
        let incidents = (JSONValue.array(root["incidents"]) ?? [])
            .filter { !isResolved(JSONValue.string($0["status"])) }
            .compactMap(incident(from:))
        return .report(StatusReport(source: source, components: components, incidents: incidents))
    }

    /// OpenAI's `summary.json` has no `incidents` key and
    /// `incidents/unresolved.json` is a 404, so the open ones have to be sieved
    /// out of the full history. Those records carry no `components` array
    /// either: an OpenAI incident is page-wide as far as we can tell.
    public static func statuspageIncidents(body: Data) -> [StatusIncident]? {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = JSONValue.array(root["incidents"])
        else { return nil }
        return raw
            .filter { !isResolved(JSONValue.string($0["status"])) }
            .compactMap(incident(from:))
    }

    public static func adding(_ incidents: [StatusIncident], to read: StatusRead) -> StatusRead {
        guard case .report(let report) = read else { return read }
        return .report(StatusReport(
            source: report.source,
            components: report.components,
            incidents: report.incidents + incidents.filter { new in
                !report.incidents.contains { $0.id == new.id }
            }
        ))
    }

    /// xAI's feed. Every item is one incident on one service; the service slug
    /// is in the link (`https://status.x.ai/grok-com/INC…`).
    ///
    /// An item counts as closed only on positive evidence — a `resolved`
    /// category or `Status: RESOLVED` in the body. Anything else is open, so a
    /// vocabulary we have never seen errs towards showing a disruption instead
    /// of hiding one.
    ///
    /// The counterweight is `openWindow`: all 105 items in the feed are
    /// history, and if the markers ever change shape the whole archive would
    /// read as open. An incident nobody has resolved in a week is history too.
    public static func xAIFeed(body: Data, now: Date = Date(), openWindow: TimeInterval = 7 * 24 * 3600) -> StatusRead {
        guard let text = String(data: body, encoding: .utf8), text.contains("<item>") else {
            return .unchecked(source: .xAI, reason: "Status feed was not readable")
        }
        var incidents: [StatusIncident] = []
        for item in slices(of: text, between: "<item>", and: "</item>") {
            let categories = Set(tags(named: "category", in: item).map { $0.lowercased() })
            let statusLine = first(of: item, between: "<h3>Status:", and: "</h3>")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if categories.contains("resolved") || statusLine == "resolved" { continue }

            let published = tags(named: "pubDate", in: item).first.flatMap(rfc822)
            if let published, now.timeIntervalSince(published) > openWindow { continue }

            let link = tags(named: "link", in: item).first
            let rawTitle = tags(named: "title", in: item).first ?? "Incident"
            let id = tags(named: "guid", in: item).first ?? link ?? rawTitle
            let slug = link.flatMap(xAISlug)

            incidents.append(StatusIncident(
                id: id,
                title: unescapeXML(strippingServicePrefix(rawTitle)),
                stage: nil,
                startedAt: published,
                url: link.flatMap(URL.init(string:)),
                componentIDs: slug.map { [$0] } ?? [],
                componentNames: slug.map { [XAIServices.namesBySlug[$0] ?? $0] } ?? []
            ))
        }
        // The feed says nothing about a service that is merely slow, so the
        // component list is the static one and every entry reads operational.
        // Only incidents can put xAI into trouble.
        return .report(StatusReport(source: .xAI, components: XAIServices.components, incidents: incidents))
    }

    // MARK: - Statuspage pieces

    static func component(from raw: [String: Any]) -> StatusComponent? {
        // Statuspage groups are containers, not services. Their status is a
        // roll-up of the children, which are listed separately — counting both
        // would report one outage twice.
        if JSONValue.bool(raw["group"]) == true { return nil }
        guard let id = JSONValue.string(raw["id"]), let name = JSONValue.string(raw["name"]) else { return nil }
        return StatusComponent(id: id, name: name, health: health(JSONValue.string(raw["status"])))
    }

    static func health(_ raw: String?) -> ComponentHealth {
        switch raw {
        case "operational": .operational
        case "degraded_performance": .degraded
        case "partial_outage": .partialOutage
        case "major_outage": .majorOutage
        case "under_maintenance": .maintenance
        default: .unknown
        }
    }

    /// `postmortem` is Statuspage's word for "over, and written up". Only these
    /// two mean the user is no longer affected.
    static func isResolved(_ status: String?) -> Bool {
        status == "resolved" || status == "postmortem"
    }

    static func incident(from raw: [String: Any]) -> StatusIncident? {
        guard let id = JSONValue.string(raw["id"]), let name = JSONValue.string(raw["name"]) else { return nil }
        let components = JSONValue.array(raw["components"]) ?? []
        return StatusIncident(
            id: id,
            title: name,
            stage: JSONValue.string(raw["status"]),
            startedAt: DateParsing.iso8601(raw["started_at"]) ?? DateParsing.iso8601(raw["created_at"]),
            url: JSONValue.string(raw["shortlink"]).flatMap(URL.init(string:)),
            componentIDs: components.compactMap { JSONValue.string($0["id"]) },
            componentNames: components.compactMap { JSONValue.string($0["name"]) }
        )
    }

    // MARK: - Feed pieces

    static func xAISlug(_ link: String) -> String? {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        return parts.count >= 2 ? parts[0] : nil
    }

    /// `[Grok (Web)] Something broke` → `Something broke`. The service is
    /// already a column of its own; repeating it in the headline wastes the
    /// only line we have.
    static func strippingServicePrefix(_ title: String) -> String {
        guard title.hasPrefix("["), let close = title.firstIndex(of: "]") else { return title }
        let rest = title[title.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? title : rest
    }

    static func rfc822(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func unescapeXML(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func slices(of text: String, between open: String, and close: String) -> [String] {
        all(of: text, between: open, and: close)
    }

    /// Contents of every `<name …>…</name>`, attributes and all — `<guid
    /// isPermaLink="false">` is the one that has them, and matching on a bare
    /// `<guid>` would silently find nothing.
    private static func tags(named name: String, in text: String) -> [String] {
        var result: [String] = []
        var index = text.startIndex
        while let open = text.range(of: "<\(name)", range: index..<text.endIndex),
              let openEnd = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let close = text.range(of: "</\(name)>", range: openEnd.upperBound..<text.endIndex) {
            result.append(
                String(text[openEnd.upperBound..<close.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
            index = close.upperBound
        }
        return result
    }

    private static func first(of text: String, between open: String, and close: String) -> String? {
        all(of: text, between: open, and: close).first
    }

    private static func all(of text: String, between open: String, and close: String) -> [String] {
        var result: [String] = []
        var index = text.startIndex
        while let start = text.range(of: open, range: index..<text.endIndex),
              let end = text.range(of: close, range: start.upperBound..<text.endIndex) {
            result.append(String(text[start.upperBound..<end.lowerBound]))
            index = end.upperBound
        }
        return result
    }
}
