import AppKit
import SwiftUI
import UsageBarCore

/// Owns the menu bar item. Paints the pill; the popover lists every account.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?
    var onRename: ((String, String) -> Void)?

    private var outcomes: [UsageOutcome] = []
    private var lastError: String?
    private var cards: [AccountCard] = []

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
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
            button.toolTip = tooltip(for: BarPresentation.showing(cards))
        }
    }

    func update(outcomes: [UsageOutcome], error: String? = nil) {
        self.outcomes = outcomes
        self.lastError = error
        let presentation = BarPresentation.of(outcomes: outcomes)
        self.cards = presentation.cards
        render(presentation)
        if popover.isShown {
            installPopoverContent()
        }
    }

    func update(byProvider: [Provider: [UsageOutcome]], error: String? = nil) {
        update(cards: BarPresentation.cards(byProvider: byProvider), byProvider: byProvider, error: error)
    }

    func update(cards: [AccountCard], byProvider: [Provider: [UsageOutcome]], error: String? = nil) {
        let flat = Provider.allCases.flatMap { byProvider[$0] ?? [] }
        self.outcomes = flat
        self.lastError = error
        self.cards = cards
        render(BarPresentation.showing(cards))
        if popover.isShown {
            installPopoverContent()
        }
    }

    private func render(_ bar: BarPresentation) {
        guard let button = statusItem.button else { return }
        let image = PillImage.draw(segments: bar.segments)
        button.image = image
        button.title = ""
        button.toolTip = tooltip(for: bar)
        button.setAccessibilityLabel(accessibilityLabel(for: bar))
        statusItem.length = image.size.width + 8
    }

    private func tooltip(for bar: BarPresentation) -> String {
        if bar.segments.isEmpty { return "AI Usage Bar" }
        return bar.segments.map { segment in
            let name = AccountNames.name(for: segment.trackingID, default: segment.name)
            let pct = segment.utilization.map(BarPresentation.percentString) ?? "—"
            return "\(name) \(pct)"
        }.joined(separator: " · ")
    }

    private func accessibilityLabel(for bar: BarPresentation) -> String {
        tooltip(for: bar)
    }

    private func installPopoverContent() {
        let view = UsagePopoverView(
            cards: cards,
            onRename: { [weak self] id, name in
                self?.onRename?(id, name)
                if self?.popover.isShown == true {
                    self?.installPopoverContent()
                }
            },
            onRefresh: { [weak self] in self?.onRefresh?() },
            onCookies: { [weak self] in
                self?.popover.performClose(nil)
                self?.onOpenSettings?()
            },
            onQuit: { [weak self] in self?.onQuit?() }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.intrinsicContentSize]
        popover.contentViewController = hosting
        var size = hosting.view.fittingSize
        if size.width < 360 { size.width = 360 }
        if size.height < 80 { size.height = 220 }
        popover.contentSize = size
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        installPopoverContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Fixed-width segments so neighbouring menu-bar icons do not jump while
/// the set of accounts stays the same.
enum PillImage {
    static let segmentWidth: CGFloat = 8
    static let gap: CGFloat = 2
    static let height: CGFloat = 14
    static let pad: CGFloat = 3

    static func draw(segments: [BarSegment]) -> NSImage {
        let count = max(segments.count, 1)
        let width = pad * 2 + CGFloat(count) * segmentWidth + CGFloat(max(0, count - 1)) * gap
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size, flipped: false) { rect in
            let capsule = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2, yRadius: height / 2)
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            capsule.fill()

            let slots = segments.isEmpty
                ? [BarTone.idle]
                : segments.map(\.tone)
            for (index, tone) in slots.enumerated() {
                let x = pad + CGFloat(index) * (segmentWidth + gap)
                let slot = NSRect(x: x, y: 3, width: segmentWidth, height: height - 6)
                color(for: tone).setFill()
                NSBezierPath(roundedRect: slot, xRadius: 2, yRadius: 2).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func color(for tone: BarTone) -> NSColor {
        switch tone {
        case .ok: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .error: return .systemRed.withAlphaComponent(0.7)
        case .idle, .expired: return .systemGray
        }
    }
}
