import Foundation
import Testing
@testable import UsageBarCore

@Suite("BarPresentation")
struct BarPresentationTests {

    @Test func worstAccountLimitWinsAcrossProviders() {
        let claude = UsageOutcome.snapshot(UsageSnapshot(provider: .claude, limits: [
            Limit(id: "session", label: "5 Stunden", utilization: 0, resetsAt: nil, locked: .unknown, scope: .account),
            Limit(id: "weekly_all", label: "Woche", utilization: 1, resetsAt: nil, locked: .unknown, scope: .account),
            Limit(id: "model", label: "Woche · X", utilization: 1, resetsAt: nil, locked: .unknown, scope: .model),
        ]))
        let grok = UsageOutcome.snapshot(UsageSnapshot(provider: .grok, limits: [
            Limit(id: "fast", label: "2 Stunden · fast", utilization: 0, resetsAt: nil, locked: .unlocked, scope: .account),
        ]))

        let bar = BarPresentation.of(outcomes: [claude, grok])
        #expect(bar.title == "100%")
        #expect(bar.tone == .critical)
        #expect(bar.worst?.id == "weekly_all")
        #expect(bar.provider == .claude)
    }

    @Test func modelLimitCannotPaintTheBar() {
        let snap = UsageOutcome.snapshot(UsageSnapshot(provider: .claude, limits: [
            Limit(id: "weekly_all", label: "Woche", utilization: 0.2, resetsAt: nil, locked: .unknown, scope: .account),
            Limit(id: "model", label: "Woche · X", utilization: 1, resetsAt: nil, locked: .unknown, scope: .model),
        ]))
        let bar = BarPresentation.of(outcomes: [snap])
        #expect(bar.title == "20%")
        #expect(bar.tone == .ok)
    }

    @Test func chatGPTLockPaintsCriticalEvenBelowNinety() {
        let snap = UsageOutcome.snapshot(UsageSnapshot(provider: .chatGPT, limits: [
            Limit(id: "primary", label: "Woche", utilization: 0.5, resetsAt: nil, locked: .locked, scope: .account),
        ]))
        let bar = BarPresentation.of(outcomes: [snap])
        #expect(bar.tone == .critical)
        #expect(bar.title == "50%")
    }

    /// Locked ChatGPT at 40% must beat open Claude at 80%. Utilization-first
    /// ranking hid the lock behind a merely high open number.
    @Test func lockedProviderBeatsHigherOpenUtilization() {
        let claude = UsageOutcome.snapshot(UsageSnapshot(provider: .claude, limits: [
            Limit(id: "weekly_all", label: "Woche", utilization: 0.8, resetsAt: nil, locked: .unknown, scope: .account),
        ]))
        let chatGPT = UsageOutcome.snapshot(UsageSnapshot(provider: .chatGPT, limits: [
            Limit(id: "primary", label: "Woche", utilization: 0.4, resetsAt: nil, locked: .locked, scope: .account),
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
            Limit(id: "weekly_all", label: "Woche", utilization: 0.1, resetsAt: nil, locked: .unknown, scope: .account),
        ]))
        let grok = UsageOutcome.snapshot(UsageSnapshot(provider: .grok, limits: [
            Limit(id: "fast", label: "2 Stunden · fast", utilization: 0.9, resetsAt: nil, locked: .unlocked, scope: .account),
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
            Limit(id: "fast", label: "2 Stunden · fast", utilization: 0.1, resetsAt: nil, locked: .unlocked, scope: .account),
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
            Limit(id: "weekly_all", label: "Woche", utilization: 0.75, resetsAt: nil, locked: .unknown, scope: .account),
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
}
