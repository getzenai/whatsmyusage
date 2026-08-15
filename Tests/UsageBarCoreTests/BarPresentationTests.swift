import Foundation
import Testing
@testable import UsageBarCore

@Suite("BarPresentation")
struct BarPresentationTests {

    @Test func worstAccountLimitWinsAcrossProviders() {
        let claude = UsageOutcome.snapshot(UsageSnapshot(provider: .claude, limits: [
            Limit(id: "session", label: "5 hours", utilization: 0, resetsAt: nil, locked: .unknown, scope: .account),
            Limit(id: "weekly_all", label: "Week", utilization: 1, resetsAt: nil, locked: .unknown, scope: .account),
            Limit(id: "model", label: "Week · X", utilization: 1, resetsAt: nil, locked: .unknown, scope: .model),
        ]))
        let grok = UsageOutcome.snapshot(UsageSnapshot(provider: .grok, limits: [
            Limit(id: "fast", label: "2 hours · fast", utilization: 0, resetsAt: nil, locked: .unlocked, scope: .account),
        ]))

        let bar = BarPresentation.of(outcomes: [claude, grok])
        #expect(bar.title == "100%")
        #expect(bar.tone == .critical)
        #expect(bar.worst?.id == "weekly_all")
        #expect(bar.provider == .claude)
    }

    @Test func grokWeeklyBeatsEmptyTwoHourWindows() {
        let windows = UsageOutcome.snapshot(UsageSnapshot(provider: .grok, limits: [
            Limit(id: "fast", label: "2 hours · fast", utilization: 0, resetsAt: nil, locked: .unlocked, scope: .account),
            Limit(id: "expert", label: "2 hours · expert", utilization: 0, resetsAt: nil, locked: .unlocked, scope: .account),
        ]))
        let weekly = UsageOutcome.snapshot(UsageSnapshot(provider: .grok, limits: [
            Limit(
                id: "weekly",
                label: "Week",
                utilization: 0.37,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                locked: .unknown,
                scope: .account
            ),
        ]))
        let bar = BarPresentation.of(outcomes: [windows, weekly])
        #expect(bar.title == "37%")
        #expect(bar.tone == .ok)
        #expect(bar.worst?.id == "weekly")
        #expect(bar.provider == .grok)
    }

    @Test func modelLimitCannotPaintTheBar() {
        let snap = UsageOutcome.snapshot(UsageSnapshot(provider: .claude, limits: [
            Limit(id: "weekly_all", label: "Week", utilization: 0.2, resetsAt: nil, locked: .unknown, scope: .account),
            Limit(id: "model", label: "Week · X", utilization: 1, resetsAt: nil, locked: .unknown, scope: .model),
        ]))
        let bar = BarPresentation.of(outcomes: [snap])
        #expect(bar.title == "20%")
        #expect(bar.tone == .ok)
    }

    @Test func chatGPTLockPaintsCriticalEvenBelowNinety() {
        let snap = UsageOutcome.snapshot(UsageSnapshot(provider: .chatGPT, limits: [
            Limit(id: "primary", label: "Week", utilization: 0.5, resetsAt: nil, locked: .locked, scope: .account),
        ]))
        let bar = BarPresentation.of(outcomes: [snap])
        #expect(bar.tone == .critical)
        #expect(bar.title == "50%")
    }

    /// Locked ChatGPT at 40% must beat open Claude at 80%. Utilization-first
    /// ranking hid the lock behind a merely high open number.
    @Test func lockedProviderBeatsHigherOpenUtilization() {
        let claude = UsageOutcome.snapshot(UsageSnapshot(provider: .claude, limits: [
            Limit(id: "weekly_all", label: "Week", utilization: 0.8, resetsAt: nil, locked: .unknown, scope: .account),
        ]))
        let chatGPT = UsageOutcome.snapshot(UsageSnapshot(provider: .chatGPT, limits: [
            Limit(id: "primary", label: "Week", utilization: 0.4, resetsAt: nil, locked: .locked, scope: .account),
        ]))

        for outcomes in [[claude, chatGPT], [chatGPT, claude]] {
            let bar = BarPresentation.of(outcomes: outcomes)
            #expect(bar.title == "40%")
            #expect(bar.tone == .critical)
            #expect(bar.provider == .chatGPT)
            #expect(bar.worst?.locked == .locked)
        }
    }

