import Foundation
import Testing
@testable import UsageBarCore

private let origin = Date(timeIntervalSince1970: 1_800_000_000)

private func row(
    trackingID: String,
    limitID: String,
    utilization: Double,
    provider: Provider = .claude,
    locked: LockState = .unknown,
    scope: LimitScope = .account,
    label: String? = nil,
    resetsAt: Date? = origin.addingTimeInterval(3 * 3600),
    minutesAgo: Double = 1,
    now: Date = origin
) -> UsageMeasurement {
    UsageMeasurement(
        observedAt: now.addingTimeInterval(-minutesAgo * 60),
        provider: provider,
        trackingID: trackingID,
        limitID: limitID,
        label: label ?? limitID,
        utilization: utilization,
        resetsAt: resetsAt,
        locked: locked,
        scope: scope,
        severity: .normal
    )
}

private func berlinCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

@Suite("HumanStatus")
struct HumanStatusTests {
    @Test func pickLeadsAndUUIDsStayOut() {
        let now = origin
        let latest = [
            row(
                trackingID: "3d9b381c-aaaa-bbbb",
                limitID: "weekly_all",
                utilization: 0.92,
                label: "Week",
                now: now
            ),
            row(
                trackingID: "aaaa1111-bbbb-cccc",
                limitID: "weekly_all",
                utilization: 0.41,
                label: "Week",
                now: now
            ),
        ]
        let status = UsageQuery.status(from: latest, now: now)
        let pick = UsageQuery.pick(from: latest, now: now)
        let text = HumanStatus.render(
            status: status,
            pick: pick,
            names: HumanStatus.Names(custom: [
                "3d9b381c-aaaa-bbbb": "Claude Max Zen AI",
                "aaaa1111-bbbb-cccc": "Claude Team",
            ]),
            now: now,
            showLimits: false,
            calendar: berlinCalendar()
        )
        #expect(text.hasPrefix("Use Claude Team — 41% Week"))
        #expect(!text.contains("3d9b381c-aaaa-bbbb"))
        #expect(!text.contains("aaaa1111-bbbb-cccc"))
        #expect(!text.contains("unknown"))
        #expect(text.contains("opens 12:00"))
    }

    @Test func lockedUnknownIsNotPrinted() {
        let now = origin
        let latest = [
            row(
                trackingID: "acct-1",
                limitID: "weekly_all",
                utilization: 0.2,
                locked: .unknown,
                label: "Week",
                now: now
            ),
        ]
        let status = UsageQuery.status(from: latest, now: now)
        let text = HumanStatus.render(
            status: status,
            pick: UsageQuery.pick(from: latest, now: now),
            names: HumanStatus.Names(defaults: ["acct-1": "Claude Max"]),
            now: now,
            showLimits: false,
            calendar: berlinCalendar()
        )
        #expect(!text.contains("locked"))
        #expect(!text.contains("unknown"))
    }

    @Test func lockedIsPrintedWhenTheProviderSentIt() {
        let now = origin
        let latest = [
            row(
                trackingID: "acct-1",
                limitID: "weekly_all",
                utilization: 1,
                provider: .grok,
                locked: .locked,
                label: "2-hour",
                now: now
            ),
        ]
        let status = UsageQuery.status(from: latest, now: now)
        let text = HumanStatus.render(
            status: status,
            pick: UsageQuery.pick(from: latest, now: now),
            names: HumanStatus.Names(defaults: ["acct-1": "Grok"]),
            now: now,
            showLimits: false,
            calendar: berlinCalendar()
        )
        #expect(text.contains("locked"))
        #expect(text.contains("No account has room"))
    }

    @Test func staleLeadsWithWhatToDoAndDoesNotLookEmpty() {
        let now = origin
        let staleMinutes = (UsageQuery.staleAfter / 60) + 2
        let latest = [
            row(
                trackingID: "acct-1",
                limitID: "weekly_all",
                utilization: 0.1,
                label: "Week",
                minutesAgo: staleMinutes,
                now: now
            ),
        ]
        let status = UsageQuery.status(from: latest, now: now)
        let text = HumanStatus.render(
            status: status,
            pick: UsageQuery.pick(from: latest, now: now),
            names: HumanStatus.Names(custom: ["acct-1": "Claude Max Zen AI"]),
            now: now,
            showLimits: false,
            calendar: berlinCalendar()
        )
        #expect(text.contains("Open WhatsMyUsage so it can refresh."))
        #expect(text.contains("Claude Max Zen AI"))
        #expect(!text.contains("unknown"))
        #expect(!text.contains("0%"))
        #expect(!text.contains("10%"))
    }

    @Test func extraLimitsAppearWhenTheyDisagree() {
        let now = origin
        let latest = [
            row(
                trackingID: "acct-1",
                limitID: "weekly_all",
                utilization: 0.2,
                label: "Week",
                now: now
            ),
            row(
                trackingID: "acct-1",
                limitID: "fable",
                utilization: 1,
                locked: .unknown,
                scope: .model,
                label: "Fable",
                now: now
            ),
        ]
        let status = UsageQuery.status(from: latest, now: now)
        let text = HumanStatus.render(
            status: status,
            pick: UsageQuery.pick(from: latest, now: now),
            names: HumanStatus.Names(defaults: ["acct-1": "Claude Max"]),
            now: now,
            showLimits: false,
            calendar: berlinCalendar()
        )
        #expect(text.contains("Fable"))
        #expect(text.contains("100%"))
    }

