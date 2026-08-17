import Foundation
import Testing
@testable import UsageBarCore

/// Shapes measured from the four live pages on 2026-08-17, with placeholder
/// ids and names. No account, no key, no live number is in here.
private enum StatusFixtures {
    /// Statuspage v2 `summary.json`. The badge says everything is fine and an
    /// incident is open at the same time — the case that killed reading the
    /// badge. Also carries a group, which is a container and not a service.
    static let claudeGreenBadgeOpenIncident = """
    {
      "page": {"id": "pageid", "name": "Claude"},
      "status": {"indicator": "none", "description": "All Systems Operational"},
      "components": [
        {"id": "c-web", "name": "claude.ai", "status": "operational", "group": false},
        {"id": "c-code", "name": "Claude Code", "status": "degraded_performance", "group": false},
        {"id": "c-console", "name": "Claude Console (platform.claude.com)", "status": "operational", "group": false},
        {"id": "g-all", "name": "Everything", "status": "degraded_performance", "group": true}
      ],
      "incidents": [
        {
          "id": "inc1",
          "name": "Degraded performance for two models",
          "status": "monitoring",
          "impact": "minor",
          "started_at": "2026-08-17T09:12:00.000Z",
          "shortlink": "https://stspg.io/example",
          "components": [{"id": "c-code", "name": "Claude Code"}]
        },
        {
          "id": "inc0",
          "name": "Yesterday's thing",
          "status": "resolved",
          "impact": "major",
          "started_at": "2026-08-16T09:12:00.000Z",
          "components": [{"id": "c-web", "name": "claude.ai"}]
        }
      ],
      "scheduled_maintenances": []
    }
    """

    /// OpenAI's build: no `incidents` key at all. Two components share the name
    /// "Login" — that is the page, not a typo here.
    static let openAISummaryWithoutIncidents = """
    {
      "page": {"id": "pageid", "name": "OpenAI"},
      "status": {"indicator": "none", "description": "All Systems Operational"},
      "components": [
        {"id": "o-chat", "name": "Chat Completions", "status": "operational"},
        {"id": "o-login-a", "name": "Login", "status": "operational"},
        {"id": "o-login-b", "name": "Login", "status": "operational"}
      ]
    }
    """

    /// `incidents.json`: the full history, no `components`, no `started_at`.
    static let openAIIncidents = """
    {
      "page": {"id": "pageid", "name": "OpenAI"},
      "incidents": [
        {"id": "oi1", "name": "Elevated errors", "status": "investigating", "impact": "minor",
         "created_at": "2026-08-17T10:00:00Z"},
        {"id": "oi0", "name": "Older thing", "status": "resolved", "impact": "minor",
         "created_at": "2026-08-13T10:00:00Z", "resolved_at": "2026-08-13T23:58:22Z"},
        {"id": "oi-post", "name": "Written up", "status": "postmortem", "impact": "major",
         "created_at": "2026-08-10T10:00:00Z"}
      ]
    }
    """

    static let githubOutage = """
    {
      "page": {"id": "pageid", "name": "GitHub"},
      "status": {"indicator": "major", "description": "Partial System Outage"},
      "components": [
        {"id": "gh-actions", "name": "Actions", "status": "major_outage", "group": false},
        {"id": "gh-pages", "name": "Pages", "status": "degraded_performance", "group": false},
        {"id": "gh-packages", "name": "Packages", "status": "operational", "group": false}
      ],
      "incidents": [
        {"id": "ghi1", "name": "Incident with GitHub.com", "status": "investigating",
         "impact": "critical", "started_at": "2026-08-17T13:40:03.620Z",
         "shortlink": "https://stspg.io/example",
         "components": [{"id": "gh-actions", "name": "Actions"}]}
      ]
    }
    """

