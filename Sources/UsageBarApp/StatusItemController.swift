import AppKit
import SwiftUI
import UsageBarCore

/// Owns the menu bar item. Paints the pill; the popover lists every account.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let model = PopoverModel()
    private let achievementsWindow = AchievementsWindowController()
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onOpenUpdate: (() -> Void)?
    var onRename: ((String, String) -> Void)?
    /// Asked for on every popover open, so the badges are as fresh as the log.
    var historyProvider: (() -> PopoverHistory)?
    /// One slot per account, or one for all of them. Set from the preferences.
    var pillStyle: PillStyle = .perAccount

    private var outcomes: [UsageOutcome] = []
    private var lastError: String?
    private var cards: [AccountCard] = []
    private var status: StatusDigest = .off
    /// The version a background check found, or nil. Pushed in rather than read
    /// from the updater: the popover stays a view over what it was handed.
    var updateVersion: String? {
        didSet {
            guard updateVersion != oldValue else { return }
            if popover.isShown { refreshPopoverData() }
        }
    }

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = makeContentController()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp])
            button.imagePosition = .imageOnly
        }
        render(BarPresentation.idle)
    }

    func refreshTooltip() {
        if let button = statusItem.button {
            button.toolTip = tooltip(for: BarPresentation.showing(cards, pill: pillStyle))
        }
    }

    /// Arrives on its own schedule — a status read is not a usage reading, and
    /// making one wait for the other would age both.
    func update(status digest: StatusDigest) {
        self.status = digest
        render(BarPresentation.showing(cards, pill: pillStyle))
        if popover.isShown { refreshPopoverData() }
    }

    func update(outcomes: [UsageOutcome], error: String? = nil) {
        self.outcomes = outcomes
        self.lastError = error
        let presentation = BarPresentation.of(outcomes: outcomes, pill: pillStyle)
        self.cards = presentation.cards
        render(presentation)
        if popover.isShown { refreshPopoverData() }
    }

    func update(byProvider: [Provider: [UsageOutcome]], error: String? = nil) {
        update(cards: BarPresentation.cards(byProvider: byProvider), byProvider: byProvider, error: error)
    }

    func update(cards: [AccountCard], byProvider: [Provider: [UsageOutcome]], error: String? = nil) {
        let flat = Provider.allCases.flatMap { byProvider[$0] ?? [] }
        self.outcomes = flat
        self.lastError = error
        self.cards = cards
        render(BarPresentation.showing(cards, pill: pillStyle))
        if popover.isShown { refreshPopoverData() }
    }

    private func render(_ bar: BarPresentation) {
        guard let button = statusItem.button else { return }
        let image = PillImage.draw(segments: bar.segments, disrupted: disruptedSegmentIDs)
        button.image = image
        button.title = ""
        button.toolTip = tooltip(for: bar)
        button.setAccessibilityLabel(accessibilityLabel(for: bar))
        statusItem.length = image.size.width + 8
    }

    /// The slots that carry a dot. In compact mode there is one slot for
    /// everything, so any disrupted account dots it.
    private var disruptedSegmentIDs: Set<String> {
        guard pillStyle != .compact else {
            return status.dotsCompactSlot(cards: cards) ? [BarPresentation.compactTrackingID] : []
        }
        return status.dottedTrackingIDs(cards: cards)
    }

    private func tooltip(for bar: BarPresentation) -> String {
        if bar.segments.isEmpty { return AppIdentity.displayName }
        let dotted = disruptedSegmentIDs
        let accounts = bar.segments.map { segment in
            let name = AccountNames.name(for: segment.trackingID, default: segment.name)
            let pct = segment.utilization.map(BarPresentation.percentString) ?? "—"
            let flag = dotted.contains(segment.trackingID) ? " ⚠︎" : ""
            return "\(name) \(pct)\(flag)"
        }.joined(separator: " · ")
        guard let line = status.line() else { return accounts }
        return "\(accounts)\n\(line.text)"
    }

    private func accessibilityLabel(for bar: BarPresentation) -> String {
        tooltip(for: bar)
    }

    /// Built once. Replacing it while the popover is open is what collapsed the
    /// window to a stub on Refresh — the new controller has no measured height yet.
    private func makeContentController() -> NSViewController {
        let view = UsagePopoverView(
            model: model,
            actions: PopoverActions(
                rename: { [weak self] id, name in self?.onRename?(id, name) },
                refresh: { [weak self] in self?.onRefresh?() },
                openSettings: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.onOpenSettings?()
                },
                openAchievements: { [weak self] in
                    guard let self else { return }
                    self.popover.performClose(nil)
                    self.achievementsWindow.show(self.history.achievements)
                },
                openUpdate: { [weak self] in
                    self?.popover.performClose(nil)
                    self?.onOpenUpdate?()
                },
                quit: { [weak self] in self?.onQuit?() }
            )
        )
        let hosting = NSHostingController(rootView: view)
        // `.preferredContentSize` is the one NSPopover follows. With
        // `.intrinsicContentSize` the popover keeps AppKit's 320×320 default and
        // clips the accounts off the bottom.
        hosting.sizingOptions = [.preferredContentSize]
        return hosting
    }

    /// The popover reads the log every time it opens, and again on every refresh
    /// while it is open, so the waits are as fresh as the numbers above them.
    private var history: PopoverHistory = .none

    private func refreshPopoverData() {
        history = historyProvider?() ?? .none
        model.cards = cards
        model.waits = history.waits
        model.hasAchievements = !history.achievements.isEmpty
        model.status = status
        model.updateVersion = updateVersion
    }

    func openPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        refreshPopoverData()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        openPopover()
    }
}

