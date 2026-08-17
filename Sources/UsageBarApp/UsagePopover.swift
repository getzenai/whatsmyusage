import SwiftUI
import UsageBarCore

/// What the popover shows right now. The view observes this instead of being rebuilt:
/// a fresh `NSHostingController` reports its height only after layout, and a refresh
/// used to collapse the open popover to a stub in the meantime.
@MainActor
final class PopoverModel: ObservableObject {
    @Published var cards: [AccountCard] = []
    @Published var waits: [Achievements.CurrentWait] = []
    @Published var hasAchievements = false
    @Published var status: StatusDigest = .off
}

/// What a click in the popover does. Held by the controller, not the view.
struct PopoverActions {
    var rename: (String, String) -> Void
    var refresh: () -> Void
    var openSettings: () -> Void
    var openAchievements: () -> Void
    var quit: () -> Void
}

/// Popover body. Custom views — not disabled menu rows — so the type stays readable.
struct UsagePopoverView: View {
    @ObservedObject var model: PopoverModel
    let actions: PopoverActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.cards.isEmpty {
                Text("No account — open Settings to paste cookies.")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .padding(16)
            } else {
                ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                    if index > 0 { Divider().opacity(0.35) }
                    AccountCardView(
                        card: card,
                        waits: model.waits,
                        disruption: model.status.banner(for: card.provider),
                        onRename: actions.rename
                    )
                }
            }

            if let line = model.status.line() {
                Divider().opacity(0.35)
                StatusLineView(line: line, entries: model.status.entries)
            }

            Divider().opacity(0.35)
            HStack(spacing: 12) {
                Button("Refresh", action: actions.refresh)
                Button("Settings…", action: actions.openSettings)
                if model.hasAchievements {
                    // An icon, not a section: the badges are the fun part, not the point.
                    Button(action: actions.openAchievements) {
                        Image(systemName: "trophy")
                            .font(.system(size: 12))
                    }
                    .help("Achievements")
                    .accessibilityLabel("Achievements")
                }
                Spacer()
                Text(AppVersion.label)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button("Quit", action: actions.quit)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 360)
        .background(.background)
    }
}

/// The one line the normal case is allowed to cost. Grey, and the only thing
/// in it is the time: a standing "All Systems Operational" teaches the eye to
/// skip the spot, and the real outage gets skipped with it.
private struct StatusLineView: View {
    let line: StatusDigest.Line
    let entries: [StatusDigest.Entry]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if line.tone != .quiet {
                Image(systemName: line.tone == .trouble ? "exclamationmark.triangle.fill" : "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(line.tone == .trouble ? Color.orange : Color.secondary)
            }
            if let url = link {
                Link(line.text, destination: url)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
            } else {
                Text(line.text)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .help(helpText)
    }

    private var color: Color {
        switch line.tone {
        case .quiet: .secondary
        case .trouble: .primary
        case .unchecked: .secondary
        }
    }

    /// Only a line that is about one page gets to open one.
    private var link: URL? {
        let troubled = entries.filter { $0.state == .trouble && $0.source.provider == nil }
        guard troubled.count == 1 else { return nil }
        return troubled[0].incidents.first?.url ?? troubled[0].source.pageURL
    }

    private var helpText: String {
        entries.map { entry in
            switch entry.state {
            case .ok: "\(entry.source.displayName): no incidents"
            case .trouble: "\(entry.source.displayName): \(entry.headline ?? "incident")"
            case .unchecked: "\(entry.source.displayName): \(entry.headline ?? "not checked")"
            }
        }.joined(separator: "\n")
    }
}

/// The disruption sits on the account it is about, because that is where the
/// question "is it me or them?" is asked.
private struct DisruptionBanner: View {
    let entry: StatusDigest.Entry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Link(destination: entry.incidents.first?.url ?? entry.source.pageURL) {
                    Text(entry.headline ?? "\(entry.source.displayName) reports an incident")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Which services, and since when — the two things that decide whether the
    /// incident is the one holding *you* up.
    private var detail: String? {
        var bits: [String] = []
        let names = entry.incidents.flatMap(\.componentNames) + entry.degraded.map(\.name)
        if !names.isEmpty {
            var seen: Set<String> = []
            bits.append(names.filter { seen.insert($0).inserted }.joined(separator: ", "))
        }
        if let started = entry.incidents.compactMap(\.startedAt).min() {
            bits.append("open for \(max(0, Date().timeIntervalSince(started)).hoursAndMinutes)")
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }
}

private struct AccountCardView: View {
    let card: AccountCard
    let waits: [Achievements.CurrentWait]
    var disruption: StatusDigest.Entry?
    var onRename: (String, String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var nameFocused: Bool

    private var displayName: String {
        AccountNames.name(for: card.trackingID, default: card.defaultName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if editing {
                    TextField("Account name", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .focused($nameFocused)
                        .onSubmit { commit() }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { commit() }
                        }
                        .onDisappear { commit() }
                        .onAppear { nameFocused = true }
                } else {
                    Text(displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .onTapGesture { beginEdit() }
                        .help("Click to rename")
                }
                Spacer(minLength: 8)
            }

            if let disruption {
                DisruptionBanner(entry: disruption)
            }

            if let message = card.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }

            ForEach(card.limits) { limit in
                LimitRow(limit: limit, wait: wait(for: limit))
            }

            if let reset = card.resetAvailableLabel {
                Text(reset)
                    .font(.system(size: 12))
                    .foregroundStyle(card.tone == .blocked ? Color.primary : Color.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// The wait belongs to the limit it is about — on its own it read like a badge.
    private func wait(for limit: Limit) -> Achievements.CurrentWait? {
        waits.first { $0.trackingID == card.trackingID && $0.limitID == limit.id }
    }

    private func beginEdit() {
        draft = displayName
        editing = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        nameFocused = false
        onRename(card.trackingID, draft)
    }
}

private struct LimitRow: View {
    let limit: Limit
    var wait: Achievements.CurrentWait?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(limit.label)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if limit.locked == .locked {
                    Text("locked")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red)
                }
                Text(BarPresentation.percentString(limit.utilization))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(barColor)
                        .frame(width: max(4, geo.size.width * BarPresentation.filledFraction(limit.utilization)))
                }
            }
            .frame(height: 5)

            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Reset time and, when this limit is the one holding you up, how long it has.
    /// The measured wait, not now − since: the last reading is the last thing we know.
    private var footnote: String? {
        let reset = limit.resetsAt.map { "resets \(ResetFormatting.remaining(until: $0))" }
        let waiting = wait.map { "full for \($0.duration.hoursAndMinutes)" }
        return [reset, waiting].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    private var barColor: Color {
        switch BarPresentation.tone(of: limit) {
        case .blocked: return .red
        case .critical: return .orange
        case .warning: return .yellow
        case .ok: return .green
        default: return .gray
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