    /// xAI's RSS. One open item, one resolved, one open but ancient. The guid
    /// carries an attribute — a match on a bare `<guid>` finds nothing.
    static func xAIFeed(openPublished: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" ?>
        <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
          <channel>
            <title>xAI System Status</title>
            <atom:link href="https://status.x.ai/feed.xml" rel="self" type="application/rss+xml" />
            <ttl>30</ttl>
            <item>
              <title>[Grok (Web)] Chat replies are failing &amp; slow</title>
              <link>https://status.x.ai/grok-com/INCopen1</link>
              <guid isPermaLink="false">INCopen1</guid>
              <description><![CDATA[
                   <h3>Status: INVESTIGATING</h3>
                   <p>Severity: disruption</p>
              ]]></description>
              <pubDate>\(openPublished)</pubDate>
              <category>disruption</category>
              <category>investigating</category>
            </item>
            <item>
              <title>[API (us-west-2.api.x.ai)] Lower success rate</title>
              <link>https://status.x.ai/api-us-west-2/INCdone1</link>
              <guid isPermaLink="false">INCdone1</guid>
              <description><![CDATA[
                   <h3>Status: RESOLVED</h3>
                   <p>Severity: available</p>
              ]]></description>
              <pubDate>Tue, 07 Jul 2026 15:40:26 GMT</pubDate>
              <category>available</category>
              <category>resolved</category>
            </item>
            <item>
              <title>[Grok (iOS)] Something nobody ever closed</title>
              <link>https://status.x.ai/ios-app/INCstale</link>
              <guid isPermaLink="false">INCstale</guid>
              <description><![CDATA[<h3>Status: INVESTIGATING</h3>]]></description>
              <pubDate>Mon, 06 Jul 2026 10:00:00 GMT</pubDate>
              <category>disruption</category>
              <category>investigating</category>
            </item>
          </channel>
        </rss>
        """
    }
}

private func report(_ read: StatusRead) throws -> StatusReport {
    guard case .report(let report) = read else {
        Issue.record("expected a report, got \(read)")
        throw StatusMismatch()
    }
    return report
}

private struct StatusMismatch: Error {}

private func summary(_ source: StatusSource, _ json: String) -> StatusRead {
    ServiceStatusParser.statuspageSummary(source: source, body: Data(json.utf8))
}

@Suite("Status page parsing")
struct ServiceStatusParserTests {

    /// The one that decides the whole design: `indicator: none` next to an open
    /// incident. Measured on status.claude.com, 2026-08-17.
    @Test func openIncidentSurvivesAGreenBadge() throws {
        let parsed = try report(summary(.claude, StatusFixtures.claudeGreenBadgeOpenIncident))
        #expect(parsed.incidents.map(\.id) == ["inc1"])
        #expect(parsed.incidents[0].componentIDs == ["c-code"])
        #expect(parsed.incidents[0].stage == "monitoring")
        #expect(parsed.incidents[0].url?.absoluteString == "https://stspg.io/example")
    }

    /// A group is a roll-up of the services beneath it, and those are listed
    /// too. Counting both reports one outage twice.
    @Test func groupsAreNotServices() throws {
        let parsed = try report(summary(.claude, StatusFixtures.claudeGreenBadgeOpenIncident))
        #expect(parsed.components.map(\.id) == ["c-web", "c-code", "c-console"])
        #expect(parsed.components[1].health == .degraded)
    }

    @Test func resolvedAndPostmortemAreOver() {
        #expect(ServiceStatusParser.isResolved("resolved"))
        #expect(ServiceStatusParser.isResolved("postmortem"))
        #expect(!ServiceStatusParser.isResolved("monitoring"))
        #expect(!ServiceStatusParser.isResolved(nil))
    }

    /// A word we have never seen is not a promise that things are fine.
    @Test func unknownComponentWordIsTrouble() {
        #expect(ServiceStatusParser.health("hyperspace_reroute") == .unknown)
        #expect(ComponentHealth.unknown.isTrouble)
        #expect(!ComponentHealth.operational.isTrouble)
        #expect(!ComponentHealth.maintenance.isTrouble)
    }

    @Test func garbageIsUncheckedNotHealthy() {
        guard case .unchecked = summary(.claude, "<html>nope</html>") else {
            Issue.record("HTML must not read as a healthy page")
            return
        }
        guard case .unchecked = summary(.claude, #"{"page": {"id": "x"}}"#) else {
            Issue.record("a page with no services must not read as healthy")
            return
        }
    }

    @Test func openAIIncidentsComeFromTheSeparateList() throws {
        let base = summary(.openAI, StatusFixtures.openAISummaryWithoutIncidents)
        #expect(try report(base).incidents.isEmpty)
        let extra = try #require(ServiceStatusParser.statuspageIncidents(body: Data(StatusFixtures.openAIIncidents.utf8)))
        #expect(extra.map(\.id) == ["oi1"])
        // No `started_at` in that build — `created_at` is the fallback.
        #expect(extra[0].startedAt != nil)
        #expect(extra[0].componentIDs.isEmpty)

        let merged = try report(ServiceStatusParser.adding(extra, to: base))
        #expect(merged.incidents.map(\.id) == ["oi1"])
        #expect(merged.components.count == 3)

        // Merging the same list twice must not double the incident.
        let again = try report(ServiceStatusParser.adding(extra, to: .report(merged)))
        #expect(again.incidents.count == 1)
    }

    @Test func feedKeepsOnlyWhatIsOpenAndRecent() throws {
        let now = ServiceStatusParser.rfc822("Mon, 17 Aug 2026 12:00:00 GMT")!
        let published = "Mon, 17 Aug 2026 09:30:00 GMT"
        let parsed = try report(ServiceStatusParser.xAIFeed(
            body: Data(StatusFixtures.xAIFeed(openPublished: published).utf8),
            now: now
        ))
        #expect(parsed.incidents.map(\.id) == ["INCopen1"])
        #expect(parsed.incidents[0].componentIDs == ["grok-com"])
        #expect(parsed.incidents[0].componentNames == [XAIServices.grokWeb])
        // The service is a column of its own; the prefix would waste the line.
        #expect(parsed.incidents[0].title == "Chat replies are failing & slow")
        #expect(parsed.incidents[0].startedAt == ServiceStatusParser.rfc822(published))
    }

    /// The feed carries no health, only incidents. Its component list is the
    /// static one, so Settings has something to tick.
    @Test func feedReportsNoDegradation() throws {
        let now = ServiceStatusParser.rfc822("Mon, 17 Aug 2026 12:00:00 GMT")!
        let parsed = try report(ServiceStatusParser.xAIFeed(
            body: Data(StatusFixtures.xAIFeed(openPublished: "Mon, 17 Aug 2026 09:30:00 GMT").utf8),
            now: now
        ))
        #expect(parsed.components.allSatisfy { $0.health == .operational })
        #expect(parsed.components.contains { $0.id == "grok-com" })
    }

    @Test func aFeedThatIsNotAFeedIsUnchecked() {
        guard case .unchecked(let source, _) = ServiceStatusParser.xAIFeed(body: Data("<html/>".utf8)) else {
            Issue.record("an empty feed must not read as healthy")
            return
        }
        #expect(source == .xAI)
    }

    @Test func servicePrefixIsStrippedOnlyWhenThereIsOne() {
        #expect(ServiceStatusParser.strippingServicePrefix("[Grok (Web)] Boom") == "Boom")
        #expect(ServiceStatusParser.strippingServicePrefix("No brackets here") == "No brackets here")
        #expect(ServiceStatusParser.strippingServicePrefix("[Only a service]") == "[Only a service]")
    }
}

@Suite("Status digest")
struct StatusDigestTests {
    private let checkedAt = Date(timeIntervalSince1970: 1_787_000_000)

    private func digest(
        _ reads: [StatusRead],
        _ prefs: StatusPreferences = StatusPreferences()
    ) -> StatusDigest {
        StatusDigest.of(reads: reads, preferences: prefs, checkedAt: checkedAt)
    }

    private var claudeRead: StatusRead {
        summary(.claude, StatusFixtures.claudeGreenBadgeOpenIncident)
    }

    private var githubRead: StatusRead {
        summary(.github, StatusFixtures.githubOutage)
    }

    @Test func theMasterSwitchLeavesNothingBehind() {
        let off = digest([claudeRead], StatusPreferences(enabled: false))
        #expect(off == .off)
        #expect(off.line() == nil)
        #expect(off.banner(for: .claude) == nil)
    }

    /// Claude Code is watched by default, and it is the one the incident names.
    @Test func defaultWatchListCatchesTheDefaultIncident() throws {
        let entry = try #require(digest([claudeRead]).entry(for: .claude))
        #expect(entry.state == .trouble)
        #expect(entry.headline == "Degraded performance for two models")
        #expect(entry.degraded.map(\.name) == ["Claude Code"])
    }

    /// Untick the affected service and the same page reads quiet — that is the
    /// whole point of the component list.
    @Test func untickingTheAffectedServiceSilencesIt() throws {
        var prefs = StatusPreferences()
        prefs.watchedComponentIDs[.claude] = ["c-web"]
        let entry = try #require(digest([claudeRead], prefs).entry(for: .claude))
        #expect(entry.state == .ok)
    }

    /// OpenAI never names a component. Treating that as "not mine" is how a
    /// real outage disappears, so it counts for whatever is ticked.
    @Test func anIncidentWithoutComponentsAlwaysCounts() throws {
        let base = summary(.openAI, StatusFixtures.openAISummaryWithoutIncidents)
        let extra = try #require(ServiceStatusParser.statuspageIncidents(body: Data(StatusFixtures.openAIIncidents.utf8)))
        var prefs = StatusPreferences()
        prefs.watchedComponentIDs[.openAI] = ["o-chat"]
        let entry = try #require(digest([ServiceStatusParser.adding(extra, to: base)], prefs).entry(for: .openAI))
        #expect(entry.state == .trouble)
        #expect(entry.headline == "Elevated errors")
    }

    /// A service the page has invented since we last looked is not a service
    /// the user decided to ignore.
    @Test func anIncidentOnAnUnlistedServiceStillCounts() throws {
        let json = """
        {"page": {"id": "p"},
         "components": [{"id": "c-web", "name": "claude.ai", "status": "operational"}],
         "incidents": [{"id": "i", "name": "Trouble on something new", "status": "investigating",
                        "components": [{"id": "c-brandnew", "name": "Claude Something"}]}]}
        """
        var prefs = StatusPreferences()
        prefs.watchedComponentIDs[.claude] = ["c-web"]
        let entry = try #require(digest([summary(.claude, json)], prefs).entry(for: .claude))
        #expect(entry.state == .trouble)
    }

    /// A degraded service nobody declared an incident for is still a reason the
    /// work is not going through.
    @Test func degradationWithoutAnIncidentIsTrouble() throws {
        let json = """
        {"page": {"id": "p"},
         "status": {"indicator": "none", "description": "All Systems Operational"},
         "components": [{"id": "c-code", "name": "Claude Code", "status": "partial_outage"}],
         "incidents": []}
        """
        let entry = try #require(digest([summary(.claude, json)]).entry(for: .claude))
        #expect(entry.state == .trouble)
        #expect(entry.headline == "Partial outage: Claude Code")
    }

    @Test func silenceIsNeverHealth() throws {
        let read = StatusRead.unchecked(source: .xAI, reason: "Status page unreachable")
        // Claude's own trouble is already a banner on its card, so the line is
        // free to carry the thing that has nowhere else to go: a page we could
        // not read. It must never turn into "no incidents".
        let line = try #require(digest([claudeRead, read]).line())
        #expect(line.tone == .unchecked)
        #expect(line.text == "Status unchecked · xAI")

        let quiet = try #require(digest([read]).line())
        #expect(quiet.tone == .unchecked)
        #expect(quiet.text == "Status unchecked · xAI")
    }

    @Test func theQuietLineIsOnlyATime() throws {
        let json = """
        {"page": {"id": "p"}, "status": {"indicator": "none", "description": "All Systems Operational"},
         "components": [{"id": "c-web", "name": "claude.ai", "status": "operational"}], "incidents": []}
        """
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        let line = try #require(digest([summary(.claude, json)]).line(formatter: formatter))
        #expect(line.tone == .quiet)
        #expect(line.text == "No incidents · checked \(formatter.string(from: checkedAt))")
    }

    /// GitHub hangs on no account, so its incident can only be read here.
    @Test func theHomelessSourceGetsTheWholeLine() throws {
        let line = try #require(digest([githubRead]).line())
        #expect(line.tone == .trouble)
        #expect(line.text == "GitHub: Incident with GitHub.com")
    }

    /// Two troubles, one of them GitHub's: the line has to name both, because
    /// GitHub has no card to be named on.
    @Test func severalTroublesCollapseToNames() throws {
        let line = try #require(digest([claudeRead, githubRead]).line())
        #expect(line.text == "Incidents · Claude, GitHub")
    }

    /// Claude alone is already shown as a banner on its card. Repeating it
    /// would be noise — but "No incidents" would be false, so what is left is
    /// the time.
    @Test func aBanneredTroubleShrinksTheLineToTheTime() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        let line = try #require(digest([claudeRead]).line(formatter: formatter))
        #expect(line.tone == .quiet)
        #expect(line.text == "Checked \(formatter.string(from: checkedAt))")
    }

    @Test func onlyTheAffectedAccountGetsABannerAndADot() throws {
        let cards = [
            AccountCard(trackingID: "claude:a", provider: .claude, defaultName: "Work",
                        limits: [], tone: .ok, utilization: 0.2),
            AccountCard(trackingID: "claude:b", provider: .claude, defaultName: "Private",
                        limits: [], tone: .ok, utilization: 0.2),
            AccountCard(trackingID: "chatgpt:a", provider: .chatGPT, defaultName: "ChatGPT",
                        limits: [], tone: .ok, utilization: 0.2),
        ]
        let result = digest([claudeRead, githubRead])
        #expect(result.banner(for: .claude) != nil)
        #expect(result.banner(for: .chatGPT) == nil)
        // Every Claude login is behind the same claude.ai.
        #expect(result.dottedTrackingIDs(cards: cards) == ["claude:a", "claude:b"])
        #expect(result.dotsCompactSlot(cards: cards))
    }

    /// GitHub is nobody's account: it must not put a dot on a pill slot.
    @Test func aHomelessIncidentDoesNotDotThePill() {
        let cards = [AccountCard(trackingID: "claude:a", provider: .claude, defaultName: "Work",
                                 limits: [], tone: .ok, utilization: 0.2)]
        #expect(digest([githubRead]).dottedTrackingIDs(cards: cards).isEmpty)
    }

    /// An unchecked page is not a disrupted one — no banner, no dot, one line.
    @Test func uncheckedNeverPaintsTheCard() {
        let result = digest([.unchecked(source: .claude, reason: "Status page answered HTTP 503")])
        #expect(result.banner(for: .claude) == nil)
        #expect(result.dottedTrackingIDs(cards: []).isEmpty)
    }

    @Test func aSourceTheUserSwitchedOffIsNotInTheDigest() {
        var prefs = StatusPreferences()
        prefs.setEnabled(false, for: .github)
        #expect(digest([claudeRead, githubRead], prefs).entry(for: .github) == nil)
        #expect(prefs.isEnabled(.claude))
    }
}

@Suite("Status preferences")
struct StatusPreferencesTests {
    private let components = [
        StatusComponent(id: "c-web", name: "claude.ai", health: .operational),
        StatusComponent(id: "c-code", name: "Claude Code", health: .operational),
        StatusComponent(id: "c-console", name: "Claude Console (platform.claude.com)", health: .operational),
    ]

    @Test func defaultsResolveByNameNotByID() throws {
        let watched = try #require(StatusPreferences().watched(.claude, among: components))
        #expect(watched == ["c-web", "c-code"])
    }

    /// A page that renamed everything we know must fall back to watching all of
    /// it. Watching nothing would be silent.
    @Test func renamedAwayDefaultsWatchEverything() {
        let renamed = [StatusComponent(id: "x", name: "Something else entirely", health: .operational)]
        #expect(StatusPreferences().watched(.claude, among: renamed) == nil)
    }

    /// OpenAI has no default: 25 services, two of them called "Login", and
    /// incidents that name none of them.
    @Test func openAIHasNoDefaultNarrowing() {
        #expect(StatusPreferences().watched(.openAI, among: components) == nil)
        #expect(!StatusDefaults.hasDefault(.openAI))
    }

    @Test func tickingStartsFromWhatIsShownAsTicked() {
        var prefs = StatusPreferences()
        // Starts at the default {c-web, c-code}; ticking the third adds it.
        prefs.toggleComponent("c-console", for: .claude, among: components)
        #expect(prefs.watchedComponentIDs[.claude] == ["c-web", "c-code", "c-console"])
        prefs.toggleComponent("c-web", for: .claude, among: components)
        #expect(prefs.watchedComponentIDs[.claude] == ["c-code", "c-console"])
    }

    /// A source with no default starts fully ticked, so the first click has to
    /// remove one rather than leaving one.
    @Test func tickingASourceWithoutDefaultsStartsFromAll() {
        var prefs = StatusPreferences()
        prefs.toggleComponent("c-web", for: .openAI, among: components)
        #expect(prefs.watchedComponentIDs[.openAI] == ["c-code", "c-console"])
    }

    @Test func everySourceMapsToTheAccountItBelongsTo() {
        #expect(StatusSource.claude.provider == .claude)
        #expect(StatusSource.openAI.provider == .chatGPT)
        #expect(StatusSource.xAI.provider == .grok)
        #expect(StatusSource.github.provider == nil)
    }

    /// The feed only ever gives slugs; these are the names beside them.
    @Test func xAIDefaultsAreGrokWebAndSignOn() throws {
        let watched = try #require(StatusPreferences().watched(.xAI, among: XAIServices.components))
        #expect(watched == ["grok-com", "single-sign-on"])
    }
}