    /// Claude is always `.unknown`. Treating that as different from `.unlocked`
    /// made the first input win and hid Grok at 90% behind Claude at 10%.
    @Test func unknownAndUnlockedDeferToUtilizationRegardlessOfOrder() {
        let claude = UsageOutcome.snapshot(UsageSnapshot(provider: .claude, limits: [
            Limit(id: "weekly_all", label: "Week", utilization: 0.1, resetsAt: nil, locked: .unknown, scope: .account),
        ]))
        let grok = UsageOutcome.snapshot(UsageSnapshot(provider: .grok, limits: [
            Limit(id: "fast", label: "2 hours · fast", utilization: 0.9, resetsAt: nil, locked: .unlocked, scope: .account),
        ]))

        for outcomes in [[claude, grok], [grok, claude]] {
            let bar = BarPresentation.of(outcomes: outcomes)
            #expect(bar.title == "90%")
            #expect(bar.tone == .critical)
            #expect(bar.provider == .grok)
        }
    }

    @Test func expiredDoesNotHideARealReading() {
        let snap = UsageOutcome.snapshot(UsageSnapshot(provider: .grok, limits: [
            Limit(id: "fast", label: "2 hours · fast", utilization: 0.1, resetsAt: nil, locked: .unlocked, scope: .account),
        ]))
        let bar = BarPresentation.of(outcomes: [.expired, snap])
        #expect(bar.title == "10%")
        #expect(bar.tone == .ok)
    }

    @Test func onlyExpiredShowsLogin() {
        let bar = BarPresentation.of(outcomes: [.expired, .notTrackable(message: "x")])
        #expect(bar.title == "login")
        #expect(bar.tone == .expired)
    }

    @Test func nothingConfiguredIsIdle() {
        #expect(BarPresentation.of(outcomes: []) == .idle)
    }

    @Test func warningBand() {
        let snap = UsageOutcome.snapshot(UsageSnapshot(provider: .claude, limits: [
            Limit(id: "weekly_all", label: "Week", utilization: 0.75, resetsAt: nil, locked: .unknown, scope: .account),
        ]))
        #expect(BarPresentation.of(outcomes: [snap]).tone == .warning)
    }