    @Test func limitsFlagPrintsEveryFreshLimit() {
        let now = origin
        let latest = [
            row(
                trackingID: "acct-1",
                limitID: "weekly_all",
                utilization: 0.2,
                label: "Week",
                now: now
            ),
            row(
                trackingID: "acct-1",
                limitID: "five_hour",
                utilization: 0.1,
                label: "5-hour",
                now: now
            ),
        ]
        let status = UsageQuery.status(from: latest, now: now)
        let hidden = HumanStatus.render(
            status: status,
            pick: UsageQuery.pick(from: latest, now: now),
            names: HumanStatus.Names(defaults: ["acct-1": "Claude Max"]),
            now: now,
            showLimits: false,
            calendar: berlinCalendar()
        )
        let shown = HumanStatus.render(
            status: status,
            pick: UsageQuery.pick(from: latest, now: now),
            names: HumanStatus.Names(defaults: ["acct-1": "Claude Max"]),
            now: now,
            showLimits: true,
            calendar: berlinCalendar()
        )
        #expect(!hidden.contains("5-hour"))
        #expect(shown.contains("5-hour"))
    }

    @Test func emptyLogDoesNotClaimEveryAccountIsFull() {
        let status = UsageQuery.status(from: [], now: origin)
        let text = HumanStatus.render(
            status: status,
            pick: UsageQuery.pick(from: [], now: origin),
            names: HumanStatus.Names(),
            now: origin,
            showLimits: false,
            calendar: berlinCalendar()
        )
        #expect(text == "No readings in the log.")
        #expect(!text.contains("No account has room"))
    }

    @Test func hiddenLimitsStayOutOfTheTextEvenWhenTheyDisagree() {
        let now = origin
        let latest = [
            row(
                trackingID: "acct-1",
                limitID: "weekly_all",
                utilization: 0.2,
                label: "Week",
                now: now
            ),
            row(
                trackingID: "acct-1",
                limitID: "weekly_scoped:Fable",
                utilization: 1,
                locked: .unknown,
                scope: .model,
                label: "Week · Fable",
                now: now
            ),
        ]
        let prefs = DisplayPreferences(
            hiddenLimitKeys: [DisplayPreferences.limitKey(
                trackingID: "acct-1",
                limitID: "weekly_scoped:Fable"
            )]
        )
        let text = HumanStatus.render(
            status: UsageQuery.status(from: latest, now: now),
            pick: UsageQuery.pick(from: latest, now: now),
            names: HumanStatus.Names(defaults: ["acct-1": "Claude Max"]),
            now: now,
            showLimits: true,
            preferences: prefs,
            calendar: berlinCalendar()
        )
        #expect(!text.contains("Fable"))
        #expect(text.contains("Week"))
        // Hidden Fable still blocks pick — hiding is display, not safety.
        #expect(text.contains("No account has room"))
    }

    @Test func agePhraseFloorsAndKeepsMinutesPastAnHour() {
        let now = origin
        #expect(HumanStatus.agePhrase(from: now.addingTimeInterval(-6 * 60), now: now) == "6m")
        #expect(HumanStatus.agePhrase(from: now.addingTimeInterval(-16 * 60), now: now) == "16m")
        #expect(HumanStatus.agePhrase(from: now.addingTimeInterval(-41 * 60), now: now) == "41m")
        #expect(HumanStatus.agePhrase(from: now.addingTimeInterval(-(2 * 3600 + 60)), now: now) == "2h 1m")
        #expect(HumanStatus.agePhrase(from: now.addingTimeInterval(-24 * 3600), now: now) == "24h")
        #expect(HumanStatus.agePhrase(from: now.addingTimeInterval(-(2 * 3600 + 20 * 60)), now: now) == "2h 20m")
    }

    @Test func staleSentenceUsesMinutesNotRoundedUpHours() {
        let now = origin
        let staleMinutes = (UsageQuery.staleAfter / 60) + 2
        let latest = [
            row(
                trackingID: "acct-1",
                limitID: "weekly_all",
                utilization: 0.1,
                label: "Week",
                minutesAgo: staleMinutes,
                now: now
            ),
        ]
        let text = HumanStatus.render(
            status: UsageQuery.status(from: latest, now: now),
            pick: UsageQuery.pick(from: latest, now: now),
            names: HumanStatus.Names(custom: ["acct-1": "Claude Max Zen AI"]),
            now: now,
            showLimits: false,
            calendar: berlinCalendar()
        )
        #expect(text.contains("Readings are \(Int(staleMinutes))m old."))
        #expect(!text.contains("1h old"))
        #expect(!text.contains("h old"))
    }
}
