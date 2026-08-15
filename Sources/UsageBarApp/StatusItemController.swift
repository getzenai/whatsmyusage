import AppKit
import UsageBarCore

/// Owns the menu bar item. Deliberately dumb: it paints `BarPresentation` and
/// lists limits. Refresh and cookie storage live elsewhere.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    var onRefresh: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    private var outcomes: [UsageOutcome] = []
    private var lastError: String?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.autoenablesItems = false
        statusItem.menu = menu
        render(BarPresentation.idle)
    }

    func update(outcomes: [UsageOutcome], error: String? = nil) {
        self.outcomes = outcomes
        self.lastError = error
        render(BarPresentation.of(outcomes: outcomes))
    }

    private func render(_ bar: BarPresentation) {
        if let button = statusItem.button {
            button.title = bar.title
            button.toolTip = tooltip(for: bar)
            button.attributedTitle = NSAttributedString(
                string: bar.title,
                attributes: [.foregroundColor: color(for: bar.tone), .font: NSFont.menuBarFont(ofSize: 13)]
            )
        }
        rebuildMenu(bar)
    }

    private func rebuildMenu(_ bar: BarPresentation) {
        menu.removeAllItems()

        let snapshots = outcomes.compactMap { outcome -> UsageSnapshot? in
            if case .snapshot(let s) = outcome { return s }
            return nil
        }

        if snapshots.isEmpty && outcomes.isEmpty {
            addDisabled("No account — paste cookies…")
        }

        for snapshot in snapshots {
            addDisabled(snapshot.provider.displayName + (snapshot.accountLabel.map { " · \($0)" } ?? ""))
            for limit in snapshot.limits.sortedByUrgency() {
                addDisabled(row(for: limit))
            }
            menu.addItem(.separator())
        }

        for outcome in outcomes {
            switch outcome {
            case .snapshot:
                break
            case .expired:
                addDisabled("Sign-in expired")
            case .notTrackable(let message):
                addDisabled("Not trackable: \(message)")
            case .httpError(let status):
                addDisabled(status < 0 ? "Network error" : "HTTP \(status)")
            case .notJSON:
                addDisabled("Response was not JSON")
            case .empty:
                addDisabled("No limits in the response")
            }
        }

        if let lastError {
            addDisabled(lastError)
        }

        if !outcomes.isEmpty && snapshots.isEmpty {
            menu.addItem(.separator())
        }

        addAction("Refresh", #selector(refresh), key: "r")
        addAction("Cookies…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        addAction("Quit", #selector(quit), key: "q")
    }

    private func row(for limit: Limit) -> String {
        let pct = BarPresentation.percentString(limit.utilization)
        var text = "\(limit.label)  \(pct)"
        if limit.locked == .locked { text += "  locked" }
        if let reset = limit.resetsAt {
            text += "  → \(resetFormatter.string(from: reset))"
        }
        return text
    }

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ title: String, _ selector: Selector, key: String) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
    }

    private func color(for tone: BarTone) -> NSColor {
        switch tone {
        case .idle, .expired: return .secondaryLabelColor
        case .ok: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .error: return .systemRed
        }
    }

    private func tooltip(for bar: BarPresentation) -> String {
        if let worst = bar.worst, let provider = bar.provider {
            return "\(provider.displayName) · \(worst.label) · \(bar.title)"
        }
        return "AI Usage Bar"
    }

    private let resetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    @objc private func refresh() { onRefresh?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func quit() { onQuit?() }
}