    @Test func urgencySortPutsSoonestResetFirstAndUndatedLast() {
        let soon = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)
        let limits = [
            Limit(id: "c", label: "c", utilization: 0.9, resetsAt: nil, locked: .unknown, scope: .account),
            Limit(id: "b", label: "b", utilization: 0.1, resetsAt: later, locked: .unknown, scope: .account),
            Limit(id: "a", label: "a", utilization: 0.2, resetsAt: soon, locked: .unknown, scope: .account),
        ]
        #expect(limits.sortedByUrgency().map(\.id) == ["a", "b", "c"])
    }

    @Test func noAccountLimitMeansNoWorst() {
        let snap = UsageSnapshot(provider: .claude, limits: [
            Limit(id: "m", label: "m", utilization: 1, resetsAt: nil, locked: .unknown, scope: .model),
        ])
        #expect(snap.worstAccountLimit == nil)
        #expect(BarPresentation.of(outcomes: [.snapshot(snap)]).tone == .idle)
    }

    @Test func pillHasOneSegmentPerAccountNotOnePercent() {
        let claude = UsageOutcome.snapshot(UsageSnapshot(
            provider: .claude,
            trackingID: "claude:org-a",
            accountLabel: "Org A",
            limits: [
                Limit(id: "week", label: "Week", utilization: 0.14, resetsAt: nil, locked: .unknown, scope: .account),
            ]
        ))
        let chatGPT = UsageOutcome.snapshot(UsageSnapshot(provider: .chatGPT, limits: [
            Limit(id: "primary", label: "Week", utilization: 1, resetsAt: nil, locked: .locked, scope: .account),
        ]))
        let grok = UsageOutcome.snapshot(UsageSnapshot(provider: .grok, limits: [
            Limit(id: "weekly", label: "Week", utilization: 0.21, resetsAt: nil, locked: .unknown, scope: .account),
        ]))

        let bar = BarPresentation.of(outcomes: [claude, chatGPT, grok])
        #expect(bar.segments.map(\.provider) == [.claude, .chatGPT, .grok])
        #expect(bar.segments.map(\.tone) == [.ok, .critical, .ok])
        #expect(bar.segments[0].name == "Org A")
        // Dominant title stays the worst reading — the pill is the segments.
        #expect(bar.title == "100%")
        #expect(bar.tone == .critical)
    }

    @Test func twoClaudeOrgsAreTwoSegments() {
        let a = UsageOutcome.snapshot(UsageSnapshot(
            provider: .claude,
            trackingID: "claude:a",
            accountLabel: "A",
            limits: [Limit(id: "w", label: "Week", utilization: 0.1, resetsAt: nil, locked: .unknown, scope: .account)]
        ))
        let b = UsageOutcome.snapshot(UsageSnapshot(
            provider: .claude,
            trackingID: "claude:b",
            accountLabel: "B",
            limits: [Limit(id: "w", label: "Week", utilization: 0.9, resetsAt: nil, locked: .unknown, scope: .account)]
        ))
        let bar = BarPresentation.of(outcomes: [a, b])
        #expect(bar.segments.count == 2)
        #expect(bar.segments.map(\.trackingID) == ["claude:a", "claude:b"])
        #expect(bar.segments.map(\.tone) == [.ok, .critical])
    }

    @Test func grokWindowsMergeIntoOneCard() {
        let fast = UsageOutcome.snapshot(UsageSnapshot(
            provider: .grok,
            accountLabel: "fast",
            limits: [Limit(id: "fast", label: "Fast · 2 hours", utilization: 0, resetsAt: nil, locked: .unlocked, scope: .account)]
        ))
        let weekly = UsageOutcome.snapshot(UsageSnapshot(provider: .grok, limits: [
            Limit(id: "weekly", label: "Week", utilization: 0.21, resetsAt: nil, locked: .unknown, scope: .account),
        ]))
        let cards = BarPresentation.cards(from: [fast, weekly])
        #expect(cards.count == 1)
        #expect(cards[0].provider == .grok)
        #expect(cards[0].trackingID == "grok")
        #expect(Set(cards[0].limits.map(\.id)) == ["fast", "weekly"])
        #expect(BarPresentation.of(outcomes: [fast, weekly]).segments.count == 1)
    }

    @Test func accountCardDoesNotRepeatTheOrgOnEveryLimit() {
        let snap = UsageSnapshot(
            provider: .claude,
            trackingID: "claude:org",
            accountLabel: "Zen",
            limits: [
                Limit(id: "session", label: "5 hours", utilization: 0.01, resetsAt: nil, locked: .unknown, scope: .account),
                Limit(id: "week", label: "Week", utilization: 0.14, resetsAt: nil, locked: .unknown, scope: .account),
            ]
        )
        let card = BarPresentation.cards(from: [.snapshot(snap)])[0]
        #expect(card.defaultName == "Zen")
        #expect(Set(card.limits.map(\.label)) == ["5 hours", "Week"])
    }

    @Test func expiredProviderBecomesAGraySegmentBesideALiveOne() {
        let grok = UsageOutcome.snapshot(UsageSnapshot(provider: .grok, limits: [
            Limit(id: "weekly", label: "Week", utilization: 0.2, resetsAt: nil, locked: .unknown, scope: .account),
        ]))
        let bar = BarPresentation.of(byProvider: [
            .chatGPT: [.expired],
            .grok: [grok],
        ])
        #expect(bar.segments.map(\.provider) == [.chatGPT, .grok])
        #expect(bar.segments[0].tone == .expired)
        #expect(bar.segments[1].tone == .ok)
        #expect(bar.title == "20%")
    }

    @Test func resetIsRemainingTimeNotADate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ResetFormatting.remaining(until: now.addingTimeInterval(2 * 86_400 + 5 * 3600), now: now) == "in 2d 5h")
        #expect(ResetFormatting.remaining(until: now.addingTimeInterval(3 * 86_400), now: now) == "in 3d")
        #expect(ResetFormatting.remaining(until: now.addingTimeInterval(2 * 3600 + 30 * 60), now: now) == "in 2h 30m")
        #expect(ResetFormatting.remaining(until: now.addingTimeInterval(45 * 60), now: now) == "in 45m")
        #expect(ResetFormatting.remaining(until: now.addingTimeInterval(-10), now: now) == "resetting")
    }

    @Test func withIDPrefixKeepsTheHumanLabel() {
        let limit = Limit(id: "session", label: "5 hours", utilization: 0.1, resetsAt: nil, locked: .unknown, scope: .account)
        let tagged = limit.withIDPrefix("org-1")
        #expect(tagged.id == "org-1/session")
        #expect(tagged.label == "5 hours")
    }
}
