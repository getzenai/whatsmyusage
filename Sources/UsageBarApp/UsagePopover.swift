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
                    AccountCardView(card: card, waits: model.waits, onRename: actions.rename)
                }
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

private struct AccountCardView: View {
    let card: AccountCard
    let waits: [Achievements.CurrentWait]
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

            if let message = card.message {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
            }

            ForEach(card.limits) { limit in
                LimitRow(limit: limit, wait: wait(for: limit))
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
        case .critical: return .red
        case .warning: return .orange
        case .ok: return .green
        default: return .gray
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