/// Fixed-width segments so neighbouring menu-bar icons do not jump while
/// the set of accounts stays the same.
enum PillImage {
    static let segmentWidth: CGFloat = 8
    static let gap: CGFloat = 2
    static let height: CGFloat = 14
    static let pad: CGFloat = 3

    /// Diameter of the disruption dot. Small on purpose: the slot's colour
    /// already means "how full", and a provider outage must not repaint it.
    /// Above the slot there is no room either — the menu bar is 22 pt and the
    /// pill 14 of them, so a badge on top gets clipped.
    static let dotDiameter: CGFloat = 3.5

    static func draw(segments: [BarSegment], disrupted: Set<String> = []) -> NSImage {
        let count = max(segments.count, 1)
        let width = pad * 2 + CGFloat(count) * segmentWidth + CGFloat(max(0, count - 1)) * gap
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let capsule = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2, yRadius: height / 2)
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            capsule.fill()

            let slots = segments.isEmpty
                ? [BarSegment(trackingID: "", provider: .claude, name: "", utilization: nil, tone: .idle)]
                : segments
            for (index, segment) in slots.enumerated() {
                let x = pad + CGFloat(index) * (segmentWidth + gap)
                let slot = NSRect(x: x, y: 3, width: segmentWidth, height: height - 6)
                let fill = color(for: segment.tone)
                fill.setFill()
                NSBezierPath(roundedRect: slot, xRadius: 2, yRadius: 2).fill()

                guard disrupted.contains(segment.trackingID) else { continue }
                let dot = NSRect(
                    x: slot.midX - dotDiameter / 2,
                    y: slot.maxY - dotDiameter - 1,
                    width: dotDiameter,
                    height: dotDiameter
                )
                // Ink, not a new hue: the palette says "how full", and a
                // disruption somewhere else is not a fuller meter. The ink
                // follows the slot, not the system theme — `labelColor` in
                // Dark Mode is nearly white, and white on `systemGreen` is
                // 2:1.
                nsColor(for: DisruptionInk.on(fill: srgb(of: fill))).setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func color(for tone: BarTone) -> NSColor {
        switch tone {
        case .ok: return .systemGreen
        case .warning: return .systemYellow
        case .critical: return .systemOrange
        case .blocked: return .systemRed
        case .error: return .systemRed.withAlphaComponent(0.7)
        case .idle, .expired: return .systemGray
        }
    }

    private static func srgb(of color: NSColor) -> SRGBColor {
        let converted = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        return SRGBColor(
            red: Double(converted.redComponent),
            green: Double(converted.greenComponent),
            blue: Double(converted.blueComponent)
        )
    }

    private static func nsColor(for ink: DisruptionInk) -> NSColor {
        let c = ink.color
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}
